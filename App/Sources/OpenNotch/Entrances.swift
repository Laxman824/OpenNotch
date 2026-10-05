import Foundation

// Puff's entrances on the chat's empty stage, its greeting, and being tossed around — all pure
// (curves of time, checked by --checks). `OnboardingStageView` draws them with cached sprites on
// CALayers (rule 7); nothing here touches a view.

enum Entrance: String, CaseIterable {
    case slam                 // the superhero landing (OnboardingStageView's own .landing phase)
    case umbrella             // floats down under an umbrella, closes it
    case rope                 // slides down a rope, swings, lets go
    case portal               // a glowing ring opens on the floor and pops Puff out
    case bungee               // drops on a cord, bounces, unclips
    case roll                 // rolls in from the side as a ball, a bit dizzy (rare)
    case soft                 // Calm liveliness: a small, quiet drop
    case appear               // Reduce Motion: fades in
    // Hero entrances (Lively): short cinematic shots like the onboarding landing.
    case meteor               // a flaming comet streaks in: crater, fire ring, embers, smoke
    case lightning            // the screen darkens, a bolt strikes, Puff stands in the flash
    case jetpack              // flies down on a flame, hovers in a dust storm, cuts out, drops
    case teleport             // a beam of light; Puff materialises, ring burst
    case spinDash             // rolls in as a spinning ball, kicks up dust, springs into the hero pose

    /// The big, energetic ones (Lively): full effects, slow-mo, punch-in, shake.
    var isHero: Bool { [.slam, .meteor, .lightning, .jetpack, .teleport, .spinDash].contains(self) }
}

/// One-shot effects an entrance fires at a moment (the stage draws them).
enum EntranceCue: Equatable {
    case charge               // the notch-top glow and dripping sparks
    case impact               // the full superhero slam (flash, cracks, debris, shockwaves, aura)
    case fireImpact           // crater, fire ring, embers, smoke
    case electricImpact       // cyan shockwaves and crackles
    case smallImpact          // a shockwave and dust
    case bolt                 // a lightning bolt from the top to Puff
    case materialize          // ring burst + sparkles
    case dust                 // a puff of dust
    case sparkles
}

/// Where Puff and its props are at time t of an entrance. Heights in points above the floor.
struct EntranceFrame: Equatable {
    var feet = 0.0
    var dx = 0.0              // points from its spot
    var spin = 0.0            // radians
    var lean = 0.0
    var scale = 1.0
    var opacity = 1.0
    var squash = 0.0
    var clip = "idle"
    var expression: PuffExpression?
    var trail = false
    var umbrella = 0.0        // 0 closed/hidden … 1 open
    var ropeEnd: Double?      // the rope/cord's lower end (points above the floor); nil = no rope
    var ring = 0.0            // portal ring, 0…1
    var flame = 0.0           // jet flame under the feet (jetpack) or a fiery aura (meteor), 0…1
    var beam = 0.0            // a column of light (teleport), 0…1
    var dark = 0.0            // the stage darkens (lightning), 0…1
}

enum EntranceLogic {
    static func duration(_ e: Entrance) -> Double {
        switch e {
        case .slam: return OnboardingLogic.fallTime + 0.45
        case .umbrella: return 2.5
        case .rope: return 2.3
        case .portal: return 1.7
        case .bungee: return 2.8
        case .roll: return 2.0
        case .soft: return 0.9
        case .appear: return 0.4
        case .meteor: return 1.7
        case .lightning: return 1.75
        case .jetpack: return 2.2
        case .teleport: return 1.6
        case .spinDash: return 1.9
        }
    }

    /// Effects and when they fire (seconds of scene time).
    static func cues(_ e: Entrance) -> [(at: Double, cue: EntranceCue)] {
        switch e {
        case .slam: return []                                  // the stage's own charge/landing phases
        case .meteor: return [(0.55, .fireImpact), (1.05, .sparkles)]
        case .lightning: return [(0.32, .bolt), (0.36, .electricImpact), (0.62, .bolt), (1.15, .sparkles)]
        case .jetpack: return [(0.85, .dust), (1.55, .smallImpact)]
        case .teleport: return [(0.75, .materialize)]
        case .spinDash: return [(0.75, .dust), (1.12, .impact)]
        case .umbrella, .rope, .portal, .bungee, .roll, .soft, .appear: return []
        }
    }

