import SwiftUI
import Swinject

extension Main {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        var body: some View {
            router.view(for: .home)
                .sheet(isPresented: $state.isModalPresented) {
                    NavigationView { self.state.modal!.view }
                        .navigationViewStyle(StackNavigationViewStyle())
                }
                .sheet(isPresented: $state.isSecondaryModalPresented) {
                    if let view = state.secondaryModalView {
                        view
                    } else {
                        EmptyView()
                    }
                }
                .onAppear(perform: configureView)
        }
    }
}
