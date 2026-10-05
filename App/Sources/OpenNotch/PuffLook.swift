import SwiftUI

// Puff's look: body shape, accessory and finish, chosen in onboarding ("Make me yours") or
// Settings › General. One string pref (`puff.look` = "shape/accessory/finish"), so the cached
// sprites (PerchSprites.Key.look) and every PuffCanvas pick it up. The default — blob, sprout,
// jelly — is the original Puff. Original designs (a plush-toy line-up was the starting point only).

enum PuffShape: String, CaseIterable, Identifiable {
    case blob, bunny, bear, kitty, dino, ghost, mushroom, star, cloud, owl
    var id: String { rawValue }
    var name: String {
        switch self {
        case .blob: return "Puff"
        case .bunny: return "Bunny"
        case .bear: return "Bear"
        case .kitty: return "Kitty"
        case .dino: return "Dino"
        case .ghost: return "Ghost"
        case .mushroom: return "Shroom"
        case .star: return "Star"
        case .cloud: return "Cloud"
        case .owl: return "Owl"
        }
    }
    /// Body size relative to the classic blob (width, height).
    var scale: (w: CGFloat, h: CGFloat) {
        switch self {
        case .blob: return (1, 1)
        case .bunny: return (0.9, 0.84)
        case .bear: return (0.98, 0.94)
        case .kitty: return (0.88, 1.0)
        case .dino: return (0.8, 1.04)
        case .ghost: return (0.9, 1.0)
        case .mushroom: return (0.98, 1.1)
        case .star: return (1.12, 1.08)
        case .cloud: return (1.1, 0.95)
        case .owl: return (0.9, 1.04)
        }
    }
    /// Its own arms/feet replace the stubby ones (star points, owl wings, a ghost's hem).
    var hidesArms: Bool { self == .star || self == .owl }
    var hidesFeet: Bool { self == .ghost }
    /// Face lower/wider for some (as a fraction of the body height / spread).
    var faceDrop: CGFloat { self == .mushroom ? 0.15 : (self == .bear ? 0.02 : (self == .owl ? -0.02 : 0)) }
    var faceSpread: CGFloat { self == .owl ? 1.12 : (self == .mushroom ? 0.9 : 1) }
}

enum PuffAccessory: String, CaseIterable, Identifiable {
    case none, sprout, headphones, scarf, pocket, bow, crown, glasses, beanie, flower, antenna
    var id: String { rawValue }
    var name: String {
        switch self {
        case .none: return "None"
        case .sprout: return "Sprout"
        case .headphones: return "Headphones"
        case .scarf: return "Scarf"
        case .pocket: return "Pocket"
        case .bow: return "Bow"
        case .crown: return "Crown"
        case .glasses: return "Glasses"
        case .beanie: return "Beanie"
        case .flower: return "Flower"
        case .antenna: return "Antenna"
        }
    }
    var icon: String {
        switch self {
        case .none: return "circle.slash"
        case .sprout: return "leaf.fill"
        case .headphones: return "headphones"
        case .scarf: return "wind"
        case .pocket: return "rectangle.bottomhalf.filled"
        case .bow: return "gift.fill"
        case .crown: return "crown.fill"
        case .glasses: return "eyeglasses"
        case .beanie: return "snowflake"
        case .flower: return "camera.macro"
        case .antenna: return "antenna.radiowaves.left.and.right"
        }
    }
}

enum PuffFinish: String, CaseIterable, Identifiable {
    case jelly, plush
    var id: String { rawValue }
    var name: String { self == .jelly ? "Jelly" : "Plush" }
}

struct PuffLook: Equatable {
    var shape = PuffShape.blob
    var accessory = PuffAccessory.sprout
    var finish = PuffFinish.jelly

    static let pref = "puff.look"
    static let original = PuffLook()

    var id: String { "\(shape.rawValue)/\(accessory.rawValue)/\(finish.rawValue)" }

    init(shape: PuffShape = .blob, accessory: PuffAccessory = .sprout, finish: PuffFinish = .jelly) {
        self.shape = shape; self.accessory = accessory; self.finish = finish
    }

    /// Parses "shape/accessory/finish"; anything unknown keeps the original's part.
    init(id: String) {
        let p = id.split(separator: "/").map(String.init)
        shape = p.count > 0 ? PuffShape(rawValue: p[0]) ?? .blob : .blob
        accessory = p.count > 1 ? PuffAccessory(rawValue: p[1]) ?? .sprout : .sprout
        finish = p.count > 2 ? PuffFinish(rawValue: p[2]) ?? .jelly : .jelly
    }

    static var currentID: String { UserDefaults.standard.string(forKey: pref) ?? original.id }
    static var current: PuffLook { PuffLook(id: currentID) }

    /// A random look (the "Surprise me" button) that differs from `not`.
    static func surprise(not: PuffLook, roll: (Int) -> Int) -> PuffLook {
        for _ in 0..<8 {
            let l = PuffLook(shape: PuffShape.allCases[roll(PuffShape.allCases.count)],
                             accessory: PuffAccessory.allCases[roll(PuffAccessory.allCases.count)],
                             finish: PuffFinish.allCases[roll(PuffFinish.allCases.count)])
            if l != not { return l }
        }
        return not == original ? PuffLook(shape: .star, accessory: .scarf, finish: .plush) : original
    }
}

// MARK: - Drawing

enum PuffDraw {
    private static let edge = Color.black.opacity(0.16)
    private static let pink = Color(red: 1.0, green: 0.62, blue: 0.72)

