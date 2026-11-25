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

    @ObservationIgnored private var reopenWith: (files: [URL], inBackground: Bool)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    /// Only an installed bundle can be reopened; `swift run` has none.
    let canReopen = Bundle.main.bundleURL.pathExtension == "app"

    private var documents: ProjectDocuments { .shared }

    private var openProjects: [URL] { documents.windows.map(\.model.fileURL) }

    private var rendering: Bool { documents.windows.contains { $0.model.isRendering } }

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
        ) {
            NSLog("Tandem: a newer build is installed and nothing is open, so reopening on it")
            reopen(with: [], inBackground: true)
        }
    }

    /// A project wouldn't open. True when this took care of it (reopening
    /// or offering to), false to explain the error as usual.
    func handleFailedOpen(_ url: URL) -> Bool {
        let outdated = canReopen && AppBuild.isOutdated()
        if outdated { isAvailable = true }
        let choice = AppBuild.afterFailedOpen(
            fileIsNewer: ProjectFile.isFromNewerTandem(url), outdated: outdated, canReopen: canReopen,
            openProjects: documents.windows.count, rendering: rendering
        )
        switch choice {
        case .explain:
            return false
        case .reopen:
            NSLog("Tandem: %@ is from the newer build installed since this one started, so reopening on it", url.lastPathComponent)
            reopen(with: [url], inBackground: false)
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
    private func reopen(with files: [URL], inBackground: Bool) {
        isReopening = true
        reopenWith = (files, inBackground)
        // From the run loop, as a failed open can come in the middle of
        // launching or of another alert.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// The quit was cancelled: stay as we are.
    func quitCancelled() {
        reopenWith = nil
        isReopening = false
    }

    /// From `applicationWillTerminate`: starts a small shell that waits for
    /// this process to end, then opens the new build. Without asking for
    /// a reopen, nothing happens.
    func launchReplacement() {
        guard let reopenWith else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Self.waitThenOpen(pid: getpid(), app: Bundle.main.bundleURL, files: reopenWith.files, inBackground: reopenWith.inBackground)
        do {
            try process.run()
        } catch {
            NSLog("Tandem: couldn't reopen on the new build: %@", error.localizedDescription)
        }
    }

    /// `sh` arguments that wait (up to two minutes) for `pid` to exit, then
    /// open `app` with `files`. Paths go as arguments, never in the script.
    nonisolated static func waitThenOpen(pid: pid_t, app: URL, files: [URL], inBackground: Bool) -> [String] {
        let script = """
        pid="$1"; app="$2"; shift 2
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i + 1)); [ "$i" -gt 1200 ] && exit 1
          sleep 0.1
        done
        exec /usr/bin/open \(inBackground ? "-g " : "")-a "$app" "$@"
        """
        return ["-c", script, "tandem-reopen", String(pid), app.path] + files.map(\.path)
    }
}
