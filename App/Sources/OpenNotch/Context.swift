import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What you were working on when the notch opened — "Ask about this".
struct WorkContext: Equatable {
    var appName = ""
    var bundleID = ""
    var pid: pid_t = 0
    var windowTitle: String?
    var selectedText: String?
    var page: WebPage?
    var finderPaths: [String] = []
    /// A browser/Finder we could read, but macOS hasn't been asked yet.
    var needsAutomationFor: String?

    struct WebPage: Equatable { var url: String; var title: String }

    var isEmpty: Bool { selectedText == nil && page == nil && finderPaths.isEmpty }
}

enum ContextGrabber {
    static let browsers: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "company.thebrowser.Browser": "Arc",
        "com.apple.Safari": "Safari",
    ]
    private static let q = DispatchQueue(label: "opennotch.context", qos: .userInitiated)

    /// Snapshot the frontmost app. Never prompts: Accessibility and Automation
    /// are only *used* if already granted. Calls back on main.
    static func capture(_ done: @escaping @Sendable (WorkContext) -> Void) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            done(WorkContext()); return
        }
        var ctx = WorkContext(appName: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "",
                              pid: app.processIdentifier)
        q.async {
            if AXIsProcessTrusted() {
                let axApp = AXUIElementCreateApplication(ctx.pid)
                AXUIElementSetMessagingTimeout(axApp, 0.5)          // a hung app must not hang us
                if let focused: AXUIElement = attr(axApp, kAXFocusedUIElementAttribute),
                   let sel: String = attr(focused, kAXSelectedTextAttribute) {
                    let t = sel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { ctx.selectedText = String(sel.prefix(20_000)) }
                }
                if let win: AXUIElement = attr(axApp, kAXFocusedWindowAttribute),
                   let title: String = attr(win, kAXTitleAttribute), !title.isEmpty {
                    ctx.windowTitle = title
                }
            }
            if let name = browsers[ctx.bundleID] {
                switch automationStatus(ctx.bundleID) {
                case noErr: ctx.page = readPage(appName: name, safari: ctx.bundleID == "com.apple.Safari")
                case OSStatus(errAEEventWouldRequireUserConsent): ctx.needsAutomationFor = name
                default: break
                }
            } else if ctx.bundleID == "com.apple.finder" {
                switch automationStatus(ctx.bundleID) {
                case noErr: ctx.finderPaths = finderSelection()
                case OSStatus(errAEEventWouldRequireUserConsent): ctx.needsAutomationFor = "Finder"
                default: break
                }
            }
            DispatchQueue.main.async { done(ctx) }
        }
    }

    /// Ask macOS for Automation permission (shows the dialog). Main thread not required.
    static func requestAutomation(bundleID: String, _ done: @escaping @Sendable (Bool) -> Void) {
        q.async {
            let ok = automationStatus(bundleID, ask: true) == noErr
            DispatchQueue.main.async { done(ok) }
        }
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// noErr = allowed · -1744 = not asked yet · -1743 = denied · -600 = not running.
    static func automationStatus(_ bundleID: String, ask: Bool = false) -> OSStatus {
        var target = AEAddressDesc()
        let data = Array(bundleID.utf8)
        let made = data.withUnsafeBytes { AECreateDesc(typeApplicationBundleID, $0.baseAddress, data.count, &target) }
        guard made == noErr else { return OSStatus(made) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }

    private static func osa(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Hard timeout: a busy browser must not block the notch.
        let deadline = Date().addingTimeInterval(1.5)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readPage(appName: String, safari: Bool) -> WorkContext.WebPage? {
        let script = safari
            ? "tell application \"Safari\" to return (URL of front document) & linefeed & (name of front document)"
            : "tell application \"\(appName)\" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
        guard let out = osa(script) else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard let url = parts.first, url.hasPrefix("http") else { return nil }
        return .init(url: url, title: parts.dropFirst().joined(separator: " "))
    }

    private static func finderSelection() -> [String] {
        let script = """
        tell application "Finder"
          set out to ""
          repeat with f in (selection as alias list)
            set out to out & POSIX path of f & linefeed
          end repeat
          return out
        end tell
        """
        return (osa(script) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }.prefix(20).map { $0 }
    }
}

/// Puts rewritten text back where it came from.
///
/// Paste is the one method that works in native apps, Chrome, Electron and web
/// editors alike: stash the clipboard, put our text on it, bring the source app
/// back, press ⌘V, then restore the clipboard. Needs Accessibility (to send ⌘V).
enum TextInserter {
    enum Result { case replaced, copiedOnly(String) }

    @MainActor
    static func replaceSelection(in pid: pid_t, with text: String, clipboard: ClipboardStore?,
                                 _ done: @escaping (Result) -> Void) {
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            clipboard?.suppressNextChange()
            pb.clearContents()
            pb.setString(text, forType: .string)
            done(.copiedOnly(AXIsProcessTrusted() ? "The app you were in has closed — the text is on your clipboard."
                                                  : "Copied — press ⌘V to paste. (Allow Accessibility to replace in place.)"))
            return
        }
        // Save every type of every item currently on the clipboard.
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        clipboard?.suppressNextChange()
        pb.clearContents()
        pb.setString(text, forType: .string)
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let v = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.postToPid(pid)
            up?.postToPid(pid)
            // Give the app time to read the clipboard before restoring it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                clipboard?.suppressNextChange()
                pb.clearContents()
                let items = saved.map { pairs -> NSPasteboardItem in
                    let it = NSPasteboardItem()
                    for (t, d) in pairs { it.setData(d, forType: t) }
                    return it
                }
                if !items.isEmpty { pb.writeObjects(items) }
                done(.replaced)
            }
        }
    }
}
