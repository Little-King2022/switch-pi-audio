import Foundation
import SwiftUI

enum AppLanguagePreference: String, CaseIterable {
    case system, english = "en", simplifiedChinese = "zh-Hans"

    static let storageKey = "appLanguage"

    func resolve(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        case .system:
            for identifier in preferredLanguages {
                switch identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
                case "en": return .english
                case "zh": return .simplifiedChinese
                default: continue
                }
            }
            return .english
        }
    }
}

enum AppLanguage: String {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    private static let resources = Dictionary(uniqueKeysWithValues:
        [AppLanguage.english, .simplifiedChinese].compactMap { language in
            Bundle.main.url(forResource: language.rawValue, withExtension: "lproj")
                .flatMap(Bundle.init(url:))
                .map { (language, $0) }
        }
    )

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    fileprivate func format(_ key: String, arguments: [CVarArg]) -> String {
        let translated = Self.resources[self]?.localizedString(forKey: key, value: nil, table: nil) ?? key
        let template = translated == key
            ? Self.resources[.english]?.localizedString(forKey: key, value: nil, table: nil) ?? key
            : translated
        return arguments.isEmpty ? template : String(format: template, locale: Locale(identifier: rawValue), arguments: arguments)
    }
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage.english
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

// Keep messages unrendered until display, so visible errors and progress
// descriptions switch languages without restarting streams or measurements.
struct AppMessage: Sendable {
    enum Argument: Sendable {
        case integer(Int64)
        case text(String)
        case label(String)
    }

    private let key: String
    private let arguments: [Argument]
    private let verbatim: Bool

    init(_ key: String, _ arguments: Argument...) {
        self.key = key
        self.arguments = arguments
        self.verbatim = false
    }

    init(verbatim text: String) {
        self.key = text
        self.arguments = []
        self.verbatim = true
    }

    init(error: Error) {
        self = (error as? PlayerError)?.message ?? AppMessage(verbatim: error.localizedDescription)
    }

    func text(in language: AppLanguage) -> String {
        if verbatim { return key }
        return language.format(key, arguments: arguments.map {
            switch $0 {
            case .integer(let value): return value
            case .text(let value): return value
            case .label(let value): return language.text(value)
            }
        })
    }
}

struct PlayerError: LocalizedError {
    let message: AppMessage
    var errorDescription: String? { message.text(in: .english) }
    init(_ message: AppMessage) { self.message = message }
}
