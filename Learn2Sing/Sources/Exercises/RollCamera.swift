import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Observation

// The MIDI editor's piano roll is moved and zoomed the way a photo is: two fingers
// anywhere on it, whatever tool is in hand, take hold of it and carry it in any
// direction while they pinch it bigger or smaller, all at once. One finger does the
// same with the hand tool, and scrolls it up and down on the keys.
//
// The roll isn't a scroll view for that. Two nested ones (one up and down, one across)
// could only ever move along one of their axes at a time, and neither zooms. Instead
// the camera here says what the roll shows, and the keys, the ruler and the grid are
// each drawn through it, only as much of them as is on screen.

// MARK: - What the roll shows

/// What the piano roll shows: how far it's zoomed, and which point of the roll is at
/// the top left corner of the grid's viewport.
///
/// The editor lays everything out and edits it in the roll's own space, unzoomed: x
/// from the dead margin in front of beat 0, y from the top row. So the tools work
/// exactly as they did before the roll could zoom, and only drawing and touches go
/// through a shot.
struct RollShot: Equatable {
    /// The point of the roll at the viewport's top left corner, in the roll's own space.
    var origin: CGPoint
    /// Screen points to one point of the roll's own space.
    var zoom: CGFloat

    /// The point of the roll drawn at `point` in the viewport.
    func roll(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x / zoom, y: origin.y + point.y / zoom)
    }

    /// The shot at `zoom` that draws `point` of the roll at `screen` in the viewport.
    static func holding(_ point: CGPoint, at screen: CGPoint, zoom: CGFloat) -> RollShot {
        RollShot(origin: CGPoint(x: point.x - screen.x / zoom, y: point.y - screen.y / zoom),
                 zoom: zoom)
    }
}

// MARK: - Camera

/// Where the piano roll is scrolled to and how far it's zoomed, and the motion that
/// carries it on once the fingers let go: gliding to a stop, or springing back from
/// past an edge or a zoom limit, as a scroll view does.
///
/// Only the views that draw through it watch it (see `RollCameraCanvas`), so the roll
/// moves every frame without the editor around it being asked to redraw.
@Observable
final class RollCamera {
    /// What the roll shows.
    private(set) var shot = RollShot(origin: .zero, zoom: 1)
    /// Whether the scroll indicators are up: while the roll moves, and a moment after.
    private(set) var indicatorsShown = false

    /// The grid's viewport in screen points: the stretch of the roll on screen, right
    /// of the piano keys.
    @ObservationIgnored private(set) var viewport = CGSize.zero
    /// How big the roll is in its own space.
    @ObservationIgnored private(set) var content = CGSize.zero

    /// As far in as it zooms: a quarter-beat note about a fingertip wide.
    static let maxZoom: CGFloat = 3
    /// As far out as it ever zooms, so a short viewport (a phone on its side) doesn't
    /// shrink the rows to nothing trying to fit them all.
    static let minZoomFloor: CGFloat = 0.3

    /// As far out as it zooms: until every row fits the viewport's height, but no
    /// further than `minZoomFloor`. Never short of the size the editor draws at
    /// unzoomed.
    var minZoom: CGFloat {
        guard viewport.height > 0, content.height > 0 else { return 1 }
        return min(1, max(Self.minZoomFloor, viewport.height / content.height))
    }

    /// Whether fingers are moving the roll.
    var isNavigating: Bool { navigation != nil }
    /// Whether the roll is on its way somewhere by itself.
    var isMoving: Bool { motion != nil }

    // MARK: Limits

    /// The furthest the origin may go at `zoom` on each axis: as far as brings the
    /// roll's far edge to the viewport's. Nowhere on an axis the whole roll fits.
    func maxOrigin(zoom: CGFloat) -> CGPoint {
        CGPoint(x: max(0, content.width - viewport.width / zoom),
                y: max(0, content.height - viewport.height / zoom))
    }

    /// `origin` held inside the roll's edges at `zoom`.
    func clamped(_ origin: CGPoint, zoom: CGFloat) -> CGPoint {
        let far = maxOrigin(zoom: zoom)
        return CGPoint(x: origin.x.clamped(to: 0...far.x), y: origin.y.clamped(to: 0...far.y))
    }

