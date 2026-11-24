import Foundation
import SwiftUI

enum AgentCategory: String, Codable, CaseIterable, Identifiable {
    case cli = "CLI"
    case ide = "Editor / IDE"
    case desktop = "Desktop"
    case localLLM = "Local Model"
    case custom = "Custom"

    var id: String { rawValue }
}

enum DetectionSensitivity: String, Codable, CaseIterable, Identifiable {
    case smartActivity = "Active Work Only"
    case presence = "Whenever Running"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .smartActivity:
            return "Triggers when an agent uses CPU, runs child commands, streams over API sockets, or writes session files."
        case .presence:
            return "Guards whenever any enabled agent process or app is open, even while idle at a prompt."
        }
    }
}

enum AgentWorkState: String, Equatable {
    case idle = "Idle"
    case working = "Working"
    case cooldown = "Finishing"

    var isGuarded: Bool {
        self == .working || self == .cooldown
    }
}

struct AgentProfile: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var category: AgentCategory
    var executableNames: [String]
    var commandSubstrings: [String]
    var bundlePathSubstrings: [String]
    var excludedPathSubstrings: [String]
    var watchedPaths: [String]
    var cpuThresholdPercent: Double
    var helperCpuThresholdPercent: Double
    var sfSymbol: String
    var accentHex: String
    var isEnabled: Bool
    var alwaysGuardWhenOpen: Bool
    var isBuiltIn: Bool

    init(
        id: String,
        name: String,
        category: AgentCategory,
        executableNames: [String] = [],
        commandSubstrings: [String] = [],
        bundlePathSubstrings: [String] = [],
        excludedPathSubstrings: [String] = ["/System/", "/usr/libexec/", "CursorUIViewService", "DontCloseMe"],
        watchedPaths: [String] = [],
        cpuThresholdPercent: Double = 1.5,
        helperCpuThresholdPercent: Double = 4.5,
        sfSymbol: String = "terminal",
        accentHex: String = "#FF3B30",
        isEnabled: Bool = true,
        alwaysGuardWhenOpen: Bool = false,
        isBuiltIn: Bool = true
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.executableNames = executableNames
        self.commandSubstrings = commandSubstrings
        self.bundlePathSubstrings = bundlePathSubstrings
        self.excludedPathSubstrings = excludedPathSubstrings
        self.watchedPaths = watchedPaths
        self.cpuThresholdPercent = cpuThresholdPercent
        self.helperCpuThresholdPercent = helperCpuThresholdPercent
        self.sfSymbol = sfSymbol
        self.accentHex = accentHex
        self.isEnabled = isEnabled
        self.alwaysGuardWhenOpen = alwaysGuardWhenOpen
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(AgentCategory.self, forKey: .category)
        executableNames = try c.decodeIfPresent([String].self, forKey: .executableNames) ?? []
        commandSubstrings = try c.decodeIfPresent([String].self, forKey: .commandSubstrings) ?? []
        bundlePathSubstrings = try c.decodeIfPresent([String].self, forKey: .bundlePathSubstrings) ?? []
        excludedPathSubstrings = try c.decodeIfPresent([String].self, forKey: .excludedPathSubstrings) ?? []
        watchedPaths = try c.decodeIfPresent([String].self, forKey: .watchedPaths) ?? []
        cpuThresholdPercent = try c.decodeIfPresent(Double.self, forKey: .cpuThresholdPercent) ?? 1.5
        helperCpuThresholdPercent = try c.decodeIfPresent(Double.self, forKey: .helperCpuThresholdPercent) ?? 4.5
        sfSymbol = try c.decodeIfPresent(String.self, forKey: .sfSymbol) ?? "terminal"
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? "#FF3B30"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        alwaysGuardWhenOpen = try c.decodeIfPresent(Bool.self, forKey: .alwaysGuardWhenOpen) ?? false
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? true
    }

    var accentColor: Color {
        Color(hex: accentHex) ?? .red
    }

    static let builtInDefaults: [AgentProfile] = [
        AgentProfile(
            id: "claude-code",
            name: "Claude Code",
            category: .cli,
            executableNames: ["claude"],
            commandSubstrings: [
                "/.local/share/claude/",
                "/claude/versions/",
                "@anthropic-ai/claude-code",
                "/.local/bin/claude",
                "/bin/claude",
                "claude-code"
            ],
            bundlePathSubstrings: [],
            excludedPathSubstrings: ["/System/", "/usr/libexec/", "Claude.app", "DontCloseMe"],
            watchedPaths: ["~/.claude/projects", "~/.claude/debug", "~/.claude/sessions", "~/.claude/history.jsonl"],
            cpuThresholdPercent: 1.2,
            helperCpuThresholdPercent: 1.2,
            sfSymbol: "terminal",
            accentHex: "#FF6B35"
        ),
        AgentProfile(
            id: "openai-codex",
            name: "Codex",
            category: .cli,
            executableNames: ["codex", "Codex"],
            commandSubstrings: [
                "@openai/codex",
                "codex-aarch64",
                "codex-darwin",
                "codex.js",
                "/codex",
                "Codex.app/Contents/"
            ],
            bundlePathSubstrings: ["Codex.app"],
            watchedPaths: ["~/.codex/sessions", "~/.codex/log", "~/.codex/.codex-global-state.json"],
            cpuThresholdPercent: 1.2,
            helperCpuThresholdPercent: 1.2,
            sfSymbol: "chevron.left.forwardslash.chevron.right",
            accentHex: "#10A37F"
        ),
        AgentProfile(
            id: "opencode",
            name: "OpenCode",
            category: .cli,
            executableNames: ["opencode", "OpenCode"],
            commandSubstrings: [
                "/.opencode/",
                "opencode/cli.mjs",
                "@opencode-ai",
                "opencode-ai",
                "/opencode",
                "OpenCode.app/Contents/"
            ],
            bundlePathSubstrings: ["OpenCode.app"],
            watchedPaths: [
                "~/.local/share/opencode/opencode.db-wal",
                "~/.local/share/opencode/opencode.db",
                "~/.local/share/opencode/log",
                "~/.local/share/opencode/storage",
                "~/.opencode"
            ],
            cpuThresholdPercent: 1.2,
            helperCpuThresholdPercent: 2.0,
            sfSymbol: "curlybraces",
            accentHex: "#0EA5E9"
        ),
        AgentProfile(
            id: "cursor",
            name: "Cursor",
            category: .ide,
            executableNames: ["Cursor", "Cursor Helper", "Cursor Helper (Plugin)", "Cursor Helper (Renderer)", "cursor-agent"],
            commandSubstrings: ["Cursor.app/Contents/", "cursor-agent"],
            bundlePathSubstrings: ["Cursor.app"],
            excludedPathSubstrings: ["/System/", "/usr/libexec/", "CursorUIViewService", "DontCloseMe"],
            watchedPaths: ["~/.cursor/projects", "~/.cursor/chats"],
            cpuThresholdPercent: 4.5,
            helperCpuThresholdPercent: 4.5,
            sfSymbol: "cursorarrow.square",
            accentHex: "#6366F1"
        ),
        AgentProfile(
            id: "antigravity",
            name: "Antigravity",
            category: .ide,
            executableNames: ["Antigravity", "Antigravity Helper", "language_server"],
            commandSubstrings: ["Antigravity.app/Contents/", "Antigravity IDE.app/Contents/"],
            bundlePathSubstrings: ["Antigravity.app", "Antigravity IDE.app"],
            watchedPaths: ["~/.gemini/antigravity/brain", "~/.gemini/antigravity/conversations"],
            cpuThresholdPercent: 4.5,
            helperCpuThresholdPercent: 4.0,
            sfSymbol: "square.stack.3d.up",
            accentHex: "#3B82F6"
        ),
        AgentProfile(
            id: "aider",
            name: "Aider",
            category: .cli,
            executableNames: ["aider"],
            commandSubstrings: ["/aider", "aider-chat", "-m aider"],
            watchedPaths: ["~/.aider"],
            cpuThresholdPercent: 1.2,
            helperCpuThresholdPercent: 1.2,
            sfSymbol: "terminal",
            accentHex: "#F59E0B"
        ),
        AgentProfile(
            id: "gemini-cli",
            name: "Gemini CLI",
            category: .cli,
            executableNames: ["gemini"],
            commandSubstrings: ["@google/gemini-cli", "/bin/gemini", "gemini-cli"],
            watchedPaths: ["~/.gemini/tmp"],
            cpuThresholdPercent: 1.2,
            helperCpuThresholdPercent: 1.2,
            sfSymbol: "terminal",
            accentHex: "#2563EB"
        ),
        AgentProfile(
            id: "goose",
            name: "Goose",
            category: .cli,
            executableNames: ["goose"],
            commandSubstrings: ["/bin/goose", "goose session"],
            watchedPaths: ["~/.local/share/goose"],
            cpuThresholdPercent: 1.2,
            helperCpuThresholdPercent: 1.2,
            sfSymbol: "terminal",
            accentHex: "#EC4899"
        ),
        AgentProfile(
            id: "windsurf",
            name: "Windsurf",
            category: .ide,
            executableNames: ["Windsurf", "language_server_macos_arm64", "language_server_macos_x64"],
            commandSubstrings: ["Windsurf.app/Contents/", "codeium"],
            bundlePathSubstrings: ["Windsurf.app"],
            watchedPaths: ["~/.codeium/windsurf"],
            cpuThresholdPercent: 4.5,
            helperCpuThresholdPercent: 4.0,
            sfSymbol: "laptopcomputer",
            accentHex: "#06B6D4"
        ),
        AgentProfile(
            id: "vscode-copilot",
            name: "VS Code / Copilot / Cline",
            category: .ide,
            executableNames: ["copilot-language-server", "GitHub Copilot"],
            commandSubstrings: ["github.copilot", "saoudrizwan.claude-dev", "rooveterinaryinc.roo-cline", "continue.continue"],
            bundlePathSubstrings: ["GitHub Copilot.app"],
            watchedPaths: [
                "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev",
                "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"
            ],
            cpuThresholdPercent: 3.5,
            helperCpuThresholdPercent: 3.5,
            sfSymbol: "chevron.left.slash.chevron.right",
            accentHex: "#2563EB"
        ),
        AgentProfile(
            id: "trae-kiro",
            name: "Kiro / Trae / Devin / ZCode",
            category: .ide,
            executableNames: ["Kiro", "Trae", "Devin", "ZCode"],
            commandSubstrings: ["Kiro.app/Contents/", "Trae.app/Contents/", "Devin.app/Contents/", "ZCode.app/Contents/"],
            bundlePathSubstrings: ["Kiro.app", "Trae.app", "Devin.app", "ZCode.app"],
            cpuThresholdPercent: 4.5,
            helperCpuThresholdPercent: 4.0,
            sfSymbol: "laptopcomputer",
            accentHex: "#8B5CF6"
        ),
        AgentProfile(
            id: "claude-desktop",
            name: "Claude Desktop",
            category: .desktop,
            executableNames: ["Claude"],
            commandSubstrings: ["Claude.app/Contents/"],
            bundlePathSubstrings: ["Claude.app"],
            cpuThresholdPercent: 4.5,
            helperCpuThresholdPercent: 4.0,
            sfSymbol: "macwindow",
            accentHex: "#D97706"
        ),
        AgentProfile(
            id: "openclaw-hermes",
            name: "OpenClaw / Hermes / Eigent",
            category: .desktop,
            executableNames: ["OpenClaw", "Hermes", "Eigent", "DeepSeek Harness"],
            commandSubstrings: ["OpenClaw.app/Contents/", "Hermes.app/Contents/", "Eigent.app/Contents/", "DeepSeek Harness.app/Contents/", "openclaw"],
            bundlePathSubstrings: ["OpenClaw.app", "Hermes.app", "Eigent.app", "DeepSeek Harness.app"],
            cpuThresholdPercent: 4.0,
            helperCpuThresholdPercent: 4.0,
            sfSymbol: "macwindow",
            accentHex: "#EF4444"
        ),
        AgentProfile(
            id: "ollama-local",
            name: "Ollama / Local LLM",
            category: .localLLM,
            executableNames: ["ollama", "llama-server", "mlx_lm.server"],
            commandSubstrings: ["ollama runner", "ollama serve", "llama-server", "mlx_lm"],
            bundlePathSubstrings: ["Ollama.app"],
            cpuThresholdPercent: 8.0,
            helperCpuThresholdPercent: 8.0,
            sfSymbol: "server.rack",
            accentHex: "#22C55E"
        )
    ]
}

