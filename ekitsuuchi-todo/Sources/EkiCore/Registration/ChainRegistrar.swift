import Foundation

/// 店登録の結果（画面の 1 行レポートと履歴用）。失敗は例外ではなくここに載せる: 1 駅の失敗で他の駅を巻き込まない。
public struct RegistrationReport: Equatable, Sendable {
    /// 台帳に登録されている表記（既にあれば最初の表記）。
    public var chainName: String
    /// 検索を試みた駅の数（失敗した駅も含む）。
    public var stationsSearched: Int
    /// 駅名 → 失敗の理由。失敗した駅の既存データには触れていない。
    public var stationFailures: [String: String]
    /// 反映後、台帳にあるこのチェーンの支店の数。
    public var branchesKept: Int
    /// 営業時間を取れなかった新しい支店名（hoursFetchedAt = nil のまま = 次回すぐ再取得の対象）。
    public var hoursFailures: [String]
    /// 台帳（保存）側の失敗。nil なら台帳への反映は成功。ブリーフの欄に足した追加欄。
    public var ledgerError: String?

    public init(
        chainName: String,
        stationsSearched: Int = 0,
        stationFailures: [String: String] = [:],
        branchesKept: Int = 0,
        hoursFailures: [String] = [],
        ledgerError: String? = nil
    ) {
        self.chainName = chainName
        self.stationsSearched = stationsSearched
        self.stationFailures = stationFailures
        self.branchesKept = branchesKept
        self.hoursFailures = hoursFailures
        self.ledgerError = ledgerError
    }
}

/// 店登録（§4「店登録時」）と、駅を足したときの部分再実行（§4 週1更新-3）。
///
/// 通信（検索・営業時間）は台帳の変更の外で行い、結果は 1 回の `mutate` でまとめて反映する。
/// `mutate` の中に await を置けない作りなので、通信中も他の変更（タスク追加・完了）は止まらず、
/// 反映時にだけ「いまの台帳」に対して差分をかける（通信前のコピーで上書きしない）。
public struct ChainRegistrar: Sendable {
    private let repository: LedgerRepository
    private let search: StoreSearching
    private let hours: BusinessHoursProviding
    private let now: @Sendable () -> Date

    public init(
        repository: LedgerRepository,
        search: StoreSearching,
        hours: BusinessHoursProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.search = search
        self.hours = hours
        self.now = now
    }

    // MARK: - 公開

    /// チェーンを 1 つ登録して、有効な全駅の近くの支店と営業時間を取る。店画面の「再取得」も同じ入口。
    /// 名前の登録を最初にやる: 通信が失敗しても、駅が 0 件でも、タスクの「店」に使える名前になる（D11）。
    public func register(chainName: String) async -> RegistrationReport {
        let trimmed = chainName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ChainName.key(trimmed).isEmpty else {
            return RegistrationReport(chainName: trimmed, ledgerError: LedgerError.emptyField("chain").errorDescription)
        }
        do {
            try await repository.registerChain(trimmed)
        } catch {
            return RegistrationReport(chainName: trimmed, ledgerError: Self.message(error))
        }
        let snapshot = await repository.snapshot()
        let registered = snapshot.registeredChains.first { ChainName.matches($0, trimmed) } ?? trimmed
        return await run(chain: registered, onlyStation: nil)
    }

    /// 駅を足した（または有効にした）とき、その駅ぶんだけ、登録済みの全チェーンで店登録をやり直す。
    /// 駅が無い・無効なら何もしない（監視されない駅のために API を叩かない）。
    /// 他の駅の `nearestStations` には触れない。チェーンごとに 1 回ずつ台帳へ反映する。
    public func registerStation(id: UUID) async -> [RegistrationReport] {
        let snapshot = await repository.snapshot()
        guard let station = snapshot.station(id: id), station.isEnabled else { return [] }
        var reports: [RegistrationReport] = []
        for chain in snapshot.registeredChains {
            if Task.isCancelled { break }
            reports.append(await run(chain: chain, onlyStation: id))
        }
        return reports
    }

