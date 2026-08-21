import AppKit
import SwiftUI

/// Reports the hosting panel's real visibility to the model. SwiftUI's
/// onAppear/onDisappear are not re-fired reliably by MenuBarExtra's window
/// panel, so open/close detection hangs off the window itself: attachment
/// plus occlusion-state changes.
struct PanelVisibility: NSViewRepresentable {
    let model: ShapingModel

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.model = model
    }

    final class ObservingView: NSView {
        weak var model: ShapingModel?
        private var observation: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observation {
                NotificationCenter.default.removeObserver(observation)
                self.observation = nil
            }
            guard let window else {
                model?.panelDidClose()
                return
            }
            observation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportVisibility() }
            }
            reportVisibility()
        }

        private func reportVisibility() {
            guard let window else {
                model?.panelDidClose()
                return
            }
            if window.isVisible && window.occlusionState.contains(.visible) {
                model?.panelDidOpen()
            } else {
                model?.panelDidClose()
            }
        }

        deinit {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
        }
    }
}
