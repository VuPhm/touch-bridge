import Cocoa

// MARK: - Native Status & Settings Window (P3-01 Section 1 & 7)

public final class StatusSettingsWindowController: NSWindowController {
    public static let shared = StatusSettingsWindowController()
    
    private let deviceLabel = NSTextField(labelWithString: "Loading…")
    private let displayLabel = NSTextField(labelWithString: "Loading…")
    private let calibrationLabel = NSTextField(labelWithString: "Loading…")
    private let accessibilityLabel = NSTextField(labelWithString: "Loading…")
    private let engineLabel = NSTextField(labelWithString: "Loading…")
    private let enableSwitch = NSSwitch()
    private let grantAXButton = NSButton(title: "Grant Permission…", target: nil, action: nil)
    private let calibrateButton = NSButton(title: "Calibrate…", target: nil, action: nil)
    private let diagnosticsButton = NSButton(title: "Open Diagnostics…", target: nil, action: nil)
    
    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TouchBridge — Status & Settings"
        win.center()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        guard let win = self.window else { return }
        
        let container = NSView(frame: win.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 480, height: 420))
        container.autoresizingMask = [.width, .height]
        win.contentView = container
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])
        
        // Header
        let title = NSTextField(labelWithString: "TouchBridge Runtime Status")
        title.font = NSFont.boldSystemFont(ofSize: 16)
        stack.addArrangedSubview(title)
        
        let desc = NSTextField(labelWithString: "Passive IOHID Touchscreen Bridge with Pointer-Independent Semantic Interaction.")
        desc.font = NSFont.systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        stack.addArrangedSubview(desc)
        
        let sep1 = NSBox()
        sep1.boxType = .separator
        stack.addArrangedSubview(sep1)
        sep1.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        // State Rows
        stack.addArrangedSubview(createCard(title: "Touchscreen Hardware", valueLabel: deviceLabel))
        stack.addArrangedSubview(createCard(title: "Target Display", valueLabel: displayLabel))
        
        let calStack = NSStackView()
        calStack.orientation = .horizontal
        calStack.spacing = 8
        calStack.addArrangedSubview(calibrationLabel)
        calibrateButton.target = self
        calibrateButton.action = #selector(handleCalibrate)
        calibrateButton.bezelStyle = .rounded
        calStack.addArrangedSubview(calibrateButton)
        stack.addArrangedSubview(createCard(title: "Calibration", customView: calStack))
        
        let axStack = NSStackView()
        axStack.orientation = .horizontal
        axStack.spacing = 8
        axStack.addArrangedSubview(accessibilityLabel)
        grantAXButton.target = self
        grantAXButton.action = #selector(handleGrantAX)
        grantAXButton.bezelStyle = .rounded
        axStack.addArrangedSubview(grantAXButton)
        stack.addArrangedSubview(createCard(title: "Accessibility API", customView: axStack))
        
        // Enable switch
        let switchStack = NSStackView()
        switchStack.orientation = .horizontal
        switchStack.spacing = 10
        enableSwitch.target = self
        enableSwitch.action = #selector(handleSwitch)
        switchStack.addArrangedSubview(enableSwitch)
        switchStack.addArrangedSubview(engineLabel)
        stack.addArrangedSubview(createCard(title: "Touch Interaction Engine", customView: switchStack))
        
        let sep2 = NSBox()
        sep2.boxType = .separator
        stack.addArrangedSubview(sep2)
        sep2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        // Safety Invariant Notice
        let invariantBox = NSTextField(labelWithString: "🛡️ Safety Invariants Active: Zero Cursor Warping • Zero Mouse Event Injection • Pointer Isolated")
        invariantBox.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        invariantBox.textColor = .secondaryLabelColor
        stack.addArrangedSubview(invariantBox)
        
        // Bottom actions
        let bottomStack = NSStackView()
        bottomStack.orientation = .horizontal
        bottomStack.distribution = .fill
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(bottomStack)
        bottomStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(handleOpenDiagnostics)
        bottomStack.addArrangedSubview(diagnosticsButton)
        
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomStack.addArrangedSubview(spacer)
        
        let closeButton = NSButton(title: "Close", target: self, action: #selector(handleClose))
        closeButton.keyEquivalent = "\r"
        bottomStack.addArrangedSubview(closeButton)
    }
    
    private func createCard(title: String, valueLabel: NSTextField? = nil, customView: NSView? = nil) -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 3
        
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .secondaryLabelColor
        v.addArrangedSubview(t)
        
        if let vl = valueLabel {
            vl.font = NSFont.systemFont(ofSize: 13)
            v.addArrangedSubview(vl)
        }
        if let cv = customView {
            v.addArrangedSubview(cv)
        }
        return v
    }
    
    public func update(with snapshot: RuntimeSnapshot) {
        deviceLabel.stringValue = snapshot.device.description
        displayLabel.stringValue = snapshot.display.description
        calibrationLabel.stringValue = snapshot.calibration.description
        accessibilityLabel.stringValue = snapshot.accessibility.description
        engineLabel.stringValue = snapshot.engine.description
        
        grantAXButton.isHidden = (snapshot.accessibility == .available)
        enableSwitch.state = snapshot.isUserEnabled ? .on : .off
    }
    
    public func showWindowToFront() {
        update(with: TouchBridgeRuntime.shared.currentSnapshot)
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Actions
    
    @objc private func handleSwitch() {
        TouchBridgeRuntime.shared.setEnabled(enableSwitch.state == .on)
    }
    
    @objc private func handleGrantAX() {
        TouchBridgeRuntime.shared.requestAccessibilityPermissionExplicitly()
    }
    
    @objc private func handleCalibrate() {
        CalibrationWindowController.shared.startCalibrationSession()
    }
    
    @objc private func handleOpenDiagnostics() {
        DiagnosticsWindowController.shared.showWindowToFront()
    }
    
    @objc private func handleClose() {
        self.window?.close()
    }
}
