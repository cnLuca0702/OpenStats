import Localization
import SwiftUI

/// 设置 · 监控大屏：开关、端口与当前地址
struct DashboardSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        SettingsGroup {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("启用监控大屏"), subtitle: tr("同一局域网里的设备（平板、旧电脑、电视的浏览器）打开下面的地址，即可实时查看本机监控，适合挂一块监控屏")) {
                    DSToggle(isOn: $settings.dashboardEnabled, label: tr("启用监控大屏"))
                }
            }
            GroupRow {
                SettingRow(title: tr("端口")) {
                    SegmentedControl(selection: $settings.dashboardPort,
                                     options: AppSettings.dashboardPortOptions.map { ($0, "\($0)") })
                        .frame(width: DS.Size.sidebarWidth)
                }
            }
            GroupRow {
                status
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.dashboard.availability {
        case .off:
            SettingRow(title: tr("状态")) {
                Text(tr("未开启"))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        case .starting(let port):
            SettingRow(title: tr("状态")) {
                Text(tr("正在启动 · 端口 \(port)"))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        case .running(let port):
            SettingRow(title: tr("状态")) {
                VStack(alignment: .trailing, spacing: DS.Space.s1) {
                    Text(tr("服务运行中 · 端口 \(port)"))
                        .foregroundStyle(DS.Palette.success)
                    if let address = model.dashboard.address {
                        Text(address).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        case .failed(let port, let reason):
            SettingRow(title: tr("状态"), subtitle: reason) {
                Text(tr("端口 \(port) 启动失败"))
                    .foregroundStyle(DS.Palette.error)
            }
        }
    }
}
