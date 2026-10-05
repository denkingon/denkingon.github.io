import Foundation

// Places API (New) v1 の応答の写し。実際に使う項目だけを、すべて任意で宣言する
// （proto3 の JSON は 0 や空を省くことがある。無い項目で全体が読めなくなるより、使う側で扱うほうが安全）。
// 外には出さない: 外に出るのは BranchCandidate と OpeningHours だけ。

enum PlacesAPI {
    // MARK: places:searchText

    struct LatLng: Encodable, Equatable {
        var latitude: Double
        var longitude: Double
    }

    /// 応答側の位置。片方が欠けた 1 件で検索全体を読めなくしないよう、任意で受ける。
    struct PlaceLocation: Decodable {
        var latitude: Double?
        var longitude: Double?
    }

    struct SearchTextRequest: Encodable {
        struct Circle: Encodable { var center: LatLng; var radius: Double }
        struct LocationBias: Encodable { var circle: Circle }

        var textQuery: String
        var languageCode: String
        var regionCode: String
        var pageSize: Int
        var locationBias: LocationBias
    }

    struct LocalizedText: Decodable {
        var text: String?
        var languageCode: String?
    }

    struct Place: Decodable {
        var id: String?
        var displayName: LocalizedText?
        var location: PlaceLocation?
    }

    /// 該当なしは `{}`（places キーごと無い）。
    struct SearchTextResponse: Decodable {
        var places: [Place]?
    }

    // MARK: places/{id}

    struct DateParts: Decodable {
        var year: Int?
        var month: Int?
        var day: Int?
    }

    /// day は 0=日曜。proto3 は 0 を省くので、無いときは 0 として読む（`resolved*`）。
    struct Point: Decodable {
        var day: Int?
        var hour: Int?
        var minute: Int?
        /// currentOpeningHours の枠にだけ付く（その枠が実際に来る日付）。
        var date: DateParts?

        var resolvedDay: Int { day ?? 0 }
        var resolvedHour: Int { hour ?? 0 }
        var resolvedMinute: Int { minute ?? 0 }
    }

    struct Period: Decodable {
        var open: Point?
        var close: Point?
    }

    struct SpecialDayEntry: Decodable {
        var date: DateParts?
    }

    struct HoursBlock: Decodable {
        var periods: [Period]?
        var specialDays: [SpecialDayEntry]?
    }

    struct TimeZoneBlock: Decodable {
        var id: String?
    }

    struct PlaceHoursResponse: Decodable {
        var regularOpeningHours: HoursBlock?
        var currentOpeningHours: HoursBlock?
        var timeZone: TimeZoneBlock?
    }

    // MARK: error body

    struct ErrorBody: Decodable {
        struct Inner: Decodable {
            var code: Int?
            var message: String?
            var status: String?
        }
        var error: Inner?
    }
}
