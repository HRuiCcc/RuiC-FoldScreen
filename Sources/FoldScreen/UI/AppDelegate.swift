import AppKit
import Combine
import SwiftUI

/// Wires the pieces together and owns the menu bar item.
///
/// The app is an accessory (`LSUIElement`), so this delegate is the only place
/// that knows about AppKit: the effect, the settings store, and the preview all
/// stay free of window management.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var store: SettingsStore!
    private var effect: LiveFold!
    private var preview: FoldPreview!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    /// Keeps the menu bar item in step with the preference.
    private var iconObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SettingsStore()
        // The scripted source and still frames are test seams, reachable from the
        // command line so the effect can be exercised without a physical lid.
        let sensor: LidAngleSource? =
            CommandLine.arguments.contains("--scripted-lid") ? ScriptedLidAngleSource.sweep() : nil
        let effect = LiveFold(store: store, sensor: sensor)
        let preview = FoldPreview(store: store)

        self.store = store
        self.effect = effect
        self.preview = preview

        observeIconPreference()

        // The headless check takes precedence over whatever was persisted, so it
        // behaves the same on a machine that has run the app before.
        if CommandLine.arguments.contains("--smoke") {
            effect.startForDiagnostics()
            Task { [effect] in
                try? await Task.sleep(for: .seconds(6))
                let report = await effect.diagnosticReport()
                try? report.write(
                    toFile: "/tmp/foldscreen-smoke.txt", atomically: true, encoding: .utf8)
            }
        } else {
            if effect.isEnabled {
                // Restore the effect if it was on when the app last quit.
                effect.restoreIfNeeded()
            }
            if shouldOpenSettingsOnLaunch {
                openSettings()
            }
        }
    }

    /// Whether launching the app should put the settings window on screen.
    ///
    /// A first run explains itself, and so does a launch that is the only route
    /// back to a hidden menu bar item. A login-item launch is neither: the user
    /// did not ask for anything, so it stays quiet.
    private var shouldOpenSettingsOnLaunch: Bool {
        guard !LoginItem.launchedAsLoginItem else { return false }
        return !effect.isEnabled || store.settings.hideMenuBarIcon
    }

    /// Reopening a running app is how the user asks for the settings window back
    /// once the menu bar item is hidden, so bring it up rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        effect?.disable(message: "已退出。")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        effect?.refreshLoginItem()
    }

    // MARK: - Menu bar

    /// Puts the menu bar item in or out of the menu bar as the user asks.
    ///
    /// `@Published` replays the current value on subscription, so this also gets
    /// the item right on launch without a separate code path.
    private func observeIconPreference() {
        iconObservation = store.$settings
            .map(\.hideMenuBarIcon)
            .removeDuplicates()
            .sink { [weak self] hidden in self?.setMenuBarItemHidden(hidden) }
    }

    private func setMenuBarItemHidden(_ hidden: Bool) {
        if hidden {
            guard let statusItem else { return }
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        } else {
            installStatusItem()
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "laptopcomputer", accessibilityDescription: "合盖弯屏")
        item.button?.toolTip = "合盖弯屏 RuiC-FoldScreen"

        let menu = NSMenu()
        menu.addItem(withTitle: "合盖弯屏", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let toggle = menu.addItem(
            withTitle: "启用 / 暂停", action: #selector(toggleEffect), keyEquivalent: "")
        toggle.target = self

        let settings = menu.addItem(
            withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self

        let play = menu.addItem(
            withTitle: "播放预览", action: #selector(playPreview), keyEquivalent: "")
        play.target = self

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出合盖弯屏", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleEffect() {
        effect.toggle()
    }

    @objc private func playPreview() {
        openSettings()
        preview.play()
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        effect.refreshLoginItem()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "合盖弯屏"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 720, height: 540)
            window.contentView = NSHostingView(
                rootView: SettingsView(store: store, effect: effect, preview: preview))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The window is kept for reuse, so stop the preview animation when it is
        // no longer on screen.
        preview?.pause()
    }
}
