import Cocoa

/// Detects short taps on Magic Mouse surface via MultitouchSupport
/// and synthesizes mouse click events.
final class TouchManager {
    static let shared = TouchManager()

    var isEnabled = true

    /// Maximum contact duration to count as a tap (seconds).
    var maxTapDuration: Double = 0.28
    /// Minimum contact duration to ignore bounce (seconds).
    var minTapDuration: Double = 0.02
    /// Max finger movement on the normalized surface (0…1).
    var maxSurfaceMovement: Float = 0.08
    /// Max cursor movement during the tap (points).
    var maxCursorMovement: CGFloat = 4.0
    /// Normalized X above this value → right-click.
    var rightClickThreshold: Float = 0.55
    /// Cooldown between synthesized clicks (seconds).
    var clickCooldown: Double = 0.12

    private let queue = DispatchQueue(label: "com.applemouseclick.touch")
    private var devices: [MTDeviceRef] = []

    private struct Finger {
        var startTime: Double
        var startX: Float
        var startY: Float
        var cursorStart: CGPoint
        var maxDelta: Float = 0
    }

    private var fingers: [Int32: Finger] = [:]
    private var previousIDs: Set<Int32> = []
    private var lastClickTime: Double = 0
    private var lastClickLocation: CGPoint = .zero
    private var clickCount: Int64 = 0

    private let doubleClickInterval: Double = 0.45
    private let doubleClickRadius: CGFloat = 6.0

    private init() {}

    func start() {
        stop()

        guard let unmanaged = MTDeviceCreateList() else { return }
        let array = unmanaged.takeRetainedValue()
        let count = CFArrayGetCount(array)

        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)

            // Skip built-in trackpads; keep external multitouch devices (Magic Mouse).
            if MTDeviceIsBuiltIn(device) { continue }

            MTRegisterContactFrameCallback(device, touchCallback)
            MTDeviceStart(device, 0)
            devices.append(device)
        }
    }

    func stop() {
        for device in devices {
            MTUnregisterContactFrameCallback(device, touchCallback)
            MTDeviceStop(device)
        }
        devices.removeAll()
        fingers.removeAll()
        previousIDs.removeAll()
    }

    func restart() {
        stop()
        start()
    }

    fileprivate func handleTouches(_ touches: [MTTouch], timestamp: Double) {
        guard isEnabled else { return }

        queue.sync {
            // Any non-zero state means the finger is still interacting with the surface.
            let active = touches.filter { $0.state != 0 }
            let currentIDs = Set(active.map(\.fingerID))
            let cursor = CGEvent(source: nil)?.location ?? .zero

            for touch in active {
                let id = touch.fingerID
                if var finger = fingers[id] {
                    let dx = touch.normalized.position.x - finger.startX
                    let dy = touch.normalized.position.y - finger.startY
                    finger.maxDelta = max(finger.maxDelta, sqrtf(dx * dx + dy * dy))
                    fingers[id] = finger
                } else {
                    fingers[id] = Finger(
                        startTime: timestamp,
                        startX: touch.normalized.position.x,
                        startY: touch.normalized.position.y,
                        cursorStart: cursor
                    )
                }
            }

            let lifted = previousIDs.subtracting(currentIDs)
            // Only synthesize a click when exactly one finger lifts (avoids scroll/gesture noise).
            if lifted.count == 1, let id = lifted.first, let finger = fingers[id] {
                let duration = timestamp - finger.startTime
                let cursorNow = CGEvent(source: nil)?.location ?? .zero
                let cdx = cursorNow.x - finger.cursorStart.x
                let cdy = cursorNow.y - finger.cursorStart.y
                let cursorDist = hypot(cdx, cdy)

                let isTap =
                    duration >= minTapDuration
                    && duration <= maxTapDuration
                    && finger.maxDelta <= maxSurfaceMovement
                    && cursorDist <= maxCursorMovement

                if isTap {
                    let isRight = finger.startX > rightClickThreshold
                    postClick(isRightClick: isRight)
                }
            }

            for id in lifted {
                fingers.removeValue(forKey: id)
            }
            previousIDs = currentIDs
        }
    }

    private func postClick(isRightClick: Bool) {
        let now = CACurrentMediaTime()
        if now - lastClickTime < clickCooldown { return }

        let location = CGEvent(source: nil)?.location ?? .zero
        let distance = hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y)

        if !isRightClick,
           now - lastClickTime < doubleClickInterval,
           distance < doubleClickRadius {
            clickCount += 1
        } else {
            clickCount = 1
        }

        lastClickTime = now
        lastClickLocation = location
        let count = clickCount

        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .hidSystemState)
            let downType: CGEventType = isRightClick ? .rightMouseDown : .leftMouseDown
            let upType: CGEventType = isRightClick ? .rightMouseUp : .leftMouseUp
            let button: CGMouseButton = isRightClick ? .right : .left

            guard
                let down = CGEvent(
                    mouseEventSource: source,
                    mouseType: downType,
                    mouseCursorPosition: location,
                    mouseButton: button
                ),
                let up = CGEvent(
                    mouseEventSource: source,
                    mouseType: upType,
                    mouseCursorPosition: location,
                    mouseButton: button
                )
            else { return }

            if !isRightClick {
                down.setIntegerValueField(.mouseEventClickState, value: count)
                up.setIntegerValueField(.mouseEventClickState, value: count)
            }

            down.post(tap: .cghidEventTap)
            usleep(30_000)
            up.post(tap: .cghidEventTap)
        }
    }
}

private func touchCallback(
    device: MTDeviceRef?,
    touches: UnsafeMutablePointer<MTTouch>?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32
) {
    guard let touches else { return }
    let array = Array(UnsafeBufferPointer(start: touches, count: Int(numTouches)))
    TouchManager.shared.handleTouches(array, timestamp: timestamp)
}
