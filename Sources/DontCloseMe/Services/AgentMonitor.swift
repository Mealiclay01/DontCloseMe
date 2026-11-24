import Foundation

@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var detectedAgents: [DetectedAgent] = []
    @Published private(set) var isAnyAgentWorking: Bool = false
    @Published private(set) var cooldownRemaining: TimeInterval? = nil
    @Published var manualSimulateWorking: Bool = false {
        didSet { evaluateGlobalWorkTransition() }
    }

    var workingAgents: [DetectedAgent] {
        var list = detectedAgents.filter { $0.state.isGuarded }
        if manualSimulateWorking {
            let simProfile = AgentProfile(
                id: "simulated-agent",
                name: "Simulated Agent",
                category: .cli,
                sfSymbol: "terminal",
                accentHex: "#FF3B30"
            )
            list.insert(
                DetectedAgent(
                    profile: simProfile,
                    pids: [0],
                    sampleCommand: "Simulated Active Task",
                    treeCPUPercent: 42.0,
                    activeChildCount: 1,
                    hasRecentFileActivity: true,
                    hasActiveNetworkSocket: true,
                    state: .working,
                    reasons: ["Manual simulation"],
                    lastActiveAt: Date(),
                    workingSince: Date()
                ),
                at: 0
            )
        }
        return list
    }

    var onWorkingStarted: (() -> Void)?
    var onAllAgentsFinished: (() -> Void)?

    private weak var settings: AppSettings?
    private nonisolated let scanner = SystemProcessScanner()
    private nonisolated let fileWatcher = FileActivityWatcher()
    private let scanQueue = DispatchQueue(label: "com.dontcloseme.agent-scan", qos: .utility)

    private var timer: Timer?
    private var isScanInFlight = false
    private var lastWorkingAtByProfile: [String: Date] = [:]
    private var workingSinceByProfile: [String: Date] = [:]
    private var previouslyAnyWorking = false

    private nonisolated static let passiveShellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "login", "tmux", "screen", "caffeinate"
    ]

    init(settings: AppSettings) {
        self.settings = settings
        start()
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        timer?.invalidate()
        scanNow()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanNow()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func scanNow() {
        guard !isScanInFlight, let settings else { return }
        isScanInFlight = true

        let profiles = settings.agentProfiles.filter { $0.isEnabled }
        let sensitivity = settings.sensitivity
        let cooldown = settings.cooldownGraceSeconds
        let prevActive = lastWorkingAtByProfile
        let prevSince = workingSinceByProfile

        scanQueue.async { [weak self] in
            guard let self else { return }
            let (byPID, childrenByParent) = self.scanner.scanUserProcesses()
            let now = Date()
            let nowEpoch = UInt64(now.timeIntervalSince1970)

            var results: [DetectedAgent] = []
            var nextActive = prevActive
            var nextSince = prevSince

            for profile in profiles {
                let matched = self.matchProcesses(for: profile, in: byPID)
                if matched.isEmpty {
                    nextActive.removeValue(forKey: profile.id)
                    nextSince.removeValue(forKey: profile.id)
                    continue
                }

                let rootPIDs = Set(matched.map { $0.pid })
                let treePIDs = self.collectDescendantTree(roots: rootPIDs, childrenByParent: childrenByParent)

                var treeCPU = 0.0
                var activeChildCount = 0
                var hasSocket = false

                for pid in treePIDs {
                    guard let proc = byPID[pid] else { continue }
                    treeCPU += proc.cpuPercent
                    if !hasSocket && self.scanner.checkActiveLLMSocket(pid: pid) {
                        hasSocket = true
                    }
                    if !rootPIDs.contains(pid) {
                        let lowerName = proc.executableName.lowercased()
                        let spawnedRecently = proc.startTimeSec > 0 && nowEpoch >= proc.startTimeSec && (nowEpoch - proc.startTimeSec) < 25
                        let isMCPChild = proc.commandLine.lowercased().contains("mcp")
                        if !Self.passiveShellNames.contains(lowerName) && (proc.cpuPercent >= 0.3 || (spawnedRecently && !isMCPChild)) {
                            activeChildCount += 1
                        }
                    }
                }

                var reasons: [String] = []
                let cpuLimit = profile.category == .ide ? profile.helperCpuThresholdPercent : profile.cpuThresholdPercent
                if treeCPU >= cpuLimit {
                    reasons.append(String(format: "CPU %.1f%%", treeCPU))
                }
                if activeChildCount > 0 {
                    reasons.append("\(activeChildCount) subprocess\(activeChildCount == 1 ? "" : "es")")
                }

                let fileActive: Bool
                if reasons.isEmpty && sensitivity == .smartActivity && !profile.alwaysGuardWhenOpen {
                    fileActive = self.fileWatcher.hasRecentActivity(in: profile.watchedPaths, within: 15.0)
                } else {
                    fileActive = false
                }
                if fileActive {
                    reasons.append("Session updated")
                }

                let socketCPUFloor = profile.category == .ide ? 1.5 : 0.35
                if hasSocket && treeCPU >= socketCPUFloor {
                    reasons.append("Active API stream")
                }

                let isActivelyWorking: Bool
                if sensitivity == .presence || profile.alwaysGuardWhenOpen {
                    isActivelyWorking = true
                    if reasons.isEmpty {
                        reasons.append(profile.alwaysGuardWhenOpen ? "Pinned" : "Process running")
                    }
                } else {
                    isActivelyWorking = !reasons.isEmpty
                }

                let state: AgentWorkState
                if isActivelyWorking {
                    state = .working
                    nextActive[profile.id] = now
                    if nextSince[profile.id] == nil {
                        nextSince[profile.id] = now
                    }
                } else if let last = nextActive[profile.id], now.timeIntervalSince(last) < cooldown {
                    state = .cooldown
                    reasons.append("Cooldown")
                } else {
                    state = .idle
                    nextSince.removeValue(forKey: profile.id)
                }

                let sampleCmd = matched.first?.commandLine ?? profile.name
                results.append(
                    DetectedAgent(
                        profile: profile,
                        pids: Array(rootPIDs).sorted(),
                        sampleCommand: sampleCmd,
                        treeCPUPercent: treeCPU,
                        activeChildCount: activeChildCount,
                        hasRecentFileActivity: fileActive,
                        hasActiveNetworkSocket: hasSocket,
                        state: state,
                        reasons: reasons,
                        lastActiveAt: nextActive[profile.id],
                        workingSince: nextSince[profile.id]
                    )
                )
            }

            results.sort { lhs, rhs in
                if lhs.state.isGuarded != rhs.state.isGuarded {
                    return lhs.state.isGuarded && !rhs.state.isGuarded
                }
                return lhs.treeCPUPercent > rhs.treeCPUPercent
            }

            DispatchQueue.main.async {
                self.lastWorkingAtByProfile = nextActive
                self.workingSinceByProfile = nextSince
                self.detectedAgents = results
                self.isScanInFlight = false
                self.evaluateGlobalWorkTransition()
            }
        }
    }

    private func evaluateGlobalWorkTransition() {
        let now = Date()
        let cooldown = settings?.cooldownGraceSeconds ?? 20.0
        let guarded = workingAgents
        let currentlyWorking = !guarded.isEmpty

        if guarded.allSatisfy({ $0.state == .cooldown }),
           let mostRecent = guarded.compactMap({ $0.lastActiveAt }).max() {
            let rem = max(0, cooldown - now.timeIntervalSince(mostRecent))
            cooldownRemaining = rem
        } else {
            cooldownRemaining = nil
        }

        isAnyAgentWorking = currentlyWorking
        if currentlyWorking && !previouslyAnyWorking {
            previouslyAnyWorking = true
            onWorkingStarted?()
        } else if !currentlyWorking && previouslyAnyWorking {
            previouslyAnyWorking = false
            onAllAgentsFinished?()
        }
    }

    nonisolated func matchProcesses(
        for profile: AgentProfile,
        in byPID: [pid_t: ProcessSnapshot]
    ) -> [ProcessSnapshot] {
        var matched: [ProcessSnapshot] = []
        let execSet = Set(profile.executableNames.map { $0.lowercased() })

        for proc in byPID.values {
            let hayPath = proc.executablePath.lowercased()
            let hayCmd = proc.commandLine.lowercased()
            let hayName = proc.executableName.lowercased()
            let hayComm = proc.commName.lowercased()
            let hayArgv0 = proc.argv0Basename.lowercased()

            let excluded = profile.excludedPathSubstrings.contains { excl in
                let low = excl.lowercased()
                return hayPath.contains(low) || hayCmd.contains(low) || hayName.contains(low) || hayComm.contains(low)
            }
            if excluded { continue }

            var hit = false
            if execSet.contains(hayName) || execSet.contains(hayComm) || execSet.contains(hayArgv0) {
                if hayName == "language_server" && !profile.bundlePathSubstrings.isEmpty {
                    hit = profile.bundlePathSubstrings.contains {
                        hayPath.contains($0.lowercased()) || hayCmd.contains($0.lowercased())
                    }
                } else {
                    hit = true
                }
            }
            if !hit {
                hit = profile.bundlePathSubstrings.contains {
                    let low = $0.lowercased()
                    return hayPath.contains(low) || hayCmd.contains(low)
                }
            }
            if !hit {
                hit = profile.commandSubstrings.contains {
                    let low = $0.lowercased()
                    return hayCmd.contains(low) || hayPath.contains(low)
                }
            }

            if hit {
                matched.append(proc)
            }
        }
        return matched
    }

    nonisolated private func collectDescendantTree(
        roots: Set<pid_t>,
        childrenByParent: [pid_t: [pid_t]]
    ) -> Set<pid_t> {
        var visited = roots
        var queue = Array(roots)
        while let current = queue.popLast() {
            for child in childrenByParent[current] ?? [] {
                if visited.insert(child).inserted {
                    queue.append(child)
                }
            }
        }
        return visited
    }
}
