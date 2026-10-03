import AppKit
import Combine
import SwiftUI

// Ledge's perch: when nothing else needs the closed notch, Puff (with arms and
// feet) sits in a little ear beside it and lives there — breathes, blinks,
// follows the pointer, and now and then waves, stretches, yawns, kicks its feet,
// hops, or walks behind the camera to the other side. It types along while you
// type, dances while music plays and dozes off when you're away. The other ear
// counts down to your next meeting.
//
// Cost: one small Canvas at AnimationPolicy's fps (24, or 12 on battery / Low
// Power), 6 fps while asleep, paused whenever the notch is open or hidden.

enum PerchAction: String, CaseIterable {
    case idle, wave, stretch, yawn, kick, hop, lookAround, walk
    /// How long each one plays (walk is set by the distance).
    var duration: Double {
        switch self {
        case .idle: return 0
        case .wave: return 1.6
        case .stretch: return 1.9
        case .yawn: return 1.8
        case .kick: return 2.4
        case .hop: return 0.9
        case .lookAround: return 2.2
        case .walk: return 2.4
        }
    }
}

/// Pure pose maths (checked by `--checks`): what the limbs, gaze and mouth do
/// at progress `p` (0…1) of an action, or in a continuous state.
enum PerchPose {
    struct Pose: Equatable {
        var limbs = PuffLimbs()
        var gaze: CGPoint? = nil          // nil = follow the pointer
        var mood: AvatarMood? = nil       // overrides the agent mood
        var bob: CGFloat = 0              // body lift, fraction of size
    }

    static func action(_ a: PerchAction, p: Double, t: Double) -> Pose {
        var pose = Pose()
        let env = sin(min(1, max(0, p)) * .pi)                       // 0 → 1 → 0 over the action
        switch a {
        case .idle:
            pose.limbs.armL = 0.25 + 0.05 * sin(t * 1.9)
            pose.limbs.armR = 0.25 + 0.05 * sin(t * 1.9 + 0.4)
        case .wave:
            pose.limbs.armR = 0.25 + env * (2.3 + 0.35 * sin(t * 14))
            pose.mood = .happy
        case .stretch:
            pose.limbs.armL = 0.25 + env * 2.6
            pose.limbs.armR = 0.25 + env * 2.6
            pose.bob = CGFloat(env) * 0.06
        case .yawn:
            pose.limbs.armL = 0.25 + env * 1.2
            pose.mood = env > 0.35 ? .sleeping : nil                // eyes shut, small round mouth
            pose.gaze = CGPoint(x: 0, y: -0.6)
        case .kick:
            pose.limbs.footL = max(0, sin(t * 9)) * env
            pose.limbs.footR = max(0, sin(t * 9 + .pi)) * env
            pose.limbs.armL = 0.45; pose.limbs.armR = 0.45
        case .hop:
            pose.limbs.armL = 0.25 + env * 1.4
            pose.limbs.armR = 0.25 + env * 1.4
        case .lookAround:
            pose.gaze = CGPoint(x: sin(p * .pi * 2) * 0.9, y: -0.2)
        case .walk:
            let step = sin(t * 11)
            pose.limbs.footL = max(0, step) * 0.8
            pose.limbs.footR = max(0, -step) * 0.8
            pose.limbs.armL = 0.35 + 0.35 * step
            pose.limbs.armR = 0.35 - 0.35 * step
            pose.bob = CGFloat(abs(step)) * 0.035
        }
        return pose
    }

    /// While you type: arms tap along.
    static func typing(t: Double) -> Pose {
        var pose = Pose()
        pose.limbs.armL = 0.9 + 0.25 * max(0, sin(t * 22))
        pose.limbs.armR = 0.9 + 0.25 * max(0, sin(t * 22 + .pi))
        pose.gaze = CGPoint(x: 0, y: 0.7)
        return pose
    }

    /// While music plays: a bouncy little dance (~2 beats a second).
    static func dance(t: Double) -> Pose {
        var pose = Pose()
        let beat = sin(t * 2 * .pi * 2)
        pose.limbs.armL = 1.4 + 0.9 * beat
        pose.limbs.armR = 1.4 - 0.9 * beat
        pose.limbs.footL = max(0, beat) * 0.6
        pose.limbs.footR = max(0, -beat) * 0.6
        pose.bob = CGFloat(abs(beat)) * 0.05
        pose.mood = .happy
        return pose
    }

