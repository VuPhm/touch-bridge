import Cocoa

// MARK: - Native Menu-Bar Surface (P3-01 Section 7)

public protocol MenuBarActionDelegate: AnyObject {
    func menuBarDidToggleEnabled()
    func menuBarDidRequestCalibration()
    func menuBarDidRequestDiagnostics()
    func menuBarDidRequestSettings()
    func menuBarDidRequestAccessibilityPermission()
    func menuBarDidRequestQuit()
}

public final class MenuBarController: NSObject {
    public weak var actionDelegate: MenuBarActionDelegate?
    
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    
    // Status items in menu
    private let titleItem = NSMenuItem(title: "TouchBridge Prototype", action: nil, keyEquivalent: "")
    private let deviceItem = NSMenuItem(title: "Touchscreen: Checking…", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "Display: Checking…", action: nil, keyEquivalent: "")
    private let calibrationItem = NSMenuItem(title: "Calibration: Checking…", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Accessibility: Checking…", action: nil, keyEquivalent: "")
    private let engineItem = NSMenuItem(title: "Touch Engine: Initializing…", action: nil, keyEquivalent: "")
    
    // Action items
    private let enableToggleItem = NSMenuItem(title: "Enable Touch", action: #selector(toggleEnableAction), keyEquivalent: "e")
    private let calibrateItem = NSMenuItem(title: "Calibrate Touchscreen…", action: #selector(calibrateAction), keyEquivalent: "c")
    private let diagnosticsItem = NSMenuItem(title: "Diagnostics…", action: #selector(diagnosticsAction), keyEquivalent: "d")
    private let testbedItem = NSMenuItem(title: "Arbitration Testbed…", action: #selector(testbedAction), keyEquivalent: "t")
    private let settingsItem = NSMenuItem(title: "Status & Settings…", action: #selector(settingsAction), keyEquivalent: ",")
    private let grantAXItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(grantAXAction), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit TouchBridge", action: #selector(quitAction), keyEquivalent: "q")
    
    public override init() {
        super.init()
        setupStatusItem()
        buildMenu()
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = createStatusBarIcon(isOperational: false)
            button.imagePosition = .imageLeft
            button.title = " TB"
            button.toolTip = "TouchBridge — Native Touchscreen Bridge"
        }
        item.menu = menu
        self.statusItem = item
    }
    
    private func buildMenu() {
        menu.removeAllItems()
        
        // Header
        titleItem.attributedTitle = NSAttributedString(
            string: "TouchBridge (P3-01 Runtime)",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        
        // State Information Hierarchy
        for item in [deviceItem, displayItem, calibrationItem, accessibilityItem, engineItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Actions
        enableToggleItem.target = self
        menu.addItem(enableToggleItem)
        
        calibrateItem.target = self
        menu.addItem(calibrateItem)
        
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)
        
        testbedItem.target = self
        menu.addItem(testbedItem)
        
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        grantAXItem.target = self
        grantAXItem.isHidden = true
        menu.addItem(grantAXItem)
        
        menu.addItem(NSMenuItem.separator())
        
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    public func update(with snapshot: RuntimeSnapshot) {
        // 1. Device Item
        let devIcon: String
        switch snapshot.device {
        case .available: devIcon = "🟢"
        case .detected: devIcon = "🟡"
        case .disconnected: devIcon = "⚪️"
        case .unavailableBusy, .error: devIcon = "🔴"
        }
        deviceItem.title = "  \(devIcon) Touchscreen:   \(snapshot.device.description)"
        
        // 2. Display Item
        let dispIcon: String
        switch snapshot.display {
        case .bound: dispIcon = "🟢"
        case .targetDetected: dispIcon = "🟡"
        case .targetMissing: dispIcon = "⚪️"
        case .configurationChanged: dispIcon = "🔴"
        }
        displayItem.title = "  \(dispIcon) Display:           \(snapshot.display.description)"
        
        // 3. Calibration Item
        let calIcon: String
        switch snapshot.calibration {
        case .valid: calIcon = "🟢"
        case .calibrating: calIcon = "🟡"
        case .missing: calIcon = "⚪️"
        case .stale: calIcon = "🔴"
        }
        calibrationItem.title = "  \(calIcon) Calibration:      \(snapshot.calibration.description)"
        
        // 4. Accessibility Item
        let axIcon = snapshot.accessibility == .available ? "🟢" : "🔴"
        accessibilityItem.title = "  \(axIcon) Accessibility:   \(snapshot.accessibility.description)"
        grantAXItem.isHidden = (snapshot.accessibility == .available)
        
        // 5. Engine Item
        let engIcon: String
        switch snapshot.engine {
        case .ready: engIcon = "🟢"
        case .active: engIcon = "🟢"
        case .disabled: engIcon = "⚪️"
        case .suspended, .error: engIcon = "🟡"
        }
        engineItem.title = "  \(engIcon) Touch Engine:  \(snapshot.engine.description)"
        
        // 6. Enable Toggle Item
        enableToggleItem.state = snapshot.isUserEnabled ? .on : .off
        enableToggleItem.title = snapshot.isUserEnabled ? "Touch Enabled" : "Touch Disabled"
        
        // 7. Update status bar icon
        if let button = statusItem?.button {
            button.image = createStatusBarIcon(isOperational: snapshot.engine.isOperational)
            button.toolTip = "TouchBridge: \(snapshot.engine.description)"
        }
    }
    
    private func createStatusBarIcon(isOperational: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        
        let bounds = NSRect(origin: .zero, size: size)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        
        // Outer ring
        let circlePath = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
        circlePath.lineWidth = 1.6
        if isOperational {
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.secondaryLabelColor.setStroke()
        }
        circlePath.stroke()
        
        // Center crosshair / touch target dot
        let dotRect = NSRect(x: center.x - 2.5, y: center.y - 2.5, width: 5.0, height: 5.0)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        if isOperational {
            NSColor.controlAccentColor.setFill()
        } else {
            NSColor.secondaryLabelColor.setFill()
        }
        dotPath.fill()
        
        img.unlockFocus()
        img.isTemplate = !isOperational
        return img
    }
    
    // MARK: - Actions
    
    @objc private func toggleEnableAction() {
        actionDelegate?.menuBarDidToggleEnabled()
    }
    
    @objc private func calibrateAction() {
        actionDelegate?.menuBarDidRequestCalibration()
    }
    
    @objc private func diagnosticsAction() {
        actionDelegate?.menuBarDidRequestDiagnostics()
    }
    
    @objc private func testbedAction() {
        ArbitrationTestWindowController.shared.showTestWindow()
    }
    
    @objc private func settingsAction() {
        actionDelegate?.menuBarDidRequestSettings()
    }
    
    @objc private func grantAXAction() {
        actionDelegate?.menuBarDidRequestAccessibilityPermission()
    }
    
    @objc private func quitAction() {
        actionDelegate?.menuBarDidRequestQuit()
    }
}
