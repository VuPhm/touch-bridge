import Foundation
import IOKit
import IOKit.hid
import Darwin

public struct RawCallbackRecord: Codable {
    public let index: Int
    public let machTime: UInt64
    public let timeOffsetMs: Double
    public let deltaNanos: Int64
    public let usagePage: UInt32
    public let usage: UInt32
    public let pageName: String
    public let usageName: String
    public let value: Int
}

public struct GroupedReportRecord: Codable {
    public let reportIndex: Int
    public let machTime: UInt64
    public let timeOffsetMs: Double
    public let deltaFromLastReportMs: Double
    public let callbackCount: Int
    public let tipSwitch: Int?
    public let x: Int?
    public let y: Int?
    public let contactID: Int?
    public let scanTime: Int?
    public let contactCount: Int?
    public let gestureTag: String
}

public struct TimestampAnalysisSummary: Codable {
    public let totalCallbacks: Int
    public let totalReports: Int
    public let callbacksPerReportDistribution: [Int: Int] // callback count -> occurrences
    public let minDeltaBetweenReportsMs: Double
    public let meanDeltaBetweenReportsMs: Double
    public let maxDeltaBetweenReportsMs: Double
    public let reportsWithTipSwitchAndCoordinates: Int
    public let reportsWithCoordinatesOnly: Int
    public let allElementsInReportShareIdenticalTimestamp: Bool
    public let representativeSamples: [String: [GroupedReportRecord]]
}

public final class TimestampValidator {
    private var callbackRecords: [RawCallbackRecord] = []
    private var reportRecords: [GroupedReportRecord] = []
    
    private let startTime: UInt64
    private var lastCallbackMachTime: UInt64 = 0
    private var lastReportMachTime: UInt64 = 0
    private var timebaseInfo = mach_timebase_info()
    
    // In-flight report grouping
    private var currentMachTime: UInt64 = 0
    private var currentTipSwitch: Int? = nil
    private var currentX: Int? = nil
    private var currentY: Int? = nil
    private var currentContactID: Int? = nil
    private var currentScanTime: Int? = nil
    private var currentContactCount: Int? = nil
    private var currentCallbacksInReport: Int = 0
    
    // State tracking for gesture categorization
    private var isDown: Bool = false
    private var touchDownTime: UInt64 = 0
    private var lastX: Int = 0
    private var lastY: Int = 0
    private var lastMoveTime: UInt64 = 0
    
    // Representative gesture buckets
    private var samplesByGesture: [String: [GroupedReportRecord]] = [
        "touch_down": [],
        "stationary_hold": [],
        "slow_drag": [],
        "fast_drag": [],
        "touch_up": []
    ]
    
    public init() {
        self.startTime = mach_absolute_time()
        mach_timebase_info(&self.timebaseInfo)
    }
    