    /// The superhero landing: one fist on the ground, the other arm thrown back, a knee up.
    static func hero() -> Pose {
        var pose = Pose()
        pose.limbs.armR = 0.05                      // fist down to the floor
        pose.limbs.armL = 1.9                       // arm flung back and up
        pose.limbs.footL = 0.35
        pose.gaze = CGPoint(x: 0.35, y: 0.1)
        return pose
    }

    /// Watching something with you: settled, eyes on the screen below.
    static func watching() -> Pose {
        var pose = Pose()
        pose.limbs.armL = 0.15; pose.limbs.armR = 0.15
        pose.gaze = CGPoint(x: 0, y: 0.75)
        return pose
    }

    static func asleep() -> Pose {
        var pose = Pose()
        pose.limbs.armL = 0.1; pose.limbs.armR = 0.1
        pose.mood = .sleeping
        return pose
    }

    /// Seconds until the next idle action (livelier = sooner).
    static func pause(_ l: Liveliness) -> ClosedRange<Double> {
        switch l { case .calm: return 25...50; case .friendly: return 10...22; case .lively: return 5...11 }
    }
}

/// Picks what Puff does next. Not published per frame — the TimelineView reads it.
@MainActor
final class PerchBrain: ObservableObject {
    private(set) var action: PerchAction = .idle {
        // Rare (a few times a minute): lets the view switch its frame rate. Deferred,
        // because step() runs while SwiftUI is drawing.
        didSet { if action != oldValue { DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() } } }
    }
    private(set) var started = Date()
    private var next = Date().addingTimeInterval(3)
    /// 0 = left ear, 1 = right ear; during a walk, the position between them.
    private(set) var x: Double = 0
    private var walkFrom: Double = 0
    let physics = CharacterBrain()

    func step(_ now: Date) {
        let p = progress(now)
        if action == .walk { x = walkFrom + (walkFrom == 0 ? 1 : -1) * smooth(p) }
        if action != .idle && p >= 1 {
            if action == .walk { x = walkFrom == 0 ? 1 : 0 }
            action = .idle
            next = now.addingTimeInterval(Double.random(in: PerchPose.pause(Liveliness.current)))
        }
        if action == .idle && now >= next { begin(Self.pick(), now) }
    }

    func progress(_ now: Date) -> Double {
        action.duration > 0 ? min(1, now.timeIntervalSince(started) / action.duration) : 0
    }

    private func begin(_ a: PerchAction, _ now: Date) {
        action = a
        started = now
        walkFrom = x
        switch a {
        case .hop: physics.celebrate(sound: false)
        case .wave: physics.wave()
        default: break
        }
    }

    /// Weighted: mostly small things, a walk now and then.
    static func pick() -> PerchAction {
        let bag: [PerchAction] = [.wave, .wave, .stretch, .yawn, .kick, .kick, .hop, .lookAround, .lookAround, .walk, .walk]
        return bag.randomElement() ?? .wave
    }

    private func smooth(_ p: Double) -> Double { p * p * (3 - 2 * p) }
}

/// What the perch needs from the notch, published only when it actually changes —
/// observing Backend/NotchController directly rebuilt the perch on every unrelated
/// publish (audio levels, privacy polls…), which cost more than the animation itself.
@MainActor
final class PerchModel: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var notchSize = CGSize(width: 190, height: 30)
    @Published private(set) var ear: CGFloat = 40

    func sync(visible v: Bool, notchSize n: CGSize, ear e: CGFloat) {
        if v != visible { visible = v }
        if n != notchSize { notchSize = n }
        if e != ear { ear = e }
    }
}

// MARK: - Drawing without SwiftUI's frame loop

/// Pre-rendered Puff frames. Any SwiftUI update costs ~0.5 % CPU per frame/s in this
/// app (even for a plain dot), so the perch renders each distinct frame once with
/// ImageRenderer and then only swaps CALayer contents. Physics (squash, hop, sway)
/// is a layer transform, not part of the image. LRU-capped (~6 MB).
@MainActor
final class PerchSprites {
    struct Key: Hashable {
        var clip: String          // "idle", an action, "typing", "dance", "sleep"
        var frame: Int
        var gazeX: Int            // -1, 0, 1
        var blink: Bool
        var mood: AvatarMood
        var expression: PuffExpression?
        var palette: String
    }

    static let fps = 12.0
    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let limit = 320
    var scale: CGFloat = 2

