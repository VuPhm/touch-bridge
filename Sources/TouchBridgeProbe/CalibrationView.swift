import Foundation
import Cocoa
import CoreGraphics

public protocol CalibrationDelegate: AnyObject {
    func calibrationDidComplete(profile: CalibrationProfile)
    func calibrationDidCancel()
}

public final class CalibrationView: NSView {
    public weak var delegate: CalibrationDelegate?
    
    public override var isFlipped: Bool { true } // Top-Left origin matches CoreGraphics local space
    
    private let targetDisplay: DisplayMetadata
    private let inset: Double = 54.0 // 54 pt margin provides finger clearance without bezel clipping
    
    private enum CalibrationPhase {
        case fitting      // 9 fit points (4 corners, 4 edge midpoints, 1 center)
        case verifying    // 4 out-of-sample quarter points
        case reviewing    // Display residuals, verification errors, and save confirmation
    }
    
    private var phase: CalibrationPhase = .fitting
    private var targetPointsLocalCG: [(label: String, pt: CGPoint, isVerify: Bool)] = []
    private var currentPointIndex: Int = 0
    private var capturedPoints: [CalibrationPointPair] = []
    
    // In-touch sample accumulation for dwell stability
    private var activeTouchSamples: [TouchSample] = []
    private var isTouchingCurrentPoint: Bool = false
    private var lastStabilityWarning: String? = nil
    
    // Solved results for review
    private var solvedMatrix: AffineMatrix2D? = nil
    private var solvedResiduals: [Double] = []
    private var solvedMeanResidual: Double = 0.0
    private var solvedMaxResidual: Double = 0.0
    
    private var verificationErrors: [Double] = []
    private var verificationMeanError: Double = 0.0
    private var verificationMaxError: Double = 0.0
    
    private let fitPointCount: Int = 9
    private let verifyPointCount: Int = 4
    
    public init(frame: NSRect, display: DisplayMetadata) {
        self.targetDisplay = display
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1.0).cgColor
        
