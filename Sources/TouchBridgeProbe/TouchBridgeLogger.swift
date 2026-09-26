import Foundation

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
    
    private init() {}
    
    public static func log(_ category: LogCategory, _ level: LogLevel, _ message: String) {
        let entry = LogEntry(category: category, level: level, message: message)
        shared.append(entry)
        
        if printToStdout {
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
    
    private func append(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        
        let callback = onNewEntry
        DispatchQueue.main.async {
            callback?(entry)
        }
    }
    
    public func recentEntries(category: LogCategory? = nil, limit: Int = 100) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        
        let filtered = (category != nil) ? entries.filter { $0.category == category } : entries
        return Array(filtered.suffix(limit))
    }
    
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
