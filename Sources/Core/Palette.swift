import SwiftUI

/// 全 app 的配色。
///
/// 只有黑白灰：白底黑字，没有强调色。所有灰阶都是中性灰，不用系统那套带蓝调的
/// `systemGray` —— 混在纯白背景上能看出偏色。
///
/// 界面锁定浅色外观（见 `PlaiApp`），所以这里可以写死具体明度，不必区分深浅模式。
enum Palette {
    /// 页面底色。
    static let canvas = Color.white
    /// 正文。
    static let ink = Color.black
    /// 次要文字：说明、时间戳、状态。
    static let inkSecondary = Color(white: 0.42)
    /// 更弱的一层：占位符、脚注。
    static let inkTertiary = Color(white: 0.62)

    /// 模型回复的气泡底色。
    static let bubbleAssistant = Color(white: 0.955)
    /// 用户消息的气泡底色 —— 反过来，黑底白字。
    static let bubbleUser = Color.black
    static let bubbleUserText = Color.white

    /// 代码块、思考过程这类嵌套块，要比气泡再深一档才分得开。
    static let surfaceSunken = Color(white: 0.92)
    /// 输入框底色。
    static let field = Color(white: 0.95)
    /// 分隔线。
    static let hairline = Color(white: 0.88)
}
