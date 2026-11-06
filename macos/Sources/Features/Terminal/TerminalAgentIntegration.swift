import AppKit
import Darwin

struct TerminalAgentSession: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case claude, codex, pi
    }

    var kind: Kind
    var session: String
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var directory: String
    var nativeSessionID: String?

    var hasExistingConversation: Bool {
        guard kind == .pi else { return true }
        guard let expected = nativeSessionID.flatMap(UUID.init(uuidString:)),
              let header = TerminalAgentIntegration.readHeader(session),
              header["type"] as? String == "session",
              let id = header["id"] as? String else { return false }
        return UUID(uuidString: id) == expected
    }

    var resumeArguments: [String] {
        switch kind {
        case .claude: return arguments + ["--resume", session]
        case .codex: return arguments + ["resume", session]
        case .pi: return arguments + ["--session", session]
        }
    }

    var isValid: Bool {
        guard executable.hasPrefix("/"), directory.hasPrefix("/"),
              TerminalAgentIntegration.savedOptions(kind: kind, arguments: arguments) == arguments,
              environment.keys.allSatisfy(TerminalAgentIntegration.environmentKeys.contains),
              ([executable, directory] + resumeArguments).allSatisfy({ !Ghostty.Shell.containsControlCharacters($0) }),
              environment.values.allSatisfy({ !Ghostty.Shell.containsControlCharacters($0) }) else { return false }
        if kind == .pi {
            return session.hasPrefix("/") && session.hasSuffix(".jsonl") &&
                nativeSessionID.flatMap(UUID.init(uuidString:)) != nil
        }
        return nativeSessionID == nil && UUID(uuidString: session) != nil
    }

    func command(helper: String, resumeToken: UUID? = nil) -> String? {
        guard isValid, !Ghostty.Shell.containsControlCharacters(helper),
              let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) else { return nil }
        var argv = ["/usr/bin/env", "GHOSTTY_AGENT_RESUME=" + json]
        if let resumeToken { argv.append("GHOSTTY_AGENT_RESUME_TOKEN=" + resumeToken.uuidString) }
        argv += [helper, "--ghostty-agent-resume"]
        return argv.map(Ghostty.Shell.quote).joined(separator: " ")
    }
}

struct TerminalAgentRestoration: Codable, Equatable {
    var session: TerminalAgentSession?
    var issue: String?
}

/// Per-invocation helpers report exact identities, never newest-by-directory guesses.
/// Files contain restart metadata only, not prompts, transcripts, or credentials.
enum TerminalAgentIntegration {
    struct Launch: Codable {
        var token: UUID
        var surface: UUID
        var pid: pid_t
        var startTime: UInt64
        var kind: TerminalAgentSession.Kind
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var directory: String
        var session: String?
        var nativeSessionID: String?
        var resumeToken: UUID?
    }

    static let queue = DispatchQueue(label: "com.mitchellh.ghostty.agent-session", qos: .utility)
    private static var snapshots: [UUID: (pid_t, TerminalAgentRestoration)] = [:]
    private static var confirmations: [UUID: (UUID, TerminalAgentSession)] = [:]
    private static let lock = NSLock()
    private static var installedDirectory: URL?

    static var directory: URL { TerminalSavedTabs.directory.appendingPathComponent("agent-integration", isDirectory: true) }
    static var helper: String { Bundle.main.executableURL!.path }
    static let environmentKeys = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR", "PI_AGENT_DIR"]

