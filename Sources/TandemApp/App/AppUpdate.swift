import AppKit
import Observation
import TandemAPI
import TandemCore

/// Notices when Tandem has been rebuilt since it started and reopens on
/// the new build (see `AppBuild`). restart.sh installs a new build but
/// leaves the app running while an export or review clip renders, and
/// before this nothing restarted it: on 25 Nov 2026 a five-day-old app
/// refused a project the new build had saved.
///
/// - A project from a newer Tandem that won't open reopens Tandem on the
///   new build with it, straight away when nothing else is open, or from
///   an alert's button when something is.
/// - The status bar of each project offers "Reopen to update".
/// - With nothing open and Mike in another app, Tandem reopens by itself.
@MainActor
@Observable
final class AppUpdate {
    static let shared = AppUpdate()

    /// True once the installed build is newer than this process.
    private(set) var isAvailable = false
    /// True from a reopen being asked for until Tandem quits (or the quit
    /// is cancelled), so the button shows it's working and can't be
    /// pressed twice.
    private(set) var isReopening = false

    @ObservationIgnored private var reopenWith: (files: [URL], inBackground: Bool, welcome: Bool)?

    /// The key a reopen passes when the welcome window wasn't up, so the
    /// new build doesn't show it either.
    nonisolated static let noWelcomeKey = "TandemReopenedWithoutWelcome"

