import Foundation
import Darwin
import GhosttyKit
import Testing
@testable import Ghostty

struct TerminalAgentIntegrationTests {
    private static var nodeExecutable: URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("node") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @MainActor @Test(.enabled(if: TerminalAgentIntegrationTests.nodeExecutable != nil))
    func piBridgeDoesNotReportHeadlessOrChildAgentSessions() throws {
        let node = try #require(Self.nodeExecutable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("reported")
        let helper = root.appendingPathComponent("report-helper")
        try Data("#!/bin/sh\ntouch \(Ghostty.Shell.quote(marker.path))\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        _ = try TerminalAgentIntegration.install()
        let module = TerminalAgentIntegration.directory.appendingPathComponent("pi-session.mjs")
        let moduleData = try JSONEncoder().encode(module.absoluteString)
        let literal = try #require(String(data: moduleData, encoding: .utf8))
        let script = """
        import fs from "node:fs";
        const { default: install } = await import(\(literal));
        let callback;
        install({ on: (_event, handler) => { callback = handler; } });
        const ctx = { hasUI: true, cwd: "/tmp", sessionManager: {
            getSessionFile: () => "/tmp/session.jsonl",
            getSessionId: () => "00000000-0000-4000-8000-000000000001"
        }};
        process.env.GHOSTTY_AGENT_OWNER_PID = String(process.pid + 1);
        callback({}, ctx);
        if (fs.existsSync(process.env.TEST_MARKER)) throw new Error("Child session overwrote parent");
        process.env.GHOSTTY_AGENT_OWNER_PID = String(process.pid);
        ctx.hasUI = false;
        callback({}, ctx);
        if (fs.existsSync(process.env.TEST_MARKER)) throw new Error("Headless session overwrote parent");
        ctx.hasUI = true;
        callback({}, ctx);
        if (!fs.existsSync(process.env.TEST_MARKER)) throw new Error("Interactive owner did not report");
        """
        let process = Process()
        process.executableURL = node
        process.arguments = ["--input-type=module", "-e", script]
        var environment = ProcessInfo.processInfo.environment
        environment["GHOSTTY_AGENT_HELPER"] = helper.path
        environment["TEST_MARKER"] = marker.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @MainActor @Test(arguments: [
        "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", nil
    ] as [String?], [false, true])
    func dormantResumeAndManualRecoveryKeepExactSessions(reportedID: String?, exitsBeforePoll: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mock-agent")
        let argvFile = root.appendingPathComponent("arguments")
        let ready = root.appendingPathComponent("ready")
        let id = "00000000-0000-4000-8000-000000000001"
        var report = ""
        if let reportedID {
            report = """
            printf '{"session_id":"\(reportedID)","cwd":"%s","hook_event_name":"SessionStart"}' "$PWD" |
                "$GHOSTTY_AGENT_HELPER" --ghostty-agent-report
            """
        }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(Ghostty.Shell.quote(argvFile.path))
        \(report)
        touch \(Ghostty.Shell.quote(ready.path))
        \(exitsBeforePoll ? "exit 0" : "read value")
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let surfaceID = UUID()
        let record = TerminalAgentIntegration.directory.appendingPathComponent("\(surfaceID.uuidString).json")
        defer { try? FileManager.default.removeItem(at: record) }
        let restoration = TerminalAgentRestoration(session: .init(kind: .claude, session: id,
            executable: executable.path, arguments: ["--model", "test-model"], environment: [:], directory: root.path))
        let encoded = try JSONEncoder().encode(restoration)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let leaf: [String: Any] = ["uuid": surfaceID.uuidString, "pwd": root.path,
            "title": "Saved agent", "isUserSetTitle": true, "agentRestoration": object]
        let decoder = JSONDecoder()
        decoder.userInfo[.durableTabSnapshot] = true
        let surface = try decoder.decode(Ghostty.SurfaceView.self, from: JSONSerialization.data(withJSONObject: leaf))
        #expect(surface.surfaceModel == nil)
        #expect(!FileManager.default.fileExists(atPath: ready.path))
        surface.startDeferredTerminal()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        let arguments = try String(contentsOf: argvFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Array(arguments.suffix(4)) == ["--model", "test-model", "--resume", id])
        if exitsBeforePoll {
            let launch = try JSONDecoder().decode(TerminalAgentIntegration.Launch.self, from: Data(contentsOf: record))
            while TerminalAppIcon.ProcessInspector.identity(pid: launch.pid)?.startTime == launch.startTime, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(TerminalAppIcon.ProcessInspector.identity(pid: launch.pid)?.startTime != launch.startTime)
        }
        TerminalAgentIntegration.refreshSynchronously([surface])
        let mismatch = reportedID != nil && reportedID != id
        #expect((surface.savedSessionIssue != nil) == mismatch)
        let encoder = JSONEncoder()
        encoder.userInfo[.durableTabSnapshot] = true
        let persisted = try JSONSerialization.jsonObject(with: encoder.encode(surface)) as? [String: Any]
        if exitsBeforePoll && reportedID == id {
            #expect(surface.agentRestoration == nil)
            #expect(persisted?["agentRestoration"] == nil)
        } else {
            #expect(surface.agentRestoration?.session?.session == id)
        }
        if mismatch && exitsBeforePoll {
            let previous = try JSONDecoder().decode(TerminalAgentIntegration.Launch.self, from: Data(contentsOf: record))
            try FileManager.default.removeItem(at: ready)
            let recovery = """
            #!/bin/sh
            printf '{"session_id":"\(id)","cwd":"%s","hook_event_name":"SessionStart"}' "$PWD" |
                "$GHOSTTY_AGENT_HELPER" --ghostty-agent-report
            touch \(Ghostty.Shell.quote(ready.path))
            """
            try Data(recovery.utf8).write(to: executable)
            let command = try #require(surface.savedResumeCommand)
            let terminal = try #require(surface.surface)
            command.withCString { ghostty_surface_text(terminal, $0, UInt(command.utf8.count)) }
            #expect(surface.surfaceModel?.perform(action: "text:\\x0d") == true)
            let retryDeadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: ready.path), Date() < retryDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(FileManager.default.fileExists(atPath: ready.path))
            let retry = try JSONDecoder().decode(TerminalAgentIntegration.Launch.self, from: Data(contentsOf: record))
            #expect(retry.token != previous.token)
            #expect(retry.session == id)
            while TerminalAppIcon.ProcessInspector.identity(pid: retry.pid)?.startTime == retry.startTime, Date() < retryDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(TerminalAppIcon.ProcessInspector.identity(pid: retry.pid)?.startTime != retry.startTime)
            TerminalAgentIntegration.refreshSynchronously([surface])
            #expect(surface.savedSessionIssue == nil)
            #expect(surface.agentRestoration == nil)
            let saved = try JSONSerialization.jsonObject(with: encoder.encode(surface)) as? [String: Any]
            #expect(saved?["agentRestoration"] == nil)
        }
    }

    @Test func copiedResumeCommandCannotStartMissingConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mock-agent")
        let marker = root.appendingPathComponent("agent-was-started")
        let script = "#!/bin/sh\ntouch \(Ghostty.Shell.quote(marker.path))\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let missing = root.appendingPathComponent("missing.jsonl")
        let session = TerminalAgentSession(kind: .pi, session: missing.path, executable: executable.path,
            arguments: [], environment: [:], directory: root.path,
            nativeSessionID: "00000000-0000-4000-8000-000000000001")
        let helper = try #require(Bundle.main.executableURL)
        let command = try #require(session.command(helper: helper.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = root
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func hookReportsKeepSameDirectoryConversationsDistinctAndOmitSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("mock-agent")
        let script = """
        #!/bin/sh
        printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart"}' "$TEST_SESSION_ID" "$PWD" |
            "$GHOSTTY_AGENT_HELPER" --ghostty-agent-report
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let helper = try #require(Bundle.main.executableURL)
        let first = "00000000-0000-4000-8000-000000000001"
        let second = "00000000-0000-4000-8000-000000000002"
        var sessions: [String] = []
        for id in [first, second] {
            let surface = UUID()
            let recordURL = TerminalAgentIntegration.directory.appendingPathComponent("\(surface.uuidString).json")
            defer { try? FileManager.default.removeItem(at: recordURL) }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--ghostty-agent-launch", "claude", executable.path,
                "--model", "opus", "--resume", "old-selector", "private prompt"]
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["GHOSTTY_AGENT_SURFACE"] = surface.uuidString
            environment["GHOSTTY_AGENT_HELPER"] = helper.path
            environment["TEST_SESSION_ID"] = id
            environment["OPENAI_API_KEY"] = "must-not-persist"
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let data = try Data(contentsOf: recordURL)
            let record = try JSONDecoder().decode(TerminalAgentIntegration.Launch.self, from: data)
            #expect(record.surface == surface)
            #expect(record.arguments == ["--model", "opus"])
            var expectedDirectory = stat()
            var actualDirectory = stat()
            #expect(stat(directory.path, &expectedDirectory) == 0)
            #expect(stat(record.directory, &actualDirectory) == 0)
            #expect(actualDirectory.st_dev == expectedDirectory.st_dev)
            #expect(actualDirectory.st_ino == expectedDirectory.st_ino)
            #expect(record.environment["OPENAI_API_KEY"] == nil)
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(!text.contains("private prompt"))
            sessions.append(try #require(record.session))
        }
        #expect(sessions == [first, second])
    }

    @Test func codexIdentityComesFromWritableRootRolloutNotReadOnlyHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = "00000000-0000-4000-8000-000000000001"
        let old = "00000000-0000-4000-8000-000000000002"
        let root = directory.appendingPathComponent("rollout-active.jsonl")
        let history = directory.appendingPathComponent("rollout-history.jsonl")
        let subagent = directory.appendingPathComponent("rollout-subagent.jsonl")
        let fifo = directory.appendingPathComponent("rollout-pipe.jsonl")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let padding = String(repeating: "x", count: 9000)
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(active)\",\"source\":\"cli\",\"instructions\":\"\(padding)\"}}"
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(old)\",\"source\":\"cli\"}}\n".utf8).write(to: history)
        var contents = Data((header + "\n").utf8)
        contents.append(Data(String(repeating: "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n", count: 160_000).utf8))
        try contents.write(to: root)
        let script = """
        exec 9>>\(Ghostty.Shell.quote(root.path))
        exec 8<\(Ghostty.Shell.quote(history.path))
        exec 7>\(Ghostty.Shell.quote(subagent.path))
        exec 6<>\(Ghostty.Shell.quote(fifo.path))
        printf '%s\\n' '{"type":"session_meta","payload":{"id":"00000000-0000-4000-8000-000000000003","source":{"subagent":"test"}}}' >&7
        printf r
        read value
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        #expect(output.fileHandleForReading.readData(ofLength: 1) == Data("r".utf8))
        #expect(TerminalAgentIntegration.codexSession(pid: process.processIdentifier) == active)
    }
}
