import Foundation

@main
struct CheckLocalization {
    static func main() throws {
        precondition(AppLanguagePreference.system.resolve(preferredLanguages: ["zh-Hant-TW", "en"]) == .simplifiedChinese)
        precondition(AppLanguagePreference.system.resolve(preferredLanguages: ["en_GB", "zh-Hans"]) == .english)
        precondition(AppLanguagePreference.system.resolve(preferredLanguages: ["fr-FR", "zh-CN"]) == .simplifiedChinese)
        precondition(AppLanguagePreference.system.resolve(preferredLanguages: ["ja-JP"]) == .english)
        precondition(AppLanguagePreference.system.resolve(preferredLanguages: []) == .english)
        precondition(AppLanguagePreference.english.resolve(preferredLanguages: ["zh-CN"]) == .english)
        precondition(AppLanguagePreference.simplifiedChinese.resolve(preferredLanguages: ["en-US"]) == .simplifiedChinese)

        let suite = "io.github.little-king2022.SwitchPiAudio.localization-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for preference in AppLanguagePreference.allCases {
            defaults.set(preference.rawValue, forKey: AppLanguagePreference.storageKey)
            let fetched = UserDefaults(suiteName: suite)?.string(forKey: AppLanguagePreference.storageKey)
            precondition(fetched.flatMap(AppLanguagePreference.init(rawValue:)) == preference)
        }

        func strings(_ language: AppLanguage) throws -> [String: String] {
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(language.rawValue).lproj/Localizable.strings")
            let data = try Data(contentsOf: url)
            let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
            return parsed as! [String: String]
        }

        let english = try strings(.english), chinese = try strings(.simplifiedChinese)
        precondition(!english.isEmpty && Set(english.keys) == Set(chinese.keys))
        for key in english.keys {
            precondition(!english[key]!.isEmpty && !chinese[key]!.isEmpty)
        }
        precondition(AppLanguage.english.text("language.system") == "System")
        precondition(AppLanguage.simplifiedChinese.text("language.system") == "跟随系统")
        precondition(AppLanguage.english.text("monitor.sample", Int64(2), Int64(80)) == "Sample: 2 underruns, 80 ms dropped")
        precondition(AppLanguage.simplifiedChinese.text("monitor.sample", Int64(2), Int64(80)) == "该采样点：缓冲不足 2 次，丢弃 80 ms")
        let message = AppMessage("error.audio_operation", .label("audio.volume"), .integer(-50))
        precondition(message.text(in: .english) == "Set volume failed (-50).")
        precondition(message.text(in: .simplifiedChinese) == "设置音量失败（-50）")
        precondition(AppMessage(error: PlayerError(message)).text(in: .simplifiedChinese) == message.text(in: .simplifiedChinese))
        precondition(AppMessage(verbatim: "ssh: raw failure").text(in: .simplifiedChinese) == "ssh: raw failure")
        print("Verified language resolution, preference persistence, \(english.count) matching string keys, localized messages and verbatim diagnostics.")
    }
}
