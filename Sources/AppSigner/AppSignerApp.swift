import SwiftUI

@main
struct AppSignerApp: App {
    @StateObject private var model = SignerViewModel()

    var body: some Scene {
        WindowGroup("AppSigner") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 460, minHeight: 560)
                .onAppear { model.onAppear() }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}