    /// タスク追加・取込のあと（D11）。まだ登録されていないチェーンだけを登録する。
    /// 登録済みのものは再取得しない（それは `register` = 店画面の「再取得」の仕事）。
    public func ensureRegistered(chains: [String]) async -> [RegistrationReport] {
        var reports: [RegistrationReport] = []
        var seen = Set<String>()
        for raw in chains {
            if Task.isCancelled { break }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ChainName.key(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            // 毎回いまの台帳で確かめる: 前のチェーンの登録中に別経路が登録したかもしれない。
            let snapshot = await repository.snapshot()
            if snapshot.registeredChains.contains(where: { ChainName.key($0) == key }) { continue }
            reports.append(await register(chainName: name))
        }
        return reports
    }

    // MARK: - 本体

    /// 検索で得た 1 支店（複数駅から見えたものを 1 件にまとめた形）。
    private struct Merged {
        var placeID: String
        var name: String
        var coordinate: Coordinate
        /// 駅 id → 駅座標からの距離 m（こちらで計算した haversine。API の値は使わない）。
        var meters: [UUID: Double] = [:]
        /// 駅が現れた順（結果を決定的にするため）。
        var stationOrder: [UUID] = []
    }

    private struct FetchedHours {
        var hours: OpeningHours?
        var fetchedAt: Date?
    }

    private func run(chain: String, onlyStation: UUID?) async -> RegistrationReport {
        var report = RegistrationReport(chainName: chain)
        let snapshot = await repository.snapshot()
        let targets = snapshot.stations.filter { $0.isEnabled && (onlyStation == nil || $0.id == onlyStation) }

        // 1. 検索（駅ごとに順番に。失敗は駅単位で記録して続ける）
        var succeeded: [Station] = []
        var mergedByID: [String: Merged] = [:]
        var mergedOrder: [String] = []
        var cancelled = false
        for station in targets {
            if cancelled {
                report.stationFailures[Self.failureKey(station, in: report.stationFailures)] = Self.cancelledMessage
                continue
            }
            do {
                try Task.checkCancellation()
            } catch {
                cancelled = true
                report.stationFailures[Self.failureKey(station, in: report.stationFailures)] = Self.cancelledMessage
                continue
            }
            // 前の駅の通信中に消された・無効にされた駅には API を使わない。
            let current = await repository.snapshot().station(id: station.id)
            guard let current, current.isEnabled else { continue }
            report.stationsSearched += 1
            do {
                let candidates = try await search.searchBranches(
                    chainName: chain,
                    near: station.coordinate,
                    radiusMeters: Tuning.branchSearchRadiusMeters
                )
                succeeded.append(station)
                for c in candidates where !c.placeID.isEmpty {
                    let meters = station.coordinate.distance(to: c.coordinate)
                    // NaN/∞ の座標は JSON に載らず、1 件のせいで保存が丸ごと失敗する。捨てる。
                    guard meters.isFinite, c.coordinate.latitude.isFinite, c.coordinate.longitude.isFinite else { continue }
                    if var m = mergedByID[c.placeID] {
                        if let old = m.meters[station.id] {
                            m.meters[station.id] = min(old, meters)   // 同じ駅の検索結果に重複があっても 1 件
                        } else {
                            m.meters[station.id] = meters
                            m.stationOrder.append(station.id)
                        }
                        mergedByID[c.placeID] = m
                    } else {
                        mergedByID[c.placeID] = Merged(
                            placeID: c.placeID, name: c.name, coordinate: c.coordinate,
                            meters: [station.id: meters], stationOrder: [station.id]
                        )
                        mergedOrder.append(c.placeID)
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    cancelled = true
                    report.stationFailures[Self.failureKey(station, in: report.stationFailures)] = Self.cancelledMessage
                } else {
                    report.stationFailures[Self.failureKey(station, in: report.stationFailures)] = Self.message(error)
                }
            }
        }
        // キャンセルされたら台帳には何も反映しない（途中の半端な状態を作らない）。登録した名前だけが残る。
        if cancelled {
            report.branchesKept = Self.count(chain, in: snapshot)
            return report
        }

        // 2. 新しい支店だけ営業時間を取る（既存の支店の営業時間は週 1 更新の仕事）
        let knownIDs = Set(snapshot.branches.map(\.id))
        var fetched: [String: FetchedHours] = [:]
        var failedNames: [String] = []
        for id in mergedOrder where !knownIDs.contains(id) {
            guard let m = mergedByID[id] else { continue }
            if Task.isCancelled {
                cancelled = true
                break
            }
            do {
                let h = try await hours.openingHours(placeID: id)
                // nil は「Google に営業時間が無い」という答え。取得済みとして扱い、毎回は聞き直さない。
                fetched[id] = FetchedHours(hours: h, fetchedAt: now())
            } catch {
                if Task.isCancelled || error is CancellationError {
                    cancelled = true
                    break
                }
                // 失敗は hoursFetchedAt = nil のまま残す = 週 1 更新で真っ先に再取得される。
                fetched[id] = FetchedHours(hours: nil, fetchedAt: nil)
                failedNames.append(m.name)
            }
        }
        if cancelled {
            report.branchesKept = Self.count(chain, in: snapshot)
            return report
        }
        report.hoursFailures = failedNames

        // 3. 1 回の mutate で反映
        guard !succeeded.isEmpty else {
            report.branchesKept = Self.count(chain, in: snapshot)
            return report
        }
        let succeededIDs = Set(succeeded.map(\.id))
        do {
            report.branchesKept = try await repository.mutate { ledger in
                // 通信中に消された駅・登録解除されたチェーンには反映しない。
                guard ledger.registeredChains.contains(where: { ChainName.matches($0, chain) }) else {
                    return Self.count(chain, in: ledger)
                }
                let liveStations = Set(ledger.stations.map(\.id)).intersection(succeededIDs)
                Self.apply(
                    to: &ledger, chain: chain, liveStations: liveStations,
                    merged: mergedByID, order: mergedOrder, fetched: fetched
                )
                return Self.count(chain, in: ledger)
            }
        } catch {
            report.ledgerError = Self.message(error)
            report.branchesKept = Self.count(chain, in: snapshot)
        }
        return report
    }

    /// 検索結果を台帳へ反映する（純粋な関数。`mutate` の中で呼ぶ）。
    private static func apply(
        to ledger: inout Ledger,
        chain: String,
        liveStations: Set<UUID>,
        merged: [String: Merged],
        order: [String],
        fetched: [String: FetchedHours]
    ) {
        let existingIDs = Set(ledger.branches.map(\.id))
        var result: [Branch] = []
        for var branch in ledger.branches {
            guard ChainName.matches(branch.chainName, chain) else {
                result.append(branch)
                continue
            }
            let hadStations = !branch.nearestStations.isEmpty
            let candidate = merged[branch.id]
            if let candidate {
                let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { branch.name = candidate.name }
                branch.coordinate = candidate.coordinate
            }
            // 成功した駅の分だけ書き換える。返ってきたら更新、返らなければ外す。失敗した駅の分は触らない。
            branch.nearestStations = branch.nearestStations.compactMap { entry in
                guard liveStations.contains(entry.stationID) else { return entry }
                guard let meters = candidate?.meters[entry.stationID] else { return nil }
                return StationDistance(stationID: entry.stationID, meters: meters)
            }
            if let candidate {
                for sid in candidate.stationOrder
                where liveStations.contains(sid) && !branch.nearestStations.contains(where: { $0.stationID == sid }) {
                    branch.nearestStations.append(StationDistance(stationID: sid, meters: candidate.meters[sid] ?? 0))
                }
            }
            // どの駅からも見えなくなった支店は消す（最初から駅を持たないものには触らない）。
            if hadStations && branch.nearestStations.isEmpty { continue }
            result.append(branch)
        }
        // 新しい支店。ID が別のチェーンの支店として既にあるものは奪わない。
        for id in order where !existingIDs.contains(id) {
            guard let m = merged[id] else { continue }
            let stations = m.stationOrder
                .filter { liveStations.contains($0) }
                .map { StationDistance(stationID: $0, meters: m.meters[$0] ?? 0) }
            guard !stations.isEmpty else { continue }
            let h = fetched[id]
            result.append(Branch(
                id: id, chainName: chain, name: m.name, coordinate: m.coordinate,
                hours: h?.hours, hoursFetchedAt: h?.fetchedAt, nearestStations: stations
            ))
        }
        ledger.branches = result
    }

    private static func count(_ chain: String, in ledger: Ledger) -> Int {
        ledger.branches.filter { ChainName.matches($0.chainName, chain) }.count
    }

    private static let cancelledMessage = "キャンセルされました"

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// 駅名が同じ駅が 2 つあっても失敗を上書きしない。
    private static func failureKey(_ station: Station, in failures: [String: String]) -> String {
        failures[station.name] == nil ? station.name : "\(station.name) (\(station.id.uuidString.prefix(8)))"
    }
}
