import Foundation
import Cocoa

// MARK: - Structured Lightweight Logger (P3-01 Section 11)

public enum LogCategory: String, CaseIterable, Codable {
    case hid = "HID"
    case display = "DISPLAY"
    case calibration = "CALIB"
    case gesture = "GESTURE"
    case accessibility = "AX"
    case semantic = "SEMANTIC"
    case lifecycle = "LIFECYCLE"
    case safety = "SAFETY"
}

public enum LogLevel: String, Codable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public struct LogEntry: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let category: LogCategory
    public let level: LogLevel
    public let message: String
    
    public init(category: LogCategory, level: LogLevel, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.category = category
        self.level = level
        self.message = message
    }
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    
    public var formattedLine: String {
        let ts = LogEntry.timeFormatter.string(from: timestamp)
        return "[\(ts)] [\(category.rawValue)] [\(level.rawValue)] \(message)"
    }
}

public final class TouchBridgeLogger {
    public static let shared = TouchBridgeLogger()
    
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let maxEntries = 1000
    
    /// Optional listener for UI log views (e.g. Diagnostics Window)
    public var onNewEntry: ((LogEntry) -> Void)?
    
    /// Controls whether logs are mirrored to stdout
    public static var printToStdout: Bool = true
    public static var writeDebugToDisk: Bool = false
    private static let logFilePath = "/tmp/touchbridge_dev.log"
    private var persistentFileHandle: FileHandle?
    
    private init() {}
    
    public static func log(_ category: LogCategory, _ level: LogLevel, _ message: String) {
        let entry = LogEntry(category: category, level: level, message: message)
        shared.append(entry)
        
        if level != .debug || writeDebugToDisk || shared.onNewEntry != nil {
            shared.writeToFile(entry.formattedLine + "\n")
        }
        
        if printToStdout && (level != .debug || writeDebugToDisk) {
            print(entry.formattedLine)
            fflush(stdout)
        }
    }
    
    public static func debug(_ category: LogCategory, _ message: String) {
        log(category, .debug, message)
    }
    
    public static func info(_ category: LogCategory, _ message: String) {
        log(category, .info, message)
    }
    
    public static func warning(_ category: LogCategory, _ message: String) {
        log(category, .warning, message)
    }
    
    public static func error(_ category: LogCategory, _ message: String) {
        log(category, .error, message)
    }
    
    private func writeToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if persistentFileHandle == nil {
            if !FileManager.default.fileExists(atPath: Self.logFilePath) {
                FileManager.default.createFile(atPath: Self.logFilePath, contents: nil, attributes: nil)
            }
            persistentFileHandle = FileHandle(forWritingAtPath: Self.logFilePath)
            persistentFileHandle?.seekToEndOfFile()
        }
        persistentFileHandle?.write(data)
    }

    private func append(_ entry: LogEntry) {
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        let callback = onNewEntry
        lock.unlock()
        
        if let callback {
            DispatchQueue.main.async {
                callback(entry)
            }
        }
    }
    
    public func recentEntries(category: LogCategory? = nil, limit: Int = 100) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        
        let filtered = (category != nil) ? entries.filter { $0.category == category } : entries
        return Array(filtered.suffix(limit))
    }
    
    public func dumpFormattedEntries() -> String {
        // Prefer persistent file on disk if it exists; otherwise use in-memory entries
        if let diskContents = try? String(contentsOfFile: Self.logFilePath, encoding: .utf8), !diskContents.isEmpty {
            return diskContents
        }
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.formattedLine).joined(separator: "\n")
    }

    @discardableResult
    public static func exportDiagnosticReportToDesktop() -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let timestampStr = df.string(from: Date())
        let desktopDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let fileURL = desktopDir.appendingPathComponent("TouchBridge-Diagnostic-\(timestampStr).txt")
        
        let report = """
        ================================================================================
        TOUCHBRIDGE DIAGNOSTIC REPORT
        Timestamp: \(Date())
        macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Hardware: MacBook Pro 2019 (16-inch, Intel x86_64)
        Bundle ID: \(Bundle.main.bundleIdentifier ?? "com.antigravity.touchbridge.dev")
        Bundle Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "1.0.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "Dev"))
        Accessibility Trusted: \(AXPermissionManager.shared.isTrusted())
        ================================================================================
        
        [RECENT LOG RECORDS]
        \(shared.dumpFormattedEntries())
        """
        
        do {
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            TouchBridgeLogger.info(.lifecycle, "Diagnostic report exported to Desktop: \(fileURL.lastPathComponent)")
            return fileURL
        } catch {
            TouchBridgeLogger.error(.lifecycle, "Failed to write diagnostic report: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