    /// The body outline for a shape inside `r` (its bounding box; feet on r.maxY). `t` ripples a ghost's hem.
    static func bodyPath(_ shape: PuffShape, in r: CGRect, t: Double = 0) -> Path {
        let w = r.width, h = r.height
        switch shape {
        case .blob, .bear:
            return RoundedRectangle(cornerRadius: min(w, h) * (shape == .bear ? 0.5 : 0.47), style: .continuous).path(in: r)
        case .bunny, .owl:                                              // an egg: narrower on top
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + 0.58 * h),
                       control1: CGPoint(x: r.midX + 0.4 * w, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + 0.26 * h))
            p.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                       control1: CGPoint(x: r.maxX, y: r.maxY - 0.06 * h), control2: CGPoint(x: r.midX + 0.34 * w, y: r.maxY))
            p.addCurve(to: CGPoint(x: r.minX, y: r.minY + 0.58 * h),
                       control1: CGPoint(x: r.midX - 0.34 * w, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - 0.06 * h))
            p.addCurve(to: CGPoint(x: r.midX, y: r.minY),
                       control1: CGPoint(x: r.minX, y: r.minY + 0.26 * h), control2: CGPoint(x: r.midX - 0.4 * w, y: r.minY))
            p.closeSubpath()
            return p
        case .dino:                                                     // tall bean leaning right, left side tucked in
            var p = Path()
            p.move(to: CGPoint(x: r.minX + 0.45 * w, y: r.maxY))
            p.addCurve(to: CGPoint(x: r.minX + 0.03 * w, y: r.maxY - 0.32 * h),
                       control1: CGPoint(x: r.minX + 0.12 * w, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - 0.12 * h))
            p.addCurve(to: CGPoint(x: r.minX + 0.16 * w, y: r.minY + 0.36 * h),
                       control1: CGPoint(x: r.minX + 0.07 * w, y: r.maxY - 0.5 * h), control2: CGPoint(x: r.minX + 0.18 * w, y: r.minY + 0.5 * h))
            p.addCurve(to: CGPoint(x: r.minX + 0.62 * w, y: r.minY),
                       control1: CGPoint(x: r.minX + 0.12 * w, y: r.minY + 0.12 * h), control2: CGPoint(x: r.minX + 0.34 * w, y: r.minY))
            p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + 0.4 * h),
                       control1: CGPoint(x: r.minX + 0.92 * w, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + 0.14 * h))
            p.addCurve(to: CGPoint(x: r.minX + 0.45 * w, y: r.maxY),
                       control1: CGPoint(x: r.maxX, y: r.maxY - 0.06 * h), control2: CGPoint(x: r.maxX - 0.18 * w, y: r.maxY))
            p.closeSubpath()
            return p
        case .ghost:                                                    // dome, straight sides, rippling hem
            var p = Path()
            let hem = r.maxY - 0.1 * h
            p.move(to: CGPoint(x: r.minX, y: hem))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + 0.45 * h))
            p.addCurve(to: CGPoint(x: r.midX, y: r.minY),
                       control1: CGPoint(x: r.minX, y: r.minY + 0.1 * h), control2: CGPoint(x: r.minX + 0.22 * w, y: r.minY))
            p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + 0.45 * h),
                       control1: CGPoint(x: r.maxX - 0.22 * w, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + 0.1 * h))
            p.addLine(to: CGPoint(x: r.maxX, y: hem))
            let n = 4
            for i in 0..<n {
                let x0 = r.maxX - CGFloat(i) * w / CGFloat(n), x1 = x0 - w / CGFloat(n)
                let wob = CGFloat(sin(t * 3 + Double(i) * 1.7)) * 0.04 * h
                p.addQuadCurve(to: CGPoint(x: x1, y: hem), control: CGPoint(x: (x0 + x1) / 2, y: r.maxY + 0.12 * h + wob))
            }
            p.closeSubpath()
            return p
        case .mushroom:                                                 // the stem (the cap is drawn on top: markings)
            let stem = CGRect(x: r.midX - 0.36 * w, y: r.minY + 0.3 * h, width: 0.72 * w, height: 0.7 * h)
            return RoundedRectangle(cornerRadius: 0.3 * w, style: .continuous).path(in: stem)
        case .star:                                                     // chubby five-point star, every corner rounded
            let R = min(w * 0.56, h * 0.6), cy = r.maxY - 0.81 * R, cx = r.midX
            let pts: [CGPoint] = (0..<10).map { i in
                let a = -Double.pi / 2 + Double(i) * .pi / 5
                let rr = i % 2 == 0 ? R : R * 0.66
                return CGPoint(x: cx + CGFloat(cos(a)) * rr, y: cy + CGFloat(sin(a)) * rr)
            }
            func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            var p = Path()
            p.move(to: mid(pts[9], pts[0]))
            for i in 0..<10 { p.addQuadCurve(to: mid(pts[i], pts[(i + 1) % 10]), control: pts[i]) }
            p.closeSubpath()
            return p
        case .cloud, .kitty:
            return sampled(shape, in: r)
        }
    }

    /// A squircle with radial bumps: puffs along the top (cloud) or two ears (kitty).
    private static func sampled(_ shape: PuffShape, in r: CGRect) -> Path {
        let a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
        let n = 3.0, steps = 120
        var p = Path()
        func bump(_ th: Double, _ centre: Double, _ width: Double) -> Double {
            var d = abs(th - (centre < 0 ? centre + 2 * .pi : centre))
            d = min(d, 2 * .pi - d)
            return d < width ? 0.5 + 0.5 * cos(.pi * d / width) : 0
        }
        for i in 0...steps {
            let th = Double(i) / Double(steps) * 2 * .pi
            let ct = cos(th), st = sin(th)
            var x = Double(a) * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
            var y = Double(b) * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
            let up = max(0, -st)
            var k = 1.0
            if shape == .cloud {
                k += 0.2 * bump(th, -.pi / 2, 0.5) + 0.16 * bump(th, -.pi / 2 - 0.85, 0.42) + 0.16 * bump(th, -.pi / 2 + 0.85, 0.42)
                    + 0.1 * bump(th, .pi - 0.15, 0.38) + 0.1 * bump(th, 0.15, 0.38) - 0.08 * up
            } else {
                for ear in [-.pi / 2 - 0.62, -.pi / 2 + 0.62] {
                    var d = abs(th - (ear < 0 ? ear + 2 * .pi : ear))
                    d = min(d, 2 * .pi - d)
                    k += 0.3 * pow(max(0, 1 - d / 0.3), 1.6)
                }
            }
            x *= k; y *= k
            let pt = CGPoint(x: c.x + CGFloat(x), y: min(r.maxY, c.y + CGFloat(y)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    /// Where a hat or sprout sits: the top of the head (centre, y).
    static func crown(_ shape: PuffShape, in r: CGRect) -> CGPoint {
        switch shape {
        case .blob: return CGPoint(x: r.midX, y: r.minY + r.height * 0.04)
        case .bunny, .owl: return CGPoint(x: r.midX, y: r.minY + r.height * 0.03)
        case .bear: return CGPoint(x: r.midX, y: r.minY + r.height * 0.03)
        case .dino: return CGPoint(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.01)
        case .ghost: return CGPoint(x: r.midX, y: r.minY + r.height * 0.02)
        case .mushroom: return CGPoint(x: r.midX, y: r.minY - r.height * 0.02)
        case .star:
            let R = min(r.width * 0.56, r.height * 0.6)
            return CGPoint(x: r.midX, y: r.maxY - 0.81 * R - R + R * 0.14)
        case .cloud: return CGPoint(x: r.midX, y: r.minY - r.height * 0.02)
        case .kitty: return CGPoint(x: r.midX, y: r.minY + r.height * 0.03)
        }
    }

    /// The body's own fill: a mushroom's stem is cream, everything else wears the palette.
    static func bodyColors(_ shape: PuffShape, top: Color, bottom: Color) -> (Color, Color) {
        shape == .mushroom ? (Color(red: 0.98, green: 0.94, blue: 0.86), Color(red: 0.88, green: 0.8, blue: 0.7)) : (top, bottom)
    }

    private static func shaded(_ g: GraphicsContext, _ path: Path, _ a: Color, _ b: Color, _ rect: CGRect, stroke: Bool = true, s: CGFloat) {
        g.fill(path, with: .linearGradient(Gradient(colors: [a, b]), startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                           endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        if stroke { g.stroke(path, with: .color(edge), lineWidth: max(0.6, s * 0.01)) }
    }

    /// Parts behind the body: ears, tails, spikes, tufts.
    static func behind(_ shape: PuffShape, _ g: GraphicsContext, body r: CGRect, top: Color, bottom: Color, t: Double, s: CGFloat) {
        let w = r.width, h = r.height
        switch shape {
        case .bunny:
            for (side, tilt, len) in [(-1.0, -0.2, 0.42), (1.0, 0.5, 0.36)] {
                var e = g
                e.translateBy(x: r.midX + CGFloat(side) * w * 0.2, y: r.minY + h * 0.16)
                e.rotate(by: .radians(tilt + 0.05 * sin(t * 2 + side)))
                let ew = s * 0.15, el = s * len
                let ear = CGRect(x: -ew / 2, y: -el, width: ew, height: el)
                let path = Capsule().path(in: ear)
                shaded(e, path, top.mix(.white, 0.08), top.mix(bottom, 0.4), ear, s: s)
                let inner = ear.insetBy(dx: ew * 0.26, dy: el * 0.1).offsetBy(dx: 0, dy: el * 0.04)
                e.fill(Capsule().path(in: inner), with: .linearGradient(Gradient(colors: [pink.opacity(0.85), pink.mix(top, 0.4).opacity(0.7)]),
                                                                         startPoint: CGPoint(x: 0, y: inner.minY), endPoint: CGPoint(x: 0, y: inner.maxY)))
            }
            let tr = s * 0.1                                            // cotton tail peeking out
            let tc = CGPoint(x: r.maxX - w * 0.02, y: r.maxY - h * 0.24)
            g.fill(Circle().path(in: CGRect(x: tc.x - tr, y: tc.y - tr, width: tr * 2, height: tr * 2)), with: .color(.white.opacity(0.95)))
        case .bear:
            for side in [-1.0, 1.0] {
                let er = w * 0.16
                let c = CGPoint(x: r.midX + CGFloat(side) * w * 0.34, y: r.minY + h * 0.1)
                let o = CGRect(x: c.x - er, y: c.y - er, width: er * 2, height: er * 2)
                shaded(g, Circle().path(in: o), top, top.mix(bottom, 0.5), o, s: s)
                let i = o.insetBy(dx: er * 0.42, dy: er * 0.42)
                g.fill(Circle().path(in: i), with: .color(pink.mix(top, 0.35).opacity(0.85)))
            }
        case .kitty:
            var tail = Path()                                           // a curl that swishes
            let sw = CGFloat(sin(t * 1.6)) * w * 0.05
            tail.move(to: CGPoint(x: r.maxX - w * 0.2, y: r.maxY - h * 0.1))
            tail.addCurve(to: CGPoint(x: r.maxX + w * 0.1 + sw, y: r.minY + h * 0.36),
                          control1: CGPoint(x: r.maxX + w * 0.1, y: r.maxY - h * 0.02),
                          control2: CGPoint(x: r.maxX + w * 0.16 + sw * 0.5, y: r.minY + h * 0.62))
            tail.addQuadCurve(to: CGPoint(x: r.maxX + w * 0.17 + sw, y: r.minY + h * 0.22),     // the tip curls outward
                              control: CGPoint(x: r.maxX + w * 0.07 + sw, y: r.minY + h * 0.2))
            g.stroke(tail, with: .color(edge), style: StrokeStyle(lineWidth: s * 0.1, lineCap: .round))
            g.stroke(tail, with: .linearGradient(Gradient(colors: [bottom, top]), startPoint: CGPoint(x: r.maxX, y: r.maxY),
                                                  endPoint: CGPoint(x: r.maxX, y: r.minY)),
                     style: StrokeStyle(lineWidth: s * 0.08, lineCap: .round))
        case .dino:
            // A chunky tapered tail sweeping out to the left, its tip curling up.
            let wag = CGFloat(sin(t * 2)) * h * 0.03
            var tail = Path()
            tail.move(to: CGPoint(x: r.minX + w * 0.18, y: r.maxY - h * 0.34))
            tail.addQuadCurve(to: CGPoint(x: r.minX - w * 0.24, y: r.maxY - h * 0.3 + wag), control: CGPoint(x: r.minX - w * 0.08, y: r.maxY - h * 0.2))
            tail.addQuadCurve(to: CGPoint(x: r.minX - w * 0.19, y: r.maxY - h * 0.2 + wag), control: CGPoint(x: r.minX - w * 0.27, y: r.maxY - h * 0.2 + wag))
            tail.addQuadCurve(to: CGPoint(x: r.minX + w * 0.3, y: r.maxY - h * 0.01), control: CGPoint(x: r.minX - w * 0.08, y: r.maxY + h * 0.02))
            tail.closeSubpath()
            shaded(g, tail, top.mix(bottom, 0.45), bottom, CGRect(x: r.minX - w * 0.3, y: r.maxY - h * 0.34, width: w * 0.6, height: h * 0.34), s: s)
            let spike = bottom.mix(.black, 0.18)                        // a crest of soft spikes along the back
            let base = crown(.dino, in: r)
            for (i, dx) in [-0.3, -0.1, 0.12, 0.32].enumerated() {
                let sz = s * (i == 1 || i == 2 ? 0.15 : 0.12)
                let bx = base.x + CGFloat(dx) * w
                let by = base.y + h * (abs(dx) * 0.3) + sz * 0.3        // base just inside the outline
                let tip = CGPoint(x: bx + CGFloat(dx) * sz * 0.8, y: by - sz * 1.05)
                var sp = Path()
                sp.move(to: CGPoint(x: bx - sz * 0.5, y: by))
                sp.addQuadCurve(to: tip, control: CGPoint(x: bx - sz * 0.32, y: by - sz * 0.55))
                sp.addQuadCurve(to: CGPoint(x: bx + sz * 0.5, y: by), control: CGPoint(x: bx + sz * 0.36, y: by - sz * 0.5))
                sp.closeSubpath()
                g.fill(sp, with: .linearGradient(Gradient(colors: [spike.mix(.white, 0.25), spike]), startPoint: tip, endPoint: CGPoint(x: bx, y: by)))
                g.stroke(sp, with: .color(edge), style: StrokeStyle(lineWidth: max(0.6, s * 0.01), lineJoin: .round))
            }
        case .owl:
            for side in [-1.0, 1.0] {                                   // ear tufts
                var tuft = Path()
                let bx = r.midX + CGFloat(side) * w * 0.28, by = r.minY + h * 0.14
                tuft.move(to: CGPoint(x: bx - CGFloat(side) * w * 0.14, y: by + h * 0.04))
                tuft.addQuadCurve(to: CGPoint(x: bx + CGFloat(side) * w * 0.14, y: by - h * 0.2),
                                  control: CGPoint(x: bx - CGFloat(side) * w * 0.02, y: by - h * 0.02))
                tuft.addQuadCurve(to: CGPoint(x: bx + CGFloat(side) * w * 0.12, y: by + h * 0.06),
                                  control: CGPoint(x: bx + CGFloat(side) * w * 0.16, y: by - h * 0.05))
                tuft.closeSubpath()
                shaded(g, tuft, top.mix(.black, 0.08), top.mix(bottom, 0.5), r, s: s)
            }
        default: break
        }
    }

    /// Markings on the body, under the face: bellies, muzzles, a cap, eye discs, ear insides.
    static func markings(_ shape: PuffShape, _ g: GraphicsContext, body r: CGRect, face f: Face, top: Color, bottom: Color,
                         eye: Color, t: Double, s: CGFloat) {
        let w = r.width, h = r.height
        let light = top.mix(.white, 0.55)
        func belly(_ dy: CGFloat, _ bw: CGFloat, _ bh: CGFloat) -> CGRect {
            CGRect(x: r.midX - w * bw / 2, y: r.maxY - h * (bh + dy), width: w * bw, height: h * bh)
        }
        switch shape {
        case .bunny:
            let b = belly(0.05, 0.5, 0.32)
            g.fill(Ellipse().path(in: b), with: .color(light.opacity(0.55)))
        case .bear:
            let b = belly(0.05, 0.46, 0.28)
            g.fill(Ellipse().path(in: b), with: .color(light.opacity(0.4)))
            let m = CGRect(x: r.midX - w * 0.2, y: f.mouthY - h * 0.13, width: w * 0.4, height: h * 0.26)
            g.fill(Ellipse().path(in: m), with: .radialGradient(Gradient(colors: [light, light.mix(top, 0.35)]),
                                                                 center: CGPoint(x: m.midX, y: m.minY + m.height * 0.35),
                                                                 startRadius: 0, endRadius: m.width * 0.6))
            let n = CGRect(x: r.midX - w * 0.06, y: m.minY + m.height * 0.08, width: w * 0.12, height: h * 0.07)
            g.fill(Ellipse().path(in: n), with: .color(Color(red: 0.18, green: 0.12, blue: 0.16)))
            g.fill(Ellipse().path(in: CGRect(x: n.minX + n.width * 0.22, y: n.minY + n.height * 0.15, width: n.width * 0.3, height: n.height * 0.3)),
                   with: .color(.white.opacity(0.6)))
        case .kitty:
            for side in [-1.0, 1.0] {                                   // pink ear insides
                var e = Path()
                let ex = r.midX + CGFloat(side) * w * 0.31, ey = r.minY + h * 0.02
                e.move(to: CGPoint(x: ex - w * 0.08, y: ey + h * 0.16))
                e.addQuadCurve(to: CGPoint(x: ex + CGFloat(side) * w * 0.04, y: ey - h * 0.04), control: CGPoint(x: ex - w * 0.03, y: ey + h * 0.02))
                e.addQuadCurve(to: CGPoint(x: ex + w * 0.08, y: ey + h * 0.16), control: CGPoint(x: ex + w * 0.05, y: ey + h * 0.04))
                e.closeSubpath()
                g.fill(e, with: .color(pink.opacity(0.75)))
            }
            for dx in [-0.07, 0.0, 0.07] {                              // forehead stripes
                var st = Path()
                st.move(to: CGPoint(x: r.midX + CGFloat(dx) * w, y: r.minY + h * 0.1))
                st.addLine(to: CGPoint(x: r.midX + CGFloat(dx) * w * 0.8, y: r.minY + h * (dx == 0 ? 0.24 : 0.2)))
                g.stroke(st, with: .color(bottom.mix(.black, 0.25).opacity(0.5)), style: StrokeStyle(lineWidth: max(1, s * 0.028), lineCap: .round))
            }
            g.fill(Ellipse().path(in: belly(0.04, 0.48, 0.24)), with: .color(light.opacity(0.4)))
        case .dino:
            let b = belly(0.04, 0.42, 0.34).offsetBy(dx: w * 0.04, dy: 0)
            g.fill(Ellipse().path(in: b), with: .color(light.opacity(0.55)))
            for k in 1...3 {
                var l = Path()
                let y = b.minY + b.height * CGFloat(k) / 4
                l.move(to: CGPoint(x: b.minX + b.width * 0.2, y: y)); l.addLine(to: CGPoint(x: b.maxX - b.width * 0.2, y: y))
                g.stroke(l, with: .color(top.mix(bottom, 0.5).opacity(0.35)), style: StrokeStyle(lineWidth: max(0.8, s * 0.014), lineCap: .round))
            }
        case .ghost:
            g.fill(Ellipse().path(in: belly(0.0, 0.7, 0.3)), with: .radialGradient(Gradient(colors: [eye.opacity(0.25), eye.opacity(0)]),
                                                                                    center: CGPoint(x: r.midX, y: r.maxY - h * 0.1),
                                                                                    startRadius: 0, endRadius: w * 0.4))
        case .mushroom:
            let cap = CGRect(x: r.midX - 0.62 * w, y: r.minY, width: 1.24 * w, height: 0.48 * h)
            var p = Path()
            p.move(to: CGPoint(x: cap.minX, y: cap.maxY - cap.height * 0.12))
            p.addCurve(to: CGPoint(x: cap.midX, y: cap.minY),
                       control1: CGPoint(x: cap.minX + cap.width * 0.02, y: cap.minY + cap.height * 0.25),
                       control2: CGPoint(x: cap.minX + cap.width * 0.25, y: cap.minY))
            p.addCurve(to: CGPoint(x: cap.maxX, y: cap.maxY - cap.height * 0.12),
                       control1: CGPoint(x: cap.maxX - cap.width * 0.25, y: cap.minY),
                       control2: CGPoint(x: cap.maxX - cap.width * 0.02, y: cap.minY + cap.height * 0.25))
            p.addQuadCurve(to: CGPoint(x: cap.minX, y: cap.maxY - cap.height * 0.12), control: CGPoint(x: cap.midX, y: cap.maxY + cap.height * 0.18))
            p.closeSubpath()
            // A soft shadow the cap casts on the stem.
            g.fill(Ellipse().path(in: CGRect(x: r.midX - 0.38 * w, y: cap.maxY - cap.height * 0.12, width: 0.76 * w, height: h * 0.1)),
                   with: .color(.black.opacity(0.12)))
            shaded(g, p, top, bottom, cap, s: s)
            g.fill(p, with: .radialGradient(Gradient(colors: [.white.opacity(0.22), .clear]), center: CGPoint(x: cap.midX - cap.width * 0.15, y: cap.minY + cap.height * 0.3),
                                            startRadius: 0, endRadius: cap.width * 0.4))
            var spots = g
            spots.clip(to: p)
            for (x, y, rr) in [(0.24, 0.42, 0.09), (0.5, 0.2, 0.07), (0.72, 0.5, 0.1), (0.42, 0.62, 0.05), (0.88, 0.75, 0.06), (0.1, 0.72, 0.05)] {
                let c = CGPoint(x: cap.minX + cap.width * CGFloat(x), y: cap.minY + cap.height * CGFloat(y))
                let rad = cap.width * CGFloat(rr)
                spots.fill(Ellipse().path(in: CGRect(x: c.x - rad, y: c.y - rad * 0.85, width: rad * 2, height: rad * 1.7)), with: .color(.white.opacity(0.92)))
            }
        case .star:
            break
        case .cloud:
            var inner = g
            inner.clip(to: bodyPath(.cloud, in: r))
            for (x, y, rr) in [(0.3, 0.32, 0.22), (0.62, 0.25, 0.25), (0.45, 0.55, 0.3)] {
                let c = CGPoint(x: r.minX + w * CGFloat(x), y: r.minY + h * CGFloat(y))
                let rad = w * CGFloat(rr)
                inner.fill(Circle().path(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)),
                           with: .radialGradient(Gradient(colors: [.white.opacity(0.16), .clear]), center: CGPoint(x: c.x - rad * 0.3, y: c.y - rad * 0.3),
                                                 startRadius: 0, endRadius: rad))
            }
            inner.fill(Ellipse().path(in: CGRect(x: r.minX, y: r.maxY - h * 0.3, width: w, height: h * 0.4)), with: .color(Color.blue.opacity(0.08)))
        case .owl:
            let b = belly(0.03, 0.56, 0.42)
            g.fill(Ellipse().path(in: b), with: .color(light.opacity(0.5)))
            for row in 0..<3 {                                          // feather chevrons
                for col in 0..<(row == 1 ? 2 : 3) {
                    let x = b.minX + b.width * (row == 1 ? 0.36 + 0.28 * CGFloat(col) : 0.24 + 0.26 * CGFloat(col))
                    let y = b.minY + b.height * (0.3 + 0.2 * CGFloat(row))
                    var v = Path()
                    v.move(to: CGPoint(x: x - w * 0.04, y: y)); v.addLine(to: CGPoint(x: x, y: y + h * 0.035)); v.addLine(to: CGPoint(x: x + w * 0.04, y: y))
                    g.stroke(v, with: .color(top.mix(bottom, 0.6).opacity(0.5)), style: StrokeStyle(lineWidth: max(0.8, s * 0.014), lineCap: .round, lineJoin: .round))
                }
            }
            for side in [-1.0, 1.0] {                                   // eye discs
                let c = CGPoint(x: r.midX + CGFloat(side) * f.spread, y: f.eyeY)
                let rad = max(f.ew, f.eh) * 0.95
                g.fill(Circle().path(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)), with: .color(light.opacity(0.75)))
            }
            for side in [-1.0, 1.0] {                                   // wings, folded at the sides
                var wing = Path()
                let x = side < 0 ? r.minX + w * 0.04 : r.maxX - w * 0.04
                let flap = CGFloat(sin(t * 3)) * h * 0.01
                wing.move(to: CGPoint(x: x, y: r.minY + h * 0.4))
                wing.addQuadCurve(to: CGPoint(x: x - CGFloat(side) * w * 0.02, y: r.maxY - h * 0.15 + flap),
                                  control: CGPoint(x: x + CGFloat(side) * w * 0.1, y: r.minY + h * 0.62))
                wing.addQuadCurve(to: CGPoint(x: x, y: r.minY + h * 0.4), control: CGPoint(x: x - CGFloat(side) * w * 0.14, y: r.minY + h * 0.6))
                wing.closeSubpath()
                shaded(g, wing, top.mix(.black, 0.06), bottom.mix(.black, 0.12), r, s: s)
            }
        case .blob:
            break
        }
    }

    /// Small face details drawn over the face: noses, whiskers, a beak, a fang, a twinkle, rain.
    static func faceExtras(_ shape: PuffShape, _ g: GraphicsContext, body r: CGRect, face f: Face, mood: AvatarMood, t: Double, s: CGFloat) {
        let w = r.width, h = r.height
        let ink = Color(red: 0.10, green: 0.07, blue: 0.16)
        switch shape {
        case .bunny:
            let n = CGRect(x: r.midX - w * 0.035, y: f.eyeY + f.eh * 0.5, width: w * 0.07, height: h * 0.04)
            g.fill(Ellipse().path(in: n), with: .color(pink))
        case .kitty:
            let n = CGRect(x: r.midX - w * 0.03, y: f.eyeY + f.eh * 0.5, width: w * 0.06, height: h * 0.035)
            g.fill(Ellipse().path(in: n), with: .color(pink))
            for side in [-1.0, 1.0] {
                for k in 0..<2 {
                    var wh = Path()
                    let y = f.mouthY - h * 0.02 + CGFloat(k) * h * 0.05
                    wh.move(to: CGPoint(x: r.midX + CGFloat(side) * w * 0.22, y: y))
                    wh.addLine(to: CGPoint(x: r.midX + CGFloat(side) * w * 0.48, y: y - h * 0.03 + CGFloat(k) * h * 0.05))
                    g.stroke(wh, with: .color(ink.opacity(0.45)), style: StrokeStyle(lineWidth: max(0.7, s * 0.011), lineCap: .round))
                }
            }
        case .dino:
            var fang = Path()
            let x = r.midX + w * 0.05, y = f.mouthY + h * 0.01
            fang.move(to: CGPoint(x: x - w * 0.025, y: y)); fang.addLine(to: CGPoint(x: x, y: y + h * 0.05)); fang.addLine(to: CGPoint(x: x + w * 0.025, y: y))
            fang.closeSubpath()
            g.fill(fang, with: .color(.white))
        case .owl:
            var beak = Path()
            let y = f.eyeY + f.eh * 0.4
            beak.move(to: CGPoint(x: r.midX - w * 0.05, y: y))
            beak.addLine(to: CGPoint(x: r.midX + w * 0.05, y: y))
            beak.addQuadCurve(to: CGPoint(x: r.midX, y: y + h * 0.1), control: CGPoint(x: r.midX + w * 0.03, y: y + h * 0.06))
            beak.closeSubpath()
            g.fill(beak, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.78, blue: 0.3), Color(red: 0.95, green: 0.55, blue: 0.2)]),
                                               startPoint: CGPoint(x: r.midX, y: y), endPoint: CGPoint(x: r.midX, y: y + h * 0.1)))
        case .star:
            let k = 0.5 + 0.5 * sin(t * 2.6)
            g.draw(Text("✦").font(.system(size: s * 0.1)).foregroundColor(.white.opacity(0.4 + 0.6 * k)),
                   at: CGPoint(x: r.maxX - w * 0.1, y: r.minY + h * 0.18))
        case .cloud where mood == .sad:
            for i in 0..<3 {
                let k = CGFloat((t * 1.2 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                let c = CGPoint(x: r.minX + w * (0.3 + 0.2 * CGFloat(i)), y: r.maxY + k * h * 0.25)
                g.fill(Ellipse().path(in: CGRect(x: c.x - s * 0.012, y: c.y - s * 0.02, width: s * 0.024, height: s * 0.04)),
                       with: .color(Color(red: 0.55, green: 0.8, blue: 1).opacity(Double(1 - k))))
            }
        default: break
        }
    }

    /// Plush finish: fibres along the outline and across the body (deterministic), no glossy highlights.
    static func plush(_ g: GraphicsContext, body: Path, rect: CGRect, top: Color, bottom: Color, s: CGFloat) {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
        }
        var f = g
        f.clip(to: body)
        let fibre = max(0.6, s * 0.009)
        for i in 0..<220 {                                              // short fibres in the nap direction (down and out)
            let p = CGPoint(x: rect.minX + rnd() * rect.width, y: rect.minY + rnd() * rect.height)
            let out = (p.x - rect.midX) / max(1, rect.width) * 0.9
            let len = s * (0.018 + 0.016 * rnd())
            var l = Path()
            l.move(to: p)
            l.addLine(to: CGPoint(x: p.x + out * len * 2, y: p.y + len))
            f.stroke(l, with: .color(i % 3 == 0 ? Color.black.opacity(0.08) : Color.white.opacity(0.12)),
                     style: StrokeStyle(lineWidth: fibre, lineCap: .round))
        }
        f.fill(body, with: .radialGradient(Gradient(colors: [.white.opacity(0.14), .clear]),
                                           center: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.3),
                                           startRadius: 0, endRadius: rect.width * 0.6))
        // Fuzzy silhouette: fibres sticking out along the outline.
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let n = 140
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n), b = min(1, a + 0.002)
            let seg = body.trimmedPath(from: a, to: b).boundingRect
            guard seg.width.isFinite, !seg.isNull else { continue }
            let p = CGPoint(x: seg.midX, y: seg.midY)
            let dx = p.x - c.x, dy = p.y - c.y
            let d = max(1, (dx * dx + dy * dy).squareRoot())
            let len = s * (0.008 + 0.01 * rnd())
            var l = Path()
            l.move(to: CGPoint(x: p.x - dx / d * len * 0.5, y: p.y - dy / d * len * 0.5))
            l.addLine(to: CGPoint(x: p.x + dx / d * len, y: p.y + dy / d * len + len * 0.3))
            let col = p.y < c.y ? top : bottom
            g.stroke(l, with: .color(col.mix(.white, 0.12).opacity(0.6)), style: StrokeStyle(lineWidth: fibre * 1.4, lineCap: .round))
        }
    }

    struct Face { let eyeY: CGFloat; let spread: CGFloat; let ew: CGFloat; let eh: CGFloat; let mouthY: CGFloat; let lookX: CGFloat }

    // MARK: Materials

    private static func hex(_ v: UInt32) -> Color { PaletteCode.color(v) }
    static let gold = Gradient(stops: [.init(color: hex(0xFFF6CF), location: 0), .init(color: hex(0xF7CB4D), location: 0.32),
                                       .init(color: hex(0xC8891A), location: 0.55), .init(color: hex(0xF4C752), location: 0.78),
                                       .init(color: hex(0x9A6510), location: 1)])
    static let silver = Gradient(stops: [.init(color: .white, location: 0), .init(color: hex(0xC9CED6), location: 0.4),
                                         .init(color: hex(0x868E9C), location: 0.62), .init(color: hex(0xE8EBF0), location: 1)])

    private static func linear(_ g: Gradient, _ r: CGRect, vertical: Bool = true) -> GraphicsContext.Shading {
        .linearGradient(g, startPoint: CGPoint(x: vertical ? r.midX : r.minX, y: vertical ? r.minY : r.midY),
                        endPoint: CGPoint(x: vertical ? r.midX : r.maxX, y: vertical ? r.maxY : r.midY))
    }

    /// A soft contact shadow under an accessory (an offset fill — no blur, cheap every frame).
    private static func drop(_ g: GraphicsContext, _ p: Path, _ s: CGFloat, _ k: Double = 0.2) {
        g.fill(p.offsetBy(dx: 0, dy: s * 0.016), with: .color(.black.opacity(k)))
    }

    /// A glossy sphere (pearls, gems, orbs, buttons).
    private static func gem(_ g: GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ base: Color) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        g.fill(Circle().path(in: rect), with: .radialGradient(Gradient(colors: [base.mix(.white, 0.55), base, base.mix(.black, 0.35)]),
                                                              center: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.35), startRadius: 0, endRadius: r * 1.5))
        g.fill(Circle().path(in: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.6, width: r * 0.5, height: r * 0.42)), with: .color(.white.opacity(0.85)))
    }

    /// Accessories in front of the body (in the body's rotated context). Fine detail only when big enough.
    static func accessory(_ a: PuffAccessory, _ g: GraphicsContext, look: PuffLook, body r: CGRect, face: Face,
                          palette: AvatarPalette, t: Double, s: CGFloat, mood: AvatarMood) {
        let w = r.width, h = r.height
        let top = crown(look.shape, in: r)
        let detail = s >= 40
        let line = max(0.7, s * 0.01)
        let edge = Color.black.opacity(0.25)
        switch a {
        case .none, .sprout:
            break                                                   // the sprout grows behind the body (PuffCanvas)

        case .headphones:
            // Brushed-metal band with a stitched leather cushion, sliders, cups with a metal ring, soft pads, an LED.
            let y0 = r.minY + h * 0.42
            var band = Path()
            band.move(to: CGPoint(x: r.minX + w * 0.06, y: y0))
            band.addCurve(to: CGPoint(x: r.maxX - w * 0.06, y: y0),
                          control1: CGPoint(x: r.minX - w * 0.02, y: top.y - h * 0.36), control2: CGPoint(x: r.maxX + w * 0.02, y: top.y - h * 0.36))
            drop(g, band.strokedPath(StrokeStyle(lineWidth: s * 0.05, lineCap: .round)), s)
            g.stroke(band, with: .color(hex(0x5B606B)), style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
            g.stroke(band, with: linear(silver, CGRect(x: r.minX, y: top.y - h * 0.3, width: w, height: h * 0.4)),
                     style: StrokeStyle(lineWidth: s * 0.034, lineCap: .round))
            let cushion = band.trimmedPath(from: 0.3, to: 0.7)
            g.stroke(cushion, with: .color(hex(0x2B2622)), style: StrokeStyle(lineWidth: s * 0.06, lineCap: .round))
            g.stroke(cushion, with: .linearGradient(Gradient(colors: [hex(0x6B5446), hex(0x3A2E27)]), startPoint: CGPoint(x: r.midX, y: top.y - h * 0.3),
                                                    endPoint: CGPoint(x: r.midX, y: top.y - h * 0.15)),
                     style: StrokeStyle(lineWidth: s * 0.048, lineCap: .round))
            if detail {
                g.stroke(cushion, with: .color(hex(0xE9D3B5).opacity(0.7)), style: StrokeStyle(lineWidth: max(0.6, s * 0.006), dash: [s * 0.012, s * 0.01]))
            }
            for side in [-1.0, 1.0] {
                let cw = w * 0.22, ch = h * 0.38
                let cx = side < 0 ? r.minX + w * 0.03 : r.maxX - w * 0.03
                let cup = CGRect(x: cx - cw / 2, y: r.minY + h * 0.36, width: cw, height: ch)
                // slider/yoke from the band end to the cup
                var yoke = Path()
                yoke.move(to: CGPoint(x: cx - CGFloat(side) * cw * 0.05, y: y0 - h * 0.05))
                yoke.addLine(to: CGPoint(x: cx, y: cup.minY + ch * 0.18))
                g.stroke(yoke, with: .color(hex(0x9AA1AD)), style: StrokeStyle(lineWidth: s * 0.022, lineCap: .round))
                let pad = RoundedRectangle(cornerRadius: cw * 0.48, style: .continuous).path(in: cup.offsetBy(dx: -CGFloat(side) * cw * 0.18, dy: 0))
                g.fill(pad, with: .color(hex(0x2E2A2B)))                  // soft pad toward the head
                let shell = RoundedRectangle(cornerRadius: cw * 0.46, style: .continuous).path(in: cup)
                drop(g, shell, s)
                g.fill(shell, with: .linearGradient(Gradient(colors: [hex(0xFBF6EC), hex(0xDCCFBA)]),
                                                    startPoint: CGPoint(x: cup.midX, y: cup.minY), endPoint: CGPoint(x: cup.midX, y: cup.maxY)))
                let ring = RoundedRectangle(cornerRadius: cw * 0.4, style: .continuous).path(in: cup.insetBy(dx: cw * 0.12, dy: ch * 0.1))
                g.stroke(ring, with: linear(silver, cup), lineWidth: max(1, s * 0.016))
                g.stroke(shell, with: .color(edge), lineWidth: line)
                g.fill(Ellipse().path(in: CGRect(x: cup.minX + cw * 0.2, y: cup.minY + ch * 0.08, width: cw * 0.3, height: ch * 0.16)),
                       with: .color(.white.opacity(0.7)))
                if detail {                                             // a tiny LED that breathes
                    let k = 0.55 + 0.45 * sin(t * 2.4 + side)
                    let lr = s * 0.012
                    let lc = CGPoint(x: cup.midX, y: cup.maxY - ch * 0.22)
                    g.fill(Circle().path(in: CGRect(x: lc.x - lr * 3, y: lc.y - lr * 3, width: lr * 6, height: lr * 6)),
                           with: .radialGradient(Gradient(colors: [palette.eye.opacity(0.5 * k), .clear]), center: lc, startRadius: 0, endRadius: lr * 3))
                    g.fill(Circle().path(in: CGRect(x: lc.x - lr, y: lc.y - lr, width: lr * 2, height: lr * 2)), with: .color(palette.eye))
                }
                if mood == .talking || mood == .working {
                    let k = CGFloat((t * 0.8 + (side > 0 ? 0.5 : 0)).truncatingRemainder(dividingBy: 1))
                    g.draw(Text("♪").font(.system(size: s * 0.11, weight: .bold)).foregroundColor(palette.eye.opacity(Double(1 - k))),
                           at: CGPoint(x: cx + CGFloat(side) * s * (0.06 + 0.05 * k), y: cup.minY - k * s * 0.12))
                }
            }

        case .scarf:
            // A chunky striped knit wrapped around the neck, knotted, two tails with fringe.
            let berry = hex(0xD9465A), deep = hex(0x9E2A40), cream = hex(0xFFF1DC)
            let y = min(r.maxY - h * 0.24, face.mouthY + h * 0.09)
            let th = h * 0.16, dip = h * 0.07
            var wrap = Path()
            wrap.move(to: CGPoint(x: r.minX + w * 0.02, y: y))
            wrap.addQuadCurve(to: CGPoint(x: r.maxX - w * 0.02, y: y), control: CGPoint(x: r.midX, y: y + dip * 2))
            wrap.addLine(to: CGPoint(x: r.maxX - w * 0.04, y: y + th))
            wrap.addQuadCurve(to: CGPoint(x: r.minX + w * 0.04, y: y + th), control: CGPoint(x: r.midX, y: y + th + dip * 2))
            wrap.closeSubpath()
            drop(g, wrap, s, 0.22)
            g.fill(wrap, with: .linearGradient(Gradient(colors: [berry.mix(.white, 0.1), berry, deep]), startPoint: CGPoint(x: r.midX, y: y),
                                               endPoint: CGPoint(x: r.midX, y: y + th + dip)))
            var stripes = g
            stripes.clip(to: wrap)
            for k in [0.33, 0.66] {
                var st = Path()
                let yy = y + th * CGFloat(k)
                st.move(to: CGPoint(x: r.minX, y: yy)); st.addQuadCurve(to: CGPoint(x: r.maxX, y: yy), control: CGPoint(x: r.midX, y: yy + dip * 2))
                stripes.stroke(st, with: .color(cream.opacity(0.9)), lineWidth: th * 0.13)
            }
            if detail {                                                 // knit stitches
                for i in 0..<14 {
                    let x = r.minX + w * (0.06 + 0.88 * CGFloat(i) / 13)
                    let u = (x - r.midX) / (w / 2)
                    let yy = y + dip * 2 * (1 - u * u) * 0.5 + th * 0.18
                    for row in 0..<2 {
                        var v = Path()
                        let yr = yy + CGFloat(row) * th * 0.48
                        v.move(to: CGPoint(x: x - w * 0.018, y: yr)); v.addLine(to: CGPoint(x: x, y: yr + th * 0.14)); v.addLine(to: CGPoint(x: x + w * 0.018, y: yr))
                        stripes.stroke(v, with: .color(deep.opacity(0.45)), style: StrokeStyle(lineWidth: max(0.5, s * 0.006), lineCap: .round))
                    }
                }
            }
            g.stroke(wrap, with: .color(edge), lineWidth: line)
            // Knot and tails on the right, swaying a little.
            let knot = CGPoint(x: r.maxX - w * 0.24, y: y + th * 0.75 + dip * 0.4)
            let room = s * 0.98 - knot.y
            for (i, ang) in [(0, 0.08), (1, 0.32)] {
                var tp = g
                tp.translateBy(x: knot.x + CGFloat(i) * w * 0.05, y: knot.y)
                tp.rotate(by: .radians(ang + 0.05 * sin(t * 2.2 + Double(i))))
                let tw = w * 0.15, tl = max(h * 0.1, min(h * (i == 0 ? 0.3 : 0.24), room - tw * 0.4))
                let tr = CGRect(x: -tw / 2, y: 0, width: tw, height: tl)
                let tail = RoundedRectangle(cornerRadius: tw * 0.3).path(in: tr)
                tp.fill(tail, with: .linearGradient(Gradient(colors: [berry, deep]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: tl)))
                tp.fill(Path(CGRect(x: tr.minX, y: tl * 0.55, width: tw, height: tl * 0.12)), with: .color(cream.opacity(0.9)))
                tp.stroke(tail, with: .color(edge), lineWidth: line)
                for k in 0..<4 {
                    var fr = Path()
                    let x = tr.minX + tw * (CGFloat(k) + 0.5) / 4
                    fr.move(to: CGPoint(x: x, y: tl - 1)); fr.addLine(to: CGPoint(x: x, y: tl + tw * 0.35))
                    tp.stroke(fr, with: .color(deep), style: StrokeStyle(lineWidth: line * 1.3, lineCap: .round))
                }
            }
            let kr = CGRect(x: knot.x - w * 0.08, y: knot.y - th * 0.45, width: w * 0.16, height: th * 0.9)
            g.fill(Ellipse().path(in: kr), with: .radialGradient(Gradient(colors: [berry.mix(.white, 0.2), deep]),
                                                                  center: CGPoint(x: kr.midX - kr.width * 0.2, y: kr.minY + kr.height * 0.3),
                                                                  startRadius: 0, endRadius: kr.width))
            g.stroke(Ellipse().path(in: kr), with: .color(edge), lineWidth: line)

        case .pocket:
            // A canvas patch: folded hem, stitched border, a button; a pencil and a note peek out.
            let pw = w * 0.44, ph = h * 0.28
            let pr = CGRect(x: r.midX - pw / 2, y: min(r.maxY - ph - h * 0.07, face.mouthY + h * 0.11), width: pw, height: ph)
            if detail {
                var note = g                                            // a folded note
                note.translateBy(x: pr.minX + pw * 0.3, y: pr.minY)
                note.rotate(by: .radians(-0.18))
                let nr = CGRect(x: -pw * 0.14, y: -ph * 0.42, width: pw * 0.3, height: ph * 0.6)
                note.fill(Path(nr), with: .color(.white))
                note.stroke(Path(nr), with: .color(edge.opacity(0.6)), lineWidth: line * 0.8)
                for k in 1...3 {
                    var l = Path()
                    let yy = nr.minY + nr.height * CGFloat(k) * 0.2
                    l.move(to: CGPoint(x: nr.minX + nr.width * 0.18, y: yy)); l.addLine(to: CGPoint(x: nr.maxX - nr.width * 0.18, y: yy))
                    note.stroke(l, with: .color(hex(0x8FB7E8)), lineWidth: max(0.5, s * 0.005))
                }
            }
            var pencil = g                                              // a pencil, eraser up
            pencil.translateBy(x: pr.maxX - pw * 0.24, y: pr.minY + ph * 0.1)
            pencil.rotate(by: .radians(0.22))
            let pl = ph * 0.95, pwid = s * 0.034
            pencil.fill(Path(CGRect(x: -pwid / 2, y: -pl * 0.62, width: pwid, height: pl)),
                        with: .linearGradient(Gradient(colors: [hex(0xFFD45C), hex(0xF2A93B)]), startPoint: CGPoint(x: -pwid / 2, y: 0), endPoint: CGPoint(x: pwid / 2, y: 0)))
            pencil.fill(Path(CGRect(x: -pwid / 2, y: -pl * 0.7, width: pwid, height: pl * 0.09)), with: linear(silver, CGRect(x: -pwid / 2, y: 0, width: pwid, height: 1), vertical: false))
            pencil.fill(RoundedRectangle(cornerRadius: pwid * 0.35).path(in: CGRect(x: -pwid / 2, y: -pl * 0.82, width: pwid, height: pl * 0.13)),
                        with: .color(hex(0xF59CB0)))
            let patch = UnevenRoundedRectangle(topLeadingRadius: pw * 0.06, bottomLeadingRadius: pw * 0.32,
                                               bottomTrailingRadius: pw * 0.32, topTrailingRadius: pw * 0.06).path(in: pr)
            drop(g, patch, s)
            g.fill(patch, with: .linearGradient(Gradient(colors: [hex(0xFFF6E6), hex(0xE9D6B6)]), startPoint: CGPoint(x: pr.midX, y: pr.minY),
                                                endPoint: CGPoint(x: pr.midX, y: pr.maxY)))
            var hem = g
            hem.clip(to: patch)
            hem.fill(Path(CGRect(x: pr.minX, y: pr.minY, width: pw, height: ph * 0.2)), with: .color(hex(0xD9C29C)))
            g.stroke(UnevenRoundedRectangle(topLeadingRadius: pw * 0.04, bottomLeadingRadius: pw * 0.26, bottomTrailingRadius: pw * 0.26,
                                            topTrailingRadius: pw * 0.04).path(in: pr.insetBy(dx: pw * 0.07, dy: ph * 0.08)),
                     with: .color(hex(0xE07A3C)), style: StrokeStyle(lineWidth: max(0.6, s * 0.008), dash: [s * 0.018, s * 0.014]))
            g.stroke(patch, with: .color(edge), lineWidth: line)
            gem(g, CGPoint(x: pr.midX, y: pr.minY + ph * 0.2), s * 0.022, hex(0xC9884A))

        case .bow:
            // A satin bow: folded loops with sheen, a knot, V-cut tails.
            let rose = hex(0xFF7AA2), deep = hex(0xC93C6E)
            let c = CGPoint(x: top.x + w * 0.24, y: top.y + h * 0.1)
            var b = g
            b.translateBy(x: c.x, y: c.y)
            b.rotate(by: .radians(0.18 + 0.03 * sin(t * 1.6)))
            for side in [-1.0, 1.0] {                                   // tails first
                var tail = Path()
                let sx = CGFloat(side)
                tail.move(to: CGPoint(x: sx * s * 0.02, y: s * 0.02))
                tail.addLine(to: CGPoint(x: sx * s * 0.09, y: s * 0.14))
                tail.addLine(to: CGPoint(x: sx * s * 0.06, y: s * 0.12))
                tail.addLine(to: CGPoint(x: sx * s * 0.045, y: s * 0.15))
                tail.addLine(to: CGPoint(x: -sx * s * 0.01, y: s * 0.03))
                tail.closeSubpath()
                b.fill(tail, with: .linearGradient(Gradient(colors: [rose, deep]), startPoint: .zero, endPoint: CGPoint(x: 0, y: s * 0.15)))
                b.stroke(tail, with: .color(edge), lineWidth: line)
            }
            for side in [-1.0, 1.0] {
                let sx = CGFloat(side)
                var loop = Path()
                loop.move(to: .zero)
                loop.addCurve(to: CGPoint(x: sx * s * 0.17, y: -s * 0.02), control1: CGPoint(x: sx * s * 0.05, y: -s * 0.13), control2: CGPoint(x: sx * s * 0.17, y: -s * 0.12))
                loop.addCurve(to: .zero, control1: CGPoint(x: sx * s * 0.17, y: s * 0.08), control2: CGPoint(x: sx * s * 0.05, y: s * 0.07))
                loop.closeSubpath()
                drop(b, loop, s)
                b.fill(loop, with: .radialGradient(Gradient(colors: [rose.mix(.white, 0.35), rose, deep]),
                                                   center: CGPoint(x: sx * s * 0.1, y: -s * 0.03), startRadius: 0, endRadius: s * 0.13))
                b.fill(Ellipse().path(in: CGRect(x: sx > 0 ? s * 0.015 : -s * 0.065, y: -s * 0.03, width: s * 0.05, height: s * 0.06)),
                       with: .color(deep.opacity(0.45)))                // inner fold
                if detail {
                    var sheen = Path()
                    sheen.move(to: CGPoint(x: sx * s * 0.07, y: -s * 0.07))
                    sheen.addQuadCurve(to: CGPoint(x: sx * s * 0.14, y: -s * 0.04), control: CGPoint(x: sx * s * 0.12, y: -s * 0.085))
                    b.stroke(sheen, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: s * 0.012, lineCap: .round))
                }
                b.stroke(loop, with: .color(edge), lineWidth: line)
            }
            let kr = CGRect(x: -s * 0.035, y: -s * 0.04, width: s * 0.07, height: s * 0.075)
            b.fill(RoundedRectangle(cornerRadius: s * 0.02).path(in: kr), with: .linearGradient(Gradient(colors: [rose.mix(.white, 0.2), deep]),
                                                                                              startPoint: CGPoint(x: 0, y: kr.minY), endPoint: CGPoint(x: 0, y: kr.maxY)))
            b.stroke(RoundedRectangle(cornerRadius: s * 0.02).path(in: kr), with: .color(edge), lineWidth: line)

        case .crown:
            // Polished gold, pearl tips, a jewelled band, a travelling shine.
            let cw = w * 0.5, ch = h * 0.27
            var cr = g
            cr.translateBy(x: top.x, y: top.y + ch * 0.32)
            cr.rotate(by: .radians(-0.1))
            let base: CGFloat = 0
            var p = Path()
            let tips: [(CGFloat, CGFloat)] = [(-0.5, -0.82), (-0.25, -0.62), (0, -1), (0.25, -0.62), (0.5, -0.82)]
            p.move(to: CGPoint(x: -cw / 2, y: base))
            p.addLine(to: CGPoint(x: -cw * 0.5, y: -ch * 0.82))
            for i in 1..<tips.count {
                let prev = tips[i - 1], cur = tips[i]
                p.addLine(to: CGPoint(x: (prev.0 + cur.0) / 2 * cw, y: -ch * 0.36))      // valley
                p.addLine(to: CGPoint(x: cur.0 * cw, y: cur.1 * ch))
            }
            p.addLine(to: CGPoint(x: cw / 2, y: base))
            p.closeSubpath()
            let box = CGRect(x: -cw / 2, y: -ch, width: cw, height: ch)
            drop(cr, p, s, 0.25)
            cr.fill(p, with: linear(gold, box))
            var shine = cr                                              // a shine sweeping across now and then
            shine.clip(to: p)
            let sx = CGFloat((t * 0.35).truncatingRemainder(dividingBy: 1)) * cw * 2.2 - cw * 1.1
            var band = Path()
            band.move(to: CGPoint(x: sx - cw * 0.06, y: base)); band.addLine(to: CGPoint(x: sx + cw * 0.12, y: -ch))
            band.addLine(to: CGPoint(x: sx + cw * 0.22, y: -ch)); band.addLine(to: CGPoint(x: sx + cw * 0.04, y: base)); band.closeSubpath()
            shine.fill(band, with: .color(.white.opacity(0.45)))
            cr.stroke(p, with: .color(hex(0x7A4F0A)), style: StrokeStyle(lineWidth: line, lineJoin: .round))
            let bandRect = CGRect(x: -cw / 2, y: -ch * 0.24, width: cw, height: ch * 0.24)
            cr.fill(Path(bandRect), with: linear(Gradient(colors: [hex(0xF9D774), hex(0xB8780F)]), bandRect))
            cr.stroke(Path(bandRect), with: .color(hex(0x7A4F0A)), lineWidth: line * 0.8)
            for (x, col) in [(-0.3, hex(0x2E7DF0)), (0.0, hex(0xE0284A)), (0.3, hex(0x22B36B))] {
                gem(cr, CGPoint(x: CGFloat(x) * cw, y: -ch * 0.12), s * (x == 0 ? 0.024 : 0.018), col)
            }
            for tip in tips { gem(cr, CGPoint(x: tip.0 * cw, y: tip.1 * ch - s * 0.012), s * 0.016, hex(0xFFF8EE)) }
            let tw = 0.5 + 0.5 * sin(t * 3)
            cr.draw(Text("✦").font(.system(size: s * 0.08)).foregroundColor(.white.opacity(tw)), at: CGPoint(x: cw * 0.42, y: -ch * 1.05))

        case .glasses:
            // Round gold wire frames, tinted lenses with a glint, nose pads, arms.
            let rad = max(face.ew, face.eh) * 0.82
            var centers: [CGPoint] = []
            for side in [-1.0, 1.0] {
                centers.append(CGPoint(x: r.midX + CGFloat(side) * face.spread + face.lookX * w * 0.1, y: face.eyeY))
            }
            for (i, c) in centers.enumerated() {                        // arms to the sides
                var arm = Path()
                let sx: CGFloat = i == 0 ? -1 : 1
                arm.move(to: CGPoint(x: c.x + sx * rad, y: c.y - rad * 0.2))
                arm.addLine(to: CGPoint(x: (sx < 0 ? r.minX + w * 0.03 : r.maxX - w * 0.03), y: c.y - rad * 0.35))
                g.stroke(arm, with: linear(gold, CGRect(x: r.minX, y: c.y - rad, width: w, height: rad)), style: StrokeStyle(lineWidth: max(0.8, s * 0.012), lineCap: .round))
            }
            for c in centers {
                let lens = Circle().path(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                g.fill(lens, with: .linearGradient(Gradient(colors: [.white.opacity(0.2), palette.eye.opacity(0.12)]),
                                                   startPoint: CGPoint(x: c.x - rad, y: c.y - rad), endPoint: CGPoint(x: c.x + rad, y: c.y + rad)))
                var glint = g
                glint.clip(to: lens)
                var gl = Path()
                gl.move(to: CGPoint(x: c.x - rad * 0.2, y: c.y - rad)); gl.addLine(to: CGPoint(x: c.x + rad * 0.15, y: c.y - rad))
                gl.addLine(to: CGPoint(x: c.x - rad * 0.65, y: c.y + rad)); gl.addLine(to: CGPoint(x: c.x - rad, y: c.y + rad)); gl.closeSubpath()
                glint.fill(gl.offsetBy(dx: rad * 0.55, dy: 0), with: .color(.white.opacity(0.22)))
                g.stroke(lens, with: .color(hex(0x6B4A12)), lineWidth: max(1.2, s * 0.022))
                g.stroke(lens, with: linear(gold, CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)), lineWidth: max(0.8, s * 0.014))
            }
            var bridge = Path()
            bridge.move(to: CGPoint(x: centers[0].x + rad * 0.95, y: face.eyeY - rad * 0.2))
            bridge.addQuadCurve(to: CGPoint(x: centers[1].x - rad * 0.95, y: face.eyeY - rad * 0.2), control: CGPoint(x: r.midX, y: face.eyeY - rad * 0.65))
            g.stroke(bridge, with: linear(gold, CGRect(x: r.midX - rad, y: face.eyeY - rad, width: rad * 2, height: rad)), lineWidth: max(1, s * 0.016))
            if detail {
                for c in centers {
                    let np = CGPoint(x: c.x + (c.x < r.midX ? rad * 0.72 : -rad * 0.72), y: face.eyeY + rad * 0.25)
                    g.fill(Ellipse().path(in: CGRect(x: np.x - s * 0.007, y: np.y - s * 0.011, width: s * 0.014, height: s * 0.022)), with: .color(.white.opacity(0.55)))
                }
            }

        case .beanie:
            // Cable-knit dome, a ribbed cuff with a leather tag, a fluffy pom-pom.
            let knit = hex(0xF0B443), shade = hex(0xC98419), cuffC = hex(0xE3A133)
            let bw = w * 0.9, cuffH = h * 0.14
            let cuffY = top.y + h * 0.16
            var dome = Path()
            dome.move(to: CGPoint(x: top.x - bw / 2, y: cuffY))
            dome.addCurve(to: CGPoint(x: top.x + bw / 2, y: cuffY),
                          control1: CGPoint(x: top.x - bw * 0.5, y: top.y - h * 0.26), control2: CGPoint(x: top.x + bw * 0.5, y: top.y - h * 0.26))
            dome.closeSubpath()
            drop(g, dome, s)
            g.fill(dome, with: .linearGradient(Gradient(colors: [knit.mix(.white, 0.15), knit, shade]), startPoint: CGPoint(x: top.x, y: top.y - h * 0.2),
                                               endPoint: CGPoint(x: top.x, y: cuffY)))
            if detail {                                                 // cable-knit columns
                var cable = g
                cable.clip(to: dome)
                for col in -3...3 {
                    let x = top.x + CGFloat(col) * bw * 0.13
                    for row in 0..<6 {
                        let yy = cuffY - CGFloat(row + 1) * h * 0.045
                        var v = Path()
                        v.move(to: CGPoint(x: x - bw * 0.04, y: yy - h * 0.02)); v.addLine(to: CGPoint(x: x, y: yy)); v.addLine(to: CGPoint(x: x + bw * 0.04, y: yy - h * 0.02))
                        cable.stroke(v, with: .color(shade.opacity(0.55)), style: StrokeStyle(lineWidth: max(0.6, s * 0.008), lineCap: .round, lineJoin: .round))
                    }
                }
            }
            g.stroke(dome, with: .color(edge), lineWidth: line)
            let cuff = CGRect(x: top.x - bw * 0.55, y: cuffY - cuffH * 0.35, width: bw * 1.1, height: cuffH)
            let cuffPath = RoundedRectangle(cornerRadius: cuffH * 0.45, style: .continuous).path(in: cuff)
            g.fill(cuffPath, with: .linearGradient(Gradient(colors: [cuffC.mix(.white, 0.1), shade]), startPoint: CGPoint(x: cuff.midX, y: cuff.minY),
                                                   endPoint: CGPoint(x: cuff.midX, y: cuff.maxY)))
            var ribs = g
            ribs.clip(to: cuffPath)
            for k in 1..<14 {
                var l = Path()
                let x = cuff.minX + cuff.width * CGFloat(k) / 14
                l.move(to: CGPoint(x: x, y: cuff.minY)); l.addLine(to: CGPoint(x: x, y: cuff.maxY))
                ribs.stroke(l, with: .color(shade.opacity(0.5)), lineWidth: max(0.6, s * 0.008))
            }
            g.stroke(cuffPath, with: .color(edge), lineWidth: line)
            let tag = CGRect(x: cuff.maxX - cuff.width * 0.3, y: cuff.minY + cuffH * 0.22, width: cuff.width * 0.14, height: cuffH * 0.56)
            g.fill(RoundedRectangle(cornerRadius: s * 0.008).path(in: tag), with: .color(hex(0x8A5A34)))
            if detail { g.stroke(RoundedRectangle(cornerRadius: s * 0.006).path(in: tag.insetBy(dx: tag.width * 0.15, dy: tag.height * 0.2)),
                                 with: .color(hex(0xE8C9A0)), style: StrokeStyle(lineWidth: max(0.4, s * 0.004), dash: [s * 0.008, s * 0.006])) }
            // Pom-pom: soft ball with fibres.
            let pr = s * 0.075
            let pc = CGPoint(x: top.x + CGFloat(sin(t * 2)) * s * 0.008, y: top.y - h * 0.14)
            let ball = Circle().path(in: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2))
            g.fill(ball, with: .radialGradient(Gradient(colors: [.white, hex(0xF3ECE2), hex(0xD9CCBB)]),
                                               center: CGPoint(x: pc.x - pr * 0.3, y: pc.y - pr * 0.35), startRadius: 0, endRadius: pr * 1.4))
            if detail {
                for i in 0..<28 {
                    let a = Double(i) / 28 * 2 * .pi
                    var f = Path()
                    f.move(to: CGPoint(x: pc.x + CGFloat(cos(a)) * pr * 0.75, y: pc.y + CGFloat(sin(a)) * pr * 0.75))
                    f.addLine(to: CGPoint(x: pc.x + CGFloat(cos(a)) * pr * 1.12, y: pc.y + CGFloat(sin(a)) * pr * 1.12))
                    g.stroke(f, with: .color(hex(0xEDE4D8)), style: StrokeStyle(lineWidth: max(0.6, s * 0.008), lineCap: .round))
                }
            }

        case .flower:
            // A cherry blossom with notched petals and stamens, a bud, two veined leaves.
            let c = CGPoint(x: top.x - w * 0.22, y: top.y + h * 0.1)
            let spin = sin(t * 1.2) * 0.12
            for (ang, len) in [(-2.5, 0.16), (-0.55, 0.14)] {           // leaves
                var lf = g
                lf.translateBy(x: c.x, y: c.y)
                lf.rotate(by: .radians(ang))
                var leaf = Path()
                leaf.move(to: .zero)
                leaf.addQuadCurve(to: CGPoint(x: s * len, y: 0), control: CGPoint(x: s * len * 0.5, y: -s * 0.045))
                leaf.addQuadCurve(to: .zero, control: CGPoint(x: s * len * 0.5, y: s * 0.045))
                lf.fill(leaf, with: .linearGradient(Gradient(colors: [hex(0x8EE59A), hex(0x2F9E5B)]), startPoint: .zero, endPoint: CGPoint(x: s * len, y: 0)))
                if detail {
                    var vein = Path(); vein.move(to: CGPoint(x: s * 0.01, y: 0)); vein.addLine(to: CGPoint(x: s * len * 0.85, y: 0))
                    lf.stroke(vein, with: .color(.white.opacity(0.5)), lineWidth: max(0.5, s * 0.005))
                }
            }
            func blossom(_ at: CGPoint, _ pr: CGFloat, _ rot: Double) {
                for i in 0..<5 {
                    var pt = g
                    pt.translateBy(x: at.x, y: at.y)
                    pt.rotate(by: .radians(Double(i) * 2 * .pi / 5 + rot))
                    var petal = Path()                                  // a petal with a notch at the tip
                    petal.move(to: .zero)
                    petal.addCurve(to: CGPoint(x: -pr * 0.12, y: -pr), control1: CGPoint(x: -pr * 0.55, y: -pr * 0.3), control2: CGPoint(x: -pr * 0.5, y: -pr * 0.95))
                    petal.addLine(to: CGPoint(x: 0, y: -pr * 0.86))
                    petal.addLine(to: CGPoint(x: pr * 0.12, y: -pr))
                    petal.addCurve(to: .zero, control1: CGPoint(x: pr * 0.5, y: -pr * 0.95), control2: CGPoint(x: pr * 0.55, y: -pr * 0.3))
                    pt.fill(petal, with: .linearGradient(Gradient(colors: [hex(0xFFE3EC), hex(0xFFFFFF), hex(0xF7A8C2)]),
                                                         startPoint: CGPoint(x: 0, y: -pr), endPoint: .zero))
                    pt.stroke(petal, with: .color(hex(0xE57FA3).opacity(0.6)), lineWidth: max(0.5, s * 0.005))
                }
                g.fill(Circle().path(in: CGRect(x: at.x - pr * 0.28, y: at.y - pr * 0.28, width: pr * 0.56, height: pr * 0.56)), with: .color(hex(0xF46F95)))
                if detail {
                    for i in 0..<7 {
                        let a = Double(i) / 7 * 2 * .pi + rot
                        let d = CGPoint(x: at.x + CGFloat(cos(a)) * pr * 0.42, y: at.y + CGFloat(sin(a)) * pr * 0.42)
                        g.fill(Circle().path(in: CGRect(x: d.x - s * 0.006, y: d.y - s * 0.006, width: s * 0.012, height: s * 0.012)), with: .color(hex(0xFFD15C)))
                    }
                }
            }
            blossom(c, s * 0.1, spin)
            gem(g, CGPoint(x: c.x + s * 0.11, y: c.y - s * 0.06), s * 0.028, hex(0xFF9DBC))      // a bud

        case .antenna:
            // A silver spring on a metal mount, a glowing orb with a halo.
            let tip = CGPoint(x: top.x + sin(t * 2.2) * s * 0.035, y: max(s * 0.08, top.y - h * 0.32))
            let mount = CGRect(x: top.x - s * 0.04, y: top.y - s * 0.02, width: s * 0.08, height: s * 0.04)
            var coil = Path()
            let n = 7
            coil.move(to: CGPoint(x: top.x, y: top.y - s * 0.01))
            for i in 1...(n * 2) {
                let k = CGFloat(i) / CGFloat(n * 2)
                let x = top.x + (tip.x - top.x) * k + (i % 2 == 0 ? -1 : 1) * s * 0.018 * (1 - k * 0.4)
                coil.addLine(to: CGPoint(x: x, y: top.y + (tip.y - top.y) * k))
            }
            g.stroke(coil, with: .color(hex(0x5B606B)), style: StrokeStyle(lineWidth: max(1, s * 0.016), lineCap: .round, lineJoin: .round))
            g.stroke(coil, with: linear(silver, CGRect(x: top.x - s * 0.03, y: tip.y, width: s * 0.06, height: top.y - tip.y), vertical: false),
                     style: StrokeStyle(lineWidth: max(0.7, s * 0.01), lineCap: .round, lineJoin: .round))
            g.fill(Ellipse().path(in: mount), with: linear(silver, mount))
            g.stroke(Ellipse().path(in: mount), with: .color(edge), lineWidth: line)
            let busy = mood == .thinking || mood == .working || mood == .talking
            let pulse = busy ? 0.6 + 0.4 * sin(t * 6) : 0.8 + 0.2 * sin(t * 1.5)
            let br = s * 0.05
            g.fill(Circle().path(in: CGRect(x: tip.x - br * 2.6, y: tip.y - br * 2.6, width: br * 5.2, height: br * 5.2)),
                   with: .radialGradient(Gradient(colors: [palette.eye.opacity(0.55 * pulse), palette.eye.opacity(0)]), center: tip, startRadius: 0, endRadius: br * 2.6))
            gem(g, tip, br, palette.eye)
            if detail {
                let a = t * 2.5
                let o = CGPoint(x: tip.x + CGFloat(cos(a)) * br * 1.9, y: tip.y + CGFloat(sin(a)) * br * 0.8)
                g.draw(Text("✦").font(.system(size: s * 0.045)).foregroundColor(.white.opacity(0.8)), at: o)
            }
        }
    }
}

