import Foundation
import TandemCrashReports

// Before anything can load a library that prints to stdout.
StandardOutput.claim()
StandardOutput.printStrayLinesForTests(environment: ProcessInfo.processInfo.environment)
// Crashes of the installed release command only (see CrashReports). After
// claim(), so nothing it might print lands in an agent's JSON.
CrashReports.start(component: "cli")

// `tandem`: see Help.swift for the commands and CLI.swift for how they run.
let status = await CLI(
    arguments: Array(CommandLine.arguments.dropFirst()),
    directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    environment: ProcessInfo.processInfo.environment
).run()
exit(status)