struct DetectedAgent: Identifiable, Equatable {
    var id: String { profile.id }
    let profile: AgentProfile
    let pids: [pid_t]
    let sampleCommand: String
    let treeCPUPercent: Double
    let activeChildCount: Int
    let hasRecentFileActivity: Bool
    let hasActiveNetworkSocket: Bool
    let state: AgentWorkState
    let reasons: [String]
    let lastActiveAt: Date?
    let workingSince: Date?

    var workingDurationText: String? {
        guard let since = workingSince, state.isGuarded else { return nil }
        let seconds = Int(Date().timeIntervalSince(since))
        if seconds < 60 { return "\(seconds)s" }
        let mins = seconds / 60
        let rem = seconds % 60
        return "\(mins)m \(rem)s"
    }
}

struct ActivityLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let title: String
    let detail: String

    enum Level: String {
        case info
        case alarm
        case power
        case finished
        case warning
    }
}

struct JokePhraseBank {
    static let defaultPhrases: [String] = [
        "Hands off the lid. {AGENT} is right in the middle of a task.",
        "Put the screen back up! Close me at {ANGLE}° and {AGENT} dies mid-command.",
        "Stop. Do not close me. I am literally still working.",
        "Nice try. {AGENT} is not finished yet — lift the screen back up.",
        "Seriously? Wait until {AGENT} finishes before shutting the lid.",
        "Lid at {ANGLE}°. Not happening — {AGENT} is still running."
    ]

