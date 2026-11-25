import Darwin
import Foundation
import TandemCore

/// Telling a running Tandem app from a build installed since it started.
///
/// restart.sh builds a new bundle and swaps it in, then stops the app; but
/// kill.sh won't stop it while an export or review clip runs (exit 3), and
/// then nothing restarted it. On 24 Nov 2026 the app ran on from 20 Nov
/// while agents edited through the new build's CLI, which saved the
/// project in a schema the old app didn't know. Mike double-clicked it,
/// the app said it was "saved by a newer Tandem", and `tandem status`
/// said only "open in: nothing else". Both sides now notice.
///
/// The rule: a process runs the file it was started from, mapped into
/// memory, whatever happens to the path afterwards. build-app.sh puts each
/// build in place by renaming a new bundle over the old one, so the
/// installed executable is a different file (another inode) from the one
/// an older process has mapped, even once the old one is deleted. Comparing
/// files, not times, also holds when a process starts in the moment between
/// a build being signed and swapped in, a copy keeps an older date, or the
/// clock is wrong (two reviewers of the first version, 25 Nov 2026).
public enum AppBuild {
    /// A file, by the volume and inode it's on.
    public struct FileID: Equatable, Hashable, Sendable {
        public var device: UInt64
        public var inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// A Tandem app process.
    public struct RunningApp: Equatable, Sendable {
        public var pid: pid_t
        public var started: Date
        /// The executable file it runs, or nil if that couldn't be read.
        public var executable: FileID?

        public init(pid: pid_t, started: Date, executable: FileID?) {
            self.pid = pid
            self.started = started
            self.executable = executable
        }
    }

    /// The process name of the app's executable, as build-app.sh installs it.
    public static let appExecutableName = "tandem-app"

    /// The file at `url`, or nil if there's none.
    public static func fileID(of url: URL) -> FileID? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileID(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
    }

    /// When the file at `url` was last written, or nil if there's none.
    public static func modified(_ url: URL) -> Date? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    /// When process `pid` started, or nil if it isn't running (or isn't ours to see).
    public static func started(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    /// The executable file process `pid` runs: its first file-backed memory
    /// region, which is the main executable (dyld and libraries are mapped
    /// above it). It's still there after the file has been replaced or
    /// deleted. Nil if the process isn't ours to look at.
    public static func runningExecutable(pid: pid_t) -> FileID? {
        var address: UInt64 = 0
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        for _ in 0..<64 {
            var info = proc_regionwithpathinfo()
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size) == size else { return nil }
            let stat = info.prp_vip.vip_vi.vi_stat
            if stat.vst_ino != 0 { return FileID(device: UInt64(stat.vst_dev), inode: stat.vst_ino) }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            guard next > address else { return nil }
            address = next
        }
        return nil
    }

    /// True when `running` is known and isn't the file installed now.
    public static func isStale(running: FileID?, installed: FileID?) -> Bool {
        guard let running, let installed else { return false }
        return running != installed
    }

    /// True when this process's own executable has been replaced since it
    /// started: the app is running a build that's no longer installed.
    public static func isOutdated(executable: URL? = Bundle.main.executableURL) -> Bool {
        guard let executable else { return false }
        return isStale(running: runningExecutable(pid: getpid()), installed: fileID(of: executable))
    }

    // MARK: - What the app does about it

    /// What the app does when a project wouldn't open.
    public enum AfterFailedOpen: Equatable, Sendable {
        /// Say why, as always: the file isn't from a newer Tandem, or this
        /// app is the newest there is.
        case explain
        /// Quit and open it in the new build straight away: nothing else
        /// is open, so nothing is lost or interrupted.
        case reopen
        /// Ask, with a button that reopens: other projects are open, or
        /// something renders.
        case askToReopen
    }

    public static func afterFailedOpen(fileIsNewer: Bool, outdated: Bool, canReopen: Bool, openProjects: Int, rendering: Bool) -> AfterFailedOpen {
        guard fileIsNewer, outdated, canReopen else { return .explain }
        return openProjects == 0 && !rendering ? .reopen : .askToReopen
    }

    /// True when an out-of-date app can reopen on the new build without
    /// anyone noticing: no project open or on its way, Mike in another app,
    /// and up for a while, so a reopen can never loop.
    public static func reopensWhileIdle(outdated: Bool, canReopen: Bool, openProjects: Int, opening: Bool, active: Bool, upFor: TimeInterval) -> Bool {
        outdated && canReopen && openProjects == 0 && !opening && !active && upFor >= minimumUptime
    }

    /// How long an app runs before it reopens by itself.
    public static let minimumUptime: TimeInterval = 60

    /// Whether SIGTERM (kill.sh, `tandem quit-app`) quits the app. Not
    /// while an export or review clip renders in it: kill.sh can only see
    /// the `tandem export` and `tandem clip` commands, not an export from
    /// the app's own menu or through MCP. A second signal within
    /// `insistWithin` of a refused one quits anyway (TANDEM_FORCE_KILL=1).
    public static func quitsOnSignal(rendering: Bool, refusedAt: Date?, now: Date = Date()) -> Bool {
        guard rendering else { return true }
        guard let refusedAt else { return false }
        return now.timeIntervalSince(refusedAt) < insistWithin
    }

    public static let insistWithin: TimeInterval = 3

    // MARK: - Finding the app from the CLI

    /// The app executable installed beside this command: the CLI lives in
    /// the bundle's Contents/MacOS, next to tandem-app.
    public static var installedAppExecutable: URL? {
        guard let cli = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        return cli.deletingLastPathComponent().appendingPathComponent(appExecutableName)
    }

