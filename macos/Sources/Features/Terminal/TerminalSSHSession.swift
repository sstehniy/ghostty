import AppKit
import Darwin

struct TerminalSSHSession: Codable, Equatable {
    var program: String
    var arguments: [String]
    var destination: String
    var remoteDirectory: String?

    var isValid: Bool {
        guard program == "ssh" || (program.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: program)),
              !Ghostty.Shell.containsControlCharacters(destination),
              let parsed = TerminalSSHDetection.parse(executablePath: nil, arguments: [program] + arguments),
              parsed.session.arguments == arguments,
              parsed.session.destination == destination else { return false }
        return remoteDirectory.map(Self.isValidDirectory) ?? true
    }

    static func isValidDirectory(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 1024 && !path.contains("\\") &&
            !Ghostty.Shell.containsControlCharacters(path)
    }

    static func remoteCommand(for directory: String) -> String {
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "cd \(quoted); exec \"$SHELL\" -l"
    }

    static func directory(fromRemoteCommand command: String) -> String? {
        let prefix = "cd '"
        let suffix = "'; exec \"$SHELL\" -l"
        guard command.hasPrefix(prefix), command.hasSuffix(suffix),
              command.count >= prefix.count + suffix.count else { return nil }
        let escaped = String(command.dropFirst(prefix.count).dropLast(suffix.count))
        let directory = escaped.replacingOccurrences(of: "'\"'\"'", with: "'")
        // Only accept our exact encoding, never arbitrary shell syntax around a path.
        guard isValidDirectory(directory), remoteCommand(for: directory) == command else { return nil }
        return directory
    }
}

enum TerminalSSHDetection {
    struct Parsed {
        var session: TerminalSSHSession
        var wrapped: Bool
        var sshOverride: String?
        var requestsTTY: Bool
    }

    struct Detected {
        var session: TerminalSSHSession
        var sshExecutable: String
        var localShell: String?
    }

    static func isSSH(executablePath: String?, arguments: [String]) -> Bool {
        let names = [executablePath, arguments.first].compactMap { $0 }.map { URL(fileURLWithPath: $0).lastPathComponent }
        return names.contains("ssh") || (names.contains("ghostty") && arguments.dropFirst().first == "+ssh")
    }

    static func parse(executablePath: String?, arguments: [String]) -> Parsed? {
        parse(executablePath: executablePath, arguments: arguments, allowRefused: false)
    }

    static func destination(executablePath: String?, arguments: [String]) -> String? {
        parse(executablePath: executablePath, arguments: arguments, allowRefused: true)?.session.destination
    }

    private static func parse(executablePath: String?, arguments: [String], allowRefused: Bool) -> Parsed? {
        guard isSSH(executablePath: executablePath, arguments: arguments), !arguments.isEmpty,
              !arguments.contains(where: Ghostty.Shell.containsControlCharacters) else { return nil }
        let wrapped = arguments.dropFirst().first == "+ssh" &&
            [executablePath, arguments.first].compactMap { $0 }.contains { URL(fileURLWithPath: $0).lastPathComponent == "ghostty" }
        var index = wrapped ? 2 : 1
        var sshOverride: String?
        if wrapped {
            while index < arguments.count, arguments[index].hasPrefix("--") {
                let flag = arguments[index]
                index += 1
                if flag == "--" { break }
                if flag.hasPrefix("--ssh=") { sshOverride = String(flag.dropFirst(6)) }
            }
        }
        var sanitized: [String] = []
        var login: String?
        var refused = false
        var requestsTTY = false
        let noValue = Set("46AaCfGgKkMNnqsTtVvXxYy")
        let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw")
        let forbidden = Set("NfGVQOWsTn")
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            if arg == "--" {
                sanitized.append(arg)
                break
            }
            if !arg.hasPrefix("-") || arg == "-" {
                index -= 1
                break
            }
            let letters = Array(arg.dropFirst())
            var kept = "-"
            var offset = 0
            while offset < letters.count {
                let flag = letters[offset]
                offset += 1
                guard noValue.contains(flag) || takesValue.contains(flag) else { return nil }
                if forbidden.contains(flag) { refused = true }
                if flag == "t" { requestsTTY = true }
                if takesValue.contains(flag) {
                    let attached = offset < letters.count
                    let value: String
                    if attached {
                        value = String(letters[offset...])
                    } else {
                        guard index < arguments.count else { return nil }
                        value = arguments[index]
                        index += 1
                    }
                    let key = value.split(whereSeparator: { $0 == "=" || $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
                    if flag == "o", ["remotecommand", "sessiontype", "forkafterauthentication", "stdinnull"].contains(key) {
                        refused = true
                    }
                    let strip = "LRD".contains(flag) || (flag == "o" &&
                        ["localforward", "remoteforward", "dynamicforward", "controlmaster"].contains(key))
                    if !strip {
                        kept.append(flag)
                        if attached {
                            kept += value
                        } else {
                            sanitized += [kept, value]
                            kept = "-"
                        }
                    }
                    if flag == "l" { login = value }
                    break
                }
                if flag != "M" { kept.append(flag) }
            }
            if kept != "-" { sanitized.append(kept) }
        }
        guard index < arguments.count else { return nil }
        let host = arguments[index]
        guard !host.isEmpty else { return nil }
        sanitized.append(host)
        var remoteDirectory: String?
        if index + 1 < arguments.count {
            if index + 2 == arguments.count {
                remoteDirectory = TerminalSSHSession.directory(fromRemoteCommand: arguments[index + 1])
            }
            if remoteDirectory == nil { refused = true }
        }
        guard allowRefused || !refused else { return nil }
        var destination = host.hasPrefix("ssh://") ? String(host.dropFirst(6)) : host
        if let login, !destination.contains("@") { destination = login + "@" + destination }
        let program = !wrapped && arguments[0].hasPrefix("/") ? arguments[0] : "ssh"
        return Parsed(session: TerminalSSHSession(program: program, arguments: sanitized, destination: destination, remoteDirectory: remoteDirectory),
                      wrapped: wrapped, sshOverride: sshOverride, requestsTTY: requestsTTY)
    }

    @MainActor static func detect(for surface: Ghostty.SurfaceView) -> Detected? {
        guard let model = surface.surfaceModel, let pid = model.foregroundPID.flatMap(pid_t.init(exactly:)) else { return nil }
        let inspector = TerminalAppIcon.ProcessInspector.self
        let executable = inspector.executablePath(pid: pid)
        guard var parsed = parse(executablePath: executable, arguments: inspector.arguments(pid: pid)) else { return nil }
        if let directory = model.remotePwd, TerminalSSHSession.isValidDirectory(directory) {
            parsed.session.remoteDirectory = directory
        }
        var ssh = executable ?? "/usr/bin/ssh"
        if parsed.wrapped {
            ssh = inspector.childPIDs(pid: pid).compactMap { inspector.executablePath(pid: $0) }
                .first { URL(fileURLWithPath: $0).lastPathComponent == "ssh" } ??
                parsed.sshOverride.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/usr/bin/ssh"
        }
        let shell = inspector.parentPID(pid: pid).flatMap { inspector.executablePath(pid: $0) }
        guard model.foregroundPID == Int(pid) else { return nil }
        return Detected(session: parsed.session, sshExecutable: ssh, localShell: shell)
    }

    @MainActor static func session(for surface: Ghostty.SurfaceView) -> TerminalSSHSession? {
        detect(for: surface)?.session
    }
}

enum TerminalSSHReconnect {
    struct EffectiveConfiguration {
        var remoteCommand = false
        var forwards = false
        var refused = false