    /// Frames in a clip at 12 fps (loops for idle/typing/dance/sleep).
    static func frames(_ clip: String) -> Int {
        switch clip {
        case "idle": return 48            // 4 s breathing loop
        case "typing", "dance": return 12 // 1 s
        case "sleep": return 16           // zzz drifting up, at 4 fps → 4 s
        case "watch", "hero": return 1
        default: return max(1, Int(((PerchAction(rawValue: clip)?.duration ?? 1) * fps).rounded()))
        }
    }

    func image(_ k: Key, size: CGFloat) -> CGImage? {
        if let hit = cache[k] { return hit }
        let t = 1000 + Double(k.frame) / (k.clip == "sleep" ? 4 : Self.fps)
        let pose: PerchPose.Pose
        switch k.clip {
        case "typing": pose = PerchPose.typing(t: t)
        case "dance": pose = PerchPose.dance(t: t)
        case "sleep": pose = PerchPose.asleep()
        case "watch": pose = PerchPose.watching()
        case "hero": pose = PerchPose.hero()
        case "idle": pose = PerchPose.action(.idle, p: 0, t: t)
        default:
            let a = PerchAction(rawValue: k.clip) ?? .idle
            pose = PerchPose.action(a, p: Double(k.frame) / Double(max(1, Self.frames(k.clip) - 1)), t: t)
        }
        let view = PuffCanvas(size: size, mood: pose.mood ?? k.mood, palette: AvatarPalette.named(k.palette), t: t,
                              gaze: pose.gaze ?? CGPoint(x: Double(k.gazeX) * 0.75, y: 0.1),
                              phys: PuffPhysics(expression: k.expression), limbs: pose.limbs, blink: k.blink ? true : nil)
            .frame(width: size, height: size)
        let r = ImageRenderer(content: view)
        r.scale = scale
        guard let img = r.cgImage else { return nil }
        cache[k] = img
        order.append(k)
        if order.count > limit { cache[order.removeFirst()] = nil }
        return img
    }

    func clear() { cache = [:]; order = [] }
}

/// The perch: an AppKit view with one CALayer for Puff, driven by a light timer.
/// Never takes the mouse — clicks and hovers go to the notch underneath.
@MainActor
final class PerchHostView: NSView {
    private let model: PerchModel
    private let backend: Backend
    private let hub: Hub
    private let brain = PerchBrain()
    private let sprites = PerchSprites()
    private let puff = CALayer()
    private let label = CATextLayer()
    private var timer: Timer?
    private var subs: Set<AnyCancellable> = []
    private var ticks = 0
    private var typing = false, asleep = false, music = false
    private var interval: TimeInterval = 0

    init(model: PerchModel, backend: Backend, hub: Hub) {
        self.model = model
        self.backend = backend
        self.hub = hub
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        puff.contentsGravity = .resizeAspect
        puff.anchorPoint = CGPoint(x: 0.5, y: 0)              // squash/sway from the feet
        layer?.addSublayer(puff)
        label.fontSize = 11.5
        label.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        label.alignmentMode = .center
        label.foregroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.addSublayer(label)
        model.$visible.removeDuplicates().sink { [weak self] v in self?.setRunning(v) }.store(in: &subs)
        UserDefaults.standard.publisher(for: \.avatarPalette).sink { [weak self] _ in self?.sprites.clear() }.store(in: &subs)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        if s != sprites.scale { sprites.scale = s; sprites.clear() }
        puff.contentsScale = s
        label.contentsScale = s
    }

    private func setRunning(_ on: Bool) {
        isHidden = !on
        if on { schedule(1 / PerchSprites.fps); render() } else { timer?.invalidate(); timer = nil }
    }

    private func schedule(_ every: TimeInterval) {
        guard every != interval || timer == nil else { return }
        interval = every
        timer?.invalidate()
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        typing = key < 0.7
        asleep = min(key, mouse) > 180
        music = backend.nowPlaying.playing
        if ticks % 360 == 0 { label.string = nextMeeting(Date()).map { "📅 " + $0 } ?? "" }
        // Asleep: 4 fps. Otherwise 12 — the frames are cached, so a frame costs almost nothing.
        schedule(asleep || Attention.shared.state == .watching ? 0.25 : 1 / PerchSprites.fps)
    }

