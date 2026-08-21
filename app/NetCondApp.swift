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

    private static var launchCheckScheduled = false

    init() {
        // A menu-bar app relaunches rarely, so don't rely on the daily
        // schedule alone: check the feed on every launch — silent when up to
        // date, the standard update prompt when a newer version exists. The
        // short delay lets the updater finish starting.
        guard !Self.launchCheckScheduled else { return }
        Self.launchCheckScheduled = true
        let updater = updaterController.updater
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            updater.checkForUpdatesInBackground()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, updaterController: updaterController)
        } label: {
            Image(systemName: model.state.active ? "tortoise.fill" : "speedometer")
        }
        .menuBarExtraStyle(.window)
    }
}