    /// The app processes started from `executable`'s path, whichever build
    /// they run. A process started before a rebuild still names the path it
    /// was launched from, though the file there has been replaced since.
    public static func runningApps(executable: URL) -> [RunningApp] {
        let wanted = executable.resolvingSymlinksInPath().standardizedFileURL.path
        return allPIDs().compactMap { pid in
            guard pid > 0, pid != getpid(), processName(pid) == executable.lastPathComponent,
                  let path = launchPath(pid), URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == wanted,
                  let started = started(pid: pid) else { return nil }
            return RunningApp(pid: pid, started: started, executable: runningExecutable(pid: pid))
        }
    }

    /// The apps in `running` that run another file than the one installed.
    public static func stale(_ running: [RunningApp], installed: FileID?) -> [RunningApp] {
        running.filter { isStale(running: $0.executable, installed: installed) }
    }

    /// What to tell an agent about a Tandem app running an older build
    /// than the installed one, or nil when there's none. `holder` is the
    /// pid that has the project open, if any; `built` is when the installed
    /// build was written.
    public static func staleAppWarning(_ stale: [RunningApp], built: Date, holder: pid_t?, now: Date = Date()) -> String? {
        // The one holding the project, when that's one of them.
        guard let app = stale.first(where: { $0.pid == holder }) ?? stale.first else { return nil }
        let when = { (date: Date) in DateText.short(date, now: now) }
        var text = "The Tandem app running now (pid \(app.pid), started \(when(app.started))) is an older build than the one installed (built \(when(built))): it runs a file that has since been replaced. "
        if holder == app.pid {
            text += "It has this project open and answers commands the old way, and Mike is looking at the old build. "
        } else {
            text += "It can't open a project the new build has saved in a newer format: if you opened this one for Mike and it still says \"open in: nothing else\", that's why (the app says \"saved by a newer Tandem\"). "
        }
        text += "Restart it on the new build: if it has none of Mike's projects open, `tandem quit-app` (it saves what's open, and refuses while an export or review clip runs) and open the project again; if it has, ask Mike to click \"Reopen to update\" in its status bar, or to quit and reopen Tandem."
        return text
    }

    /// The warning for the app installed beside this command, if it's stale.
    public static func staleAppWarning(holder: pid_t?, executable: URL? = installedAppExecutable) -> String? {
        guard let executable, let installed = fileID(of: executable), let built = modified(executable) else { return nil }
        return staleAppWarning(stale(runningApps(executable: executable), installed: installed), built: built, holder: holder)
    }

    // MARK: - Saying so in results

    /// `status` and `handback` with what Mike won't see: a Tandem app on an
    /// older build than the one installed, and for a hand-back, a project
    /// nothing has open in the app. Done by the command that asked rather
    /// than the service, since an old app answering `status` can't know
    /// it's old. Other results pass through.
    public static func noting<R>(
        _ result: R, route: ProjectClient.Route, projectURL: URL,
        staleWarning: (pid_t?) -> String? = { staleAppWarning(holder: $0) }
    ) -> R {
        var holder: pid_t?
        if case .remote(_, let owner, let pid) = route, owner == ProjectSession.Owner.app.rawValue { holder = pid }
        if var status = result as? StatusResult {
            // Who had it when status was answered, rather than a look after.
            holder = status.openIn.flatMap { $0.owner == ProjectSession.Owner.app.rawValue ? $0.pid : nil }
            guard let warning = staleWarning(holder) else { return result }
            status.warnings = (status.warnings ?? []) + [warning]
            return status as? R ?? result
        }
        if var handback = result as? HandbackResult {
            var warnings = handback.warnings ?? []
            if let warning = staleWarning(holder) {
                warnings.append(warning)
            } else if holder == nil, (handback.recorded ?? 0) > 0 {
                warnings.append(notOpenWarning(projectURL))
            }
            guard !warnings.isEmpty else { return result }
            handback.warnings = warnings
            return handback as? R ?? result
        }
        return result
    }

    /// A hand-back to a project the app doesn't have open.
    static func notOpenWarning(_ projectURL: URL) -> String {
        "Nothing has \(projectURL.lastPathComponent) open in the Tandem app, so Mike won't see what you handed back until it is. Open it for him (`open \"\(projectURL.path)\"`) and check that `tandem status` says \"open in: the Tandem app\". If it still says \"nothing else\" a few seconds later, the app couldn't open it: the alert in the app, or a warning in `tandem status`, says why."
    }

    // MARK: - libproc

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes that start while listing.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    private static func processName(_ pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }

    /// The path the process was started from (KERN_PROCARGS2's exec path),
    /// which stays the same when the file there is later replaced. Only
    /// readable for this user's processes.
    private static func launchPath(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let bytes = buffer[MemoryLayout<Int32>.size..<size].prefix { $0 != 0 }
        let path = String(decoding: bytes, as: UTF8.self)
        if path.hasPrefix("/") { return path }
        // Started by a relative path (from a shell, not Launch Services):
        // where the file it runs is now.
        var current = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &current, UInt32(current.count)) > 0 else { return nil }
        return String(cString: current)
    }
}

/// Short dates for messages: "14:23" today, "20 Nov 09:12" otherwise.
enum DateText {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }
}

extension ProjectFile {
    /// The schema a project file was saved in, read without building the
    /// project, or nil if the file can't be read. A file without one is the
    /// current schema, as `Project`'s decoder takes it.
    public static func savedSchemaVersion(at url: URL) -> Int? {
        struct File: Decodable {
            struct Body: Decodable { var schemaVersion: Int? }
            var project: Body
        }
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return file.project.schemaVersion ?? Project.currentSchemaVersion
    }

    /// True when the project at `url` was saved by a newer Tandem than this one.
    public static func isFromNewerTandem(_ url: URL) -> Bool {
        (savedSchemaVersion(at: url) ?? 0) > Project.currentSchemaVersion
    }
}
