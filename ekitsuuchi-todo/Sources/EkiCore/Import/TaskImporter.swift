import Foundation

// 入力 JSON v1（設計書 §2 / 計画書 M4）。A（LINE・Notion の自動抽出）もこの形で吐けば繋がる。
//   {"version":1,"items":[{"store":"ダイソー","item":"フィルム","source":"LINE:友人","date":"2026-09-14"}]}

/// ファイル全体を受け付けられないときのエラー。行ごとの不備はここではなく `RejectedRow` になる。
public enum ImportError: Error, Equatable {
    /// JSON として読めない、または最上位がオブジェクトではない。
    case notJSON
    case missingVersion
    /// 対応していない version。値は画面に出す用の文字列。
    case unsupportedVersion(String)
    /// `items` が無い、または配列ではない。
    case itemsNotArray
}

extension ImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notJSON: return "JSON として読めません（最上位は {…} にしてください）。"
        case .missingVersion: return "version がありません（\"version\": 1 が必要です）。"
        case .unsupportedVersion(let v): return "version \(v) には対応していません（対応: \(TaskImporter.supportedVersion)）。"
        case .itemsNotArray: return "items が配列ではありません。"
        }
    }
}

/// 取り込めなかった 1 行。1 行の不備でファイル全体を失敗させない（残りは取り込む）。
public struct RejectedRow: Equatable, Sendable {
    /// `items` 配列内の位置（0 始まり）。画面に出すときは +1 する。
    public var index: Int
    /// 人が読める理由（日本語）。
    public var reason: String

    public init(index: Int, reason: String) {
        self.index = index
        self.reason = reason
    }
}

public struct ImportParseResult: Equatable, Sendable {
    public var items: [InflowItem]
    public var rejected: [RejectedRow]

    public init(items: [InflowItem], rejected: [RejectedRow]) {
        self.items = items
        self.rejected = rejected
    }
}

/// `LedgerRepository.importItems` の結果。
public struct ImportSummary: Equatable, Sendable {
    /// 実際に台帳へ入ったタスク。
    public var added: [TodoTask]
    /// 既にある（`TaskDedupe`）ため入れなかった件数。ファイル内の重複も含む。
    public var duplicates: Int
    /// 店または品目が空で入れなかった件数（`TaskImporter` を通した入力では 0。他の流入口の保険）。
    public var invalid: Int
    /// 入力に出てきたが、まだ店登録されていないチェーン名（重複行のぶんも含む。登録は冪等なので、
    /// 前回の登録が失敗していても再試行できる）。初出の表記で、同じチェーンは 1 つにまとめる。
    public var chainsNeedingRegistration: [String]

    public init(added: [TodoTask] = [], duplicates: Int = 0, invalid: Int = 0, chainsNeedingRegistration: [String] = []) {
        self.added = added
        self.duplicates = duplicates
        self.invalid = invalid
        self.chainsNeedingRegistration = chainsNeedingRegistration
    }
}

public enum TaskImporter {
    public static let supportedVersion = 1
    /// `source` が無い行に入れる値。
    public static let defaultSource = "JSON取込"

    public static func parse(_ data: Data) throws -> ImportParseResult {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: stripBOM(data))
        } catch {
            throw ImportError.notJSON
        }
        guard case .object(let top) = root else { throw ImportError.notJSON }

        guard let versionValue = top["version"], versionValue != .null else { throw ImportError.missingVersion }
        guard case .number(let v) = versionValue, v == Double(supportedVersion) else {
            throw ImportError.unsupportedVersion(versionValue.shortDescription)
        }
        guard case .array(let rows)? = top["items"] else { throw ImportError.itemsNotArray }

        var items: [InflowItem] = []
        var rejected: [RejectedRow] = []
        for (index, row) in rows.enumerated() {
            switch parseRow(row) {
            case .success(let item): items.append(item)
            case .failure(let reason): rejected.append(RejectedRow(index: index, reason: reason))
            }
        }
        return ImportParseResult(items: items, rejected: rejected)
    }

    // メモ帳等が付ける UTF-8 BOM。JSONDecoder は BOM 付きを受け付けないことがある。
    private static func stripBOM(_ data: Data) -> Data {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        guard data.count >= 3, Array(data.prefix(3)) == bom else { return data }
        return Data(data.dropFirst(3))
    }

    private enum RowResult {
        case success(InflowItem)
        case failure(String)
    }

    private static func parseRow(_ row: JSONValue) -> RowResult {
        guard case .object(let o) = row else { return .failure("行がオブジェクトではありません") }

        guard let store = nonBlankString(o["store"]) else { return .failure(missingText("store", o["store"])) }
        guard let item = nonBlankString(o["item"]) else { return .failure(missingText("item", o["item"])) }

        var source = defaultSource
        switch o["source"] {
        case nil, .null?:
            break
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { source = t }
        default:
            return .failure("source は文字列にしてください")
        }

        var date: CalendarDay?
        switch o["date"] {
        case nil, .null?:
            break
        case .string(let s)?:
            // 厳密に yyyy-MM-dd だけ。前後の空白や 2026-9-14 は拒否する（出典日の誤読を黙って通さない）。
            // CalendarDay(isoString:) は Int() 経由で "+026" や "+9" も通すため、書き戻して一致するかも見る。
            guard let d = CalendarDay(isoString: s), d.isoString == s else {
                return .failure("date は yyyy-MM-dd の形式にしてください（\(s)）")
            }
            date = d
        default:
            return .failure("date は yyyy-MM-dd の文字列にしてください")
        }

        return .success(InflowItem(store: store, item: item, source: source, date: date))
    }

    private static func nonBlankString(_ v: JSONValue?) -> String? {
        guard case .string(let s)? = v else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func missingText(_ key: String, _ v: JSONValue?) -> String {
        switch v {
        case nil, .null?: return "\(key) がありません"
        case .string?: return "\(key) が空です"
        default: return "\(key) は文字列にしてください"
        }
    }
}

/// 型の違い（数値・真偽値・文字列）を取り違えずに行ごとに判定するための最小の JSON 木。
/// JSONSerialization は Darwin では true が数値 1 に化けるなど、環境差があるので使わない。
private enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        // 残るのは 1e999 のように Double に収まらない数だけ（構文は読み込み時に検証済み）。
        // ここで投げると、無関係な余計なキーひとつでファイル全体が notJSON になる。
        else { self = .number(.infinity) }
    }

    var shortDescription: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return "\"\(s)\""
        case .array: return "配列"
        case .object: return "オブジェクト"
        }
    }
}

/// `TaskInflow`（差し替え口 3）の v0 実装の 1 つ。JSON のバイト列から取り出す。
/// 取り込めなかった行は返さない（件数を出したい呼び出し側は `TaskImporter.parse` を直接使う）。
public struct JSONDataInflow: TaskInflow {
    private let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public func fetchItems() async throws -> [InflowItem] {
        try TaskImporter.parse(data).items
    }
}
