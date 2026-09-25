import Foundation
import Cocoa
import CoreGraphics

public struct VerificationTarget {
    public let id: String
    public let label: String
    public let pointLocalCG: CGPoint
    public var observedTouchLocalCG: CGPoint? = nil
    public var observedErrorPt: Double? = nil
    public var isVerified: Bool { observedTouchLocalCG != nil }
}

public final class DiagnosticView: NSView {
    public override var isFlipped: Bool { true } // Top-Left origin matches CoreGraphics local space
    
    private let targetDisplay: DisplayMetadata
    private let profile: CalibrationProfile
    
    // Test Verification Targets
    private var verificationTargets: [VerificationTarget] = []
    
    // Live Touch State
    private var currentSample: TouchSample? = nil
    private var mappedLocalPoint: DisplayLocalPoint? = nil
    private var isTouchDown: Bool = false
    private var touchTrail: [CGPoint] = []
    
    // System Cursor Verification State
    private var initialCursorPos: CGPoint = .zero
    private var currentCursorPos: CGPoint = .zero
    private var cursorHasMovedDuringTouch: Bool = false
    private var cursorPollTimer: Timer?
    
    // Status / Log
    private var lastObservedTargetLog: String = "Ready for physical verification tests."
    
    public init(frame: NSRect, display: DisplayMetadata, profile: CalibrationProfile) {
        self.targetDisplay = display
        self.profile = profile
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        
        setupTargets()
        startCursorMonitoring()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    deinit {
        cursorPollTimer?.invalidate()
    }
    
    private func setupTargets() {
        let w = Double(bounds.width)
        let h = Double(bounds.height)
        let margin: Double = 64.0
        
        verificationTargets = [
            // Four Corners
            VerificationTarget(id: "TL", label: "Corner: Top-Left", pointLocalCG: CGPoint(x: margin, y: margin)),
            VerificationTarget(id: "TR", label: "Corner: Top-Right", pointLocalCG: CGPoint(x: w - margin, y: margin)),
            VerificationTarget(id: "BR", label: "Corner: Bottom-Right", pointLocalCG: CGPoint(x: w - margin, y: h - margin)),
            VerificationTarget(id: "BL", label: "Corner: Bottom-Left", pointLocalCG: CGPoint(x: margin, y: h - margin)),
            
            // Center
            VerificationTarget(id: "CTR", label: "Center Target", pointLocalCG: CGPoint(x: w / 2, y: h / 2)),
            
            // Edge Points
            VerificationTarget(id: "ET", label: "Edge: Top", pointLocalCG: CGPoint(x: w / 2, y: margin)),
            VerificationTarget(id: "EB", label: "Edge: Bottom", pointLocalCG: CGPoint(x: w / 2, y: h - margin)),
            VerificationTarget(id: "EL", label: "Edge: Left", pointLocalCG: CGPoint(x: margin, y: h / 2)),
            VerificationTarget(id: "ER", label: "Edge: Right", pointLocalCG: CGPoint(x: w - margin, y: h / 2)),
            
            // Diagonal Reference
            VerificationTarget(id: "DIAG", label: "Diagonal Drag", pointLocalCG: CGPoint(x: w * 0.75, y: h * 0.75))
        ]
    }
    
    private func startCursorMonitoring() {
        let initialLoc = NSEvent.mouseLocation
        self.initialCursorPos = CGPoint(x: initialLoc.x, y: initialLoc.y)
        self.currentCursorPos = self.initialCursorPos
        
        // Poll cursor periodically to prove system cursor is completely untouched
        cursorPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            let p = CGPoint(x: loc.x, y: loc.y)
            self.currentCursorPos = p
            if self.isTouchDown {
                let dx = p.x - self.initialCursorPos.x
                let dy = p.y - self.initialCursorPos.y
                if sqrt(dx * dx + dy * dy) > 2.0 {
                    self.cursorHasMovedDuringTouch = true
                }
            } else {
                self.initialCursorPos = p
            }
            self.needsDisplay = true
        }
    }
    
    public func handleTouchSample(_ sample: TouchSample) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentSample = sample
            
            // Calibrate: Map normalized sensor point into target display local space
            let localPt = self.profile.mapToDisplayLocal(sensor: sample.normalizedSensorPoint)
            self.mappedLocalPoint = localPt
            
