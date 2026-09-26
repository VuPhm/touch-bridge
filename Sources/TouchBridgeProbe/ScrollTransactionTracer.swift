import Foundation
import CoreGraphics
import Cocoa
import ApplicationServices

// MARK: - P3-02 Scroll Transaction Tracer (Section 2 & 6)

public struct ScrollTraceRecord: Codable {
    public let timestamp: String
    public let machTime: UInt64
    public let phase: String
    public let fingerY: Double
    public let fingerDeltaFromStart: Double
    public let axTargetIdentity: String
    public let scrollbarIdentity: String
    public let initialAXValue: Double
    public let requestedAXValue: Double?
    public let scheduledAt: String?
    public let executedAt: String?
    public let requestedValue: Double?
    public let axError: Int32?
    public let axReadbackImmediate: Double?
    public let axReadbackNextRunloop: Double?
    public let valueAtTouchUp: Double?
    public let valueAt20to50ms: Double?
    public let valueAt100ms: Double?
    public let pendingCoalescedWriteCount: Int
}

public final class ScrollSessionTrace {
    public let sessionID: String
    public let applicationName: String
    public let axTargetIdentity: String
    public let scrollbarIdentity: String
    public let initialAXValue: Double
    public let startTimeDate: Date
    public let startGlobalY: Double
    
    public private(set) var records: [ScrollTraceRecord] = []
    public private(set) var coalescedWriteCount: Int = 0
    public private(set) var lastRequestedValue: Double
    public private(set) var lastImmediateReadback: Double? = nil
    
    public var valueAtTouchUp: Double? = nil
    public var valueAt35ms: Double? = nil
    public var valueAt100ms: Double? = nil
    public var classification: String = "PENDING"
    public var finalSummary: String = ""
    
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
    
    public init(
        sessionID: String,
        applicationName: String,
        targetIdentity: String,
        scrollbarIdentity: String,
        initialAXValue: Double,
        startGlobalY: Double
    ) {
        self.sessionID = sessionID
        self.applicationName = applicationName
        self.axTargetIdentity = targetIdentity
        self.scrollbarIdentity = scrollbarIdentity
        self.initialAXValue = initialAXValue
        self.startGlobalY = startGlobalY
        self.startTimeDate = Date()
        self.lastRequestedValue = initialAXValue
    }
    
    public func recordDown(fingerY: Double) {
        append(
            phase: "down",
            fingerY: fingerY,
            requestedAXValue: initialAXValue,
            axReadbackImmediate: initialAXValue
        )
    }
    
    public func recordPanStart(fingerY: Double) {
        append(
            phase: "pan-start",
            fingerY: fingerY,
            requestedAXValue: initialAXValue,
            axReadbackImmediate: initialAXValue
        )
    }
    
    public func recordCoalescedSkip(fingerY: Double, targetValue: Double) {
        coalescedWriteCount += 1
    }
    
    public func recordAXWrite(
        phase: String = "pan-update",
        fingerY: Double,
        scheduledAt: Date,
        executedAt: Date,
        requestedValue: Double,
        error: AXError,
        immediateReadback: Double?
    ) {
        self.lastRequestedValue = requestedValue
        self.lastImmediateReadback = immediateReadback
        
        append(
            phase: phase,
            fingerY: fingerY,
            requestedAXValue: requestedValue,
            scheduledAt: dateFormatter.string(from: scheduledAt),
            executedAt: dateFormatter.string(from: executedAt),
            requestedValue: requestedValue,
            axError: error.rawValue,
            axReadbackImmediate: immediateReadback
        )
    }
    
    public func recordTouchUp(
        fingerY: Double,
        valueObserved: Double?
    ) {
        self.valueAtTouchUp = valueObserved
        append(
            phase: "up",
            fingerY: fingerY,
            requestedAXValue: lastRequestedValue,
            axReadbackImmediate: valueObserved,
            valueAtTouchUp: valueObserved
        )
    }
    
    public func recordPanEnd(fingerY: Double, valueObserved: Double?) {
        append(
            phase: "pan-end",
            fingerY: fingerY,
            requestedAXValue: lastRequestedValue,
            axReadbackImmediate: valueObserved,
            valueAtTouchUp: valueAtTouchUp
        )
    }
    