/// Pick Puff's body, accessory and finish (onboarding "Make me yours" and Settings).
struct PuffLookPicker: View {
    @AppStorage(PuffLook.pref) private var lookID = PuffLook.original.id
    var onPick: (() -> Void)? = nil

    private var look: PuffLook { PuffLook(id: lookID) }

    var body: some View {
        VStack(spacing: 10) {
            row("Body") {
                ForEach(PuffShape.allCases) { sh in
                    chip(selected: look.shape == sh, help: sh.name) {
                        var l = look; l.shape = sh; lookID = l.id; onPick?()
                    } label: {
                        PuffCanvas(size: 30, mood: .idle, palette: AvatarPalette.named(UserDefaults.standard.string(forKey: "avatarPalette") ?? "aurora"),
                                   t: 0, gaze: .zero, outfit: PuffLook(shape: sh, accessory: .none, finish: look.finish))
                            .frame(width: 30, height: 30)
                    }
                }
            }
            row("Extra") {
                ForEach(PuffAccessory.allCases) { a in
                    chip(selected: look.accessory == a, help: a.name) {
                        var l = look; l.accessory = a; lookID = l.id; onPick?()
                    } label: {
                        Image(systemName: a.icon).font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                    }
                }
            }
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { look.finish }, set: { var l = look; l.finish = $0; lookID = l.id; onPick?() })) {
                    ForEach(PuffFinish.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Button {
                    lookID = PuffLook.surprise(not: look) { Int.random(in: 0..<$0) }.id
                    onPick?()
                } label: { Label("Surprise me", systemImage: "dice.fill").font(.system(size: 11.5, weight: .medium)) }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                if look != .original {
                    Button("Original") { lookID = PuffLook.original.id; onPick?() }
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.tertiary).frame(width: 34, alignment: .trailing)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { content() } }
        }
    }

    private func chip<L: View>(selected: Bool, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            label()
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.glow[0].opacity(0.22) : .white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.glow[0] : Theme.hairline, lineWidth: selected ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .animation(.spring(duration: 0.25, bounce: 0.4), value: selected)
    }
}
