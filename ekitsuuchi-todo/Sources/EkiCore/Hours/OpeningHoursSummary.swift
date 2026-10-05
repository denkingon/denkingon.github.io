import Foundation

// 店画面の「今日の営業時間」。評価と同じ規則（開店日に属する枠・特別日は置き換え）で枠を数える。

public extension OpeningHours {
    /// 店のローカル日付で `now` の日に「開く」枠を `10:00–21:00` の形で。複数は `10:00–14:00、17:00–22:00`。
    /// 24:00 閉店は `…–24:00`、翌日に閉まる枠は `18:00–翌2:00`。24 時間営業は `24時間営業`、枠が無ければ `休み`。
    /// 前日から続く深夜営業の「今日の 0〜2 時」は今日の枠ではない（前日の枠の閉店として出る）。
    /// 接触・重なる枠は 1 本にまとめる（14:00 閉店と 14:00 開店は連続営業）。
    func todayText(at now: Date) -> String {
        if isAlwaysOpen { return "24時間営業" }
        let day = CalendarDay(date: now, timeZone: timeZone)
        let periods = openingPeriods(on: day, specialByDay: specialPeriodsByDay())
            .sorted { ($0.openMinute, $0.closeMinute) < ($1.openMinute, $1.closeMinute) }

        var merged: [(openMinute: Int, closeMinute: Int)] = []
        for p in periods {
            if let last = merged.last, p.openMinute <= last.closeMinute {
                merged[merged.count - 1].closeMinute = max(last.closeMinute, p.closeMinute)
            } else {
                merged.append(p)
            }
        }
        guard !merged.isEmpty else { return "休み" }
        return merged
            .map { "\(Self.openText($0.openMinute))–\(Self.closeText($0.closeMinute))" }
            .joined(separator: "、")
    }

    private static func openText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// 1440 以下は同日（ちょうど 1440 は 24:00）。超えたら 翌 / 翌々 / N日後 を付けて時刻は先頭ゼロ無し。
    private static func closeText(_ minutes: Int) -> String {
        if minutes <= 1440 { return openText(minutes) }
        var dayOffset = minutes / 1440
        var rem = minutes % 1440
        if rem == 0 {          // ちょうど 0 時 = その前日の 24 時
            dayOffset -= 1
            rem = 1440
        }
        let prefix = dayOffset == 1 ? "翌" : (dayOffset == 2 ? "翌々" : "\(dayOffset)日後")
        return prefix + String(format: "%d:%02d", rem / 60, rem % 60)
    }
}
