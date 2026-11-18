import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Observation

// A drawing moved and zoomed the way a photo is: two fingers take hold of it and carry
// it in any direction while they pinch it bigger or smaller, all at once. Fingers held
// level, side by side, stretch it across and nothing else; held upright, one above the
// other, they stretch it up and down and nothing else; held any other way, they zoom
// it both ways alike, exactly as a photo zooms. One finger moves it too, wherever the
// screen lets it. The MIDI editor's piano roll and the review screen both go through
// this, so the two handle exactly alike.
//
// Neither is a scroll view. Nested ones (one up and down, one across) could only ever
// move along one of their axes at a time, and a scroll view zooms both ways alike or
// not at all. Instead the camera here says what the drawing shows, and the screen draws
// through it, only as much of the drawing as is on screen.

// MARK: - What the camera shows

/// What a camera shows: how far it's zoomed each way, and which point of the content
/// is at the top left corner of the viewport.
///
/// The content keeps its own units (the editor's unzoomed points, the review screen's
/// beats and semitones), so whatever is laid out or edited in them stays as it is, and
/// only drawing and touches go through a shot.
struct PanZoomShot: Equatable {
    /// The point of the content at the viewport's top left corner.
    var origin: CGPoint
    /// Screen points to one of the content's units: across, and down.
    var zoom: CGSize

    /// The point of the content drawn at `point` in the viewport.
    func content(at point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x / zoom.width, y: origin.y + point.y / zoom.height)
    }

    /// Where `rect` of the content is drawn in the viewport.
    func screen(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - origin.x) * zoom.width, y: (rect.minY - origin.y) * zoom.height,
               width: rect.width * zoom.width, height: rect.height * zoom.height)
    }

    /// The shot at `zoom` that draws `point` of the content at `screen` in the viewport.
    static func holding(_ point: CGPoint, at screen: CGPoint, zoom: CGSize) -> PanZoomShot {
        PanZoomShot(origin: CGPoint(x: point.x - screen.x / zoom.width,
                                    y: point.y - screen.y / zoom.height),
                    zoom: zoom)
    }
}

/// How far a camera may go, each way.
struct PanZoomLimits: Equatable {
    /// How far it may go along one axis.
    struct Dimension: Equatable {
        /// As far out and as far in as it zooms, in screen points to one of the
        /// content's units.
        var zoom: ClosedRange<CGFloat>
        /// The stretch of content there is to show.
        var content: ClosedRange<CGFloat>
        /// The point along the viewport, from its leading edge, that has to stay over
        /// the content: what the screen reads the content at, such as the review
        /// screen's playhead. nil keeps the whole viewport over the content instead,
        /// both ends of it, and the leading end where all of it is on screen at once.
        var focus: CGFloat? = nil

        /// The furthest the origin may go at `zoom`, with a viewport `length` long.
        func origins(zoom: CGFloat, length: CGFloat) -> ClosedRange<CGFloat> {
            if let focus {
                return (content.lowerBound - focus / zoom)...(content.upperBound - focus / zoom)
            }
            return content.lowerBound...max(content.lowerBound, content.upperBound - length / zoom)
        }
    }

    var x: Dimension
    var y: Dimension

    /// Nowhere to go: what a camera has until its screen says how far it may.
    static let none = PanZoomLimits(x: Dimension(zoom: 1...1, content: 0...0),
                                    y: Dimension(zoom: 1...1, content: 0...0))
}

// MARK: - Camera

/// Where a drawing is scrolled to and how far it's zoomed each way, and the motion that
/// carries it on once the fingers let go: gliding to a stop, or springing back from past
/// an edge or a zoom limit, as a scroll view does.
///
/// Only the views that draw through it watch it (see `PanZoomCanvas`), so the drawing
/// moves every frame without the screen around it being asked to redraw.
@Observable
final class PanZoomCamera {
    /// What the camera shows.
    private(set) var shot = PanZoomShot(origin: .zero, zoom: CGSize(width: 1, height: 1))
    /// Whether the scroll indicators are up: while the view moves, and a moment after.
    private(set) var indicatorsShown = false

    /// Whether the camera has been put anywhere yet (see `jump(to:)`). Until then
    /// `shot` stands for nothing, and a screen draws whatever it opens on instead.
    @ObservationIgnored private(set) var isPlaced = false
    /// The viewport, in screen points.
    @ObservationIgnored private(set) var viewport = CGSize.zero
    /// How far the camera may go.
    @ObservationIgnored private(set) var limits = PanZoomLimits.none

