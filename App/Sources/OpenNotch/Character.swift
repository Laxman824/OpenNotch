import AppKit
import SwiftUI

// Puff — OpenNotch's notch character. A soft jelly blob with big glossy eyes
// and a sprout, drawn procedurally (SwiftUI Canvas, no images). Original
// design; the interaction ideas (poke → annoyed, 3 pokes → dizzy, happy hop,
// peeking out of the notch) are common pet-app tropes.
//
// Two layers:
//   CharacterBrain — per-view physics + reactions (springs, poke counting,
//                    petting detection, timed expressions). Stepped per frame.
//   PuffCanvas     — pure drawing from (mood, expression, physics snapshot, t).

/// Short-lived expressions from interaction; they outrank the agent mood.
enum PuffExpression: Hashable {
    case annoyed, dizzy, love, surprised, celebrate
    /// The superhero landing: determined brows and a confident grin.
    case heroic
}

@MainActor
final class CharacterBrain: ObservableObject {
    // Springs (units: fraction of size). Not @Published — read during redraw.
    private(set) var squash = 0.0, squashV = 0.0        // + = flatter/wider
    private(set) var hop = 0.0, hopV = 0.0              // height above rest
    private(set) var sway = 0.0, swayV = 0.0            // radians
    private(set) var eyeBoost = 1.0                     // eyes grow while hovered
    private(set) var hearts: [(born: Date, x: Double)] = []
    private(set) var expression: (kind: PuffExpression, until: Date)?

    private var lastStep: Date?
    private var pokes: [Date] = []
    private var hovering = false
    private var petTurns: [Date] = []
    private var lastPetX: CGFloat?
    private var petDir = 0
    private var lastDone: Date?
    private var lastHop = Date.distantPast

    var current: PuffExpression? {
        guard let e = expression, e.until > Date() else { return nil }
        return e.kind
    }

    /// Advance physics to `now` (called from the TimelineView).
    func step(_ now: Date, doneAt: Date?, dragging: Bool) {
        let dt = min(0.05, max(0, now.timeIntervalSince(lastStep ?? now)))
        lastStep = now
        // A turn finished since we last looked: celebrate.
        if let d = doneAt, d != lastDone {
            if lastDone != nil, now.timeIntervalSince(d) < 2 { celebrate(sound: false) }
            lastDone = d
        }
        if dragging, current != .surprised { set(.surprised, for: 0.6) }
        // Jelly: bouncy but settles in ~1 s.
        squashV += (-260 * squash - 11 * squashV) * dt
        squash = max(-0.35, min(0.35, squash + squashV * dt))
        swayV += (-90 * sway - 6 * swayV) * dt
        sway = max(-0.5, min(0.5, sway + swayV * dt))
        if hop > 0 || hopV != 0 {
            hopV -= 7.5 * dt
            hop += hopV * dt
            if hop <= 0 && hopV <= 0 {                          // landing (only while falling)
                hop = 0
                if hopV < -0.4 { squashV += -hopV * 3.2 }      // landing squish
                hopV = 0
            }
        }
        let target = hovering ? 1.14 : 1.0
        eyeBoost += (target - eyeBoost) * min(1, dt * 10)
        hearts.removeAll { now.timeIntervalSince($0.born) > 1.8 }
        if current == .dizzy { sway = 0.12 * sin(now.timeIntervalSinceReferenceDate * 7) }
    }

    // MARK: interactions

    func poke() {
        let now = Date()
        pokes = pokes.filter { now.timeIntervalSince($0) < 1.6 } + [now]
        squashV -= 6.5                                       // squish down…
        swayV += Double.random(in: -2.5...2.5)
        if pokes.count >= 3 {
            pokes = []
            set(.dizzy, for: 3.2)
            SoundFX.play(.dizzy)
        } else if current != .dizzy {
            set(.annoyed, for: 1.3)
            SoundFX.play(.boop)
        }
    }

    func hover(_ on: Bool) {
        if on && !hovering {
            squashV += 2.5                                   // a little perk-up
            if Date().timeIntervalSince(lastHop) > 6 { hopV = 0.9; lastHop = Date(); SoundFX.play(.pop) }
        }
        hovering = on
        if !on { lastPetX = nil; petTurns = [] }
    }

