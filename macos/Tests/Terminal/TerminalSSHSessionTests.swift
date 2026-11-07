import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct TerminalSSHSessionTests {
    @Test(arguments: [
        (["ssh", "host"], ["host"], "host"),
        (["ssh", "-p", "22", "user@host"], ["-p", "22", "user@host"], "user@host"),
        (["ssh", "-p22", "-A", "host"], ["-p22", "-A", "host"], "host"),
        (["ssh", "-l", "me", "host"], ["-l", "me", "host"], "me@host"),
        (["ssh", "ssh://me@host:2222"], ["ssh://me@host:2222"], "me@host:2222"),
        (["ssh", "-vvt", "host"], ["-vvt", "host"], "host"),
        (["ssh", "--", "host"], ["--", "host"], "host"),
        (["ghostty", "+ssh", "--terminfo=false", "--", "-J", "bastion", "host"], ["-J", "bastion", "host"], "host"),
        (["ghostty", "+ssh", "--ssh=/usr/bin/ssh", "-Ap2222", "host"], ["-Ap2222", "host"], "host"),
        (["ssh", "-L", "8080:x:80", "-vMD1080", "-R9000:x:80", "-A", "-S", "/tmp/control",
          "-o", "LocalForward=8081 x:81", "-oControlMaster=yes", "-o", "ServerAliveInterval 30", "host"],
         ["-v", "-A", "-S", "/tmp/control", "-o", "ServerAliveInterval 30", "host"], "host"),
    ])
    func parsesAndSanitizes(argv: [String], expected: [String], destination: String) throws {
        let parsed = try #require(TerminalSSHDetection.parse(executablePath: nil, arguments: argv))
        #expect(parsed.session.program == "ssh")
        #expect(parsed.session.arguments == expected)
        #expect(parsed.session.destination == destination)
        #expect(parsed.session.isValid)
    }

    @Test(arguments: [
        ["ssh", "host", "ls"], ["ssh", "-N", "-L", "8080:x:80", "host"], ["ssh", "-f", "host"],
        ["ssh", "-G", "host"], ["ssh", "-V", "host"], ["ssh", "-Q", "cipher", "host"],
        ["ssh", "-O", "check", "host"], ["ssh", "-W", "host:22", "host"], ["ssh", "-s", "host"],
        ["ssh", "-T", "host"], ["ssh", "-n", "host"], ["ssh", "-o", "RemoteCommand=tmux", "host"],
        ["ssh", "-oSESSIONtype default", "host"], ["ssh", "-o", "ForkAfterAuthentication=no", "host"],
        ["ssh", "-oStdinNull=no", "host"], ["ssh"], ["ssh", "-Z", "host"], ["ssh", "-p"],
        ["ssh", "ho\nst"], ["ssh", "-i", "bad\u{85}key", "host"], ["mosh", "host"],
    ])
    func refusesUnsafeOrNoninteractiveSessions(argv: [String]) {
        #expect(TerminalSSHDetection.parse(executablePath: nil, arguments: argv) == nil)
    }

    @Test func recognizesExecutableAndKeepsAbsoluteProgram() throws {
        let parsed = try #require(TerminalSSHDetection.parse(executablePath: "/usr/bin/ssh", arguments: ["/usr/bin/ssh", "host"]))
        #expect(parsed.session.program == "/usr/bin/ssh")
        #expect(TerminalSSHDetection.parse(executablePath: "/usr/bin/ssh", arguments: ["alias", "host"])?.session.program == "ssh")
        #expect(TerminalSSHDetection.destination(executablePath: nil, arguments: ["ssh", "-N", "-lme", "host"]) == "me@host")
    }

    @Test func effectiveConfigurationControlsReconnect() {
        let session = TerminalSSHSession(program: "ssh", arguments: ["host"], destination: "host", remoteDirectory: "/srv")
        let cases: [(String?, String?)] = [
            ("sessiontype default\nremotecommand none\n", #"ssh -t host 'cd '"'"'/srv'"'"'; exec "$SHELL" -l'"# + "\n"),
            ("remotecommand tmux new -A\nlocalforward 8080 x:80\n", "ssh -o ClearAllForwardings=yes host\n"),
            ("sessiontype none\n", nil), ("sessiontype subsystem\n", nil), ("forkafterauthentication yes\n", nil),
            (nil, "ssh host\n"),
        ]
        for (output, expected) in cases {
            var config = Ghostty.SurfaceConfiguration()
            TerminalSSHReconnect.apply(session, sshExecutable: "/usr/bin/ssh", localShell: "/bin/zsh", to: &config) { _, _ in output }
            #expect(config.initialInput == expected)
        }
        for key in ["localforward", "remoteforward", "dynamicforward"] {
            #expect(TerminalSSHReconnect.EffectiveConfiguration("\(key) 8080 host:80").forwards)
        }
    }

    @Test(arguments: ["/bin/bash", "/bin/zsh", "/usr/local/bin/fish"])
    func typedReconnectPreservesFloatShellAndLocalConfiguration(shell: String) {
        let session = TerminalSSHSession(program: "ssh", arguments: ["host"], destination: "host", remoteDirectory: "/srv/a b")
        var config = Ghostty.SurfaceConfiguration()
        config.command = shell
        config.workingDirectory = "/tmp"
        config.fontSize = 17
        config.closeOnExit = true
        TerminalSSHReconnect.apply(session, sshExecutable: "/usr/bin/ssh", localShell: shell, to: &config) { _, _ in "sessiontype default\n" }
        #expect(config.initialInput == #"ssh -t host 'cd '"'"'/srv/a b'"'"'; exec "$SHELL" -l'"# + "\n")
        #expect(config.command == shell)
        #expect(config.workingDirectory == "/tmp")
        #expect(config.fontSize == 17)
        #expect(config.closeOnExit)
    }

    @Test(arguments: [["-t"], ["-tt"], ["-vvt"], ["-i/tmp/key"]])
    func requestsTTYExactlyOnce(options: [String]) throws {
        let session = TerminalSSHSession(program: "ssh", arguments: options + ["host"], destination: "host", remoteDirectory: "/srv")
        var config = Ghostty.SurfaceConfiguration()
        TerminalSSHReconnect.apply(session, sshExecutable: "/usr/bin/ssh", localShell: "/bin/sh", to: &config) { _, _ in "sessiontype default" }
        let line = try #require(config.initialInput)
        #expect(line.hasPrefix("ssh -t ") == (options == ["-i/tmp/key"] || options == ["-t"]))
        #expect(!line.contains("-t -t"))
    }

    @Test func apostrophesRemainDataAcrossBothShells() throws {
        let session = TerminalSSHSession(program: "ssh", arguments: ["host"], destination: "host", remoteDirectory: "/srv/a'b c;$(echo bad)")
        var config = Ghostty.SurfaceConfiguration()
        TerminalSSHReconnect.apply(session, sshExecutable: "/usr/bin/ssh", localShell: "/bin/sh", to: &config) { _, _ in "sessiontype default" }
        let line = try #require(config.initialInput)
        let command = "ssh() { printf '%s\\0' \"$@\"; }; " + line
        let output = try #require(TerminalSSHReconnect.effectiveConfiguration("/bin/sh", arguments: ["-c", command]))
        #expect(output.split(separator: "\0").map(String.init) == ["-t", "host", #"cd '/srv/a'"'"'b c;$(echo bad)'; exec "$SHELL" -l"#])
    }

    @Test(arguments: [false, true])
    func generatedReconnectCanBeInheritedAndSavedAgain(wrapped: Bool) throws {
        let directory = "/srv/a'b c;$(echo data)"
        let original = TerminalSSHSession(program: "ssh", arguments: ["-J", "bastion", "host"], destination: "host", remoteDirectory: directory)
        var first = Ghostty.SurfaceConfiguration()
        TerminalSSHReconnect.apply(original, sshExecutable: "/usr/bin/ssh", localShell: "/bin/sh", to: &first) { _, _ in "sessiontype default" }
        let line = try #require(first.initialInput)
        let output = try #require(TerminalSSHReconnect.effectiveConfiguration("/bin/sh", arguments: ["-c", "ssh() { printf '%s\\0' \"$@\"; }; " + line]))
        let prefix = wrapped ? ["ghostty", "+ssh", "--terminfo=false", "--"] : ["ssh"]
        let argv = prefix + output.split(separator: "\0").map(String.init)
        #expect(TerminalSSHDetection.parse(executablePath: nil, arguments: argv + ["extra"]) == nil)
        let parsed = try #require(TerminalSSHDetection.parse(executablePath: nil, arguments: argv))
        #expect(parsed.session.arguments == ["-t", "-J", "bastion", "host"])
        #expect(parsed.session.remoteDirectory == directory)
        let saved = try JSONDecoder().decode(TerminalSSHSession.self, from: JSONEncoder().encode(parsed.session))
        #expect(saved.isValid)
        #expect(saved.remoteDirectory == directory)
        var second = Ghostty.SurfaceConfiguration()
        TerminalSSHReconnect.apply(saved, sshExecutable: "/usr/bin/ssh", localShell: "/bin/sh", to: &second) { _, _ in "sessiontype default" }
        #expect(second.initialInput == first.initialInput)
    }

    @Test(arguments: [
        #"cd '/srv'; exec "$SHELL" -l; touch /tmp/unwanted"#,
        #"cd '/srv'; exec "$SHELL" -l # extra"#,
        #"cd '/srv'$(touch /tmp/unwanted)''; exec "$SHELL" -l"#,
        #"cd '/srv'"$(touch /tmp/unwanted)"''; exec "$SHELL" -l"#,
        #"cd '/srv''; touch /tmp/unwanted; echo '''; exec "$SHELL" -l"#,
        #"cd '/bad\path'; exec "$SHELL" -l"#,
        #"cd 'relative'; exec "$SHELL" -l"#,
    ])
    func refusesCommandsImitatingGeneratedReconnect(command: String) {
        #expect(TerminalSSHDetection.parse(executablePath: nil, arguments: ["ssh", "host", command]) == nil)
    }

    @Test func unsupportedShellsAndFishBackslashesUseCommandMode() {
        for (shell, arguments) in [("/bin/nu", ["host"]), ("/bin/fish", ["-i", "a\\b", "host"]), ("", ["host"])] {
            let session = TerminalSSHSession(program: "ssh", arguments: arguments, destination: "host")
            var config = Ghostty.SurfaceConfiguration()
            TerminalSSHReconnect.apply(session, sshExecutable: "/usr/bin/ssh", localShell: shell, to: &config) { _, _ in nil }
            #expect(config.initialInput == nil)
            #expect(config.command == (arguments.count == 1 ? "ssh host" : #"ssh -i 'a\b' host"#))
        }
        var config = Ghostty.SurfaceConfiguration()
        let invalid = TerminalSSHSession(program: "ssh", arguments: ["bad\nhost"], destination: "bad\nhost")
        TerminalSSHReconnect.apply(invalid, sshExecutable: "/usr/bin/ssh", localShell: "/bin/sh", to: &config) { _, _ in
            Issue.record("Invalid data reached ssh -G")
            return nil
        }
        #expect(config.command == nil && config.initialInput == nil)
    }

    @Test func configRunnerHandlesSuccessFailureAndTimeout() {
        #expect(TerminalSSHReconnect.effectiveConfiguration("/usr/bin/printf", arguments: ["sessiontype default\n"]) == "sessiontype default\n")
        #expect(TerminalSSHReconnect.effectiveConfiguration("/usr/bin/false", arguments: []) == nil)
        let start = ContinuousClock.now
        #expect(TerminalSSHReconnect.effectiveConfiguration("/bin/sleep", arguments: ["2"]) == nil)
        #expect(start.duration(to: .now) < .seconds(1))
        let large = TerminalSSHReconnect.effectiveConfiguration("/usr/bin/awk", arguments: ["BEGIN { for (i=0;i<20000;i++) print \"host prod\" }"])
        #expect(large?.utf8.count == 200_000)
    }

    @Test func savedDataValidationRejectsCommandsControlsAndInvalidDirectories() throws {
        let valid = TerminalSSHSession(program: "ssh", arguments: ["host"], destination: "host", remoteDirectory: "/srv/a b")
        #expect(try JSONDecoder().decode(TerminalSSHSession.self, from: JSONEncoder().encode(valid)) == valid)
        for path in ["relative", "/bad\npath", "/bad\\path", "/" + String(repeating: "x", count: 1024)] {
            var invalid = valid
            invalid.remoteDirectory = path
            #expect(!invalid.isValid)
        }
        var invalid = valid
        invalid.arguments += ["ls"]
        #expect(!invalid.isValid)
        invalid = valid
        invalid.arguments = ["-L8080:x:80", "host"]
        #expect(!invalid.isValid)
        invalid = valid
        invalid.program = "./ssh"
        #expect(!invalid.isValid)
    }
}

@Suite(.serialized)
struct TerminalSSHRestorationTests {
    @MainActor @Test(arguments: [(false, false), (true, false), (true, true)])
    func commandModeReconnectHonorsNormalExitPolicy(waitAfterCommand: Bool, closeOnExit: Bool) async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = root.appendingPathComponent("ssh")
        try Data("#!/bin/sh\nsleep 1\nexit 0\n".utf8).write(to: ssh)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let session = TerminalSSHSession(program: ssh.path, arguments: ["host"], destination: "host")
        let policy = try TemporaryConfig("wait-after-command = \(waitAfterCommand)")
        var config = Ghostty.SurfaceConfiguration()
        config.closeOnExit = closeOnExit
        TerminalSSHReconnect.apply(session, sshExecutable: ssh.path, localShell: "/bin/nu",
                                   to: &config, waitAfterCommand: policy.waitAfterCommand) { _, _ in nil }
        let view = Ghostty.SurfaceView(app, baseConfig: config, deferTerminal: true)
        var didClose = false
        let observer = NotificationCenter.default.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: view, queue: nil) { _ in
            MainActor.assumeIsolated { didClose = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        view.startDeferredTerminal()
        let deadline = Date().addingTimeInterval(5)
        while !view.processExited, Date() < deadline {
            ghostty.appTick()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(view.processExited)
        #expect(didClose == (closeOnExit || !waitAfterCommand))
    }

    @MainActor @Test func liveForegroundDetectionKeepsRemoteCwdSeparateAndExpiresIt() async throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = root.appendingPathComponent("ssh")
        try FileManager.default.createSymbolicLink(at: ssh, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh"
        config.workingDirectory = "/tmp"
        config.initialInput = "(printf '\\033]7;file://localhost/tmp\\007\\033]7;file://remote.invalid/srv/a%%20b\\007'; exec \(Ghostty.Shell.quote(ssh.path)) 60)\n"
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        let deadline = Date().addingTimeInterval(3)
        while TerminalSSHDetection.session(for: view)?.remoteDirectory != "/srv/a b", Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let foreground = view.surfaceModel?.foregroundPID.flatMap(pid_t.init(exactly:))
        let argv = foreground.map { TerminalAppIcon.ProcessInspector.arguments(pid: $0) } ?? []
        let detected = try #require(TerminalSSHDetection.detect(for: view), "Foreground: \(argv), screen: \(view.cachedScreenContents.get())")
        #expect(detected.session.remoteDirectory == "/srv/a b")
        #expect(detected.session.program == ssh.path)
        #expect(detected.session.destination == "60")
        #expect(["/bin/sh", "/bin/bash"].contains(detected.localShell ?? ""))
        #expect(view.pwd == "/tmp")
        let model = try #require(view.surfaceModel)
        let pid = try #require(model.foregroundPID)
        for (action, name, inherits) in [
            ("new_tab", Ghostty.Notification.ghosttyNewTab, true),
            ("new_tab_local", Ghostty.Notification.ghosttyNewTab, false),
            ("new_split:right", Ghostty.Notification.ghosttyNewSplit, true),
            ("new_split_local", Ghostty.Notification.ghosttyNewSplit, false),
        ] {
            var created: Ghostty.SurfaceConfiguration?
            let observer = NotificationCenter.default.addObserver(forName: name, object: view, queue: nil) { notification in
                MainActor.assumeIsolated {
                    created = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            #expect(model.perform(action: action))
            let inherited = try #require(created)
            #expect(inherited.workingDirectory == "/tmp")
            #expect(inherited.initialInput == (inherits ? Ghostty.Shell.quote(ssh.path) + " 60\n" : nil))
        }
        #expect(model.perform(action: "text:\\x03"))
        while model.foregroundPID == pid, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.foregroundPID != pid)
        #expect(model.remotePwd == nil)
        #expect(TerminalSSHDetection.session(for: view) == nil)
    }

    @MainActor @Test func secondGenerationLiveRecipeSurvivesDurableSaveWithoutOSC7() async throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        let directory = "/srv/a'b c"
        // The proxy holds SSH at the handshake without contacting any host.
        let original = TerminalSSHSession(program: "/usr/bin/ssh",
            arguments: ["-F", "/dev/null", "-o", "ProxyCommand=exec /bin/sleep 60", "ghostty-test.invalid"],
            destination: "ghostty-test.invalid", remoteDirectory: directory)
        var config = Ghostty.SurfaceConfiguration()
        TerminalSSHReconnect.apply(original, sshExecutable: "/usr/bin/ssh", localShell: "/bin/sh", to: &config) { _, _ in "sessiontype default" }
        config.command = "/bin/sh"
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        let deadline = Date().addingTimeInterval(3)
        while TerminalSSHDetection.session(for: view) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let pid = view.surfaceModel?.foregroundPID.flatMap(pid_t.init(exactly:))
        let argv = pid.map { TerminalAppIcon.ProcessInspector.arguments(pid: $0) } ?? []
        let session = try #require(TerminalSSHDetection.session(for: view), "Foreground: \(argv), screen: \(view.cachedScreenContents.get())")
        #expect(session.destination == "ghostty-test.invalid")
        #expect(session.remoteDirectory == directory)
        #expect(view.surfaceModel?.remotePwd == nil)
        let encoder = JSONEncoder()
        encoder.userInfo[.durableTabSnapshot] = true
        let snapshot = try #require(JSONSerialization.jsonObject(with: encoder.encode(view)) as? [String: Any])
        let saved = try #require(snapshot["sshRestoration"])
        let recipe = try JSONDecoder().decode(TerminalSSHSession.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(recipe.isValid)
        #expect(recipe.remoteDirectory == directory)
    }

    @MainActor @Test func wakeReconnectsOnlyWhenEnabledAndNeverOnDecode() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = root.appendingPathComponent("ssh")
        let marker = root.appendingPathComponent("connected")
        let script = """
        #!/bin/sh
        if [ "$1" = -G ]; then printf 'sessiontype default\\n'; exit 0; fi
        printf '%s\\n' "$@" > \(Ghostty.Shell.quote(marker.path))
        """
        try Data(script.utf8).write(to: ssh)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let session = TerminalSSHSession(program: ssh.path, arguments: ["host"], destination: "host")
        let sshObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
        let original = try #require(ghostty.config.config)
        let backup = try #require(ghostty_config_clone(original))
        defer {
            if let restored = ghostty_config_clone(backup) { ghostty.config.clone(config: restored) }
            ghostty_config_free(backup)
        }
        for enabled in [false, true] {
            let configFile = root.appendingPathComponent("config")
            try Data("ssh-inherit-session = \(enabled)\n".utf8).write(to: configFile)
            let config = Ghostty.Config(at: configFile.path)
            let configured = try #require(config.config)
            ghostty.config.clone(config: try #require(ghostty_config_clone(configured)))
            let leaf: [String: Any] = ["uuid": UUID().uuidString, "pwd": root.path, "title": "Saved SSH", "sshRestoration": sshObject]
            let decoder = JSONDecoder()
            decoder.userInfo[.durableTabSnapshot] = true
            let view = try decoder.decode(Ghostty.SurfaceView.self, from: JSONSerialization.data(withJSONObject: leaf))
            #expect(view.surfaceModel == nil)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            view.startDeferredTerminal()
            ghostty.config.clone(config: try #require(ghostty_config_clone(backup)))
            let deadline = Date().addingTimeInterval(3)
            while enabled && !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(FileManager.default.fileExists(atPath: marker.path) == enabled)
            if enabled {
                let args = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map(String.init)
                #expect(args == ["host"])
            }
        }
    }

    @MainActor @Test func onlyDurableSnapshotsRetainValidatedSSHAndAgentWins() throws {
        let session = TerminalSSHSession(program: "ssh", arguments: ["host"], destination: "host", remoteDirectory: "/srv")
        let ssh = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
        let agent = TerminalAgentRestoration(session: .init(kind: .claude, session: UUID().uuidString,
            executable: "/usr/bin/true", arguments: [], environment: [:], directory: "/tmp"))
        let agentObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent))
        for (durable, withAgent, invalid) in [(true, false, false), (false, false, false), (true, true, false), (true, false, true)] {
            var leaf: [String: Any] = ["uuid": UUID().uuidString, "pwd": "/tmp", "title": "Saved SSH", "sshRestoration": ssh]
            if withAgent { leaf["agentRestoration"] = agentObject }
            if invalid { leaf["sshRestoration"] = ["program": "ssh", "arguments": ["host", "ls"], "destination": "host"] }
            let decoder = JSONDecoder()
            decoder.userInfo[.durableTabSnapshot] = durable
            let view = try decoder.decode(Ghostty.SurfaceView.self, from: JSONSerialization.data(withJSONObject: leaf))
            #expect((view.surfaceModel == nil) == durable)
            let encoder = JSONEncoder()
            encoder.userInfo[.durableTabSnapshot] = true
            let saved = try #require(JSONSerialization.jsonObject(with: encoder.encode(view)) as? [String: Any])
            #expect((saved["sshRestoration"] != nil) == (durable && !withAgent && !invalid))
            let ordinary = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as? [String: Any])
            #expect(ordinary["sshRestoration"] == nil)
        }
    }
}
