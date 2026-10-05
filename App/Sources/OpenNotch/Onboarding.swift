import AppKit
import SwiftUI

// First run, inside the notch instead of a Settings window: Puff crash-lands out of
// the notch (superhero landing), then walks you through (1) how to open and close it,
// (2) an optional desktop buddy, (3) an AI, (4) a first try — with Back at every step.
// Nothing here asks for a permission — each feature asks the first time it's used
// (the notch steps aside for the dialog). The full checklist stays in Settings › Permissions.

/// Pure rules (checked in AgentChecks).
enum OnboardingLogic {
    enum Brain: Equatable { case none, apple, other(String) }

    static func brain(connected: Bool, kind: ProviderKind?) -> Brain {
        guard connected, let kind else { return .none }
        return kind == .apple ? .apple : .other(kind.label)
    }

    /// Desktop companions offered on the buddy step (ids match `DesktopCompanion.avatarNames`).
    static let buddies: [(id: String, name: String, icon: String, tint: Color)] = [
        ("ledge", "Classic", "figure.wave", Color(red: 0.72, green: 0.64, blue: 1.0)),
        ("bee", "Bee", "ladybug.fill", Color(red: 1.0, green: 0.62, blue: 0.2)),
        ("cat", "Cat", "cat.fill", Color(red: 0.55, green: 0.95, blue: 0.5)),
    ]

    /// Tries that work with no permissions and no setup.
    static let tries = ["What can you do?", "Set a 5-minute timer", "Brainstorm 5 names for a cat"]

    static let steps = 6

    /// What Puff says on the stage at each step (and when poked).
    static func line(_ step: Int) -> String {
        ["Got a better name for me? ✍️", "Dress me up! 🎨", "That's my notch up there ☝️", "Pick a friend! 🐝",
         "Brain time! 🧠", "Ooh — try one! ✨"][max(0, min(steps - 1, step))]
    }

    /// Name ideas on the name step (never another product's character name).
    static let nameIdeas = ["Ledge", "Nova", "Jarvis", "Pixel", "Bolt"]

    /// A usable assistant name (it's also the hands-free wake word): 1–20 letters,
    /// digits, spaces, - or '. Nil if it isn't one.
    static func cleanName(_ raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard (1...20).contains(n.count), n.rangeOfCharacter(from: .letters) != nil,
              n.range(of: #"^[\p{L}\p{N} '\-]+$"#, options: .regularExpression) != nil else { return nil }
        return n
    }

    /// Desktop buddy cheer for an onboarding step (`DesktopCompanion.cheerOnboarding`), if any.
    static func cheer(_ step: Int) -> Int? { [4: 2, 5: 3][step] }
    static let pokeLines = ["Hey! 😆", "That tickles!", "Boop!", "Again? 🙈", "I'm working here! 😤"]

    /// Where Puff stands (0…1 across the stage) for each step — it walks over when you move on.
    static func spot(_ step: Int) -> Double { [0.2, 0.5, 0.8, 0.18, 0.82, 0.5][max(0, min(steps - 1, step))] }

    /// What Puff says when you pick a colour on the colours step.
    static let colourLines = ["Ooh, I like it! 💜", "So fresh! ✨", "Is this my colour? 😍", "Looking sharp! 😎", "Fancy! 🌈"]

    // The landing, as pure curves of time since the drop began (seconds; a 0.75 s
    // charge-up at the notch comes before it).
    static let chargeTime = 0.75
    static let fallTime = 0.42

    /// One full forward flip on the way down.
    static func spin(_ t: Double) -> Double { -2 * .pi * fall(t) }

    /// 0 at the top → 1 on the ground: accelerating, like a drop.
    static func fall(_ t: Double) -> Double { let p = max(0, min(1, t / fallTime)); return p * p }

    /// Squash after the slam (+ = flatter): a big hit that rings out.
    static func impactSquash(_ t: Double) -> Double {
        let s = t - fallTime
        guard s >= 0 else { return -0.22 * fall(t) }            // stretched thin while falling
        return 0.55 * exp(-7 * s) * cos(17 * s)
    }

    /// Camera-shake offset (points) for the content, `p` 0…1 over the shake.
    static func shake(_ p: Double) -> Double { p <= 0 || p >= 1 ? 0 : 8 * sin(p * .pi * 9) * (1 - p) }
}

struct OnboardingView: View {
    @ObservedObject var notch: NotchController
    @ObservedObject var backend: Backend
    @ObservedObject var hub: Hub
    @StateObject private var ai = AIModel()
    @AppStorage("assistantName") private var assistantName = "Ledge"
    @State private var step = 0
    @State private var forward = true
    @State private var phase = Phase.landing
    @State private var shake: Double = 0
    @State private var stage = StageDirector()
    @State private var picked: String? = DesktopCompanion.enabled ? DesktopCompanion.avatar : nil
    @State private var nameDraft = Prefs.name
    @FocusState private var nameFocused: Bool