            switch sample.phase {
            case .down:
                self.isTouchDown = true
                self.touchTrail = [localPt.cgPoint]
                self.checkTargetProximity(touchCG: localPt.cgPoint)
                
            case .move:
                if self.isTouchDown {
                    self.touchTrail.append(localPt.cgPoint)
                    if self.touchTrail.count > 150 {
                        self.touchTrail.removeFirst(self.touchTrail.count - 150)
                    }
                    self.checkTargetProximity(touchCG: localPt.cgPoint)
                }
                
            case .up:
                self.isTouchDown = false
                self.checkTargetProximity(touchCG: localPt.cgPoint)
            }
            
            self.needsDisplay = true
        }
    }
    
    private func checkTargetProximity(touchCG: CGPoint) {
        let captureRadius: CGFloat = 80.0
        
        for i in 0..<verificationTargets.count {
            let target = verificationTargets[i]
            let dx = touchCG.x - target.pointLocalCG.x
            let dy = touchCG.y - target.pointLocalCG.y
            let dist = sqrt(dx * dx + dy * dy)
            
            if dist <= captureRadius {
                // If this is the best (closest) touch seen for this target, record it
                let currentBest = target.observedErrorPt ?? Double.greatestFiniteMagnitude
                if Double(dist) < currentBest {
                    verificationTargets[i].observedTouchLocalCG = touchCG
                    verificationTargets[i].observedErrorPt = Double(dist)
                    
                    let errX = touchCG.x - target.pointLocalCG.x
                    let errY = touchCG.y - target.pointLocalCG.y
                    let msg = String(format: "[VERIFIED] %@: Touch @ (%.1f, %.1f), Target @ (%.1f, %.1f), Error = %.2f pt (dx: %+.1f, dy: %+.1f)",
                                     target.label, touchCG.x, touchCG.y, target.pointLocalCG.x, target.pointLocalCG.y, dist, errX, errY)
                    print(msg)
                    lastObservedTargetLog = msg
                    autoSaveResults()
                }
            }
        }
    }
    
    private func autoSaveResults() {
        let summary = getVerificationSummary()
        let reportURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("verification_results.json")
        try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
    }
    
    public func getVerificationSummary() -> [String: Any] {
        var results: [[String: Any]] = []
        var totalError = 0.0
        var maxError = 0.0
        var verifiedCount = 0
        
        var cornerErrors: [Double] = []
        var edgeErrors: [Double] = []
        var centerError: Double? = nil
        
        for t in verificationTargets {
            var item: [String: Any] = [
                "id": t.id,
                "label": t.label,
                "targetX": t.pointLocalCG.x,
                "targetY": t.pointLocalCG.y,
                "verified": t.isVerified
            ]
            if let touch = t.observedTouchLocalCG, let err = t.observedErrorPt {
                let dx = touch.x - t.pointLocalCG.x
                let dy = touch.y - t.pointLocalCG.y
                item["observedX"] = touch.x
                item["observedY"] = touch.y
                item["errorPt"] = err
                item["errorX"] = dx
                item["errorY"] = dy
                
                totalError += err
                if err > maxError { maxError = err }
                verifiedCount += 1
                
                if t.id.hasPrefix("T") || t.id.hasPrefix("B") {
                    if t.id == "TL" || t.id == "TR" || t.id == "BL" || t.id == "BR" {
                        cornerErrors.append(err)
                    } else if t.id.hasPrefix("E") {
                        edgeErrors.append(err)
                    }
                } else if t.id == "CTR" {
                    centerError = err
                } else if t.id.hasPrefix("E") {
                    edgeErrors.append(err)
                }
            }
            results.append(item)
        }
        
        let avgError = verifiedCount > 0 ? (totalError / Double(verifiedCount)) : 0.0
        let avgCorner = !cornerErrors.isEmpty ? (cornerErrors.reduce(0, +) / Double(cornerErrors.count)) : 0.0
        let maxCorner = cornerErrors.max() ?? 0.0
        let avgEdge = !edgeErrors.isEmpty ? (edgeErrors.reduce(0, +) / Double(edgeErrors.count)) : 0.0
        let maxEdge = edgeErrors.max() ?? 0.0
        
        // Diagonal drag analysis:
        // Ideal line from (64, 64) to (W-64, H-64)
        var diagonalDeviationSum = 0.0
        var diagonalMaxDeviation = 0.0
        var diagonalSampleCount = 0
        let w = Double(bounds.width)
        let h = Double(bounds.height)
        let x1 = 64.0, y1 = 64.0
        let x2 = w - 64.0, y2 = h - 64.0
        let lineLength = sqrt((x2 - x1)*(x2 - x1) + (y2 - y1)*(y2 - y1))
        
        for pt in touchTrail {
            let px = Double(pt.x)
            let py = Double(pt.y)
            if px >= 64.0 && px <= w - 64.0 && py >= 64.0 && py <= h - 64.0 {
                // Perpendicular distance from point to line (x1, y1)-(x2, y2)
                let num = abs((y2 - y1)*px - (x2 - x1)*py + x2*y1 - y2*x1)
                let perpDist = num / lineLength
                if perpDist < 120.0 { // Points following the diagonal gesture
                    diagonalDeviationSum += perpDist
                    if perpDist > diagonalMaxDeviation { diagonalMaxDeviation = perpDist }
                    diagonalSampleCount += 1
                }
            }
        }
        
        let diagonalMeanDev = diagonalSampleCount > 0 ? (diagonalDeviationSum / Double(diagonalSampleCount)) : 0.0
        
        return [
            "targetDisplayID": targetDisplay.id,
            "targetDisplayName": targetDisplay.name,
            "displayBounds": "\(Int(bounds.width))x\(Int(bounds.height))",
            "targets": results,
            "verifiedCount": verifiedCount,
            "totalTargets": verificationTargets.count,
            "averageErrorPt": avgError,
            "maximumErrorPt": maxError,
            "regionalErrors": [
                "corners": [
                    "count": cornerErrors.count,
                    "meanErrorPt": avgCorner,
                    "maxErrorPt": maxCorner
                ],
                "edges": [
                    "count": edgeErrors.count,
                    "meanErrorPt": avgEdge,
                    "maxErrorPt": maxEdge
                ],
                "center": [
                    "errorPt": centerError as Any
                ]
            ],
            "diagonalDrag": [
                "samplesRecorded": diagonalSampleCount,
                "meanPerpendicularErrorPt": diagonalMeanDev,
                "maxPerpendicularErrorPt": diagonalMaxDeviation
            ],
            "cursorRemainedUntouched": !cursorHasMovedDuringTouch
        ]
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        let w = bounds.width
        let h = bounds.height
        
        // 1. Background grid
        ctx.setStrokeColor(NSColor(white: 0.14, alpha: 1.0).cgColor)
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
        
        // 2. Draw Diagonal guideline for drag testing
        ctx.setStrokeColor(NSColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 0.35).cgColor)
        ctx.setLineWidth(2.0)
        ctx.setLineDash(phase: 0, lengths: [8, 6])
        ctx.move(to: CGPoint(x: 64, y: 64))
        ctx.addLine(to: CGPoint(x: w - 64, y: h - 64))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: []) // Reset dash
        
        // 3. Draw Verification Targets
        for target in verificationTargets {
            let p = target.pointLocalCG
            let isVerified = target.isVerified
            
            let strokeColor = isVerified ? NSColor(red: 0.15, green: 0.85, blue: 0.4, alpha: 1.0) : NSColor(red: 0.4, green: 0.65, blue: 0.95, alpha: 0.85)
            let fillColor = isVerified ? NSColor(red: 0.15, green: 0.85, blue: 0.4, alpha: 0.2) : NSColor(red: 0.4, green: 0.65, blue: 0.95, alpha: 0.1)
            
            let r: CGFloat = 20.0
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            
            // Crosshair
            ctx.move(to: CGPoint(x: p.x - 12, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x + 12, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - 12))
            ctx.addLine(to: CGPoint(x: p.x, y: p.y + 12))
            ctx.strokePath()
            
            // Label
            let errStr = isVerified ? String(format: " (%.1f pt)", target.observedErrorPt ?? 0) : ""
            let label = "\(target.label)\(errStr)"
            let labelAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: isVerified ? .bold : .medium),
                .foregroundColor: isVerified ? NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0) : NSColor(white: 0.7, alpha: 1.0)
            ]
            let lx = (p.x < w / 2) ? p.x + 26 : p.x - 140
            let ly = (p.y < h / 2) ? p.y + 6 : p.y - 18
            (label as NSString).draw(at: CGPoint(x: lx, y: ly), withAttributes: labelAttr)
        }
        
        // 4. Draw Touch Drag Trail (when dragging)
        if touchTrail.count > 1 {
            ctx.setStrokeColor(NSColor(red: 1.0, green: 0.6, blue: 0.1, alpha: 0.6).cgColor)
            ctx.setLineWidth(3.0)
            ctx.move(to: touchTrail[0])
            for i in 1..<touchTrail.count {
                ctx.addLine(to: touchTrail[i])
            }
            ctx.strokePath()
        }
        
        // 5. Draw Live Calibrated Touch Marker (Crosshair + Reticle)
        if let local = mappedLocalPoint, isTouchDown {
            let p = local.cgPoint
            
            // Outer Halo
            ctx.setFillColor(NSColor(red: 1.0, green: 0.35, blue: 0.15, alpha: 0.25).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64))
            
            // Target Ring
            ctx.setStrokeColor(NSColor(red: 1.0, green: 0.4, blue: 0.15, alpha: 1.0).cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44))
            
            // Precision Crosshairs
            let crossLen: CGFloat = 32.0
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: p.x - crossLen, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x + crossLen, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - crossLen))
            ctx.addLine(to: CGPoint(x: p.x, y: p.y + crossLen))
            ctx.strokePath()
            
            // Center Core Dot
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        }
        
        // 6. Draw Diagnostic HUD Panel in top-left
        let hudRect = CGRect(x: 24, y: 24, width: 480, height: 165)
        ctx.setFillColor(NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 0.88).cgColor)
        let hudPath = CGPath(roundedRect: hudRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(hudPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor(white: 0.25, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(hudPath)
        ctx.strokePath()
        
        let hudTitleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let hudBodyAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.85, alpha: 1.0)
        ]
        let greenAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        ]
        
        ("TouchBridge P1 — Diagnostic Verification HUD" as NSString).draw(at: CGPoint(x: 36, y: 32), withAttributes: hudTitleAttr)
        
        let rawStr: String
        let normStr: String
        let localStr: String
        let globalStr: String
        
        if let s = currentSample, let loc = mappedLocalPoint {
            rawStr = String(format: "Raw HID: (%4d, %4d) | Phase: %@", s.rawX, s.rawY, s.phase.rawValue)
            normStr = String(format: "Normalized: (u: %.4f, v: %.4f)", s.normX, s.normY)
            localStr = String(format: "Mapped Local CG: [%6.1f, %6.1f] pt", loc.cgPoint.x, loc.cgPoint.y)
            let g = loc.toGlobal(display: targetDisplay)
            globalStr = String(format: "Mapped Global CG: [%6.1f, %6.1f] pt", g.cgGlobal.x, g.cgGlobal.y)
        } else {
            rawStr = "Raw HID: Awaiting touch..."
            normStr = "Normalized: —"
            localStr = "Mapped Local CG: —"
            globalStr = "Mapped Global CG: —"
        }
        
        (rawStr as NSString).draw(at: CGPoint(x: 36, y: 56), withAttributes: hudBodyAttr)
        (normStr as NSString).draw(at: CGPoint(x: 36, y: 74), withAttributes: hudBodyAttr)
        (localStr as NSString).draw(at: CGPoint(x: 36, y: 92), withAttributes: hudBodyAttr)
        (globalStr as NSString).draw(at: CGPoint(x: 36, y: 110), withAttributes: hudBodyAttr)
        
        // System cursor lock indicator
        let cursorStatus = cursorHasMovedDuringTouch ? "CURSOR MOVED! (FAIL)" : "LOCKED / UNTOUCHED (PASS)"
        let cursorColor = cursorHasMovedDuringTouch ? NSColor.red : NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        let cursorAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: cursorColor
        ]
        let cursorLine = String(format: "System Cursor: [%.0f, %.0f] — %@", currentCursorPos.x, currentCursorPos.y, cursorStatus)
        (cursorLine as NSString).draw(at: CGPoint(x: 36, y: 132), withAttributes: cursorAttr)
        
        let verifiedCount = verificationTargets.filter { $0.isVerified }.count
        let checklistStatus = String(format: "Test Progress: %d / %d targets tested", verifiedCount, verificationTargets.count)
        (checklistStatus as NSString).draw(at: CGPoint(x: 36, y: 154), withAttributes: greenAttr)
        
        // 7. Instructions footer
        let footerAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.65, alpha: 1.0)
        ]
        let footer = "Instructions: Touch 4 corners, center, and edges. Perform diagonal drag. Press 'S' to save report, 'R' to recalibrate, 'Q' to quit."
        (footer as NSString).draw(at: CGPoint(x: 24, y: h - 32), withAttributes: footerAttr)
    }
}
