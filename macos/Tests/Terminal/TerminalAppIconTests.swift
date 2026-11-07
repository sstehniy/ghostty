import AppKit
import Foundation
import Testing
@testable import Ghostty

struct TerminalAppIconTests {
    @Test(arguments: [
        // Direct executables
        ("/opt/homebrew/bin/claude", ["claude"], TerminalAppIcon.claude),
        ("/Users/me/.local/share/claude/versions/2.0.14", ["claude"], .claude),
        ("/Users/me/.local/share/claude/versions/2.0.14", ["2.0.14"], .claude),
        ("/opt/homebrew/bin/codex", ["codex", "--model", "o3"], .codex),
        ("/x/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex", ["codex"], .codex),
        ("/usr/local/bin/codex-aarch64-apple-darwin", ["codex-aarch64-apple-darwin"], .codex),
        ("/Users/me/.npm-global/bin/pi", ["pi"], .pi),
        ("/Users/me/.opencode/bin/opencode", ["opencode"], .opencode),
        ("/x/node_modules/opencode-darwin-arm64/bin/opencode", ["opencode"], .opencode),
        ("/Users/me/.amp/bin/amp", ["amp"], .amp),
        ("/opt/homebrew/bin/gemini", ["gemini"], .gemini),
        ("/opt/homebrew/bin/copilot", ["copilot"], .copilot),
        ("/Users/me/.local/bin/cursor-agent", ["cursor-agent"], .cursor),
        ("/opt/homebrew/bin/qwen", ["qwen"], .qwen),
        ("/Users/me/.local/bin/kiro-cli", ["kiro-cli"], .kiro),
        ("/Users/me/.local/bin/kiro-cli-chat", ["kiro-cli-chat", "chat"], .kiro),
    ])
    func directExecutables(path: String, argv: [String], expected: TerminalAppIcon) {
        #expect(TerminalAppIcon.classify(executablePath: path, arguments: argv) == expected)
    }

    @Test(arguments: [
        // Node shebang launches: argv[1] is the script
        (["node", "/opt/homebrew/bin/claude"], TerminalAppIcon.claude),
        (["node", "--no-warnings", "/opt/homebrew/bin/codex"], .codex),
        (["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"], .claude),
        (["node", "/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"], .pi),
        (["node", "/Users/me/.npm-global/bin/pi"], .pi),
        (["npx", "@openai/codex"], .codex),
        (["npm", "exec", "@anthropic-ai/claude-code"], .claude),
        (["bun", "/Users/me/.bun/bin/claude"], .claude),
        (["node22", "/opt/homebrew/bin/codex"], .codex),
        (["node", "/usr/local/lib/node_modules/opencode-ai/bin/opencode"], .opencode),
        (["node", "/usr/local/lib/node_modules/@sourcegraph/amp/dist/main.js"], .amp),
        (["node", "/opt/homebrew/bin/gemini"], .gemini),
        (["npx", "@google/gemini-cli"], .gemini),
        (["node", "/usr/local/lib/node_modules/@github/copilot/index.js"], .copilot),
        (["node", "/Users/me/.local/share/cursor-agent/versions/2025.10.02/index.js"], .cursor),
        (["npx", "@qwen-code/qwen-code"], .qwen),
    ])
    func nodeLaunches(argv: [String], expected: TerminalAppIcon) {
        let path = "/opt/homebrew/bin/" + argv[0]
        #expect(TerminalAppIcon.classify(executablePath: path, arguments: argv) == expected)
    }

    @Test(arguments: [
        ("/bin/zsh", ["-zsh"]),
        ("/usr/bin/vim", ["vim", "claude.md"]),
        ("/opt/homebrew/bin/node", ["node", "server.js", "--name", "claude"]),
        ("/opt/homebrew/bin/node", ["node", "server.js"]),
        ("/usr/bin/python3", ["python3", "/opt/homebrew/bin/claude"]),
        ("/usr/local/bin/pip", ["pip"]),
        ("/usr/bin/vim", ["vim", "/Users/me/.local/share/cursor-agent/notes.md"]),
        ("/opt/homebrew/bin/node", ["node", "server.js", "--provider", "gemini"]),
    ])
    func unrecognizedProgramsFallBackToTerminal(path: String, argv: [String]) {
        #expect(TerminalAppIcon.classify(executablePath: path, arguments: argv) == .terminal)
    }

    @Test(arguments: [
        ["ssh", "host"], ["ssh", "-N", "host"], ["ssh", "host", "ls"],
        ["ghostty", "+ssh", "--terminfo=false", "--", "host"],
    ])
    func sshShowsRemoteBadge(argv: [String]) {
        #expect(TerminalAppIcon.classify(executablePath: nil, arguments: argv) == .remote)
    }

    @Test func remoteLabelsUseRemoteNotLocalDirectory() {
        let result = TerminalAppIconResolver.Resolution(icon: .remote, destination: "me@host")
        #expect(result.remoteLabel(directory: nil) == "me@host")
        #expect(result.remoteLabel(directory: "/srv/a b") == "me@host:/srv/a b")
        #expect(TerminalAppIconResolver.Resolution().remoteLabel(directory: "/local") == nil)
    }

    @Test func unknownProcessFallsBackToTerminal() {
        #expect(TerminalAppIcon.classify(executablePath: nil, arguments: []) == .terminal)
    }

    @Test func bundledAssetsExist() {
        for icon in TerminalAppIcon.allCases {
            guard let name = icon.assetName else { continue }
            #expect(NSImage(named: name) != nil, "missing asset \(name)")
        }
    }

    @Test func parsesProcArgsBuffer() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0, 0])
        for arg in ["node", "/opt/homebrew/bin/claude", "--resume"] {
            buffer.append(contentsOf: Array(arg.utf8) + [0])
        }
        // Environment follows the arguments and must not be returned.
        buffer.append(contentsOf: Array("SECRET=1".utf8) + [0])

        let args = TerminalAppIcon.ProcessInspector.parseProcArgs(buffer)
        #expect(args == ["node", "/opt/homebrew/bin/claude", "--resume"])
    }

    @Test func inspectsCurrentProcess() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(TerminalAppIcon.ProcessInspector.identity(pid: pid) != nil)
        #expect(TerminalAppIcon.ProcessInspector.executablePath(pid: pid) != nil)
        #expect(!TerminalAppIcon.ProcessInspector.arguments(pid: pid).isEmpty)
    }
}