    static func configure(_ config: inout Ghostty.SurfaceConfiguration, surface: UUID) {
        do {
            let bin = try install()
            config.environmentVariables["GHOSTTY_AGENT_BIN_DIR"] = bin.path
            config.environmentVariables["GHOSTTY_AGENT_HELPER"] = helper
            config.environmentVariables["GHOSTTY_AGENT_SURFACE"] = surface.uuidString
        } catch {
            AppDelegate.logger.error("Cannot install agent session helpers: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func install() throws -> URL {
        if let installedDirectory { return installedDirectory }
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let script = """
        #!/bin/sh
        set -f
        kind=${0##*/}
        old_ifs=$IFS
        IFS=:
        for dir in $PATH; do
            [ "$dir" = "$GHOSTTY_AGENT_BIN_DIR" ] && continue
            [ "$dir/$kind" -ef "$0" ] && continue
            [ -n "$dir" ] || dir=.
            if [ -f "$dir/$kind" ] && [ -x "$dir/$kind" ]; then
                IFS=$old_ifs
                exec "$GHOSTTY_AGENT_HELPER" --ghostty-agent-launch "$kind" "$dir/$kind" "$@"
            fi
        done
        printf 'Ghostty: %s executable not found in PATH\\n' "$kind" >&2
        exit 127
        """
        for kind in TerminalAgentSession.Kind.allCases {
            let url = bin.appendingPathComponent(kind.rawValue)
            try writeOwned(Data(script.utf8), to: url, mode: 0o700)
        }
        let resumeScript = """
        #!/bin/sh
        export GHOSTTY_AGENT_RESUME_TOKEN="$1"
        exec "$GHOSTTY_AGENT_HELPER" --ghostty-agent-resume
        """
        try writeOwned(Data(resumeScript.utf8), to: bin.appendingPathComponent("ghostty-resume-saved-agent"), mode: 0o700)
        let extensionSource = """
        import { execFileSync } from "node:child_process";
        export default function (pi) {
            pi.on("session_start", (_event, ctx) => {
                if (!ctx.hasUI || process.pid !== Number(process.env.GHOSTTY_AGENT_OWNER_PID)) return;
                const session = ctx.sessionManager.getSessionFile();
                if (!session || !process.env.GHOSTTY_AGENT_HELPER) return;
                try {
                    execFileSync(process.env.GHOSTTY_AGENT_HELPER,
                        ["--ghostty-agent-report", session, ctx.cwd, ctx.sessionManager.getSessionId()],
                        { stdio: ["ignore", "ignore", "ignore"], timeout: 3000 });
                } catch {}
            });
        }
        """
        try writeOwned(Data(extensionSource.utf8), to: directory.appendingPathComponent("pi-session.mjs"), mode: 0o600)
        installedDirectory = bin
        return bin
    }

    static func writeOwned(_ data: Data, to url: URL, mode: Int) throws {
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Runs before AppKit or libghostty initialization, including in hook subprocesses.
    static func handleCommandLine() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, command.hasPrefix("--ghostty-agent-") else { return }
        do {
            if command == "--ghostty-agent-launch", args.count >= 3,
               let kind = TerminalAgentSession.Kind(rawValue: args[1]) {
                try launch(kind: kind, executable: args[2], arguments: Array(args.dropFirst(3)))
            } else if command == "--ghostty-agent-resume" {
                guard let json = ProcessInfo.processInfo.environment["GHOSTTY_AGENT_RESUME"],
                      let data = json.data(using: .utf8) else { throw CocoaError(.coderInvalidValue) }
                let session = try JSONDecoder().decode(TerminalAgentSession.self, from: data)
                guard session.isValid, session.hasExistingConversation,
                      chdir(session.directory) == 0 else {
                    throw CocoaError(.fileReadNoPermission)
                }
                for (key, value) in session.environment { setenv(key, value, 1) }
                unsetenv("GHOSTTY_AGENT_RESUME")
                try launch(kind: session.kind, executable: session.executable, arguments: session.resumeArguments)
            } else if command == "--ghostty-agent-report" {
                try report(arguments: Array(args.dropFirst()))
                exit(0)
            } else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
        } catch {
            FileHandle.standardError.write(Data("Ghostty agent integration: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func launch(kind: TerminalAgentSession.Kind, executable: String, arguments: [String]) throws {
        var argv = arguments
        let env = ProcessInfo.processInfo.environment
        if let surface = env["GHOSTTY_AGENT_SURFACE"].flatMap(UUID.init(uuidString:)),
           let options = savedOptions(kind: kind, arguments: arguments),
           let identity = TerminalAppIcon.ProcessInspector.identity(pid: getpid()) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let token = UUID()
                let record = Launch(token: token, surface: surface, pid: getpid(), startTime: identity.startTime,
                    kind: kind, executable: URL(fileURLWithPath: executable).standardizedFileURL.path,
                    arguments: options, environment: env.filter { environmentKeys.contains($0.key) },
                    directory: FileManager.default.currentDirectoryPath,
                    resumeToken: env["GHOSTTY_AGENT_RESUME_TOKEN"].flatMap(UUID.init(uuidString:)))
                let path = directory.appendingPathComponent("\(surface.uuidString).json")
                try writeOwned(try JSONEncoder().encode(record), to: path, mode: 0o600)
                setenv("GHOSTTY_AGENT_TOKEN", token.uuidString, 1)
                setenv("GHOSTTY_AGENT_OWNER_PID", String(getpid()), 1)
                setenv("GHOSTTY_AGENT_RECORD", path.path, 1)
                if kind == .pi {
                    argv = ["--extension", directory.appendingPathComponent("pi-session.mjs").path] + argv
                } else if kind == .claude {
                    let hook = ["hooks": ["SessionStart": [["hooks": [["type": "command",
                        "command": Ghostty.Shell.quote(helper) + " --ghostty-agent-report"]]]]]]
                    let json = try JSONSerialization.data(withJSONObject: hook)
                    guard let settings = String(data: json, encoding: .utf8) else { throw CocoaError(.coderInvalidValue) }
                    argv = ["--settings", settings] + argv
                } else {
                    // Codex's standalone process owns its rollout descriptor. Its shared
                    // daemon cannot be mapped back to a terminal by inspecting that fd.
                    if !argv.contains("--no-daemon") { argv = ["--no-daemon"] + argv }
                }
            } catch {
                argv = arguments
                FileHandle.standardError.write(Data("Ghostty could not capture this agent session; running without restoration.\n".utf8))
            }
        }
        // Nested agents must not overwrite the terminal's top-level conversation.
        unsetenv("GHOSTTY_AGENT_SURFACE")
        unsetenv("GHOSTTY_AGENT_RESUME_TOKEN")
        let strings = ([executable] + argv).map { strdup($0) }
        defer { for string in strings { free(string) } }
        var cArguments = strings + [nil]
        execv(executable, &cArguments)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }

    private static func report(arguments: [String]) throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["GHOSTTY_AGENT_RECORD"],
              let token = env["GHOSTTY_AGENT_TOKEN"].flatMap(UUID.init(uuidString:)),
              URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        else { throw CocoaError(.fileReadNoPermission) }
        let url = URL(fileURLWithPath: path)
        var record = try JSONDecoder().decode(Launch.self, from: Data(contentsOf: url))
        guard record.token == token,
              TerminalAppIcon.ProcessInspector.identity(pid: record.pid)?.startTime == record.startTime
        else { throw CocoaError(.fileReadNoPermission) }
        if record.kind == .pi {
            guard arguments.count == 3, arguments[0].hasPrefix("/"), arguments[0].hasSuffix(".jsonl"),
                  UUID(uuidString: arguments[2]) != nil else {
                throw CocoaError(.coderInvalidValue)
            }
            record.session = arguments[0]
            record.directory = arguments[1]
            record.nativeSessionID = arguments[2]
        } else {
            let input = FileHandle.standardInput.readData(ofLength: 64 * 1024)
            guard let json = try JSONSerialization.jsonObject(with: input) as? [String: Any],
                  let session = json["session_id"] as? String, UUID(uuidString: session) != nil,
                  json["hook_event_name"] as? String == "SessionStart" else {
                throw CocoaError(.coderInvalidValue)
            }
            record.session = session
            if let cwd = json["cwd"] as? String { record.directory = cwd }
        }
        try writeOwned(try JSONEncoder().encode(record), to: url, mode: 0o600)
    }

    /// Only known, non-secret launch options survive; positional prompts never do.
    static func savedOptions(kind: TerminalAgentSession.Kind, arguments: [String]) -> [String]? {
        var values: Set<String> = ["--model", "-m"]
        var flags: Set<String> = []
        var selectors: Set<String> = []
        switch kind {
        case .claude:
            values.formUnion(["--permission-mode", "--effort", "--agent", "--setting-sources"])
            flags.formUnion(["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"])
            selectors = ["--session-id"]
        case .codex:
            values.formUnion(["--profile", "-p", "--sandbox", "-s", "--ask-for-approval", "-a", "--local-provider"])
            flags.formUnion(["--dangerously-bypass-approvals-and-sandbox", "--no-alt-screen", "--oss", "--no-daemon"])
        case .pi:
            values.formUnion(["--provider", "--thinking", "--session-dir"])
            flags = ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes"]
            selectors = ["--session"]
        }
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let option = parts[0]
            if ["--help", "-h", "--version", "-v", "-V", "--print", "--mode", "--no-session"].contains(option) { return nil }
            if option == "-p", kind != .codex { return nil }
            if option == "--settings" || option == "--bare" { return nil }
            if kind == .codex && ["exec", "e", "review", "app-server", "login", "logout", "mcp", "mcp-server", "help", "features", "fork"].contains(option) { return nil }
            if kind == .pi && ["--resume", "-r"].contains(option) {
                index += 1
                continue
            }
            if kind == .claude && ["--resume", "-r"].contains(option) {
                if parts.count == 1, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    index += 1
                }
                index += 1
                continue
            }
            if kind == .codex && option == "resume" {
                index += 1
                if index < arguments.count && !arguments[index].hasPrefix("-") { index += 1 }
                continue
            }
            if kind == .codex && ["-c", "--config"].contains(option) {
                let assignment: String
                if parts.count == 2 { assignment = parts[1] } else {
                    index += 1
                    guard index < arguments.count else { return nil }
                    assignment = arguments[index]
                }
                let key = assignment.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
                let allowed = ["model", "model_provider", "model_reasoning_effort", "model_reasoning_summary",
                    "sandbox_mode", "approval_policy"]
                guard let key, allowed.contains(key), assignment.contains("="),
                      !Ghostty.Shell.containsControlCharacters(assignment) else { return nil }
                result += ["--config", assignment]
            } else if values.contains(option) || selectors.contains(option) {
                let value: String
                if parts.count == 2 { value = parts[1] } else {
                    index += 1
                    guard index < arguments.count else { return nil }
                    value = arguments[index]
                }
                if values.contains(option) {
                    guard !Ghostty.Shell.containsControlCharacters(value) else { return nil }
                    result += [option, value]
                }
            } else if flags.contains(option) {
                result.append(option)
            } else if ["--continue", "-c", "--last", "--all"].contains(option) && kind != .codex {
                // A session selector is replaced by the exact captured identity.
            } else if ["--last", "--all"].contains(option) && kind == .codex {
            } else if argument.hasPrefix("-") {
                // An unknown option may consume a value or change launch semantics.
                return nil
            }
            index += 1
        }
        if kind == .pi && result.contains("--no-extensions") { return nil }
        return result
    }

