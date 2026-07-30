import SwiftUI

@main
struct ZulipMacApp: App {
    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            AppRootView()
        }
        .defaultSize(width: 1_080, height: 720)
        .windowStyle(.hiddenTitleBar)

        Settings {
            Form {
                LabeledContent("Application", value: AppIdentity.displayName)
                LabeledContent("Minimum system", value: AppIdentity.minimumSystem)
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 420)
        }
    }
}
