import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private var panel: SearchPanelController!
    private var hud: HUDController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SearchPanelController(model: model)
        hud = HUDController(model: model)
        panel.openSettings = { [weak self] in self?.openSettings() }

        model.togglePanel = { [weak self] in self?.panel.toggle() }
        model.hidePanel = { [weak self] in self?.panel.hide() }
        model.showHUD = { [weak self] text, isError in self?.hud.show(text, isError: isError) }

        setUpMainMenu()
        setUpStatusItem()
        model.$bridgeState.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusIcon() }.store(in: &bag)
        model.startServices()

        if model.catalog.isEmpty && model.presets.isEmpty {
            // First launch: show where to find the pairing code.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.openSettings(tab: "connection") }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    /// Menu-bar apps still need an Edit menu, or ⌘C/⌘V/⌘A won't work in text fields.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    // MARK: status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        // Cue mark: filled cue point when Premiere is connected, hollow while waiting.
        let connected = model.bridgeState.isConnected
        let image = NSImage(named: connected ? "MenuBarIcon" : "MenuBarIconIdle")
            ?? NSImage(systemSymbolName: connected ? "command.square.fill" : "command.square", accessibilityDescription: "Cue")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "Cue — \(model.bridgeState.label)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: "Open Cue", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        open.toolTip = model.prefs.openHotKey.display
        menu.addItem(open)
        menu.addItem(.separator())

        let state = NSMenuItem(title: model.bridgeState.label, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let code = NSMenuItem(title: "Pairing code: \(model.prefs.pairingCode)", action: #selector(copyCode), keyEquivalent: "")
        code.target = self
        menu.addItem(code)
        let sync = NSMenuItem(title: "Sync Effects from Premiere", action: model.bridgeState.isConnected ? #selector(sync) : nil, keyEquivalent: "")
        sync.target = self
        menu.addItem(sync)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func openPanel() { panel.show() }
    @objc private func sync() { model.requestSync() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.prefs.pairingCode, forType: .string)
    }

    // MARK: settings window

    func openSettings(tab: String? = nil) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            let w = NSWindow(contentViewController: host)
            w.title = "Cue Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 780, height: 600))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        if let tab {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .cueSelectSettingsTab, object: tab) }
        }
    }
}

extension Notification.Name {
    static let cueSelectSettingsTab = Notification.Name("CueSelectSettingsTab")
}
