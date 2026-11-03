import Foundation
import Cocoa
import CoreGraphics

/// Non-activating floating popover offering "Hiện bàn phím" on triple-tap inside editable text inputs.
/// Conforms strictly to requirements:
/// - Does not steal focus from the target text input.
/// - Does not destroy or cancel the active paragraph text selection.
/// - Closes when tapping outside, absorbing the dismiss tap so background content is not activated.
/// - Automatically clamps inside screen bounds.
/// - Closes when switching apps.
public final class KeyboardPopoverController: NSObject {
    public static let shared = KeyboardPopoverController()

    private var panel: NSPanel?
    private var backdropWindow: NSWindow?
    private var onOpenKeyboard: (() -> Void)?
    private var appSwitchObserver: Any?

    private override init() {
        super.init()
    }

    public func present(near globalPoint: CGPoint, onScreenKeyboardAction: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(near: globalPoint, onScreenKeyboardAction: onScreenKeyboardAction)
        }
    }

    public func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.hideOnMain()
        }
    }

    private func showOnMain(near globalPoint: CGPoint, onScreenKeyboardAction: @escaping () -> Void) {
        hideOnMain()
        self.onOpenKeyboard = onScreenKeyboardAction

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: globalPoint.x, y: $0.frame.origin.y + 10)) }) ?? NSScreen.main else {
            return
        }

        let width: CGFloat = 160
        let height: CGFloat = 44

        // Convert CoreGraphics global point (top-left origin) to AppKit point (bottom-left origin)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
        let appKitY = primaryHeight - globalPoint.y

        // Position horizontally centered, clamped inside screen edges
        var originX = globalPoint.x - (width / 2.0)
        originX = max(screen.frame.minX + 16, min(screen.frame.maxX - width - 16, originX))

        // Position vertically above the tap point; if near top edge, place below
        var originY = appKitY + 20
        if originY + height > screen.frame.maxY - 40 {
            originY = appKitY - height - 20
        }
        originY = max(screen.frame.minY + 16, originY)

        let popoverRect = NSRect(x: originX, y: originY, width: width, height: height)

        // 1. Transparent Backdrop to absorb outside taps
        let backdrop = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        backdrop.level = .floating
        backdrop.backgroundColor = .clear
        backdrop.isOpaque = false
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = false

        let backdropView = BackdropDismissView(frame: NSRect(origin: .zero, size: screen.frame.size)) { [weak self] in
            self?.dismiss()
        }
        backdrop.contentView = backdropView
        self.backdropWindow = backdrop

        // 2. Non-activating Popover Panel
        let p = NSPanel(
            contentRect: popoverRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let cardView = PopoverCardView(frame: NSRect(origin: .zero, size: popoverRect.size))
        cardView.onAction = { [weak self] in
            guard let self = self else { return }
            let action = self.onOpenKeyboard
            self.hideOnMain()
            action?()
        }
        p.contentView = cardView
        self.panel = p

        backdrop.orderFront(nil)
        p.orderFront(nil)

        // Dismiss automatically if user switches active application
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func hideOnMain() {
        if let obs = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appSwitchObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        backdropWindow?.orderOut(nil)
        backdropWindow = nil
        onOpenKeyboard = nil
    }
}

// MARK: - Helper Views

private final class BackdropDismissView: NSView {
    var onDismiss: (() -> Void)?

    init(frame: NSRect, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

private final class PopoverCardView: NSView {
    var onAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(red: 0.12, green: 0.14, blue: 0.17, alpha: 0.96).cgColor
        layer?.borderColor = NSColor(white: 0.28, alpha: 1.0).cgColor
        layer?.borderWidth = 1.0

        let button = NSButton(title: "Hiện bàn phím", target: self, action: #selector(handleButtonClicked))
        button.bezelStyle = .rounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        button.layer?.cornerRadius = 6
        
        let pstyle = NSMutableParagraphStyle()
        pstyle.alignment = .center
        button.attributedTitle = NSAttributedString(
            string: "Hiện bàn phím",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .paragraphStyle: pstyle
            ]
        )

        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    @objc private func handleButtonClicked() {
        onAction?()
    }
}