    public func recordPostUpReadback(delayMs: Int, value: Double?) {
        if delayMs <= 50 {
            self.valueAt35ms = value
        } else {
            self.valueAt100ms = value
            classifyAndSummarize()
        }
        
        append(
            phase: "post-up-\(delayMs)ms",
            fingerY: records.last?.fingerY ?? startGlobalY,
            requestedAXValue: lastRequestedValue,
            axReadbackImmediate: value,
            valueAtTouchUp: valueAtTouchUp,
            valueAt20to50ms: valueAt35ms,
            valueAt100ms: valueAt100ms
        )
    }
    
    private func append(
        phase: String,
        fingerY: Double,
        requestedAXValue: Double? = nil,
        scheduledAt: String? = nil,
        executedAt: String? = nil,
        requestedValue: Double? = nil,
        axError: Int32? = nil,
        axReadbackImmediate: Double? = nil,
        axReadbackNextRunloop: Double? = nil,
        valueAtTouchUp: Double? = nil,
        valueAt20to50ms: Double? = nil,
        valueAt100ms: Double? = nil
    ) {
        let deltaY = fingerY - startGlobalY
        let rec = ScrollTraceRecord(
            timestamp: dateFormatter.string(from: Date()),
            machTime: mach_absolute_time(),
            phase: phase,
            fingerY: fingerY,
            fingerDeltaFromStart: deltaY,
            axTargetIdentity: axTargetIdentity,
            scrollbarIdentity: scrollbarIdentity,
            initialAXValue: initialAXValue,
            requestedAXValue: requestedAXValue,
            scheduledAt: scheduledAt,
            executedAt: executedAt,
            requestedValue: requestedValue,
            axError: axError,
            axReadbackImmediate: axReadbackImmediate,
            axReadbackNextRunloop: axReadbackNextRunloop,
            valueAtTouchUp: valueAtTouchUp,
            valueAt20to50ms: valueAt20to50ms,
            valueAt100ms: valueAt100ms,
            pendingCoalescedWriteCount: coalescedWriteCount
        )
        records.append(rec)
    }
    
    private func classifyAndSummarize() {
        let upVal = valueAtTouchUp ?? lastRequestedValue
        let post100Val = valueAt100ms ?? upVal
        let post35Val = valueAt35ms ?? upVal
        
        // Evaluate direction of gesture:
        let totalDelta = lastRequestedValue - initialAXValue
        
        // Check if post-release drift moves back toward initialAXValue by > 0.015
        let isMovingBack: Bool
        if totalDelta > 0.02 {
            // Pan increased scrollbar: rollback means post-release value DECREASED significantly
            isMovingBack = (lastRequestedValue - post100Val) > 0.015 || (lastRequestedValue - post35Val) > 0.015
        } else if totalDelta < -0.02 {
            // Pan decreased scrollbar: rollback means post-release value INCREASED significantly
            isMovingBack = (post100Val - lastRequestedValue) > 0.015 || (post35Val - lastRequestedValue) > 0.015
        } else {
            isMovingBack = false
        }
        
        if isMovingBack {
            // Determine WHO caused it:
            // Did TouchBridge dispatch a write after .up?
            let writesAfterUp = records.filter { $0.phase.contains("flush") || ($0.phase == "pan-end" && $0.requestedValue != nil) }
            if let lateWrite = writesAfterUp.last, abs((lateWrite.requestedValue ?? 0.0) - post100Val) < 0.01 {
                self.classification = "TOUCHBRIDGE_STALE_WRITE"
            } else {
                self.classification = "APPLICATION_REBOUND"
            }
        } else if abs(totalDelta) < 0.005 && records.count > 5 {
            self.classification = "MAPPING_ERROR"
        } else {
            self.classification = "NORMAL_STABLE"
        }
        
        let report = formatTransactionReport()
        TouchBridgeLogger.info(.semantic, "\n" + report)
        ScrollTransactionTracer.shared.persistTrace(self)
    }
    