    private func render() {
        guard !isHidden else { return }
        if ticks % 3 == 0 { sample() }
        ticks += 1
        let now = Date()
        let watching = Attention.shared.state == .watching
        if !watching { brain.step(now) }                     // no antics during your movie
        let ph = brain.physics
        ph.step(now, doneAt: backend.lastDoneAt, dragging: false)

        let size = max(22, model.notchSize.height - 3)
        let ear = model.ear
        let width = model.notchSize.width + 2 * ear
        let palette = UserDefaults.standard.string(forKey: "avatarPalette") ?? "aurora"
        let gx = AssistantFace.gaze().x
        let gazeX = gx > 0.35 ? 1 : gx < -0.35 ? -1 : 0
        let clock = now.timeIntervalSinceReferenceDate

        var key = PerchSprites.Key(clip: "idle", frame: 0, gazeX: gazeX, blink: false, mood: .idle,
                                   expression: ph.current, palette: palette)
        var bob = 0.0
        if watching {
            key.clip = "watch"; key.gazeX = 0
            key.blink = clock.truncatingRemainder(dividingBy: 4.6) > 4.3
        } else if asleep {
            key.clip = "sleep"; key.frame = Int(clock * 4) % PerchSprites.frames("sleep"); key.gazeX = 0
        } else if music && brain.action != .walk {
            key.clip = "dance"; key.frame = Int(clock * PerchSprites.fps) % 12; key.gazeX = 0
            bob = PerchPose.dance(t: 1000 + Double(key.frame) / PerchSprites.fps).bob
        } else if brain.action == .idle && typing {
            key.clip = "typing"; key.frame = Int(clock * PerchSprites.fps) % 12; key.gazeX = 0
        } else if brain.action == .idle {
            key.frame = Int(clock * PerchSprites.fps) % 48
            // Blink about every 3.8 s for two frames.
            key.blink = clock.truncatingRemainder(dividingBy: 3.8) > 3.62
            if key.blink { key.frame = 0 }
        } else {
            key.clip = brain.action.rawValue
            let n = PerchSprites.frames(key.clip)
            key.frame = min(n - 1, Int(brain.progress(now) * Double(n - 1)))
            key.gazeX = 0
            bob = PerchPose.action(brain.action, p: brain.progress(now), t: 1000 + Double(key.frame) / PerchSprites.fps).bob
        }
        if ph.current == nil { key.expression = nil }
        key.mood = currentMood(backend: backend, listening: false, now: now)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let img = sprites.image(key, size: size) { puff.contents = img }
        let x0 = ear / 2, x1 = width - ear / 2
        let cx = x0 + (x1 - x0) * CGFloat(brain.x)
        let h = bounds.height
        puff.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        // Layer coordinates: y up. Feet near the bottom of the ear; hop/bob lift.
        let lift = CGFloat(ph.hop) * size * 0.55 + CGFloat(bob) * size
        puff.position = CGPoint(x: cx, y: h - size - 1 + lift)
        let sq = CGFloat(ph.squash)
        var tr = CATransform3DMakeRotation(-CGFloat(ph.sway), 0, 0, 1)
        tr = CATransform3DScale(tr, 1 + sq * 0.85, 1 - sq, 1)
        puff.transform = tr
        label.frame = CGRect(x: brain.x < 0.5 ? width - ear : 0, y: (h - 15) / 2, width: ear, height: 15)
        label.opacity = brain.action == .walk ? 0 : 1
        CATransaction.commit()
    }

    private func nextMeeting(_ now: Date) -> String? {
        guard let e = hub.calendar.events(from: now, to: now.addingTimeInterval(90 * 60)).first(where: { !$0.isAllDay }) else { return nil }
        let mins = Int(ceil(e.startDate.timeIntervalSince(now) / 60))
        return mins <= 0 ? "now" : "\(mins)m"
    }
}

extension UserDefaults {
    /// KVO-observable "avatarPalette" key (the perch re-renders its frames when it changes).
    @objc dynamic var avatarPalette: String? { string(forKey: "avatarPalette") }
}

// MARK: - The little walker on the chat bar

/// Puff strolling along the top edge of "Ask Ledge anything…": walks to and fro,
/// stops to wave, look around or stretch, types along while you type, looks up
/// thinking while the assistant works, and hops when an answer lands. Same cached
/// frames on a CALayer as the perch; the timer runs only while the chat is open.
@MainActor
final class ComposerWalkerView: NSView {
    private let backend: Backend
    private let sprites = PerchSprites()
    private let physics = CharacterBrain()
    private let puff = CALayer()
    private var timer: Timer?
    private var x: CGFloat = 0.15                   // 0…1 along the bar
    private var dir: CGFloat = 1
    private var clip: PerchAction = .walk
    private var clipStart = Date()
    private var nextChange = Date().addingTimeInterval(4)
    private var last = Date()
    var size: CGFloat = 26

