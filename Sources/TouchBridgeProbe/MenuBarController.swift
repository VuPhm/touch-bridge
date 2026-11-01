import Cocoa

// MARK: - Native Menu-Bar Surface (P3-01 Section 7 & Production Polish)

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
    
    // Header & Status
    private let headerItem = NSMenuItem(title: "TouchBridge", action: nil, keyEquivalent: "")
    private let statusSummaryItem = NSMenuItem(title: "Trạng thái: Đang kiểm tra…", action: nil, keyEquivalent: "")
    private let displaySummaryItem = NSMenuItem(title: "Màn hình: Đang kiểm tra…", action: nil, keyEquivalent: "")
    
    // Quick Actions
    private let toggleTouchItem = NSMenuItem(title: "Bật cảm ứng", action: #selector(toggleEnableAction), keyEquivalent: "e")
    private let calibrateItem = NSMenuItem(title: "Hiệu chuẩn màn hình…", action: #selector(calibrateAction), keyEquivalent: "c")
    private let settingsItem = NSMenuItem(title: "Cài đặt…", action: #selector(settingsAction), keyEquivalent: ",")
    private let exportReportItem = NSMenuItem(title: "Xuất báo cáo chẩn đoán ra Desktop…", action: #selector(exportReportAction), keyEquivalent: "")
    private let grantAXItem = NSMenuItem(title: "Cấp quyền Trợ năng (Accessibility)…", action: #selector(grantAXAction), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Thoát TouchBridge", action: #selector(quitAction), keyEquivalent: "q")
    
    public override init() {
        super.init()
        setupStatusItem()
        buildMenu()
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = createStatusBarIcon(isOperational: false)
            button.imagePosition = .imageOnly
            button.toolTip = "TouchBridge"
        }
        item.menu = menu
        self.statusItem = item
    }
    
    private func buildMenu() {
        menu.removeAllItems()
        
        // App Header
        let versionStr = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        headerItem.attributedTitle = NSAttributedString(
            string: "TouchBridge (\(versionStr))",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())
        
        // Concise Status
        statusSummaryItem.isEnabled = false
        menu.addItem(statusSummaryItem)
        displaySummaryItem.isEnabled = false
        menu.addItem(displaySummaryItem)
        
        // Quick Grant Permission if missing
        grantAXItem.target = self
        grantAXItem.isHidden = true
        menu.addItem(grantAXItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Primary Actions
        toggleTouchItem.target = self
        menu.addItem(toggleTouchItem)
        
        calibrateItem.target = self
        menu.addItem(calibrateItem)
        
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        exportReportItem.target = self
        menu.addItem(exportReportItem)
        
        menu.addItem(NSMenuItem.separator())
        
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    public func update(with snapshot: RuntimeSnapshot) {
        // Status Summary (clean monochrome, no emojis)
        if snapshot.accessibility != .available {
            statusSummaryItem.title = "Trợ năng: Chưa cấp quyền"
            grantAXItem.isHidden = false
        } else if !snapshot.isUserEnabled {
            statusSummaryItem.title = "Cảm ứng: Đang tắt"
            grantAXItem.isHidden = true
        } else if snapshot.device == .disconnected {
            statusSummaryItem.title = "Thiết bị: Chưa cắm màn cảm ứng"
            grantAXItem.isHidden = true
        } else if snapshot.calibration == .missing {
            statusSummaryItem.title = "Hiệu chuẩn: Cần hiệu chuẩn"
            grantAXItem.isHidden = true
        } else {
            statusSummaryItem.title = "Cảm ứng: Sẵn sàng hoạt động"
            grantAXItem.isHidden = true
        }
        
        // Display Summary
        if let disp = snapshot.display.boundDisplay {
            let rotStr = disp.rotationDegrees > 0 ? " @ \(Int(disp.rotationDegrees))°" : ""
            displaySummaryItem.title = "Màn hình: \(disp.name) (\(Int(disp.cgWidth))×\(Int(disp.cgHeight))\(rotStr))"
            displaySummaryItem.isHidden = false
        } else {
            displaySummaryItem.title = "Màn hình: Chưa kết nối màn ngoài"
        }
        
        // Toggle item text & state
        toggleTouchItem.title = snapshot.isUserEnabled ? "Tắt cảm ứng" : "Bật cảm ứng"
        toggleTouchItem.state = snapshot.isUserEnabled ? .on : .off
        
        // Update status bar icon
        if let button = statusItem?.button {
            button.image = createStatusBarIcon(isOperational: snapshot.engine.isOperational && snapshot.isUserEnabled)
            let statusText = snapshot.isUserEnabled ? (snapshot.engine.isOperational ? "Đang hoạt động" : "Tạm dừng") : "Đang tắt"
            button.toolTip = "TouchBridge: \(statusText)"
        }
    }
    
    private func createStatusBarIcon(isOperational: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        
        let bounds = NSRect(origin: .zero, size: size)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        
        // Outer display bezel
        let screenRect = bounds.insetBy(dx: 2.0, dy: 3.0)
        let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 2.5, yRadius: 2.5)
        screenPath.lineWidth = 1.4
        
        // Stroke color: system black for template (inverts on dark mode), dimmed gray when disabled
        let strokeColor = isOperational ? NSColor.black : NSColor(white: 0.5, alpha: 0.6)
        strokeColor.setStroke()
        screenPath.stroke()
        
        // Center touch point / contact dot
        let dotRect = NSRect(x: center.x - 2.0, y: center.y - 2.0, width: 4.0, height: 4.0)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        strokeColor.setFill()
        dotPath.fill()
        
        img.unlockFocus()
        // Template mode adapts automatically to system Light/Dark mode.
        // Disabled mode uses non-template dimmed gray so it remains muted across modes.
        img.isTemplate = isOperational
        return img
    }
    
    // MARK: - Actions
    
    @objc private func toggleEnableAction() {
        actionDelegate?.menuBarDidToggleEnabled()
    }
    
    @objc private func calibrateAction() {
        actionDelegate?.menuBarDidRequestCalibration()
    }
    
    @objc private func settingsAction() {
        actionDelegate?.menuBarDidRequestSettings()
    }
    
    @objc private func exportReportAction() {
        TouchBridgeLogger.exportDiagnosticReportToDesktop()
    }
    
    @objc private func grantAXAction() {
        actionDelegate?.menuBarDidRequestAccessibilityPermission()
    }
    
    @objc private func quitAction() {
        actionDelegate?.menuBarDidRequestQuit()
    }
}