    /// Stroking: the pointer going back and forth over the face.
    func pet(x: CGFloat) {
        let now = Date()
        if let last = lastPetX {
            let dir = x > last + 1 ? 1 : x < last - 1 ? -1 : 0
            if dir != 0 && dir != petDir {
                if petDir != 0 { petTurns.append(now) }
                petDir = dir
            }
        }
        lastPetX = x
        petTurns = petTurns.filter { now.timeIntervalSince($0) < 1.6 }
        if petTurns.count >= 4 {
            petTurns = []
            if current != .love { SoundFX.play(.love) }
            set(.love, for: 2.4)
            for i in 0..<3 { hearts.append((now.addingTimeInterval(Double(i) * 0.18), Double.random(in: -0.35...0.35))) }
            squashV -= 2
        }
    }

    func celebrate(sound: Bool = true) {
        hopV = 1.7
        lastHop = Date()
        set(.celebrate, for: 1.5)
        if sound { SoundFX.play(.yay) }
    }

    /// Peeking out of the notch: a wiggle hello.
    func wave() {
        swayV += 5
        squashV += 3
    }

    private func set(_ e: PuffExpression, for seconds: Double) {
        expression = (e, Date().addingTimeInterval(seconds))
    }
}

// MARK: - Drawing

struct PuffPhysics {
    var squash = 0.0, hop = 0.0, sway = 0.0, eyeBoost = 1.0
    var expression: PuffExpression? = nil
    var hearts: [(age: Double, x: Double)] = []
}

/// Stubby arms and little feet (the perch in the closed notch). Angles in
/// radians: 0 = arm hanging at the side, π/2 = straight out, π = up.
/// Feet: how far each is lifted (0…1).
struct PuffLimbs: Equatable {
    var armL = 0.25, armR = 0.25
    var footL = 0.0, footR = 0.0
}

struct PuffCanvas: View {
    let size: CGFloat
    let mood: AvatarMood
    let palette: AvatarPalette
    let t: Double
    let gaze: CGPoint
    var phys = PuffPhysics()
    var speech: CGFloat? = nil
    var level: CGFloat = 0
    /// Arms and feet, when Puff has a body (nil = the classic blob).
    var limbs: PuffLimbs? = nil
    /// Force eyes shut/open (pre-rendered perch frames); nil = blink on its own clock.
    var blink: Bool? = nil

