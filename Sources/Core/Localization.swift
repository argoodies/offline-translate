import Foundation

/// 取一条界面文案。
///
/// 全程英语：key 就是要显示的英文原文，包里没有任何 `.lproj`，
/// `String(localized:)` 找不到译文时原样返回 key。
///
/// 留着这层薄包装而不是散落一地的 `String(localized:)`，是为了将来要加语言时
/// 只有一个入口要改。
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}
