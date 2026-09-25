import SwiftUI

/// 联网时挡在对话前面的那一页。
///
/// Aero 的主张是「不被打扰」，所以入口就把这件事变成一个动作：去打开飞行模式。
/// 检测到断网后会自动放行，不需要用户再点什么。
struct AirplaneGateView: View {
    @EnvironmentObject private var gate: NetworkGate
    @EnvironmentObject private var engine: ChatEngine

    /// 飞机图标的轻微呼吸感，让这一页不像一个死掉的错误页。
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 132, height: 132)
                    .scaleEffect(pulsing ? 1.08 : 0.94)

                Image(systemName: "airplane")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(-90))
            }
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }

            Text(String(localized: "请打开飞行模式"))
                .font(.title3.weight(.semibold))
                .padding(.top, 28)

            Text(String(localized: "Aero 完全离线运行，不需要网络。\n从右上角下拉打开控制中心，点亮飞机图标。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 36)

            statusPill
                .padding(.top, 28)

            Spacer()

            modelStatus
                .padding(.bottom, 4)

            // 留个出口。网络状态的判断依赖系统回调，真出现误判时不该把人锁死在启动页。
            Button(String(localized: "仍要继续")) {
                gate.userBypassed = true
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// 等飞行模式的这段时间里模型也在加载，让用户看得到进度。
    @ViewBuilder
    private var modelStatus: some View {
        if engine.phase == .loadingModel {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(String(localized: "正在加载模型…"))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else if engine.phase == .ready {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                Text(String(localized: "模型已就绪"))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(gate.isOffline ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(gate.isOffline
                 ? String(localized: "已离线")
                 : String(localized: "检测到网络连接"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}