    enum Phase { case landing, hello, steps }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: StageDirector.band)        // Puff's stage
            if phase == .steps {
                dots.transition(.opacity)
                Group {
                    switch step {
                    case 0: naming
                    case 1: colours
                    case 2: hello
                    case 3: buddy
                    case 4: brain
                    default: tryOne
                    }
                }
                .frame(maxWidth: 440)
                .frame(maxHeight: .infinity)
                .id(step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: forward ? 30 : -30)).combined(with: .scale(scale: 0.97)),
                    removal: .opacity.combined(with: .offset(x: forward ? -30 : 30))))
                footer
            } else {
                Spacer()
            }
        }
        .modifier(Shake(p: shake))
        .overlay {
            // Said while Puff stands up from the landing, before the steps slide in.
            if phase == .hello {
                VStack(spacing: 6) {
                    PopTitle(text: "Hi! I'm \(assistantName)!")
                    Text("I live in your notch. Let's get you set up — 30 seconds.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 272)                          // under Puff, who stands mid-panel
                .transition(.opacity.combined(with: .scale(scale: 0.85)).combined(with: .offset(y: 12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Theme.panel
                Color.black
                OnboardingStage(director: stage)
            }
        }
        .onAppear(perform: start)
        .onChange(of: ai.active) { _, k in
            // Signed in from the brain step: move on by itself.
            if step == 4, k == .openrouter { go(5) }
        }
    }

    // MARK: flow

    private func start() {
        step = 0; phase = .landing; forward = true
        stage.onImpact = {
            shake = 0
            withAnimation(.linear(duration: 0.5)) { shake = 1 }
        }
        stage.onStandUp = {
            withAnimation(.spring(duration: 0.45, bounce: 0.35)) { phase = .hello }
        }
        stage.onReady = {
            withAnimation(.easeOut(duration: 0.2)) { phase = .steps }
            desktop?.cheerOnboarding(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if step == 0 { stage.say(OnboardingLogic.line(0)) } }
        }
        nameDraft = assistantName
        // Give the stage view a moment to get its size, then drop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { stage.land(at: OnboardingLogic.spot(0)) }
    }

    private func go(_ s: Int) {
        let s = max(0, min(OnboardingLogic.steps - 1, s))
        guard s != step else { return }
        forward = s > step
        withAnimation(.spring(duration: 0.42, bounce: 0.18)) { step = s }
        stage.walk(to: OnboardingLogic.spot(s), excited: forward)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if step == s { stage.say(OnboardingLogic.line(s)) } }
        SoundFX.play(forward ? (s == OnboardingLogic.steps - 1 ? .yay : .boop) : .pop)
        if forward, let c = OnboardingLogic.cheer(s) { desktop?.cheerOnboarding(c) }
        if s != 0 { nameFocused = false }
    }

    private func finish(skipped: Bool = false) {
        desktop?.cheerOnboarding(skipped ? -1 : 4)
        UserDefaults.standard.set(true, forKey: Prefs.onboardingDone)
        let close = {
            hub.module = .chat
            withAnimation(.easeOut(duration: 0.25)) { notch.onboarding = false }
            notch.focusInput = true
        }
        if skipped { close(); return }
        // A little victory dance (and confetti) before the chat takes over.
        stage.dance()
        stage.say("Let's gooo! 🚀")
        SoundFX.play(.yay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { close() }
    }

    // MARK: steps

    private var hello: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                Text("Open me from anywhere").font(Typo.title(19))
                Text("Ask me anything, or let me do small jobs on your Mac.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                tip("cursorarrow.motionlines", "Point at the notch", "to open me")
                tip("keyboard", "Press ⌥Space", "from any app")
                tip("escape", "Move away or press Esc", "to close")
                tip("doc.badge.plus", "Drop a file on the notch", "to ask about it")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            primary("Next") { go(3) }
        }
    }

    /// Make me yours: body shape, an extra, jelly or plush, and colours — Puff on the stage changes as you pick.
    private var colours: some View {
        let picked = {
            stage.cheer()
            stage.say(OnboardingLogic.colourLines.randomElement() ?? "Nice! ✨")
            SoundFX.play(.boop)
        }
        return VStack(spacing: 12) {
            VStack(spacing: 5) {
                Text("Make me yours").font(Typo.title(19))
                Text("Pick my body, an extra and my colours — or let me surprise you. Change it any time in Settings › General.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            PuffLookPicker(onPick: picked)
            PuffColorPicker(onPick: picked)
            primary("Next") { go(2) }
        }
    }

    /// Ledge is the default; any name works (it's also the hands-free wake word).
    private var naming: some View {
        let clean = OnboardingLogic.cleanName(nameDraft)
        return VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("What should you call me?").font(Typo.title(19))
                Text("\"Ledge\" is fine — or give me a name you like. You'll also say it to wake me in hands-free mode.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Ledge", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .padding(.vertical, 9).padding(.horizontal, 14)
                .frame(width: 260)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(clean == nil && !nameDraft.isEmpty ? Color.orange : (nameFocused ? Theme.glow[0] : Theme.hairline),
                                  lineWidth: nameFocused ? 1.5 : 1))
                .onSubmit { saveName() }
            HStack(spacing: 6) {
                ForEach(OnboardingLogic.nameIdeas, id: \.self) { n in
                    Button { nameDraft = n; stage.cheer() } label: {
                        Text(n).font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(nameDraft == n ? Theme.glow[0].opacity(0.25) : .white.opacity(0.06)))
                            .overlay(Capsule().stroke(nameDraft == n ? Theme.glow[0] : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            primary(clean.map { $0 == assistantName ? "Keep \($0)" : "Call me \($0)" } ?? "Next") { saveName() }
                .disabled(clean == nil)
        }
        .onAppear { nameDraft = assistantName }
    }

    private func saveName() {
        guard let n = OnboardingLogic.cleanName(nameDraft) else { return }
        let changed = n != assistantName
        assistantName = n
        VoiceTurn.wakeName = n
        if changed {
            stage.cheer()
            stage.say("\(n) it is! 🎉")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { go(1) }
        } else {
            go(1)
        }
    }

    /// Opt-in: nobody walks the desktop unless picked here or in Settings › Desktop.
    private var buddy: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Want a buddy on your desktop?").font(Typo.title(19))
                Text("Pick one and it hops out of the notch, walks around your screen and cheers you on. Optional — change it any time in Settings › Desktop.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ForEach(OnboardingLogic.buddies, id: \.id) { b in
                    Button { pick(b.id) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: b.icon).font(.system(size: 26)).foregroundStyle(b.tint)
                                .symbolEffect(.bounce, value: picked == b.id)
                            Text(b.name).font(.system(size: 12.5, weight: .bold))
                        }
                        .frame(width: 118, height: 84)
                        .background(RoundedRectangle(cornerRadius: 14).fill(picked == b.id ? b.tint.opacity(0.2) : .white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(picked == b.id ? b.tint : Theme.hairline, lineWidth: picked == b.id ? 2 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(HoverLift())
                    .accessibilityAddTraits(picked == b.id ? .isSelected : [])
                }
            }
            if picked != nil {
                primary("Next") { go(4) }
            } else {
                secondary("No thanks, just the notch") { go(4) }
            }
        }
    }

    private func pick(_ id: String) {
        guard let d = desktop else { return }
        let first = picked == nil
        picked = id
        stage.cheer()
        if id != DesktopCompanion.avatar || !DesktopCompanion.enabled { d.setAvatar(id) }
        d.entrance()
        if first { d.cheerOnboarding(1) }
    }

    @ViewBuilder private var brain: some View {
        let b = OnboardingLogic.brain(connected: backend.aiConnected, kind: ProviderStore.activeKind)
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(b == .none ? "Give me a brain" : "My brain").font(Typo.title(19))
                Text(brainText(b)).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let busy = ai.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(.system(size: 12)) }
            } else if let m = ai.message, !m.ok {
                Text(m.text).font(.system(size: 11.5)).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            switch b {
            case .other:
                primary("Next") { go(5) }
            case .apple:
                primary("Keep Apple's AI") { go(5) }
                secondary("Sign in with OpenRouter — free, smarter") { ai.signInOpenRouter() }
            case .none:
                primary("Sign in with OpenRouter — free, no card") { ai.signInOpenRouter() }
                HStack(spacing: 16) {
                    secondary("Use my own API key…") { SettingsWindow.shared.show(.ai) }
                    secondary("Later") { go(5) }
                }
            }
        }
    }

    private func brainText(_ b: OnboardingLogic.Brain) -> String {
        switch b {
        case .none:
            return "I need an AI to think with. The quickest way is free: sign in with OpenRouter in your browser. Or paste a key from OpenAI, Anthropic, Gemini or Groq, or run a local model."
        case .apple:
            return "I'm using Apple's on-device AI — free, private, works offline. It's fine for quick questions and short texts. For bigger jobs (several steps, the web, email) sign in with OpenRouter: also free."
        case .other(let name):
            return "Connected to \(name). You can switch any time from the model name at the top."
        }
    }

    private var tryOne: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Try one").font(Typo.title(19))
                Text("I ask before I touch your calendar, files or apps — and before anything risky. Nothing is ever sent without you.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                ForEach(OnboardingLogic.tries, id: \.self) { q in
                    Button { finish(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { backend.send(q) } } label: {
                        HStack {
                            Text(q).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.glow[0])
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(HoverLift())
                }
            }
            secondary("I'll type my own") { finish() }
        }
    }

    // MARK: pieces

    private var footer: some View {
        HStack {
            if step > 0 {
                Button { go(step - 1) } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .transition(.opacity)
            }
            Spacer()
            Button("Skip setup") { finish(skipped: true) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 22).padding(.bottom, 14)
        .animation(.easeOut(duration: 0.2), value: step)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<OnboardingLogic.steps, id: \.self) { i in
                // Dots are buttons too: jump back to any step you've seen.
                Button { if i < step { go(i) } } label: {
                    Capsule().fill(i == step ? Theme.glow[0] : .white.opacity(i < step ? 0.45 : 0.2))
                        .frame(width: i == step ? 18 : 6, height: 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(i >= step)
            }
        }
        .animation(.spring(duration: 0.3), value: step)
        .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(OnboardingLogic.steps)")
    }

    private func tip(_ icon: String, _ bold: String, _ rest: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.glow[0]).frame(width: 22)
            Text(bold).font(.system(size: 12.5, weight: .semibold)) + Text(" " + rest).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
        }
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 9)
                .background(Capsule().fill(Theme.userBubble))
        }
        .buttonStyle(HoverLift())
        .keyboardShortcut(.defaultAction)
        .disabled(ai.busy != nil)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
    }

    private var desktop: DesktopCompanion? { (NSApp.delegate as? AppDelegate)?.desktop }
}

/// The intro title, letter by letter: each pops up with a little overshoot (one-shot).
struct PopTitle: View {
    let text: String
    var font: Font = Typo.title(28)
    @State private var shown = false
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { i, ch in
                Text(String(ch))
                    .font(font)
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.glow[0].mix(.white, 0.5)], startPoint: .top, endPoint: .bottom))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 16)
                    .scaleEffect(shown ? 1 : 0.4, anchor: .bottom)
                    .animation(.spring(duration: 0.45, bounce: 0.55).delay(Double(i) * min(0.035, 1.1 / Double(max(1, text.count)))), value: shown)
            }
        }
        .shadow(color: Theme.glow[1].opacity(0.6), radius: 14)
        .onAppear { shown = true }
    }
}

private extension NSColor {
    func mix(with other: NSColor, _ k: CGFloat) -> NSColor { blended(withFraction: k, of: other) ?? self }
}

/// One-shot camera shake for the landing (animates `p` 0 → 1 once).
struct Shake: GeometryEffect {
    var p: Double
    var animatableData: Double { get { p } set { p = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: OnboardingLogic.shake(p)))
    }
}

// MARK: - Puff's stage

/// Tells the stage what to do; the SwiftUI side keeps one and gets the callbacks.
@MainActor
final class StageDirector {
    /// Height of the band at the top where Puff walks once the steps are showing.
    static let band: CGFloat = 104
    weak var view: OnboardingStageView?
    var onImpact: (() -> Void)?
    var onStandUp: (() -> Void)?
    var onReady: (() -> Void)?

    func land(at x: Double) { view?.land(at: x) }
    func walk(to x: Double, excited: Bool) { view?.walk(to: x, excited: excited) }
    func cheer() { view?.cheer() }
    func dance() { view?.dance() }
    func say(_ text: String) { view?.say(text) }
}

/// Puff landing in the chat's empty state ("Hi, I'm … What can I do for you?"), then
/// settling there. Lands once per empty chat; pauses while the notch is closed.
struct HeroStage: NSViewRepresentable {
    var visible: Bool
    var size: CGFloat = 70
    /// The first message was just sent: Puff springs up and out (the handoff).
    var leaving = false
    /// The page flashes and shakes on an impact; the rest of the page builds in once Puff stands.
    var onImpact: (() -> Void)? = nil
    var onStand: (() -> Void)? = nil
    func makeCoordinator() -> StageDirector { StageDirector() }
    func makeNSView(context: Context) -> OnboardingStageView {
        let v = OnboardingStageView()
        v.mini = true
        v.size = size
        v.director = context.coordinator
        context.coordinator.view = v
        return v
    }
    func updateNSView(_ v: OnboardingStageView, context: Context) {
        context.coordinator.onImpact = onImpact
        context.coordinator.onStandUp = onStand
        v.setVisible(visible)
        if leaving { v.leave() }
    }
}

struct OnboardingStage: NSViewRepresentable {
    let director: StageDirector
    func makeNSView(context: Context) -> OnboardingStageView {
        let v = OnboardingStageView()
        v.director = director
        director.view = v
        return v
    }
    func updateNSView(_ v: OnboardingStageView, context: Context) {}
}

/// Puff, big, on CALayers (rule 7: cached sprite frames, a timer only while on screen).
/// The landing: drops out of the notch with speed-trail ghosts, slams into the middle of
/// the panel (squash, flash, two shockwave rings, dust, a camera shake), holds the
/// crouch, springs up and waves — then hops up to the stage band and walks to each
/// step's spot, wandering and fidgeting in between. Click Puff to poke it.
@MainActor
final class OnboardingStageView: NSView {
    enum Phase { case waiting, charge, landing, standing, toBand, walking, wander, dance, entrance, held, thrown, leaving, gone }