    /// Slow motion just before the big moment — the "shot" (1 = real time).
    static func timeScale(_ e: Entrance, t: Double) -> Double {
        let impact: Double?
        switch e {
        case .slam: impact = OnboardingLogic.fallTime
        case .meteor: impact = 0.55
        case .spinDash: impact = 1.12
        case .jetpack: impact = 1.55
        default: impact = nil
        }
        guard let i = impact, t > i - 0.16, t < i else { return 1 }
        return 0.35
    }

    /// When it first touches the floor (dust, sound); nil = no impact.
    static func touchdown(_ e: Entrance) -> Double? {
        switch e {
        case .slam: return OnboardingLogic.fallTime
        case .umbrella: return 1.9
        case .rope: return 1.78
        case .portal: return 1.05
        case .bungee: return 2.1
        case .roll: return 1.3
        case .soft: return 0.6
        case .appear: return nil
        case .meteor: return 0.55
        case .lightning: return nil
        case .jetpack: return 1.55
        case .teleport: return nil
        case .spinDash: return 1.12
        }
    }

    /// Which entrance this time: Reduce Motion fades, Calm drops softly, otherwise a weighted pick
    /// that never repeats the last one. `roll` ∈ [0, 1).
    static func pick(liveliness: Liveliness, reduceMotion: Bool, last: Entrance?, roll: Double) -> Entrance {
        if reduceMotion { return .appear }
        if liveliness == .calm { return .soft }
        // Lively (the default): hero shots. Friendly: the gentler set.
        let weights: [(Entrance, Double)] = liveliness == .lively
            ? [(.slam, 3), (.meteor, 2), (.lightning, 2), (.jetpack, 2), (.teleport, 2), (.spinDash, 2)]
            : [(.slam, 1), (.umbrella, 2), (.rope, 2), (.portal, 2), (.bungee, 1), (.roll, 1)]
        let pool = weights.filter { $0.0 != last }
        let total = pool.reduce(0) { $0 + $1.1 }
        var r = max(0, min(0.999_999, roll)) * total
        for (e, w) in pool {
            if r < w { return e }
            r -= w
        }
        return pool.last?.0 ?? .slam
    }

    private static func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
    private static func easeInOut(_ p: Double) -> Double { let q = clamp(p); return q * q * (3 - 2 * q) }
    private static func easeOut(_ p: Double) -> Double { let q = clamp(p); return 1 - (1 - q) * (1 - q) }
    /// A landing wobble: squash that rings down after touching the floor.
    static func wobble(_ since: Double, amount: Double = 0.18) -> Double {
        since < 0 ? 0 : amount * exp(-since * 7) * cos(since * 22)
    }

