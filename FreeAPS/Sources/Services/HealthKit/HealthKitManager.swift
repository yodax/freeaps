import Foundation
import HealthKit
import Swinject

protocol HealthKitManager {
    /// Storage of HealthKit
    var store: HKHealthStore { get }
    /// Check availability HealthKit on current device and user's permissions
    var isAvailableOnCurrentDevice: Bool { get }
    /// Check all needed permissions
    /// Return false if one or more permissions are deny or not choosen
    var areAllowAllPermissions: Bool { get }
    /// Check availability HealthKit on current device and user's permission of object
    func isAvailableFor(object: HKObjectType) -> Bool
    /// Requests user to give permissions on using HealthKit
    func requestPermission(completion: ((Bool, Error?) -> Void)?)
    /// Save blood glucose data to HealthKit store
    func save(bloodGlucoses: [BloodGlucose], completion: ((Result<Bool, Error>) -> Void)?)
    /// Create observer for data passing beetwen Health Store and FreeAPS
    func createObserver()
    /// Enable background delivering objects from Apple Health to FreeAPS
    func enableBackgroundDelivery()
}

final class BaseHealthKitManager: HealthKitManager, Injectable {
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!

    private enum Config {
        // unwraped HKObjects
        static var permissions: Set<HKSampleType> {
            var result: Set<HKSampleType> = []
            for permission in optionalPermissions {
                result.insert(permission!)
            }
            return result
        }

        static let optionalPermissions = Set([Config.HealthBGObject])
        // link to object in HealthKit
        static let HealthBGObject = HKObjectType.quantityType(forIdentifier: .bloodGlucose)

        static let frequencyBackgroundDeliveryBloodGlucoseFromHealth = HKUpdateFrequency(rawValue: 10)!
    }

    // App must have only one HealthKit Store
    private static var _store = HKHealthStore()
    var store: HKHealthStore {
        Self._store
    }

    var isAvailableOnCurrentDevice: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    var areAllowAllPermissions: Bool {
        var result = true
        Config.permissions.forEach { permission in
            if [HKAuthorizationStatus.sharingDenied, HKAuthorizationStatus.notDetermined]
                .contains(store.authorizationStatus(for: permission))
            {
                result = false
            }
        }
        return result
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        guard isAvailableOnCurrentDevice, let bjObject = Config.HealthBGObject else {
            return
        }
        if isAvailableFor(object: bjObject) {
            debug(.service, "Create HealthKit Observer for Blood Glucose")
            createObserver()
        }
        enableBackgroundDelivery()
    }

    func isAvailableFor(object: HKObjectType) -> Bool {
        let status = store.authorizationStatus(for: object)
        switch status {
        case HKAuthorizationStatus.sharingAuthorized:
            return true
        default:
            return false
        }
    }

    func requestPermission(completion: ((Bool, Error?) -> Void)? = nil) {
        guard isAvailableOnCurrentDevice else {
            completion?(false, HKError.notAvailableOnCurrentDevice)
            return
        }
        for permission in Config.optionalPermissions {
            guard permission != nil else {
                completion?(false, HKError.dataNotAvailable)
                return
            }
        }

        store.requestAuthorization(toShare: Config.permissions, read: Config.permissions) { status, error in
            completion?(status, error)
        }
    }

    func save(bloodGlucoses: [BloodGlucose], completion: ((Result<Bool, Error>) -> Void)? = nil) {
        for bgItem in bloodGlucoses {
            let bgQuantity = HKQuantity(
                unit: .milligramsPerDeciliter,
                doubleValue: Double(bgItem.glucose!)
            )

            let bjObjectSample = HKQuantitySample(
                type: Config.HealthBGObject!,
                quantity: bgQuantity,
                start: bgItem.dateString,
                end: bgItem.dateString,
                metadata: [
                    "HKMetadataKeyExternalUUID": bgItem.id,
                    "HKMetadataKeySyncIdentifier": bgItem.id,
                    "HKMetadataKeySyncVersion": 1,
                    "fromFreeAPSX": true
                ]
            )

            store.save(bjObjectSample) { status, error in
                guard error == nil else {
                    completion?(Result.failure(error!))
                    return
                }
                completion?(Result.success(status))
            }
        }
    }

