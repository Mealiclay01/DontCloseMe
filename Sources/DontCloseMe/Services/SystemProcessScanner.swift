import Foundation
import Darwin

struct ProcessSnapshot {
    let pid: pid_t
    let ppid: pid_t
    let executablePath: String
    let executableName: String
    let commName: String
    let argv0Basename: String
    let commandLine: String
    let startTimeSec: UInt64
    let totalCPUTimeNs: UInt64
    var cpuPercent: Double
}

final class SystemProcessScanner {
    private struct CachedArgs {
        let startSec: UInt64
        let startUsec: UInt64
        let argv0Basename: String
        let commandLine: String
    }

    private var previousCPUTimes: [pid_t: (cpuNs: UInt64, timestampNs: UInt64)] = [:]
    private var argsCache: [pid_t: CachedArgs] = [:]
    private let currentUID = getuid()
    private let selfPID = getpid()

    func scanUserProcesses() -> (byPID: [pid_t: ProcessSnapshot], childrenByParent: [pid_t: [pid_t]]) {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return ([:], [:]) }

        let capacity = Int(estimatedCount) + 128
        var pids = [pid_t](repeating: 0, count: capacity)
        let bufferBytes = Int32(capacity * MemoryLayout<pid_t>.size)
        let actualCount = proc_listallpids(&pids, bufferBytes)
        guard actualCount > 0 else { return ([:], [:]) }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        var snapshots: [pid_t: ProcessSnapshot] = [:]
        var childrenByParent: [pid_t: [pid_t]] = [:]
        var nextCPUTimes: [pid_t: (UInt64, UInt64)] = [:]
        var nextArgsCache: [pid_t: CachedArgs] = [:]

        for i in 0..<Int(actualCount) {
            let pid = pids[i]
            if pid <= 1 || pid == selfPID { continue }

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            if bsd.pbi_uid != currentUID { continue }

            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let execPath = pathLen > 0 ? String(cString: pathBuffer) : ""
            if execPath.hasPrefix("/System/") || execPath.hasPrefix("/usr/libexec/") {
                continue
            }

            let commName = extractComm(from: bsd)
            let execName = execPath.isEmpty
                ? commName
                : URL(fileURLWithPath: execPath).lastPathComponent

            let totalCPU = task.pti_total_user + task.pti_total_system
            var cpuPercent = 0.0
            if let prev = previousCPUTimes[pid], nowNs > prev.timestampNs, totalCPU >= prev.cpuNs {
                let deltaCPU = Double(totalCPU - prev.cpuNs)
                let deltaWall = Double(nowNs - prev.timestampNs)
                cpuPercent = (deltaCPU / deltaWall) * 100.0
            }
            nextCPUTimes[pid] = (totalCPU, nowNs)

            let cmdLine: String
            let argv0Basename: String
            if let cached = argsCache[pid],
               cached.startSec == bsd.pbi_start_tvsec,
               cached.startUsec == bsd.pbi_start_tvusec {
                cmdLine = cached.commandLine
                argv0Basename = cached.argv0Basename
                nextArgsCache[pid] = cached
            } else {
                let (firstArg, fullArgs) = readProcessArgs(pid: pid)
                cmdLine = fullArgs.isEmpty ? execPath : fullArgs
                argv0Basename = firstArg.isEmpty
                    ? execName
                    : URL(fileURLWithPath: firstArg).lastPathComponent
                nextArgsCache[pid] = CachedArgs(
                    startSec: bsd.pbi_start_tvsec,
                    startUsec: bsd.pbi_start_tvusec,
                    argv0Basename: argv0Basename,
                    commandLine: cmdLine
                )
            }

            let snap = ProcessSnapshot(
                pid: pid,
                ppid: pid_t(bsd.pbi_ppid),
                executablePath: execPath,
                executableName: execName,
                commName: commName,
                argv0Basename: argv0Basename,
                commandLine: cmdLine,
                startTimeSec: bsd.pbi_start_tvsec,
                totalCPUTimeNs: totalCPU,
                cpuPercent: cpuPercent
            )
            snapshots[pid] = snap
            childrenByParent[pid_t(bsd.pbi_ppid), default: []].append(pid)
        }

