import Foundation

/// 複数スレッドから触る小さな値の入れ物（delegate はメイン、コールバックの設定は別スレッド、など）。
/// Sendable 性は NSLock で保証する。ロックを持ったままコールバックは呼ばないこと。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
