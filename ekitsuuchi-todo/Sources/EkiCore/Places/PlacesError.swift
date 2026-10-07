import Foundation

/// Places API 呼び出しの失敗。履歴・店画面にそのまま出せるよう Japanese の説明を持つ。
/// ネットワーク自体の失敗（オフライン等）は `HTTPTransport` の投げた Error をそのまま通す。
public enum PlacesError: Error, Equatable, Sendable {
    /// キーが空。リクエストを出す前に弾く（無駄な 403 とログ汚れを避ける）。
    case missingAPIKey
    /// 400 とその他の想定外ステータス。
    case badRequest(String)
    /// 401 / 403: キーの制限（バンドル ID・API の種類）や課金設定の問題が多い。
    case permissionDenied(String)
    case notFound(String)
    /// 429: 割り当て超過。次回に回す。
    case rateLimited
    /// 5xx。
    case server(Int)
    /// 2xx なのに読めない。
    case malformedResponse(String)
}

extension PlacesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Places の API キーが設定されていません"
        case .badRequest(let m):
            return "Places への問い合わせが不正です: \(m)"
        case .permissionDenied(let m):
            return "Places の利用が許可されていません（キーの制限・課金設定を確認）: \(m)"
        case .notFound(let m):
            return "Places に該当する場所がありません: \(m)"
        case .rateLimited:
            return "Places の利用上限に達しました。時間をおいて再取得します"
        case .server(let code):
            return "Places 側のエラーです（\(code)）"
        case .malformedResponse(let m):
            return "Places の応答を読めませんでした: \(m)"
        }
    }
}
