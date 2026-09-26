import Foundation
import IOKit
import IOKit.hid

// MARK: - Pipeline Layer 2: HIDFrameSource (P3-01 Section 3)

public protocol HIDFrameSourceDelegate: AnyObject {
    func hidFrameSource(_ source: HIDFrameSource, didProduceSample sample: TouchSample)
}

public final class HIDFrameSource: TouchscreenDeviceDelegate {
    public weak var delegate: HIDFrameSourceDelegate?
    
    private let aggregator: TouchFrameAggregator
    private var isPaused: Bool = false
    
    public init(logMinX: Int = 0, logMaxX: Int = 4096, logMinY: Int = 0, logMaxY: Int = 4096) {
        self.aggregator = TouchFrameAggregator(
            logMinX: logMinX, logMaxX: logMaxX,
            logMinY: logMinY, logMaxY: logMaxY,
            onSample: { _ in }
        )
        self.aggregator.onSampleForwarder = { [weak self] sample in
            guard let self = self, !self.isPaused else { return }
            self.delegate?.hidFrameSource(self, didProduceSample: sample)
        }
    }
    
    public func updateRanges(logMinX: Int, logMaxX: Int, logMinY: Int, logMaxY: Int) {
        // Can reinitialize or configure aggregator if ranges update dynamically
        TouchBridgeLogger.debug(.hid, "HIDFrameSource ranges updated: X[\(logMinX)..\(logMaxX)], Y[\(logMinY)..\(logMaxY)]")
    }
    
    public func pause() {
        isPaused = true
    }
    
    public func resume() {
        isPaused = false
    }
    
    // MARK: - TouchscreenDeviceDelegate
    
    public func touchscreenDevice(_ device: TouchscreenDevice, didChangeState state: DeviceState) {
        if state == .disconnected {
            // Flush or reset aggregator state on disconnect
            aggregator.reset()
        }
    }
    
    public func touchscreenDevice(_ device: TouchscreenDevice, didReceiveRawElement value: IOHIDValue) {
        guard !isPaused else { return }
        
        let elem = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let intVal = IOHIDValueGetIntegerValue(value)
        let machTime = IOHIDValueGetTimeStamp(value)
        let cookie = UInt32(IOHIDElementGetCookie(elem))
        
        aggregator.handleElement(usagePage: page, usage: usage, value: intVal, machTime: machTime, cookie: cookie)
    }
}