    var active = false {
        didSet {
            guard active != oldValue else { return }
            isHidden = !active
            timer?.invalidate(); timer = nil
            guard active else { return }
            last = Date()
            let t = Timer(timeInterval: 1 / PerchSprites.fps, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    init(backend: Backend) {
        self.backend = backend
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        puff.anchorPoint = CGPoint(x: 0.5, y: 0)
        puff.contentsGravity = .resizeAspect
        layer?.addSublayer(puff)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        if s != sprites.scale { sprites.scale = s; sprites.clear() }
        puff.contentsScale = s
    }

    private func pickNext(_ now: Date) {
        // Mostly walking, with little stops.
        let bag: [PerchAction] = [.walk, .walk, .walk, .idle, .wave, .lookAround, .stretch, .kick]
        clip = bag.randomElement() ?? .walk
        clipStart = now
        if clip == .walk && Bool.random() { dir = -dir }
        if clip == .wave { physics.wave() }
        nextChange = now.addingTimeInterval(clip == .walk ? Double.random(in: 3...7)
                                            : clip == .idle ? Double.random(in: 1.5...3.5) : clip.duration)
    }

    private func tick() {
        guard active, bounds.width > size * 2 else { return }
        let now = Date()
        let dt = min(0.2, now.timeIntervalSince(last))
        last = now
        physics.step(now, doneAt: backend.lastDoneAt, dragging: false)
        let typing = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 0.7
        let busy = backend.busy
        if now >= nextChange && !typing && !busy { pickNext(now) }

        let palette = UserDefaults.standard.string(forKey: "avatarPalette") ?? "aurora"
        var key = PerchSprites.Key(clip: "idle", frame: 0, gazeX: 0, blink: false, mood: .idle,
                                   expression: physics.current, palette: palette)
        let clock = now.timeIntervalSinceReferenceDate
        if busy {
            // Waiting for the answer: stand still and think.
            key.frame = Int(clock * PerchSprites.fps) % 48
            key.mood = currentMood(backend: backend, listening: false, now: now)
        } else if typing {
            key.clip = "typing"; key.frame = Int(clock * PerchSprites.fps) % 12
        } else if clip == .walk {
            let span = bounds.width - size
            x += dir * CGFloat(dt) * 38 / max(1, span)
            if x >= 1 { x = 1; dir = -1 } else if x <= 0 { x = 0; dir = 1 }
            key.clip = "walk"
            key.frame = Int(clock * PerchSprites.fps) % PerchSprites.frames("walk")
            key.gazeX = dir > 0 ? 1 : -1                // looks where it's going
        } else if clip == .idle {
            key.frame = Int(clock * PerchSprites.fps) % 48
            key.blink = clock.truncatingRemainder(dividingBy: 3.8) > 3.62
            if key.blink { key.frame = 0 }
        } else {
            key.clip = clip.rawValue
            let n = PerchSprites.frames(key.clip)
            let p = min(1, now.timeIntervalSince(clipStart) / clip.duration)
            key.frame = min(n - 1, Int(p * Double(n - 1)))
        }
        if physics.current == nil { key.expression = nil }
        if !busy { key.mood = currentMood(backend: backend, listening: false, now: now) == .happy ? .happy : .idle }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let img = sprites.image(key, size: size) { puff.contents = img }
        puff.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let cx = size / 2 + (bounds.width - size) * x
        // Feet on the bar's top edge (this view's bottom); hops lift it.
        puff.position = CGPoint(x: cx, y: -size * 0.1 + CGFloat(physics.hop) * size * 0.55)
        let sq = CGFloat(physics.squash)
        var tr = CATransform3DMakeRotation(-CGFloat(physics.sway), 0, 0, 1)
        tr = CATransform3DScale(tr, 1 + sq * 0.85, 1 - sq, 1)
        puff.transform = tr
        CATransaction.commit()
    }
}

struct ComposerWalker: NSViewRepresentable {
    let backend: Backend
    var active: Bool
    var size: CGFloat = 26

    func makeNSView(context: Context) -> ComposerWalkerView {
        let v = ComposerWalkerView(backend: backend)
        v.size = size
        return v
    }

    func updateNSView(_ v: ComposerWalkerView, context: Context) {
        v.size = size
        v.active = active && UserDefaults.standard.string(forKey: "character.style") ?? "puff" == "puff"
    }
}