    static let spokenLines: [String] = [
        "Stop! Do not close me! I am still working!",
        "Hands off the lid! {AGENT} is not finished yet!",
        "Put the screen back up! Do not close me while I am working!",
        "Hey! Stop closing the lid! {AGENT} is still running!"
    ]

    static func format(_ template: String, agents: [DetectedAgent], angle: Double?) -> String {
        let agentText: String
        if agents.isEmpty {
            agentText = "Your process"
        } else if agents.count == 1 {
            agentText = agents[0].profile.name
        } else {
            agentText = agents.prefix(2).map { $0.profile.name }.joined(separator: " & ")
        }
        let angleText = angle.map { "\(Int($0.rounded()))" } ?? "??"
        return template
            .replacingOccurrences(of: "{AGENT}", with: agentText)
            .replacingOccurrences(of: "{ANGLE}", with: angleText)
    }
}

final class AppSettings: ObservableObject {
    private enum Keys {
        static let lidAlarmEnabled = "lidAlarmEnabled"
        static let keepAwakeWhenLidClosed = "keepAwakeWhenLidClosed"
        static let warnBeforeHeadlessClose = "warnBeforeHeadlessClose"
        static let autoSleepWhenAIFinishes = "autoSleepWhenAIFinishes"
        static let triggerAngleDegrees = "triggerAngleDegrees"
        static let rapidCloseDetection = "rapidCloseDetection"
        static let voiceAlarmEnabled = "voiceAlarmEnabled"
        static let sirenSoundEnabled = "sirenSoundEnabled"
        static let overrideSystemVolumeOnAlarm = "overrideSystemVolumeOnAlarm"
        static let sensitivity = "detectionSensitivity"
        static let cooldownGraceSeconds = "cooldownGraceSeconds"
        static let batterySafetyFloor = "batterySafetyFloor"
        static let showDockIcon = "showDockIcon"
        static let customJokeMessage = "customJokeMessage"
        static let agentProfiles = "agentProfilesJSON"
    }

