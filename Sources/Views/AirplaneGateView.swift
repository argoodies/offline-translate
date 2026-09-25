import SwiftUI

/// 联网时挡在对话前面的那一页。
///
/// Aero 的主张是「不被打扰」，所以入口就把这件事变成一个动作：去打开飞行模式。
/// 检测到断网后会自动放行，不需要用户再点什么 —— 也没有别的路可走，这是硬条件。
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
                    .fill(Palette.surfaceSunken)
                    .frame(width: 132, height: 132)
                    .scaleEffect(pulsing ? 1.08 : 0.94)

                Image(systemName: "airplane")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Palette.ink)
            }
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }

            Text(L("Turn on Airplane Mode"))
                .font(.title3.weight(.semibold))
                .padding(.top, 28)

            Text(L("Aero runs entirely offline and needs no network.\nSwipe down from the top-right for Control Center, then tap the airplane."))
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 36)

            statusPill
                .padding(.top, 28)

            Spacer()

            modelStatus
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }

    /// 等飞行模式的这段时间里模型也在加载，让用户看得到进度。
    @ViewBuilder
    private var modelStatus: some View {
        if engine.phase == .loadingModel {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("Loading model…"))
            }
            .font(.caption2)
            .foregroundStyle(Palette.inkTertiary)
        } else if engine.phase == .ready {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                Text(L("Model ready"))
            }
            .font(.caption2)
            .foregroundStyle(Palette.inkTertiary)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(Palette.ink, lineWidth: 1.5)
                .background(Circle().fill(gate.isOffline ? Palette.ink : Color.clear))
                .frame(width: 9, height: 9)
            Text(gate.isOffline
                 ? L("Offline")
                 : L("Network connection detected"))
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.surfaceSunken, in: Capsule())
    }
}