    /// `drop` = how far above the floor Puff starts (top of the stage); `size` = Puff's size;
    /// `side` = which side a roll comes from (±1); `width` = the stage width.
    static func frame(_ e: Entrance, t: Double, drop h: Double, size: Double, width: Double, side: Double = 1) -> EntranceFrame {
        var f = EntranceFrame()
        let hands = size * 0.92
        switch e {
        case .slam:
            break                                        // drawn by the stage's own landing phase

        case .umbrella:
            let land = touchdown(e) ?? 1.9
            f.umbrella = 1
            if t < land {
                let p = t / land
                f.feet = h * pow(1 - p, 1.15)
                f.dx = 14 * sin(t * 3.2) * (1 - p)
                f.lean = 0.1 * sin(t * 3.2 + 0.6) * (1 - p)
                f.clip = "stretch"
            } else {
                f.squash = wobble(t - land, amount: 0.12)
                f.umbrella = clamp(1 - (t - land - 0.1) / 0.35)
                f.clip = f.umbrella > 0.3 ? "stretch" : "idle"
            }

        case .rope:
            let hang = 22.0, slide = 1.2, release = 1.6, land = touchdown(e) ?? 1.78
            f.clip = "stretch"
            if t < slide {
                f.feet = h + (hang - h) * easeInOut(t / slide)
                f.ropeEnd = f.feet + hands
            } else if t < release {
                let s = t - slide
                f.feet = hang + 3 * sin(s * 14) * exp(-s * 4)
                f.lean = 0.12 * sin(s * 7)
                f.ropeEnd = f.feet + hands
            } else if t < land {
                let q = (t - release) / (land - release)
                f.feet = hang * (1 - q * q)
                f.ropeEnd = hang + hands + (t - release) * 600
            } else {
                f.feet = 0
                f.squash = wobble(t - land)
                f.ropeEnd = hang + hands + (t - release) * 600
                f.clip = t - land < 0.25 ? "stretch" : "idle"
            }
            if let r = f.ropeEnd, r > h + size * 2 { f.ropeEnd = nil }

        case .portal:
            let open = 0.3, top = 0.75, land = touchdown(e) ?? 1.05
            f.ring = t < open ? easeOut(t / open) : (t < 1.15 ? 1 : clamp(1 - (t - 1.15) / 0.3))
            if t < open {
                f.opacity = 0; f.scale = 0.2
            } else if t < top {
                let q = (t - open) / (top - open)
                let back = 1 + 2.2 * pow(q - 1, 3) + 1.2 * pow(q - 1, 2)      // ease-out-back
                f.scale = 0.2 + 0.8 * back
                f.feet = 46 * sin(q * .pi / 2)
                f.clip = "stretch"; f.expression = .celebrate
            } else if t < land {
                let q = (t - top) / (land - top)
                f.feet = 46 * (1 - q * q)
                f.clip = "stretch"
            } else {
                f.squash = wobble(t - land)
            }

        case .bungee:
            let fall = 0.45, unclip = 1.9, land = touchdown(e) ?? 2.1
            f.clip = "stretch"
            if t < fall {
                let q = t / fall
                f.feet = h + (10 - h) * q * q
                f.trail = true
                f.ropeEnd = f.feet + hands
                f.expression = .surprised
            } else if t < unclip {
                let s = t - fall
                f.feet = 34 - 24 * exp(-s * 2.2) * cos(s * 9)
                f.ropeEnd = f.feet + hands
                f.expression = s < 0.7 ? .surprised : nil
            } else if t < land {
                let s = unclip - fall
                let from = 34 - 24 * exp(-s * 2.2) * cos(s * 9)
                let q = (t - unclip) / (land - unclip)
                f.feet = from * (1 - q * q)
                f.ropeEnd = from + hands + (t - unclip) * 700
            } else {
                f.squash = wobble(t - land)
                f.expression = t - land < 0.5 ? .dizzy : nil
                f.clip = "idle"
                f.ropeEnd = nil
            }

        case .roll:
            let stop = touchdown(e) ?? 1.3
            if t < stop {
                let travel = width * 0.6 * (1 - easeOut(t / stop))
                f.dx = -side * travel
                f.spin = side * travel / max(1, size * 0.45)            // rolling: angle = distance / radius
                f.feet = 3 * abs(sin(t * 12)) * (1 - t / stop)
            } else {
                let s = t - stop
                f.lean = 0.15 * sin(s * 16) * exp(-s * 5)
                f.squash = wobble(s, amount: 0.1)
                f.expression = s < 0.6 ? .dizzy : nil
            }

        case .soft:
            let land = touchdown(e) ?? 0.6
            f.opacity = clamp(t / 0.3)
            f.feet = t < land ? 26 * (1 - easeOut(t / land)) : 0
            f.squash = wobble(t - land, amount: 0.06)

        case .appear:
            f.opacity = clamp(t / duration(e))

        case .meteor:
            let hit = 0.55, rise = 1.25
            if t < hit {
                let q = t / hit
                let k = q * q                                          // accelerating
                f.dx = -side * width * 0.42 * (1 - k)
                f.feet = h * (1 - k)
                f.spin = side * 6 * q
                f.clip = "stretch"; f.trail = true; f.flame = 1; f.expression = .heroic
                f.scale = 0.75 + 0.25 * q
            } else if t < rise {
                f.clip = "hero"; f.expression = .heroic
                f.squash = wobble(t - hit, amount: 0.22)
                f.lean = 0.16 * min(1, (t - hit) / 0.15)
                f.flame = clamp(1 - (t - hit) / 0.5)
            } else {
                f.clip = "idle"
                f.squash = wobble(t - rise, amount: 0.06)
            }

        case .lightning:
            f.dark = t < 0.3 ? easeOut(t / 0.3) : clamp(1 - (t - 0.9) / 0.5)
            if t < 0.34 {
                f.opacity = 0
            } else if t < 1.25 {
                // Stands in the flash: flickers in, hero pose, crackling.
                f.opacity = t < 0.5 ? (Int(t * 40) % 2 == 0 ? 1 : 0.35) : 1
                f.clip = "hero"; f.expression = .heroic
                f.lean = 0.14
                f.squash = wobble(t - 0.36, amount: 0.15)
            } else {
                f.clip = "idle"
            }

        case .jetpack:
            let hover = 0.85, cut = 1.35, land = 1.55
            f.clip = "stretch"
            if t < hover {
                let q = easeOut(t / hover)
                f.feet = h + (34 - h) * q
                f.dx = side * 10 * sin(t * 9) * (1 - q)
                f.flame = 1
            } else if t < cut {
                f.feet = 34 + 3 * sin((t - hover) * 18)
                f.lean = 0.06 * sin((t - hover) * 9)
                f.flame = 0.8 + 0.2 * sin(t * 40)
            } else if t < land {
                let q = (t - cut) / (land - cut)
                f.feet = 34 * (1 - q * q)
                f.expression = .surprised
            } else {
                f.squash = wobble(t - land, amount: 0.2)
                f.clip = t - land < 0.25 ? "stretch" : "idle"
            }

        case .teleport:
            f.beam = t < 0.3 ? easeOut(t / 0.3) : clamp(1 - (t - 0.85) / 0.35)
            if t < 0.3 {
                f.opacity = 0
            } else if t < 0.8 {
                let q = (t - 0.3) / 0.5
                f.opacity = q < 0.7 ? (Int(t * 30) % 2 == 0 ? 0.9 : 0.4) : 1
                f.scale = 0.15 + 0.85 * easeOut(q)
                f.feet = 10 * (1 - q)
                f.clip = "stretch"; f.expression = .heroic
            } else {
                f.clip = t < 1.2 ? "hero" : "idle"; f.expression = t < 1.2 ? .heroic : nil
                f.lean = t < 1.2 ? 0.1 : 0
                f.squash = wobble(t - 0.8, amount: 0.12)
            }

        case .spinDash:
            let skid = 0.75, apex = 0.95, land = 1.12
            if t < skid {
                let q = easeOut(t / skid)
                let travel = width * 0.55 * (1 - q)
                f.dx = side * travel
                f.spin = -side * (width * 0.55 - travel) / max(1, size * 0.4) - side * t * 4
                f.feet = 2 * abs(sin(t * 20))
                f.trail = true
                f.squash = 0.12                                         // a squashed ball
            } else if t < land {
                let q = (t - skid) / (land - skid)
                f.feet = 46 * sin(q * .pi) * (t < apex ? 1 : 1)
                f.spin = -side * 2 * .pi * (1 - q)                       // unrolls into the pose
                f.clip = "stretch"; f.expression = .heroic
            } else {
                f.clip = t < 1.6 ? "hero" : "idle"; f.expression = t < 1.6 ? .heroic : nil
                f.lean = t < 1.6 ? 0.16 : 0
                f.squash = wobble(t - land, amount: 0.22)
            }
        }
        return f
    }
}