    private static func pad(_ str: String, _ width: Int, right: Bool = false) -> String {
        if str.count >= width { return String(str.prefix(width)) }
        let sp = String(repeating: " ", count: width - str.count)
        return right ? (sp + str) : (str + sp)
    }

    public func formatTransactionReport() -> String {
        var s = "================================================================================\n"
        s += "SCROLL TRANSACTION TRACE: [\(sessionID)] on [\(applicationName)]\n"
        s += "Target: \(axTargetIdentity) | Scrollbar: \(scrollbarIdentity)\n"
        s += "Initial AXValue: \(String(format: "%.3f", initialAXValue)) | Last Requested: \(String(format: "%.3f", lastRequestedValue))\n"
        s += "Value at UP: \(valueAtTouchUp.map { String(format: "%.3f", $0) } ?? "N/A") | +35ms: \(valueAt35ms.map { String(format: "%.3f", $0) } ?? "N/A") | +100ms: \(valueAt100ms.map { String(format: "%.3f", $0) } ?? "N/A")\n"
        s += "Coalesced / Skipped writes: \(coalescedWriteCount)\n"
        s += "Classification: [\(classification)]\n"
        s += "--------------------------------------------------------------------------------\n"
        s += "\(ScrollSessionTrace.pad("Timestamp", 12)) | \(ScrollSessionTrace.pad("Phase", 12)) | \(ScrollSessionTrace.pad("FingerY", 8, right: true)) | \(ScrollSessionTrace.pad("DeltaY", 8, right: true)) | \(ScrollSessionTrace.pad("ReqVal", 8, right: true)) | \(ScrollSessionTrace.pad("AXWrite", 8, right: true)) | \(ScrollSessionTrace.pad("Readback", 8, right: true))\n"
        s += "--------------------------------------------------------------------------------\n"
        for r in records {
            let reqStr = r.requestedAXValue.map { String(format: "%.3f", $0) } ?? "-"
            let wrtStr = r.requestedValue.map { String(format: "%.3f", $0) } ?? "-"
            let rdbStr = r.axReadbackImmediate.map { String(format: "%.3f", $0) } ?? "-"
            let fyStr = String(format: "%.1f", r.fingerY)
            let dyStr = String(format: "%+.1f", r.fingerDeltaFromStart)
            s += "\(ScrollSessionTrace.pad(r.timestamp, 12)) | \(ScrollSessionTrace.pad(r.phase, 12)) | \(ScrollSessionTrace.pad(fyStr, 8, right: true)) | \(ScrollSessionTrace.pad(dyStr, 8, right: true)) | \(ScrollSessionTrace.pad(reqStr, 8, right: true)) | \(ScrollSessionTrace.pad(wrtStr, 8, right: true)) | \(ScrollSessionTrace.pad(rdbStr, 8, right: true))\n"
        }
        s += "================================================================================\n"
        return s
    }
}

public final class ScrollTransactionTracer {
    public static let shared = ScrollTransactionTracer()
    
    public private(set) var activeSessions: [String: ScrollSessionTrace] = [:]
    public private(set) var completedTraces: [ScrollSessionTrace] = []
    
    private init() {}
    
    public func startSession(
        sessionID: String,
        applicationName: String,
        targetIdentity: String,
        scrollbarIdentity: String,
        initialAXValue: Double,
        startGlobalY: Double
    ) -> ScrollSessionTrace {
        let trace = ScrollSessionTrace(
            sessionID: sessionID,
            applicationName: applicationName,
            targetIdentity: targetIdentity,
            scrollbarIdentity: scrollbarIdentity,
            initialAXValue: initialAXValue,
            startGlobalY: startGlobalY
        )
        activeSessions[sessionID] = trace
        return trace
    }
    
    public func getSession(id: String) -> ScrollSessionTrace? {
        return activeSessions[id]
    }
    
    public func persistTrace(_ trace: ScrollSessionTrace) {
        completedTraces.append(trace)
        activeSessions.removeValue(forKey: trace.sessionID)
        
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scroll_transaction_traces.log")
        let text = trace.formatTransactionReport() + "\n\n"
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let fileHandle = try? FileHandle(forWritingTo: url) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    try? fileHandle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
