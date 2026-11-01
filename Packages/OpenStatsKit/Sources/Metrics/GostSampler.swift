import Darwin
import Foundation
import Network

// MARK: - 读数模型

/// 一个 gost 进程
public struct GostProcess: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    /// 相邻两次采样的 CPU 时间差 ÷ 墙钟时间，单核满载为 1
    public var cpu: Double
    public var memoryBytes: UInt64
    public var startTime: Date?

    init(pid: Int32, name: String, cpu: Double, memoryBytes: UInt64, startTime: Date?) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.startTime = startTime
    }
}

/// 经代理探测的结果
public enum GostProbeState: Sendable, Equatable {
    /// 探测成功，括号里是收到响应的毫秒数与识别出的代理协议
    case ok(milliseconds: Double, kind: GostPortKind)
    /// 连不上代理或响应超时
    case failed
    /// 首次探测还没回来
    case pending

    public var milliseconds: Double? {
        if case let .ok(value, _) = self { return value }
        return nil
    }

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

/// 端口上跑的代理协议：gost 的端口可能应答 HTTP 代理，也可能应答 SOCKS5
public enum GostPortKind: String, Sendable {
    case http, socks

    public var title: String {
        switch self {
        case .http: "HTTP"
        case .socks: "SOCKS5"
        }
    }
}

/// 一个监听中的代理端口
public struct GostPort: Sendable, Equatable, Identifiable {
    /// "地址:端口"，IPv6 带方括号
    public var id: String { "\(address):\(port)" }
    public let pid: Int32
    /// 监听地址，`*` 表示所有接口
    public let address: String
    public let port: Int
    public var probe: GostProbeState
    public var probedAt: Date?
    /// 最近约 1 小时的探测延迟（毫秒），探测失败的那次为 nil；走势图用
    public var latencyHistory: [Double?] = []

    init(pid: Int32, address: String, port: Int, probe: GostProbeState = .pending, probedAt: Date? = nil) {
        self.pid = pid
        self.address = address
        self.port = port
        self.probe = probe
        self.probedAt = probedAt
    }
}

public struct GostStatus: Sendable, Equatable {
    public var date = Date()
    public var processes: [GostProcess] = []
    public var ports: [GostPort] = []

    public init() {}

    public var isRunning: Bool { !processes.isEmpty }

    /// 探测成功的端口数
    public var healthyPortCount: Int { ports.filter { $0.probe.isOK }.count }

