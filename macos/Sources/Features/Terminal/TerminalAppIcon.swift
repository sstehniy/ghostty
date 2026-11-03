import AppKit
import Darwin
import SwiftUI

/// The icon shown for a tab in the tab sidebar. This is derived from the foreground
/// process of the tab's last focused pane.
///
/// Only local processes can be identified. Programs running remotely (e.g. over
/// SSH) appear as the local `ssh` process and therefore fall back to `.terminal`.
enum TerminalAppIcon: String, CaseIterable, Equatable {
    case terminal
    case claude
    case codex
    case pi
    case opencode
    case amp
    case gemini
    case copilot
    case cursor
    case qwen
    case kiro

    /// The asset catalog image for this icon, or nil when a system symbol is used.
    var assetName: String? {
        switch self {
        case .terminal: return nil
        case .claude: return "TabIconClaude"
        case .codex: return "TabIconCodex"
        case .pi: return "TabIconPi"
        case .opencode: return "TabIconOpenCode"
        case .amp: return "TabIconAmp"
        case .gemini: return "TabIconGemini"
        case .copilot: return "TabIconCopilot"
        case .cursor: return "TabIconCursor"
        case .qwen: return "TabIconQwen"
        case .kiro: return "TabIconKiro"
        }
    }

    /// Whether the asset is a monochrome mark that's tinted with the theme's
    /// foreground color. Other assets keep their brand colors.
    var isTemplate: Bool {
        switch self {
        case .opencode, .amp, .copilot, .cursor: return true
        case .terminal, .claude, .codex, .pi, .gemini, .qwen, .kiro: return false
        }
    }

    /// The SF Symbol used when no bundled asset exists.
    var systemSymbolName: String { "apple.terminal" }

    /// A human readable name used for accessibility.
    var accessibilityName: String {
        switch self {
        case .terminal: return "Terminal"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .pi: return "Pi"
        case .opencode: return "OpenCode"
        case .amp: return "Amp"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .cursor: return "Cursor"
        case .qwen: return "Qwen Code"
        case .kiro: return "Kiro"
        }
    }
}

// MARK: Classification

extension TerminalAppIcon {
    /// Interpreters run the script given as their first non-flag argument, e.g.
    /// `node /opt/homebrew/bin/claude`.
    private static let interpreters: Set<String> = [
        "node", "nodejs", "bun", "deno", "tsx", "ts-node",
    ]

    /// Package runners take a subcommand before the package, e.g.
    /// `npm exec @openai/codex` or `npx @anthropic-ai/claude-code`.
    private static let packageRunners: Set<String> = [
        "npx", "npm", "pnpm", "pnpx", "yarn", "bunx",
    ]

    /// The number of non-flag arguments inspected for package runners.
    private static let packageRunnerArgumentLimit = 2

    /// Classify a process from its executable path and launch arguments.
    ///
    /// - Parameters:
    ///   - executablePath: The resolved executable path, if known.
    ///   - arguments: The full argv, including argv[0].
    static func classify(executablePath: String?, arguments: [String]) -> TerminalAppIcon {
        var candidates: [String] = []
        if let executablePath { candidates.append(executablePath) }
        if let argv0 = arguments.first { candidates.append(argv0) }

        // A direct match on the executable or argv[0].
        for candidate in candidates {
            if let match = match(path: candidate) { return match }
        }

        // Interpreted launches such as `node /opt/homebrew/bin/claude` or
        // `npx @openai/codex`. Only the script or package position is inspected so
        // that ordinary arguments (`node server.js --name claude`) never match.
        let limit: Int
        if candidates.contains(where: isInterpreter) {
            limit = 1
        } else if candidates.contains(where: { packageRunners.contains(basename($0)) }) {
            limit = packageRunnerArgumentLimit
        } else {
            return .terminal
        }

        let scriptArguments = arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-") }
            .prefix(limit)
        for argument in scriptArguments {
            if let match = match(path: argument) { return match }
        }

        return .terminal
    }

    private static func isInterpreter(_ path: String) -> Bool {
        let name = basename(path)
        if interpreters.contains(name) { return true }

        // Versioned node binaries such as `node22`.
        if name.hasPrefix("node"), name.dropFirst(4).allSatisfy(\.isNumber) { return true }
        return false
    }

    /// Path fragments that identify a program regardless of its executable name,
    /// e.g. `node_modules/@anthropic-ai/claude-code/cli.js`.
    private static let pathFragments: [(String, TerminalAppIcon)] = [
        ("@anthropic-ai/claude-code", .claude),
        // The native Claude installer runs binaries named after their version
        // from ~/.local/share/claude/versions/<version>.
        ("/claude/versions/", .claude),
        ("@openai/codex", .codex),
        ("pi-coding-agent", .pi),
        ("/opencode-ai/", .opencode),
        ("/.opencode/bin/", .opencode),
        ("@sourcegraph/amp", .amp),
        ("@google/gemini-cli", .gemini),
        ("@github/copilot", .copilot),
        // Cursor's installer runs `node index.js` from
        // ~/.local/share/cursor-agent/versions/<version>.
        ("/cursor-agent/", .cursor),
        ("@qwen-code/qwen-code", .qwen),
    ]

