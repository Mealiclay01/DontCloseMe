import XCTest
@testable import DontCloseMe

final class DontCloseMeTests: XCTestCase {
    func testJokeFormattingReplacesTokens() {
        let profile = AgentProfile.builtInDefaults.first { $0.id == "claude-code" }!
        let agent = DetectedAgent(
            profile: profile,
            pids: [123],
            sampleCommand: "claude",
            treeCPUPercent: 18.5,
            activeChildCount: 1,
            hasRecentFileActivity: true,
            hasActiveNetworkSocket: true,
            state: .working,
            reasons: ["CPU 18.5%"],
            lastActiveAt: Date(),
            workingSince: Date()
        )
        let msg = JokePhraseBank.format(
            "{AGENT} is working at {ANGLE}°!",
            agents: [agent],
            angle: 71.6
        )
        XCTAssertEqual(msg, "Claude Code is working at 72°!")
    }

    func testCursorProfileExcludesSystemCursorUIViewService() {
        let cursor = AgentProfile.builtInDefaults.first { $0.id == "cursor" }!
        XCTAssertTrue(cursor.excludedPathSubstrings.contains("CursorUIViewService"))
        XCTAssertTrue(cursor.excludedPathSubstrings.contains("/System/"))
    }

    @MainActor
    func testAgentMonitorMatchesRealSymlinksWrapperScriptsAndExclusions() {
        let settings = AppSettings()
        let monitor = AgentMonitor(settings: settings)

        let byPID: [pid_t: ProcessSnapshot] = [
            // Real Claude Code symlink: proc_pidpath resolves to versions/2.1.198, argv0 is "claude"
            101: ProcessSnapshot(
                pid: 101, ppid: 1,
                executablePath: "/Users/test/.local/share/claude/versions/2.1.198",
                executableName: "2.1.198",
                commName: "2.1.198",
                argv0Basename: "claude",
                commandLine: "claude",
                startTimeSec: 1000,
                totalCPUTimeNs: 1000, cpuPercent: 12.0
            ),
            // Real OpenCode wrapper script: exec node ~/.opencode/cli.mjs
            102: ProcessSnapshot(
                pid: 102, ppid: 1,
                executablePath: "/opt/homebrew/bin/node",
                executableName: "node",
                commName: "node",
                argv0Basename: "node",
                commandLine: "/opt/homebrew/bin/node /Users/test/.opencode/cli.mjs",
                startTimeSec: 1000,
                totalCPUTimeNs: 1000, cpuPercent: 8.0
            ),
            // OpenAI Codex CLI
            103: ProcessSnapshot(
                pid: 103, ppid: 1,
                executablePath: "/opt/homebrew/bin/node",
                executableName: "node",
                commName: "node",
                argv0Basename: "node",
                commandLine: "node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js",
                startTimeSec: 1000,
                totalCPUTimeNs: 1000, cpuPercent: 6.0
            ),
            // System CursorUIViewService must NEVER match Cursor
            104: ProcessSnapshot(
                pid: 104, ppid: 1,
                executablePath: "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService",
                executableName: "CursorUIViewService",
                commName: "CursorUIViewService",
                argv0Basename: "CursorUIViewService",
                commandLine: "CursorUIViewService",
                startTimeSec: 1000,
                totalCPUTimeNs: 1000, cpuPercent: 15.0
            ),
            // Real Cursor.app
            105: ProcessSnapshot(
                pid: 105, ppid: 1,
                executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                executableName: "Cursor",
                commName: "Cursor",
                argv0Basename: "Cursor",
                commandLine: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                startTimeSec: 1000,
                totalCPUTimeNs: 1000, cpuPercent: 0.2
            )
        ]

        let claude = AgentProfile.builtInDefaults.first { $0.id == "claude-code" }!
        let opencode = AgentProfile.builtInDefaults.first { $0.id == "opencode" }!
        let codex = AgentProfile.builtInDefaults.first { $0.id == "openai-codex" }!
        let cursor = AgentProfile.builtInDefaults.first { $0.id == "cursor" }!

        XCTAssertEqual(monitor.matchProcesses(for: claude, in: byPID).map(\.pid), [101])
        XCTAssertEqual(monitor.matchProcesses(for: opencode, in: byPID).map(\.pid), [102])
        XCTAssertEqual(monitor.matchProcesses(for: codex, in: byPID).map(\.pid), [103])
        XCTAssertEqual(monitor.matchProcesses(for: cursor, in: byPID).map(\.pid), [105])
    }

    func testFileActivityWatcherFindsDeepNestedFiles() throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DontCloseMeWatcherTest-\(UUID().uuidString)", isDirectory: true)
        let deepDir = tmpRoot.appendingPathComponent("2026/11/24", isDirectory: true)
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let sessionFile = deepDir.appendingPathComponent("rollout.jsonl")
        try "{}".write(to: sessionFile, atomically: true, encoding: .utf8)

        let watcher = FileActivityWatcher()
        XCTAssertTrue(watcher.hasRecentActivity(in: [tmpRoot.path], within: 10.0))
    }

    func testLaunchWatchdogDetachesWithoutHanging() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcherURL = projectRoot.appendingPathComponent("Sources/DontCloseMe/Resources/launch_watchdog.sh")
        let watchdogURL = projectRoot.appendingPathComponent("Sources/DontCloseMe/Resources/clamshell_watchdog.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: launcherURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: watchdogURL.path))

        // Spawn a background sleep via the same perl setsid+close_fds launcher pattern and ensure caller exits < 1s
        let tmpState = FileManager.default.temporaryDirectory.appendingPathComponent("dcm-test-\(UUID().uuidString).state")
        try "WANT_DISABLE_SLEEP=0\nBATTERY_FLOOR=12\nSLEEP_NOW_NONCE=0\n".write(to: tmpState, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpState) }

        let dummy = Process()
        dummy.executableURL = URL(fileURLWithPath: "/bin/sleep")
        dummy.arguments = ["5"]
        try dummy.run()
        defer { if dummy.isRunning { dummy.terminate() } }

        let t0 = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [launcherURL.path, watchdogURL.path, "\(dummy.processIdentifier)", tmpState.path]
        try proc.run()
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
    }

    @MainActor
    func testProcessScannerFindsCurrentProcessOrUserProcesses() {
        let scanner = SystemProcessScanner()
        let (byPID, _) = scanner.scanUserProcesses()
        XCTAssertFalse(byPID.isEmpty, "Expected at least one user process during test")
    }
}
