import Foundation

/// タスクの「店」と支店台帳の「チェーン名」を突き合わせるための正規化（コンテンツ設計書 §2: 一致させる）。
/// 全角/半角・大文字/小文字・空白の違いで別のチェーンにならないようにする。
public enum ChainName {
    /// NFKC fold, lowercase, all whitespace removed. "ＤＡＩＳＯ " == "daiso".
    public static func key(_ name: String) -> String {
        let folded = name.precomposedStringWithCompatibilityMapping.lowercased()
        return String(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    public static func matches(_ a: String, _ b: String) -> Bool {
        let ka = key(a)
        return !ka.isEmpty && ka == key(b)
    }
}
