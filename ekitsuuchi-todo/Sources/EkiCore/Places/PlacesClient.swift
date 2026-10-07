import Foundation

/// Google Places API (New) v1 のクライアント。差し替え口 1・2（店の検索／営業時間）の v0 実装（§5）。
/// 旧 Places API は新規プロジェクトでは使えないので (New) を使う。
///
/// API キーは `X-Goog-Api-Key` ヘッダにだけ載せる。URL・ボディ・ログ・エラー文言には出さない
/// （URL はプロキシやクラッシュログに残りやすい）。
public struct PlacesClient: StoreSearching, BusinessHoursProviding, Sendable {
    private static let baseURL = "https://places.googleapis.com/v1"
    /// locationBias.circle.radius の上限（API の仕様）。
    private static let maxBiasRadiusMeters = 50_000.0

    private let apiKey: String
    private let transport: HTTPTransport
    private let languageCode: String
    private let regionCode: String

    public init(apiKey: String, transport: HTTPTransport, languageCode: String = "ja", regionCode: String = "JP") {
        // ビルド設定やコピペで混ざる前後の空白・改行はヘッダを壊すので落とす。
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.languageCode = languageCode
        self.regionCode = regionCode
    }

    // MARK: StoreSearching

    public func searchBranches(chainName: String, near center: Coordinate, radiusMeters: Double) async throws -> [BranchCandidate] {
        try requireKey()
        // JSON に載せられない座標（NaN/∞）は EncodingError ではなく PlacesError で返す。
        guard center.latitude.isFinite, center.longitude.isFinite else {
            throw PlacesError.badRequest("座標が不正です")
        }
        // 空のチェーン名は突き合わせが全件一致になってしまう（D12）ので、問い合わせずに空で返す。
        let chainKey = ChainName.key(chainName)
        guard !chainKey.isEmpty, radiusMeters.isFinite, radiusMeters > 0 else { return [] }

        let body = PlacesAPI.SearchTextRequest(
            textQuery: chainName.trimmingCharacters(in: .whitespacesAndNewlines),
            languageCode: languageCode,
            regionCode: regionCode,
            pageSize: 20,
            locationBias: .init(circle: .init(
                center: .init(latitude: center.latitude, longitude: center.longitude),
                radius: min(radiusMeters, Self.maxBiasRadiusMeters)
            ))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = HTTPRequest(
            url: Self.baseURL + "/places:searchText",
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "X-Goog-Api-Key": apiKey,
                "X-Goog-FieldMask": "places.id,places.displayName,places.location",
            ],
            body: try encoder.encode(body)
        )
        let response: PlacesAPI.SearchTextResponse = try await perform(request)

        // locationBias は「寄せる」だけで範囲を保証しない。半径内かどうかは自前の haversine で決める（D12）。
        var seen = Set<String>()
        var found: [(candidate: BranchCandidate, meters: Double)] = []
        for place in response.places ?? [] {
            guard let id = place.id, !id.isEmpty,
                  let name = place.displayName?.text,
                  let lat = place.location?.latitude, let lon = place.location?.longitude,
                  ChainName.key(name).contains(chainKey) else { continue }
            let coordinate = Coordinate(latitude: lat, longitude: lon)
            let meters = center.distance(to: coordinate)
            guard meters <= radiusMeters, seen.insert(id).inserted else { continue }
            found.append((BranchCandidate(placeID: id, name: name, coordinate: coordinate), meters))
        }
        // 同距離は id 順（実行ごとに並びが変わらないように）。
        found.sort { ($0.meters, $0.candidate.placeID) < ($1.meters, $1.candidate.placeID) }
        return found.map(\.candidate)
    }

    // MARK: BusinessHoursProviding

    public func openingHours(placeID: String) async throws -> OpeningHours? {
        try requireKey()
        var id = placeID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("places/") { id.removeFirst("places/".count) }   // resource name で渡されても受ける
        guard !id.isEmpty else { throw PlacesError.badRequest("placeID が空です") }

        let request = HTTPRequest(
            url: Self.baseURL + "/places/" + Self.escape(id)
                + "?languageCode=" + Self.escape(languageCode) + "&regionCode=" + Self.escape(regionCode),
            method: "GET",
            headers: [
                "X-Goog-Api-Key": apiKey,
                "X-Goog-FieldMask": "regularOpeningHours,currentOpeningHours,timeZone",
            ]
        )
        let response: PlacesAPI.PlaceHoursResponse = try await perform(request)
        return PlacesHoursMapper.map(response)
    }

    // MARK: transport

    private func requireKey() throws {
        if apiKey.isEmpty { throw PlacesError.missingAPIKey }
    }

    private func perform<T: Decodable>(_ request: HTTPRequest) async throws -> T {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else { throw error(for: response) }
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw PlacesError.malformedResponse(redact(Self.describe(error)))
        }
    }

    private func error(for response: HTTPResponse) -> PlacesError {
        let message = errorMessage(from: response)
        switch response.status {
        case 400: return .badRequest(message)
        case 401, 403: return .permissionDenied(message)
        case 404: return .notFound(message)
        case 429: return .rateLimited
        case 500...: return .server(response.status)
        default: return .badRequest(message)
        }
    }

    /// `{"error":{"code","message","status"}}` から人が読める 1 行を取る。読めなければ HTTP ステータスだけ。
    private func errorMessage(from response: HTTPResponse) -> String {
        let inner = (try? JSONDecoder().decode(PlacesAPI.ErrorBody.self, from: response.body))?.error
        let raw = [inner?.message, inner?.status]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "HTTP \(response.status)"
        return String(redact(raw).prefix(300))
    }

    /// 万一サーバのメッセージがキーを含んでいても、履歴やログに出さない。
    private func redact(_ text: String) -> String {
        apiKey.isEmpty ? text : text.replacingOccurrences(of: apiKey, with: "***")
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        switch decoding {
        case .dataCorrupted(let c): return c.debugDescription
        case .keyNotFound(let k, _): return "キーがありません: \(k.stringValue)"
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "型が違います: \(c.debugDescription)"
        @unknown default: return "decoding error"
        }
    }

    /// パス/クエリの 1 要素用。unreserved 以外は全部パーセントエンコード（"/" "?" も）。
    private static func escape(_ s: String) -> String {
        // CharacterSet.alphanumerics は全角英数字も含むので使わない。
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// キーが print / dump / ログ補間に出ないようにする。
extension PlacesClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "PlacesClient(apiKey: <redacted>, language: \(languageCode), region: \(regionCode))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
