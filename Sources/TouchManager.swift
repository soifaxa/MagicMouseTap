import Cocoa

/// Detects short taps on Magic Mouse surface via MultitouchSupport
/// and synthesizes mouse click / click-hold drag events.
final class TouchManager {
    static let shared = TouchManager()

    var isEnabled = true {
        didSet {
            if !isEnabled {
                cancelInteraction()
            }
        }
    }

    /// Maximum contact duration to count as a tap (seconds).
    var maxTapDuration: Double = 0.28
    /// Minimum contact duration to ignore bounce (seconds).
    var minTapDuration: Double = 0.02
    /// Hold duration before arming left-button drag while still (seconds).
    var dragHoldDuration: Double = 0.40
    /// Stillness required before movement can arm a drag (seconds).
    var dragMoveArmDuration: Double = 0.20
    /// Max finger movement on the normalized surface (0…1).
    var maxSurfaceMovement: Float = 0.08
    /// Max cursor movement during the tap / before arming drag (points).
    var maxCursorMovement: CGFloat = 4.0
    /// Normalized X above this value → right-click.
    var rightClickThreshold: Float = 0.55
    /// Cooldown between synthesized clicks (seconds).
    var clickCooldown: Double = 0.12

    private let queue = DispatchQueue(label: "com.applemouseclick.touch")
    private let stateLock = NSLock()
    private var devices: [MTDeviceRef] = []

    private struct Finger {
        var startTime: Double
        var startX: Float
        var startY: Float
        var cursorStart: CGPoint
        var maxDelta: Float = 0
        /// True after a short stable contact; movement may then arm a drag.
        var canArmOnMove = false
    }

    private var fingers: [Int32: Finger] = [:]
    private var previousIDs: Set<Int32> = []
    private var lastClickTime: Double = 0
    private var lastClickLocation: CGPoint = .zero
    private var clickCount: Int64 = 0

    /// True while a synthesized left button is held for drag.
    /// Read from the event-tap callback; guarded by `stateLock`.
    private var isMouseDown = false
    private var dragFingerID: Int32?
    /// Shared across down / dragged / up so apps (e.g. Chrome tabs) treat one drag gesture.
    private var dragEventNumber: Int64 = 0
    private var nextMouseEventNumber: Int64 = 10_000

    /// Converts hardware `mouseMoved` → `leftMouseDragged` while our button is held.
    /// Physical mouse motion alone does not produce dragged events after a synthetic mouseDown.
    fileprivate var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    private let doubleClickInterval: Double = 0.45
    private let doubleClickRadius: CGFloat = 6.0

    private init() {}

