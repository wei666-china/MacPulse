import Foundation

/// 动态 key 的本地化查表:枚举 rawValue 这类「既当标识又当显示文本」的字符串,
/// 定义处必须保持字面量,显示处用这个函数过一遍。查不到就原样返回中文——
/// 与全局 String(localized:) 的兜底行为一致,永远不会显示成空或 key 名。
func L(_ key: String) -> String {
    String(localized: String.LocalizationValue(key))
}
