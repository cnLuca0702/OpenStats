import Localization
import Metrics
import SwiftUI

/// Gost 代理详情：顶部是整体状态，下面是每个端口的探测结果与进程开销。
/// 端口经代理向 cp.cloudflare.com 发一次 HEAD，约 10 秒一轮
struct GostPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let settings = model.settings
        let gost = model.store.gost

        GostHero(gost: gost)

        ForEach(MenuBarItem.gost.popoverSections.filter { isDetailPage || settings.isVisible($0) }) { section in
            switch section {
            case .gostPorts:
                SectionCard(title: section.title,
                            hint: tr("端口来自本机 gost 进程的监听列表；“延迟”是把请求经该代理转发到 Cloudflare 再回来的完整往返时间（HTTP 与 SOCKS5 自动识别），连不上或超时记为不通"),
                            trailing: { Text(tr("约每 10 秒探测")) }) {
                    if let gost {
                        if !gost.isRunning {
                            Text(tr("没有名为 gost 的进程")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                        } else if gost.ports.isEmpty {
                            Text(tr("正在查找监听端口…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                        } else {
                            ForEach(gost.ports) { port in
                                InfoRow(label: portTitle(port)) {
                                    Text(verbatim: probeText(port.probe))
                                        .foregroundStyle(probeTone(port.probe).color)
                                }
                            }
                        }
                    } else {
                        Text(tr("正在读取…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
            case .gostProcesses:
                SectionCard(title: section.title,
                            hint: tr("本机所有名为 gost 的进程；CPU 与内存和活动监视器同一口径")) {
                    if let gost {
                        if gost.processes.isEmpty {
                            Text(tr("没有名为 gost 的进程")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                        } else {
                            ForEach(gost.processes) { process in
                                VStack(spacing: DS.Space.s1) {
                                    InfoRow(label: "\(process.name) · PID \(process.pid)") {
                                        Text(verbatim: "\(Format.coreShare(process.cpu)) · \(Format.bytes(process.memoryBytes))")
                                    }
                                    if let start = process.startTime {
                                        InfoRow(label: tr("运行时长"), text: Format.uptime(since: start))
                                    }
                                }
                            }
                        }
                    } else {
                        Text(tr("正在读取…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private func portTitle(_ port: GostPort) -> String {
        let address = port.address == "*" ? tr("所有接口") : port.address
        return "\(address):\(port.port)"
    }

    private func probeText(_ probe: GostProbeState) -> String {
        switch probe {
        case let .ok(milliseconds, kind): tr("\(kind.title) · \(Int(milliseconds.rounded())) ms")
        case .failed: tr("不通")
        case .pending: tr("探测中…")
        }
    }

    private func probeTone(_ probe: GostProbeState) -> Tone {
        switch probe {
        case .ok: .success
        case .failed: .error
        case .pending: .neutral
        }
    }
}

/// 顶部：可用端口比例，右侧是进程数、端口数与最快延迟
private struct GostHero: View {
    let gost: GostStatus?

    var body: some View {
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            PopoverHero(label: tr("Gost 代理"),
                        value: heroValue,
                        valueColor: heroTone == .neutral ? DS.Palette.textPrimary : heroTone.color,
                        caption: heroCaption,
                        captionTone: heroCaptionTone,
                        stats: [
                            HeroStat(label: tr("进程"), value: processText),
                            HeroStat(label: tr("端口"), value: portText),
                            HeroStat(label: tr("延迟"), value: latencyText,
                                     tone: latencyTone,
                                     help: tr("经代理访问 Cloudflare 的往返时间，取最快的端口")),
                        ])
        }
    }

    private var value: (up: Int, total: Int)? {
        guard let gost, !gost.ports.isEmpty else { return nil }
        return (gost.healthyPortCount, gost.ports.count)
    }

    private var heroValue: String {
        guard let gost else { return "—" }
        if !gost.isRunning { return tr("未运行") }
        guard let ports = value else { return tr("查找中") }
        return "\(ports.up)/\(ports.total)"
    }

    private var heroTone: Tone {
        guard let gost, gost.isRunning, let ports = value else { return .neutral }
        if ports.up == ports.total { return .success }
        return ports.up == 0 ? .error : .warning
    }

    private var heroCaption: String? {
        guard let gost else { return nil }
        if !gost.isRunning { return tr("监控本机名为 gost 的代理进程") }
        guard let ports = value else { return tr("正在查找监听端口") }
        if let latency = gost.bestLatency, ports.up > 0 { return tr("最快延迟 \(Int(latency.rounded())) ms") }
        return ports.up == 0 ? tr("端口均不可用") : nil
    }

    private var heroCaptionTone: Tone {
        guard let ports = value else { return .neutral }
        return ports.up == ports.total ? .neutral : ports.up == 0 ? .error : .warning
    }

    private var processText: String {
        guard let gost, !gost.processes.isEmpty else { return "—" }
        return tr("\(gost.processes.count) 个")
    }

    private var portText: String {
        guard let ports = value else { return "—" }
        return "\(ports.up)/\(ports.total)"
    }

    private var latencyText: String {
        guard let latency = gost?.bestLatency else { return "—" }
        return tr("\(Int(latency.rounded())) ms")
    }

    private var latencyTone: Tone {
        guard let latency = gost?.bestLatency else { return .neutral }
        return latency > 1000 ? .warning : .neutral
    }
}
