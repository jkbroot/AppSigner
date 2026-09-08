import SwiftUI

@main
struct AppSignerApp: App {
    @StateObject private var model = SignerViewModel()

    var body: some Scene {
        WindowGroup("AppSigner") {
            RootView()
                .environmentObject(model)
                .onAppear { model.onAppear() }
                .onOpenURL { model.acceptFiles([$0]) }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
    }
}
