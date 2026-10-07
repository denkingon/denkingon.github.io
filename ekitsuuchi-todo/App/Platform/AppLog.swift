import os

/// 1 か所に集めたロガー。Console.app / `log stream --predicate 'subsystem == "dev.denkingon.ekitsuuchi"'` で絞れる。
/// API キーの値はどのログにも出さない。
enum AppLog {
    private static let subsystem = "dev.denkingon.ekitsuuchi"

    static let location = Logger(subsystem: subsystem, category: "location")
    static let notify = Logger(subsystem: subsystem, category: "notify")
    static let places = Logger(subsystem: subsystem, category: "places")
    static let ledger = Logger(subsystem: subsystem, category: "ledger")
    static let refresh = Logger(subsystem: subsystem, category: "refresh")
}