    private func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        zoom.clamped(to: minZoom...Self.maxZoom)
    }

    /// The viewport is `size` now.
    func setViewport(_ size: CGSize) {
        guard size != viewport else { return }
        viewport = size
        settleIntoLimits()
    }

    /// The roll is `size` now, with `lead` points more of it than before in front of
    /// what was its left edge (fewer when negative). The origin moves along with the
    /// edge, so what was on screen stays where it was.
    func setContent(_ size: CGSize, leadGrownBy lead: CGFloat = 0) {
        guard size != content || lead != 0 else { return }
        content = size
        if lead != 0 {
            // Whatever the roll was on its way to has moved too.
            stopMotion()
            shot.origin.x += lead
            navigation?.free.origin.x += lead
        }
        settleIntoLimits()
    }

    /// Straight back inside the zoom limits (about the viewport's middle) and the
    /// roll's edges, after the viewport or the roll changed size. Not while fingers
    /// have hold of it: the rubber band takes the new limits in, and the fingers let go
    /// into them.
    private func settleIntoLimits() {
        guard navigation == nil, viewport.width > 0, viewport.height > 0 else { return }
        var settled = shot
        let zoom = clampedZoom(settled.zoom)
        if zoom != settled.zoom {
            let middle = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            settled = .holding(settled.roll(middle), at: middle, zoom: zoom)
        }
        settled.origin = clamped(settled.origin, zoom: zoom)
        guard settled != shot else { return }
        stopMotion()
        show(settled, indicating: false)
    }

    // MARK: Moving it from code

    /// Straight to `y`, without the scroll indicators: where the roll opens.
    func jump(toY y: CGFloat) {
        stopMotion()
        let origin = clamped(CGPoint(x: shot.origin.x, y: y), zoom: shot.zoom)
        show(RollShot(origin: origin, zoom: shot.zoom), indicating: false)
    }

    /// To `origin`, which the caller has already held inside the roll's edges, with
    /// the scroll indicators up: a drag scrolling the roll at its edge.
    func scroll(to origin: CGPoint) {
        show(RollShot(origin: origin, zoom: shot.zoom))
    }

    /// Springs across to `x`, held inside the roll's edges: playback keeping the
    /// playhead on screen.
    func glide(toX x: CGFloat) {
        guard navigation == nil else { return }
        let target = clamped(CGPoint(x: x, y: shot.origin.y), zoom: shot.zoom).x
        motion = .drift(x: .springing(target: target, velocity: 0), y: .still)
        startTicking()
    }

    /// Stops whatever the roll is doing by itself, where it is. Returns whether it was
    /// doing anything.
    @discardableResult
    func stopMotion() -> Bool {
        let wasMoving = motion != nil
        motion = nil
        stopTicking()
        return wasMoving
    }

    /// The rest of the way back inside the limits, for a press that stopped the roll
    /// springing back and let go without moving it.
    func resumeSettling() {
        guard navigation == nil, motion == nil, viewport.width > 0, viewport.height > 0 else { return }
        settle(around: CGPoint(x: viewport.width / 2, y: viewport.height / 2), velocity: .zero)
    }

    // MARK: Fingers

    /// Fingers moving the roll: where their midpoint was at the last move, and the
    /// shot they'd be holding if nothing held the roll back. What it shows is that,
    /// held back by the rubber band past its edges and its zoom limits.
    private struct Navigation {
        var centroid: CGPoint
        var free: RollShot
    }
    @ObservationIgnored private var navigation: Navigation?

    /// Fingers have taken hold of the roll with their midpoint at `centroid` in the
    /// viewport. Whatever it was doing by itself stops where it is.
    func beginNavigation(at centroid: CGPoint) {
        stopMotion()
        navigation = Navigation(centroid: centroid, free: unbanded(shot, around: centroid))
    }

    /// A finger landed or lifted, so the midpoint jumped to `centroid`. The roll stays
    /// where it is and goes on from there.
    func rebaseNavigation(at centroid: CGPoint) {
        guard navigation != nil else { return }
        navigation = Navigation(centroid: centroid, free: unbanded(shot, around: centroid))
    }

    /// The fingers' midpoint moved to `centroid` and they spread to `scale` times as
    /// far apart: the point of the roll that was under them is under them still, at
    /// the new size.
    func navigate(to centroid: CGPoint, scale: CGFloat) {
        guard var navigation else { return }
        let held = navigation.free.roll(navigation.centroid)
        let zoom = (navigation.free.zoom * scale).clamped(to: 0.01...100)
        navigation.free = .holding(held, at: centroid, zoom: zoom)
        navigation.centroid = centroid
        self.navigation = navigation
        show(banded(navigation.free, around: centroid))
    }

    /// The fingers let go, moving at `velocity`, in points a second across the viewport.
    func endNavigation(velocity: CGVector) {
        guard let navigation else { return }
        self.navigation = nil
        settle(around: navigation.centroid, velocity: velocity)
    }

    // MARK: Rubber band

    /// The most the zoom gives past either of its limits, as the logarithm of a ratio:
    /// about a third.
    private static let zoomGive: CGFloat = log(1.35)

    /// `free` as it's shown: held back past an edge or a zoom limit the way a scroll
    /// view's rubber band holds it, with the point of the roll under `centroid` kept
    /// there.
    private func banded(_ free: RollShot, around centroid: CGPoint) -> RollShot {
        let zoom = bandedZoom(free.zoom)
        var shown = RollShot.holding(free.roll(centroid), at: centroid, zoom: zoom)
        let far = maxOrigin(zoom: zoom)
        shown.origin.x = banded(shown.origin.x, far: far.x, zoom: zoom, span: viewport.width)
        shown.origin.y = banded(shown.origin.y, far: far.y, zoom: zoom, span: viewport.height)
        return shown
    }

    /// The free shot that `banded(_:around:)` shows as `shown`: for taking hold of the
    /// roll where it is while it's still springing back.
    private func unbanded(_ shown: RollShot, around centroid: CGPoint) -> RollShot {
        let far = maxOrigin(zoom: shown.zoom)
        var held = shown
        held.origin.x = unbanded(shown.origin.x, far: far.x, zoom: shown.zoom, span: viewport.width)
        held.origin.y = unbanded(shown.origin.y, far: far.y, zoom: shown.zoom, span: viewport.height)
        return .holding(held.roll(centroid), at: centroid, zoom: unbandedZoom(shown.zoom))
    }

    private func banded(_ value: CGFloat, far: CGFloat, zoom: CGFloat, span: CGFloat) -> CGFloat {
        if value < 0 { return -rubberBand(-value * zoom, span: span) / zoom }
        if value > far { return far + rubberBand((value - far) * zoom, span: span) / zoom }
        return value
    }

    private func unbanded(_ value: CGFloat, far: CGFloat, zoom: CGFloat, span: CGFloat) -> CGFloat {
        if value < 0 { return -stretch(drawnAs: -value * zoom, span: span) / zoom }
        if value > far { return far + stretch(drawnAs: (value - far) * zoom, span: span) / zoom }
        return value
    }

    /// Past a zoom limit, held back the same way, by the ratio rather than the distance.
    private func bandedZoom(_ zoom: CGFloat) -> CGFloat {
        let low = minZoom, high = Self.maxZoom
        if zoom > high { return high * exp(rubberBand(log(zoom / high), span: Self.zoomGive)) }
        if zoom < low { return low / exp(rubberBand(log(low / zoom), span: Self.zoomGive)) }
        return zoom
    }

    private func unbandedZoom(_ zoom: CGFloat) -> CGFloat {
        let low = minZoom, high = Self.maxZoom
        if zoom > high { return high * exp(stretch(drawnAs: log(zoom / high), span: Self.zoomGive)) }
        if zoom < low { return low / exp(stretch(drawnAs: log(low / zoom), span: Self.zoomGive)) }
        return zoom
    }

    // MARK: Motion

    /// One axis of the roll moving by itself, in the roll's own points.
    private enum Drift {
        case still
        /// Gliding to a stop, at `velocity` points a second for now.
        case coasting(velocity: CGFloat)
        /// Springing to `target`, at `velocity` points a second for now.
        case springing(target: CGFloat, velocity: CGFloat)
    }

    private enum Motion {
        /// Each axis on its own way.
        case drift(x: Drift, y: Drift)
        /// Back inside the zoom limits, from `from` to `to`, keeping what's at `anchor`
        /// in the viewport there as it goes. `remaining` of the way is left, shrinking at
        /// `velocity` a second.
        case rezoom(from: RollShot, to: RollShot, anchor: CGPoint, remaining: CGFloat, velocity: CGFloat)
    }
    @ObservationIgnored private var motion: Motion?

    /// The share of its speed a glide keeps every millisecond: a scroll view's normal
    /// deceleration.
    private static let decelerationRate: CGFloat = 0.998
    /// How quickly the springs pull, a second: back from past an edge in about half a
    /// second, as a scroll view comes back.
    private static let springRate: CGFloat = 13
    /// The slowest a let-go may be and still glide, in screen points a second.
    private static let slowestGlide: CGFloat = 40

    /// The fingers let go with their midpoint at `centroid`: back inside the zoom
    /// limits if they left it past one, and otherwise on at the speed they let go at,
    /// each axis springing back inside the roll's edges wherever it's past one.
    private func settle(around centroid: CGPoint, velocity: CGVector) {
        let zoom = clampedZoom(shot.zoom)
        if abs(zoom - shot.zoom) > 0.0001 {
            let target = RollShot.holding(shot.roll(centroid), at: centroid, zoom: zoom)
            let to = RollShot(origin: clamped(target.origin, zoom: zoom), zoom: zoom)
            motion = .rezoom(from: shot, to: to, anchor: centroid, remaining: 1, velocity: 0)
        } else {
            let far = maxOrigin(zoom: zoom)
            let x = drift(from: shot.origin.x, far: far.x, velocity: -velocity.dx / zoom)
            let y = drift(from: shot.origin.y, far: far.y, velocity: -velocity.dy / zoom)
            if case .still = x, case .still = y {
                motion = nil
            } else {
                motion = .drift(x: x, y: y)
            }
        }
        if motion != nil { startTicking() }
    }

    private func drift(from value: CGFloat, far: CGFloat, velocity: CGFloat) -> Drift {
        if value < 0 { return .springing(target: 0, velocity: velocity) }
        if value > far { return .springing(target: far, velocity: velocity) }
        if abs(velocity) * shot.zoom < Self.slowestGlide { return .still }
        return .coasting(velocity: velocity)
    }

    /// Moves the roll on by `seconds` of whatever it's doing.
    private func step(by seconds: CGFloat) {
        guard let motion else { return }
        switch motion {
        case .rezoom(let from, let to, let anchor, var remaining, var velocity):
            Self.spring(&remaining, &velocity, to: 0, over: seconds)
            if abs(remaining) < 0.001, abs(velocity) < 0.01 {
                self.motion = nil
                show(to)
            } else {
                let progress = 1 - remaining
                let zoom = from.zoom * pow(to.zoom / from.zoom, progress)
                let start = from.roll(anchor), end = to.roll(anchor)
                let held = CGPoint(x: start.x + (end.x - start.x) * progress,
                                   y: start.y + (end.y - start.y) * progress)
                self.motion = .rezoom(from: from, to: to, anchor: anchor,
                                      remaining: remaining, velocity: velocity)
                show(.holding(held, at: anchor, zoom: zoom))
            }
        case .drift(var x, var y):
            let far = maxOrigin(zoom: shot.zoom)
            let origin = CGPoint(x: advance(&x, from: shot.origin.x, far: far.x, over: seconds),
                                 y: advance(&y, from: shot.origin.y, far: far.y, over: seconds))
            if case .still = x, case .still = y {
                self.motion = nil
            } else {
                self.motion = .drift(x: x, y: y)
            }
            show(RollShot(origin: origin, zoom: shot.zoom))
        }
    }

    /// Where one axis at `value` is `seconds` later, with `drift` updated to how it's
    /// moving by then.
    private func advance(_ drift: inout Drift, from value: CGFloat, far: CGFloat,
                         over seconds: CGFloat) -> CGFloat {
        switch drift {
        case .still:
            return value
        case .coasting(let velocity):
            // Exactly as far as the speed, shed at the scroll view's rate, carries it.
            let rate = log(Self.decelerationRate) * 1000
            let decay = exp(rate * seconds)
            let next = value + velocity * (decay - 1) / rate
            let slower = velocity * decay
            if next < 0 {
                // Carried into an edge: past it a little, and back.
                drift = .springing(target: 0, velocity: slower)
            } else if next > far {
                drift = .springing(target: far, velocity: slower)
            } else if abs(slower) * shot.zoom < 5 {
                drift = .still
            } else {
                drift = .coasting(velocity: slower)
            }
            return next
        case .springing(let target, var velocity):
            var position = value
            Self.spring(&position, &velocity, to: target, over: seconds)
            if abs(position - target) * shot.zoom < 0.2, abs(velocity) * shot.zoom < 5 {
                drift = .still
                return target
            }
            drift = .springing(target: target, velocity: velocity)
            return position
        }
    }

    /// Moves `value`, going at `velocity`, `seconds` along a critically damped spring
    /// pulling it to `target`: it gets there without swinging past, unless it was
    /// already moving away.
    private static func spring(_ value: inout CGFloat, _ velocity: inout CGFloat,
                               to target: CGFloat, over seconds: CGFloat) {
        let rate = springRate
        let offset = value - target
        let push = velocity + rate * offset
        let decay = exp(-rate * seconds)
        value = target + (offset + push * seconds) * decay
        velocity = (velocity - rate * push * seconds) * decay
    }

    /// Shows `newShot`, with the scroll indicators up unless told otherwise.
    private func show(_ newShot: RollShot, indicating: Bool = true) {
        guard newShot != shot else { return }
        shot = newShot
        if indicating { flashIndicators() }
    }

    // MARK: Ticking

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTick: CFTimeInterval?

    private func startTicking() {
        guard link == nil else { return }
        let link = CADisplayLink(target: RollCameraTicker(self),
                                 selector: #selector(RollCameraTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = nil
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
        lastTick = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        // The first tick goes by the frame it's for: there's no last one to go by.
        let seconds = lastTick.map { now - $0 } ?? (link.targetTimestamp - now)
        lastTick = now
        // A hitch slows the motion down rather than jumping it.
        step(by: CGFloat(seconds.clamped(to: 0...(1.0 / 30))))
        if motion == nil { stopTicking() }
    }

    // MARK: Scroll indicators

    /// How long the indicators stay up after the roll stops.
    private static let indicatorLinger: CFTimeInterval = 0.5
    @ObservationIgnored private var lastMoved: CFTimeInterval = 0
    @ObservationIgnored private var indicatorCheck: Task<Void, Never>?

    private func flashIndicators() {
        lastMoved = CACurrentMediaTime()
        if !indicatorsShown { indicatorsShown = true }
        if indicatorCheck == nil { checkIndicators(after: Self.indicatorLinger) }
    }

    /// Takes the indicators down once the roll has been still for `indicatorLinger`
    /// with no fingers on it, looking again `delay` from now. One check at a time,
    /// however often the roll moves.
    private func checkIndicators(after delay: CFTimeInterval) {
        indicatorCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.indicatorCheck = nil
            let still = CACurrentMediaTime() - self.lastMoved
            if still >= Self.indicatorLinger - 0.01, self.navigation == nil, self.motion == nil {
                self.indicatorsShown = false
            } else {
                self.checkIndicators(after: max(0.05, Self.indicatorLinger - still))
            }
        }
    }
}