    /// Where the reopen says what it did: ~/Library/Logs/Tandem/reopen.log.
    nonisolated static var logURL: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tandem", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("reopen.log")
    }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    /// Only an installed bundle can be reopened; `swift run` has none.
    let canReopen = Bundle.main.bundleURL.pathExtension == "app"

    private var documents: ProjectDocuments { .shared }

    /// What's open, and what's waiting for another process to let go, to
    /// open again in the new build.
    private var openProjects: [URL] { documents.windows.map(\.model.fileURL) + documents.opening.sorted { $0.path < $1.path } }

    /// An export, review clip or archive runs (from the app, the CLI or
    /// MCP), which quitting would cut off. SIGTERM checks this too.
    var isBusy: Bool { documents.windows.contains { $0.model.isRendering || $0.isArchiving } }

    private var rendering: Bool { isBusy }

    func start() {
        // A stat of one file: cheap enough to look every half minute.
        // In the common modes, so it still looks while an alert is up.
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { AppUpdate.shared.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppUpdate.shared.check() }
        }
        check()
    }

    func check() {
        if !isAvailable { isAvailable = canReopen && AppBuild.isOutdated() }
        // Never from under an alert Mike hasn't answered.
        guard isAvailable, !isReopening, NSApp.modalWindow == nil else { return }
        let upFor = AppBuild.started(pid: getpid()).map { Date().timeIntervalSince($0) } ?? 0
        if AppBuild.reopensWhileIdle(
            outdated: isAvailable, canReopen: canReopen, openProjects: documents.windows.count,
            opening: documents.isOpening, active: NSApp.isActive, upFor: upFor
        ), !documents.hasOtherWindows {
            NSLog("Tandem: a newer build is installed and nothing is open, so reopening on it")
            reopen(with: [], inBackground: true, welcome: documents.isWelcomeVisible)
        }
    }

    /// A project wouldn't open. True when this took care of it (reopening
    /// or offering to), false to explain the error as usual.
    func handleFailedOpen(_ url: URL) -> Bool {
        if isReopening {
            openAfterReopening(url)
            return true
        }
        let outdated = canReopen && AppBuild.isOutdated()
        if outdated { isAvailable = true }
        let choice = AppBuild.afterFailedOpen(
            fileIsNewer: ProjectFile.isFromNewerTandem(url), outdated: outdated, canReopen: canReopen,
            openProjects: openProjects.count, rendering: rendering
        )
        switch choice {
        case .explain:
            return false
        case .reopen:
            NSLog("Tandem: %@ is from the newer build installed since this one started, so reopening on it", url.lastPathComponent)
            reopen(with: openProjects + [url], inBackground: false)
            return true
        case .askToReopen:
            let alert = NSAlert()
            alert.messageText = "Tandem has been updated since it was started"
            var detail = "Reopen Tandem to open \(url.lastPathComponent): it was saved by the new version. Your open projects save and open again."
            if rendering { detail += " An export is running, and reopening now stops it." }
            alert.informativeText = detail
            alert.addButton(withTitle: "Reopen Tandem")
            alert.addButton(withTitle: "Not now")
            if alert.runModal() == .alertFirstButtonReturn {
                reopen(with: openProjects + [url], inBackground: false)
            }
            return true
        }
    }

    /// The status bar's button: reopen with everything that's open now.
    func reopenFromStatusBar() {
        guard !isReopening else { return }
        if rendering {
            let alert = NSAlert()
            alert.messageText = "An export is running"
            alert.informativeText = "Reopening Tandem now stops it. You can reopen once it has finished."
            alert.addButton(withTitle: "Wait")
            alert.addButton(withTitle: "Reopen anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        reopen(with: openProjects, inBackground: false)
    }

    /// Quits like Cmd-Q (projects save, or Mike is asked about any that
    /// won't), and once this process has gone, opens the installed build
    /// with `files`.
    private func reopen(with files: [URL], inBackground: Bool, welcome: Bool = true) {
        // Several projects can come in one open (Finder, `open a b`): each
        // one asked for joins the list, and Tandem quits once.
        var all = reopenWith?.files ?? []
        for file in files.map(\.standardizedFileURL) where !all.contains(file) { all.append(file) }
        reopenWith = (all, (reopenWith?.inBackground ?? true) && inBackground, (reopenWith?.welcome ?? false) || welcome || !files.isEmpty)
        guard !isReopening else { return }
        isReopening = true
        // From the run loop's default mode, so it waits for any alert or
        // open panel to close: a quit asked for under one is ignored, and
        // the reopen would never happen.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// A project asked for while Tandem is reopening opens in the new build.
    func openAfterReopening(_ url: URL) {
        reopen(with: [url], inBackground: false)
    }

    /// The quit was cancelled: stay as we are.
    func quitCancelled() {
        reopenWith = nil
        isReopening = false
    }

    /// From `applicationWillTerminate`: starts a small shell that waits for
    /// this process to end, then opens the new build. Without asking for
    /// a reopen, nothing happens.
    func launchReplacement(quittingOnSignal: Bool) {
        // kill.sh or `tandem quit-app` asked meanwhile: they mean stop.
        guard let reopenWith, !quittingOnSignal else { return }
        let arguments = ["/bin/sh"] + Self.waitThenOpen(
            pid: getpid(), app: Bundle.main.bundleURL, files: reopenWith.files,
            inBackground: reopenWith.inBackground, welcome: reopenWith.welcome, log: Self.logURL
        )
        // In a session of its own: launchd ends what's left in an app's
        // process group when the app quits (a plain child never got to run
        // `open` when Tandem had been started from Finder or `open`).
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", nil, &attributes, &argv, environ)
        if status != 0 {
            NSLog("Tandem: couldn't reopen on the new build: %s", strerror(status))
        }
    }

    /// `sh` arguments that wait (up to two minutes) for `pid` to exit, then
    /// open `app` with `files`. Paths go as arguments, never in the script.
    /// Launch Services can still count the old process as running for a
    /// moment after it has gone, and then `open` fails (-10810) or hands the
    /// files to it, so it waits a second and tries a few times, writing what
    /// happened to `log`.
    nonisolated static func waitThenOpen(pid: pid_t, app: URL, files: [URL], inBackground: Bool, welcome: Bool, log: URL) -> [String] {
        let script = """
        pid="$1"; app="$2"; log="$3"; shift 3
        # Without a log it still reopens: a failed redirect would end sh.
        if touch "$log" 2>/dev/null; then exec >>"$log" 2>&1; else exec >/dev/null 2>&1; fi
        echo "$(date): reopening $app once $pid has quit"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i + 1)); [ "$i" -gt 1200 ] && { echo "it didn't quit"; exit 1; }
          sleep 0.1
        done
        for try in 1 2 3 4 5; do
          sleep 1
          /usr/bin/open \(inBackground ? "-g " : "")-a "$app" "$@"\(welcome ? "" : " --args -\(noWelcomeKey) YES") && { echo "opened"; exit 0; }
          echo "open failed, try $try"
        done
        exit 1
        """
        return ["-c", script, "tandem-reopen", String(pid), app.path, log.path] + files.map(\.path)
    }
}
