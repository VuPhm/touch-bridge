import Foundation
import CoreGraphics

public struct CalibrationPointPair: Codable, Equatable {
    public let label: String
    public let targetLocalCG: CGPoint      // Target in Display Local CG points (Top-Left origin)
    public let rawSensor: RawHIDPoint       // Captured raw HID coordinate
    public let normalizedSensor: NormalizedSensorPoint // Normalized sensor coordinate [0..1]
    
    public init(label: String, targetLocalCG: CGPoint, rawSensor: RawHIDPoint, normalizedSensor: NormalizedSensorPoint) {
        self.label = label
        self.targetLocalCG = targetLocalCG
        self.rawSensor = rawSensor
        self.normalizedSensor = normalizedSensor
    }
}

/// 2D Affine Transform Matrix:
/// X = a*u + b*v + tx
/// Y = c*u + d*v + ty
public struct AffineMatrix2D: Codable, CustomStringConvertible, Equatable {
    public let a: Double
    public let b: Double
    public let tx: Double
    public let c: Double
    public let d: Double
    public let ty: Double
    
    public init(a: Double, b: Double, tx: Double, c: Double, d: Double, ty: Double) {
        self.a = a
        self.b = b
        self.tx = tx
        self.c = c
        self.d = d
        self.ty = ty
    }
    
    public var description: String {
        String(format: "AffineMatrix2D:\n  X = %8.3f*u + %8.3f*v + %8.3f\n  Y = %8.3f*u + %8.3f*v + %8.3f",
               a, b, tx, c, d, ty)
    }
    
    public func transform(u: Double, v: Double) -> CGPoint {
        let x = a * u + b * v + tx
        let y = c * u + d * v + ty
        return CGPoint(x: x, y: y)
    }
    
    /// Solves linear least-squares affine fit from N >= 3 points.
    /// A = [u_i, v_i, 1]
    /// (A^T * A) * p = A^T * b
    public static func solveLeastSquares(points: [CalibrationPointPair]) -> (matrix: AffineMatrix2D, residuals: [Double], maxResidual: Double, meanResidual: Double)? {
        guard points.count >= 3 else { return nil }
        
        // Build 3x3 normal equation matrix: M = A^T * A
        var m00 = 0.0, m01 = 0.0, m02 = 0.0
        var m10 = 0.0, m11 = 0.0, m12 = 0.0
        var m20 = 0.0, m21 = 0.0, m22 = 0.0
        
        var bx0 = 0.0, bx1 = 0.0, bx2 = 0.0
        var by0 = 0.0, by1 = 0.0, by2 = 0.0
        
        for pt in points {
            let u = pt.normalizedSensor.u
            let v = pt.normalizedSensor.v
            let x = Double(pt.targetLocalCG.x)
            let y = Double(pt.targetLocalCG.y)
            
            m00 += u * u;     m01 += u * v;     m02 += u
            m10 += v * u;     m11 += v * v;     m12 += v
            m20 += 1.0 * u;   m21 += 1.0 * v;   m22 += 1.0
            
            bx0 += u * x;     bx1 += v * x;     bx2 += x
            by0 += u * y;     by1 += v * y;     by2 += y
        }
        
        // Invert 3x3 matrix M:
        let det = m00 * (m11 * m22 - m12 * m21) -
                  m01 * (m10 * m22 - m12 * m20) +
                  m02 * (m10 * m21 - m11 * m20)
        
        guard abs(det) > 1e-9 else {
            print("[ERROR] Affine determinant near zero: \(det)")
            return nil
        }
        
        let invDet = 1.0 / det
        
        let inv00 = (m11 * m22 - m12 * m21) * invDet
        let inv01 = (m02 * m21 - m01 * m22) * invDet
        let inv02 = (m01 * m12 - m02 * m11) * invDet
        
        let inv10 = (m12 * m20 - m10 * m22) * invDet
        let inv11 = (m00 * m22 - m02 * m20) * invDet
        let inv12 = (m02 * m10 - m00 * m12) * invDet
        
        let inv20 = (m10 * m21 - m11 * m20) * invDet
        let inv21 = (m01 * m20 - m00 * m21) * invDet
        let inv22 = (m00 * m11 - m01 * m10) * invDet
        
        // Solve for [a, b, tx]
        let a  = inv00 * bx0 + inv01 * bx1 + inv02 * bx2
        let b  = inv10 * bx0 + inv11 * bx1 + inv12 * bx2
        let tx = inv20 * bx0 + inv21 * bx1 + inv22 * bx2
        
        // Solve for [c, d, ty]
        let c  = inv00 * by0 + inv01 * by1 + inv02 * by2
        let d  = inv10 * by0 + inv11 * by1 + inv12 * by2
        let ty = inv20 * by0 + inv21 * by1 + inv22 * by2
        
        let matrix = AffineMatrix2D(a: a, b: b, tx: tx, c: c, d: d, ty: ty)
        
        // Calculate residuals
        var residuals: [Double] = []
        var sumResiduals = 0.0
        var maxResidual = 0.0
        
        for pt in points {
            let pred = matrix.transform(u: pt.normalizedSensor.u, v: pt.normalizedSensor.v)
            let dx = pred.x - pt.targetLocalCG.x
            let dy = pred.y - pt.targetLocalCG.y
            let dist = sqrt(dx * dx + dy * dy)
            residuals.append(dist)
            sumResiduals += dist
            if dist > maxResidual { maxResidual = dist }
        }
        
        let meanResidual = sumResiduals / Double(points.count)
        return (matrix, residuals, maxResidual, meanResidual)
    }
}