    private static let ink = Color(red: 0.10, green: 0.07, blue: 0.16)
    private static let blush = Color(red: 1.0, green: 0.45, blue: 0.62)

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height)
            let detailed = s >= 30
            let tiny = s < 24
            let expr = phys.expression
            let happy = mood == .happy || expr == .celebrate || expr == .love

            // ── Body geometry: jelly squash, breathing, hop, sway ──
            let breathe = CGFloat(sin(t * (mood == .sleeping ? 1.0 : 1.9))) * (mood == .sleeping ? 0.03 : 0.018)
            let sq = CGFloat(phys.squash) + breathe
            let w = s * 0.80 * (1 + sq * 0.85)
            let h = s * (tiny ? 0.74 : 0.68) * (1 - sq)
            let ground = sz.height / 2 + s * (tiny ? 0.37 : 0.40)
            let lift = CGFloat(phys.hop) * s * 0.55 + (happy && phys.hop == 0 ? CGFloat(abs(sin(t * 7))) * s * 0.03 : 0)
            let body = CGRect(x: sz.width / 2 - w / 2, y: ground - h - lift, width: w, height: h)

            var g = ctx
            g.translateBy(x: body.midX, y: body.maxY)
            g.rotate(by: .radians(phys.sway + (mood == .listening ? 0.06 * sin(t * 1.2) : 0)))
            g.translateBy(x: -body.midX, y: -body.maxY)

            let top = palette.head.first ?? .purple
            let bottom = palette.head.last ?? .pink
            let bodyPath = RoundedRectangle(cornerRadius: min(w, h) * 0.47, style: .continuous).path(in: body)

            // Soft halo (gradient, not blur).
            if !tiny {
                // Kept inside the canvas: a halo cut off at the frame shows as a dark square on glass.
                let r = min(max(w, h) * 0.8, s * 0.5, body.midY, sz.height - body.midY, body.midX, sz.width - body.midX)
                g.fill(Ellipse().path(in: CGRect(x: body.midX - r, y: body.midY - r, width: r * 2, height: r * 2)),
                       with: .radialGradient(Gradient(colors: [top.opacity(mood == .sleeping ? 0.12 : 0.32), top.opacity(0)]),
                                             center: CGPoint(x: body.midX, y: body.midY), startRadius: w * 0.3, endRadius: r))
            }

            // ── Sprout (sways with the body, perks up when listening, glows when busy) ──
            if !tiny {
                let base = CGPoint(x: body.midX, y: body.minY + h * 0.04)
                let angle = phys.sway * 1.8 + sin(t * 1.6) * 0.10 + (mood == .listening ? -0.15 : 0)
                    + (mood == .working ? sin(t * 9) * 0.25 : 0)
                let len = s * 0.15
                let tip = CGPoint(x: base.x + CGFloat(sin(angle)) * len, y: base.y - CGFloat(cos(angle)) * len)
                var stem = Path()
                stem.move(to: base)
                stem.addQuadCurve(to: tip, control: CGPoint(x: base.x, y: base.y - len * 0.6))
                g.stroke(stem, with: .color(Color(red: 0.36, green: 0.82, blue: 0.52)),
                         style: StrokeStyle(lineWidth: max(1.2, s * 0.035), lineCap: .round))
                let busy = mood == .thinking || mood == .working || mood == .talking
                let leafGlow = busy ? 0.6 + 0.4 * sin(t * 5) : 0.0
                for side in [-1.0, 1.0] {
                    var leaf = g
                    leaf.translateBy(x: tip.x, y: tip.y)
                    leaf.rotate(by: .radians(angle + side * 0.9))
                    let lw = s * 0.12, lh = s * 0.065
                    let rect = CGRect(x: side > 0 ? 0 : -lw, y: -lh / 2, width: lw, height: lh)
                    leaf.fill(Ellipse().path(in: rect), with: .linearGradient(
                        Gradient(colors: [Color(red: 0.55, green: 0.95, blue: 0.62), Color(red: 0.25, green: 0.72, blue: 0.48)]),
                        startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                    if leafGlow > 0 {
                        leaf.fill(Ellipse().path(in: rect.insetBy(dx: -lw * 0.2, dy: -lh * 0.4)),
                                  with: .color(palette.eye.opacity(0.25 * leafGlow)))
                    }
                }
            }

            // ── Limbs, behind the body ──
            if let limbs {
                let edge = Color.black.opacity(0.16)
                // Feet: soft shaded pads under the body; lifted ones rise and tip.
                for (side, lift) in [(-1.0, limbs.footL), (1.0, limbs.footR)] {
                    let fw = w * 0.27, fh = h * 0.21
                    let fx = body.midX + CGFloat(side) * w * 0.2 - fw / 2
                    let fy = body.maxY - fh * 0.55 - CGFloat(lift) * s * 0.09
                    let r = CGRect(x: fx, y: fy, width: fw, height: fh)
                    let foot = Ellipse().path(in: r)
                    g.fill(foot, with: .linearGradient(Gradient(colors: [bottom, bottom.mix(.black, 0.28)]),
                                                       startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
                    g.stroke(foot, with: .color(edge), lineWidth: max(0.6, s * 0.01))
                    if detailed {
                        g.fill(Ellipse().path(in: CGRect(x: r.minX + fw * 0.22, y: r.minY + fh * 0.16, width: fw * 0.32, height: fh * 0.26)),
                               with: .color(.white.opacity(0.3)))
                    }
                }
                // Arms: stubby jelly arms growing out of the body (same colour as the body
                // where they join), with round mitten hands.
                let shoulder = top.mix(bottom, 0.62)
                for (side, angle) in [(-1.0, limbs.armL), (1.0, limbs.armR)] {
                    let len = s * 0.2, thick = s * 0.12
                    var a = g
                    a.translateBy(x: body.midX + CGFloat(side) * w * 0.37, y: body.minY + h * 0.55)
                    a.rotate(by: .radians(-side * angle))       // raise outward on both sides
                    let r = CGRect(x: -thick / 2, y: 0, width: thick, height: len)
                    let arm = Capsule().path(in: r)
                    let shade = Gradient(colors: [shoulder, shoulder.mix(bottom, 0.5).mix(.black, 0.12)])
                    a.fill(arm, with: .linearGradient(shade, startPoint: .zero, endPoint: CGPoint(x: 0, y: len)))
                    let hr = thick * 0.64
                    let hand = Circle().path(in: CGRect(x: -hr, y: len - hr * 1.15, width: hr * 2, height: hr * 2))
                    a.fill(hand, with: .radialGradient(Gradient(colors: [shoulder.mix(.white, 0.18), shoulder.mix(bottom, 0.6)]),
                                                       center: CGPoint(x: -hr * 0.3, y: len - hr * 0.6), startRadius: 0, endRadius: hr * 1.6))
                    a.stroke(hand, with: .color(edge), lineWidth: max(0.6, s * 0.01))
                }
            }

            // ── Body: glossy jelly ──
            g.fill(bodyPath, with: .linearGradient(Gradient(colors: [top, bottom]),
                                                   startPoint: CGPoint(x: body.midX, y: body.minY),
                                                   endPoint: CGPoint(x: body.midX, y: body.maxY)))
            // underside shade + top sheen
            g.fill(bodyPath, with: .radialGradient(Gradient(colors: [.clear, Color.black.opacity(0.18)]),
                                                   center: CGPoint(x: body.midX, y: body.minY + h * 0.35),
                                                   startRadius: w * 0.25, endRadius: w * 0.75))
            if detailed {
                // Jelly: light glowing through the bottom, a soft core, and a rim light on top.
                g.fill(Ellipse().path(in: CGRect(x: body.minX + w * 0.18, y: body.maxY - h * 0.34, width: w * 0.64, height: h * 0.3)),
                       with: .radialGradient(Gradient(colors: [bottom.mix(.white, 0.45).opacity(0.55), bottom.opacity(0)]),
                                             center: CGPoint(x: body.midX, y: body.maxY - h * 0.16), startRadius: 0, endRadius: w * 0.34))
                g.fill(bodyPath, with: .radialGradient(Gradient(colors: [.white.opacity(0.14), .clear]),
                                                       center: CGPoint(x: body.midX, y: body.minY + h * 0.42),
                                                       startRadius: 0, endRadius: w * 0.42))
                g.stroke(bodyPath, with: .linearGradient(Gradient(colors: [.white.opacity(0.42), .white.opacity(0)]),
                                                         startPoint: CGPoint(x: body.midX, y: body.minY),
                                                         endPoint: CGPoint(x: body.midX, y: body.minY + h * 0.45)),
                         lineWidth: max(1, s * 0.018))
            }
            let sheen = CGRect(x: body.minX + w * 0.16, y: body.minY + h * 0.08, width: w * 0.34, height: h * 0.2)
            g.fill(Ellipse().path(in: sheen), with: .color(.white.opacity(0.32)))
            if !tiny {
                g.fill(Circle().path(in: CGRect(x: body.maxX - w * 0.24, y: body.minY + h * 0.16, width: w * 0.06, height: w * 0.06)),
                       with: .color(.white.opacity(0.45)))
            }

            // ── Eyes, on a sphere ──
            var look = gaze
            if mood == .thinking { look = CGPoint(x: sin(t * 1.3) * 0.7, y: -0.75) }
            if mood == .working { look = CGPoint(x: sin(t * 2.6) * 0.55, y: 0.35) }
            if mood == .sleeping { look = .zero }
            let eyeY = body.midY - h * 0.02 + CGFloat(look.y) * h * 0.08
            let spread = w * 0.2
            let boost = CGFloat(phys.eyeBoost) * (expr == .surprised ? 1.25 : 1)
            let ew = w * (tiny ? 0.2 : 0.18) * boost, eh = w * (tiny ? 0.24 : 0.23) * boost
            let lw = max(1.2, s * 0.045)

            // Blink every ~3.8 s (sometimes double). Deterministic in t.
            let period = 3.8, cycle = floor(t / period), phase = t - cycle * period
            let blinking = blink ?? (phase > period - 0.12 || (Int(cycle) % 4 == 1 && phase > period - 0.38 && phase < period - 0.27))

            for side in [-1.0, 1.0] {
                let sideF = CGFloat(side)
                // Perspective: the eye on the side you look toward gets a touch bigger.
                let persp = 1 + 0.10 * CGFloat(look.x) * sideF
                let cx = body.midX + sideF * spread + CGFloat(look.x) * w * 0.10
                let cy = eyeY
                let e = CGRect(x: cx - ew * persp / 2, y: cy - eh * persp / 2, width: ew * persp, height: eh * persp)

                func arc(_ up: Bool, _ k: CGFloat = 0.45) {
                    var p = Path()
                    p.move(to: CGPoint(x: e.minX, y: cy + (up ? eh * 0.12 : -eh * 0.05)))
                    p.addQuadCurve(to: CGPoint(x: e.maxX, y: cy + (up ? eh * 0.12 : -eh * 0.05)),
                                   control: CGPoint(x: cx, y: cy + (up ? -eh * k : eh * k)))
                    g.stroke(p, with: .color(Self.ink), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }

                switch (expr, mood) {
                case (.dizzy?, _):                                                   // @ @ spinning
                    var sp = Path()
                    let turns = 2.4, steps = 40
                    for i in 0...steps {
                        let k = Double(i) / Double(steps)
                        let a = k * turns * 2 * .pi + t * 8 * side
                        let r = CGFloat(k) * ew * 0.55
                        let p = CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r)
                        if i == 0 { sp.move(to: p) } else { sp.addLine(to: p) }
                    }
                    g.stroke(sp, with: .color(Self.ink), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
                case (.love?, _):                                                    // ♥ ♥
                    g.fill(Self.heart(in: e.insetBy(dx: -ew * 0.12, dy: -eh * 0.02)), with: .color(Self.blush))
                    g.fill(Circle().path(in: CGRect(x: e.minX + ew * 0.22, y: e.minY + eh * 0.2, width: ew * 0.22, height: ew * 0.22)),
                           with: .color(.white.opacity(0.8)))
                case (.annoyed?, _):                                                 // flat-lidded glare
                    var lid = g
                    lid.clip(to: Path(CGRect(x: e.minX - 2, y: cy - eh * 0.05, width: e.width + 4, height: eh)))
                    lid.fill(Ellipse().path(in: e), with: .color(Self.ink))
                    var brow = Path()
                    brow.move(to: CGPoint(x: cx - ew * 0.7 * sideF, y: cy - eh * 0.25))
                    brow.addLine(to: CGPoint(x: cx + ew * 0.6 * sideF, y: cy - eh * 0.05))
                    g.stroke(brow, with: .color(Self.ink), style: StrokeStyle(lineWidth: lw * 0.85, lineCap: .round))
                case (.celebrate?, _), (nil, .happy):                                // ^ ^
                    arc(true, 0.55)
                case (nil, .sleeping):                                               // ‿ ‿
                    arc(false, 0.3)
                default:
                    if blinking {
                        arc(false, 0.15)
                    } else {
                        g.fill(Ellipse().path(in: e), with: .color(Self.ink))
                        if detailed {
                            // Iris glow in the lower half: sparkly, coloured eyes.
                            var iris = g
                            iris.clip(to: Ellipse().path(in: e))
                            iris.fill(Ellipse().path(in: CGRect(x: e.minX - ew * 0.1, y: e.midY - eh * 0.05, width: ew * 1.2, height: eh * 0.85)),
                                      with: .radialGradient(Gradient(colors: [palette.eye.opacity(0.75), palette.eye.opacity(0)]),
                                                            center: CGPoint(x: e.midX, y: e.maxY - eh * 0.12), startRadius: 0, endRadius: ew * 0.62))
                        }
                        if expr == .heroic {                                         // determined brows
                            var brow = Path()
                            // Inner ends low, outer ends high: determined, not worried.
                            brow.move(to: CGPoint(x: cx - ew * 0.75 * sideF, y: e.minY - eh * 0.05))
                            brow.addLine(to: CGPoint(x: cx + ew * 0.6 * sideF, y: e.minY - eh * 0.36))
                            g.stroke(brow, with: .color(Self.ink), style: StrokeStyle(lineWidth: lw * 0.95, lineCap: .round))
                        }
                        // big + small catchlights
                        let big = ew * 0.36, small = ew * 0.16
                        g.fill(Circle().path(in: CGRect(x: e.midX - big * 0.15, y: e.minY + eh * 0.14, width: big, height: big)),
                               with: .color(.white.opacity(0.95)))
                        if !tiny {
                            g.fill(Circle().path(in: CGRect(x: e.minX + ew * 0.2, y: e.maxY - eh * 0.34, width: small, height: small)),
                                   with: .color(.white.opacity(0.7)))
                        }
                        if mood == .sad && detailed {                                // worried brows
                            var brow = Path()
                            brow.move(to: CGPoint(x: cx - ew * 0.6 * sideF, y: e.minY - eh * 0.05))
                            brow.addLine(to: CGPoint(x: cx + ew * 0.6 * sideF, y: e.minY - eh * 0.25))
                            g.stroke(brow, with: .color(Self.ink.opacity(0.8)), style: StrokeStyle(lineWidth: lw * 0.7, lineCap: .round))
                        }
                    }
                }

                // Cheeks
                let cheekA = happy ? 0.75 : expr == .annoyed ? 0.85 : 0.42
                let cw = ew * 1.1, ch = eh * 0.42
                g.fill(Ellipse().path(in: CGRect(x: cx + sideF * ew * 0.45 - cw / 2, y: cy + eh * 0.55, width: cw, height: ch)),
                       with: .color(Self.blush.opacity(cheekA)))
            }

            // ── Mouth ──
            let my = eyeY + eh * 0.82
            let mw = w * 0.11
            switch (expr, mood) {
            case (.celebrate?, _), (.love?, _), (nil, .happy):                       // open "D" smile
                var p = Path()
                p.move(to: CGPoint(x: body.midX - mw, y: my - eh * 0.05))
                p.addQuadCurve(to: CGPoint(x: body.midX + mw, y: my - eh * 0.05), control: CGPoint(x: body.midX, y: my + eh * 0.6))
                p.closeSubpath()
                g.fill(p, with: .color(Self.ink))
                if !tiny {
                    g.fill(Ellipse().path(in: CGRect(x: body.midX - mw * 0.45, y: my + eh * 0.12, width: mw * 0.9, height: eh * 0.18)),
                           with: .color(Color(red: 1, green: 0.5, blue: 0.6)))
                }
            case (.heroic?, _):                                                      // confident lopsided grin
                var p = Path()
                p.move(to: CGPoint(x: body.midX - mw * 0.9, y: my + eh * 0.02))
                p.addQuadCurve(to: CGPoint(x: body.midX + mw * 1.0, y: my - eh * 0.12), control: CGPoint(x: body.midX + mw * 0.1, y: my + eh * 0.42))
                p.closeSubpath()
                g.fill(p, with: .color(Self.ink))
                g.fill(Ellipse().path(in: CGRect(x: body.midX - mw * 0.3, y: my + eh * 0.04, width: mw * 0.8, height: eh * 0.1)),
                       with: .color(.white.opacity(0.9)))
            case (.annoyed?, _):                                                     // grumpy squiggle
                var p = Path()
                p.move(to: CGPoint(x: body.midX - mw * 0.8, y: my + eh * 0.08))
                p.addCurve(to: CGPoint(x: body.midX + mw * 0.8, y: my + eh * 0.08),
                           control1: CGPoint(x: body.midX - mw * 0.25, y: my - eh * 0.18),
                           control2: CGPoint(x: body.midX + mw * 0.25, y: my + eh * 0.34))
                g.stroke(p, with: .color(Self.ink), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
            case (.dizzy?, _):
                let r = mw * (0.55 + 0.15 * CGFloat(sin(t * 9)))
                g.fill(Ellipse().path(in: CGRect(x: body.midX - r, y: my, width: r * 2, height: r * 1.3)), with: .color(Self.ink))
            case (.surprised?, _), (nil, .alert):                                     // "o"
                let r = mw * 0.42
                g.fill(Ellipse().path(in: CGRect(x: body.midX - r, y: my, width: r * 2, height: r * 2.4)), with: .color(Self.ink))
            case (nil, .talking):
                let open = speech.map { 0.2 + 0.8 * Double(min(1, $0 * 1.6)) } ?? 0.3 + 0.7 * abs(sin(t * 15) * sin(t * 5.7))
                let hh = max(1.5, eh * 0.55 * CGFloat(open))
                g.fill(Ellipse().path(in: CGRect(x: body.midX - mw * 0.6, y: my, width: mw * 1.2, height: hh)), with: .color(Self.ink))
            case (nil, .sad):
                var p = Path()
                p.move(to: CGPoint(x: body.midX - mw * 0.7, y: my + eh * 0.25))
                p.addQuadCurve(to: CGPoint(x: body.midX + mw * 0.7, y: my + eh * 0.25), control: CGPoint(x: body.midX, y: my - eh * 0.1))
                g.stroke(p, with: .color(Self.ink), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
            case (nil, .sleeping):
                let r = mw * (0.22 + 0.06 * CGFloat(sin(t * 1.0)))
                g.fill(Ellipse().path(in: CGRect(x: body.midX - r, y: my + eh * 0.05, width: r * 2, height: r * 2)), with: .color(Self.ink.opacity(0.8)))
            default:                                                                  // small smile
                var p = Path()
                p.move(to: CGPoint(x: body.midX - mw * 0.55, y: my))
                p.addQuadCurve(to: CGPoint(x: body.midX + mw * 0.55, y: my), control: CGPoint(x: body.midX, y: my + eh * 0.32))
                g.stroke(p, with: .color(Self.ink), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
            }

            // Anger mark
            if expr == .annoyed && !tiny {
                let c = CGPoint(x: body.maxX - w * 0.12, y: body.minY + h * 0.1)
                let r = s * 0.05
                for q in 0..<4 {
                    let a = Double(q) * .pi / 2 + .pi / 4
                    var p = Path()
                    let o = CGPoint(x: c.x + CGFloat(cos(a)) * r * 0.5, y: c.y + CGFloat(sin(a)) * r * 0.5)
                    p.move(to: o)
                    p.addQuadCurve(to: CGPoint(x: c.x + CGFloat(cos(a)) * r * 1.4, y: c.y + CGFloat(sin(a)) * r * 1.4),
                                   control: CGPoint(x: c.x + CGFloat(cos(a + 0.6)) * r, y: c.y + CGFloat(sin(a + 0.6)) * r))
                    g.stroke(p, with: .color(Color(red: 1, green: 0.3, blue: 0.35)), style: StrokeStyle(lineWidth: max(1, s * 0.025), lineCap: .round))
                }
            }

            // ── Floating extras (unrotated) ──
            if !tiny {
                switch (expr, mood) {
                case (.dizzy?, _):                                                    // stars circling the head
                    for i in 0..<3 {
                        let a = t * 4 + Double(i) * 2.094
                        let p = CGPoint(x: body.midX + CGFloat(cos(a)) * w * 0.48, y: body.minY - s * 0.02 + CGFloat(sin(a)) * s * 0.06)
                        ctx.draw(Text("★").font(.system(size: s * 0.13)).foregroundColor(.yellow.opacity(0.6 + 0.4 * sin(a))), at: p)
                    }
                case (.celebrate?, _):                                                 // sparkle burst
                    for i in 0..<4 {
                        let a = Double(i) * .pi / 2 + .pi / 4
                        let k = CGFloat((t * 1.5).truncatingRemainder(dividingBy: 1))
                        let p = CGPoint(x: body.midX + CGFloat(cos(a)) * w * (0.5 + 0.25 * k),
                                        y: body.midY + CGFloat(sin(a)) * h * (0.55 + 0.25 * k))
                        ctx.draw(Text("✦").font(.system(size: s * 0.12)).foregroundColor(palette.eye.opacity(Double(1 - k))), at: p)
                    }
                case (nil, .thinking):
                    for i in 0..<3 {
                        let a = t * 2.4 + Double(i) * 2.094
                        let p = CGPoint(x: body.maxX + CGFloat(cos(a)) * s * 0.05, y: body.minY + CGFloat(sin(a)) * s * 0.05)
                        let r = s * 0.026 * (1 + 0.3 * CGFloat(sin(a)))
                        ctx.fill(Circle().path(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(palette.eye.opacity(0.85)))
                    }
                case (nil, .alert):
                    let y = body.minY - s * 0.04 - CGFloat(abs(sin(t * 5))) * s * 0.05
                    ctx.draw(Text("!").font(.system(size: s * 0.24, weight: .heavy, design: .rounded)).foregroundColor(.yellow),
                             at: CGPoint(x: body.maxX, y: y))
                case (nil, .sleeping):
                    let k = (t * 0.5).truncatingRemainder(dividingBy: 1)
                    ctx.draw(Text("z").font(.system(size: s * (0.13 + 0.08 * k), weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.7 * (1 - k))),
                             at: CGPoint(x: body.maxX + CGFloat(k) * s * 0.06, y: body.minY - CGFloat(k) * s * 0.16))
                default: break
                }
                for heart in phys.hearts where heart.age >= 0 {
                    let k = CGFloat(min(1, heart.age / 1.8))
                    let hs = s * 0.13 * (0.6 + 0.4 * k)
                    let c = CGPoint(x: body.midX + CGFloat(heart.x) * w + CGFloat(sin(heart.age * 6)) * s * 0.03,
                                    y: body.minY - k * s * 0.35)
                    ctx.fill(Self.heart(in: CGRect(x: c.x - hs / 2, y: c.y - hs / 2, width: hs, height: hs)),
                             with: .color(Self.blush.opacity(Double(1 - k))))
                }
            }
        }
    }

    static func heart(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.3),
                   control1: CGPoint(x: r.midX - r.width * 0.1, y: r.maxY - r.height * 0.2),
                   control2: CGPoint(x: r.minX, y: r.midY))
        p.addArc(center: CGPoint(x: r.minX + r.width / 4, y: r.minY + r.height * 0.28), radius: r.width / 4,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: r.maxX - r.width / 4, y: r.minY + r.height * 0.28), radius: r.width / 4,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.midY),
                   control2: CGPoint(x: r.midX + r.width * 0.1, y: r.maxY - r.height * 0.2))
        return p
    }
}

// MARK: - Sounds (synthesised here — original, tiny, and quiet)

@MainActor
enum SoundFX {
    enum Kind: CaseIterable { case pop, boop, dizzy, love, yay, peek }

    private static var cache: [Kind: NSSound] = [:]

    static func play(_ k: Kind) {
        guard Prefs.on(Prefs.characterSounds) else { return }
        if let s = cache[k] {
            s.stop(); s.play(); return
        }
        let data = wav(k)
        guard let s = NSSound(data: data) else { return }
        s.volume = 0.22
        cache[k] = s
        s.play()
    }

    /// Notes as (frequency start, frequency end, seconds); short sine chirps with soft envelopes.
    private static func notes(_ k: Kind) -> [(Double, Double, Double)] {
        switch k {
        case .pop: return [(620, 1240, 0.07)]
        case .boop: return [(520, 360, 0.09)]
        case .dizzy: return [(700, 520, 0.12), (620, 430, 0.12), (540, 330, 0.18)]
        case .love: return [(1180, 1400, 0.07), (0, 0, 0.04), (1320, 1580, 0.09)]
        case .yay: return [(784, 784, 0.07), (988, 988, 0.07), (1175, 1300, 0.14)]
        case .peek: return [(420, 820, 0.12)]
        }
    }

    static func wav(_ k: Kind) -> Data {
        let rate = 22_050.0
        var samples: [Int16] = []
        for (f0, f1, dur) in notes(k) {
            let n = Int(dur * rate)
            var phase = 0.0
            for i in 0..<n {
                let x = Double(i) / Double(max(1, n - 1))
                let f = f0 + (f1 - f0) * x + (k == .dizzy ? 25 * sin(Double(i) / rate * 2 * .pi * 18) : 0)
                phase += 2 * .pi * f / rate
                let env = min(1, x / 0.08) * pow(1 - x, 1.6)                  // quick attack, soft tail
                let v = f0 == 0 ? 0 : (sin(phase) + 0.18 * sin(phase * 2)) * env * 0.55
                samples.append(Int16(max(-1, min(1, v)) * 32_000))
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}


extension Color {
    /// Linear blend toward `other` (0 = self, 1 = other), in sRGB.
    func mix(_ other: Color, _ k: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white, b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let f = CGFloat(max(0, min(1, k)))
        return Color(red: Double(a.redComponent + (b.redComponent - a.redComponent) * f),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * f),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * f),
                     opacity: Double(a.alphaComponent + (b.alphaComponent - a.alphaComponent) * f))
    }
}
