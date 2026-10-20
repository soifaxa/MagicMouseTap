import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var hasStartedMultitouch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar utility")
        ProcessInfo.processInfo.disableSuddenTermination()

        setupStatusItem()
        requestAccessibilityIfNeeded()
        startMultitouchIfNeeded()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        TouchManager.shared.stop()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "computermouse",
                accessibilityDescription: "Magic Mouse Tap"
            )
        }

        let menu = NSMenu()
        menu.delegate = self

        enabledItem = NSMenuItem(
            title: "Tap to Click",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = .on
        menu.addItem(enabledItem)

        permissionItem = NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(NSMenuItem.separator())

        let reconnect = NSMenuItem(
            title: "Reconnect Mouse",
            action: #selector(reconnect),
            keyEquivalent: "r"
        )
        reconnect.target = self
        menu.addItem(reconnect)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit Magic Mouse Tap",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refreshMenuState()
    }

    private func refreshMenuState() {
        let trusted = AXIsProcessTrusted()
        enabledItem.isEnabled = trusted
        enabledItem.state = TouchManager.shared.isEnabled && trusted ? .on : .off
        permissionItem.isHidden = trusted

        if let button = statusItem.button {
            let symbol = TouchManager.shared.isEnabled && trusted
                ? "computermouse"
                : "computermouse.fill"
            button.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: "Magic Mouse Tap"
            )
        }
    }

    // MARK: - Accessibility / multitouch

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func startMultitouchIfNeeded() {
        guard AXIsProcessTrusted(), !hasStartedMultitouch else { return }
        TouchManager.shared.start()
        hasStartedMultitouch = true
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        guard AXIsProcessTrusted() else {
            openAccessibilitySettings()
            return
        }
        TouchManager.shared.isEnabled.toggle()
        refreshMenuState()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        requestAccessibilityIfNeeded()
    }

    @objc private func reconnect() {
        guard AXIsProcessTrusted() else { return }
        TouchManager.shared.restart()
        hasStartedMultitouch = true
    }

    @objc private func systemDidWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, AXIsProcessTrusted() else { return }
            TouchManager.shared.restart()
            self.hasStartedMultitouch = true
            self.refreshMenuState()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Start once Accessibility is granted, without requiring a full relaunch.
        startMultitouchIfNeeded()
        refreshMenuState()
    }
}