    /// 状态里的延迟取最快的一个端口；全部失败或还没探测过时为 nil
    public var bestLatency: Double? {
        ports.compactMap(\.probe.milliseconds).min()
    }
}

// MARK: - 采样器

/// 本机 gost 代理监控：进程用 sysctl 枚举（每拍都查，开销极小），
/// 监听端口用 lsof 发现（约 30 秒一次，进程退出时端口立刻作废），
/// 每个端口做一次完整线路探测（HTTP HEAD 或 SOCKS5 CONNECT 到 cp.cloudflare.com），
/// 约 10 秒一轮。后两类都是慢操作，放在后台任务里做，采样本身只汇总已到的结果。
public actor GostSampler {
    /// 进程名精确匹配 gost；想监控别的本地代理改这里即可
    static let processName = "gost"
    /// 经代理探测的目标：Cloudflare 的 204 页，只为确认链路通，不下载内容
    static let probeHost = "cp.cloudflare.com"
    static let probePath = "/generate_204"
    static let probeTimeout: TimeInterval = 4

    static let discoveryInterval: TimeInterval = 30
    static let probeInterval: TimeInterval = 10

    private var cpuTimes: [Int32: (total: UInt64, date: Date)] = [:]
    private var ports: [GostPort] = []
    private var lastDiscovery = Date.distantPast
    private var discoveryInFlight = false
    private var probing = Set<String>()
    private var previousDate: Date?

    public init() {}

    /// 汇总一次读数；到期的端口发现与探测在后台补，结果下一拍生效
    public func sample(now: Date) -> GostStatus {
        var status = GostStatus()
        status.date = now
        status.processes = scanProcesses(now: now)

        let livePIDs = Set(status.processes.map(\.pid))
        ports.removeAll { !livePIDs.contains($0.pid) }
        status.ports = ports.sorted { $0.port < $1.port }

        if !status.processes.isEmpty {
            if now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval, !discoveryInFlight {
                discoveryInFlight = true
                let pids = status.processes.map(\.pid)
                Task.detached(priority: .utility) {
                    let found = Self.listeningPorts(pids: pids)
                    await self.applyDiscovery(found, now: Date())
                }
            }
            for port in status.ports
            where !probing.contains(port.id)
                && (port.probedAt.map { now.timeIntervalSince($0) >= Self.probeInterval } ?? true) {
                probing.insert(port.id)
                let target = port
                Task.detached(priority: .utility) {
                    let state = await Self.probe(port: target.port)
                    await self.applyProbe(target.id, state, now: Date())
                }
            }
        }

        previousDate = now
        return status
    }

    private func applyDiscovery(_ found: [GostPort], now: Date) {
        discoveryInFlight = false
        lastDiscovery = now
        var byKey = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        for existing in ports { byKey[existing.id]?.probe = existing.probe; byKey[existing.id]?.probedAt = existing.probedAt }
        ports = byKey.values.sorted { $0.port < $1.port }
    }

    private func applyProbe(_ key: String, _ state: GostProbeState, now: Date) {
        probing.remove(key)
        guard let index = ports.firstIndex(where: { $0.id == key }) else { return }
        ports[index].probe = state
        ports[index].probedAt = now
        // 保留约 1 小时（每 10 秒一条）供走势图使用
        ports[index].latencyHistory.append(state.milliseconds)
        if ports[index].latencyHistory.count > 360 {
            ports[index].latencyHistory.removeFirst(ports[index].latencyHistory.count - 360)
        }
    }

    // MARK: 进程

    /// 用一次 KERN_PROC_ALL 就拿到全部进程名与启动时间，再对 gost 进程逐个读 rusage
    private func scanProcesses(now: Date) -> [GostProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var count = size / MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 3, &entries, &size, nil, 0) == 0 else { return [] }
        count = min(count, size / MemoryLayout<kinfo_proc>.stride)

        let elapsed = previousDate.map { now.timeIntervalSince($0) } ?? 0
        var results: [GostProcess] = []
        for entry in entries.prefix(count) {
            let comm = withUnsafeBytes(of: entry.kp_proc.p_comm) { raw -> String in
                let bytes = raw.prefix(while: { $0 != 0 })
                return String(decoding: bytes, as: UTF8.self)
            }
            guard comm == Self.processName else { continue }

            let pid = entry.kp_proc.p_pid
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { continue }

            let totalCPU = info.ri_user_time + info.ri_system_time
            var cpu = 0.0
            if elapsed > 0, let before = cpuTimes[pid]?.total, totalCPU >= before {
                cpu = min(1, Double(totalCPU - before) / 1_000_000_000 / elapsed)
            }
            cpuTimes[pid] = (totalCPU, now)

            let start = entry.kp_proc.p_starttime
            let startTime = start.tv_sec > 0 ? Date(timeIntervalSince1970: TimeInterval(start.tv_sec)) : nil
            results.append(GostProcess(pid: pid, name: comm, cpu: cpu,
                                       memoryBytes: info.ri_phys_footprint, startTime: startTime))
        }

        let live = Set(results.map(\.pid))
        for pid in cpuTimes.keys where !live.contains(pid) { cpuTimes[pid] = nil }
        return results.sorted { $0.pid < $1.pid }
    }

    // MARK: 端口