    func createObserver() {
        guard let bgType = Config.HealthBGObject else {
            fatalError("Unable to get the Blood Glucose type")
        }

        let query = HKObserverQuery(sampleType: bgType, predicate: nil) { [unowned self] _, _, observerError in

            if let _ = observerError {
                return
            }

            // loading only daily bg
            let predicate = HKQuery.predicateForSamples(
                withStart: Date().addingTimeInterval(-1.days.timeInterval),
                end: nil,
                options: .strictStartDate
            )

            store.execute(getQueryForDeletedBloodGlucose(sampleType: bgType, predicate: predicate))
            store.execute(getQueryForAddedBloodGlucose(sampleType: bgType, predicate: predicate))
        }
        store.execute(query)
    }

    func enableBackgroundDelivery() {
        guard let bgType = Config.HealthBGObject else {
            fatalError("Unable to get the Blood Glucose type")
        }

        store.enableBackgroundDelivery(
            for: bgType,
            frequency: Config.frequencyBackgroundDeliveryBloodGlucoseFromHealth
        ) { status, e in
            guard e == nil else {
                error(Logger.Category.service, "Can not enable background delivery for Apple Health", description: nil, error: e!)
            }
            debug(.service, "HealthKit background delivery status is \(status)")
        }
    }

    private func getQueryForDeletedBloodGlucose(sampleType: HKQuantityType, predicate: NSPredicate) -> HKQuery {
        let query = HKAnchoredObjectQuery(
            type: sampleType,
            predicate: predicate,
            anchor: nil,
            limit: 1000
        ) { [unowned self] _, _, deletedObjects, _, _ in
            guard let samples = deletedObjects else {
                return
            }

            DispatchQueue.global(qos: .utility).async {
                var removingBGID = [String]()
                samples.forEach {
                    if let idString = $0.metadata?["HKMetadataKeySyncIdentifier"] as? String {
                        removingBGID.append(idString)
                    } else {
                        removingBGID.append($0.uuid.uuidString)
                    }
                }
                glucoseStorage.removeGlucose(byIDCollection: removingBGID)
            }
        }
        return query
    }

    private func getQueryForAddedBloodGlucose(sampleType: HKQuantityType, predicate: NSPredicate) -> HKQuery {
        let query = HKSampleQuery(
            sampleType: sampleType,
            predicate: predicate,
            limit: Int(HKObjectQueryNoLimit),
            sortDescriptors: nil
        ) { [unowned self] _, results, _ in

            guard let samples = results as? [HKQuantitySample] else {
                return
            }

            let oldSamples: [HealthKitSample] = fileStorage
                .retrieve(OpenAPS.HealthKit.downloadedGlucose, as: [HealthKitSample].self) ?? []

            var newSamples = [HealthKitSample]()
            for sample in samples {
                if sample.wasUserEntered {
                    newSamples.append(HealthKitSample(
                        healthKitId: sample.uuid.uuidString,
                        date: sample.startDate,
                        glucose: Int(round(sample.quantity.doubleValue(for: .milligramsPerDeciliter)))
                    ))
                }
            }

            newSamples = newSamples
                .filter { !oldSamples.contains($0) }

            newSamples.forEach({ sample in
                let glucose = BloodGlucose(
                    _id: sample.healthKitId,
                    sgv: nil,
                    direction: nil,
                    date: Decimal(Int(sample.date.timeIntervalSince1970) * 1000),
                    dateString: sample.date,
                    unfiltered: nil,
                    filtered: nil,
                    noise: nil,
                    glucose: sample.glucose,
                    type: nil
                )
                glucoseStorage.storeGlucose([glucose])
            })

            let savingSamples = (newSamples + oldSamples)
                .removeDublicates()
                .filter { $0.date >= Date().addingTimeInterval(-1.days.timeInterval) }

            self.fileStorage.save(savingSamples, as: OpenAPS.HealthKit.downloadedGlucose)
        }
        return query
    }
}

enum HealthKitPermissionRequestStatus {
    case needRequest
    case didRequest
}

enum HKError: Error {
    // HealthKit work only iPhone (not on iPad)
    case notAvailableOnCurrentDevice
    // Some data can be not available on current iOS-device
    case dataNotAvailable
}