        init(_ output: String) {
            for line in output.split(separator: "\n") {
                let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard fields.count == 2 else { continue }
                let key = fields[0].lowercased()
                let value = fields[1].trimmingCharacters(in: .whitespaces).lowercased()
                switch key {
                case "remotecommand": remoteCommand = value != "none"
                case "localforward", "remoteforward", "dynamicforward": forwards = true
                case "sessiontype": if value != "default" { refused = true }
                case "forkafterauthentication": if value == "yes" { refused = true }
                default: break
                }
            }
        }
    }

    @MainActor static func inherit(
        from surface: Ghostty.SurfaceView,
        to config: inout Ghostty.SurfaceConfiguration,
        waitAfterCommand: Bool
    ) {
        guard let detected = TerminalSSHDetection.detect(for: surface) else { return }
        apply(detected.session, sshExecutable: detected.sshExecutable, localShell: detected.localShell,
              to: &config, waitAfterCommand: waitAfterCommand)
    }

    static func apply(
        _ session: TerminalSSHSession,
        sshExecutable: String,
        localShell: String?,
        to config: inout Ghostty.SurfaceConfiguration,
        waitAfterCommand: Bool = false,
        runner: (String, [String]) -> String? = effectiveConfiguration
    ) {
        guard session.isValid, !Ghostty.Shell.containsControlCharacters(sshExecutable) else { return }
        let effective = runner(sshExecutable, ["-G"] + session.arguments).map(EffectiveConfiguration.init)
        guard effective?.refused != true else { return }
        var argv = [session.program]
        let directory = effective.flatMap { $0.remoteCommand ? nil : session.remoteDirectory }
        let requestsTTY = TerminalSSHDetection.parse(executablePath: nil, arguments: [session.program] + session.arguments)?.requestsTTY == true
        if directory != nil, !requestsTTY {
            argv.append("-t")
        }
        if effective?.forwards == true { argv += ["-o", "ClearAllForwardings=yes"] }
        argv += session.arguments
        if let directory {
            argv.append(TerminalSSHSession.remoteCommand(for: directory))
        }
        let line = argv.map(Ghostty.Shell.quote).joined(separator: " ")
        guard !Ghostty.Shell.containsControlCharacters(line) else { return }
        let shell = localShell.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        if ["bash", "zsh", "sh", "dash", "ksh", "fish"].contains(shell),
           !(shell == "fish" && argv.contains(where: { $0.contains("\\") })) {
            config.initialInput = line + "\n"
        } else {
            config.command = line
            config.initialInput = nil
            // Explicit commands otherwise force wait-after-command in the embedded runtime.
            config.closeOnExit = config.closeOnExit || !(waitAfterCommand || config.waitAfterCommand)
        }
    }

    /// Drain stdout while waiting so even a large ssh_config cannot fill the pipe.
    static func effectiveConfiguration(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        let deadline = DispatchTime.now() + .milliseconds(300)
        do { try process.run() } catch { return nil }
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            if DispatchTime.now() >= deadline || output.count > 1_048_576 {
                kill(process.processIdentifier, SIGKILL)
                return nil
            }
            if count <= 0, !process.isRunning { break }
            if count <= 0 {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 5)
            }
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
