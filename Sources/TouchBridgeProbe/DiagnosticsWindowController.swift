import Cocoa
import CoreGraphics

// MARK: - Native Diagnostics Surface Window (P3-01 Section 10)

public final class DiagnosticsWindowController: NSWindowController, NSTextViewDelegate {
    public static let shared = DiagnosticsWindowController()
    
    private let tabView = NSTabView()
    
    // Tab 1: Hardware & Displays
    private let hardwareTextView = NSTextView()
    
    // Tab 2: Calibration Verification
    private var verificationContainer = NSView()
    private var activeDiagnosticView: DiagnosticView?
    
    // Tab 3: Semantic AX Tests
    private var semanticContainer = NSView()
    private var activeSemanticView: SemanticTestView?
    
    // Tab 4: Structured Logs
    private let logsTextView = NSTextView()
    private let categoryFilterPopup = NSPopUpButton()
    
    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 840, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TouchBridge — Diagnostics & Inspection"
        win.center()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        
        setupUI()
        setupLogObserver()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        guard let win = self.window else { return }
        
        let content = NSView(frame: win.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 840, height: 600))
        content.autoresizingMask = [.width, .height]
        win.contentView = content
        
        tabView.frame = content.bounds.insetBy(dx: 12, dy: 12)
        tabView.autoresizingMask = [.width, .height]
        content.addSubview(tabView)
        
        // Tab 1: Hardware & Displays
        let tab1 = NSTabViewItem(identifier: "hardware")
        tab1.label = "Hardware & Displays"
        tab1.view = setupHardwareTab()
        tabView.addTabViewItem(tab1)
        
        // Tab 2: Live Touch & Calibration
        let tab2 = NSTabViewItem(identifier: "verification")
        tab2.label = "Touch & Calibration"
        tab2.view = setupVerificationTab()
        tabView.addTabViewItem(tab2)
        
        // Tab 3: Semantic AX Tests
        let tab3 = NSTabViewItem(identifier: "semantic")
        tab3.label = "Semantic AX Tests"
        tab3.view = setupSemanticTab()
        tabView.addTabViewItem(tab3)
        
        // Tab 4: Logs
        let tab4 = NSTabViewItem(identifier: "logs")
        tab4.label = "Structured Logs"
        tab4.view = setupLogsTab()
        tabView.addTabViewItem(tab4)
    }
    
    // MARK: - Tab 1: Hardware
    
    private func setupHardwareTab() -> NSView {
        let container = NSView()
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        
        hardwareTextView.isEditable = false
        hardwareTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = hardwareTextView
        container.addSubview(scroll)
        
        let refreshBtn = NSButton(title: "Refresh Hardware State", target: self, action: #selector(refreshHardwareInfo))
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        refreshBtn.bezelStyle = .rounded
        container.addSubview(refreshBtn)
        
        NSLayoutConstraint.activate([
            refreshBtn.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            refreshBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            
            scroll.topAnchor.constraint(equalTo: refreshBtn.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        refreshHardwareInfo()
        return container
    }
    
    @objc public func refreshHardwareInfo() {
        let runtime = TouchBridgeRuntime.shared
        let displays = runtime.displayManager.enumerateDisplays()
        
        var text = "================================================================================\n"
        text += "                    TouchBridge Hardware & Display Inspection\n"
        text += "================================================================================\n\n"
        
        text += "[1] Connected Displays (\(displays.count)):\n"
        for d in displays {
            text += d.description + "\n\n"
        }
        
        text += "[2] Bound Target Display:\n"
        if let bound = runtime.displayState.boundDisplay {
            text += "  - Name: \"\(bound.name)\" (ID: \(bound.id))\n"
            text += "  - Bounds: [\(bound.cgOriginX), \(bound.cgOriginY), \(bound.cgWidth), \(bound.cgHeight)] pt\n"
            text += "  - Scale: \(bound.backingScaleFactor)x | Rotation: \(bound.rotationDegrees)°\n\n"
        } else {
            text += "  - None bound (Target Missing)\n\n"
        }
        
        text += "[3] Touchscreen Device Controller:\n"
        text += "  - State: \(runtime.deviceState.description)\n"
        text += "  - Hardware VID: 0x\(String(format: "%04X", TouchscreenDevice.targetVendorID)), PID: 0x\(String(format: "%04X", TouchscreenDevice.targetProductID))\n"
        text += "  - Coordinate Ranges: X[\(runtime.device.logMinX)..\(runtime.device.logMaxX)], Y[\(runtime.device.logMinY)..\(runtime.device.logMaxY)]\n\n"
        
        text += "[4] Calibration Profile:\n"
        if let prof = runtime.calibrationState.activeProfile {
            text += "  - Status: VALID\n"
            text += "  - Mean Residual Error: \(String(format: "%.2f", prof.meanResidualError)) pt, Max: \(String(format: "%.2f", prof.maxResidualError)) pt\n"
            text += "  - Created: \(prof.createdAt)\n"
            text += "  - Affine Matrix:\n\(prof.affineMatrix?.description ?? "None")\n\n"
        } else {
            text += "  - Status: \(runtime.calibrationState.description)\n\n"
        }
        
        text += "[5] Accessibility Trust:\n"
        text += "  - Status: \(runtime.accessibilityState.description)\n"
        text += "  - Process Trusted: \(runtime.permissionManager.isTrusted() ? "YES" : "NO")\n\n"
        
        text += "================================================================================\n"
        hardwareTextView.string = text
    }
    
    // MARK: - Tab 2: Verification
    
    private func setupVerificationTab() -> NSView {
        verificationContainer = NSView()
        verificationContainer.autoresizingMask = [.width, .height]
        reloadVerificationView()
        return verificationContainer
    }
    
    public func reloadVerificationView() {
        activeDiagnosticView?.removeFromSuperview()
        activeDiagnosticView = nil
        
        guard let disp = TouchBridgeRuntime.shared.displayState.boundDisplay,
              let prof = TouchBridgeRuntime.shared.calibrationState.activeProfile else {
            let note = NSTextField(labelWithString: "Connect external touchscreen and calibrate to activate live touch verification.")
            note.frame = NSRect(x: 20, y: 200, width: 500, height: 30)
            verificationContainer.subviews.forEach { $0.removeFromSuperview() }
            verificationContainer.addSubview(note)
            return
        }
        
        let diag = DiagnosticView(frame: verificationContainer.bounds, display: disp, profile: prof)
        diag.autoresizingMask = [.width, .height]
        verificationContainer.subviews.forEach { $0.removeFromSuperview() }
        verificationContainer.addSubview(diag)
        activeDiagnosticView = diag
    }
    
    // MARK: - Tab 3: Semantic AX Tests
    
    private func setupSemanticTab() -> NSView {
        semanticContainer = NSView()
        semanticContainer.autoresizingMask = [.width, .height]
        reloadSemanticView()
        return semanticContainer
    }
    
    public func reloadSemanticView() {
        activeSemanticView?.removeFromSuperview()
        activeSemanticView = nil
        
        guard let disp = TouchBridgeRuntime.shared.displayState.boundDisplay,
              let prof = TouchBridgeRuntime.shared.calibrationState.activeProfile else {
            let note = NSTextField(labelWithString: "Semantic AX Tests require a bound display and valid calibration.")
            note.frame = NSRect(x: 20, y: 200, width: 500, height: 30)
            semanticContainer.subviews.forEach { $0.removeFromSuperview() }
            semanticContainer.addSubview(note)
            return
        }
        
        let semView = SemanticTestView(frame: semanticContainer.bounds, display: disp, profile: prof)
        semView.autoresizingMask = [.width, .height]
        semanticContainer.subviews.forEach { $0.removeFromSuperview() }
        semanticContainer.addSubview(semView)
        activeSemanticView = semView
    }
    
    // MARK: - Tab 4: Logs
    
    private func setupLogsTab() -> NSView {
        let container = NSView()
        
        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.spacing = 10
        topBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topBar)
        
        let filterLabel = NSTextField(labelWithString: "Filter Category:")
        topBar.addArrangedSubview(filterLabel)
        
        categoryFilterPopup.addItem(withTitle: "All Categories")
        for cat in LogCategory.allCases {
            categoryFilterPopup.addItem(withTitle: cat.rawValue)
        }
        categoryFilterPopup.target = self
        categoryFilterPopup.action = #selector(handleCategoryFilterChanged)
        topBar.addArrangedSubview(categoryFilterPopup)
        
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topBar.addArrangedSubview(spacer)
        
        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(handleClearLogs))
        clearBtn.bezelStyle = .rounded
        topBar.addArrangedSubview(clearBtn)
        
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        
        logsTextView.isEditable = false
        logsTextView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        scroll.documentView = logsTextView
        container.addSubview(scroll)
        
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        refreshLogs()
        return container
    }
    
    private func setupLogObserver() {
        TouchBridgeLogger.shared.onNewEntry = { [weak self] _ in
            self?.refreshLogs()
        }
    }
    
    private func refreshLogs() {
        let selectedTitle = categoryFilterPopup.titleOfSelectedItem
        let category: LogCategory? = (selectedTitle != nil && selectedTitle != "All Categories") ? LogCategory(rawValue: selectedTitle!) : nil
        let entries = TouchBridgeLogger.shared.recentEntries(category: category, limit: 300)
        let fullText = entries.map { $0.formattedLine }.joined(separator: "\n")
        logsTextView.string = fullText
        logsTextView.scrollToEndOfDocument(nil)
    }
    
    @objc private func handleCategoryFilterChanged() {
        refreshLogs()
    }
    
    @objc private func handleClearLogs() {
        TouchBridgeLogger.shared.clear()
        refreshLogs()
    }
    
    public func showWindowToFront() {
        refreshHardwareInfo()
        reloadVerificationView()
        reloadSemanticView()
        refreshLogs()
        
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func forwardTouchSample(_ sample: TouchSample) {
        activeDiagnosticView?.handleTouchSample(sample)
    }
}
