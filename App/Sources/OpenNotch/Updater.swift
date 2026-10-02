import AppKit
import Combine
import Sparkle

/// Auto-updates via Sparkle. The feed is `appcast.xml` attached to the newest
/// GitHub release (`releases/latest/download/appcast.xml`); every update is
/// EdDSA-signed (public key `SUPublicEDKey` in Info.plist, private key in the
/// maintainer's Keychain) and must carry the same code signature as the
/// running app. Checks daily unless turned off in Settings › General.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false

    /// Only a real bundle with a feed updates itself (not the debug binary or --checks).
    static var available: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func start() {
        guard Self.available, controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.canCheck = v }.store(in: &subs)
    }
    private var subs: Set<AnyCancellable> = []

    func checkNow() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    // MARK: SPUStandardUserDriverDelegate — a menu-bar-less app must bring its update window forward itself.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if !state.userInitiated, let notch = (NSApp.delegate as? AppDelegate)?.notch {
                notch.showAlert(.info(icon: "arrow.down.circle", text: "OpenNotch \(update.displayVersionString) is ready to install"), for: 5)
            }
        }
    }
}
