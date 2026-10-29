import Foundation
#if !DEBUG
import Sentry
#endif

/// Sends crashes from the installed Tandem to Sentry (project `tandem`), so
/// Mike's watcher hears about a crash without anyone having to mention it.
///
/// Only the release app in ~/Applications (or /Applications), and the
/// `tandem` command inside it, ever report. Agents build and run Tandem all
/// day: debug builds (`restart.sh`, `swift test`), test runs, CI and copies
/// staged with `TANDEM_APP_DIR` elsewhere stay silent, so their crashes
/// don't reach the watcher.
///
/// Crashes only, not errors: a command that fails (a clip that isn't there,
/// a bad range) is normal while an agent edits, and goes back to the agent
/// rather than to Sentry. No tracing, sessions or network breadcrumbs.
public enum CrashReports {
    /// A Sentry DSN is a public client key; it ships inside the app anyway.
    static let dsn = "https://ab6630bea33fc780aa4fdc232ab16747@o4508736647266304.ingest.us.sentry.io/4512336956555264"

    /// `component` is `mac` for the app and `cli` for the `tandem` command,
    /// so the watcher can tell them apart.
    public static func start(component: String) {
        #if !DEBUG
        let bundle = Bundle.main
        guard shouldReport(bundleURL: bundle.bundleURL, environment: ProcessInfo.processInfo.environment) else { return }
        let release = releaseName(info: bundle.infoDictionary ?? [:])
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = "production"
            options.releaseName = release
            options.sendDefaultPii = false
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            options.enableAutoSessionTracking = false
            // The app has its own main-thread meter, and Sentry's hang
            // reports are noisy on macOS while a long export or render runs.
            options.enableAppHangTracking = false
            // Swizzling is what adds network breadcrumbs (provider URLs can
            // carry search terms) and reports failed HTTP requests as
            // errors; neither belongs here.
            options.enableSwizzling = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.sendClientReports = false
            // The app and the command share a bundle, so each gets its own
            // folder; otherwise the next `tandem` run could pick up the app's
            // crash report and send it tagged `cli`.
            options.cacheDirectoryPath = cacheDirectory(component: component).path
            options.beforeSend = { event in
                isBrokenPipe(event) ? nil : event
            }
            options.initialScope = { scope in
                scope.setTag(value: component, key: "component")
                return scope
            }
        }
        #endif
    }

    /// The installed release copy, and nothing an agent or a test is running.
    static func shouldReport(bundleURL: URL, environment: [String: String]) -> Bool {
        if NSClassFromString("XCTestCase") != nil || environment["XCTestConfigurationFilePath"] != nil { return false }
        if let ci = environment["CI"], !ci.isEmpty, ci != "0", ci.lowercased() != "false" { return false }
        return isInstalledApp(bundleURL: bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Where `setup_mac.sh` puts the app (or /Applications, if Mike moves
    /// it there). The `tandem` command's main bundle is the app around it.
    static func isInstalledApp(bundleURL: URL, home: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let installed = [
            home.appendingPathComponent("Applications/Tandem.app").standardizedFileURL.resolvingSymlinksInPath().path,
            "/Applications/Tandem.app"
        ]
        return installed.contains(path)
    }

    /// `tandem@0.1.0+<commit>`: build-app.sh stamps the commit into the
    /// bundle's Info.plist as `TandemCommit`.
    static func releaseName(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let commit = info["TandemCommit"] as? String ?? info["CFBundleVersion"] as? String ?? "unknown"
        return "tandem@\(version)+\(commit)"
    }

    static func cacheDirectory(component: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mikerosoft.tandem/sentry-\(component)", isDirectory: true)
    }

    #if !DEBUG
    /// `tandem watch | head` ends the command with SIGPIPE when head has
    /// read enough. Sentry counts that signal as a crash; it isn't one.
    static func isBrokenPipe(_ event: Event) -> Bool {
        guard let exception = event.exceptions?.first else { return false }
        if exception.type == "SIGPIPE" { return true }
        let signal = exception.mechanism?.meta?.signal
        return signal?["name"] as? String == "SIGPIPE" || signal?["number"] as? Int == Int(SIGPIPE)
    }
    #endif
}