/// What Puff says (and does first) when it lands in a new chat.
struct Greeting: Equatable {
    var line: String
    var first: PerchAction = .wave
    var expression: PuffExpression?
    var party = false
}

enum GreetingLogic {
    static func greeting(now: Date, calendar: Calendar = .current, lastLanding: Date?, roll: Double) -> Greeting {
        if let last = lastLanding {
            let gap = now.timeIntervalSince(last)
            if gap >= 0 && gap < 600 {
                return Greeting(line: roll < 0.5 ? "Round two! 💪" : "Again? Let's go! 🚀", first: .hop)
            }
            if gap > 3 * 86_400 { return Greeting(line: "Missed you! 💛", first: .hop, expression: .love) }
        }
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)          // 1 = Sunday … 7 = Saturday
        if weekday == 6 && hour >= 15 && hour < 22 { return Greeting(line: "Almost the weekend! 🎉", first: .hop, party: true) }
        if weekday == 2 && hour >= 5 && hour < 12 { return Greeting(line: "New week, let's go! 💪", first: .stretch) }
        if (weekday == 1 || weekday == 7) && hour >= 9 && hour < 18 { return Greeting(line: "Happy weekend! 🌴", first: .wave) }
        switch hour {
        case 5..<11: return Greeting(line: "Good morning! ☀️", first: hour < 8 ? .yawn : .stretch)
        case 11..<17:
            let lines = ["Hi! 👋", "Hey there! 👋", "What's up? ✨"]
            return Greeting(line: lines[min(lines.count - 1, Int(max(0, roll) * Double(lines.count)))], first: .wave)
        case 17..<22: return Greeting(line: "Good evening! 🌆", first: .wave)
        default: return Greeting(line: "Up late? 🌙", first: .yawn)
        }
    }
}