/// How far past an edge the roll is drawn when fingers have pulled it `stretch` past
/// it: a scroll view's rubber band, which gives less the further it's pulled and never
/// as much as `span`.
private func rubberBand(_ stretch: CGFloat, span: CGFloat) -> CGFloat {
    guard span > 0 else { return 0 }
    return (1 - 1 / (stretch * 0.55 / span + 1)) * span
}

/// The stretch `rubberBand` draws as `drawn`.
private func stretch(drawnAs drawn: CGFloat, span: CGFloat) -> CGFloat {
    guard span > 0 else { return 0 }
    let given = min(drawn / span, 0.99)
    return (1 / (1 - given) - 1) * span / 0.55
}

/// What the camera's display link calls. A display link keeps its target, so this
/// holds the camera only weakly, and stops the link should the camera be gone.
private final class RollCameraTicker: NSObject {
    private weak var camera: RollCamera?

    init(_ camera: RollCamera) {
        self.camera = camera
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let camera else {
            link.invalidate()
            return
        }
        camera.tick(link)
    }
}

// MARK: - Drawing through the camera

/// A canvas drawn through the roll's camera: redrawn whenever the camera moves,
/// without anything around it being asked to redraw.
struct RollCameraCanvas: View {
    let camera: RollCamera
    let draw: (inout GraphicsContext, CGSize, RollShot) -> Void

