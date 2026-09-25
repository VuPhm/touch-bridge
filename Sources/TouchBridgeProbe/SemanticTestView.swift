import Foundation
import Cocoa
import CoreGraphics

public protocol SemanticTestViewDelegate: AnyObject {
    func semanticTestViewDidRequestSwitchToAppKit()
    func semanticTestViewDidRequestSwitchToCalculator()
    func semanticTestViewDidRequestSwitchToTextEdit()
    func semanticTestViewDidRequestSwitchToFinder()
    func semanticTestViewDidRequestSwitchToBrowser()
    func semanticTestViewDidRequestSaveReport()
}

public final class SemanticTestView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public weak var delegate: SemanticTestViewDelegate?
    
    // Left Column: Tap Controls
    private let incrementButton = NSButton()
    private let checkboxButton = NSButton()
    private let nativeSwitch = NSSwitch()
    private let radioA = NSButton()
    private let radioB = NSButton()
    private let segmentedControl = NSSegmentedControl()
    private let popUpButton = NSPopUpButton()
    
    // Text Focus Control
    private let textField = NSTextField()
    private let textMirrorLabel = NSTextField(labelWithString: "Keyboard Input: (tap field to focus)")
    
    // Right Column: Scroll & Table Controls
    private let scrollView = NSScrollView()
    private let scrollTextView = NSTextView()
    private let scrollInfoLabel = NSTextField(labelWithString: "NSScrollView Pos: 0.00")
    
    private let tableView = NSTableView()
    private let tableScrollView = NSScrollView()
    private let tableSelectionLabel = NSTextField(labelWithString: "Table Selection: None")
    
    // Status Displays
    private let counterLabel = NSTextField(labelWithString: "Counter: 0")
    private let checkboxLabel = NSTextField(labelWithString: "Checkbox: UNCHECKED")
    private let lastActionLabel = NSTextField(labelWithString: "Last Semantic Action: Ready for P2-B tests.")
    private let cursorInvariantLabel = NSTextField(labelWithString: "Cursor Invariant: Initializing...")
    
    // Mode Switch Buttons
    private let modeCalcButton = NSButton()
    private let modeTextEditButton = NSButton()
    private let modeFinderButton = NSButton()
    private let modeBrowserButton = NSButton()
    private let saveReportButton = NSButton()
    
    private var counter: Int = 0
    private var isCheckboxChecked: Bool = false
    private let tableData = (1...25).map { "Item Row #\($0) — TouchBridge Semantic Test Row" }
    
    private let display: DisplayMetadata
    private let profile: CalibrationProfile
    
    public init(frame: NSRect, display: DisplayMetadata, profile: CalibrationProfile) {
        self.display = display
        self.profile = profile
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor
        
        setupControls()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupControls() {
        let leftX: CGFloat = 36
        let rightX: CGFloat = 620
        var leftY: CGFloat = bounds.height - 50
        var rightY: CGFloat = bounds.height - 50
        
        // Header
        let titleLabel = NSTextField(labelWithString: "TouchBridge P2-B — Real-World Semantic Interaction Matrix")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = NSColor.white
        titleLabel.frame = NSRect(x: leftX, y: leftY, width: 700, height: 26)
        addSubview(titleLabel)
        leftY -= 40
        rightY -= 40
        
        // ================= LEFT COLUMN: TAPS & TEXT FOCUS =================
        
        // 1. NSButton
        incrementButton.title = "Tap NSButton to Increment"
        incrementButton.bezelStyle = .rounded
        incrementButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        incrementButton.frame = NSRect(x: leftX, y: leftY, width: 260, height: 40)
        incrementButton.target = self
        incrementButton.action = #selector(handleIncrementPressed(_:))
        addSubview(incrementButton)
        
        counterLabel.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        counterLabel.textColor = NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        counterLabel.frame = NSRect(x: leftX + 280, y: leftY + 8, width: 220, height: 24)
        addSubview(counterLabel)
        leftY -= 46
        
        // 2. NSCheckbox
        checkboxButton.setButtonType(.switch)
        checkboxButton.title = "AppKit NSCheckbox"
        checkboxButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        checkboxButton.frame = NSRect(x: leftX, y: leftY, width: 260, height: 30)
        checkboxButton.target = self
        checkboxButton.action = #selector(handleCheckboxToggled(_:))
        addSubview(checkboxButton)
        
        checkboxLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        checkboxLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        checkboxLabel.frame = NSRect(x: leftX + 280, y: leftY + 4, width: 220, height: 22)
        addSubview(checkboxLabel)
        leftY -= 40
        
        // 3. Radio Buttons & NSSwitch
        radioA.setButtonType(.radio)
        radioA.title = "Radio 1"
        radioA.state = .on
        radioA.frame = NSRect(x: leftX, y: leftY, width: 90, height: 24)
        addSubview(radioA)
        
        radioB.setButtonType(.radio)
        radioB.title = "Radio 2"
        radioB.frame = NSRect(x: leftX + 95, y: leftY, width: 90, height: 24)
        addSubview(radioB)
        
        nativeSwitch.frame = NSRect(x: leftX + 200, y: leftY - 2, width: 45, height: 26)
        addSubview(nativeSwitch)
        leftY -= 44
        
        // 4. NSPopUpButton & NSSegmentedControl
        popUpButton.frame = NSRect(x: leftX, y: leftY, width: 200, height: 30)
        popUpButton.addItems(withTitles: ["Menu Option Alpha", "Menu Option Beta", "Menu Option Gamma"])
        addSubview(popUpButton)
        
        segmentedControl.segmentCount = 3
        segmentedControl.setLabel("Tab 1", forSegment: 0)
        segmentedControl.setLabel("Tab 2", forSegment: 1)
        segmentedControl.setLabel("Tab 3", forSegment: 2)
        segmentedControl.selectedSegment = 0
        segmentedControl.frame = NSRect(x: leftX + 220, y: leftY + 2, width: 220, height: 26)
        addSubview(segmentedControl)
        leftY -= 50
        
        // 5. NSTextField (Text Focus Viability)
        let tfHeader = NSTextField(labelWithString: "Text Field Focus Viability (Tap to focus):")
        tfHeader.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        tfHeader.textColor = NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0)
        tfHeader.frame = NSRect(x: leftX, y: leftY, width: 400, height: 18)
        addSubview(tfHeader)
        leftY -= 26
        
        textField.placeholderString = "Physical tap transfers focus here. Type on keyboard..."
        textField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textField.frame = NSRect(x: leftX, y: leftY, width: 440, height: 32)
        textField.target = self
        textField.action = #selector(handleTextFieldChanged(_:))
        addSubview(textField)
        leftY -= 28
        
        textMirrorLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        textMirrorLabel.textColor = NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        textMirrorLabel.frame = NSRect(x: leftX, y: leftY, width: 440, height: 20)
        addSubview(textMirrorLabel)
        leftY -= 45
        
        // 6. Navigation Buttons to External Apps
        let navHeader = NSTextField(labelWithString: "Cross-Application & Browser Targets:")
        navHeader.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        navHeader.textColor = NSColor.white
        navHeader.frame = NSRect(x: leftX, y: leftY, width: 440, height: 18)
        addSubview(navHeader)
        leftY -= 32
        
        modeCalcButton.title = "Calculator"
        modeCalcButton.bezelStyle = .rounded
        modeCalcButton.frame = NSRect(x: leftX, y: leftY, width: 105, height: 30)
        modeCalcButton.target = self
        modeCalcButton.action = #selector(handleSwitchToCalc(_:))
        addSubview(modeCalcButton)
        
        modeTextEditButton.title = "TextEdit"
        modeTextEditButton.bezelStyle = .rounded
        modeTextEditButton.frame = NSRect(x: leftX + 112, y: leftY, width: 105, height: 30)
        modeTextEditButton.target = self
        modeTextEditButton.action = #selector(handleSwitchToTextEdit(_:))
        addSubview(modeTextEditButton)
        
        modeFinderButton.title = "Finder"
        modeFinderButton.bezelStyle = .rounded
        modeFinderButton.frame = NSRect(x: leftX + 224, y: leftY, width: 105, height: 30)
        modeFinderButton.target = self
        modeFinderButton.action = #selector(handleSwitchToFinder(_:))
        addSubview(modeFinderButton)
        
        modeBrowserButton.title = "Safari HTML"
        modeBrowserButton.bezelStyle = .rounded
        modeBrowserButton.frame = NSRect(x: leftX + 336, y: leftY, width: 115, height: 30)
        modeBrowserButton.target = self
        modeBrowserButton.action = #selector(handleSwitchToBrowser(_:))
        addSubview(modeBrowserButton)
        leftY -= 40
        
        saveReportButton.title = "Save P2-B Verification Report (S)"
        saveReportButton.bezelStyle = .rounded
        saveReportButton.frame = NSRect(x: leftX, y: leftY, width: 280, height: 32)
        saveReportButton.target = self
        saveReportButton.action = #selector(handleSaveReport(_:))
        addSubview(saveReportButton)
        
        // ================= RIGHT COLUMN: SCROLL & TABLE SELECTION =================
        
        // 1. NSScrollView with long text
        let scrollTitle = NSTextField(labelWithString: "Semantic Scroll Target: NSScrollView (Touch Pan to Scroll):")
        scrollTitle.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        scrollTitle.textColor = NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0)
        scrollTitle.frame = NSRect(x: rightX, y: rightY, width: 500, height: 18)
        addSubview(scrollTitle)
        rightY -= 24
        
        scrollView.frame = NSRect(x: rightX, y: rightY - 220, width: 540, height: 220)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        
        scrollTextView.frame = NSRect(x: 0, y: 0, width: 520, height: 1200)
        scrollTextView.isEditable = false
        var sampleText = "=== TouchBridge NSScrollView Semantic Scroll Demonstration ===\n\n"
        for i in 1...100 {
            sampleText += "Line \(String(format: "%03d", i)): TouchBridge pointer-independent proportional touch pan row \(i)\n"
        }
        scrollTextView.string = sampleText
        scrollView.documentView = scrollTextView
        addSubview(scrollView)
        rightY -= 255
        
        // 2. NSTableView for Row Selection
        let tableTitle = NSTextField(labelWithString: "Semantic Selection Target: NSTableView (Tap to Select Row):")
        tableTitle.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        tableTitle.textColor = NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0)
        tableTitle.frame = NSRect(x: rightX, y: rightY, width: 500, height: 18)
        addSubview(tableTitle)
        rightY -= 24
        
        tableScrollView.frame = NSRect(x: rightX, y: rightY - 170, width: 540, height: 170)
        tableScrollView.hasVerticalScroller = true
        tableScrollView.borderType = .bezelBorder
        
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("itemCol"))
        col.title = "Interactive Test Items"
        col.width = 500
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self
        tableScrollView.documentView = tableView
        addSubview(tableScrollView)
        rightY -= 195
        
        tableSelectionLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        tableSelectionLabel.textColor = NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        tableSelectionLabel.frame = NSRect(x: rightX, y: rightY, width: 500, height: 20)
        addSubview(tableSelectionLabel)
        rightY -= 40
        
        // Status & Cursor Invariant HUD
        let hudBox = NSBox(frame: NSRect(x: leftX, y: 20, width: bounds.width - 72, height: 100))
        hudBox.title = "Live Semantic Feedback & System Cursor Invariant"
        hudBox.titleFont = NSFont.systemFont(ofSize: 12, weight: .bold)
        
        lastActionLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        lastActionLabel.textColor = NSColor(white: 0.9, alpha: 1.0)
        lastActionLabel.frame = NSRect(x: 16, y: 44, width: bounds.width - 104, height: 34)
        hudBox.addSubview(lastActionLabel)
        
        cursorInvariantLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        cursorInvariantLabel.textColor = NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        cursorInvariantLabel.frame = NSRect(x: 16, y: 12, width: bounds.width - 104, height: 24)
        hudBox.addSubview(cursorInvariantLabel)
        addSubview(hudBox)
    }
    
    // NSTableView DataSource & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return tableData.count
    }
    
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        var cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: self) as? NSTextField
        if cell == nil {
            cell = NSTextField(labelWithString: "")
            cell?.identifier = NSUserInterfaceItemIdentifier("cell")
            cell?.font = NSFont.systemFont(ofSize: 12)
        }
        cell?.stringValue = tableData[row]
        return cell
    }
    
    public func tableViewSelectionDidChange(_ notification: Notification) {
        let sel = tableView.selectedRow
        tableSelectionLabel.stringValue = sel >= 0 ? "Table Selection: Row #\(sel + 1) (\"\(tableData[sel])\")" : "Table Selection: None"
        print("[AppKit Event] Table row selected: \(sel)")
    }
    
    @objc private func handleIncrementPressed(_ sender: NSButton) {
        counter += 1
        counterLabel.stringValue = "Counter: \(counter)"
        print("[AppKit Event] Increment button triggered. New count: \(counter)")
    }
    
    @objc private func handleCheckboxToggled(_ sender: NSButton) {
        isCheckboxChecked = (sender.state == .on)
        checkboxLabel.stringValue = "Checkbox: \(isCheckboxChecked ? "CHECKED" : "UNCHECKED")"
        checkboxLabel.textColor = isCheckboxChecked ? NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0) : NSColor(white: 0.85, alpha: 1.0)
    }
    
    @objc private func handleTextFieldChanged(_ sender: NSTextField) {
        textMirrorLabel.stringValue = "Keyboard Input: \"\(sender.stringValue)\""
        print("[AppKit Event] TextField updated: \(sender.stringValue)")
    }
    
    @objc private func handleSwitchToCalc(_ sender: NSButton) {
        delegate?.semanticTestViewDidRequestSwitchToCalculator()
    }
    
    @objc private func handleSwitchToTextEdit(_ sender: NSButton) {
        delegate?.semanticTestViewDidRequestSwitchToTextEdit()
    }
    
    @objc private func handleSwitchToFinder(_ sender: NSButton) {
        delegate?.semanticTestViewDidRequestSwitchToFinder()
    }
    
    @objc private func handleSwitchToBrowser(_ sender: NSButton) {
        delegate?.semanticTestViewDidRequestSwitchToBrowser()
    }
    
    @objc private func handleSaveReport(_ sender: NSButton) {
        delegate?.semanticTestViewDidRequestSaveReport()
    }
    
    public func updateEvidenceFeedback(_ text: String, invariantPassed: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastActionLabel.stringValue = text
            self.cursorInvariantLabel.stringValue = invariantPassed ? "System Cursor Invariant: LOCKED [PASS] (delta == 0.00 pt)" : "System Cursor Invariant: MOVED [FAIL]"
            self.cursorInvariantLabel.textColor = invariantPassed ? NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0) : NSColor.red
        }
    }
}
