import Foundation

/// ビルド時に xcconfig（Secrets.xcconfig、git 管理外）→ Info.plist へ埋め込まれた値を読む。
/// キーをソースや履歴に置かないための経路。値はログに出さない。
enum AppSecrets {
    /// 空文字 = 未設定（Secrets.xcconfig が無い CI ビルドなど）。呼び出し側は「キー未設定」として扱う。
    static var placesAPIKey: String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PlacesAPIKey") as? String else { return "" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // xcconfig に変数が無いと "$(PLACES_API_KEY)" がそのまま入る。サンプルの置き場所文字列も未設定扱い。
        if value.hasPrefix("$(") || value == "PASTE_YOUR_KEY_HERE" { return "" }
        return value
    }
}
