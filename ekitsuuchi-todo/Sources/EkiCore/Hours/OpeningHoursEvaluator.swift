import Foundation

// 営業時間の評価（§4 「営業中？（閉店まで30分以上）」の門）。
// 罠: 深夜営業は「開店した日」に属する区間として扱う。特別日は「その日に開く枠」だけを置き換え、
// 前日から続く枠（土曜 22:00→日曜 02:00 の日曜 01:00）は切らない。

public extension OpeningHours {
    /// 評価に使う窓（今日の何日前〜何日後までの「開店日」を展開するか）。
    /// 前: 週枠の最長またぎ（6 日）＋特別日の翌々日閉店を覆う。後: 特別日は 2 週先まで見て nextOpenAt に使う。
    private static let lookBackDays = 7
    private static let lookAheadDays = 14

    /// `now` の時点の営業状況。判定はこの店のタイムゾーン（`timeZone`）で行う。
    /// 開店は含む・閉店は含まない（[開店, 閉店)）。
    func status(at now: Date) -> HoursStatus {
        if isAlwaysOpen { return .open(closesAt: nil) }
        let runs = openRuns(around: now)
        if let current = runs.first(where: { $0.start <= now && now < $0.end }) {
            return .open(closesAt: current.end)
        }
        // runs は開始順にマージ済み。now 以前に始まって終わった区間は除かれる。
        return .closed(nextOpenAt: runs.first(where: { $0.start > now })?.start)
    }

    /// 営業中の門（§4）: 営業中で、閉店まで `minimumRemainingMinutes` 分以上ある（ちょうどは足りる扱い）。
    /// 24 時間営業は常に true。負の値は 0 とみなす。
    func isOpen(at now: Date, minimumRemainingMinutes: Int) -> Bool {
        switch status(at: now) {
        case .closed:
            return false
        case .open(let closesAt):
            guard let closesAt else { return true }
            return closesAt.timeIntervalSince(now) >= Double(max(0, minimumRemainingMinutes)) * 60
        }
    }
}

// MARK: - 区間の展開

private struct OpenRun {
    var start: Date
    var end: Date   // 排他
}

private extension OpeningHours {
    /// 窓内の開店日ごとの区間を絶対時刻にして、重なり・接触をマージして開始順に返す。
    /// 24:00 閉店 + 0:00 開店は 1 本の連続営業になる（closesAt はマージ後の終端）。
    func openRuns(around now: Date) -> [OpenRun] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone   // 日付→時刻は暦の成分から作る（86400 秒の足し算は DST でずれる）

        let today = CalendarDay(date: now, timeZone: timeZone)

        // 同じ日付の特別日が複数あっても取りこぼさないよう枠を併合する。
        var specialByDay: [CalendarDay: [DayPeriod]] = [:]
        for special in specialDays {
            specialByDay[special.date, default: []].append(contentsOf: special.periods)
        }

        var raw: [OpenRun] = []
        for offset in -Self.lookBackDays...Self.lookAheadDays {
            let day = today.addingDays(offset)
            if let periods = specialByDay[day] {
                // 特別日: その日に開く枠だけを使う（空なら終日休み。週枠のその日開店分は無視）。
                for p in periods {
                    guard p.openMinute >= 0, p.openMinute < 1440,
                          p.closeMinute > p.openMinute, p.closeMinute <= 2880 else { continue }
                    append(&raw, calendar: calendar, day: day, openMinute: p.openMinute, closeMinute: p.closeMinute)
                }
            } else {
                let weekday = day.weekdayIndex
                for p in weekly where p.openDay == weekday {
                    guard let length = Self.closeOffsetMinutes(p) else { continue }
                    append(&raw, calendar: calendar, day: day, openMinute: p.openMinute, closeMinute: p.openMinute + length)
                }
            }
        }
        return Self.merged(raw)
    }

    /// 開店から閉店までの長さ（分）。不正な枠（同日で閉店 <= 開店など）は nil で捨てる（落とさない）。
    static func closeOffsetMinutes(_ p: WeeklyPeriod) -> Int? {
        guard (0...6).contains(p.openDay), (0...6).contains(p.closeDay),
              p.openMinute >= 0, p.openMinute < 1440,
              p.closeMinute >= 0, p.closeMinute <= 1440 else { return nil }
        let days = (p.closeDay - p.openDay + 7) % 7
        if days == 0 && p.closeMinute <= p.openMinute { return nil }
        // closeMinute == 0 && days == 1 は 24:00 閉店（= 翌日 0 分）。式がそのまま通る。
        return days * 1440 + p.closeMinute - p.openMinute
    }

    func append(_ out: inout [OpenRun], calendar: Calendar, day: CalendarDay, openMinute: Int, closeMinute: Int) {
        guard let start = instant(calendar, day: day, minutes: openMinute),
              let end = instant(calendar, day: day, minutes: closeMinute),
              start < end else { return }
        out.append(OpenRun(start: start, end: end))
    }

    /// `day` の 0 時から `minutes` 分後の壁時計の時刻（1440 以上は翌日以降）。
    func instant(_ calendar: Calendar, day: CalendarDay, minutes: Int) -> Date? {
        let d = day.addingDays(minutes / 1440)
        let rem = minutes % 1440
        return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: rem / 60, minute: rem % 60))
    }

    static func merged(_ runs: [OpenRun]) -> [OpenRun] {
        var out: [OpenRun] = []
        for run in runs.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if var last = out.last, run.start <= last.end {   // 接触（start == end）も 1 本にする
                last.end = max(last.end, run.end)
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }
}
