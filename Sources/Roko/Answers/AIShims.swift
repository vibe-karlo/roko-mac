import Foundation

// What the answer engine (Answers/AI, from roko on iPhone) asks of the app
// around it, on the Mac: no launch clock, no hitch watch, no trace unless
// asked for, and words counted for the summary's "6 min read → 40 s".

enum AITrace {
    static func log(_ line: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["ROKO_AI_TRACE"] != nil { NSLog("roko ai: %@", line()) }
    }
}

enum HitchWatch {
    static func note(_ what: String) {}
}

enum LaunchClock {
    static let isEnabled = false
}

enum SavedStats {
    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
    static func summary(pageWords: Int, summaryWords: Int) {}
    static func answer(pagesRead: Int, answerWords: Int) {}
}

/// Who roko is talking to, read from the Mac's own region and languages (as on the iPhone).
nonisolated enum Audience {
    /// The phone's languages, its first first, as codes: ["en", "hr"].
    static var languages: [String] {
        Locale.preferredLanguages
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    static var isCroatian: Bool {
        Locale.current.region?.identifier == "HR" || languages.contains("hr")
    }

    /// What dictation listens for: the phone's first two languages, with
    /// English alongside a single other one (web addresses and product names
    /// are often said in English).
    static var voiceLanguages: [String] {
        var codes = Array(spoken.prefix(2))
        if codes.isEmpty { codes = ["en"] }
        if codes.count == 1, codes[0] != "en" { codes.append("en") }
        return codes
    }

    /// The phone's languages, and the language of where it is when that isn't
    /// among them: an English phone in Croatia also gets Croatian.
    static var spoken: [String] {
        guard let local = regionLanguage, !languages.contains(local) else { return languages }
        return languages.prefix(1) + [local] + languages.dropFirst()
    }

    /// The main language of the phone's region: "hr" in Croatia, "en" in the US.
    static var regionLanguage: String? {
        guard let region = Locale.current.region?.identifier else { return nil }
        return Locale.Language(identifier: "und-\(region)").maximalIdentifier.split(separator: "-").first.map(String.init)
    }

    /// A language's name in the phone's language: "English", "German".
    static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: .current) ?? code
    }

    /// DuckDuckGo's region setting, "us-en", "hr-hr": results for where the
    /// phone is, in that place's language. "wt-wt" is no region at all.
    static var duckDuckGoRegion: String {
        guard let region = Locale.current.region?.identifier else { return "wt-wt" }
        return "\(region == "GB" ? "uk" : region.lowercased())-\(regionLanguage ?? "en")"
    }
}

nonisolated extension URL {
    /// Host without the "www." that tells the reader nothing.
    var displayHost: String {
        guard let host = host() else { return absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
