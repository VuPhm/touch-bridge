import Cocoa

// MARK: - Native Settings & Status Window (TouchBridge v1.0.0)

public final class StatusSettingsWindowController: NSWindowController {
    public static let shared = StatusSettingsWindowController()
    
    // Header & Tab Navigation
    private let tabSegmentedControl = NSSegmentedControl()
    private let tabView = NSTabView()
    
    // Overview Controls
    private let statusBannerIcon = NSTextField(labelWithString: "🟢")
    private let statusBannerTitle = NSTextField(labelWithString: "Sẵn sàng hoạt động")
    private let statusBannerSubtitle = NSTextField(labelWithString: "Màn hình cảm ứng đang được kết nối và xử lý độc quyền.")
    private let bannerActionButton = NSButton(title: "Hành động", target: nil, action: nil)
    
    private let overviewDeviceLabel = NSTextField(labelWithString: "USB2IIC_CTP_CONTROL (0x1A86:0xE5E3)")
    private let overviewDisplayLabel = NSTextField(labelWithString: "TYPE C (960×1280 @ 270°)")
    private let overviewCalibrationLabel = NSTextField(labelWithString: "Hợp lệ (Sai số dư: 5.2 pt)")
    private let overviewAXLabel = NSTextField(labelWithString: "Đã cấp quyền (AXTrusted)")
    
    private let enableTouchSwitch = NSSwitch()
    private let launchAtLoginSwitch = NSSwitch()
    
    // Touch Interaction Controls
    private let directTouchSwitch = NSSwitch()
    
    // Display & Calibration Controls
    private let displayDetailNameLabel = NSTextField(labelWithString: "TYPE C")
    private let displayDetailResLabel = NSTextField(labelWithString: "960 × 1280 (HiDPI @ 2.0x)")
    private let displayDetailRotLabel = NSTextField(labelWithString: "270° (Thẳng đứng)")
    private let invertRotationSwitch = NSSwitch()
    private let calibrationStatusLabel = NSTextField(labelWithString: "Đã hiệu chuẩn (Sai số dư: 5.21 pt)")
    private let calibrateButton = NSButton(title: "Hiệu chuẩn màn hình 4 điểm…", target: nil, action: nil)
    
    // Diagnostics & About Controls
    private let diagHardwareInfoLabel = NSTextField(labelWithString: "MacBook Pro 2019 (16-inch, Intel x86_64) • macOS 14.8.9")
    private let diagEngineStatusLabel = NSTextField(labelWithString: "IOHID Seized: True • CGEvent Continuous 2D")
    private let exportReportButton = NSButton(title: "Xuất báo cáo chẩn đoán ra Desktop…", target: nil, action: nil)
    private let openDiagnosticsWindowButton = NSButton(title: "Mở bảng chẩn đoán trực tiếp…", target: nil, action: nil)
    private let openLogFinderButton = NSButton(title: "Mở file nhật ký (/tmp) trong Finder…", target: nil, action: nil)
    private let openKeyboardViewerButton = NSButton(title: "Mở bàn phím ảo macOS (Accessibility Keyboard)…", target: nil, action: nil)
    