    /// Whether fingers are moving the view.
    var isNavigating: Bool { navigation != nil }
    /// Whether the view is on its way somewhere by itself.
    var isMoving: Bool { motion != nil }

    // MARK: Limits

    /// The furthest the origin may go at `zoom`, each way.
    func origins(zoom: CGSize) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        (limits.x.origins(zoom: zoom.width, length: viewport.width),
         limits.y.origins(zoom: zoom.height, length: viewport.height))
    }

    /// `origin` held inside the limits at `zoom`.
    func clamped(_ origin: CGPoint, zoom: CGSize) -> CGPoint {
        let ranges = origins(zoom: zoom)
        return CGPoint(x: origin.x.clamped(to: ranges.x), y: origin.y.clamped(to: ranges.y))
    }

    /// `zoom` held inside the limits, each way on its own.
    private func clampedZoom(_ zoom: CGSize) -> CGSize {
        CGSize(width: zoom.width.clamped(to: limits.x.zoom),
               height: zoom.height.clamped(to: limits.y.zoom))
    }

    /// The viewport is `size` now, and the camera may go as far as `newLimits`. The
    /// content may also have moved by `shift` under it (the MIDI editor's dead margin
    /// growing in front of beat 0): the camera moves along with it, so what was on
    /// screen stays where it was.
    func update(viewport size: CGSize, limits newLimits: PanZoomLimits, shift: CGVector = .zero) {
        guard size != viewport || newLimits != limits || shift != .zero else { return }
        if shift != .zero {
            // Whatever the view was on its way to has moved too.
            stopMotion()
            shot.origin.x += shift.dx
            shot.origin.y += shift.dy
            navigation?.free.origin.x += shift.dx
            navigation?.free.origin.y += shift.dy
        }
        viewport = size
        limits = newLimits
        settleIntoLimits()
    }

    /// Straight back inside the zoom limits (about the viewport's middle) and the
    /// content's, after the viewport or the limits changed. Not while fingers have
    /// hold of the view: the rubber band takes the new limits in, and the fingers let
    /// go into them.
    private func settleIntoLimits() {
        guard isPlaced, navigation == nil, viewport.width > 0, viewport.height > 0 else { return }
        var settled = shot
        let zoom = clampedZoom(settled.zoom)
        if zoom != settled.zoom {
            let middle = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            settled = .holding(settled.content(at: middle), at: middle, zoom: zoom)
        }
        settled.origin = clamped(settled.origin, zoom: zoom)
        guard settled != shot else { return }
        stopMotion()
        show(settled, indicating: false)
    }

    // MARK: Moving it from code

    /// Straight to `newShot`, held inside the limits, without the scroll indicators:
    /// where a screen opens, or where a jump along a timeline takes it.
    func jump(to newShot: PanZoomShot) {
        stopMotion()
        isPlaced = true
        let zoom = clampedZoom(newShot.zoom)
        show(PanZoomShot(origin: clamped(newShot.origin, zoom: zoom), zoom: zoom), indicating: false)
        // Fingers already on the view go on from wherever it was put.
        if let navigation { hold(at: navigation.centroid, zoomAxes: navigation.zoomAxes) }
    }

    /// To `origin`, which the caller has already held inside the limits, with the
    /// scroll indicators up: a drag scrolling the MIDI editor's roll at its edge.
    func scroll(to origin: CGPoint) {
        show(PanZoomShot(origin: origin, zoom: shot.zoom))
    }

    /// Springs across to `x`, held inside the limits: playback keeping the MIDI
    /// editor's playhead on screen.
    func glide(toX x: CGFloat) {
        guard navigation == nil else { return }
        let target = clamped(CGPoint(x: x, y: shot.origin.y), zoom: shot.zoom).x
        motion = .drift(x: .springing(target: target, velocity: 0), y: .still)
        startTicking()
    }

    /// Stops whatever the view is doing by itself, where it is. Returns whether it was
    /// doing anything.
    @discardableResult
    func stopMotion() -> Bool {
        let wasMoving = motion != nil
        motion = nil
        stopTicking()
        return wasMoving
    }

    /// The rest of the way back inside the limits, for a press that stopped the view
    /// springing back and let go without moving it.
    func resumeSettling() {
        guard isPlaced, navigation == nil, motion == nil,
              viewport.width > 0, viewport.height > 0 else { return }
        settle(around: CGPoint(x: viewport.width / 2, y: viewport.height / 2),
               velocity: .zero, zoom: clampedZoom(shot.zoom))
    }

    // MARK: Fingers

    /// Fingers moving the view.
    private struct Navigation {
        /// Where the fingers' midpoint was at the last move.
        var centroid: CGPoint
        /// The shot they'd be holding if nothing held the view back. What it shows is
        /// that, held back by the rubber band past its edges and zoom limits.
        var free: PanZoomShot
        /// Which ways their pinch zooms: both, or only one.
        var zoomAxes: Axis.Set
        /// The zoom shown when the fingers last landed or lifted, which a pinch both
        /// ways scales as one, so the view keeps its shape.
        var base: CGSize
    }
    @ObservationIgnored private var navigation: Navigation?

    /// Fingers have taken hold of the view with their midpoint at `centroid` in the
    /// viewport, to pinch it along `zoomAxes`. Whatever it was doing by itself stops
    /// where it is.
    func beginNavigation(at centroid: CGPoint, zoomAxes: Axis.Set) {
        stopMotion()
        hold(at: centroid, zoomAxes: zoomAxes)
    }

    /// A finger landed or lifted, so the midpoint jumped to `centroid` and the pinch
    /// may zoom other ways now. The view stays where it is and goes on from there.
    func rebaseNavigation(at centroid: CGPoint, zoomAxes: Axis.Set) {
        guard navigation != nil else { return }
        hold(at: centroid, zoomAxes: zoomAxes)
    }

    private func hold(at centroid: CGPoint, zoomAxes: Axis.Set) {
        navigation = Navigation(centroid: centroid,
                                free: unbanded(shot, around: centroid, zoomAxes: zoomAxes),
                                zoomAxes: zoomAxes, base: shot.zoom)
    }

    /// The fingers' midpoint moved to `centroid`, and they spread to `scale` times as
    /// far apart the way they pinch: the point of the content that was under them is
    /// under them still, at the new size.
    func navigate(to centroid: CGPoint, scale: CGFloat) {
        guard var navigation else { return }
        let held = navigation.free.content(at: navigation.centroid)
        var zoom = navigation.free.zoom
        if navigation.zoomAxes.contains(.horizontal) {
            zoom.width = (zoom.width * scale).clamped(to: Self.freeZooms)
        }
        if navigation.zoomAxes.contains(.vertical) {
            zoom.height = (zoom.height * scale).clamped(to: Self.freeZooms)
        }
        navigation.free = .holding(held, at: centroid, zoom: zoom)
        navigation.centroid = centroid
        self.navigation = navigation
        show(banded(navigation, around: centroid))
    }

    /// The fingers let go, moving at `velocity`, in points a second across the viewport.
    func endNavigation(velocity: CGVector) {
        guard let navigation else { return }
        self.navigation = nil
        settle(around: navigation.centroid, velocity: velocity,
               zoom: settledZoom(shot.zoom, after: navigation))
    }

    /// The zoom the fingers leave the view at once it's back inside the limits. A pinch
    /// both ways shrinks back as one, so the view keeps the shape it had.
    private func settledZoom(_ zoom: CGSize, after navigation: Navigation) -> CGSize {
        guard navigation.zoomAxes == [.horizontal, .vertical] else { return clampedZoom(zoom) }
        let scale = (zoom.width / navigation.base.width).clamped(to: uniformScales(from: navigation.base))
        return clampedZoom(CGSize(width: navigation.base.width * scale,
                                  height: navigation.base.height * scale))
    }

    /// How far a pinch both ways may scale `base`: as far as keeps both of its axes
    /// inside their limits, since the two scale as one.
    private func uniformScales(from base: CGSize) -> ClosedRange<CGFloat> {
        let low = max(limits.x.zoom.lowerBound / base.width, limits.y.zoom.lowerBound / base.height)
        let high = min(limits.x.zoom.upperBound / base.width, limits.y.zoom.upperBound / base.height)
        return min(low, high)...high
    }

    /// Any zoom the fingers can take the free shot to, so a pinch that runs on past a
    /// limit can't overflow it.
    private static let freeZooms: ClosedRange<CGFloat> = 0.0001...10_000

    // MARK: Rubber band

    /// The most the zoom gives past either of its limits, as the logarithm of a ratio:
    /// about a third.
    private static let zoomGive: CGFloat = log(1.35)

    /// The free shot as it's shown: held back past an edge or a zoom limit the way a
    /// scroll view's rubber band holds it, with the point of the content under
    /// `centroid` kept there.
    private func banded(_ navigation: Navigation, around centroid: CGPoint) -> PanZoomShot {
        let zoom = bandedZoom(navigation.free.zoom, zoomAxes: navigation.zoomAxes,
                              base: navigation.base)
        var shown = PanZoomShot.holding(navigation.free.content(at: centroid), at: centroid, zoom: zoom)
        let ranges = origins(zoom: zoom)
        shown.origin.x = banded(shown.origin.x, within: ranges.x, zoom: zoom.width, span: viewport.width)
        shown.origin.y = banded(shown.origin.y, within: ranges.y, zoom: zoom.height, span: viewport.height)
        return shown
    }

    /// The free shot `banded(_:around:)` shows as `shown`, for fingers pinching along
    /// `zoomAxes`: for taking hold of the view where it is, still springing back,
    /// say, or with a finger just landed.
    private func unbanded(_ shown: PanZoomShot, around centroid: CGPoint,
                          zoomAxes: Axis.Set) -> PanZoomShot {
        let ranges = origins(zoom: shown.zoom)
        var held = shown
        held.origin.x = unbanded(shown.origin.x, within: ranges.x, zoom: shown.zoom.width,
                                 span: viewport.width)
        held.origin.y = unbanded(shown.origin.y, within: ranges.y, zoom: shown.zoom.height,
                                 span: viewport.height)
        return .holding(held.content(at: centroid), at: centroid,
                        zoom: unbandedZoom(shown.zoom, zoomAxes: zoomAxes))
    }

    private func banded(_ value: CGFloat, within range: ClosedRange<CGFloat>,
                        zoom: CGFloat, span: CGFloat) -> CGFloat {
        if value < range.lowerBound {
            return range.lowerBound - rubberBand((range.lowerBound - value) * zoom, span: span) / zoom
        }
        if value > range.upperBound {
            return range.upperBound + rubberBand((value - range.upperBound) * zoom, span: span) / zoom
        }
        return value
    }

    private func unbanded(_ value: CGFloat, within range: ClosedRange<CGFloat>,
                          zoom: CGFloat, span: CGFloat) -> CGFloat {
        if value < range.lowerBound {
            return range.lowerBound - stretch(drawnAs: (range.lowerBound - value) * zoom, span: span) / zoom
        }
        if value > range.upperBound {
            return range.upperBound + stretch(drawnAs: (value - range.upperBound) * zoom, span: span) / zoom
        }
        return value
    }

    /// The zoom shown for a free one. A pinch one way is held back on that axis alone;
    /// a pinch both ways scales `base` as one, held back as soon as either axis
    /// reaches its limit.
    private func bandedZoom(_ free: CGSize, zoomAxes: Axis.Set, base: CGSize) -> CGSize {
        switch zoomAxes {
        case .horizontal:
            return CGSize(width: band(free.width, within: limits.x.zoom), height: base.height)
        case .vertical:
            return CGSize(width: base.width, height: band(free.height, within: limits.y.zoom))
        default:
            let scale = band(free.width / base.width, within: uniformScales(from: base))
            return CGSize(width: base.width * scale, height: base.height * scale)
        }
    }

    /// The free zoom `bandedZoom` shows as `shown`, with `shown` as the base.
    private func unbandedZoom(_ shown: CGSize, zoomAxes: Axis.Set) -> CGSize {
        switch zoomAxes {
        case .horizontal:
            return CGSize(width: unband(shown.width, within: limits.x.zoom), height: shown.height)
        case .vertical:
            return CGSize(width: shown.width, height: unband(shown.height, within: limits.y.zoom))
        default:
            let scale = unband(1, within: uniformScales(from: shown))
            return CGSize(width: shown.width * scale, height: shown.height * scale)
        }
    }

    /// A zoom past a limit, held back the same way as a position past an edge, by the
    /// ratio rather than the distance.
    private func band(_ zoom: CGFloat, within range: ClosedRange<CGFloat>) -> CGFloat {
        if zoom > range.upperBound {
            return range.upperBound * exp(rubberBand(log(zoom / range.upperBound), span: Self.zoomGive))
        }
        if zoom < range.lowerBound {
            return range.lowerBound / exp(rubberBand(log(range.lowerBound / zoom), span: Self.zoomGive))
        }
        return zoom
    }

    private func unband(_ zoom: CGFloat, within range: ClosedRange<CGFloat>) -> CGFloat {
        if zoom > range.upperBound {
            return range.upperBound * exp(stretch(drawnAs: log(zoom / range.upperBound), span: Self.zoomGive))
        }
        if zoom < range.lowerBound {
            return range.lowerBound / exp(stretch(drawnAs: log(range.lowerBound / zoom), span: Self.zoomGive))
        }
        return zoom
    }

    // MARK: Motion

    /// One axis of the view moving by itself, in the content's units.
    private enum Drift {
        case still
        /// Gliding to a stop, at `velocity` units a second for now.
        case coasting(velocity: CGFloat)
        /// Springing to `target`, at `velocity` units a second for now.
        case springing(target: CGFloat, velocity: CGFloat)
    }

    private enum Motion {
        /// Each axis on its own way.
        case drift(x: Drift, y: Drift)
        /// Back inside the zoom limits, from `from` to `to`, keeping what's at `anchor`
        /// in the viewport there as it goes. `remaining` of the way is left, shrinking at
        /// `velocity` a second.
        case rezoom(from: PanZoomShot, to: PanZoomShot, anchor: CGPoint,
                    remaining: CGFloat, velocity: CGFloat)
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

    /// The fingers let go with their midpoint at `centroid`: to `zoom` if the view is
    /// at any other, and otherwise on at the speed they let go at, each axis springing
    /// back inside the limits wherever it's past one.
    private func settle(around centroid: CGPoint, velocity: CGVector, zoom: CGSize) {
        let current = shot.zoom
        if abs(zoom.width - current.width) > current.width * 0.0001
            || abs(zoom.height - current.height) > current.height * 0.0001 {
            let target = PanZoomShot.holding(shot.content(at: centroid), at: centroid, zoom: zoom)
            let to = PanZoomShot(origin: clamped(target.origin, zoom: zoom), zoom: zoom)
            motion = .rezoom(from: shot, to: to, anchor: centroid, remaining: 1, velocity: 0)
        } else {
            let ranges = origins(zoom: current)
            let x = drift(from: shot.origin.x, within: ranges.x,
                          velocity: -velocity.dx / current.width, zoom: current.width)
            let y = drift(from: shot.origin.y, within: ranges.y,
                          velocity: -velocity.dy / current.height, zoom: current.height)
            if case .still = x, case .still = y {
                motion = nil
            } else {
                motion = .drift(x: x, y: y)
            }
        }
        if motion != nil { startTicking() }
    }

    private func drift(from value: CGFloat, within range: ClosedRange<CGFloat>,
                       velocity: CGFloat, zoom: CGFloat) -> Drift {
        if value < range.lowerBound { return .springing(target: range.lowerBound, velocity: velocity) }
        if value > range.upperBound { return .springing(target: range.upperBound, velocity: velocity) }
        if abs(velocity) * zoom < Self.slowestGlide { return .still }
        return .coasting(velocity: velocity)
    }

    /// Moves the view on by `seconds` of whatever it's doing.
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
                let zoom = CGSize(width: from.zoom.width * pow(to.zoom.width / from.zoom.width, progress),
                                  height: from.zoom.height * pow(to.zoom.height / from.zoom.height, progress))
                let start = from.content(at: anchor), end = to.content(at: anchor)
                let held = CGPoint(x: start.x + (end.x - start.x) * progress,
                                   y: start.y + (end.y - start.y) * progress)
                self.motion = .rezoom(from: from, to: to, anchor: anchor,
                                      remaining: remaining, velocity: velocity)
                show(.holding(held, at: anchor, zoom: zoom))
            }
        case .drift(var x, var y):
            let zoom = shot.zoom
            let ranges = origins(zoom: zoom)
            let origin = CGPoint(
                x: advance(&x, from: shot.origin.x, within: ranges.x, zoom: zoom.width, over: seconds),
                y: advance(&y, from: shot.origin.y, within: ranges.y, zoom: zoom.height, over: seconds))
            if case .still = x, case .still = y {
                self.motion = nil
            } else {
                self.motion = .drift(x: x, y: y)
            }
            show(PanZoomShot(origin: origin, zoom: zoom))
        }
    }

    /// Where one axis at `value` is `seconds` later, with `drift` updated to how it's
    /// moving by then. `zoom` turns its speed and distance into screen points, which is
    /// what decides when it has stopped.
    private func advance(_ drift: inout Drift, from value: CGFloat, within range: ClosedRange<CGFloat>,
                         zoom: CGFloat, over seconds: CGFloat) -> CGFloat {
        switch drift {
        case .still:
            return value
        case .coasting(let velocity):
            // Exactly as far as the speed, shed at the scroll view's rate, carries it.
            let rate = log(Self.decelerationRate) * 1000
            let decay = exp(rate * seconds)
            let next = value + velocity * (decay - 1) / rate
            let slower = velocity * decay
            if next < range.lowerBound {
                // Carried into an edge: past it a little, and back.
                drift = .springing(target: range.lowerBound, velocity: slower)
            } else if next > range.upperBound {
                drift = .springing(target: range.upperBound, velocity: slower)
            } else if abs(slower) * zoom < 5 {
                drift = .still
            } else {
                drift = .coasting(velocity: slower)
            }
            return next
        case .springing(let target, var velocity):
            var position = value
            Self.spring(&position, &velocity, to: target, over: seconds)
            if abs(position - target) * zoom < 0.2, abs(velocity) * zoom < 5 {
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
    private func show(_ newShot: PanZoomShot, indicating: Bool = true) {
        guard newShot != shot else { return }
        shot = newShot
        if indicating { flashIndicators() }
    }

    // MARK: Ticking

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTick: CFTimeInterval?

    private func startTicking() {
        guard link == nil else { return }
        let link = CADisplayLink(target: PanZoomTicker(self),
                                 selector: #selector(PanZoomTicker.tick(_:)))
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

    /// How long the indicators stay up after the view stops.
    private static let indicatorLinger: CFTimeInterval = 0.5
    @ObservationIgnored private var lastMoved: CFTimeInterval = 0
    @ObservationIgnored private var indicatorCheck: Task<Void, Never>?

    private func flashIndicators() {
        lastMoved = CACurrentMediaTime()
        if !indicatorsShown { indicatorsShown = true }
        if indicatorCheck == nil { checkIndicators(after: Self.indicatorLinger) }
    }

    /// Takes the indicators down once the view has been still for `indicatorLinger`
    /// with no fingers on it, looking again `delay` from now. One check at a time,
    /// however often the view moves.
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

/// How far past an edge the view is drawn when fingers have pulled it `stretch` past
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
private final class PanZoomTicker: NSObject {
    private weak var camera: PanZoomCamera?

    init(_ camera: PanZoomCamera) {
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

/// A canvas drawn through a camera: redrawn whenever the camera moves, without
/// anything around it being asked to redraw.
struct PanZoomCanvas: View {
    let camera: PanZoomCamera
    let draw: (inout GraphicsContext, CGSize, PanZoomShot) -> Void

    var body: some View {
        // Read here, in the body, so it's this view a move of the camera redraws.
        let shot = camera.shot
        Canvas { context, size in draw(&context, size, shot) }
    }
}

/// Builds its content from what a camera shows, again whenever the camera moves,
/// without the view around it being asked to.
struct PanZoomReader<Content: View>: View {
    let camera: PanZoomCamera
    @ViewBuilder let content: (PanZoomShot) -> Content

    var body: some View {
        content(camera.shot)
    }
}

/// A camera's scroll indicators: thin bars along the viewport's right and bottom
/// edges, up while the view moves, as a scroll view has them. For content the
/// viewport keeps both ends over (limits without a focus).
struct PanZoomScrollIndicators: View {
    let camera: PanZoomCamera

    var body: some View {
        let shot = camera.shot
        let shown = camera.indicatorsShown
        Canvas { context, size in
            let limits = camera.limits
            let thickness: CGFloat = 3
            let inset: CGFloat = 3
            let shortest: CGFloat = 30
            let seen = CGSize(width: size.width / shot.zoom.width, height: size.height / shot.zoom.height)
            let wide = limits.x.content.upperBound - limits.x.content.lowerBound
            let tall = limits.y.content.upperBound - limits.y.content.lowerBound
            let across = wide > seen.width + 0.5
            let down = tall > seen.height + 0.5
            let shading = GraphicsContext.Shading.color(.white.opacity(0.45))
            if across {
                let track = size.width - inset * 2 - (down ? thickness + inset : 0)
                let length = min(track, max(shortest, track * seen.width / wide))
                let progress = ((shot.origin.x - limits.x.content.lowerBound) / (wide - seen.width))
                    .clamped(to: 0...1)
                let bar = CGRect(x: inset + (track - length) * progress,
                                 y: size.height - inset - thickness,
                                 width: length, height: thickness)
                context.fill(Path(roundedRect: bar, cornerRadius: thickness / 2), with: shading)
            }
            if down {
                let track = size.height - inset * 2 - (across ? thickness + inset : 0)
                let length = min(track, max(shortest, track * seen.height / tall))
                let progress = ((shot.origin.y - limits.y.content.lowerBound) / (tall - seen.height))
                    .clamped(to: 0...1)
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

/// Picks out the touches that move and zoom a drawing: two fingers anywhere on it, and
/// one finger wherever the screen lets one (see `oneFingerAxes`).
///
/// Where one finger is the screen's own, drawing with a tool in the MIDI editor, say,
/// two fingers never land at quite the same moment, so the first has usually been
/// handed to the tool already when the second comes down. A second finger still takes
/// the press over if it comes soon after the first, or before the first has gone
/// anywhere; any later, and the first finger's drawing goes on undisturbed.
///
/// Which ways two fingers zoom is settled as they land: held level or upright, within
/// `oneWayPinchTolerance`, they stretch the drawing that way alone; held any other
/// way, they zoom it both ways alike. It's one or the other, never a blend.
final class PanZoomRecognizer: UIGestureRecognizer {
    /// How soon after the first finger a second one still takes the press over.
    static let takeOverWindow: TimeInterval = 0.25
    /// How little the first finger may have moved for a second one to take the press
    /// over, however long after it landed.
    static let takeOverTravel: CGFloat = 10
    /// How far off level, or off upright, two fingers may land and still pinch the
    /// one way alone: 15°.
    static let oneWayPinchTolerance: CGFloat = .pi / 12
    /// Fingers closer than this to their midpoint, the way they pinch, don't zoom:
    /// there's too little distance between them to read a change in it from.
    private static let shortestSpread: CGFloat = 8

    /// Which ways one finger landing at a point moves the drawing: none where it's
    /// the screen's own.
    var oneFingerAxes: (CGPoint) -> Axis.Set = { _ in [] }
    /// The first finger of a press has landed.
    var onPressBegan: () -> Void = {}
    /// The last finger of a press has lifted, or the press was taken away.
    var onPressEnded: () -> Void = {}

    /// Where the fingers' midpoint was when the gesture began.
    private(set) var startCentroid = CGPoint.zero
    /// Where it is now, left where it was along any axis the gesture doesn't move on.
    private(set) var centroid = CGPoint.zero
    /// How many times as far apart the fingers are as at the last report, the way
    /// they pinch.
    private(set) var scale: CGFloat = 1
    /// Which ways the fingers pinch: both, or only across, or only up and down.
    private(set) var zoomAxes: Axis.Set = [.horizontal, .vertical]
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
                // Too late: the first finger is the screen's, and this one plays no part.
                for touch in touches { ignore(touch, for: event) }
                return
            }
            fingers.append(contentsOf: touches)
            if fingers.count >= 2 {
                axes = [.horizontal, .vertical]
                begin(from: nil, at: event.timestamp)
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
            // One finger that moves the drawing moves it from where it landed, so none
            // of the way it has come already is lost.
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
        zoomAxes = [.horizontal, .vertical]
    }

    /// Whether a finger landing at `time` beside the press's first one takes the
    /// press over.
    private func mayTakeOver(at time: TimeInterval) -> Bool {
        !axes.isEmpty || time - landedAt <= Self.takeOverWindow || strayed <= Self.takeOverTravel
    }

    /// Starts the gesture from `point`, or from where the fingers are when that's nil.
    private func begin(from point: CGPoint?, at time: TimeInterval) {
        settlePinch()
        let start = point ?? midpoint()
        startCentroid = start
        centroid = start
        lastMidpoint = start
        lastSpread = spread()
        scale = 1
        rebased = false
        path = .zero
        samples = [(time, .zero)]
        state = .began
    }

    /// Settles which ways the fingers down now pinch: two held level or upright
    /// stretch that way alone, any others zoom both ways.
    private func settlePinch() {
        guard let view, fingers.count == 2 else {
            zoomAxes = [.horizontal, .vertical]
            return
        }
        let a = fingers[0].location(in: view)
        let b = fingers[1].location(in: view)
        // 0 for fingers side by side, a right angle for one above the other.
        let angle = atan2(abs(b.y - a.y), abs(b.x - a.x))
        if angle <= Self.oneWayPinchTolerance {
            zoomAxes = .horizontal
        } else if angle >= .pi / 2 - Self.oneWayPinchTolerance {
            zoomAxes = .vertical
        } else {
            zoomAxes = [.horizontal, .vertical]
        }
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
        settlePinch()
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

    /// How far the fingers are from their midpoint on average, the way they pinch:
    /// straight-line for a pinch both ways, across or up and down for one way alone.
    private func spread() -> CGFloat {
        guard let view, fingers.count >= 2 else { return 0 }
        let middle = midpoint()
        let total = fingers.reduce(CGFloat(0)) { sum, finger in
            let point = finger.location(in: view)
            let dx = point.x - middle.x, dy = point.y - middle.y
            switch zoomAxes {
            case .horizontal: return sum + abs(dx)
            case .vertical: return sum + abs(dy)
            default: return sum + hypot(dx, dy)
            }
        }
        return total / CGFloat(fingers.count)
    }
}

/// The surface laid over a drawing that moves and zooms it. A screen's own drag (the
/// MIDI editor's tools) is SwiftUI's, on the view around it, and sees the same touches:
/// this takes only the ones that move the drawing, and says when a press has become one
/// of those so the screen can let go of it.
///
/// A press that lands while the drawing is still gliding stops it, as a scroll view's
/// does, and one that lets go of it partway back from past an edge sends it the rest of
/// the way.
struct PanZoomTouchSurface: UIViewRepresentable {
    let camera: PanZoomCamera
    /// Where the camera's viewport starts on the surface: the MIDI editor's grid starts
    /// right of its keys.
    var viewportOrigin: CGPoint = .zero
    /// Which ways one finger landing at a point on the surface moves the drawing: none
    /// where the screen keeps one finger for itself.
    let oneFingerAxes: (CGPoint) -> Axis.Set
    /// The first finger of a press has landed, and whether that stopped the drawing
    /// moving by itself (in which case the press was there only for that).
    var onPressBegan: (_ stoppedMotion: Bool) -> Void = { _ in }
    /// The last finger of a press has lifted.
    var onPressEnded: () -> Void = {}
    /// The press has become one that moves the drawing.
    var onNavigationBegan: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Without this the view is handed only the first finger, and never sees a pinch.
        view.isMultipleTouchEnabled = true
        let recognizer = PanZoomRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handle(_:)))
        recognizer.delegate = context.coordinator
        // The screen's own drag goes on seeing the touches; this only takes the drawing.
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
        var surface: PanZoomTouchSurface

        init(surface: PanZoomTouchSurface) {
            self.surface = surface
        }

        func hookUp(_ recognizer: PanZoomRecognizer) {
            recognizer.oneFingerAxes = { [weak self] point in
                self?.surface.oneFingerAxes(point) ?? []
            }
            recognizer.onPressBegan = { [weak self] in
                guard let surface = self?.surface else { return }
                surface.onPressBegan(surface.camera.stopMotion())
            }
            recognizer.onPressEnded = { [weak self] in
                guard let surface = self?.surface else { return }
                surface.onPressEnded()
                surface.camera.resumeSettling()
            }
        }

        @objc func handle(_ recognizer: PanZoomRecognizer) {
            let camera = surface.camera
            // The camera measures from its viewport's top left corner.
            let origin = surface.viewportOrigin
            func viewport(_ point: CGPoint) -> CGPoint {
                CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            }
            switch recognizer.state {
            case .began:
                surface.onNavigationBegan()
                camera.beginNavigation(at: viewport(recognizer.startCentroid),
                                       zoomAxes: recognizer.zoomAxes)
                camera.navigate(to: viewport(recognizer.centroid), scale: recognizer.scale)
            case .changed:
                if recognizer.rebased {
                    camera.rebaseNavigation(at: viewport(recognizer.centroid),
                                            zoomAxes: recognizer.zoomAxes)
                } else {
                    camera.navigate(to: viewport(recognizer.centroid), scale: recognizer.scale)
                }
            case .ended:
                camera.endNavigation(velocity: recognizer.releaseVelocity)
            case .cancelled:
                camera.endNavigation(velocity: .zero)
            default:
                break
            }
        }

        // The screen's own drag keeps the touches it has while this moves the drawing.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
