import Foundation

/// The language of everything MacSignal shows. It follows the system: the first of the user's
/// preferred languages (System Settings › General › Language & Region, where MacSignal can also
/// get a language of its own) that MacSignal has, otherwise English.
enum Language: String {
    case english = "en"
    case chinese = "zh-Hans"

    static var current = preferred(Locale.preferredLanguages)

    static func preferred(_ languages: [String]) -> Language {
        Bundle.preferredLocalizations(from: [english.rawValue, chinese.rawValue], forPreferences: languages)
            .first.flatMap(Language.init) ?? .english
    }

    /// For dates and times in the menu.
    var locale: Locale { Locale(identifier: rawValue) }
}

/// The text in the current language. Both languages sit together at every place text is shown,
/// so neither can be missing.
func L(_ english: String, _ chinese: String) -> String {
    Language.current == .chinese ? chinese : english
}

/// 「45 min」, 「5 hr」, 「1 hr 20 min」.
func durationText(minutes m: Int) -> String {
    let hours = L("\(m / 60) hr", "\(m / 60) 小时"), minutes = L("\(m % 60) min", "\(m % 60) 分钟")
    return m < 60 ? minutes : m % 60 == 0 ? hours : hours + " " + minutes
}
