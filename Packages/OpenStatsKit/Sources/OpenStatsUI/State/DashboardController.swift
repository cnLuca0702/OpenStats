import AppKit
import Foundation
import Localization
import Metrics
import Observation
import SystemConfiguration

/// 线程间传递最新 /metrics 内容的小盒子
final class DashboardPayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data("{}".utf8)

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func update(_ data: Data) {
        lock.lock()
        stored = data
        lock.unlock()
    }
}

/// 监控大屏：把 MetricsStore 里的读数每 2 秒整理成一份 JSON，经 DashboardServer 发给局域网里的
/// 任意设备（平板、旧电脑、电视浏览器），配合全屏模式当监控墙用。数据不出局域网
@MainActor
@Observable
public final class DashboardController {
    /// 服务可用性；running 时附带端口
    public enum Availability: Equatable {
        case off
        case starting(port: Int)
        case running(port: Int)
        case failed(port: Int, reason: String)
    }

    public private(set) var availability: Availability = .off
    public static let sampleInterval: TimeInterval = 2
    static let historyPoints = 150   // 150 × 2s = 5 分钟走势

    private let settings: AppSettings
    private let store: MetricsStore
    @ObservationIgnored let payloadBox = DashboardPayloadBox()
    @ObservationIgnored private let server: DashboardServer
    @ObservationIgnored private var sampler: Task<Void, Never>?
    /// 走势样本：时间、CPU%、内存%、累计下载 / 上传字节（网页端按差值算速率）
    struct Sample {
        let time: TimeInterval
        let cpu: Double
        let memory: Double
        let totalDown: Double
        let totalUp: Double
    }
    private var samples: [Sample] = []
    private var totalDown: Double = 0
    private var totalUp: Double = 0

    init(settings: AppSettings, store: MetricsStore) {
        self.settings = settings
        self.store = store
        server = DashboardServer(page: { DashboardPage.localizedHTML() }) { [payloadBox] in payloadBox.value }
        if settings.dashboardEnabled {
            applySettings()
        }
    }

    // MARK: 生命周期

    /// 开关或端口变化后调用（含云同步套用的设置）；幂等，当前端口已在启动或运行则不动
    public func applySettings() {
        guard settings.dashboardEnabled else {
            if availability != .off { stop() }
            return
        }
        let port = settings.dashboardPort
        switch availability {
        case .starting(let current), .running(let current):
            if current == port { return }
        case .off, .failed:
            break
        }
        availability = .starting(port: port)
        server.start(port: UInt16(clamping: port))
        if sampler == nil {
            sampler = Task { [weak self] in
                while !Task.isCancelled {
                    let start = Date()
                    await self?.sampleOnce()
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed < Self.sampleInterval {
                        try? await Task.sleep(for: .seconds(Self.sampleInterval - elapsed))
                    }
                }
            }
        }
    }

    public func stop() {
        sampler?.cancel()
        sampler = nil
        server.stop()
        availability = .off
    }

    /// 展示用地址：优先主网络接口的 IPv4
    public var address: String? {
        guard case .running = availability else { return nil }
        let host = store.networkInterface?.ipv4 ?? "127.0.0.1"
        return "http://\(host):\(settings.dashboardPort)/"
    }

    // MARK: 采样

    func sampleOnce() {
        // 监听状态（端口被占用等）在采样循环里轮询，最多晚 2 秒反映到设置页
        if case .starting(let port) = availability, let state = server.currentState() {
            availability = state.ready
                ? .running(port: port)
                : .failed(port: port, reason: state.reason ?? tr("未知错误"))
        }

        let now = Date()
        let network = store.network
        // 网页端的走势按累计字节的差值算速率，这里把瞬时速率积分成累计值
        totalDown += (network?.downloadBytesPerSecond ?? 0) * Self.sampleInterval
        totalUp += (network?.uploadBytesPerSecond ?? 0) * Self.sampleInterval
        let sample = Sample(time: now.timeIntervalSince1970,
                            cpu: (store.cpu?.total ?? 0) * 100,
                            memory: (store.memory?.usedFraction ?? 0) * 100,
                            totalDown: totalDown,
                            totalUp: totalUp)
        samples.append(sample)
        if samples.count > Self.historyPoints { samples.removeFirst(samples.count - Self.historyPoints) }
        payloadBox.update(buildPayload(sample: sample))
    }

