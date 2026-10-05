import XCTest
@testable import EkiCore

/// 領域監視の計画（D13・20 個の上限）。
final class MonitoringPlannerTests: XCTestCase {
    typealias F = JudgeFixtures
    private let now = F.at(2026, 10, 5, 15)

    private func plan(_ l: Ledger, device: Coordinate? = nil) -> MonitoringPlan {
        MonitoringPlanner.plan(ledger: l, now: now, deviceLocation: device)
    }

    /// 経度が 0.01° ずつ違う駅を n 個（i 番目は東へ i*0.01°）。
    private func line(_ n: Int) -> [Station] {
        (0..<n).map { Station(name: "駅\($0)", coordinate: Coordinate(latitude: 35.0, longitude: 139.0 + Double($0) * 0.01)) }
    }

    private func ledger(tasks: [TodoTask] = [F.task("ダイソー", "a")], stations: [Station], settings: Settings = Settings()) -> Ledger {
        Ledger(tasks: tasks, stations: stations, settings: settings)
    }

    // MARK: 監視の ON/OFF

    func test未完了が0件なら止める() {
        XCTAssertEqual(plan(ledger(tasks: [], stations: [F.fujisawa])), .stopped)
        XCTAssertEqual(plan(ledger(tasks: [F.task("ダイソー", "a", status: .done)], stations: [F.fujisawa])), .stopped)
    }

    func test期限なしの無視だけなら止める() {
        XCTAssertEqual(plan(ledger(tasks: [F.task("ダイソー", "a", status: .ignored)], stations: [F.fujisawa])), .stopped)
    }

    func test今日は無視で明日戻るタスクがあれば監視を続ける_D13() {
        let t = F.task("ダイソー", "a", status: .ignored, ignoredUntil: F.at(2026, 10, 6))
        XCTAssertEqual(plan(ledger(tasks: [t], stations: [F.fujisawa])).stations, [F.fujisawa])
    }

    func test期限が過ぎた無視も続ける_次の入域で未完了として拾う() {
        let t = F.task("ダイソー", "a", status: .ignored, ignoredUntil: F.at(2026, 10, 5, 0))
        XCTAssertTrue(plan(ledger(tasks: [t], stations: [F.fujisawa])).isMonitoring)
    }

    func test実測モードはタスクが無くても監視する_D8() {
        let l = ledger(tasks: [], stations: [F.fujisawa, F.tsujido], settings: Settings(diagnosticMode: true))
        XCTAssertEqual(plan(l).stations, [F.fujisawa, F.tsujido])
    }

    func test未完了が1件でもあれば再開する() {
        XCTAssertTrue(plan(ledger(stations: [F.fujisawa])).isMonitoring)
    }

    func test無効な駅は入れない() {
        var off = F.tsujido
        off.isEnabled = false
        XCTAssertEqual(plan(ledger(stations: [F.fujisawa, off])).stations, [F.fujisawa])
        XCTAssertEqual(plan(ledger(stations: [off])).stations, [])
        XCTAssertFalse(plan(ledger(stations: [off])).isMonitoring)
    }

    func test無効な駅は上限の数にも数えない() {
        var stations = line(21)
        stations[20].isEnabled = false
        let p = plan(ledger(stations: stations))
        XCTAssertEqual(p.stations.count, 20)
        XCTAssertFalse(p.tracksSignificantLocationChanges, "有効な駅は 20 ちょうど")
    }

    // MARK: 上限（20）

    func test20駅以内は全部_位置変化は追わない() {
        let stations = line(20)
        let p = plan(ledger(stations: stations), device: Coordinate(latitude: 35, longitude: 139))
        XCTAssertEqual(p.stations, stations)
        XCTAssertFalse(p.tracksSignificantLocationChanges)
    }

    func test21駅なら端末に近い20駅_位置変化も追う() {
        let stations = line(21)
        // 端末は西の端（駅0 のそば）。一番遠い駅20 が落ちる。
        let west = plan(ledger(stations: stations), device: Coordinate(latitude: 35, longitude: 139))
        XCTAssertEqual(west.stations.map(\.name), (0..<20).map { "駅\($0)" })
        XCTAssertTrue(west.tracksSignificantLocationChanges)
        // 端末が東の端へ動くと入れ替わる（駅0 が落ち、駅20 が入る）。
        let east = plan(ledger(stations: stations), device: Coordinate(latitude: 35, longitude: 139.20))
        XCTAssertEqual(east.stations.map(\.name), (1...20).map { "駅\($0)" })
        XCTAssertTrue(east.tracksSignificantLocationChanges)
    }

    func test少し動いても同じ集合なら同じ計画_台帳の並びで返す() {
        let stations = line(25)
        let a = plan(ledger(stations: stations), device: Coordinate(latitude: 35, longitude: 139.150))
        let b = plan(ledger(stations: stations), device: Coordinate(latitude: 35, longitude: 139.151))
        XCTAssertEqual(a, b, "App 側は計画が等しければ再登録しない")
        XCTAssertEqual(a.stations.map(\.name), a.stations.map(\.name).sorted { Int($0.dropFirst())! < Int($1.dropFirst())! })
    }

    func test位置不明なら台帳の先頭20駅() {
        let stations = line(22)
        let p = plan(ledger(stations: stations), device: nil)
        XCTAssertEqual(p.stations, Array(stations.prefix(20)))
        XCTAssertTrue(p.tracksSignificantLocationChanges)
    }

    func test同じ距離なら台帳の先に載っている方が残る() {
        // 端末の東西に等距離の駅を 2 つ（西=先, 東=後）＋その他 19 駅を遠くに置き、20 枠のうち境界で競り合わせる。
        let device = Coordinate(latitude: 35, longitude: 139)
        var stations = (0..<19).map { Station(name: "近\($0)", coordinate: Coordinate(latitude: 35, longitude: 139 + 0.001 * Double($0 + 1))) }
        // 同じ緯度で経度の差の符号だけ違うと haversine の値は厳密に同じになるとは限らないので、同一座標にする。
        let tie = Coordinate(latitude: 35.1, longitude: 139)
        stations.append(Station(name: "同率先", coordinate: tie))
        stations.append(Station(name: "同率後", coordinate: tie))
        let names = plan(ledger(stations: stations), device: device).stations.map(\.name)
        XCTAssertTrue(names.contains("同率先"))
        XCTAssertFalse(names.contains("同率後"))
    }

    func test座標が壊れた駅は最後に回る() {
        var stations = line(20)
        stations.append(Station(name: "壊", coordinate: Coordinate(latitude: .nan, longitude: .nan)))
        let p = plan(ledger(stations: stations), device: Coordinate(latitude: 35, longitude: 139))
        XCTAssertFalse(p.stations.contains { $0.name == "壊" })
    }
}