    static func snapshot(surface: UUID, pid: pid_t?) -> TerminalAgentRestoration? {
        guard let pid else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = snapshots[surface], entry.0 == pid else { return nil }
        return entry.1
    }

    static func confirmedSession(surface: UUID, token: UUID) -> TerminalAgentSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = confirmations[surface], entry.0 == token else { return nil }
        return entry.1
    }

    static func refresh(_ surfaces: [Ghostty.SurfaceView], completion: @escaping () -> Void) {
        let requests = MainActor.assumeIsolated {
            surfaces.compactMap { surface -> (UUID, pid_t?)? in
                guard let model = surface.surfaceModel else { return nil }
                return (surface.id, model.foregroundPID.flatMap(pid_t.init(exactly:)))
            }
        }
        queue.async {
            capture(requests)
            DispatchQueue.main.async {
                for surface in surfaces { surface.updateSavedAgentStatus() }
                completion()
            }
        }
    }

    static func refreshSynchronously(_ surfaces: [Ghostty.SurfaceView]) {
        let requests = MainActor.assumeIsolated {
            surfaces.compactMap { surface -> (UUID, pid_t?)? in
                guard let model = surface.surfaceModel else { return nil }
                return (surface.id, model.foregroundPID.flatMap(pid_t.init(exactly:)))
            }
        }
        queue.sync { capture(requests) }
        MainActor.assumeIsolated {
            for surface in surfaces { surface.updateSavedAgentStatus() }
        }
    }

    private static func capture(_ requests: [(UUID, pid_t?)]) {
        var captured: [UUID: (pid_t, TerminalAgentRestoration)] = [:]
        var confirmed: [UUID: (UUID, TerminalAgentSession)] = [:]
        for (surface, pid) in requests {
            let process = TerminalAppIcon.ProcessInspector.self
            let path = directory.appendingPathComponent("\(surface.uuidString).json")
            if var record = try? JSONDecoder().decode(Launch.self, from: Data(contentsOf: path)), record.surface == surface {
                let alive = process.identity(pid: record.pid)?.startTime == record.startTime
                let ownsForeground = pid.map { $0 == record.pid || descendants(of: record.pid).contains($0) } ?? false
                if alive, ownsForeground, record.kind == .codex, let pid {
                    let processes = descendants(of: record.pid).union([pid, record.pid])
                    let ids = Set(processes.compactMap { codexSession(pid: $0) })
                    record.session = ids.count == 1 ? ids.first : nil
                }
                let session = record.session.map {
                    TerminalAgentSession(kind: record.kind, session: $0, executable: record.executable,
                        arguments: record.arguments, environment: record.environment, directory: record.directory,
                        nativeSessionID: record.nativeSessionID)
                }
                // Retries share a recovery token, but each invocation authenticates reports separately.
                if let session, let resumeToken = record.resumeToken { confirmed[surface] = (resumeToken, session) }
                if alive, ownsForeground, let pid {
                    captured[surface] = (pid, .init(session: session,
                        issue: session == nil ? "The agent has not reported an exact session ID. Restart it through Ghostty's integrated shell before quitting." : nil))
                    continue
                }
            }
            if let pid {
                let icon = TerminalAppIcon.classify(executablePath: process.executablePath(pid: pid), arguments: process.arguments(pid: pid))
                if [.claude, .codex, .pi].contains(icon) {
                    captured[surface] = (pid, .init(issue: "Exact session identity is unavailable. Restart this agent through Ghostty's integrated shell before quitting."))
                }
            }
        }
        lock.lock()
        snapshots = captured
        confirmations = confirmed
        lock.unlock()
    }

    private static func descendants(of pid: pid_t) -> Set<pid_t> {
        var found: Set<pid_t> = []
        var pending = [pid]
        while let parent = pending.popLast(), found.count < 128 {
            var children = [pid_t](repeating: 0, count: 128)
            let size = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard size > 0 else { continue }
            for child in children.prefix(Int(size) / MemoryLayout<pid_t>.size) where child > 0 && found.insert(child).inserted {
                pending.append(child)
            }
        }
        return found
    }

    fileprivate static func readHeader(_ path: String, matching expected: vinfo_stat? = nil) -> [String: Any]? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { return nil }
        if let expected {
            guard metadata.st_ino == expected.vst_ino,
                  UInt32(bitPattern: metadata.st_dev) == expected.vst_dev else { return nil }
        }
        var header = Data()
        let maximumHeaderBytes = 4 * 1024 * 1024
        while header.count < maximumHeaderBytes {
            guard let chunk = try? file.read(upToCount: min(4096, maximumHeaderBytes - header.count)),
                  !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 10) {
                header.append(contentsOf: chunk[..<newline])
                break
            }
            header.append(chunk)
        }
        return (try? JSONSerialization.jsonObject(with: header)) as? [String: Any]
    }

    static func codexSession(pid: pid_t) -> String? {
        let count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard count > 0 else { return nil }
        let capacity = Int(count) / MemoryLayout<proc_fdinfo>.size
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, count)
        guard size > 0 else { return nil }
        var sessions: Set<String> = []
        for descriptor in descriptors.prefix(Int(size) / MemoryLayout<proc_fdinfo>.size) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let bytes = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, bytes) == bytes else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            // proc_fileinfo uses the kernel FWRITE bit, not userspace O_* modes.
            guard info.pfi.fi_openflags & 0x2 != 0, path.hasSuffix(".jsonl"),
                  URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") else { continue }
            guard let json = readHeader(path, matching: info.pvip.vip_vi.vi_stat),
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  payload["source"] as? String == "cli",
                  let id = payload["id"] as? String, UUID(uuidString: id) != nil else { continue }
            sessions.insert(id)
        }
        return sessions.count == 1 ? sessions.first : nil
    }
}
