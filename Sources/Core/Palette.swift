import SwiftUI
import UIKit

/// 全 app 的配色。
///
/// 只有黑白灰，没有强调色。深色模式下整套反过来：底变黑、字变白，用户气泡也跟着翻，
/// 始终是界面上唯一的大块反色。
///
/// 灰阶都是中性灰，不用系统那套 `systemGray` —— 后者带蓝调，铺在纯白上能看出偏色。
enum Palette {
    /// 页面底色。
    static let canvas = adaptive(light: 1.00, dark: 0.00)
    /// 正文。
    static let ink = adaptive(light: 0.00, dark: 1.00)
    /// 次要文字：说明、时间戳、状态。
    static let inkSecondary = adaptive(light: 0.42, dark: 0.64)
    /// 更弱的一层：占位符、脚注。
    static let inkTertiary = adaptive(light: 0.62, dark: 0.46)

    /// 模型回复的气泡底色。
    static let bubbleAssistant = adaptive(light: 0.955, dark: 0.13)
    /// 用户消息的气泡底色 —— 反过来，浅色下黑底白字，深色下白底黑字。
    static let bubbleUser = adaptive(light: 0.00, dark: 1.00)
    static let bubbleUserText = adaptive(light: 1.00, dark: 0.00)

    /// 代码块、错误条这类嵌套块，要比气泡再深一档才分得开。
    static let surfaceSunken = adaptive(light: 0.92, dark: 0.19)
    /// 输入框底色。
    static let field = adaptive(light: 0.95, dark: 0.16)
    /// 分隔线。
    static let hairline = adaptive(light: 0.88, dark: 0.26)

    /// 按当前外观取明度。
    ///
    /// 用 `UIColor` 的动态构造而不是两个静态 `Color`：系统切换深浅色时它会自己重算，
    /// 不需要在视图里读 `colorScheme` 再手动挑一个。
    private static func adaptive(light: Double, dark: Double) -> Color {
        Color(UIColor { trait in
            UIColor(white: trait.userInterfaceStyle == .dark ? dark : light, alpha: 1)
        })
    }
}