    private let aboutVersionLabel = NSTextField(labelWithString: "TouchBridge Phiên bản 1.0.0")
    private let aboutRepoButton = NSButton(title: "Xem mã nguồn trên GitHub (VuPhm/touch-bridge)", target: nil, action: nil)
    
    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 560, height: 530),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TouchBridge — Cài Đặt"
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
        
        let rootContainer = NSView(frame: win.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 560, height: 530))
        rootContainer.autoresizingMask = [.width, .height]
        win.contentView = rootContainer
        
        // 1. Top Segmented Control (Tabs)
        tabSegmentedControl.segmentCount = 4
        tabSegmentedControl.setLabel("Tổng quan", forSegment: 0)
        tabSegmentedControl.setLabel("Cảm ứng", forSegment: 1)
        tabSegmentedControl.setLabel("Màn hình", forSegment: 2)
        tabSegmentedControl.setLabel("Chẩn đoán & Giới thiệu", forSegment: 3)
        tabSegmentedControl.selectedSegment = 0
        tabSegmentedControl.target = self
        tabSegmentedControl.action = #selector(handleTabChanged)
        tabSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(tabSegmentedControl)
        
        // 2. Tab View
        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(tabView)
        
        // 3. Bottom Close Button
        let closeButton = NSButton(title: "Đóng", target: self, action: #selector(handleClose))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            tabSegmentedControl.topAnchor.constraint(equalTo: rootContainer.topAnchor, constant: 16),
            tabSegmentedControl.centerXAnchor.constraint(equalTo: rootContainer.centerXAnchor),
            tabSegmentedControl.heightAnchor.constraint(equalToConstant: 28),
            
            tabView.topAnchor.constraint(equalTo: tabSegmentedControl.bottomAnchor, constant: 14),
            tabView.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor, constant: -20),
            tabView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),
            
            closeButton.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor, constant: -14),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        ])
        
        // Build the 4 tabs
        buildOverviewTab()
        buildTouchTab()
        buildDisplayTab()
        buildDiagnosticsTab()
    }
    
    // MARK: - Tab 1: Tổng quan (Overview)
    
    private func buildOverviewTab() {
        let tabItem = NSTabViewItem(identifier: "overview")
        let view = NSView()
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
        
        // Banner Card
        let bannerBox = NSBox()
        bannerBox.boxType = .custom
        bannerBox.cornerRadius = 8
        bannerBox.fillColor = NSColor.controlBackgroundColor
        bannerBox.borderColor = NSColor.separatorColor
        bannerBox.borderWidth = 1.0
        bannerBox.translatesAutoresizingMaskIntoConstraints = false
        
        let bannerStack = NSStackView()
        bannerStack.orientation = .horizontal
        bannerStack.alignment = .centerY
        bannerStack.spacing = 12
        bannerStack.translatesAutoresizingMaskIntoConstraints = false
        bannerBox.addSubview(bannerStack)
        
        statusBannerIcon.font = NSFont.systemFont(ofSize: 28)
        bannerStack.addArrangedSubview(statusBannerIcon)
        
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        
        statusBannerTitle.font = NSFont.boldSystemFont(ofSize: 15)
        textStack.addArrangedSubview(statusBannerTitle)
        
        statusBannerSubtitle.font = NSFont.systemFont(ofSize: 12)
        statusBannerSubtitle.textColor = .secondaryLabelColor
        textStack.addArrangedSubview(statusBannerSubtitle)
        bannerStack.addArrangedSubview(textStack)
        
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bannerStack.addArrangedSubview(spacer)
        
        bannerActionButton.target = self
        bannerActionButton.action = #selector(handleBannerAction)
        bannerActionButton.bezelStyle = .rounded
        bannerActionButton.isHidden = true
        bannerStack.addArrangedSubview(bannerActionButton)
        
        NSLayoutConstraint.activate([
            bannerStack.topAnchor.constraint(equalTo: bannerBox.topAnchor, constant: 12),
            bannerStack.leadingAnchor.constraint(equalTo: bannerBox.leadingAnchor, constant: 14),
            bannerStack.trailingAnchor.constraint(equalTo: bannerBox.trailingAnchor, constant: -14),
            bannerStack.bottomAnchor.constraint(equalTo: bannerBox.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(bannerBox)
        bannerBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        // Hardware & State Details Box
        let detailsBox = createSectionBox(title: "Kết Nối & Quyền Hệ Thống")
        let detailStack = NSStackView()
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailsBox.addSubview(detailStack)
        
        detailStack.addArrangedSubview(createFieldRow(title: "Màn hình ngoài:", valueLabel: overviewDisplayLabel))
        detailStack.addArrangedSubview(createFieldRow(title: "Bộ điều khiển:", valueLabel: overviewDeviceLabel))
        detailStack.addArrangedSubview(createFieldRow(title: "Hiệu chuẩn:", valueLabel: overviewCalibrationLabel))
        detailStack.addArrangedSubview(createFieldRow(title: "Quyền Trợ năng:", valueLabel: overviewAXLabel))
        
        NSLayoutConstraint.activate([
            detailStack.topAnchor.constraint(equalTo: detailsBox.topAnchor, constant: 12),
            detailStack.leadingAnchor.constraint(equalTo: detailsBox.leadingAnchor, constant: 14),
            detailStack.trailingAnchor.constraint(equalTo: detailsBox.trailingAnchor, constant: -14),
            detailStack.bottomAnchor.constraint(equalTo: detailsBox.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(detailsBox)
        detailsBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        // System Switches Box
        let switchesBox = createSectionBox(title: "Điều Khiển Nhanh")
        let switchStack = NSStackView()
        switchStack.orientation = .vertical
        switchStack.alignment = .leading
        switchStack.spacing = 10
        switchStack.translatesAutoresizingMaskIntoConstraints = false
        switchesBox.addSubview(switchStack)
        
        enableTouchSwitch.target = self
        enableTouchSwitch.action = #selector(handleEnableTouchSwitch)
        switchStack.addArrangedSubview(createSwitchRow(
            control: enableTouchSwitch,
            title: "Bật xử lý cảm ứng",
            subtitle: "Nhận và điều khiển màn hình cảm ứng ngoài."
        ))
        
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(handleLaunchAtLoginSwitch)
        switchStack.addArrangedSubview(createSwitchRow(
            control: launchAtLoginSwitch,
            title: "Khởi động cùng máy tính (Launch at Login)",
            subtitle: "Tự động chạy TouchBridge ở menu bar khi đăng nhập."
        ))
        
        NSLayoutConstraint.activate([
            switchStack.topAnchor.constraint(equalTo: switchesBox.topAnchor, constant: 12),
            switchStack.leadingAnchor.constraint(equalTo: switchesBox.leadingAnchor, constant: 14),
            switchStack.trailingAnchor.constraint(equalTo: switchesBox.trailingAnchor, constant: -14),
            switchStack.bottomAnchor.constraint(equalTo: switchesBox.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(switchesBox)
        switchesBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        tabItem.view = view
        tabView.addTabViewItem(tabItem)
    }
    
    // MARK: - Tab 2: Cảm ứng (Touch)
    
    private func buildTouchTab() {
        let tabItem = NSTabViewItem(identifier: "touch")
        let view = NSView()
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
        
        let mainBox = createSectionBox(title: "Chế Độ Cảm Ứng Trực Tiếp (Direct-Touch)")
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainBox.addSubview(mainStack)
        
        directTouchSwitch.target = self
        directTouchSwitch.action = #selector(handleDirectTouchSwitch)
        mainStack.addArrangedSubview(createSwitchRow(
            control: directTouchSwitch,
            title: "Cuộn 1 ngón & Kéo thả thông minh",
            subtitle: "Cho phép dùng 1 ngón vuốt cuộn trang tự nhiên và kéo thả trực tiếp."
        ))
        
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        
        // Behavioral Guide
        let guideHeader = NSTextField(labelWithString: "Quy Tắc Thao Tác Cảm Ứng:")
        guideHeader.font = NSFont.boldSystemFont(ofSize: 12)
        mainStack.addArrangedSubview(guideHeader)
        
        let guide1 = createBulletLabel(title: "Chạm nhanh:", desc: "Bấm chuột trái chính xác tại vị trí chạm (Tap & Double Tap).")
        let guide2 = createBulletLabel(title: "Vuốt 1 ngón:", desc: "Nội dung cuộn 1:1 theo tay với quán tính tự nhiên ngắn.")
        let guide3 = createBulletLabel(title: "Chạm dừng phanh:", desc: "Chạm vào khi trang đang trượt sẽ dừng ngay lập tức; nhấc tay không bị click nhầm.")
        let guide4 = createBulletLabel(title: "Kéo thả trực tiếp:", desc: "Kéo ăn ngay trên thanh tiêu đề, núm cuộn và mép đổi kích thước cửa sổ.")
        let guide5 = createBulletLabel(title: "Kéo file / Chọn chữ:", desc: "Giữ yên khoảng 0.24s rồi kéo để bôi đen văn bản hoặc di chuyển file.")
        let guide6 = createBulletLabel(title: "Chuột phải:", desc: "Giữ yên ngón tay trong 0.48s tại một điểm để mở Menu ngữ cảnh.")
        let guide7 = createBulletLabel(title: "Cử chỉ 2 ngón:", desc: "Cuộn 2 ngón tay, chụm/mở để thu phóng (Pinch-to-zoom) và xoay native.")
        
        for g in [guide1, guide2, guide3, guide4, guide5, guide6, guide7] {
            mainStack.addArrangedSubview(g)
        }
        
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: mainBox.topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: mainBox.leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: mainBox.trailingAnchor, constant: -14),
            mainStack.bottomAnchor.constraint(equalTo: mainBox.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(mainBox)
        mainBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        tabItem.view = view
        tabView.addTabViewItem(tabItem)
    }
    
    // MARK: - Tab 3: Màn hình & Hiệu chuẩn (Display & Calibration)
    
    private func buildDisplayTab() {
        let tabItem = NSTabViewItem(identifier: "display")
        let view = NSView()
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
        
        // Display Details Box
        let dispBox = createSectionBox(title: "Màn Hình Cảm Ứng Đang Liên Kết")
        let dispStack = NSStackView()
        dispStack.orientation = .vertical
        dispStack.alignment = .leading
        dispStack.spacing = 8
        dispStack.translatesAutoresizingMaskIntoConstraints = false
        dispBox.addSubview(dispStack)
        
        dispStack.addArrangedSubview(createFieldRow(title: "Tên màn hình:", valueLabel: displayDetailNameLabel))
        dispStack.addArrangedSubview(createFieldRow(title: "Độ phân giải:", valueLabel: displayDetailResLabel))
        dispStack.addArrangedSubview(createFieldRow(title: "Hướng xoay hiện tại:", valueLabel: displayDetailRotLabel))
        
        invertRotationSwitch.target = self
        invertRotationSwitch.action = #selector(handleInvertRotationSwitch)
        dispStack.addArrangedSubview(createSwitchRow(
            control: invertRotationSwitch,
            title: "Đảo chiều trục tọa độ 90°/270°",
            subtitle: "Bật tùy chọn này nếu thao tác vuốt bị ngược hướng khi xoay màn hình thẳng đứng."
        ))
        
        NSLayoutConstraint.activate([
            dispStack.topAnchor.constraint(equalTo: dispBox.topAnchor, constant: 12),
            dispStack.leadingAnchor.constraint(equalTo: dispBox.leadingAnchor, constant: 14),
            dispStack.trailingAnchor.constraint(equalTo: dispBox.trailingAnchor, constant: -14),
            dispStack.bottomAnchor.constraint(equalTo: dispBox.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(dispBox)
        dispBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        // Calibration Box
        let calBox = createSectionBox(title: "Độ Chính Xác & Hiệu Chuẩn Tọa Độ")
        let calStack = NSStackView()
        calStack.orientation = .vertical
        calStack.alignment = .leading
        calStack.spacing = 10
        calStack.translatesAutoresizingMaskIntoConstraints = false
        calBox.addSubview(calStack)
        
        calStack.addArrangedSubview(createFieldRow(title: "Trạng thái:", valueLabel: calibrationStatusLabel))
        
        let calDesc = NSTextField(labelWithString: "Quy trình hiệu chuẩn bao gồm 4 điểm góc để khớp ma trận tọa độ và 2 điểm kiểm chứng độc lập (tâm và viền) để đảm bảo độ chính xác trên toàn màn hình.")
        calDesc.font = NSFont.systemFont(ofSize: 11)
        calDesc.textColor = .secondaryLabelColor
        calStack.addArrangedSubview(calDesc)
        
        calibrateButton.target = self
        calibrateButton.action = #selector(handleCalibrate)
        calibrateButton.bezelStyle = .rounded
        calStack.addArrangedSubview(calibrateButton)
        
        NSLayoutConstraint.activate([
            calStack.topAnchor.constraint(equalTo: calBox.topAnchor, constant: 12),
            calStack.leadingAnchor.constraint(equalTo: calBox.leadingAnchor, constant: 14),
            calStack.trailingAnchor.constraint(equalTo: calBox.trailingAnchor, constant: -14),
            calStack.bottomAnchor.constraint(equalTo: calBox.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(calBox)
        calBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        tabItem.view = view
        tabView.addTabViewItem(tabItem)
    }
    
    // MARK: - Tab 4: Chẩn đoán & Giới thiệu (Diagnostics & About)
    
    private func buildDiagnosticsTab() {
        let tabItem = NSTabViewItem(identifier: "diagnostics")
        let view = NSView()
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
        
        // Diagnostics Actions Box
        let diagBox = createSectionBox(title: "Công Cụ Chẩn Đoán & Báo Cáo")
        let diagStack = NSStackView()
        diagStack.orientation = .vertical
        diagStack.alignment = .leading
        diagStack.spacing = 8
        diagStack.translatesAutoresizingMaskIntoConstraints = false
        diagBox.addSubview(diagStack)
        
        diagStack.addArrangedSubview(createFieldRow(title: "Phần cứng kiểm chứng:", valueLabel: diagHardwareInfoLabel))
        diagStack.addArrangedSubview(createFieldRow(title: "Trạng thái Engine:", valueLabel: diagEngineStatusLabel))
        
        exportReportButton.target = self
        exportReportButton.action = #selector(handleExportReport)
        exportReportButton.bezelStyle = .rounded
        diagStack.addArrangedSubview(exportReportButton)
        
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        
        openDiagnosticsWindowButton.target = self
        openDiagnosticsWindowButton.action = #selector(handleOpenDiagnostics)
        openDiagnosticsWindowButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(openDiagnosticsWindowButton)
        
        openLogFinderButton.target = self
        openLogFinderButton.action = #selector(handleRevealLog)
        openLogFinderButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(openLogFinderButton)
        diagStack.addArrangedSubview(buttonRow)
        
        openKeyboardViewerButton.target = self
        openKeyboardViewerButton.action = #selector(handleToggleKeyboard)
        openKeyboardViewerButton.bezelStyle = .rounded
        diagStack.addArrangedSubview(openKeyboardViewerButton)
        
        NSLayoutConstraint.activate([
            diagStack.topAnchor.constraint(equalTo: diagBox.topAnchor, constant: 12),
            diagStack.leadingAnchor.constraint(equalTo: diagBox.leadingAnchor, constant: 14),
            diagStack.trailingAnchor.constraint(equalTo: diagBox.trailingAnchor, constant: -14),
            diagStack.bottomAnchor.constraint(equalTo: diagBox.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(diagBox)
        diagBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        // About App Box
        let aboutBox = createSectionBox(title: "Giới Thiệu TouchBridge")
        let aboutStack = NSStackView()
        aboutStack.orientation = .vertical
        aboutStack.alignment = .leading
        aboutStack.spacing = 8
        aboutStack.translatesAutoresizingMaskIntoConstraints = false
        aboutBox.addSubview(aboutStack)
        
        aboutVersionLabel.font = NSFont.boldSystemFont(ofSize: 13)
        aboutStack.addArrangedSubview(aboutVersionLabel)
        
        let aboutDesc = NSTextField(labelWithString: "Tiện ích cầu nối cảm ứng trực tiếp (Direct-Touch Bridge) tối ưu hóa cho MacBook Pro 2019 Intel và màn hình cảm ứng ngoài USB-C.")
        aboutDesc.font = NSFont.systemFont(ofSize: 11)
        aboutDesc.textColor = .secondaryLabelColor
        aboutStack.addArrangedSubview(aboutDesc)
        
        aboutRepoButton.target = self
        aboutRepoButton.action = #selector(handleOpenRepo)
        aboutRepoButton.bezelStyle = .rounded
        aboutStack.addArrangedSubview(aboutRepoButton)
        
        NSLayoutConstraint.activate([
            aboutStack.topAnchor.constraint(equalTo: aboutBox.topAnchor, constant: 12),
            aboutStack.leadingAnchor.constraint(equalTo: aboutBox.leadingAnchor, constant: 14),
            aboutStack.trailingAnchor.constraint(equalTo: aboutBox.trailingAnchor, constant: -14),
            aboutStack.bottomAnchor.constraint(equalTo: aboutBox.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(aboutBox)
        aboutBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        
        tabItem.view = view
        tabView.addTabViewItem(tabItem)
    }
    
    // MARK: - Helper UI Builders
    
    private func createSectionBox(title: String) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.title = title
        box.cornerRadius = 8
        box.fillColor = NSColor.controlBackgroundColor
        box.borderColor = NSColor.separatorColor
        box.borderWidth = 1.0
        return box
    }
    
    private func createFieldRow(title: String, valueLabel: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        t.textColor = .secondaryLabelColor
        t.widthAnchor.constraint(equalToConstant: 140).isActive = true
        row.addArrangedSubview(t)
        
        valueLabel.font = NSFont.systemFont(ofSize: 12)
        row.addArrangedSubview(valueLabel)
        return row
    }
    
    private func createSwitchRow(control: NSSwitch, title: String, subtitle: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        
        row.addArrangedSubview(control)
        
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        textStack.addArrangedSubview(t)
        
        let s = NSTextField(labelWithString: subtitle)
        s.font = NSFont.systemFont(ofSize: 10)
        s.textColor = .secondaryLabelColor
        textStack.addArrangedSubview(s)
        
        row.addArrangedSubview(textStack)
        return row
    }
    
    private func createBulletLabel(title: String, desc: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        
        let dot = NSTextField(labelWithString: "•")
        dot.font = NSFont.boldSystemFont(ofSize: 12)
        dot.textColor = .controlAccentColor
        row.addArrangedSubview(dot)
        
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.boldSystemFont(ofSize: 11)
        row.addArrangedSubview(t)
        
        let d = NSTextField(labelWithString: desc)
        d.font = NSFont.systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        row.addArrangedSubview(d)
        return row
    }
    
    // MARK: - State Updates
    
    public func update(with snapshot: RuntimeSnapshot) {
        // Banner Status
        if snapshot.accessibility != .available {
            statusBannerIcon.stringValue = "🔴"
            statusBannerTitle.stringValue = "Cần Cấp Quyền Trợ Năng (Accessibility)"
            statusBannerSubtitle.stringValue = "macOS yêu cầu cấp quyền Accessibility để TouchBridge điều khiển sự kiện."
            bannerActionButton.title = "Mở Cài Đặt Quyền…"
            bannerActionButton.action = #selector(handleGrantAX)
            bannerActionButton.isHidden = false
        } else if !snapshot.isUserEnabled {
            statusBannerIcon.stringValue = "⚪️"
            statusBannerTitle.stringValue = "Cảm Ứng Đang Tắt"
            statusBannerSubtitle.stringValue = "Bật công tắc bên dưới để bắt đầu sử dụng cảm ứng."
            bannerActionButton.title = "Bật Cảm Ứng"
            bannerActionButton.action = #selector(handleEnableTouchAction)
            bannerActionButton.isHidden = false
        } else if snapshot.device == .disconnected {
            statusBannerIcon.stringValue = "🟡"
            statusBannerTitle.stringValue = "Chưa Kết Nối Màn Hình Cảm Ứng"
            statusBannerSubtitle.stringValue = "Vui lòng cắm cáp USB của màn hình cảm ứng vào MacBook."
            bannerActionButton.isHidden = true
        } else if snapshot.calibration == .missing {
            statusBannerIcon.stringValue = "🟡"
            statusBannerTitle.stringValue = "Cần Hiệu Chuẩn Tọa Độ Màn Hình"
            statusBannerSubtitle.stringValue = "Nhấp vào nút bên dưới để căn chỉnh độ chính xác của cảm ứng."
            bannerActionButton.title = "Hiệu Chuẩn Ngay…"
            bannerActionButton.action = #selector(handleCalibrate)
            bannerActionButton.isHidden = false
        } else {
            statusBannerIcon.stringValue = "🟢"
            statusBannerTitle.stringValue = "Cảm Ứng Đang Sẵn Sàng"
            statusBannerSubtitle.stringValue = "Màn hình cảm ứng đang hoạt động bình thường và phản hồi 1:1."
            bannerActionButton.isHidden = true
        }
        
        // Labels
        overviewDeviceLabel.stringValue = snapshot.device.description
        overviewDisplayLabel.stringValue = snapshot.display.description
        overviewCalibrationLabel.stringValue = snapshot.calibration.description
        overviewAXLabel.stringValue = snapshot.accessibility == .available ? "Đã cấp quyền (Sẵn sàng)" : "Chưa cấp quyền"
        
        enableTouchSwitch.state = snapshot.isUserEnabled ? .on : .off
        launchAtLoginSwitch.state = TouchBridgeRuntime.shared.launchAtLogin ? .on : .off
        directTouchSwitch.state = TouchBridgeRuntime.shared.recognizer.directTouchModeEnabled ? .on : .off
        invertRotationSwitch.state = CalibrationProfile.invertQuarterTurnDirection ? .on : .off
        
        if let disp = snapshot.display.boundDisplay {
            displayDetailNameLabel.stringValue = disp.name
            displayDetailResLabel.stringValue = "\(Int(disp.cgWidth)) × \(Int(disp.cgHeight)) (Gốc: \(Int(disp.pixelWidth))×\(Int(disp.pixelHeight)) @ \(disp.backingScaleFactor)x)"
            displayDetailRotLabel.stringValue = "\(Int(disp.rotationDegrees))°"
        }
        
        let versionStr = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let buildStr = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Dev"
        aboutVersionLabel.stringValue = "TouchBridge v\(versionStr) (Build \(buildStr))"
    }
    
    public func showWindowToFront() {
        update(with: TouchBridgeRuntime.shared.currentSnapshot)
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Actions
    
    @objc private func handleTabChanged() {
        tabView.selectTabViewItem(at: tabSegmentedControl.selectedSegment)
    }
    
    @objc private func handleEnableTouchSwitch() {
        TouchBridgeRuntime.shared.setEnabled(enableTouchSwitch.state == .on)
    }
    
    @objc private func handleEnableTouchAction() {
        TouchBridgeRuntime.shared.setEnabled(true)
    }
    
    @objc private func handleLaunchAtLoginSwitch() {
        TouchBridgeRuntime.shared.launchAtLogin = (launchAtLoginSwitch.state == .on)
    }
    
    @objc private func handleDirectTouchSwitch() {
        TouchBridgeRuntime.shared.setDirectTouchModeEnabled(directTouchSwitch.state == .on)
    }
    
    @objc private func handleInvertRotationSwitch() {
        TouchBridgeRuntime.shared.setInvertQuarterTurnRotation(invertRotationSwitch.state == .on)
    }
    
    @objc private func handleCalibrate() {
        CalibrationWindowController.shared.startCalibrationSession()
    }
    
    @objc private func handleGrantAX() {
        TouchBridgeRuntime.shared.requestAccessibilityPermissionExplicitly()
    }
    
    @objc private func handleBannerAction() {
        // Triggers whichever action was assigned to the banner button
    }
    
    @objc private func handleExportReport() {
        TouchBridgeLogger.exportDiagnosticReportToDesktop()
    }
    
    @objc private func handleOpenDiagnostics() {
        DiagnosticsWindowController.shared.showWindowToFront()
    }
    
    @objc private func handleRevealLog() {
        let logPath = "/tmp/touchbridge_dev.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "/tmp")
        }
    }
    
    @objc private func handleToggleKeyboard() {
        OnScreenKeyboardController.shared.toggleOnScreenKeyboard()
    }
    
    @objc private func handleOpenRepo() {
        if let url = URL(string: "https://github.com/VuPhm/touch-bridge") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func handleClose() {
        self.window?.close()
    }
}