    /// 组装 /metrics；抽成可单测的纯读取
    func buildPayload(sample: Sample) -> Data {
        let cpu = store.cpu
        let memory = store.memory
        let disk = store.disk
        let gigabyte = 1_000_000_000.0
        let gibibyte = 1_073_741_824.0

        var system: [String: Any] = [
            "time": sample.time,
            "hostname": Self.hostname,
            "cpu": sample.cpu,
            "cpuPercpu": (cpu?.perCore ?? []).map { ($0 * 100).rounded(.toNearestOrAwayFromZero) },
            "load": (cpu?.loadAverage ?? [0, 0, 0]).map { ($0 * 100).rounded() / 100 },
            "memUsedGB": memory.map { Double($0.used) / gibibyte } ?? 0,
            "memTotalGB": memory.map { Double($0.total) / gibibyte } ?? 0,
            "memPercent": sample.memory,
            "swapPercent": ((memory.flatMap { $0.swapTotal > 0 ? Double($0.swapUsed) / Double($0.swapTotal) * 100 : 0 } ?? 0) * 10).rounded() / 10,
            "netDownBps": (store.network?.downloadBytesPerSecond ?? 0).rounded(),
            "netUpBps": (store.network?.uploadBytesPerSecond ?? 0).rounded(),
            "diskUsedGB": disk.map { (Double($0.used) / gigabyte * 10).rounded() / 10 } ?? 0,
            "diskTotalGB": disk.map { (Double($0.total) / gigabyte * 10).rounded() / 10 } ?? 0,
            "diskPercent": disk.map { ($0.usedFraction * 1000).rounded() / 10 } ?? 0,
            "uptimeSec": store.system.bootDate.map { Date().timeIntervalSince($0).rounded() } ?? 0,
        ]
        if let battery = store.battery {
            system["batteryPercent"] = (battery.level * 100).rounded()
        } else {
            system["batteryPercent"] = NSNull()
        }
        system["processes"] = topProcesses()

        let history: [String: Any] = [
            "cpu": samples.map(\.cpu),
            "mem": samples.map(\.memory),
            "netDown": samples.map(\.totalDown),
            "netUp": samples.map(\.totalUp),
            "time": samples.map(\.time),
        ]

        let payload: [String: Any] = [
            "system": system,
            "history": history,
            "gost": gostPayload(),
            "sampleInterval": Self.sampleInterval,
            "serverTime": Date().timeIntervalSince1970,
        ]
        // NaN / 无穷大会让 JSONSerialization 抛 Objective-C 异常直接崩溃，先换成 null
        let safe = Self.jsonSafe(payload)
        guard JSONSerialization.isValidJSONObject(safe) else { return Data("{}".utf8) }
        return (try? JSONSerialization.data(withJSONObject: safe)) ?? Data("{}".utf8)
    }

    /// 递归把非有限的浮点数换成 NSNull，其余值原样保留
    nonisolated static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonSafe)
        case let array as [Any]:
            return array.map(jsonSafe)
        case let number as Double where !number.isFinite:
            return NSNull()
        default:
            return value
        }
    }

    /// 电脑名称（“系统设置 › 通用 › 共享”里那个）。读 SystemConfiguration 的本地缓存，
    /// 不像 Host.current() 那样可能做 DNS 反查卡住主线程；只取一次，改名后重启生效
    private static let hostname: String = {
        if let name = SCDynamicStoreCopyComputerName(nil, nil).map({ $0 as String }), !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }()

    /// CPU 前六名；CPU 口径与活动监视器一致（单核满载为 100%）
    private func topProcesses() -> [[String: Any]] {
        let total = Double(store.memory?.total ?? 0)
        return store.processes
            .sorted { $0.cpu > $1.cpu }
            .prefix(6)
            .map { process in
                [
                    "pid": process.pid,
                    "name": process.name,
                    "cpu": (process.cpu * 100).rounded() / 100,
                    "mem": total > 0 ? (Double(process.memory) / total * 100 * 10).rounded() / 10 : 0,
                ] as [String: Any]
            }
    }

    private func gostPayload() -> [String: Any] {
        guard let gost = store.gost else {
            return ["running": false, "ports": [] as [[String: Any]], "processes": [] as [[String: Any]],
                    "upCount": 0, "totalPorts": 0, "bestMs": NSNull()]
        }
        let ports: [[String: Any]] = gost.ports.map { port in
            var item: [String: Any] = [
                "address": port.address == "*" ? "0.0.0.0" : port.address,
                "port": port.port,
                "pid": port.pid,
                "state": port.probe.isOK ? "ok" : (port.probe == .failed ? "failed" : "pending"),
                "history": port.latencyHistory.map { entry -> Any in if let entry { return entry } else { return NSNull() } },
            ]
            if let ms = port.probe.milliseconds { item["ms"] = ms.rounded() } else { item["ms"] = NSNull() }
            if let probedAt = port.probedAt { item["probedAt"] = probedAt.timeIntervalSince1970 } else { item["probedAt"] = NSNull() }
            if case .ok(_, let kind) = port.probe { item["kind"] = kind.title }
            return item
        }
        let processes: [[String: Any]] = gost.processes.map { process in
            [
                "pid": process.pid,
                "cpu": (process.cpu * 100).rounded() / 100,
                "memMB": (Double(process.memoryBytes) / 1_048_576 * 10).rounded() / 10,
                "uptimeSec": process.startTime.map { Date().timeIntervalSince($0).rounded() } ?? 0,
            ]
        }
        let upCount = gost.ports.filter(\.probe.isOK).count
        var result: [String: Any] = [
            "running": gost.isRunning,
            "ports": ports,
            "processes": processes,
            "upCount": upCount,
            "totalPorts": gost.ports.count,
        ]
        if let best = gost.bestLatency { result["bestMs"] = best.rounded() } else { result["bestMs"] = NSNull() }
        return result
    }
}