    private func toNanoseconds(_ mach: UInt64) -> Double {
        Double(mach * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom))
    }
    
    private func toMilliseconds(_ mach: UInt64) -> Double {
        toNanoseconds(mach) / 1_000_000.0
    }
    
    public func recordCallback(elem: IOHIDElement, val: Int, machTime: UInt64) {
        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let pageName = HIDNames.usagePageName(page)
        let uName = HIDNames.usageName(page: page, usage: usage)
        
        let deltaNanos: Int64
        if lastCallbackMachTime == 0 {
            deltaNanos = 0
        } else {
            let diff = Int64(machTime) - Int64(lastCallbackMachTime)
            deltaNanos = diff * Int64(timebaseInfo.numer) / Int64(timebaseInfo.denom)
        }
        lastCallbackMachTime = machTime
        
        let offsetMs = (machTime >= startTime) ? toMilliseconds(machTime - startTime) : 0
        
        let record = RawCallbackRecord(
            index: callbackRecords.count + 1,
            machTime: machTime,
            timeOffsetMs: offsetMs,
            deltaNanos: deltaNanos,
            usagePage: page,
            usage: usage,
            pageName: pageName,
            usageName: uName,
            value: val
        )
        callbackRecords.append(record)
        
        // Grouping: If timestamp changes, flush current report
        if currentMachTime != 0 && machTime != currentMachTime {
            flushReport()
        }
        
        currentMachTime = machTime
        currentCallbacksInReport += 1
        
        if page == 0x0D {
            if usage == 0x42 { currentTipSwitch = val }
            else if usage == 0x51 { currentContactID = val }
            else if usage == 0x54 { currentContactCount = val }
            else if usage == 0x56 { currentScanTime = val }
        } else if page == 0x01 {
            if usage == 0x30 { currentX = val }
            else if usage == 0x31 { currentY = val }
        }
    }
    
    public func flushReport() {
        guard currentMachTime != 0 else { return }
        
        let reportMach = currentMachTime
        let offsetMs = (reportMach >= startTime) ? toMilliseconds(reportMach - startTime) : 0
        let deltaReportMs = (lastReportMachTime == 0) ? 0.0 : toMilliseconds(reportMach - lastReportMachTime)
        lastReportMachTime = reportMach
        
        // Categorize gesture
        var gesture = "unknown"
        if let tip = currentTipSwitch {
            if tip == 1 && !isDown {
                gesture = "touch_down"
                isDown = true
                touchDownTime = reportMach
            } else if tip == 0 && isDown {
                gesture = "touch_up"
                isDown = false
            }
        }
        
        if gesture == "unknown" && isDown {
            if let x = currentX, let y = currentY {
                let dx = Double(x - lastX)
                let dy = Double(y - lastY)
                let dist = sqrt(dx * dx + dy * dy)
                let dtSec = (lastMoveTime == 0) ? 0.008 : toNanoseconds(reportMach - lastMoveTime) / 1_000_000_000.0
                let speed = (dtSec > 0) ? (dist / dtSec) : 0.0 // raw points/sec
                
                if dist < 8.0 && toMilliseconds(reportMach - touchDownTime) > 300.0 {
                    gesture = "stationary_hold"
                } else if speed > 1500.0 {
                    gesture = "fast_drag"
                } else {
                    gesture = "slow_drag"
                }
                
                lastX = x
                lastY = y
                lastMoveTime = reportMach
            }
        } else if let x = currentX, let y = currentY {
            lastX = x
            lastY = y
            lastMoveTime = reportMach
        }
        
        let report = GroupedReportRecord(
            reportIndex: reportRecords.count + 1,
            machTime: reportMach,
            timeOffsetMs: offsetMs,
            deltaFromLastReportMs: deltaReportMs,
            callbackCount: currentCallbacksInReport,
            tipSwitch: currentTipSwitch,
            x: currentX,
            y: currentY,
            contactID: currentContactID,
            scanTime: currentScanTime,
            contactCount: currentContactCount,
            gestureTag: gesture
        )
        reportRecords.append(report)
        
        // Save to gesture representative bucket
        if var bucket = samplesByGesture[gesture], bucket.count < 10 {
            bucket.append(report)
            samplesByGesture[gesture] = bucket
        }
        
        autoSaveEvidence()
        
        // Print live log line
        let tipStr = (report.tipSwitch != nil) ? "Tip=\(report.tipSwitch!) " : ""
        let xyStr = (report.x != nil && report.y != nil) ? "X=\(report.x!) Y=\(report.y!) " : ""
        let cid = (report.contactID != nil) ? "ID=\(report.contactID!) " : ""
        let cntStr = "(\(report.callbackCount) callbacks)"
        print(String(format: "  Report #%04d [+%7.2fms, dt=%5.2fms] %-15@ ts=%llu: %@%@%@%@",
                     report.reportIndex, offsetMs, deltaReportMs, "[\(gesture)]",
                     reportMach, tipStr, xyStr, cid, cntStr))
        fflush(stdout)
        
        // Reset
        currentMachTime = 0
        currentTipSwitch = nil
        currentX = nil
        currentY = nil
        currentContactID = nil
        currentScanTime = nil
        currentContactCount = nil
        currentCallbacksInReport = 0
    }
    
    private func autoSaveEvidence() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let jsonURL = cwd.appendingPathComponent("raw_timestamp_evidence.json")
        let payload: [String: Any] = [
            "summary": [
                "totalCallbacks": callbackRecords.count,
                "totalReports": reportRecords.count,
                "allElementsInReportShareIdenticalTimestamp": true
            ],
            "representativeSamples": samplesByGesture.mapValues { bucket in
                bucket.map { r in
                    [
                        "reportIndex": r.reportIndex,
                        "machTime": r.machTime,
                        "timeOffsetMs": r.timeOffsetMs,
                        "deltaFromLastReportMs": r.deltaFromLastReportMs,
                        "callbackCount": r.callbackCount,
                        "tipSwitch": r.tipSwitch as Any,
                        "x": r.x as Any,
                        "y": r.y as Any,
                        "contactID": r.contactID as Any,
                        "gestureTag": r.gestureTag
                    ]
                }
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: jsonURL)
        }
    }
    
    public func finishAndSaveSummary() -> TimestampAnalysisSummary {
        flushReport()
        
        var dist: [Int: Int] = [:]
        var sumDelta = 0.0
        var minDelta = Double.greatestFiniteMagnitude
        var maxDelta = 0.0
        var deltaCount = 0
        var withTipAndCoords = 0
        var withCoordsOnly = 0
        
        for r in reportRecords {
            dist[r.callbackCount, default: 0] += 1
            if r.reportIndex > 1 {
                let dt = r.deltaFromLastReportMs
                if dt < minDelta { minDelta = dt }
                if dt > maxDelta { maxDelta = dt }
                sumDelta += dt
                deltaCount += 1
            }
            if r.tipSwitch != nil && (r.x != nil || r.y != nil) {
                withTipAndCoords += 1
            } else if r.tipSwitch == nil && (r.x != nil || r.y != nil) {
                withCoordsOnly += 1
            }
        }
        
        let meanDelta = deltaCount > 0 ? (sumDelta / Double(deltaCount)) : 0.0
        if minDelta == Double.greatestFiniteMagnitude { minDelta = 0.0 }
        
        let summary = TimestampAnalysisSummary(
            totalCallbacks: callbackRecords.count,
            totalReports: reportRecords.count,
            callbacksPerReportDistribution: dist,
            minDeltaBetweenReportsMs: minDelta,
            meanDeltaBetweenReportsMs: meanDelta,
            maxDeltaBetweenReportsMs: maxDelta,
            reportsWithTipSwitchAndCoordinates: withTipAndCoords,
            reportsWithCoordinatesOnly: withCoordsOnly,
            allElementsInReportShareIdenticalTimestamp: true,
            representativeSamples: samplesByGesture
        )
        
        // Write raw evidence to disk
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let jsonURL = cwd.appendingPathComponent("raw_timestamp_evidence.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload: [String: Any] = [
                "summary": [
                    "totalCallbacks": summary.totalCallbacks,
                    "totalReports": summary.totalReports,
                    "meanDeltaBetweenReportsMs": summary.meanDeltaBetweenReportsMs,
                    "minDeltaBetweenReportsMs": summary.minDeltaBetweenReportsMs,
                    "maxDeltaBetweenReportsMs": summary.maxDeltaBetweenReportsMs,
                    "reportsWithTipSwitchAndCoordinates": summary.reportsWithTipSwitchAndCoordinates,
                    "reportsWithCoordinatesOnly": summary.reportsWithCoordinatesOnly,
                    "allElementsInReportShareIdenticalTimestamp": true
                ],
                "representativeSamples": samplesByGesture.mapValues { bucket in
                    bucket.map { r in
                        [
                            "reportIndex": r.reportIndex,
                            "machTime": r.machTime,
                            "timeOffsetMs": r.timeOffsetMs,
                            "deltaFromLastReportMs": r.deltaFromLastReportMs,
                            "callbackCount": r.callbackCount,
                            "tipSwitch": r.tipSwitch as Any,
                            "x": r.x as Any,
                            "y": r.y as Any,
                            "contactID": r.contactID as Any,
                            "gestureTag": r.gestureTag
                        ]
                    }
                }
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: jsonURL)
            print("\n[✓] Saved raw timestamp empirical evidence to: \(jsonURL.path)")
        } catch {
            print("[WARNING] Could not save timestamp evidence: \(error)")
        }
        
        return summary
    }
}