    var body: some View {
        // Read here, in the body, so it's this view a move of the camera redraws.
        let shot = camera.shot
        Canvas { context, size in draw(&context, size, shot) }
    }
}

/// The roll's scroll indicators: thin bars along the viewport's right and bottom edges,
/// up while the roll moves, as a scroll view has them.
struct RollScrollIndicators: View {
    let camera: RollCamera

    var body: some View {
        let shot = camera.shot
        let shown = camera.indicatorsShown
        Canvas { context, size in
            let content = camera.content
            let thickness: CGFloat = 3
            let inset: CGFloat = 3
            let shortest: CGFloat = 30
            let seen = CGSize(width: size.width / shot.zoom, height: size.height / shot.zoom)
            let across = content.width > seen.width + 0.5
            let down = content.height > seen.height + 0.5
            let shading = GraphicsContext.Shading.color(.white.opacity(0.45))
            if across {
                let track = size.width - inset * 2 - (down ? thickness + inset : 0)
                let length = min(track, max(shortest, track * seen.width / content.width))
                let progress = (shot.origin.x / (content.width - seen.width)).clamped(to: 0...1)
                let bar = CGRect(x: inset + (track - length) * progress,
                                 y: size.height - inset - thickness,
                                 width: length, height: thickness)
                context.fill(Path(roundedRect: bar, cornerRadius: thickness / 2), with: shading)
            }
            if down {
                let track = size.height - inset * 2 - (across ? thickness + inset : 0)
                let length = min(track, max(shortest, track * seen.height / content.height))
                let progress = (shot.origin.y / (content.height - seen.height)).clamped(to: 0...1)
                let bar = CGRect(x: size.width - inset - thickness,
                                 y: inset + (track - length) * progress,
                                 width: thickness, height: length)
                context.fill(Path(roundedRect: bar, cornerRadius: thickness / 2), with: shading)
            }
        }
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: shown ? 0.1 : 0.3), value: shown)
        .allowsHitTesting(false)
    }
}

