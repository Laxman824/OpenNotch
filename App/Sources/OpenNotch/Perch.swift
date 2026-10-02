import AppKit
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

/// A hosting view that never takes the mouse: clicks and hovers reach the notch underneath.
final class PassThroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The perch layer: Puff only while the notch is closed and nothing else owns the ears.
struct PerchLayer: View {
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController
    @ObservedObject var hub: Hub

    var body: some View {
        ZStack {
            if notch.mode == .collapsed && notch.showsPerch {
                PerchView(backend: backend, notch: notch, hub: hub)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct PerchView: View {
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController
    @ObservedObject var hub: Hub
    @StateObject private var brain = PerchBrain()
    @ObservedObject private var policy = AnimationPolicy.shared
    @AppStorage("avatarPalette") private var paletteID = "aurora"
    /// "14m" to the next meeting (refreshed every 30 s, not per frame).
    @State private var soon: String?
    /// Sampled 4× a second, not per frame (each sample is a window-server call).
    @State private var typing = false
    @State private var asleep = false

    var body: some View {
        let ear = notch.perchEarWidth
        let size = max(22, notch.notchSize.height - 3)
        let width = notch.notchSize.width + 2 * ear
        ZStack(alignment: .topLeading) {
            Color.clear
            // Only the character redraws per frame; the cadence follows what it's doing.
            TimelineView(.periodic(from: .now, by: 1.0 / frameRate)) { ctx in
                let now = ctx.date
                let t = now.timeIntervalSinceReferenceDate
                let _ = brain.step(now)
                let pose = currentPose(t: t, now: now)
                let ph = brain.physics
                let _ = ph.step(now, doneAt: backend.lastDoneAt, dragging: false)
                // Centre of the left ear → centre of the right ear.
                let x0 = ear / 2, x1 = width - ear / 2
                let cx = x0 + (x1 - x0) * CGFloat(brain.x)
                PuffCanvas(size: size, mood: pose.mood ?? currentMood(backend: backend, listening: false, now: now),
                           palette: AvatarPalette.named(paletteID), t: t,
                           gaze: pose.gaze ?? AssistantFace.gaze(),
                           phys: PuffPhysics(squash: ph.squash, hop: ph.hop, sway: ph.sway, eyeBoost: ph.eyeBoost,
                                             expression: ph.current,
                                             hearts: ph.hearts.map { (now.timeIntervalSince($0.born), $0.x) }),
                           limbs: pose.limbs)
                    .frame(width: size, height: size)
                    .offset(x: cx - size / 2, y: 1 - pose.bob * size)
            }
            .frame(width: width, height: notch.notchSize.height)
            .contentShape(Rectangle())
            .onTapGesture { brain.physics.poke() }
            // The other ear: the next meeting, if it's soon.
            if let soon {
                HStack(spacing: 3) {
                    Image(systemName: "calendar").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Module.calendar.accent)
                    Text(soon).font(Typo.numeric(11.5)).foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: ear, height: notch.notchSize.height)
                .offset(x: width - ear)
            }
        }
        .frame(width: width, height: notch.notchSize.height)
        .task {
            var n = 0
            while !Task.isCancelled {
                let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
                if typing != (key < 0.7) { typing = key < 0.7 }
                if asleep != (min(key, mouse) > 180) { asleep = min(key, mouse) > 180 }
                if n % 120 == 0 { soon = nextMeeting(Date()) }
                n += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): brain.physics.hover(true); brain.physics.pet(x: p.x)
            case .ended: brain.physics.hover(false)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(UserDefaults.standard.string(forKey: "assistantName") ?? "Ledge") is here")
    }

    /// 4 fps asleep, 12 idling (breathing and blinks read fine), full policy rate while moving.
    private var frameRate: Double {
        if asleep { return 4 }
        let moving = typing || backend.nowPlaying.playing || brain.action != .idle
        return moving ? policy.fps : min(12, policy.fps)
    }

    private func currentPose(t: Double, now: Date) -> PerchPose.Pose {
        if asleep { return PerchPose.asleep() }
        if backend.nowPlaying.playing && brain.action != .walk { return PerchPose.dance(t: t) }
        if brain.action == .idle && typing { return PerchPose.typing(t: t) }
        return PerchPose.action(brain.action, p: brain.progress(now), t: t)
    }

    private func nextMeeting(_ now: Date) -> String? {
        guard let e = hub.calendar.events(from: now, to: now.addingTimeInterval(90 * 60)).first(where: { !$0.isAllDay }) else { return nil }
        let mins = Int(ceil(e.startDate.timeIntervalSince(now) / 60))
        return mins <= 0 ? "now" : "\(mins)m"
    }
}
