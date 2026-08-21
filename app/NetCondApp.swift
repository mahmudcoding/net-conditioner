import Sparkle
import SwiftUI

@main
struct NetCondApp: App {
    @StateObject private var model = ShapingModel()

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, updaterController: updaterController)
        } label: {
            Image(systemName: model.state.active ? "tortoise.fill" : "speedometer")
        }
        .menuBarExtraStyle(.window)
    }
}
