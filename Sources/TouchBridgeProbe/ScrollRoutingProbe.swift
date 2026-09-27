import Foundation
import CoreGraphics
import AppKit

public enum ScrollLocationProbeMode: String {
    case centroid
    case preservePhysicalCursor = "cursor"
    case pidCentroid = "pid-centroid"
    case pidCursor = "pid-cursor"
    case pidWindow = "pid-window"
}

public struct ScrollWindowCorrelation {
    public let status: String
    public let windowID: Int?
    public let candidates: [String]
}

private struct WindowServerWindow {
    let id: Int
    let pid: Int32
    let title: String?
    let bounds: CGRect
    let layer: Int
    let zIndex: Int
}

/// Passive, opt-in observer used to compare cursor readback and system pointer
/// events while TouchBridge posts its scroll events.
public final class ScrollRoutingProbe {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wasActive = false
    private var startedAt: Date?
    private var preScrollMouseMoves = 0
    private var eventCounts: [UInt32: Int] = [:]
    private var lastEventLogAt: [UInt32: Date] = [:]
    private var frontmostPIDAtStart: pid_t?
    private var validatedWindowFields = Set<CGEventField>()

    public init() {}

    @discardableResult
    public func start() -> Bool {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel
        ]
        let mask = types.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: context
        ) else {
            print("[SCROLL PROBE] Event observer unavailable; check Input Monitoring permission.")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTap = tap
        runLoopSource = source
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        print("[SCROLL PROBE] Event observer active. Initial cursor=(\(fmt(cursor.x)),\(fmt(cursor.y))) frontmostPID=\(frontPID.map { String($0) } ?? "unknown")")
        fflush(stdout)
        return true
    }

    public func sample(active: Bool, state: String, touchPoint: CGPoint?) {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        if active {
            if !wasActive {
                startedAt = Date()
                eventCounts.removeAll()
                lastEventLogAt.removeAll()
                frontmostPIDAtStart = NSWorkspace.shared.frontmostApplication?.processIdentifier
                print("[SCROLL PROBE] BEGIN state=\(state) cursor=(\(fmt(cursor.x)),\(fmt(cursor.y))) touch=\(point(touchPoint)) precedingMouseMoved=\(preScrollMouseMoves) frontmostPID=\(frontmostPIDAtStart.map { String($0) } ?? "unknown")")
            }
            print("[SCROLL PROBE] SAMPLE t=\(String(format: "%.3f", Date().timeIntervalSince(startedAt ?? Date()))) state=\(state) cursor=(\(fmt(cursor.x)),\(fmt(cursor.y))) touch=\(point(touchPoint))")
        } else if wasActive {
            let counts = eventCounts.keys.sorted().map { "\($0):\(eventCounts[$0] ?? 0)" }.joined(separator: ",")
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            print("[SCROLL PROBE] END cursor=(\(fmt(cursor.x)),\(fmt(cursor.y))) eventCounts={\(counts)} frontmostPID=\(frontPID.map { String($0) } ?? "unknown") frontmostChanged=\(frontPID != frontmostPIDAtStart)")
            startedAt = nil
            frontmostPIDAtStart = nil
        }
        wasActive = active
        fflush(stdout)
    }

    public func correlateAXWindow(pid: pid_t, window: AXWindowSnapshot?) -> ScrollWindowCorrelation {
        guard let window, let position = window.position, position.count == 2,
              let size = window.size, size.count == 2 else {
            return ScrollWindowCorrelation(status: "AX_WINDOW_BOUNDS_UNAVAILABLE", windowID: nil, candidates: [])
        }
        let targetBounds = CGRect(x: position[0], y: position[1], width: size[0], height: size[1])
        let center = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
        let windows = copyOnScreenWindows()
        let samePID = windows.filter { $0.pid == pid && $0.layer == 0 }
        let containing = samePID.filter { $0.bounds.contains(center) }
        let boundsMatches = containing.filter { rect($0.bounds, matches: targetBounds) }
        let titleMatches = boundsMatches.filter { $0.title == window.title && window.title != nil }
        let matches = uniqueByID(titleMatches.isEmpty ? boundsMatches : titleMatches)
        let descriptions = samePID.map { windowDescription($0) }
        guard matches.count == 1, let match = matches.first else {
            let status = matches.isEmpty ? "NO_MATCH" : "AMBIGUOUS_\(matches.count)_MATCHES"
            return ScrollWindowCorrelation(status: status, windowID: nil, candidates: descriptions)
        }
        return ScrollWindowCorrelation(status: "UNIQUE_MATCH", windowID: match.id, candidates: descriptions)
    }

    public func attachExperimentallyJustifiedWindowFields(to event: CGEvent, targetWindowID: Int?) -> String? {
        guard let targetWindowID, !validatedWindowFields.isEmpty else { return nil }
        for field in validatedWindowFields {
            event.setIntegerValueField(field, value: Int64(targetWindowID))
        }
        return "fields=\(validatedWindowFields.map { String(describing: $0) }.sorted().joined(separator: ","))"
    }

    private func record(type: CGEventType, event: CGEvent) {
        if type == .scrollWheel && !wasActive {
            recordPhysicalScroll(event)
        }
        if type == .mouseMoved && !wasActive {
            preScrollMouseMoves += 1
            return
        }
        guard wasActive || type == .scrollWheel else { return }
        eventCounts[type.rawValue, default: 0] += 1
        let now = Date()
        if let last = lastEventLogAt[type.rawValue], now.timeIntervalSince(last) < 0.1 { return }
        lastEventLogAt[type.rawValue] = now
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        let userID = event.getIntegerValueField(.eventSourceUserID)
        let sourceState = event.getIntegerValueField(.eventSourceStateID)
        print("[SCROLL PROBE] EVENT type=\(type.rawValue) location=(\(fmt(event.location.x)),\(fmt(event.location.y))) cursor=(\(fmt(cursor.x)),\(fmt(cursor.y))) sourcePID=\(pid) sourceState=\(sourceState) sourceUID=\(userID) userData=\(event.getIntegerValueField(.eventSourceUserData))")
        fflush(stdout)
    }

    private func recordPhysicalScroll(_ event: CGEvent) {
        let location = event.location
        let windows = copyOnScreenWindows()
        let actual = windows.first { $0.layer == 0 && $0.bounds.contains(location) }
        let underMouse = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let capable = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let actualID = actual.map { Int64($0.id) }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let sourceState = event.getIntegerValueField(.eventSourceStateID)
        // CGEventSourceStateID defines HIDSystemState as 1.
        let genuineHIDEvent = sourcePID != Int64(getpid()) && sourceState == 1
        if genuineHIDEvent && actualID == underMouse { validatedWindowFields.insert(.mouseEventWindowUnderMousePointer) }
        if genuineHIDEvent && actualID == capable { validatedWindowFields.insert(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) }
        print("[SCROLL PROBE] PHYSICAL_SCROLL genuineHID=\(genuineHIDEvent) location=(\(fmt(location.x)),\(fmt(location.y))) windowUnderPointer=\(underMouse) canHandle=\(capable) actualWindowID=\(actual.map { String($0.id) } ?? "unknown") actualPID=\(actual.map { String($0.pid) } ?? "unknown") title=\(actual?.title ?? "nil") phase=\(event.getIntegerValueField(.scrollWheelEventScrollPhase)) momentum=\(event.getIntegerValueField(.scrollWheelEventMomentumPhase)) sourcePID=\(sourcePID) sourceState=\(sourceState) cursor=(\(fmt(CGEvent(source: nil)?.location.x ?? 0)),\(fmt(CGEvent(source: nil)?.location.y ?? 0))) validatedFields=\(validatedWindowFields.map { String(describing: $0) }.sorted())")
        fflush(stdout)
    }

    private func copyOnScreenWindows() -> [WindowServerWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, item in
            guard let id = item[kCGWindowNumber as String] as? Int,
                  let owner = item[kCGWindowOwnerPID as String] as? Int32,
                  let boundsObject = item[kCGWindowBounds as String] else { return nil }
            let boundsRef = boundsObject as CFTypeRef
            guard CFGetTypeID(boundsRef) == CFDictionaryGetTypeID() else { return nil }
            let boundsDict = boundsObject as! CFDictionary
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds) else { return nil }
            return WindowServerWindow(
                id: id,
                pid: owner,
                title: item[kCGWindowName as String] as? String,
                bounds: bounds,
                layer: item[kCGWindowLayer as String] as? Int ?? -1,
                zIndex: index
            )
        }
    }

    private func rect(_ lhs: CGRect, matches rhs: CGRect) -> Bool {
        abs(lhs.minX-rhs.minX) <= 8 && abs(lhs.minY-rhs.minY) <= 8 &&
            abs(lhs.width-rhs.width) <= 8 && abs(lhs.height-rhs.height) <= 8
    }

    private func uniqueByID(_ values: [WindowServerWindow]) -> [WindowServerWindow] {
        var seen = Set<Int>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private func windowDescription(_ window: WindowServerWindow) -> String {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            return "id=\(window.id),title=\(window.title ?? "nil"),bounds=\(NSStringFromRect(window.bounds)),z=\(window.zIndex),displayIntersection=unknown"
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return "id=\(window.id),title=\(window.title ?? "nil"),bounds=\(NSStringFromRect(window.bounds)),z=\(window.zIndex),displayIntersection=unknown"
        }
        let displays = displayIDs.prefix(Int(count)).compactMap { displayID in
            CGDisplayBounds(displayID).intersects(window.bounds) ? String(displayID) : nil
        }
        return "id=\(window.id),title=\(window.title ?? "nil"),bounds=\(NSStringFromRect(window.bounds)),z=\(window.zIndex),displayIntersection=\(displays.joined(separator: ","))"
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let probe = Unmanaged<ScrollRoutingProbe>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = probe.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else {
            probe.record(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func fmt(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
    private func point(_ point: CGPoint?) -> String {
        guard let point else { return "unavailable" }
        return "(\(fmt(point.x)),\(fmt(point.y)))"
    }
}