        setupTargets()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    public override var acceptsFirstResponder: Bool { true }
    
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            delegate?.calibrationDidCancel()
        } else if event.keyCode == 15 { // 'R' key (retry)
            if phase == .reviewing {
                setupTargets()
                needsDisplay = true
            } else {
                retryCurrentPoint()
            }
        } else if (event.keyCode == 36 || event.keyCode == 49) { // Return or Space
            if phase == .reviewing {
                saveAndApplyProfile()
            } else if capturedPoints.count >= fitPointCount {
                // If user has captured at least the 9 fit points, allow skipping remaining to review
                solveAndTransitionToReview()
            }
        } else {
            super.keyDown(with: event)
        }
    }
    
    private func setupTargets() {
        let w = Double(bounds.width)
        let h = Double(bounds.height)
        
        // 9 Fit Points: 4 corners + 4 edge midpoints + 1 center
        // 4 Out-of-Sample Verification Points: 4 quarter points
        targetPointsLocalCG = [
            // --- Phase 1: 9 Fit Points ---
            ("1/9 Góc Trên-Trái (Top-Left)", CGPoint(x: inset, y: inset), false),
            ("2/9 Giữa Cạnh Trên (Top-Mid)", CGPoint(x: w * 0.5, y: inset), false),
            ("3/9 Góc Trên-Phải (Top-Right)", CGPoint(x: w - inset, y: inset), false),
            ("4/9 Giữa Cạnh Phải (Right-Mid)", CGPoint(x: w - inset, y: h * 0.5), false),
            ("5/9 Góc Dưới-Phải (Bottom-Right)", CGPoint(x: w - inset, y: h - inset), false),
            ("6/9 Giữa Cạnh Dưới (Bottom-Mid)", CGPoint(x: w * 0.5, y: h - inset), false),
            ("7/9 Góc Dưới-Trái (Bottom-Left)", CGPoint(x: inset, y: h - inset), false),
            ("8/9 Giữa Cạnh Trái (Left-Mid)", CGPoint(x: inset, y: h * 0.5), false),
            ("9/9 Tâm Màn Hình (Center)", CGPoint(x: w * 0.5, y: h * 0.5), false),
            
            // --- Phase 2: 4 Verification Points ---
            ("V1/4 Kiểm Chứng Phần Tư Trên-Trái", CGPoint(x: w * 0.25, y: h * 0.25), true),
            ("V2/4 Kiểm Chứng Phần Tư Trên-Phải", CGPoint(x: w * 0.75, y: h * 0.25), true),
            ("V3/4 Kiểm Chứng Phần Tư Dưới-Phải", CGPoint(x: w * 0.75, y: h * 0.75), true),
            ("V4/4 Kiểm Chứng Phần Tư Dưới-Trái", CGPoint(x: w * 0.25, y: h * 0.75), true)
        ]
        
        currentPointIndex = 0
        capturedPoints.removeAll()
        activeTouchSamples.removeAll()
        isTouchingCurrentPoint = false
        lastStabilityWarning = nil
        phase = .fitting
    }
    
    private func retryCurrentPoint() {
        activeTouchSamples.removeAll()
        isTouchingCurrentPoint = false
        lastStabilityWarning = "Đã làm mới điểm hiện tại. Chạm giữ ~0.5s rồi nhấc tay."
        needsDisplay = true
    }
    
    public func handleTouchSample(_ sample: TouchSample) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.phase != .reviewing else { return }
            guard self.currentPointIndex < self.targetPointsLocalCG.count else { return }
            
            switch sample.phase {
            case .down:
                self.isTouchingCurrentPoint = true
                self.activeTouchSamples = [sample]
                self.lastStabilityWarning = nil
                self.needsDisplay = true
                
            case .move:
                if self.isTouchingCurrentPoint {
                    self.activeTouchSamples.append(sample)
                    self.needsDisplay = true
                }
                
            case .up:
                if self.isTouchingCurrentPoint && !self.activeTouchSamples.isEmpty {
                    self.isTouchingCurrentPoint = false
                    self.processCompletedTouch()
                }
            }
        }
    }
    
    private func processCompletedTouch() {
        guard currentPointIndex < targetPointsLocalCG.count else { return }
        let currentTarget = targetPointsLocalCG[currentPointIndex]
        let totalCount = activeTouchSamples.count
        
        // 1. Dwell Duration Check: minimum 6 samples (~60-100ms)
        guard totalCount >= 6 else {
            lastStabilityWarning = "Chạm quá nhanh (\(totalCount) mẫu). Vui lòng chạm giữ ~0.5s trên hồng tâm rồi nhấc tay."
            activeTouchSamples.removeAll()
            needsDisplay = true
            return
        }
        
        // 2. Trim 20% landing transient and 20% liftoff transient
        let startIdx = Int(Double(totalCount) * 0.20)
        let endIdx = max(startIdx + 2, Int(Double(totalCount) * 0.80))
        let stableWindow = Array(activeTouchSamples[startIdx..<endIdx])
        
        guard !stableWindow.isEmpty else {
            activeTouchSamples.removeAll()
            return
        }
        
        // 3. Compute Dwell Mean and Standard Deviation (in raw HID 4096-space)
        let n = Double(stableWindow.count)
        let sumRawX = stableWindow.reduce(0.0) { $0 + Double($1.rawX) }
        let sumRawY = stableWindow.reduce(0.0) { $0 + Double($1.rawY) }
        let meanRawX = sumRawX / n
        let meanRawY = sumRawY / n
        
        let varX = stableWindow.reduce(0.0) { $0 + pow(Double($1.rawX) - meanRawX, 2) } / n
        let varY = stableWindow.reduce(0.0) { $0 + pow(Double($1.rawY) - meanRawY, 2) } / n
        let stdX = sqrt(varX)
        let stdY = sqrt(varY)
        
        // 4. Reject sliding or unstable touches (stdDev > 25.0 raw units)
        if stdX > 25.0 || stdY > 25.0 {
            lastStabilityWarning = String(
                format: "Điểm chạm bị trượt/rung lắc (độ lệch σx=%.1f, σy=%.1f raw). Vui lòng chạm giữ yên và thử lại.",
                stdX, stdY
            )
            activeTouchSamples.removeAll()
            needsDisplay = true
            return
        }
        
        // 5. Compute Normalized Coordinates directly from raw sensor readings
        // Do NOT pass through any old calibration profiles or synthetic transformations.
        let normU = max(0.0, min(1.0, meanRawX / 4096.0))
        let normV = max(0.0, min(1.0, meanRawY / 4096.0))
        
        let pair = CalibrationPointPair(
            label: currentTarget.label,
            targetLocalCG: currentTarget.pt,
            rawSensor: RawHIDPoint(x: Int(meanRawX.rounded()), y: Int(meanRawY.rounded())),
            normalizedSensor: NormalizedSensorPoint(u: normU, v: normV)
        )
        capturedPoints.append(pair)
        NSSound.beep()
        
        print("\n[CALIBRATION] Ghi nhận thành công điểm [\(currentTarget.label)]:")
        print("  • Tọa độ mục tiêu CG:   (\(Int(currentTarget.pt.x)), \(Int(currentTarget.pt.y))) pt")
        print("  • Cảm biến Raw HID thô: (\(Int(meanRawX)), \(Int(meanRawY))) [Mẫu ổn định: \(stableWindow.count)/\(totalCount)]")
        print("  • Tọa độ chuẩn hóa thô: u=\(String(format: "%.4f", normU)), v=\(String(format: "%.4f", normV)) (σx=\(String(format: "%.1f", stdX)), σy=\(String(format: "%.1f", stdY)))")
        
        currentPointIndex += 1
        activeTouchSamples.removeAll()
        lastStabilityWarning = nil
        
        if currentPointIndex == fitPointCount {
            phase = .verifying
        }
        
        if currentPointIndex >= targetPointsLocalCG.count {
            solveAndTransitionToReview()
        } else {
            needsDisplay = true
        }
    }
    
    private func solveAndTransitionToReview() {
        let fitPoints = Array(capturedPoints.prefix(fitPointCount))
        guard fitPoints.count >= 3 else {
            lastStabilityWarning = "Chưa đủ điểm để khớp ma trận (cần ít nhất 3 điểm)."
            needsDisplay = true
            return
        }
        
        guard let fit = AffineMatrix2D.solveLeastSquares(points: fitPoints) else {
            lastStabilityWarning = "Lỗi giải ma trận bình phương tối thiểu (định thức gần bằng 0)."
            needsDisplay = true
            return
        }
        
        self.solvedMatrix = fit.matrix
        self.solvedResiduals = fit.residuals
        self.solvedMeanResidual = fit.meanResidual
        self.solvedMaxResidual = fit.maxResidual
        
        let verifyPoints = capturedPoints.count > fitPointCount ? Array(capturedPoints.dropFirst(fitPointCount)) : []
        if !verifyPoints.isEmpty {
            let vMetrics = fit.matrix.evaluateVerificationPoints(verifyPoints)
            self.verificationErrors = vMetrics.errors
            self.verificationMeanError = vMetrics.meanError
            self.verificationMaxError = vMetrics.maxError
        } else {
            self.verificationErrors = []
            self.verificationMeanError = 0.0
            self.verificationMaxError = 0.0
        }
        
        self.phase = .reviewing
        needsDisplay = true
    }
    
    private func saveAndApplyProfile() {
        guard let matrix = solvedMatrix else { return }
        let fitPoints = Array(capturedPoints.prefix(fitPointCount))
        let verifyPoints = capturedPoints.count > fitPointCount ? Array(capturedPoints.dropFirst(fitPointCount)) : []
        
        let profile = CalibrationProfile(
            version: 2,
            createdAt: Date(),
            deviceVendorID: 0x1A86,
            deviceProductID: 0xE5E3,
            deviceName: "USB2IIC_CTP_CONTROL",
            displayID: targetDisplay.id,
            displayName: targetDisplay.name,
            displayVendorNumber: targetDisplay.vendorNumber,
            displayModelNumber: targetDisplay.modelNumber,
            displaySerialNumber: targetDisplay.serialNumber,
            displayWidth: targetDisplay.cgWidth,
            displayHeight: targetDisplay.cgHeight,
            backingScaleFactor: targetDisplay.backingScaleFactor,
            rotationDegrees: targetDisplay.rotationDegrees,
            points: fitPoints,
            transformType: "affine",
            affineMatrix: matrix,
            homographyMatrix: nil,
            residualErrors: solvedResiduals,
            meanResidualError: solvedMeanResidual,
            maxResidualError: solvedMaxResidual,
            verificationPoints: verifyPoints.isEmpty ? nil : verifyPoints,
            verificationErrors: verifyPoints.isEmpty ? nil : verificationErrors,
            meanVerificationError: verifyPoints.isEmpty ? nil : verificationMeanError,
            maxVerificationError: verifyPoints.isEmpty ? nil : verificationMaxError,
            note: "Hiệu chuẩn cảm ứng vật lý 9 điểm trực tiếp. macOS không có API đọc OSD/underscan màn hình ngoài; ma trận affine này trực tiếp khớp toàn bộ khung hình hiển thị đang hoạt động."
        )
        
        let saveURL = CalibrationProfile.defaultProfileURL(for: targetDisplay.id)
        do {
            try profile.save(to: saveURL)
            TouchBridgeLogger.info(.calibration, "Đã lưu profile hiệu chuẩn 9 điểm vào: \(saveURL.path)")
            
            let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TouchBridgeCalibration.json")
            try? profile.save(to: cwdURL)
        } catch {
            TouchBridgeLogger.error(.calibration, "Không thể lưu profile: \(error)")
        }
        
        delegate?.calibrationDidComplete(profile: profile)
    }
    
    // MARK: - Drawing & Layout
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        let w = bounds.width
        let h = bounds.height
        
        // 1. Subtle Background Grid
        ctx.setStrokeColor(NSColor(white: 0.12, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        let step: CGFloat = 64.0
        for x in stride(from: step, to: w, by: step) {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: h))
        }
        for y in stride(from: step, to: h, by: step) {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: w, y: y))
        }
        ctx.strokePath()
        
        switch phase {
        case .fitting, .verifying:
            drawTargetPhase(ctx: ctx, w: w, h: h)
        case .reviewing:
            drawReviewPhase(ctx: ctx, w: w, h: h)
        }
    }
    
    private func drawTargetPhase(ctx: CGContext, w: CGFloat, h: CGFloat) {
        // Header
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let subAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 0.7, alpha: 1.0)
        ]
        
        let currentTarget = currentPointIndex < targetPointsLocalCG.count ? targetPointsLocalCG[currentPointIndex] : nil
        let isVerify = currentTarget?.isVerify ?? false
        
        let phaseText = isVerify ? "GIAI ĐOẠN 2: KIỂM CHỨNG ĐỘC LẬP (4 ĐIỂM NGOÀI MẪU)" : "GIAI ĐOẠN 1: HIỆU CHUẨN MA TRẬN 9 ĐIỂM (LEAST-SQUARES)"
        let title = "TouchBridge — Hiệu Chuẩn Cảm Ứng Vật Lý • \(phaseText)"
        let sub = "Màn hình: \(targetDisplay.name) (#\(targetDisplay.id)) • Khung hình: \(Int(w))×\(Int(h)) pt @ \(Int(targetDisplay.rotationDegrees))° • Nhấn [ESC] hủy, [R] thử lại điểm"
        
        (title as NSString).draw(at: CGPoint(x: 40, y: 35), withAttributes: titleAttributes)
        (sub as NSString).draw(at: CGPoint(x: 40, y: 64), withAttributes: subAttributes)
        
        // Status message
        let statusColor: NSColor
        let statusString: String
        if let warn = lastStabilityWarning {
            statusColor = .systemYellow
            statusString = warn
        } else if isTouchingCurrentPoint {
            statusColor = .systemGreen
            let sampleCount = activeTouchSamples.count
            statusString = "Đang giữ ngón tay trên hồng tâm (\(sampleCount) mẫu)... Nhấc tay ra để xác nhận."
        } else {
            statusColor = isVerify ? NSColor.systemTeal : NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
            let skipHint = currentPointIndex >= fitPointCount ? " • Nhấn [Return] để bỏ qua kiểm chứng và xem kết quả ngay" : ""
            statusString = "Chạm giữ tâm của: \(currentTarget?.label ?? "")\(skipHint)"
        }
        
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: statusColor
        ]
        (statusString as NSString).draw(at: CGPoint(x: 40, y: 92), withAttributes: statusAttrs)
        
        // Draw Completed Points
        for (i, pt) in capturedPoints.enumerated() {
            let p = pt.targetLocalCG
            let isV = i >= fitPointCount
            let color = isV ? NSColor.systemTeal : NSColor.systemGreen
            
            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40))
            
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40))
            
            // Checkmark
            ctx.setLineWidth(2.5)
            ctx.move(to: CGPoint(x: p.x - 6, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x - 1, y: p.y + 5))
            ctx.addLine(to: CGPoint(x: p.x + 7, y: p.y - 5))
            ctx.strokePath()
        }
        
        // Draw Active Crosshair
        if let target = currentTarget {
            let p = target.pt
            let color: NSColor
            if isTouchingCurrentPoint {
                color = .systemGreen
            } else if target.isVerify {
                color = .systemTeal
            } else {
                color = NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)
            }
            
            let ringRadius: CGFloat = isTouchingCurrentPoint ? 34.0 : 28.0
            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - ringRadius, y: p.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - ringRadius, y: p.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            
            // Inner Target
            let arm: CGFloat = 18.0
            ctx.setLineWidth(2.0)
            ctx.move(to: CGPoint(x: p.x - arm, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x + arm, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - arm))
            ctx.addLine(to: CGPoint(x: p.x, y: p.y + arm))
            ctx.strokePath()
            
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            
            // Callout Label
            let calloutAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let labelX = (p.x < w / 2) ? p.x + 36 : p.x - 180
            let labelY = (p.y < h / 2) ? p.y + 10 : p.y - 25
            (target.label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: calloutAttrs)
        }
    }
    
    private func drawReviewPhase(ctx: CGContext, w: CGFloat, h: CGFloat) {
        // Draw semi-transparent card container
        let cardRect = CGRect(x: 40, y: 35, width: w - 80, height: h - 70)
        ctx.setFillColor(NSColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 0.95).cgColor)
        let path = CGPath(roundedRect: cardRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        
        ctx.setStrokeColor(NSColor(white: 0.25, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()
        
        var yPos: CGFloat = 55
        
        // Title
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        ("KẾT QUẢ HIỆU CHUẨN CẢM ỨNG VẬT LÝ 9 ĐIỂM" as NSString).draw(at: CGPoint(x: 65, y: yPos), withAttributes: headerAttrs)
        yPos += 30
        
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 0.75, alpha: 1.0)
        ]
        ("Màn hình: \(targetDisplay.name) (#\(targetDisplay.id)) • Ma trận Affine Least-Squares" as NSString).draw(at: CGPoint(x: 65, y: yPos), withAttributes: subAttrs)
        yPos += 30
        
        // Metrics Summary Boxes
        let boxWidth: CGFloat = (cardRect.width - 60) / 2
        
        // Box 1: 9-Point Fit
        let box1Rect = CGRect(x: 65, y: yPos, width: boxWidth, height: 95)
        drawMetricBox(ctx: ctx, rect: box1Rect, title: "Sai Số Khớp 9 Điểm (Fit Residuals)", meanVal: solvedMeanResidual, maxVal: solvedMaxResidual)
        
        // Box 2: Verification Points
        let box2Rect = CGRect(x: 65 + boxWidth + 10, y: yPos, width: boxWidth, height: 95)
        if !verificationErrors.isEmpty {
            drawMetricBox(ctx: ctx, rect: box2Rect, title: "Sai Số Kiểm Chứng Độc Lập (4 Điểm Ngoài Mẫu)", meanVal: verificationMeanError, maxVal: verificationMaxError)
        } else {
            drawMetricBox(ctx: ctx, rect: box2Rect, title: "Kiểm Chứng Độc Lập", meanVal: 0.0, maxVal: 0.0, emptyNote: "Đã bỏ qua giai đoạn kiểm chứng")
        }
        yPos += 115
        
        // Regional Residuals Table
        let tableHeaderAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        ("Phân Bố Sai Số Theo Vùng Màn Hình:" as NSString).draw(at: CGPoint(x: 65, y: yPos), withAttributes: tableHeaderAttrs)
        yPos += 24
        
        // Calculate regional residuals:
        // Points: 0:Top-Left, 1:Top-Mid, 2:Top-Right, 3:Right-Mid, 4:Bottom-Right, 5:Bottom-Mid, 6:Bottom-Left, 7:Left-Mid, 8:Center
        let topRes = average(residuals: [0, 1, 2])
        let midRes = average(residuals: [7, 8, 3])
        let botRes = average(residuals: [6, 5, 4])
        let leftRes = average(residuals: [0, 7, 6])
        let ctrRes = average(residuals: [1, 8, 5])
        let rightRes = average(residuals: [2, 3, 4])
        
        let regionalStr = String(
            format: "  • Chiều dọc:   Trên: %.2f pt  •  Giữa: %.2f pt  •  Dưới: %.2f pt\n  • Chiều ngang: Trái: %.2f pt  •  Giữa: %.2f pt  •  Phải: %.2f pt",
            topRes, midRes, botRes, leftRes, ctrRes, rightRes
        )
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(white: 0.85, alpha: 1.0)
        ]
        (regionalStr as NSString).draw(at: CGPoint(x: 65, y: yPos), withAttributes: bodyAttrs)
        yPos += 45
        
        // Architectural note
        let noteAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.6, alpha: 1.0)
        ]
        let archNote = "Ghi chú: macOS không cung cấp API đọc trạng thái OSD/underscan của màn hình ngoài.\nMa trận hiệu chuẩn 9 điểm này trực tiếp bao quát kích thước hiển thị thực tế dựa trên phép đo ngón tay vật lý."
        (archNote as NSString).draw(at: CGPoint(x: 65, y: yPos), withAttributes: noteAttrs)
        yPos += 50
        
        // Action Bar / Hotkeys
        let btnAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let saveAction = "[ Phím RETURN / Space ]: Lưu Profile & Bắt Đầu Sử Dụng"
        let retryAction = "[ Phím R ]: Hiệu chuẩn lại từ đầu    •    [ Phím ESC ]: Hủy bỏ"
        
        (saveAction as NSString).draw(at: CGPoint(x: 65, y: yPos), withAttributes: btnAttrs)
        yPos += 24
        let retryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        (retryAction as NSString).draw(at: CGPoint(x: 65, y: yPos), withAttributes: retryAttrs)
    }
    
    private func average(residuals indices: [Int]) -> Double {
        guard !solvedResiduals.isEmpty else { return 0.0 }
        let vals = indices.compactMap { idx -> Double? in
            idx < solvedResiduals.count ? solvedResiduals[idx] : nil
        }
        guard !vals.isEmpty else { return 0.0 }
        return vals.reduce(0.0, +) / Double(vals.count)
    }
    
    private func drawMetricBox(ctx: CGContext, rect: CGRect, title: String, meanVal: Double, maxVal: Double, emptyNote: String? = nil) {
        ctx.setFillColor(NSColor(white: 0.16, alpha: 1.0).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor(white: 0.28, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(rect)
        
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        (title as NSString).draw(at: CGPoint(x: rect.origin.x + 12, y: rect.origin.y + 10), withAttributes: titleAttrs)
        
        if let note = emptyNote {
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            (note as NSString).draw(at: CGPoint(x: rect.origin.x + 12, y: rect.origin.y + 40), withAttributes: noteAttrs)
            return
        }
        
        let meanStr = String(format: "Trung bình: %.2f pt", meanVal)
        let maxStr = String(format: "Lớn nhất:   %.2f pt", maxVal)
        
        let isGood = meanVal <= 10.0
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold),
            .foregroundColor: isGood ? NSColor.systemGreen : NSColor.systemYellow
        ]
        (meanStr as NSString).draw(at: CGPoint(x: rect.origin.x + 12, y: rect.origin.y + 36), withAttributes: valAttrs)
        
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(white: 0.8, alpha: 1.0)
        ]
        (maxStr as NSString).draw(at: CGPoint(x: rect.origin.x + 12, y: rect.origin.y + 64), withAttributes: subAttrs)
    }
}
