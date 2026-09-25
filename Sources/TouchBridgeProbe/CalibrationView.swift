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
    private let inset: Double = 64.0 // Inset from visible screen edges
    
    private var targetPointsLocalCG: [(label: String, pt: CGPoint)] = []
    private var currentPointIndex: Int = 0
    private var capturedPoints: [CalibrationPointPair] = []
    
    // In-touch sample accumulation for stability
    private var activeTouchSamples: [TouchSample] = []
    private var isTouchingCurrentPoint: Bool = false
    
    private var statusMessage: String = "Calibration Mode: Touch target crosshair firmly"
    
    public init(frame: NSRect, display: DisplayMetadata) {
        self.targetDisplay = display
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        
        setupTargets()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupTargets() {
        let w = Double(bounds.width)
        let h = Double(bounds.height)
        
        // 4 Calibration Points in strict clockwise order from top-left:
        // 1. Top-Left
        // 2. Top-Right
        // 3. Bottom-Right
        // 4. Bottom-Left
        targetPointsLocalCG = [
            ("Top-Left (Point 1/4)", CGPoint(x: inset, y: inset)),
            ("Top-Right (Point 2/4)", CGPoint(x: w - inset, y: inset)),
            ("Bottom-Right (Point 3/4)", CGPoint(x: w - inset, y: h - inset)),
            ("Bottom-Left (Point 4/4)", CGPoint(x: inset, y: h - inset))
        ]
        currentPointIndex = 0
        capturedPoints.removeAll()
        statusMessage = "Touch and release \(targetPointsLocalCG[0].label)"
    }
    
    public func handleTouchSample(_ sample: TouchSample) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.currentPointIndex < self.targetPointsLocalCG.count else { return }
            
            print("[CALIBRATION TOUCH] Phase=\(sample.phase.rawValue) Raw=(\(sample.rawX), \(sample.rawY)) Norm=(u: \(String(format: "%.3f", sample.normX)), v: \(String(format: "%.3f", sample.normY)))")
            
            switch sample.phase {
            case .down:
                self.isTouchingCurrentPoint = true
                self.activeTouchSamples = [sample]
                self.statusMessage = "Point #\(self.currentPointIndex + 1): Touching... Lift finger to confirm"
                self.needsDisplay = true
                
            case .move:
                if self.isTouchingCurrentPoint {
                    self.activeTouchSamples.append(sample)
                    self.needsDisplay = true
                }
                
            case .up:
                if self.isTouchingCurrentPoint && !self.activeTouchSamples.isEmpty {
                    self.isTouchingCurrentPoint = false
                    self.confirmCurrentPoint()
                }
            }
        }
    }
    
    private func confirmCurrentPoint() {
        guard currentPointIndex < targetPointsLocalCG.count else { return }
        let currentTarget = targetPointsLocalCG[currentPointIndex]
        
        // Compute average/median stable raw coordinates during this touch
        let count = activeTouchSamples.count
        let sumRawX = activeTouchSamples.reduce(0) { $0 + $1.rawX }
        let sumRawY = activeTouchSamples.reduce(0) { $0 + $1.rawY }
        let avgRawX = sumRawX / count
        let avgRawY = sumRawY / count
        
        let sumNormX = activeTouchSamples.reduce(0.0) { $0 + $1.normX }
        let sumNormY = activeTouchSamples.reduce(0.0) { $0 + $1.normY }
        let avgNormX = sumNormX / Double(count)
        let avgNormY = sumNormY / Double(count)
        
        let rawPt = RawHIDPoint(x: avgRawX, y: avgRawY)
        let normPt = NormalizedSensorPoint(u: avgNormX, v: avgNormY)
        
        let pair = CalibrationPointPair(
            label: currentTarget.label,
            targetLocalCG: currentTarget.pt,
            rawSensor: rawPt,
            normalizedSensor: normPt
        )
        capturedPoints.append(pair)
        
        NSSound.beep()
        
        print("\n[CALIBRATION] Captured \(currentTarget.label):")
        print("  - Target Local CG: (\(Int(currentTarget.pt.x)), \(Int(currentTarget.pt.y)))")
        print("  - Raw HID Sensor:  (\(avgRawX), \(avgRawY)) [samples: \(count)]")
        print("  - Norm Sensor:     (u: \(String(format: "%.4f", avgNormX)), v: \(String(format: "%.4f", avgNormY)))")
        
        currentPointIndex += 1
        activeTouchSamples.removeAll()
        
        if currentPointIndex < targetPointsLocalCG.count {
            statusMessage = "Touch and release \(targetPointsLocalCG[currentPointIndex].label)"
            needsDisplay = true
        } else {
            // All 4 points captured! Solve transform
            solveAndComplete()
        }
    }
    
    private func solveAndComplete() {
        statusMessage = "Solving 4-point calibration transform..."
        needsDisplay = true
        
        guard let fit = AffineMatrix2D.solveLeastSquares(points: capturedPoints) else {
            statusMessage = "[ERROR] Failed to solve calibration. Determinant error."
            needsDisplay = true
            return
        }
        
        print("\n=======================================================")
        print("           CALIBRATION FIT RESULTS (AFFINE)            ")
        print("=======================================================")
        print(fit.matrix.description)
        print("Residual Errors per point:")
        for (i, r) in fit.residuals.enumerated() {
            print(String(format: "  Point %d [%-24@]: residual = %6.2f pt", i + 1, capturedPoints[i].label, r))
        }
        print(String(format: "Mean Residual Error: %.2f pt", fit.meanResidual))
        print(String(format: "Max Residual Error:  %.2f pt", fit.maxResidual))
        print("=======================================================\n")
        
        let profile = CalibrationProfile(
            version: 1,
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
            points: capturedPoints,
            transformType: "affine",
            affineMatrix: fit.matrix,
            homographyMatrix: nil,
            residualErrors: fit.residuals,
            meanResidualError: fit.meanResidual,
            maxResidualError: fit.maxResidual
        )
        
        // Save profile
        let saveURL = CalibrationProfile.defaultProfileURL(for: targetDisplay.id)
        do {
            try profile.save(to: saveURL)
            print("[INFO] Saved calibration profile to: \(saveURL.path)")
            
            // Also save in current working directory for immediate inspection
            let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TouchBridgeCalibration.json")
            try profile.save(to: cwdURL)
            print("[INFO] Saved local calibration copy to: \(cwdURL.path)")
        } catch {
            print("[WARNING] Failed to save profile to disk: \(error)")
        }
        
        delegate?.calibrationDidComplete(profile: profile)
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        let w = bounds.width
        let h = bounds.height
        
        // 1. Draw subtle background coordinate grid
        ctx.setStrokeColor(NSColor(white: 0.15, alpha: 1.0).cgColor)
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
        
        // 2. Draw Title Header
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let subAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor(white: 0.7, alpha: 1.0)
        ]
        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: isTouchingCurrentPoint ? NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0) : NSColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1.0)
        ]
        
        let title = "TouchBridge — Native Calibration"
        let subtitle = "Target Display: \(targetDisplay.name) (#\(targetDisplay.id)) [\(Int(w))x\(Int(h)) pt]"
        
        (title as NSString).draw(at: CGPoint(x: 40, y: 35), withAttributes: titleAttributes)
        (subtitle as NSString).draw(at: CGPoint(x: 40, y: 65), withAttributes: subAttributes)
        (statusMessage as NSString).draw(at: CGPoint(x: 40, y: 92), withAttributes: statusAttributes)
        
        // 3. Draw already captured points (with green completed circles)
        for pt in capturedPoints {
            let p = pt.targetLocalCG
            ctx.setFillColor(NSColor(red: 0.15, green: 0.8, blue: 0.35, alpha: 0.25).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48))
            
            ctx.setStrokeColor(NSColor(red: 0.15, green: 0.8, blue: 0.35, alpha: 1.0).cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48))
            
            // Checkmark
            ctx.setLineWidth(3.0)
            ctx.move(to: CGPoint(x: p.x - 8, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x - 2, y: p.y + 6))
            ctx.addLine(to: CGPoint(x: p.x + 8, y: p.y - 6))
            ctx.strokePath()
        }
        
        // 4. Draw active target crosshair
        if currentPointIndex < targetPointsLocalCG.count {
            let active = targetPointsLocalCG[currentPointIndex]
            let p = active.pt
            
            let color = isTouchingCurrentPoint ? NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0) : NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
            
            // Outer pulsing ring
            let ringRadius: CGFloat = isTouchingCurrentPoint ? 36.0 : 30.0
            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - ringRadius, y: p.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - ringRadius, y: p.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            
            // Center crosshair lines
            let armLen: CGFloat = 20.0
            ctx.setLineWidth(2.0)
            ctx.move(to: CGPoint(x: p.x - armLen, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x + armLen, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - armLen))
            ctx.addLine(to: CGPoint(x: p.x, y: p.y + armLen))
            ctx.strokePath()
            
            // Center bullseye dot
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            
            // Target label callout
            let calloutAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let labelX = (p.x < w / 2) ? p.x + 40 : p.x - 170
            let labelY = (p.y < h / 2) ? p.y + 10 : p.y - 25
            (active.label as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: calloutAttributes)
        }
    }
}
