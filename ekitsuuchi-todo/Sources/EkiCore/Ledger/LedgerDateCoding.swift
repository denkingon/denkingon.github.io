import Foundation

/// 台帳 JSON の日時表現: ISO-8601 UTC、小数秒 3 桁（"2026-10-05T09:42:00.123Z"）。
/// ミリ秒まで無損失。Foundation の ISO8601DateFormatter は小数秒を切り捨てることがあり（0.123 が 0.12299… として .122 になる）、
/// 書いて読むたびに値がずれるのを避けるため、整数のミリ秒に丸めてから自前で整形・解釈する。
/// フォーマッタを作らないのでスレッド安全で速い。
enum LedgerDateCoding {
    // 年 0001〜9999 に収める。Date.distantPast/Future でも Int64 が溢れない。
    private static let minSeconds: Int64 = -62_135_596_800
    private static let maxSeconds: Int64 = 253_402_300_799

    static func string(from date: Date) -> String {
        let raw = date.timeIntervalSince1970
        let seconds = raw.isFinite ? raw : 0
        let clamped = min(max(seconds, Double(minSeconds)), Double(maxSeconds))
        let totalMs = Int64((clamped * 1000).rounded())
        let secs = floorDiv(totalMs, 1000)
        let ms = totalMs - secs * 1000
        let days = floorDiv(secs, 86_400)
        let sod = secs - days * 86_400
        let (y, m, d) = civil(fromDays: days)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            Int(y), Int(m), Int(d), Int(sod / 3600), Int((sod % 3600) / 60), Int(sod % 60), Int(ms)
        )
    }

    /// "yyyy-MM-ddTHH:mm:ss[.fff…](Z|±HH:MM|±HHMM)". 小数はミリ秒未満を切り捨てる。
    static func date(from string: String) -> Date? {
        let b = Array(string.utf8)
        var i = 0
        func digits(_ n: Int) -> Int64? {
            guard i + n <= b.count else { return nil }
            var v: Int64 = 0
            for k in 0..<n {
                let c = b[i + k]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int64(c - 0x30)
            }
            i += n
            return v
        }
        func expect(_ c: UInt8) -> Bool {
            guard i < b.count, b[i] == c else { return false }
            i += 1
            return true
        }
        guard let y = digits(4), expect(0x2D), let mo = digits(2), expect(0x2D), let d = digits(2),
              expect(0x54) || expect(0x74) || expect(0x20),
              let h = digits(2), expect(0x3A), let mi = digits(2), expect(0x3A), let s = digits(2)
        else { return nil }
        guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 60 else { return nil }

        var ms: Int64 = 0
        if i < b.count, b[i] == 0x2E {
            i += 1
            var n = 0
            var any = false
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                if n < 3 { ms = ms * 10 + Int64(b[i] - 0x30); n += 1 }
                any = true
                i += 1
            }
            guard any else { return nil }
            while n < 3 { ms *= 10; n += 1 }
        }

        var offsetSeconds: Int64 = 0
        if i < b.count, b[i] == 0x5A || b[i] == 0x7A {
            i += 1
        } else if i < b.count, b[i] == 0x2B || b[i] == 0x2D {
            let sign: Int64 = b[i] == 0x2D ? -1 : 1
            i += 1
            guard let oh = digits(2) else { return nil }
            _ = expect(0x3A)
            guard let om = digits(2), oh < 24, om < 60 else { return nil }
            offsetSeconds = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == b.count else { return nil }

        let dayNumber = days(fromCivil: y, mo, d)
        // 2026-02-30 のような存在しない日付は、往復して一致しなければ拒否する。
        let back = civil(fromDays: dayNumber)
        guard back.0 == y, back.1 == mo, back.2 == d else { return nil }
        let secs = dayNumber * 86_400 + h * 3600 + mi * 60 + s - offsetSeconds
        let totalMs = secs * 1000 + ms
        return Date(timeIntervalSince1970: Double(totalMs) / 1000)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    // Howard Hinnant の days_from_civil / civil_from_days（1970-01-01 = 0）。
    private static func days(fromCivil y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return (y, m, d)
    }
}