    weak var director: StageDirector?
    private let sprites = PerchSprites()
    private let physics = CharacterBrain()
    private let puff = CALayer()
    private let ghosts = [CALayer(), CALayer()]
    private let groundShadow = CALayer()
    /// Streaks above Puff while it drops.
    private let speedLines: [CAGradientLayer] = (0..<5).map { _ in CAGradientLayer() }
    private var timer: Timer?
    private var phase = Phase.waiting
    private var phaseStart = Date()
    private var clip: PerchAction = .idle
    private var clipStart = Date()
    private var nextFidget = Date()
    private var last = Date()
    private var x: CGFloat = 0.5, home: CGFloat = 0.5, target: CGFloat = 0.5, dir: CGFloat = 1
    private var hopFrom: (x: CGFloat, y: CGFloat) = (0.5, 0)
    private var walkSpeed: CGFloat = 150
    private var fast = false
    private var landed = false
    private let bubble = CALayer()
    private let bubbleText = CATextLayer()
    private var bubbleHide: DispatchWorkItem?
    var size: CGFloat = 78
    /// The chat's empty state: a lighter landing (no charge-up, flash, cracks or debris),
    /// then Puff settles where it landed and fidgets — no walking, no band.
    var mini = false
    private var everShown = false
    // Chat entrances (Entrances.swift), greeting, being picked up and tossed, handing off.
    private var entrance = Entrance.slam
    private var rollSide = 1.0
    private var greeting = Greeting(line: "Hi! 👋")
    private let umbrella = CALayer()
    private let canopy = CAShapeLayer()
    private let shaft = CAShapeLayer()
    private let rope = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var downAt: CGPoint?
    private var heldAt = CGPoint.zero
    private var samples: [(p: CGPoint, t: TimeInterval)] = []
    private var toss = TossState(x: 0, y: 0, vx: 0, vy: 0)
    private var tossTop = 0.0
    private var bounceAt = Date.distantPast, bounceAmount = 0.0
    private var exprOverride: PuffExpression?
    private var exprUntil = Date.distantPast
    // Hero shots: scene clock (slow-mo), cues fired so far, and their layers.
    private var sceneT = 0.0
    private var cueIndex = 0
    private let flame = CAGradientLayer()
    private let beamLayer = CAGradientLayer()
    private let darkLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        groundShadow.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        groundShadow.opacity = 0
        layer?.addSublayer(groundShadow)
        for (i, g) in ghosts.enumerated() {
            g.anchorPoint = CGPoint(x: 0.5, y: 0)
            g.contentsGravity = .resizeAspect
            g.opacity = 0
            g.zPosition = CGFloat(-1 - i)
            layer?.addSublayer(g)
        }
        puff.anchorPoint = CGPoint(x: 0.5, y: 0)
        puff.contentsGravity = .resizeAspect
        puff.opacity = 0
        layer?.addSublayer(puff)
        for l in speedLines {
            l.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.55).cgColor]
            l.startPoint = CGPoint(x: 0.5, y: 1); l.endPoint = CGPoint(x: 0.5, y: 0)
            l.cornerRadius = 1
            l.opacity = 0
            layer?.addSublayer(l)
        }
        bubble.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        bubble.cornerRadius = 11
        bubble.opacity = 0
        bubble.zPosition = 10
        bubbleText.fontSize = 12
        bubbleText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        bubbleText.foregroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        bubbleText.alignmentMode = .center
        bubble.addSublayer(bubbleText)
        layer?.addSublayer(bubble)
        // Props for the entrances: an umbrella, a rope/cord, a portal ring on the floor.
        for l in [canopy, shaft] { l.lineCap = .round; umbrella.addSublayer(l) }
        umbrella.anchorPoint = CGPoint(x: 0.5, y: 0)
        umbrella.opacity = 0
        umbrella.zPosition = 2
        rope.lineWidth = 2.5
        rope.lineCap = .round
        rope.fillColor = NSColor.clear.cgColor
        rope.opacity = 0
        ring.fillColor = NSColor(Theme.glow[1]).withAlphaComponent(0.22).cgColor
        ring.strokeColor = NSColor(Theme.glow[0]).cgColor
        ring.lineWidth = 3
        ring.shadowColor = NSColor(Theme.glow[0]).cgColor; ring.shadowRadius = 6; ring.shadowOpacity = 0.9; ring.shadowOffset = .zero
        ring.opacity = 0
        ring.zPosition = -1
        for l in [rope, ring, umbrella] { layer?.addSublayer(l) }
        flame.type = .radial
        flame.colors = [NSColor.white.cgColor, NSColor.systemYellow.cgColor, NSColor.systemOrange.withAlphaComponent(0.85).cgColor,
                        NSColor.systemRed.withAlphaComponent(0).cgColor]
        flame.locations = [0, 0.18, 0.5, 1]
        flame.startPoint = CGPoint(x: 0.5, y: 0.5); flame.endPoint = CGPoint(x: 1, y: 1)
        flame.opacity = 0
        flame.zPosition = -0.5
        beamLayer.colors = [NSColor(Theme.glow[0]).withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.85).cgColor,
                            NSColor(Theme.glow[0]).withAlphaComponent(0).cgColor]
        beamLayer.startPoint = CGPoint(x: 0, y: 0.5); beamLayer.endPoint = CGPoint(x: 1, y: 0.5)
        beamLayer.opacity = 0
        beamLayer.zPosition = -0.4
        darkLayer.backgroundColor = NSColor.black.cgColor
        darkLayer.opacity = 0
        darkLayer.zPosition = -3
        for l in [darkLayer, beamLayer, flame] { layer?.addSublayer(l) }
    }

    /// The umbrella's shapes for Puff's current size (canopy with scalloped rim, hooked shaft).
    private func shapeUmbrella() {
        let w = size * 1.3, shaftH = size * 0.42, h = size * 0.95
        umbrella.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let c = CGMutablePath()
        let rim = shaftH, cx = w / 2, r = w / 2 - 2
        c.move(to: CGPoint(x: cx - r, y: rim))
        c.addQuadCurve(to: CGPoint(x: cx + r, y: rim), control: CGPoint(x: cx, y: rim + (h - rim) * 2))
        let n = 4
        for i in 0..<n {                                       // scallops along the rim, right to left
            let x0 = cx + r - CGFloat(i) * 2 * r / CGFloat(n), x1 = x0 - 2 * r / CGFloat(n)
            c.addQuadCurve(to: CGPoint(x: x1, y: rim), control: CGPoint(x: (x0 + x1) / 2, y: rim - 7))
        }
        c.closeSubpath()
        canopy.path = c
        canopy.fillColor = NSColor(Theme.glow[2]).cgColor
        canopy.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor
        canopy.lineWidth = 1.5
        let sh = CGMutablePath()
        sh.move(to: CGPoint(x: cx, y: rim + 4))
        sh.addLine(to: CGPoint(x: cx, y: 5))
        sh.addQuadCurve(to: CGPoint(x: cx - 7, y: 3), control: CGPoint(x: cx - 1, y: -2))
        shaft.path = sh
        shaft.strokeColor = NSColor(white: 0.85, alpha: 1).cgColor
        shaft.fillColor = NSColor.clear.cgColor
        shaft.lineWidth = 2.2
    }

    /// A speech bubble over Puff for a few seconds (follows it around).
    func say(_ text: String) {
        bubbleText.string = text
        let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 22
        bubble.bounds = CGRect(x: 0, y: 0, width: w, height: 24)
        bubbleText.frame = CGRect(x: 0, y: 4, width: w, height: 16)
        bubbleText.contentsScale = window?.backingScaleFactor ?? 2
        bubble.opacity = 1
        bubble.transform = CATransform3DMakeScale(1, 1, 1)
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.4; pop.toValue = 1; pop.damping = 9; pop.duration = pop.settlingDuration
        bubble.add(pop, forKey: "pop")
        bubbleHide?.cancel()
        let w2 = DispatchWorkItem { [weak self] in self?.bubble.opacity = 0 }
        bubbleHide = w2
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: w2)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setTimer(nil) }
        let s = window?.backingScaleFactor ?? 2
        if s != sprites.scale { sprites.scale = s; sprites.clear() }
        puff.contentsScale = s
        ghosts.forEach { $0.contentsScale = s }
    }

    // Only Puff takes the mouse (a poke); everything else goes to the steps above.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return puff.frame.insetBy(dx: 6, dy: 6).contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downAt = convert(event.locationInWindow, from: nil)
        samples = []
    }

    /// Drag Puff to pick it up (it dangles), let go to throw it.
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let d = downAt else { return }
        if phase != .held {
            guard hypot(p.x - d.x, p.y - d.y) > 4, [.wander, .standing, .dance, .walking].contains(phase) else { return }
            set(.held)
            SoundFX.play(.boop)
        }
        heldAt = p
        samples.append((p, event.timestamp))
        if samples.count > 6 { samples.removeFirst() }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard phase == .held else {
            physics.poke()
            say(OnboardingLogic.pokeLines.randomElement() ?? "Boop!")
            return
        }
        let v = velocity()
        let (vx, vy) = TossLogic.clampVelocity(Double(v.dx), Double(v.dy))
        toss = TossState(x: Double(cx(x)), y: Double(max(restFloor, heldAt.y - size * 0.82)), vx: vx, vy: vy)
        tossTop = 0
        set(.thrown)
    }

    /// Pointer speed over the last few drag samples (points/s).
    private func velocity() -> CGVector {
        guard let a = samples.first, let b = samples.last, b.t > a.t else { return .zero }
        let dt = CGFloat(b.t - a.t)
        return CGVector(dx: (b.p.x - a.p.x) / dt, dy: (b.p.y - a.p.y) / dt)
    }

    /// x (0…1) for a point across the stage.
    private func frac(_ px: CGFloat) -> CGFloat { min(1, max(0, (px - size / 2 - 20) / max(1, bounds.width - size - 40))) }
    private var restFloor: CGFloat { mini ? landFloor : bandFloor }

    /// The first message was sent: Puff springs up out of the empty stage (once).
    func leave() {
        guard mini, phase != .leaving, phase != .gone, timer != nil || phase == .wander else { return }
        sparkles(at: CGPoint(x: cx(x), y: landFloor + size * 0.4))
        if Liveliness.current != .calm { SoundFX.play(.pop) }
        set(.leaving)
    }

    private var dropTop: CGFloat { mini ? bounds.height + 150 : bounds.height + 10 }

    /// A camera punch-in on impact: the stage scales up a touch around its centre and back.
    private func punchIn() {
        guard mini, let l = layer else { return }
        let c = CGPoint(x: bounds.midX, y: landFloor + size * 0.4)
        func m(_ k: CGFloat) -> NSValue {
            var tr = CATransform3DMakeTranslation(c.x, c.y, 0)
            tr = CATransform3DScale(tr, k, k, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(tr, -c.x, -c.y, 0))
        }
        let a = CAKeyframeAnimation(keyPath: "sublayerTransform")
        a.values = [m(1), m(1.13), m(1.05), m(1)]
        a.keyTimes = [0, 0.18, 0.55, 1]
        a.duration = 0.55
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                             CAMediaTimingFunction(name: .easeInEaseOut)]
        l.add(a, forKey: "punch")
    }

    /// One-shot effects for the hero entrances.
    private func fire(_ cue: EntranceCue, at p: CGPoint) {
        switch cue {
        case .charge: portal()
        case .impact: impact(at: p)
        case .fireImpact: fireImpact(at: p)
        case .electricImpact: electricImpact(at: p)
        case .smallImpact: smallImpact(at: p)
        case .bolt: bolt(to: p)
        case .materialize: materialize(at: p)
        case .dust: softLanding(at: p)
        case .sparkles: sparkles(at: CGPoint(x: p.x, y: p.y + size * 0.6))
        }
    }

    private func burst(_ root: CALayer, at p: CGPoint, count: Int, colors: [NSColor], spread: ClosedRange<CGFloat>,
                       rise: ClosedRange<CGFloat>, size sz: ClosedRange<CGFloat>, duration: ClosedRange<Double>, gravity: Bool) {
        for i in 0..<count {
            let d = CALayer()
            let r = CGFloat.random(in: sz)
            d.bounds = CGRect(x: 0, y: 0, width: r, height: r)
            d.cornerRadius = r / 2
            d.backgroundColor = colors[i % colors.count].cgColor
            d.position = p
            d.zPosition = 5
            root.addSublayer(d)
            let side: CGFloat = i % 2 == 0 ? 1 : -1
            let to = CGPoint(x: p.x + side * CGFloat.random(in: spread), y: p.y + (gravity ? -CGFloat.random(in: 0...8) : CGFloat.random(in: rise)))
            let path = CGMutablePath()
            path.move(to: p)
            path.addQuadCurve(to: to, control: CGPoint(x: (p.x + to.x) / 2, y: p.y + CGFloat.random(in: rise)))
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.6, 1]
            let g = CAAnimationGroup()
            g.animations = [move, fade]
            g.duration = Double.random(in: duration)
            g.fillMode = .forwards; g.isRemovedOnCompletion = false
            d.opacity = 0
            d.add(g, forKey: "burst")
            DispatchQueue.main.asyncAfter(deadline: .now() + duration.upperBound + 0.1) { d.removeFromSuperlayer() }
        }
    }

    private func ringWave(_ root: CALayer, at p: CGPoint, color: NSColor, width: CGFloat, delay: Double, duration: Double = 0.6) {
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -150, y: -22, width: 300, height: 44), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = width
        ring.shadowColor = color.cgColor; ring.shadowRadius = 5; ring.shadowOpacity = 0.9; ring.shadowOffset = .zero
        ring.position = p
        animate(ring, in: root, duration: duration, delay: delay, scale: (0.1, 1.2), opacity: (1, 0))
    }

    /// Meteor: a scorched crater, a ring of fire, embers flung up, smoke rolling away.
    private func fireImpact(at p: CGPoint) {
        SoundFX.play(.pop)
        director?.onImpact?()
        punchIn()
        guard let root = layer else { return }
        let crater = CAGradientLayer()
        crater.type = .radial
        crater.colors = [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.systemOrange.withAlphaComponent(0.25).cgColor, NSColor.clear.cgColor]
        crater.startPoint = CGPoint(x: 0.5, y: 0.5); crater.endPoint = CGPoint(x: 1, y: 1)
        crater.bounds = CGRect(x: 0, y: 0, width: 170, height: 34)
        crater.position = CGPoint(x: p.x, y: p.y + 2)
        crater.zPosition = -2
        animate(crater, in: root, duration: 1.8, scale: (0.4, 1), opacity: (1, 0))
        let blast = CAGradientLayer()
        blast.type = .radial
        blast.colors = [NSColor.white.cgColor, NSColor.systemYellow.withAlphaComponent(0.9).cgColor,
                        NSColor.systemOrange.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        blast.startPoint = CGPoint(x: 0.5, y: 0.5); blast.endPoint = CGPoint(x: 1, y: 1)
        blast.bounds = CGRect(x: 0, y: 0, width: 280, height: 160)
        blast.position = CGPoint(x: p.x, y: p.y + 24)
        animate(blast, in: root, duration: 0.5, scale: (0.2, 1.3), opacity: (1, 0))
        ringWave(root, at: p, color: .systemOrange, width: 3.5, delay: 0)
        ringWave(root, at: p, color: .systemYellow, width: 2, delay: 0.1)
        burst(root, at: p, count: 22, colors: [.systemYellow, .systemOrange, .systemRed, .white], spread: 30...170, rise: 50...150,
              size: 2.5...5.5, duration: 0.6...1.1, gravity: true)
        for k in 0..<5 {                                             // smoke rolling up and away
            let puffL = CAGradientLayer()
            puffL.type = .radial
            puffL.colors = [NSColor(white: 0.55, alpha: 0.35).cgColor, NSColor.clear.cgColor]
            puffL.startPoint = CGPoint(x: 0.5, y: 0.5); puffL.endPoint = CGPoint(x: 1, y: 1)
            puffL.bounds = CGRect(x: 0, y: 0, width: 80, height: 60)
            let side: CGFloat = k % 2 == 0 ? 1 : -1
            puffL.position = CGPoint(x: p.x + side * CGFloat(20 + k * 22), y: p.y + 18)
            root.addSublayer(puffL)
            puffL.opacity = 0
            let up = CABasicAnimation(keyPath: "position.y")
            up.fromValue = p.y + 18; up.toValue = p.y + 18 + CGFloat.random(in: 40...90)
            let sc = CABasicAnimation(keyPath: "transform.scale")
            sc.fromValue = 0.4; sc.toValue = 1.8
            let f = CAKeyframeAnimation(keyPath: "opacity")
            f.values = [0, 1, 0]; f.keyTimes = [0, 0.2, 1]
            let g = CAAnimationGroup()
            g.animations = [up, sc, f]
            g.duration = 1.6
            g.beginTime = CACurrentMediaTime() + Double(k) * 0.05
            g.fillMode = .both; g.isRemovedOnCompletion = false
            puffL.add(g, forKey: "smoke")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { puffL.removeFromSuperlayer() }
        }
    }

    /// Lightning: cyan shockwaves and crackling sparks around the landing.
    private func electricImpact(at p: CGPoint) {
        SoundFX.play(.pop)
        director?.onImpact?()
        punchIn()
        guard let root = layer else { return }
        let cyan = NSColor(red: 0.55, green: 0.9, blue: 1, alpha: 1)
        ringWave(root, at: p, color: cyan, width: 3, delay: 0)
        ringWave(root, at: p, color: .white, width: 1.5, delay: 0.08)
        burst(root, at: p, count: 16, colors: [cyan, .white], spread: 20...140, rise: 20...110, size: 2...4, duration: 0.4...0.8, gravity: false)
        for i in 0..<6 {                                              // little zig-zag crackles around Puff
            let z = CAShapeLayer()
            let a = Double(i) / 6 * 2 * .pi
            let c = CGPoint(x: p.x + CGFloat(cos(a)) * size * 0.7, y: p.y + size * 0.45 + CGFloat(sin(a)) * size * 0.55)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: c.x - 8, y: c.y + 6))
            path.addLine(to: CGPoint(x: c.x - 2, y: c.y + 1)); path.addLine(to: CGPoint(x: c.x + 1, y: c.y + 5)); path.addLine(to: CGPoint(x: c.x + 8, y: c.y - 6))
            z.path = path
            z.strokeColor = cyan.cgColor; z.fillColor = NSColor.clear.cgColor; z.lineWidth = 1.8; z.lineJoin = .round
            z.shadowColor = cyan.cgColor; z.shadowRadius = 3; z.shadowOpacity = 1; z.shadowOffset = .zero
            animate(z, in: root, duration: 0.35, delay: Double(i % 3) * 0.12 + 0.05, scale: (0.6, 1.2), opacity: (1, 0))
        }
    }

    /// A lightning bolt from above the stage down to Puff, flickering.
    private func bolt(to p: CGPoint) {
        guard let root = layer else { return }
        director?.onImpact?()
        let b = CAShapeLayer()
        let path = CGMutablePath()
        var q = CGPoint(x: p.x + CGFloat.random(in: -30...30), y: bounds.height + 320)
        path.move(to: q)
        let steps = 9
        for k in 1...steps {
            let y = q.y - (bounds.height + 320 - p.y) / CGFloat(steps)
            let x = k == steps ? p.x : p.x + CGFloat.random(in: -26...26) * CGFloat(steps - k) / CGFloat(steps)
            q = CGPoint(x: x, y: y)
            path.addLine(to: q)
        }
        b.path = path
        b.strokeColor = NSColor.white.cgColor
        b.fillColor = NSColor.clear.cgColor
        b.lineWidth = 3.5
        b.lineJoin = .miter
        b.shadowColor = NSColor(red: 0.55, green: 0.9, blue: 1, alpha: 1).cgColor
        b.shadowRadius = 9; b.shadowOpacity = 1; b.shadowOffset = .zero
        b.zPosition = 25
        root.addSublayer(b)
        let f = CAKeyframeAnimation(keyPath: "opacity")
        f.values = [1, 0.2, 1, 0.3, 1, 0]
        f.keyTimes = [0, 0.15, 0.3, 0.45, 0.6, 1]
        f.duration = 0.32
        f.fillMode = .forwards; f.isRemovedOnCompletion = false
        b.add(f, forKey: "flicker")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { b.removeFromSuperlayer() }
        SoundFX.play(.boop)
    }

    /// Teleport: a ring bursts out as Puff solidifies, sparkles fall in.
    private func materialize(at p: CGPoint) {
        SoundFX.play(.yay)
        director?.onImpact?()
        punchIn()
        guard let root = layer else { return }
        ringWave(root, at: CGPoint(x: p.x, y: p.y + 2), color: NSColor(Theme.glow[0]), width: 3, delay: 0)
        ringWave(root, at: CGPoint(x: p.x, y: p.y + size * 0.5), color: NSColor(Theme.glow[1]), width: 2, delay: 0.06, duration: 0.5)
        burst(root, at: CGPoint(x: p.x, y: p.y + size * 0.5), count: 18, colors: [NSColor(Theme.glow[0]), .white, NSColor(Theme.glow[2])],
              spread: 30...120, rise: -40...80, size: 2...4, duration: 0.5...0.9, gravity: false)
    }

    /// Jetpack touchdown / small landings: a shockwave and a dust ring.
    private func smallImpact(at p: CGPoint) {
        SoundFX.play(.pop)
        director?.onImpact?()
        punchIn()
        guard let root = layer else { return }
        ringWave(root, at: p, color: NSColor(Theme.glow[0]), width: 2.5, delay: 0)
        softLanding(at: p)
        burst(root, at: p, count: 12, colors: [NSColor.white.withAlphaComponent(0.6), NSColor(Theme.glow[2])], spread: 30...130,
              rise: 10...50, size: 3...7, duration: 0.45...0.8, gravity: false)
    }

    /// A light touchdown for the non-slam entrances: two dust puffs and a pop.
    private func softLanding(at p: CGPoint) {
        guard let root = layer else { return }
        if entrance != .soft { SoundFX.play(.pop) }
        for side in [-1.0, 1.0] {
            let cloud = CAGradientLayer()
            cloud.type = .radial
            cloud.colors = [NSColor.white.withAlphaComponent(0.2).cgColor, NSColor.clear.cgColor]
            cloud.startPoint = CGPoint(x: 0.5, y: 0.5); cloud.endPoint = CGPoint(x: 1, y: 1)
            cloud.bounds = CGRect(x: 0, y: 0, width: 70, height: 40)
            cloud.position = CGPoint(x: p.x + CGFloat(side) * 34, y: p.y + 10)
            animate(cloud, in: root, duration: 0.9, scale: (0.3, 1.4), opacity: (entrance == .soft ? 0.5 : 1, 0))
        }
    }

    // MARK: geometry

    /// Feet height for the band at the top, and for the landing spot mid-panel.
    private var bandFloor: CGFloat { mini ? 6 : bounds.height - StageDirector.band + 8 }
    private var landFloor: CGFloat { mini ? 6 : bounds.height * 0.5 }

    /// On screen or not (the panel stays mounted while the notch is closed): the timer
    /// runs only while visible; the first time it shows, the mini stage lands.
    func setVisible(_ v: Bool) {
        if !v { setTimer(nil); return }
        if !everShown {
            everShown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.land(at: 0.5) }
        } else if phase != .waiting && timer == nil {
            set(phase == .landing || phase == .charge || phase == .standing ? .wander : phase)
        }
    }
    private func cx(_ x: CGFloat) -> CGFloat { size / 2 + 20 + (bounds.width - size - 40) * x }

    // MARK: commands

    func land(at spot: Double) {
        home = CGFloat(spot); target = home; x = 0.5
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // No crash-landing for people who asked for less motion: just appear and wave.
            x = home; set(.wander); begin(.wave)
            if mini { say(GreetingLogic.greeting(now: Date(), lastLanding: nil, roll: Double.random(in: 0..<1)).line) }
            director?.onStandUp?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.director?.onReady?() }
            return
        }
        landed = false
        if mini {
            let d = UserDefaults.standard
            let last = d.string(forKey: "puff.lastEntrance").flatMap(Entrance.init(rawValue:))
            entrance = EntranceLogic.pick(liveliness: Liveliness.current, reduceMotion: false, last: last, roll: Double.random(in: 0..<1))
            rollSide = Bool.random() ? 1 : -1
            greeting = GreetingLogic.greeting(now: Date(), lastLanding: d.object(forKey: "puff.lastLanding") as? Date,
                                             roll: Double.random(in: 0..<1))
            d.set(entrance.rawValue, forKey: "puff.lastEntrance")
            d.set(Date(), forKey: "puff.lastLanding")
            shapeUmbrella()
            if entrance == .bungee { rope.strokeColor = NSColor(Theme.glow[2]).cgColor }
            else { rope.strokeColor = NSColor(red: 0.86, green: 0.74, blue: 0.55, alpha: 1).cgColor }
            if entrance == .portal || entrance == .teleport { SoundFX.play(.peek) }
            if entrance == .slam {                            // the full superhero landing, charge-up first
                SoundFX.play(.peek)
                portal()
                set(.charge)
            } else {
                set(.entrance)
            }
            return
        }
        SoundFX.play(.peek)
        portal()
        set(.charge)
    }

    func walk(to spot: Double, excited: Bool) {
        home = CGFloat(spot); target = home
        fast = true
        walkSpeed = excited ? 190 : 150
        if phase == .toBand { return }                     // it'll head there once it's up
        if excited { physics.celebrate(sound: false) }
        set(.walking)
    }

    func cheer() { physics.celebrate(sound: false); begin(.wave) }

    func dance() { physics.celebrate(sound: false); set(.dance); confetti() }

    // MARK: loop

    private func set(_ p: Phase) {
        phase = p
        phaseStart = Date()
        sceneT = 0
        cueIndex = 0
        // Smooth motion while something big happens, the policy rate otherwise.
        if p == .gone { setTimer(nil); return }
        let busy = p == .charge || p == .landing || p == .standing || p == .toBand || p == .walking || p == .dance
            || p == .entrance || p == .held || p == .thrown || p == .leaving
        setTimer(busy ? 60 : AnimationPolicy.shared.fps)
    }

    private func setTimer(_ fps: Double?) {
        timer?.invalidate(); timer = nil
        guard let fps else { return }
        last = Date()
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func begin(_ a: PerchAction) {
        clip = a
        clipStart = Date()
        if a == .wave { physics.wave() }
        nextFidget = Date().addingTimeInterval(a.duration + Double.random(in: 1.2...3))
    }

    private func tick() {
        guard bounds.width > size * 2, bounds.height > (mini ? size : StageDirector.band) else { return }
        let now = Date()
        let dt = CGFloat(min(0.1, now.timeIntervalSince(last)))
        last = now
        var t = now.timeIntervalSince(phaseStart)
        if phase == .landing || phase == .entrance {
            // Scene time runs slow for a beat before the big moment (the "shot").
            sceneT += Double(dt) * EntranceLogic.timeScale(phase == .landing ? .slam : entrance, t: sceneT)
            t = sceneT
        }
        physics.step(now, doneAt: nil, dragging: false)

        var feet = bandFloor
        var extraSquash = 0.0
        var spriteClip = "idle"
        var mood = AvatarMood.happy
        var gaze = 0
        var trail = false
        var spin = 0.0, lean = 0.0
        var expression = physics.current
        var dxOff: CGFloat = 0, scaleK: CGFloat = 1, alpha: Float = 1
        var props = EntranceFrame()
        props.umbrella = 0

        switch phase {
        case .waiting, .gone:
            return
        case .entrance:
            let f = EntranceLogic.frame(entrance, t: t, drop: Double(dropTop - landFloor), size: Double(size),
                                        width: Double(bounds.width), side: rollSide)
            let cues = EntranceLogic.cues(entrance)
            while cueIndex < cues.count && t >= cues[cueIndex].at {
                fire(cues[cueIndex].cue, at: CGPoint(x: cx(x) + CGFloat(f.dx), y: landFloor))
                cueIndex += 1
            }
            feet = landFloor + CGFloat(f.feet)
            dxOff = CGFloat(f.dx); spin = f.spin; lean = f.lean; scaleK = CGFloat(f.scale); alpha = Float(f.opacity)
            extraSquash = f.squash; spriteClip = f.clip; trail = f.trail
            if let e = f.expression { expression = e }
            props = f
            if let td = EntranceLogic.touchdown(entrance), t >= td, !landed {
                landed = true
                if !entrance.isHero { softLanding(at: CGPoint(x: cx(x), y: landFloor)) }
            }
            if entrance == .portal && t >= 0.3 && !landed && phaseStart.addingTimeInterval(0.3) > now.addingTimeInterval(-dt) {
                sparkles(at: CGPoint(x: cx(x), y: landFloor + 20))
            }
            if t >= EntranceLogic.duration(entrance) {
                physics.celebrate(sound: false)
                if entrance != .soft { SoundFX.play(.yay) }
                if entrance.isHero { sparkles(at: CGPoint(x: cx(x), y: landFloor + size * 0.6)) }
                begin(.wave)
                director?.onStandUp?()
                set(.standing)
            }
        case .held:
            // Dangling from the pointer by its head.
            feet = max(landFloor, heldAt.y - size * 0.82)
            x = frac(heldAt.x)
            spriteClip = "stretch"; expression = .surprised
            let v = velocity()
            lean = max(-0.35, min(0.35, Double(v.dx) * 0.0004))
        case .thrown:
            let (n, hit) = TossLogic.step(toss, dt: Double(dt), minX: Double(cx(0)), maxX: Double(cx(1)), floor: Double(restFloor),
                                          ceiling: Double(bounds.height - size * 0.3), radius: Double(size) * 0.45)
            toss = n
            tossTop = max(tossTop, (n.vx * n.vx + n.vy * n.vy).squareRoot())
            if let speed = hit, speed > 220 {
                bounceAt = now; bounceAmount = min(0.32, speed / 2600)
                SoundFX.play(.pop)
            }
            feet = CGFloat(n.y); x = frac(CGFloat(n.x))
            spriteClip = n.y > Double(restFloor) + 2 ? "stretch" : "idle"
            if TossLogic.settled(n, floor: Double(restFloor)) {
                // Turn upright, then carry on.
                let upright = (toss.spin / (2 * .pi)).rounded() * 2 * .pi
                toss.spin += (upright - toss.spin) * min(1, Double(dt) * 14)
                if abs(upright - toss.spin) < 0.03 {
                    toss.spin = 0
                    if tossTop > 1000 {
                        exprOverride = .dizzy; exprUntil = now.addingTimeInterval(1.4)
                        say(["Wheee! 😵‍💫", "Again! 😆", "Whoa! 🤪"].randomElement() ?? "Wheee!")
                    } else {
                        say(["Hehe 😆", "Again? 🙈", "Boop!"].randomElement() ?? "Hehe")
                    }
                    home = x; target = x
                    if mini { set(.wander) } else { target = CGFloat(OnboardingLogic.spot(0)); home = target; fast = false; set(.walking) }
                }
            }
            spin = toss.spin
        case .leaving:
            // Hands off to the first message: crouch, then spring up out of the stage.
            if t < 0.12 {
                feet = landFloor; extraSquash = 0.25 * t / 0.12; spriteClip = "idle"
            } else {
                let q = min(1, (t - 0.12) / 0.45)
                feet = landFloor + CGFloat(q * q) * (bounds.height + 90)
                scaleK = 1 - 0.45 * CGFloat(q)
                alpha = Float(1 - max(0, (q - 0.55) / 0.45))
                spriteClip = "stretch"; trail = true; expression = .celebrate
                if q >= 1 { set(.gone); puff.opacity = 0; ghosts.forEach { $0.opacity = 0 }; return }
            }
        case .charge:
            // The notch glows and drips sparks; Puff is still inside.
            if t >= OnboardingLogic.chargeTime { set(.landing) }
            return
        case .landing:
            let f = OnboardingLogic.fall(t)
            feet = dropTop + (landFloor - dropTop) * CGFloat(f)
            let heroEnd = OnboardingLogic.fallTime + 0.85
            extraSquash = OnboardingLogic.impactSquash(t)
            if t < OnboardingLogic.fallTime {
                spriteClip = "stretch"                       // arms up, flipping as it dives
                spin = OnboardingLogic.spin(t)
                trail = true
            } else if t < OnboardingLogic.fallTime + 0.08 {
                spriteClip = "kick"                          // the slam
            } else {
                // Superhero landing: fist down, knee up, leaning in, determined face.
                spriteClip = "hero"; expression = .heroic; mood = .idle
                lean = 0.16 * min(1, (t - OnboardingLogic.fallTime) / 0.15)
            }
            if t >= OnboardingLogic.fallTime && !landed {
                landed = true
                impact(at: CGPoint(x: cx(x), y: landFloor))
            }
            if t > heroEnd {
                physics.celebrate(sound: false)
                SoundFX.play(.yay)
                begin(.wave)
                sparkles(at: CGPoint(x: cx(x), y: landFloor + size * 0.6))
                director?.onStandUp?()
                set(.standing)
            }
        case .standing:
            feet = landFloor
            spriteClip = clip == .wave ? "wave" : "idle"
            if mini && t > 1.0 {
                home = x; target = x
                set(.wander)
                say(greeting.line)
                if greeting.first != .wave { begin(greeting.first) }
                if let e = greeting.expression { exprOverride = e; exprUntil = Date().addingTimeInterval(1.6) }
                if greeting.party && Liveliness.current != .calm {
                    physics.celebrate(sound: false)
                    sparkles(at: CGPoint(x: cx(x), y: landFloor + size * 0.6))
                }
            } else if !mini && t > 1.9 {
                hopFrom = (x, landFloor)
                director?.onReady?()
                SoundFX.play(.pop)
                set(.toBand)
            }
        case .toBand:
            // One big arc up into the band, drifting toward the first spot.
            let p = min(1, t / 0.6)
            let e = p * p * (3 - 2 * p)
            x = hopFrom.x + (target - hopFrom.x) * CGFloat(e) * 0.35
            feet = hopFrom.y + (bandFloor - hopFrom.y) * CGFloat(e) + CGFloat(sin(p * .pi)) * 70
            spriteClip = "stretch"
            if p >= 1 { physics.celebrate(sound: false); set(.walking) }
        case .walking:
            let d = target - x
            dir = d >= 0 ? 1 : -1
            let step = dir * walkSpeed * dt / max(1, bounds.width - size - 40)
            if abs(d) <= abs(step) {
                x = target
                begin(fast ? .wave : .lookAround)
                fast = false
                set(.wander)
            } else {
                x += step
            }
            spriteClip = "walk"; gaze = Int(dir)
        case .wander:
            // Pottering around its spot: little strolls, waves, looks, kicks.
            if clip == .walk {
                x += dir * 34 * dt / max(1, bounds.width - size - 40)
                if x > home + 0.1 { dir = -1 } else if x < home - 0.1 { dir = 1 }
                x = min(1, max(0, x))
                spriteClip = "walk"; gaze = Int(dir)
            } else if clip != .idle && now.timeIntervalSince(clipStart) < clip.duration {
                spriteClip = clip.rawValue
            }
            mood = clip == .wave ? .happy : .idle
            if now >= nextFidget {
                let bag: [PerchAction] = mini ? [.wave, .lookAround, .kick, .stretch, .hop, .idle, .idle]
                    : [.walk, .walk, .wave, .lookAround, .kick, .stretch, .hop, .idle]
                let a = bag.randomElement() ?? .idle
                if a == .walk && Bool.random() { dir = -dir }
                if a == .hop { physics.celebrate(sound: false) }
                begin(a)
                if a == .walk || a == .idle { nextFidget = now.addingTimeInterval(Double.random(in: 1.5...3.5)) }
            }
        case .dance:
            spriteClip = "dance"
        }

        // Plays with you: eyes follow the pointer, types along while you type (the chat's empty stage).
        if (phase == .wander || phase == .standing) && gaze == 0 && (spriteClip == "idle" || spriteClip == "wave") {
            if let w = window {
                let m = convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                gaze = GazeLogic.toward(dx: Double(m.x - cx(x)))
            }
            if mini && phase == .wander && spriteClip == "idle"
                && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 0.7 {
                spriteClip = "typing"; gaze = 0
            }
        }
        if now < exprUntil, let e = exprOverride { expression = e }
        extraSquash += EntranceLogic.wobble(now.timeIntervalSince(bounceAt), amount: bounceAmount)

        // Pick the frame.
        let clock = now.timeIntervalSinceReferenceDate
        var key = PerchSprites.Key(clip: spriteClip, frame: 0, gazeX: gaze, blink: false, mood: mood,
                                   expression: expression, palette: UserDefaults.standard.string(forKey: "avatarPalette") ?? "aurora")
        switch spriteClip {
        case "idle":
            key.frame = Int(clock * PerchSprites.fps) % 48
            key.blink = clock.truncatingRemainder(dividingBy: 3.8) > 3.62
            if key.blink { key.frame = 0 }
        case "walk", "dance", "typing":
            key.frame = Int(clock * PerchSprites.fps) % PerchSprites.frames(spriteClip)
        case "stretch":
            key.frame = PerchSprites.frames("stretch") / 2   // arms all the way up
        case "kick", "hero":
            key.frame = 0
        default:
            let n = PerchSprites.frames(spriteClip)
            let p = min(1, now.timeIntervalSince(clipStart) / max(0.1, clip.duration))
            key.frame = min(n - 1, Int(p * Double(n - 1)))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let img = sprites.image(key, size: size)
        if let img { puff.contents = img }
        puff.opacity = alpha
        puff.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let px = cx(x) + dxOff
        let lift = CGFloat(physics.hop) * size * 0.5
        puff.position = CGPoint(x: px, y: feet + lift - size * 0.08)
        let sq = CGFloat(physics.squash + extraSquash)
        var tr = CATransform3DMakeRotation(-CGFloat(physics.sway + lean) + CGFloat(spin), 0, 0, 1)
        tr = CATransform3DScale(tr, (1 + sq * 0.8) * scaleK, (1 - sq) * scaleK, 1)
        if spin != 0 {
            // Flip around the middle of the body, not the feet.
            tr = CATransform3DTranslate(CATransform3DIdentity, 0, size * 0.45, 0)
            tr = CATransform3DRotate(tr, CGFloat(spin), 0, 0, 1)
            tr = CATransform3DTranslate(tr, 0, -size * 0.45, 0)
            tr = CATransform3DScale(tr, (1 + sq * 0.8) * scaleK, (1 - sq) * scaleK, 1)
        }
        puff.transform = tr
        // Entrance props.
        let hands = puff.position.y + size * 0.9
        umbrella.opacity = props.umbrella > 0.02 ? 1 : 0
        if props.umbrella > 0.02 {
            umbrella.position = CGPoint(x: px, y: hands - 6)
            umbrella.transform = CATransform3DScale(CATransform3DMakeRotation(-CGFloat(lean) * 1.4, 0, 0, 1),
                                                    CGFloat(0.12 + 0.88 * props.umbrella), 1, 1)
        }
        if let end = props.ropeEnd {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: px, y: bounds.height + 60))
            path.addLine(to: CGPoint(x: px, y: landFloor + CGFloat(end)))
            rope.path = path
            rope.opacity = 1
        } else {
            rope.opacity = 0
        }
        // Flame: under the feet for the jetpack, a blazing aura around a meteor.
        flame.opacity = Float(props.flame)
        if props.flame > 0.01 {
            let fl = entrance == .meteor ? size * 1.5 : size * 0.55
            let flick = 1 + 0.12 * CGFloat(sin(now.timeIntervalSinceReferenceDate * 47))
            flame.bounds = CGRect(x: 0, y: 0, width: fl * (entrance == .meteor ? 1 : 0.7), height: fl * flick)
            flame.position = entrance == .meteor ? CGPoint(x: px, y: puff.position.y + size * 0.5)
                : CGPoint(x: px, y: puff.position.y - fl * 0.35)
        }
        beamLayer.opacity = Float(props.beam)
        if props.beam > 0.01 {
            beamLayer.bounds = CGRect(x: 0, y: 0, width: size * 1.1, height: bounds.height + 400)
            beamLayer.position = CGPoint(x: px, y: landFloor + (bounds.height + 400) / 2 - 4)
        }
        darkLayer.opacity = Float(props.dark * 0.6)
        if props.dark > 0.01 { darkLayer.frame = bounds.insetBy(dx: -400, dy: -300) }
        ring.opacity = props.ring > 0.01 ? 1 : 0
        if props.ring > 0.01 {
            ring.path = CGPath(ellipseIn: CGRect(x: -size * 0.65, y: -8, width: size * 1.3, height: 16), transform: nil)
            ring.position = CGPoint(x: px, y: landFloor + 2)
            ring.transform = CATransform3DMakeScale(CGFloat(props.ring), CGFloat(props.ring), 1)
        }
        for (i, l) in speedLines.enumerated() {
            let off = CGFloat(i - 2) * size * 0.2
            let len = size * (1.1 + 0.35 * CGFloat(i % 3))
            l.bounds = CGRect(x: 0, y: 0, width: i == 2 ? 2.5 : 1.5, height: len)
            l.position = CGPoint(x: px + off, y: puff.position.y + size + len / 2 - 6)
            l.opacity = trail ? 0.85 : 0
        }
        // Speed trail while falling.
        for (i, g) in ghosts.enumerated() {
            g.contents = img
            g.bounds = puff.bounds
            g.transform = tr
            g.position = CGPoint(x: px, y: puff.position.y + CGFloat(i + 1) * 26)
            g.opacity = trail ? Float(0.32 - Double(i) * 0.14) : 0
        }
        // Ground groundShadow: smaller and fainter the higher it is above the floor it's over.
        let floor = phase == .landing || phase == .standing || phase == .entrance || phase == .leaving ? landFloor
            : (phase == .toBand ? min(feet, bandFloor) : (phase == .held || phase == .thrown ? restFloor : bandFloor))
        let height = max(0, feet + lift - floor)
        let k = max(0.25, 1 - height / 160)
        groundShadow.bounds = CGRect(x: 0, y: 0, width: size * 0.62 * k * (1 + max(0, sq) * 0.6), height: 7 * k)
        groundShadow.cornerRadius = 3.5 * k
        groundShadow.position = CGPoint(x: px, y: floor + 1)
        groundShadow.opacity = Float(0.9 * k) * alpha
        // Bubble beside the head, on the side facing the middle (above would run under the header).
        let bw = bubble.bounds.width / 2
        let side: CGFloat = px < bounds.width / 2 ? 1 : -1
        let bx = px + side * (size * 0.5 + bw + 6)
        bubble.position = CGPoint(x: min(bounds.width - bw - 6, max(bw + 6, bx)), y: puff.position.y + size * 0.62)
        CATransaction.commit()
    }

    // MARK: confetti

    /// Paper bits bursting up from Puff and fluttering down across the panel.
    private func confetti() {
        guard let root = layer else { return }
        let colors = [NSColor(Theme.glow[0]), NSColor(Theme.glow[1]), NSColor(Theme.glow[2]), .systemYellow, .systemPink, .white]
        let from = CGPoint(x: cx(x), y: bandFloor + size * 0.6)
        for i in 0..<44 {
            let c = CALayer()
            c.bounds = CGRect(x: 0, y: 0, width: CGFloat.random(in: 5...9), height: CGFloat.random(in: 3...6))
            c.backgroundColor = colors[i % colors.count].cgColor
            c.position = from
            c.zPosition = 20
            root.addSublayer(c)
            let peak = CGPoint(x: from.x + CGFloat.random(in: -260...260), y: from.y + CGFloat.random(in: 20...110))
            let land = CGPoint(x: peak.x + CGFloat.random(in: -40...40), y: CGFloat.random(in: -20...bounds.height * 0.4))
            let path = CGMutablePath()
            path.move(to: from)
            path.addQuadCurve(to: land, control: CGPoint(x: peak.x, y: peak.y + 80))
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.timingFunctions = [CAMediaTimingFunction(name: .easeOut)]
            let spin = CABasicAnimation(keyPath: "transform.rotation")
            spin.fromValue = 0; spin.toValue = CGFloat.random(in: -14...14)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.7, 1]
            let g = CAAnimationGroup()
            g.animations = [move, spin, fade]
            g.duration = Double.random(in: 1.1...1.7)
            g.fillMode = .forwards; g.isRemovedOnCompletion = false
            c.opacity = 0
            c.add(g, forKey: "confetti")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { c.removeFromSuperlayer() }
        }
    }

    // MARK: the slam

    private var glowColors: [NSColor] { [NSColor(Theme.glow[0]), NSColor(Theme.glow[1]), NSColor(Theme.glow[2])] }

    /// The charge-up: the notch at the top glows brighter and brighter and drips sparks.
    private func portal() {
        guard let root = layer else { return }
        let glow = glowColors
        let top = CGPoint(x: cx(0.5), y: bounds.height)
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [glow[0].withAlphaComponent(0.95).cgColor, glow[1].withAlphaComponent(0.35).cgColor, NSColor.clear.cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
        g.bounds = CGRect(x: 0, y: 0, width: 260, height: 90)
        g.position = top
        root.addSublayer(g)
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = [0.2, 0.7, 0.55, 1.0, 0.8, 1.35, 0.4]
        grow.keyTimes = [0, 0.25, 0.4, 0.62, 0.75, 0.93, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.8, 0.6, 1, 0.8, 1, 0]
        fade.keyTimes = grow.keyTimes
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = OnboardingLogic.chargeTime + 0.25
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        g.opacity = 0
        g.add(group, forKey: "charge")
        DispatchQueue.main.asyncAfter(deadline: .now() + group.duration + 0.1) { g.removeFromSuperlayer() }
        // Sparks dripping out of the notch.
        for i in 0..<12 {
            let d = CALayer()
            let r = CGFloat.random(in: 2...3.5)
            d.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            d.cornerRadius = r
            d.backgroundColor = (i % 2 == 0 ? glow[0] : NSColor.white).cgColor
            let from = CGPoint(x: top.x + CGFloat.random(in: -70...70), y: top.y - 4)
            d.position = from
            root.addSublayer(d)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: from)
            move.toValue = NSValue(point: CGPoint(x: from.x + CGFloat.random(in: -10...10), y: from.y - CGFloat.random(in: 40...120)))
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = 1; f.toValue = 0
            let gr = CAAnimationGroup()
            gr.animations = [move, f]
            gr.duration = 0.55
            gr.beginTime = CACurrentMediaTime() + Double(i) * 0.05
            gr.fillMode = .both; gr.isRemovedOnCompletion = false
            d.opacity = 0
            d.add(gr, forKey: "drip")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { d.removeFromSuperlayer() }
        }
    }

    /// Standing up from the landing: a ring of sparkles flies out.
    private func sparkles(at c: CGPoint) {
        guard let root = layer else { return }
        let glow = glowColors
        for i in 0..<10 {
            let st = CATextLayer()
            st.string = i % 3 == 0 ? "★" : "✦"
            st.fontSize = CGFloat.random(in: 11...18)
            st.alignmentMode = .center
            st.foregroundColor = (i % 2 == 0 ? glow[0] : NSColor.systemYellow).cgColor
            st.contentsScale = window?.backingScaleFactor ?? 2
            st.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
            st.position = c
            root.addSublayer(st)
            let a = Double(i) / 10 * 2 * .pi
            let to = CGPoint(x: c.x + CGFloat(cos(a)) * 95, y: c.y + CGFloat(sin(a)) * 60)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: c); move.toValue = NSValue(point: to)
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let sp = CABasicAnimation(keyPath: "transform.rotation")
            sp.fromValue = 0; sp.toValue = CGFloat.random(in: -3...3)
            let f = CAKeyframeAnimation(keyPath: "opacity")
            f.values = [0, 1, 1, 0]; f.keyTimes = [0, 0.1, 0.6, 1]
            let g = CAAnimationGroup()
            g.animations = [move, sp, f]
            g.duration = 0.8
            g.fillMode = .forwards; g.isRemovedOnCompletion = false
            st.opacity = 0
            st.add(g, forKey: "spark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { st.removeFromSuperlayer() }
        }
    }

    private func impact(at p: CGPoint) {
        SoundFX.play(.pop)
        director?.onImpact?()
        punchIn()
        guard let root = layer else { return }
        let glow = glowColors

        do {
        if !mini {
            // Impact frame: the whole stage flashes white for a blink (the chat flashes its whole page instead).
            let white = CALayer()
            white.backgroundColor = NSColor.white.cgColor
            white.frame = bounds
            white.zPosition = 30
            animate(white, in: root, duration: 0.18, scale: (1, 1), opacity: (0.45, 0))
        }

        // Ground cracks: glowing jagged lines racing out along the floor, fading slowly.
        let cracks = CAShapeLayer()
        let path = CGMutablePath()
        for i in 0..<7 {
            let side: CGFloat = i % 2 == 0 ? 1 : -1
            var q = CGPoint(x: p.x + side * 6, y: p.y)
            path.move(to: q)
            let reach = CGFloat.random(in: 50...150)
            let slope = CGFloat.random(in: -0.22...0.22)
            for k in 1...5 {
                let dx = side * reach * CGFloat(k) / 5
                q = CGPoint(x: p.x + dx, y: p.y + dx * slope * side + CGFloat.random(in: -5...5))
                path.addLine(to: q)
            }
        }
        cracks.path = path
        cracks.fillColor = NSColor.clear.cgColor
        cracks.strokeColor = glow[0].mix(with: .white, 0.4).cgColor
        cracks.lineWidth = 1.6
        cracks.lineJoin = .round
        cracks.shadowColor = glow[0].cgColor; cracks.shadowRadius = 4; cracks.shadowOpacity = 0.9; cracks.shadowOffset = .zero
        cracks.zPosition = -2
        root.addSublayer(cracks)
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0; draw.toValue = 1; draw.duration = 0.14
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fadeC = CABasicAnimation(keyPath: "opacity")
        fadeC.fromValue = 1; fadeC.toValue = 0
        fadeC.beginTime = 0.9; fadeC.duration = 0.9
        let gc = CAAnimationGroup()
        gc.animations = [draw, fadeC]; gc.duration = 1.8
        gc.fillMode = .forwards; gc.isRemovedOnCompletion = false
        cracks.add(gc, forKey: "cracks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { cracks.removeFromSuperlayer() }

        }
        // Soft dust clouds that billow and hang a moment.
        for side in [-1.0, 1.0] {
            for k in 0..<2 {
                let cloud = CAGradientLayer()
                cloud.type = .radial
                cloud.colors = [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.clear.cgColor]
                cloud.startPoint = CGPoint(x: 0.5, y: 0.5); cloud.endPoint = CGPoint(x: 1, y: 1)
                cloud.bounds = CGRect(x: 0, y: 0, width: 90, height: 60)
                cloud.position = CGPoint(x: p.x + CGFloat(side) * CGFloat(40 + k * 45), y: p.y + 14 + CGFloat(k) * 6)
                animate(cloud, in: root, duration: 1.3, delay: Double(k) * 0.06, scale: (0.3, 1.6), opacity: (1, 0))
            }
        }

        // Rocks and bits flung up, falling back with gravity.
        for i in 0..<10 {
            let r = CALayer()
            let sz = CGFloat.random(in: 3...6)
            r.bounds = CGRect(x: 0, y: 0, width: sz, height: sz)
            r.cornerRadius = 1
            r.backgroundColor = (i % 3 == 0 ? glow[1] : NSColor(white: 0.75, alpha: 1)).cgColor
            r.position = p
            root.addSublayer(r)
            let side: CGFloat = i % 2 == 0 ? 1 : -1
            let land = CGPoint(x: p.x + side * CGFloat.random(in: 40...170), y: p.y - CGFloat.random(in: 0...10))
            let arc = CGMutablePath()
            arc.move(to: p)
            arc.addQuadCurve(to: land, control: CGPoint(x: (p.x + land.x) / 2, y: p.y + CGFloat.random(in: 60...140)))
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = arc
            move.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.6, 1)]
            let spin = CABasicAnimation(keyPath: "transform.rotation")
            spin.toValue = CGFloat.random(in: -10...10)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.75, 1]
            let g = CAAnimationGroup()
            g.animations = [move, spin, fade]
            g.duration = Double.random(in: 0.6...0.95)
            g.fillMode = .forwards; g.isRemovedOnCompletion = false
            r.opacity = 0
            r.add(g, forKey: "rock")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { r.removeFromSuperlayer() }
        }

        // Power-up aura during the hold: rings rising up around Puff.
        for i in 0..<3 {
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -48, y: -9, width: 96, height: 18), transform: nil)
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = glow[i % 3].withAlphaComponent(0.9).cgColor
            ring.lineWidth = 2
            ring.position = CGPoint(x: p.x, y: p.y + 4)
            ring.opacity = 0
            root.addSublayer(ring)
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = p.y + 4; rise.toValue = p.y + size * 1.05
            let sc = CABasicAnimation(keyPath: "transform.scale")
            sc.fromValue = 1.1; sc.toValue = 0.55
            let f = CAKeyframeAnimation(keyPath: "opacity")
            f.values = [0, 1, 0]; f.keyTimes = [0, 0.3, 1]
            let g = CAAnimationGroup()
            g.animations = [rise, sc, f]
            g.duration = 0.6
            g.beginTime = CACurrentMediaTime() + 0.2 + Double(i) * 0.17
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.fillMode = .both; g.isRemovedOnCompletion = false
            ring.add(g, forKey: "aura")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ring.removeFromSuperlayer() }
        }

        // Flash: a radial burst of light from the impact point.
        let flash = CAGradientLayer()
        flash.type = .radial
        flash.colors = [glow[1].withAlphaComponent(0.85).cgColor, glow[0].withAlphaComponent(0.25).cgColor, NSColor.clear.cgColor]
        flash.startPoint = CGPoint(x: 0.5, y: 0.5); flash.endPoint = CGPoint(x: 1, y: 1)
        flash.bounds = CGRect(x: 0, y: 0, width: 300, height: 170)
        flash.position = CGPoint(x: p.x, y: p.y + 20)
        flash.zPosition = -5
        animate(flash, in: root, duration: 0.5, scale: (0.3, 1.25), opacity: (1, 0))

        // Two shockwave rings racing out along the floor.
        for (i, c) in [glow[0], glow[2]].enumerated() {
            let ring = CAShapeLayer()
            let r = CGRect(x: -150, y: -24, width: 300, height: 48)
            ring.path = CGPath(ellipseIn: r, transform: nil)
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = c.cgColor
            ring.lineWidth = i == 0 ? 3 : 2
            ring.position = p
            animate(ring, in: root, duration: 0.65, delay: Double(i) * 0.09, scale: (0.12, 1.15), opacity: (1, 0))
        }

        // Dust and sparks kicked up on both sides.
        for i in 0..<14 {
            let d = CALayer()
            let s = CGFloat.random(in: 4...9)
            d.bounds = CGRect(x: 0, y: 0, width: s, height: s)
            d.cornerRadius = s / 2
            d.backgroundColor = (i % 3 == 0 ? glow[i % 2 == 0 ? 0 : 2] : NSColor.white.withAlphaComponent(0.55)).cgColor
            d.position = p
            root.addSublayer(d)
            let side: CGFloat = i % 2 == 0 ? 1 : -1
            let to = CGPoint(x: p.x + side * CGFloat.random(in: 30...150), y: p.y + CGFloat.random(in: 4...60))
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: p); move.toValue = NSValue(point: to)
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1; grow.toValue = 1.8
            let g = CAAnimationGroup()
            g.animations = [move, fade, grow]
            g.duration = Double.random(in: 0.45...0.8)
            g.fillMode = .forwards; g.isRemovedOnCompletion = false
            d.opacity = 0
            d.add(g, forKey: "dust")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { d.removeFromSuperlayer() }
        }
    }

    private func animate(_ l: CALayer, in root: CALayer, duration: Double, delay: Double = 0,
                         scale: (CGFloat, CGFloat), opacity: (Float, Float)) {
        l.opacity = 0
        root.addSublayer(l)
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = scale.0; s.toValue = scale.1
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = opacity.0; o.toValue = opacity.1
        let g = CAAnimationGroup()
        g.animations = [s, o]
        g.duration = duration
        g.beginTime = CACurrentMediaTime() + delay
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.fillMode = .both; g.isRemovedOnCompletion = false
        l.add(g, forKey: "burst")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + delay + 0.1) { l.removeFromSuperlayer() }
    }
}
