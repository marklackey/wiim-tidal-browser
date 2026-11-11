import AppKit
import Darwin

private class Launcher: NSObject, NSApplicationDelegate {
    let url: URL
    let openOnLaunch: Bool
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let networkStatus = NSTextField(wrappingLabelWithString:
        "If discovery is blocked, request access and choose Allow in macOS.")

    init(url: URL, openOnLaunch: Bool) {
        self.url = url
        self.openOnLaunch = openOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "WiiM TIDAL")
        if item.button?.image == nil { item.button?.title = "WiiM" }
        item.button?.toolTip = "WiiM TIDAL"
        let menu = NSMenu()
        menu.addItem(menuItem("Open in Browser", #selector(openBrowser)))
        menu.addItem(menuItem("Local Network Access…", #selector(showNetworkAccess)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit WiiM TIDAL", #selector(quit)))
        item.menu = menu
        statusItem = item
        if openOnLaunch { openBrowser() }
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func showNetworkAccess() {
        if window == nil { window = makeAccessWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeAccessWindow() -> NSWindow {
        let heading = NSTextField(labelWithString: "WiiM TIDAL")
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "The local server is ready.")
        subtitle.textColor = .secondaryLabelColor
        let open = NSButton(title: "Open in Browser", target: self, action: #selector(openBrowser))
        open.keyEquivalent = "\r"
        open.bezelStyle = .rounded
        let networkHeading = NSTextField(labelWithString: "Local Network access")
        networkHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        networkStatus.textColor = .secondaryLabelColor
        let allow = NSButton(title: "Request Access", target: self, action: #selector(requestNetworkAccess))
        let settings = NSButton(title: "Open Privacy Settings", target: self, action: #selector(openPrivacySettings))
        let networkActions = NSStackView(views: [allow, settings])
        networkActions.spacing = 8
        let divider = NSBox()
        divider.boxType = .separator
        let controls = NSStackView(views: [heading, subtitle, open, divider, networkHeading, networkStatus, networkActions])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 9
        controls.setCustomSpacing(17, after: open)
        controls.setCustomSpacing(16, after: divider)
        controls.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 402, height: 258),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "WiiM TIDAL"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 21),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 23),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -23),
            divider.widthAnchor.constraint(equalTo: controls.widthAnchor),
            networkStatus.widthAnchor.constraint(equalTo: controls.widthAnchor),
        ])
        window.center()
        return window
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openBrowser()
        return false
    }

    @objc func openBrowser() {
        if !NSWorkspace.shared.open(url) {
            networkStatus.stringValue = "Open \(url.absoluteString) in your browser."
            showNetworkAccess()
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func openPrivacySettings() {
        if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(settings)
        }
    }

    @objc func requestNetworkAccess() {
        // Apple's documented UDP connect technique triggers the system prompt
        // without sending a datagram. The user still grants access in macOS.
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            networkStatus.stringValue = "Could not request access. Open Privacy Settings."
            return
        }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        networkStatus.stringValue = "Choose Allow if prompted. If access was denied earlier, enable WiiM TIDAL in Privacy Settings, then retry discovery."
    }
}

@_cdecl("wiim_run_launcher")
public func runLauncher(_ address: UnsafePointer<CChar>, _ openOnLaunch: Int32) {
    guard let url = URL(string: String(cString: address)) else { return }
    let app = NSApplication.shared
    let launcher = Launcher(url: url, openOnLaunch: openOnLaunch != 0)
    app.setActivationPolicy(.accessory)
    app.delegate = launcher
    withExtendedLifetime(launcher) { app.run() }
}

@_cdecl("wiim_startup_error")
public func startupError(_ message: UnsafePointer<CChar>) {
    NSApplication.shared.setActivationPolicy(.regular)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "WiiM TIDAL couldn’t start"
    alert.informativeText = String(cString: message)
    alert.runModal()
}