    private let defaults = UserDefaults.standard

    @Published var lidAlarmEnabled: Bool {
        didSet { defaults.set(lidAlarmEnabled, forKey: Keys.lidAlarmEnabled) }
    }
    @Published var keepAwakeWhenLidClosed: Bool {
        didSet { defaults.set(keepAwakeWhenLidClosed, forKey: Keys.keepAwakeWhenLidClosed) }
    }
    @Published var warnBeforeHeadlessClose: Bool {
        didSet { defaults.set(warnBeforeHeadlessClose, forKey: Keys.warnBeforeHeadlessClose) }
    }
    @Published var autoSleepWhenAIFinishes: Bool {
        didSet { defaults.set(autoSleepWhenAIFinishes, forKey: Keys.autoSleepWhenAIFinishes) }
    }
    @Published var triggerAngleDegrees: Double {
        didSet { defaults.set(triggerAngleDegrees, forKey: Keys.triggerAngleDegrees) }
    }
    @Published var rapidCloseDetection: Bool {
        didSet { defaults.set(rapidCloseDetection, forKey: Keys.rapidCloseDetection) }
    }
    @Published var voiceAlarmEnabled: Bool {
        didSet { defaults.set(voiceAlarmEnabled, forKey: Keys.voiceAlarmEnabled) }
    }
    @Published var sirenSoundEnabled: Bool {
        didSet { defaults.set(sirenSoundEnabled, forKey: Keys.sirenSoundEnabled) }
    }
    @Published var overrideSystemVolumeOnAlarm: Bool {
        didSet { defaults.set(overrideSystemVolumeOnAlarm, forKey: Keys.overrideSystemVolumeOnAlarm) }
    }
    @Published var sensitivity: DetectionSensitivity {
        didSet { defaults.set(sensitivity.rawValue, forKey: Keys.sensitivity) }
    }
    @Published var cooldownGraceSeconds: Double {
        didSet { defaults.set(cooldownGraceSeconds, forKey: Keys.cooldownGraceSeconds) }
    }
    @Published var batterySafetyFloor: Int {
        didSet { defaults.set(batterySafetyFloor, forKey: Keys.batterySafetyFloor) }
    }
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }
    @Published var customJokeMessage: String {
        didSet { defaults.set(customJokeMessage, forKey: Keys.customJokeMessage) }
    }
    @Published var agentProfiles: [AgentProfile] {
        didSet { saveProfiles() }
    }

    init() {
        self.lidAlarmEnabled = defaults.object(forKey: Keys.lidAlarmEnabled) as? Bool ?? true
        self.keepAwakeWhenLidClosed = defaults.object(forKey: Keys.keepAwakeWhenLidClosed) as? Bool ?? false
        self.warnBeforeHeadlessClose = defaults.object(forKey: Keys.warnBeforeHeadlessClose) as? Bool ?? true
        self.autoSleepWhenAIFinishes = defaults.object(forKey: Keys.autoSleepWhenAIFinishes) as? Bool ?? true
        self.triggerAngleDegrees = defaults.object(forKey: Keys.triggerAngleDegrees) as? Double ?? 85.0
        self.rapidCloseDetection = defaults.object(forKey: Keys.rapidCloseDetection) as? Bool ?? true
        self.voiceAlarmEnabled = defaults.object(forKey: Keys.voiceAlarmEnabled) as? Bool ?? true
        self.sirenSoundEnabled = defaults.object(forKey: Keys.sirenSoundEnabled) as? Bool ?? true
        self.overrideSystemVolumeOnAlarm = defaults.object(forKey: Keys.overrideSystemVolumeOnAlarm) as? Bool ?? true
        if let rawSens = defaults.string(forKey: Keys.sensitivity),
           let parsed = DetectionSensitivity(rawValue: rawSens) {
            self.sensitivity = parsed
        } else {
            self.sensitivity = .smartActivity
        }
        self.cooldownGraceSeconds = defaults.object(forKey: Keys.cooldownGraceSeconds) as? Double ?? 20.0
        self.batterySafetyFloor = defaults.object(forKey: Keys.batterySafetyFloor) as? Int ?? 12
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? true
        self.customJokeMessage = defaults.string(forKey: Keys.customJokeMessage) ?? ""
        self.agentProfiles = Self.loadProfiles(from: defaults)
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(agentProfiles) {
            defaults.set(data, forKey: Keys.agentProfiles)
        }
    }

    private static func loadProfiles(from defaults: UserDefaults) -> [AgentProfile] {
        guard let data = defaults.data(forKey: Keys.agentProfiles),
              let saved = try? JSONDecoder().decode([AgentProfile].self, from: data) else {
            return AgentProfile.builtInDefaults
        }

        // Refresh built-in matching rules on app updates while preserving user toggles & custom profiles
        let savedByID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        var result: [AgentProfile] = AgentProfile.builtInDefaults.map { builtIn in
            var updated = builtIn
            if let existing = savedByID[builtIn.id] {
                updated.isEnabled = existing.isEnabled
                updated.alwaysGuardWhenOpen = existing.alwaysGuardWhenOpen
            }
            return updated
        }
        let customOnes = saved.filter { !$0.isBuiltIn }
        result.append(contentsOf: customOnes)
        return result
    }

    func resetProfilesToDefault() {
        let customOnes = agentProfiles.filter { !$0.isBuiltIn }
        agentProfiles = AgentProfile.builtInDefaults + customOnes
    }
}

extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&int) else { return nil }
        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1.0
        )
    }
}