/// Picked up and thrown: a ball with gravity, bouncing off the floor and the stage's sides.
struct TossState: Equatable {
    var x: Double, y: Double            // x = Puff's centre, y = feet (points)
    var vx: Double, vy: Double
    var spin = 0.0
}

enum TossLogic {
    static let gravity = 2200.0
    static let maxSpeed = 1600.0

    static func clampVelocity(_ vx: Double, _ vy: Double) -> (Double, Double) {
        let s = (vx * vx + vy * vy).squareRoot()
        guard s > maxSpeed else { return (vx, vy) }
        return (vx / s * maxSpeed, vy / s * maxSpeed)
    }

    /// One step. Returns the speed of a floor hit this step (for squash/sound), if any.
    static func step(_ s: TossState, dt: Double, minX: Double, maxX: Double, floor: Double, ceiling: Double,
                     radius: Double) -> (TossState, floorHit: Double?) {
        var n = s
        n.vy -= gravity * dt
        n.x += n.vx * dt
        n.y += n.vy * dt
        n.spin -= n.vx * dt / max(1, radius)
        var hit: Double?
        if n.x < minX { n.x = minX; n.vx = abs(n.vx) * 0.55 }
        if n.x > maxX { n.x = maxX; n.vx = -abs(n.vx) * 0.55 }
        if n.y > ceiling { n.y = ceiling; n.vy = -abs(n.vy) * 0.4 }
        if n.y <= floor {
            n.y = floor
            if n.vy < 0 {
                hit = -n.vy
                n.vy = -n.vy * 0.42
                n.vx *= 0.8
                if n.vy < 60 { n.vy = 0 }
            }
            n.vx *= max(0, 1 - 3 * dt)                         // rolling friction on the floor
        }
        return (n, hit)
    }

    static func settled(_ s: TossState, floor: Double) -> Bool {
        s.y <= floor + 0.5 && abs(s.vy) < 1 && abs(s.vx) < 25
    }
}

/// Where Puff looks: toward the pointer when it's to one side (−1, 0, 1).
enum GazeLogic {
    static func toward(dx: Double, deadZone: Double = 30) -> Int { dx > deadZone ? 1 : (dx < -deadZone ? -1 : 0) }
}