/// Fallback 3x3 Projective Homography for non-linear perspective mapping
public struct HomographyMatrix3D: Codable, CustomStringConvertible, Equatable {
    public let h11: Double, h12: Double, h13: Double
    public let h21: Double, h22: Double, h23: Double
    public let h31: Double, h32: Double, h33: Double
    
    public var description: String {
        String(format: "Homography3D:\n  [%8.3f %8.3f %8.3f]\n  [%8.3f %8.3f %8.3f]\n  [%8.3f %8.3f %8.3f]",
               h11, h12, h13, h21, h22, h23, h31, h32, h33)
    }
    
    public func transform(u: Double, v: Double) -> CGPoint {
        let w = h31 * u + h32 * v + h33
        guard abs(w) > 1e-9 else { return CGPoint(x: 0, y: 0) }
        let x = (h11 * u + h12 * v + h13) / w
        let y = (h21 * u + h22 * v + h23) / w
        return CGPoint(x: x, y: y)
    }
}

public struct CalibrationProfile: Codable, Equatable {
    public let version: Int
    public let createdAt: Date
    
    // Bound Device Identity
    public let deviceVendorID: Int
    public let deviceProductID: Int
    public let deviceName: String
    
    // HID Coordinate Ranges
    public var rawMinX: Int?
    public var rawMaxX: Int?
    public var rawMinY: Int?
    public var rawMaxY: Int?
    
    // Bound Display Identity
    public let displayID: CGDirectDisplayID
    public let displayName: String
    public let displayVendorNumber: UInt32
    public let displayModelNumber: UInt32
    public let displaySerialNumber: UInt32
    public let displayWidth: Double
    public let displayHeight: Double
    public let backingScaleFactor: Double
    public let rotationDegrees: Double
    
    // Calibration Measurements
    public let points: [CalibrationPointPair]
    public let transformType: String // "affine" or "homography"
    public let affineMatrix: AffineMatrix2D?
    public let homographyMatrix: HomographyMatrix3D?
    
    // Verification Metrics
    public let residualErrors: [Double]
    public let meanResidualError: Double
    public let maxResidualError: Double
    
    public static var defaultDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".touchbridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    public static func defaultProfileURL(for displayID: CGDirectDisplayID) -> URL {
        defaultDirectory.appendingPathComponent("calibration_display_\(displayID).json")
    }
    
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
    
    public static func load(from url: URL) throws -> CalibrationProfile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CalibrationProfile.self, from: data)
    }
    
    /// Map normalized sensor point [0..1] directly into Space D (Target Display Local Coordinates)
    public func mapToDisplayLocal(sensor: NormalizedSensorPoint) -> DisplayLocalPoint {
        let localCG: CGPoint
        if let affine = affineMatrix {
            localCG = affine.transform(u: sensor.u, v: sensor.v)
        } else if let homo = homographyMatrix {
            localCG = homo.transform(u: sensor.u, v: sensor.v)
        } else {
            // Identity fallback (uncalibrated)
            localCG = CGPoint(x: sensor.u * displayWidth, y: sensor.v * displayHeight)
        }
        
        let localAppKitY = displayHeight - localCG.y
        let localAppKit = CGPoint(x: localCG.x, y: localAppKitY)
        
        return DisplayLocalPoint(
            cgPoint: localCG,
            appKitPoint: localAppKit,
            displayWidth: displayWidth,
            displayHeight: displayHeight
        )
    }
    
    /// Map normalized sensor point [0..1] into Space C (Calibrated Visible Normalized Coordinates [0..1])
    public func mapToCalibratedVisible(sensor: NormalizedSensorPoint) -> CalibratedVisiblePoint {
        let local = mapToDisplayLocal(sensor: sensor)
        let uVis = local.cgPoint.x / displayWidth
        let vVis = local.cgPoint.y / displayHeight
        return CalibratedVisiblePoint(u: uVis, v: vVis)
    }
    
    /// Validates if this calibration profile is still valid for the active display hardware state.
    public func isStale(for display: DisplayMetadata) -> (stale: Bool, reason: String?) {
        if display.id != self.displayID {
            return (true, "Display ID mismatch: profile has #\(self.displayID), active is #\(display.id)")
        }
        if abs(display.cgWidth - self.displayWidth) > 1.0 || abs(display.cgHeight - self.displayHeight) > 1.0 {
            return (true, "Display resolution changed: profile was \(Int(self.displayWidth))x\(Int(self.displayHeight)), active is \(Int(display.cgWidth))x\(Int(display.cgHeight))")
        }
        if abs(display.rotationDegrees - self.rotationDegrees) > 0.1 {
            return (true, "Display orientation changed: profile was \(self.rotationDegrees)°, active is \(display.rotationDegrees)°")
        }
        if abs(display.backingScaleFactor - self.backingScaleFactor) > 0.01 {
            return (true, "Backing scale factor changed: profile was \(self.backingScaleFactor), active is \(display.backingScaleFactor)")
        }
        return (false, nil)
    }
}