    /// Executable names, without script extensions.
    private static let executableNames: [String: TerminalAppIcon] = [
        "claude": .claude,
        "claude-code": .claude,
        "codex": .codex,
        "pi": .pi,
        "opencode": .opencode,
        "amp": .amp,
        "gemini": .gemini,
        "copilot": .copilot,
        "cursor-agent": .cursor,
        "qwen": .qwen,
        "kiro-cli": .kiro,
        "kiro-cli-chat": .kiro,
    ]

    /// Match a single path or argument against known programs.
    private static func match(path: String) -> TerminalAppIcon? {
        let lowered = path.lowercased()

        for (fragment, icon) in pathFragments where lowered.contains(fragment) {
            return icon
        }

        let name = stripScriptExtension(basename(lowered))
        if let icon = executableNames[name] { return icon }

        // Platform binaries shipped inside npm packages, e.g.
        // `codex-aarch64-apple-darwin` or `opencode-darwin-arm64`.
        if name.hasPrefix("codex-") && name.contains("apple-darwin") { return .codex }
        if name.hasPrefix("opencode-darwin") { return .opencode }
        return nil
    }

    private static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func stripScriptExtension(_ name: String) -> String {
        for ext in [".js", ".mjs", ".cjs", ".ts"] where name.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }
}

// MARK: Process Inspection

extension TerminalAppIcon {
    /// Reads process information needed for classification. These calls are
    /// blocking system calls and must not run on the main thread.
    enum ProcessInspector {
        struct Identity: Hashable {
            let pid: pid_t
            let startTime: UInt64
        }

        /// A stable identity for a running process, used to avoid stale cache
        /// hits when a pid is reused.
        static func identity(pid: pid_t) -> Identity? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
            return Identity(pid: pid, startTime: start)
        }

        static func executablePath(pid: pid_t) -> String? {
            // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN.
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(cString: buffer)
        }

        /// The argv of a process. Returns an empty array if the arguments can't be read,
        /// e.g. because the process belongs to another user.
        static func arguments(pid: pid_t) -> [String] {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

            return parseProcArgs(Array(buffer.prefix(size)))
        }

        /// Parse a KERN_PROCARGS2 buffer: an Int32 argc, the executable path,
        /// NUL padding, then argc NUL-terminated arguments.
        static func parseProcArgs(_ buffer: [UInt8]) -> [String] {
            let intSize = MemoryLayout<Int32>.size
            guard buffer.count > intSize else { return [] }
            let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            guard argc > 0 else { return [] }

            var index = intSize

            // Skip the executable path and the padding after it.
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            while index < buffer.count, buffer[index] == 0 { index += 1 }

            var result: [String] = []
            result.reserveCapacity(Int(argc))
            while index < buffer.count, result.count < Int(argc) {
                let start = index
                while index < buffer.count, buffer[index] != 0 { index += 1 }
                if let argument = String(bytes: buffer[start..<index], encoding: .utf8) {
                    result.append(argument)
                }
                index += 1
            }

            return result
        }
    }
}

// MARK: Resolver

/// Resolves app icons for foreground process IDs off the main thread, caching results
/// per process so that repeated sampling is cheap.
///
/// Process arguments may contain secrets, so they are never logged or retained;
/// only the resulting classification is cached.
final class TerminalAppIconResolver {
    static let shared = TerminalAppIconResolver()

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.tab-icon-resolver", qos: .utility)

    /// A process as of its current executable. `exec` keeps the pid and start time
    /// but replaces the executable, so the path is part of the key.
    private struct CacheKey: Hashable {
        let identity: TerminalAppIcon.ProcessInspector.Identity
        let executablePath: String?
    }

    /// Only accessed on `queue`.
    private var cache: [CacheKey: TerminalAppIcon] = [:]

    private static let cacheLimit = 256

    /// Resolve icons for the given pids. The completion is called on the main queue.
    func resolve(pids: Set<pid_t>, completion: @escaping ([pid_t: TerminalAppIcon]) -> Void) {
        guard !pids.isEmpty else {
            completion([:])
            return
        }

        queue.async { [weak self] in
            guard let self else { return }

            var result: [pid_t: TerminalAppIcon] = [:]
            for pid in pids {
                result[pid] = self.resolve(pid: pid)
            }

            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Must be called on `queue`.
    private func resolve(pid: pid_t) -> TerminalAppIcon {
        guard let identity = TerminalAppIcon.ProcessInspector.identity(pid: pid) else { return .terminal }
        let executablePath = TerminalAppIcon.ProcessInspector.executablePath(pid: pid)
        let key = CacheKey(identity: identity, executablePath: executablePath)
        if let cached = cache[key] { return cached }

        let icon = TerminalAppIcon.classify(
            executablePath: executablePath,
            arguments: TerminalAppIcon.ProcessInspector.arguments(pid: pid))

        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = icon
        return icon
    }
}

// MARK: SwiftUI

/// Renders a `TerminalAppIcon`.
struct TerminalAppIconView: View {
    let icon: TerminalAppIcon
    let foreground: Color
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let assetName = icon.assetName {
                if icon.isTemplate {
                    Image(assetName)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(foreground.opacity(0.85))
                } else {
                    Image(assetName)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                Image(systemName: icon.systemSymbolName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(foreground.opacity(0.75))
                    .padding(size * 0.04)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(icon.accessibilityName)
    }
}