// MARK: - Touches

/// Picks out the touches on the roll that move and zoom it, from the ones its tools
/// draw with: two fingers anywhere on it, whatever the tool, and one finger with the
/// hand tool, or on the keys (up and down only there).
///
/// Two fingers never land at quite the same moment, so the first has usually been
/// handed to the tool already when the second comes down. A second finger still takes
/// the press over if it comes soon after the first, or before the first has gone
/// anywhere; any later, and the first finger's drawing goes on undisturbed.
final class RollNavigationRecognizer: UIGestureRecognizer {
    /// How soon after the first finger a second one still takes the press over.
    static let takeOverWindow: TimeInterval = 0.25
    /// How little the first finger may have moved for a second one to take the press
    /// over, however long after it landed.
    static let takeOverTravel: CGFloat = 10
    /// Fingers closer than this to their midpoint don't zoom: there's too little
    /// distance between them to read a change in it from.
    private static let shortestSpread: CGFloat = 8

    /// Which ways one finger landing at a point moves the roll: none where it draws.
    var oneFingerAxes: (CGPoint) -> Axis.Set = { _ in [] }
    /// The first finger of a press has landed.
    var onPressBegan: () -> Void = {}
    /// The last finger of a press has lifted, or the press was taken away.
    var onPressEnded: () -> Void = {}

