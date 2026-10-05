import Foundation

/// 重複の規則（決定 D5、設計書 §2「同じ店＋品目が未完了で既にあれば追加しない」）。
/// 同じ店（`ChainName.key`）かつ同じ品目（NFKC・小文字・空白を畳む）で、状態が完了ではないタスクがあれば重複。
/// 「無視」も“既にある”に数える（通知だけ止めて残しているだけなので、別に積み直さない）。完了済みは数えない（また買う）。
public enum TaskDedupe {
    /// 全角/半角・大文字/小文字・前後と連続する空白の違いを無視するための正規化。
    public static func normalizedItem(_ item: String) -> String {
        item.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 重複判定用の署名（同じ店＋品目なら同じ文字列）。店か品目が空なら nil。
    /// 取込のように大量に突き合わせるとき、既存側の正規化（NFKC）を件数ぶん繰り返さないための口。
    public static func signature(store: String, item: String) -> String? {
        let storeKey = ChainName.key(store)
        let itemKey = normalizedItem(item)
        guard !storeKey.isEmpty, !itemKey.isEmpty else { return nil }
        return storeKey + "\u{0}" + itemKey
    }

    /// 完了していない既存タスクのうち、同じ店＋品目のもの。
    public static func existing(store: String, item: String, in tasks: [TodoTask]) -> TodoTask? {
        let storeKey = ChainName.key(store)
        let itemKey = normalizedItem(item)
        guard !storeKey.isEmpty, !itemKey.isEmpty else { return nil }
        return tasks.first { task in
            task.status != .done
                && ChainName.key(task.store) == storeKey
                && normalizedItem(task.item) == itemKey
        }
    }
}