        previousCPUTimes = nextCPUTimes
        argsCache = nextArgsCache
        return (snapshots, childrenByParent)
    }

    func checkActiveLLMSocket(pid: pid_t) -> Bool {
        let fdSize = MemoryLayout<proc_fdinfo>.size
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return false }

        let count = Int(bufSize) / fdSize
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let actualBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard actualBytes > 0 else { return false }

        let actualCount = min(Int(actualBytes) / fdSize, 160)
        let sockSize = Int32(MemoryLayout<socket_fdinfo>.size)

        for i in 0..<actualCount where fds[i].proc_fdtype == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sockSize)
            if r == sockSize && si.psi.soi_kind == SOCKINFO_TCP {
                if si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED {
                    let remotePort = UInt16(
                        bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport)
                    )
                    if remotePort == 443 || remotePort == 11434 || remotePort == 1234 || remotePort == 8080 {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func extractComm(from bsd: proc_bsdinfo) -> String {
        withUnsafeBytes(of: bsd.pbi_comm) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func readProcessArgs(pid: pid_t) -> (argv0: String, joined: String) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size <= 4 {
            return ("", "")
        }
        let clampedSize = min(size, 16_384)
        var buf = [UInt8](repeating: 0, count: clampedSize)
        var actualSize = clampedSize
        if sysctl(&mib, 3, &buf, &actualSize, nil, 0) != 0 || actualSize <= 4 {
            return ("", "")
        }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var idx = 4
        while idx < actualSize && buf[idx] != 0 { idx += 1 }
        while idx < actualSize && buf[idx] == 0 { idx += 1 }

        var args: [String] = []
        let maxArgs = min(Int(argc), 12)
        while idx < actualSize && args.count < maxArgs {
            let start = idx
            while idx < actualSize && buf[idx] != 0 { idx += 1 }
            if idx > start, let str = String(bytes: buf[start..<idx], encoding: .utf8) {
                args.append(str)
            }
            idx += 1
        }
        return (args.first ?? "", args.joined(separator: " "))
    }
}

final class FileActivityWatcher {
    private let fm = FileManager.default

    func hasRecentActivity(in paths: [String], within recentSeconds: TimeInterval = 15.0) -> Bool {
        let cutoff = Date().addingTimeInterval(-recentSeconds)
        for rawPath in paths {
            let expanded = (rawPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else { continue }

            let url = URL(fileURLWithPath: expanded)
            if !isDir.boolValue {
                if let modDate = modificationDate(of: url), modDate >= cutoff {
                    return true
                }
                continue
            }

            if directoryHasRecentModification(at: url, cutoff: cutoff, depth: 0, maxDepth: 5) {
                return true
            }
        }
        return false
    }

    private func modificationDate(of url: URL) -> Date? {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return vals?.contentModificationDate
    }

    private func directoryHasRecentModification(
        at url: URL,
        cutoff: Date,
        depth: Int,
        maxDepth: Int
    ) -> Bool {
        if let dirMod = modificationDate(of: url), dirMod >= cutoff {
            return true
        }
        guard depth < maxDepth else { return false }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return false
        }

        var subdirs: [(url: URL, mod: Date)] = []
        for child in children {
            if child.lastPathComponent == ".DS_Store" { continue }
            guard let vals = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            let mod = vals.contentModificationDate ?? .distantPast
            if mod >= cutoff {
                return true
            }
            if vals.isDirectory == true {
                subdirs.append((child, mod))
            }
        }

        // Traverse newest subdirectories first so deep trees like ~/.codex/sessions/YYYY/MM/DD stay <2ms
        subdirs.sort { $0.mod > $1.mod }
        for sub in subdirs.prefix(8) {
            if directoryHasRecentModification(at: sub.url, cutoff: cutoff, depth: depth + 1, maxDepth: maxDepth) {
                return true
            }
        }
        return false
    }
}