    /// lsof 列出这些进程监听的 TCP 端口；只查指定 PID，几百毫秒内返回
    private static func listeningPorts(pids: [Int32]) -> [GostPort] {
        guard !pids.isEmpty,
              let output = run("/usr/sbin/lsof", ["-nP", "-a", "-p", pids.map(String.init).joined(separator: ","),
                                                  "-iTCP", "-sTCP:LISTEN", "-Fpn"]) else { return [] }

        var ports: [GostPort] = []
        var seen = Set<String>()
        var currentPID: Int32 = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), let pid = Int32(line.dropFirst()) {
                currentPID = pid
            } else if line.hasPrefix("n"), currentPID != 0 {
                let address = line.dropFirst()
                guard let separator = address.lastIndex(of: ":") else { continue }
                guard let port = Int(address[address.index(after: separator)...]), port > 0 else { continue }
                var host = String(address[..<separator])
                if host.isEmpty { host = "*" }
                let key = "\(host):\(port)"
                if seen.insert(key).inserted {
                    ports.append(GostPort(pid: currentPID, address: host, port: port))
                }
            }
        }
        return ports
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 经代理探测

    /// 同一个端口可能是 HTTP 代理也可能是 SOCKS5 代理，两种探测同时发，谁先走完全程算谁：
    /// HTTP 按代理写法向探测目标发 HEAD；SOCKS5 先问候再 CONNECT 探测目标。
    /// 两种都把请求经代理转发到远端再回来，量到的都是完整线路的往返时间；
    /// 两者都失败或超时记为不通。
    private static func probe(port: Int) async -> GostProbeState {
        guard let endpoint = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failed }
        let start = Date()

        return await withCheckedContinuation { continuation in
            let race = ProbeRace(attempts: 2)
            let http = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
            let socks = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
            let resume: @Sendable (GostProbeState) -> Void = { state in
                guard race.claimResume() else { return }
                http.cancel()
                socks.cancel()
                continuation.resume(returning: state)
            }
            let handle: @Sendable (GostProbeState?) -> Void = { result in
                if let result {
                    resume(result)
                } else if race.recordFailure() {
                    resume(.failed)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + probeTimeout) { resume(.failed) }

            httpAttempt(connection: http, start: start, completion: handle)
            socksAttempt(connection: socks, start: start, completion: handle)
        }
    }

    /// 发 HTTP HEAD，收到任何 HTTP 响应头（含 407）都算链路通
    private static func httpAttempt(connection: NWConnection, start: Date,
                                    completion: @escaping @Sendable (GostProbeState?) -> Void) {
        singleShot(connection: connection, request: httpHeadRequest(),
                   validate: { data in
                       guard let head = String(decoding: data, as: UTF8.self)
                           .split(separator: "\r\n", maxSplits: 1).first,
                             head.hasPrefix("HTTP/") else { return nil }
                       return .ok(milliseconds: Date().timeIntervalSince(start) * 1000, kind: .http)
                   },
                   completion: completion)
    }

    /// SOCKS5：问候成功后再 CONNECT 探测目标，连接成功才说明远端线路通
    private static func socksAttempt(connection: NWConnection, start: Date,
                                     completion: @escaping @Sendable (GostProbeState?) -> Void) {
        let box = OnceBox()
        let done: @Sendable (GostProbeState?) -> Void = { result in
            guard box.claim() else { return }
            connection.cancel()
            completion(result)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: socksGreeting(), completion: .contentProcessed { error in
                    if error != nil { done(nil) }
                })
                receiveOnce(connection) { greeting in
                    // 问候应答：版本 5、选定方法 0（无认证）
                    guard let greeting, greeting.count >= 2, greeting[0] == 5, greeting[1] == 0 else { return done(nil) }
                    connection.send(content: socksConnectRequest(), completion: .contentProcessed { error in
                        if error != nil { done(nil) }
                    })
                    receiveOnce(connection) { reply in
                        // CONNECT 应答：第 2 字节为 0 表示代理已在远端连上目标
                        guard let reply, reply.count >= 2, reply[0] == 5, reply[1] == 0 else { return done(nil) }
                        done(.ok(milliseconds: Date().timeIntervalSince(start) * 1000, kind: .socks))
                    }
                }
            case .failed, .cancelled:
                done(nil)
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    /// 连上后发一段请求，第一段响应交给 `validate`：有效返回读数，无效返回 nil（本次尝试失败）
    private static func singleShot(connection: NWConnection, request: Data,
                                   validate: @escaping @Sendable (Data) -> GostProbeState?,
                                   completion: @escaping @Sendable (GostProbeState?) -> Void) {
        let box = OnceBox()
        let done: @Sendable (GostProbeState?) -> Void = { result in
            guard box.claim() else { return }
            connection.cancel()
            completion(result)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { error in
                    if error != nil { done(nil) }
                })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
                    if let data, !data.isEmpty, error == nil {
                        done(validate(data))
                    } else {
                        done(nil)
                    }
                }
            case .failed, .cancelled:
                done(nil)
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    private static func receiveOnce(_ connection: NWConnection, _ completion: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 64) { data, _, _, error in
            if let data, data.count >= 2, error == nil {
                completion(data)
            } else {
                completion(nil)
            }
        }
    }

    private static func httpHeadRequest() -> Data {
        Data(("HEAD http://\(probeHost)\(probePath) HTTP/1.1\r\n"
            + "Host: \(probeHost)\r\n"
            + "Connection: close\r\n"
            + "\r\n").utf8)
    }

    /// SOCKS5 无需认证的问候：版本 5、支持一种方法（无认证）
    private static func socksGreeting() -> Data {
        Data([0x05, 0x01, 0x00])
    }

    /// SOCKS5 CONNECT：按域名连探测目标的 80 端口
    private static func socksConnectRequest() -> Data {
        var request = Data([0x05, 0x01, 0x00, 0x03])
        let host = Data(probeHost.utf8)
        request.append(UInt8(host.count))
        request.append(host)
        request.append(contentsOf: [0, 80])  // 端口 80，网络字节序
        return request
    }
}

/// 两种握手的胜负裁定：第一个成功立即生效，全部失败才算失败；超时兜底也走这里
private final class ProbeRace: @unchecked Sendable {
    private let lock = NSLock()
    private let attempts: Int
    private var resumed = false
    private var failures = 0

    init(attempts: Int) {
        self.attempts = attempts
    }

    /// 是否轮到这次 resume 生效（只有第一次为真，含超时兜底）
    func claimResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    /// 记一次失败；全部尝试都失败时返回真
    func recordFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        failures += 1
        return failures >= attempts
    }
}

/// 回调可能从连接队列与超时队列同时进来，只放行第一个
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