    /// Thread-safe drag state for the HID event tap.
    fileprivate var activeDrag: (eventNumber: Int64, clickState: Int64)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isMouseDown else { return nil }
        return (dragEventNumber, 1)
    }

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

        installDragEventTap()
    }

    func stop() {
        cancelInteraction()
        removeDragEventTap()

        for device in devices {
            MTUnregisterContactFrameCallback(device, touchCallback)
            MTDeviceStop(device)
        }
        devices.removeAll()
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

            // Second finger (scroll/gesture): cancel an armed drag and reset tracking
            // so a leftover finger is not treated as a long hold.
            if currentIDs.count > 1 {
                if isMouseDown {
                    postMouseUp()
                }
                fingers.removeAll()
                previousIDs = []
                return
            }

            // Single finger still down: arm left drag after a stable hold or press-then-move.
            if !isMouseDown,
               currentIDs.count == 1,
               let id = currentIDs.first,
               var finger = fingers[id] {
                updateArmEligibility(&finger, timestamp: timestamp)
                fingers[id] = finger
                tryArmDrag(fingerID: id, finger: finger, timestamp: timestamp)
            }

            let lifted = previousIDs.subtracting(currentIDs)

            if let dragID = dragFingerID, lifted.contains(dragID), isMouseDown {
                postMouseUp()
            } else if !isMouseDown,
                      lifted.count == 1,
                      let id = lifted.first,
                      let finger = fingers[id] {
                // Only synthesize a click when exactly one finger lifts (avoids scroll/gesture noise).
                let duration = timestamp - finger.startTime
                let cursorNow = CGEvent(source: nil)?.location ?? .zero
                let cursorDist = hypot(
                    cursorNow.x - finger.cursorStart.x,
                    cursorNow.y - finger.cursorStart.y
                )

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

    /// Marks a left-side contact as eligible for press-then-move drag after brief stillness.
    private func updateArmEligibility(_ finger: inout Finger, timestamp: Double) {
        guard !finger.canArmOnMove,
              finger.startX <= rightClickThreshold
        else { return }

        let duration = timestamp - finger.startTime
        guard duration >= dragMoveArmDuration else { return }

        let cursorNow = CGEvent(source: nil)?.location ?? .zero
        let cursorDist = hypot(
            cursorNow.x - finger.cursorStart.x,
            cursorNow.y - finger.cursorStart.y
        )

        guard finger.maxDelta <= maxSurfaceMovement,
              cursorDist <= maxCursorMovement
        else { return }

        finger.canArmOnMove = true
    }

    /// Arms left-button drag on a long still hold, or after stillness then cursor movement.
    private func tryArmDrag(fingerID: Int32, finger: Finger, timestamp: Double) {
        // Right half: no drag; right-click still happens on lift as a tap.
        if finger.startX > rightClickThreshold { return }

        let duration = timestamp - finger.startTime
        let cursorNow = CGEvent(source: nil)?.location ?? .zero
        let cursorDist = hypot(
            cursorNow.x - finger.cursorStart.x,
            cursorNow.y - finger.cursorStart.y
        )

        let heldStill =
            duration >= dragHoldDuration
            && finger.maxDelta <= maxSurfaceMovement
            && cursorDist <= maxCursorMovement

        // Chrome tabs etc.: brief press, then move the mouse.
        let pressThenMove =
            finger.canArmOnMove
            && cursorDist > maxCursorMovement
            && finger.maxDelta <= maxSurfaceMovement

        guard heldStill || pressThenMove else { return }

        // Down at the original press point (important once the cursor already moved).
        postMouseDown(fingerID: fingerID, at: finger.cursorStart)
        if pressThenMove {
            postMouseDragged(at: cursorNow)
        }
    }

    /// Releases a held button and clears finger tracking (disable / stop / teardown).
    private func cancelInteraction() {
        queue.sync {
            if isMouseDown {
                postMouseUp()
            }
            fingers.removeAll()
            previousIDs.removeAll()
        }
    }

    private func postMouseDown(fingerID: Int32, at location: CGPoint) {
        let now = CACurrentMediaTime()
        let eventNumber = nextMouseEventNumber
        nextMouseEventNumber += 1

        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        down.post(tap: .cghidEventTap)

        clickCount = 1
        lastClickTime = now
        lastClickLocation = location
        dragFingerID = fingerID

        stateLock.lock()
        dragEventNumber = eventNumber
        isMouseDown = true
        stateLock.unlock()
    }

    private func postMouseDragged(at location: CGPoint) {
        stateLock.lock()
        let eventNumber = dragEventNumber
        let down = isMouseDown
        stateLock.unlock()
        guard down else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let dragged = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }

        dragged.setIntegerValueField(.mouseEventClickState, value: 1)
        dragged.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        dragged.post(tap: .cghidEventTap)
    }

    private func postMouseUp() {
        let location = CGEvent(source: nil)?.location ?? .zero

        stateLock.lock()
        let eventNumber = dragEventNumber
        let wasDown = isMouseDown
        isMouseDown = false
        stateLock.unlock()

        dragFingerID = nil
        guard wasDown else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }

        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - mouseMoved → leftMouseDragged

    private func installDragEventTap() {
        removeDragEventTap()

        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dragEventTapCallback,
            userInfo: nil
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
    }

    private func removeDragEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        eventTapSource = nil
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

/// Rewrites hardware mouse-moved events into left-dragged while a tap-hold is active.
private func dragEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = TouchManager.shared.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .mouseMoved, let drag = TouchManager.shared.activeDrag else {
        return Unmanaged.passUnretained(event)
    }

    event.type = .leftMouseDragged
    event.setIntegerValueField(
        .mouseEventButtonNumber,
        value: Int64(CGMouseButton.left.rawValue)
    )
    event.setIntegerValueField(.mouseEventClickState, value: drag.clickState)
    event.setIntegerValueField(.mouseEventNumber, value: drag.eventNumber)
    return Unmanaged.passUnretained(event)
}
