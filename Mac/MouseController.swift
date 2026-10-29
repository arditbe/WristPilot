import AppKit
import CoreGraphics

/// Posts mouse events. Needs the Accessibility permission.
/// A 250 Hz loop pulls movement from `PointerFilter`. Call everything on the queue passed to `init`.
final class MouseController {
    struct Config {
        var enabled = true
        var tuning = PointerFilter.Tuning()
        var invertX = false
        var invertY = false
        /// Points per Digital Crown unit.
        var crownScrollSpeed = 60.0
        /// Points per radian of pinch-and-tilt.
        var pinchScrollSpeed = 4000.0
        var invertScroll = false
        var pinchAction = MouseAction.leftClick
        var doublePinchAction = MouseAction.rightClick
    }

    var config = Config() {
        didSet { filter.tuning = config.tuning }
    }
    private(set) var isDragging = false

    private let source = CGEventSource(stateID: .hidSystemState)
    private var timer: DispatchSourceTimer?
    private var filter = PointerFilter()
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var virtualPoint: CGPoint?
    private var history: [(time: TimeInterval, point: CGPoint)] = []
    private var lastClick: (time: TimeInterval, point: CGPoint, button: CGMouseButton, count: Int)?
    private var screens: [CGRect] = []
    private var screensCheckedAt: TimeInterval = 0
    /// Scroll still to deliver, and the fractional part already delivered, in points.
    private var pendingScroll = SIMD2<Double>.zero
    private var scrollCarry = SIMD2<Double>.zero

    init(queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func addMotion(dx: Float, dy: Float, duration: UInt8, held: Bool) {
        filter.add(SIMD2(Double(dx), Double(dy)), span: Double(duration) / 1000, held: held,
                   now: ProcessInfo.processInfo.systemUptime)
    }

    func clearMotion() {
        filter.reset()
        pendingScroll = .zero
    }

    func perform(_ action: MouseAction, age: TimeInterval = 0) {
        switch action {
        case .leftClick: click(.left, age: age)
        case .rightClick: click(.right, age: age)
        case .middleClick: click(.center, age: age)
        case .doubleClick:
            click(.left, age: age)
            click(.left)
        case .toggleDrag:
            if isDragging {
                endDrag()
            } else {
                isDragging = true
                post(.leftMouseDown, at: rewind(age), button: .left)
            }
        case .none: break
        }
    }

    func scroll(crown delta: Float) {
        pendingScroll.y += Double(delta) * config.crownScrollSpeed
    }

    func scroll(pinchDX dx: Float, dy: Float) {
        // Pointing down scrolls down the page, which is a negative wheel delta.
        let sign = config.invertScroll ? 1.0 : -1.0
        pendingScroll += SIMD2(Double(dx), Double(dy)) * config.pinchScrollSpeed * sign
    }

    func click(_ button: CGMouseButton, age: TimeInterval = 0) {
        if isDragging { endDrag() }
        let point = rewind(age)
        let now = ProcessInfo.processInfo.systemUptime

        // Consecutive clicks in the same spot become double / triple clicks.
        var count = 1
        if let last = lastClick, last.button == button, now - last.time < NSEvent.doubleClickInterval,
           hypot(last.point.x - point.x, last.point.y - point.y) < 8 {
            count = last.count + 1
        }
        lastClick = (now, point, button, count)

        let (down, up): (CGEventType, CGEventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
        post(down, at: point, button: button, clickCount: count)
        post(up, at: point, button: button, clickCount: count)
    }

    func releaseAll() {
        clearMotion()
        if isDragging { endDrag() }
    }

    // MARK: Output

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(max(now - lastTick, 0.001), 0.05)
        lastTick = now
        guard config.enabled else { return }

        deliverScroll(dt: dt)
        let move = filter.step(now: now, dt: dt)
        guard abs(move.x) + abs(move.y) > 1e-4 else { return }
        moveCursor(dx: move.x * (config.invertX ? -1 : 1), dy: move.y * (config.invertY ? -1 : 1), now: now)
    }

    /// Eases pending scroll out over about 40 ms as continuous, trackpad-style scrolling.
    private func deliverScroll(dt: Double) {
        guard pendingScroll != .zero else { return }
        let take = pendingScroll * (1 - exp(-dt / 0.04))
        pendingScroll -= take
        if abs(pendingScroll.x) + abs(pendingScroll.y) < 0.05 {
            scrollCarry += pendingScroll
            pendingScroll = .zero
        }
        scrollCarry += take
        let wheelY = Int32(scrollCarry.y.rounded(.towardZero))
        let wheelX = Int32(scrollCarry.x.rounded(.towardZero))
        guard wheelX != 0 || wheelY != 0 else { return }
        scrollCarry -= SIMD2(Double(wheelX), Double(wheelY))
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: wheelY, wheel2: wheelX, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event?.post(tap: .cghidEventTap)
    }

    private func moveCursor(dx: Double, dy: Double, now: TimeInterval) {
        // Keep a sub-pixel position so slow movement isn't lost to rounding,
        // but follow the real cursor if the trackpad moved it.
        let real = currentLocation()
        var base = real
        if let virtualPoint, hypot(virtualPoint.x - real.x, virtualPoint.y - real.y) < 2 { base = virtualPoint }
        let target = clampToScreens(CGPoint(x: base.x + dx, y: base.y + dy), from: base, now: now)
        virtualPoint = target

        let event = CGEvent(mouseEventSource: source, mouseType: isDragging ? .leftMouseDragged : .mouseMoved,
                            mouseCursorPosition: target, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event?.post(tap: .cghidEventTap)

        history.append((now, target))
        if history.count > 600 { history.removeFirst(history.count - 500) }
    }

    /// Where the cursor was when the gesture started (plus radio delay), so the click lands
    /// on what you were pointing at.
    private func rewind(_ age: TimeInterval) -> CGPoint {
        let current = currentLocation()
        guard age > 0 else { return current }
        let then = ProcessInfo.processInfo.systemUptime - age - 0.03
        guard let past = history.last(where: { $0.time <= then })?.point,
              hypot(past.x - current.x, past.y - current.y) < 80 else { return current }
        filter.reset()
        virtualPoint = past
        post(isDragging ? .leftMouseDragged : .mouseMoved, at: past, button: .left)
        return past
    }

    private func endDrag() {
        isDragging = false
        post(.leftMouseUp, at: currentLocation(), button: .left)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickCount: Int = 1) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.post(tap: .cghidEventTap)
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Keeps the cursor on a display, sliding along edges instead of sticking.
    private func clampToScreens(_ point: CGPoint, from old: CGPoint, now: TimeInterval) -> CGPoint {
        if now - screensCheckedAt > 2 || screens.isEmpty {
            screensCheckedAt = now
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            screens = displays.map { CGDisplayBounds($0) }
        }
        func onScreen(_ p: CGPoint) -> Bool { screens.contains { $0.contains(p) } }

        for candidate in [point, CGPoint(x: point.x, y: old.y), CGPoint(x: old.x, y: point.y)] where onScreen(candidate) {
            return candidate
        }
        guard let screen = screens.first(where: { $0.contains(old) }) ?? screens.first else { return old }
        return CGPoint(x: min(max(point.x, screen.minX), screen.maxX - 1),
                       y: min(max(point.y, screen.minY), screen.maxY - 1))
    }
}