    /// Where the fingers' midpoint was when the gesture began.
    private(set) var startCentroid = CGPoint.zero
    /// Where it is now, left where it was along any axis the gesture doesn't move on.
    private(set) var centroid = CGPoint.zero
    /// How many times as far apart the fingers are as at the last report.
    private(set) var scale: CGFloat = 1
    /// Set when the latest report is of a finger landing or lifting, rather than of
    /// the fingers moving: the midpoint jumped, and is a new bearing to go on from.
    private(set) var rebased = false
    /// How fast the midpoint was moving as the last finger lifted, in points a second.
    private(set) var releaseVelocity = CGVector.zero

    private var fingers: [UITouch] = []
    private var landedAt: TimeInterval = 0
    private var landing = CGPoint.zero
    /// The furthest the press's first finger has strayed from where it landed.
    private var strayed: CGFloat = 0
    private var axes: Axis.Set = []
    private var lastMidpoint = CGPoint.zero
    private var lastSpread: CGFloat = 0
    /// The way the midpoint has come, leaving out its jumps as fingers land and lift,
    /// sampled for the speed it lets go at.
    private var path = CGPoint.zero
    private var samples: [(time: TimeInterval, point: CGPoint)] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view else { return }
        if fingers.isEmpty, state == .possible, let first = touches.first {
            landedAt = first.timestamp
            landing = first.location(in: view)
            strayed = 0
            axes = oneFingerAxes(landing)
            onPressBegan()
        }
        switch state {
        case .possible:
            if !fingers.isEmpty, !mayTakeOver(at: event.timestamp) {
                // Too late: the first finger is the tool's, and this one plays no part.
                for touch in touches { ignore(touch, for: event) }
                return
            }
            fingers.append(contentsOf: touches)
            if fingers.count >= 2 {
                axes = [.horizontal, .vertical]
                begin(from: midpoint(), at: event.timestamp)
            }
        case .began, .changed:
            fingers.append(contentsOf: touches)
            axes = [.horizontal, .vertical]
            rebase()
        default:
            for touch in touches { ignore(touch, for: event) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view else { return }
        switch state {
        case .possible:
            guard let first = fingers.first else { return }
            let point = first.location(in: view)
            strayed = max(strayed, hypot(point.x - landing.x, point.y - landing.y))
            // One finger that moves the roll moves it from where it landed, so none of
            // the way it has come already is lost.
            if fingers.count == 1, !axes.isEmpty, strayed > 0 {
                begin(from: landing, at: landedAt)
                track(at: event.timestamp)
            }
        case .began, .changed:
            track(at: event.timestamp)
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches, at: event.timestamp, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches, at: event.timestamp, cancelled: true)
    }

    override func reset() {
        super.reset()
        fingers = []
        samples = []
        scale = 1
        rebased = false
        strayed = 0
        axes = []
    }

    /// Whether a finger landing at `time` beside the press's first one takes the
    /// press over.
    private func mayTakeOver(at time: TimeInterval) -> Bool {
        !axes.isEmpty || time - landedAt <= Self.takeOverWindow || strayed <= Self.takeOverTravel
    }

    private func begin(from point: CGPoint, at time: TimeInterval) {
        startCentroid = point
        centroid = point
        lastMidpoint = point
        lastSpread = spread()
        scale = 1
        rebased = false
        path = .zero
        samples = [(time, .zero)]
        state = .began
    }

    private func track(at time: TimeInterval) {
        let point = midpoint()
        let spread = self.spread()
        let dx = axes.contains(.horizontal) ? point.x - lastMidpoint.x : 0
        let dy = axes.contains(.vertical) ? point.y - lastMidpoint.y : 0
        centroid.x += dx
        centroid.y += dy
        path.x += dx
        path.y += dy
        scale = fingers.count >= 2 && lastSpread >= Self.shortestSpread && spread >= Self.shortestSpread
            ? spread / lastSpread : 1
        lastMidpoint = point
        lastSpread = spread
        rebased = false
        samples.append((time, path))
        samples.removeAll { time - $0.time > 0.15 }
    }

    private func rebase() {
        let point = midpoint()
        centroid = point
        lastMidpoint = point
        lastSpread = spread()
        scale = 1
        rebased = true
        state = .changed
    }

    private func lift(_ touches: Set<UITouch>, at time: TimeInterval, cancelled: Bool) {
        fingers.removeAll { touches.contains($0) }
        guard fingers.isEmpty else {
            if state == .began || state == .changed { rebase() }
            return
        }
        switch state {
        case .began, .changed:
            releaseVelocity = cancelled ? .zero : velocity(at: time)
            state = cancelled ? .cancelled : .ended
        default:
            state = .failed
        }
        onPressEnded()
    }

    /// How fast the midpoint was going over the last moment before `time`: not at all
    /// if the fingers had come to rest before they lifted.
    private func velocity(at time: TimeInterval) -> CGVector {
        guard let last = samples.last, time - last.time < 0.05,
              let first = samples.first(where: { last.time - $0.time <= 0.08 }),
              last.time - first.time > 0.01 else { return .zero }
        let span = last.time - first.time
        return CGVector(dx: (last.point.x - first.point.x) / span,
                        dy: (last.point.y - first.point.y) / span)
    }

    private func midpoint() -> CGPoint {
        guard let view, !fingers.isEmpty else { return lastMidpoint }
        var sum = CGPoint.zero
        for finger in fingers {
            let point = finger.location(in: view)
            sum.x += point.x
            sum.y += point.y
        }
        return CGPoint(x: sum.x / CGFloat(fingers.count), y: sum.y / CGFloat(fingers.count))
    }

    /// How far the fingers are from their midpoint, on average.
    private func spread() -> CGFloat {
        guard let view, fingers.count >= 2 else { return 0 }
        let middle = midpoint()
        let total = fingers.reduce(CGFloat(0)) { sum, finger in
            let point = finger.location(in: view)
            return sum + hypot(point.x - middle.x, point.y - middle.y)
        }
        return total / CGFloat(fingers.count)
    }
}

/// The surface laid over the keys and the grid that moves and zooms the roll. The
/// tools' own drag is SwiftUI's, on the view around it, and sees the same touches:
/// this takes only the ones that move the roll, and says when a press has become one
/// of those so the tools can let go of it.
struct RollNavigationSurface: UIViewRepresentable {
    let camera: RollCamera
    /// How wide the piano keys are along the surface's left edge.
    let keysWidth: CGFloat
    /// Whether one finger on the grid moves the roll (the hand tool) instead of drawing.
    let oneFingerPans: Bool
    /// The first finger of a press has landed on the roll.
    let onPressBegan: () -> Void
    /// The last finger of a press has lifted.
    let onPressEnded: () -> Void
    /// The press has become one that moves the roll.
    let onNavigationBegan: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Without this the view is handed only the first finger, and never sees a pinch.
        view.isMultipleTouchEnabled = true
        let recognizer = RollNavigationRecognizer(target: context.coordinator,
                                                  action: #selector(Coordinator.handle(_:)))
        recognizer.delegate = context.coordinator
        // The tools' drag goes on seeing the touches; this only takes the roll.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        context.coordinator.hookUp(recognizer)
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.surface = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(surface: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: RollNavigationSurface

        init(surface: RollNavigationSurface) {
            self.surface = surface
        }

        func hookUp(_ recognizer: RollNavigationRecognizer) {
            recognizer.oneFingerAxes = { [weak self] point in
                guard let surface = self?.surface else { return [] }
                if point.x < surface.keysWidth { return .vertical }
                return surface.oneFingerPans ? [.horizontal, .vertical] : []
            }
            recognizer.onPressBegan = { [weak self] in self?.surface.onPressBegan() }
            recognizer.onPressEnded = { [weak self] in self?.surface.onPressEnded() }
        }

        @objc func handle(_ recognizer: RollNavigationRecognizer) {
            let camera = surface.camera
            // The camera measures from the grid's left edge, right of the keys.
            let keys = surface.keysWidth
            func grid(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - keys, y: point.y) }
            switch recognizer.state {
            case .began:
                surface.onNavigationBegan()
                camera.beginNavigation(at: grid(recognizer.startCentroid))
                camera.navigate(to: grid(recognizer.centroid), scale: recognizer.scale)
            case .changed:
                if recognizer.rebased {
                    camera.rebaseNavigation(at: grid(recognizer.centroid))
                } else {
                    camera.navigate(to: grid(recognizer.centroid), scale: recognizer.scale)
                }
            case .ended:
                camera.endNavigation(velocity: recognizer.releaseVelocity)
            case .cancelled:
                camera.endNavigation(velocity: .zero)
            default:
                break
            }
        }

        // The tools' drag keeps the touches it has while this moves the roll.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
