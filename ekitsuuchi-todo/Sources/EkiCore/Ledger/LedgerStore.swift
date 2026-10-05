import Foundation

/// 台帳の保存先。Core はこの口しか知らない（実体は JSON ファイル。テスト・プレビューはメモリ）。
/// 同期 API にしてあるのは、`LedgerRepository` の変更中に中断点（await）を作らないため。
public protocol LedgerStore: Sendable {
    func load() throws -> Ledger
    func save(_ ledger: Ledger) throws
}

public enum LedgerStoreError: Error, Equatable {
    /// 読めないファイルを `backupPath` に退避した。次の `load()` は空の台帳から始まる。
    case corrupt(backupPath: String)
    /// より新しいアプリが書いたファイル。古いアプリで開いて壊さないよう、手を付けずに断る。
    case newerSchema(found: Int, supported: Int)
}

extension LedgerStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .corrupt(let path):
            return "台帳ファイルを読めなかったため退避しました（\(path)）。"
        case .newerSchema(let found, let supported):
            return "台帳がより新しい版のアプリで作られています（版 \(found)、このアプリは \(supported) まで）。"
        }
    }
}

/// テスト・プレビュー用。
public final class InMemoryLedgerStore: LedgerStore, @unchecked Sendable {
    // 複数スレッドから触られるので全アクセスをロックの内側に置く。
    private let lock = NSLock()
    private var ledger: Ledger
    private var saves = 0

    public init(_ ledger: Ledger = Ledger()) {
        self.ledger = ledger
    }

    public func load() throws -> Ledger {
        lock.lock(); defer { lock.unlock() }
        return ledger
    }

    public func save(_ ledger: Ledger) throws {
        lock.lock(); defer { lock.unlock() }
        self.ledger = ledger
        saves += 1
    }

    /// 保存済みの中身（テストで確認する用）。
    public var stored: Ledger {
        lock.lock(); defer { lock.unlock() }
        return ledger
    }

    public var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return saves
    }
}

/// 台帳を 1 つの JSON ファイルとして保存する。
///
/// - 書き込みは `Data.write(options: .atomic)`（一時ファイル→置換）。途中で落ちても半端なファイルは残らない。
/// - 読めないファイルは **上書きしない**。`<name>.corrupt-<unixtime>` に退避してから `.corrupt` を投げる。
///   空の台帳で次の保存が走っても、人が書いたタスクが消えない。
/// - `schemaVersion` が新しすぎるファイルは触らずに `.newerSchema`。
/// - IMPORTANT: `.completeFileProtection` は付けない。領域監視の入域イベントは端末ロック中に
///   アプリを起こす。完全保護だとそのとき台帳を読み書きできず、通知が出ない。
///   iOS の既定（初回アンロックまで保護 = CompleteUntilFirstUserAuthentication）が必要な設定。
public struct JSONFileLedgerStore: LedgerStore {
    public let url: URL
    private let now: @Sendable () -> Date

    /// - Parameter now: 退避ファイル名の時刻。テストで固定するための差し込み口。
    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public func load() throws -> Ledger {
        let fm = FileManager.default
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // ファイルが無いのは初回起動。それ以外（権限・保護など）の読み取り失敗は壊れとは違うので、そのまま投げる。
            if !fm.fileExists(atPath: url.path) { return Ledger() }
            throw error
        }

        // 本体を読む前に版だけ見る。新しい版の中身はこのアプリの型では読めないことがある。
        struct Header: Decodable { var schemaVersion: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw try quarantine()
        }
        if let found = header.schemaVersion, found > Ledger.currentSchemaVersion {
            throw LedgerStoreError.newerSchema(found: found, supported: Ledger.currentSchemaVersion)
        }
        do {
            return try Self.makeDecoder().decode(Ledger.self, from: data)
        } catch {
            throw try quarantine()
        }
    }

    public func save(_ ledger: Ledger) throws {
        var copy = ledger
        copy.schemaVersion = Ledger.currentSchemaVersion
        let data = try Self.makeEncoder().encode(copy)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 壊れたファイルの退避

    /// 壊れたファイルを脇へ動かし、投げるべきエラーを返す。動かせなかったときはその失敗を投げる
    /// （壊れたまま放置すると次の保存が上書きしてしまうので、`.corrupt` を装わない）。
    private func quarantine() throws -> LedgerStoreError {
        let fm = FileManager.default
        let stamp = Int(now().timeIntervalSince1970)
        let dir = url.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        var n = 1
        // 同じ秒に 2 回壊れても、先に退避したものを潰さない。
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(n)")
            n += 1
        }
        try fm.moveItem(at: url, to: candidate)
        return .corrupt(backupPath: candidate.path)
    }

    // MARK: - JSON

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(LedgerDateCoding.string(from: date))
        }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = LedgerDateCoding.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 date: \(s)"))
            }
            return date
        }
        return d
    }
}
