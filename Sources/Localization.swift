import Foundation

enum L10n {
    private static let curatedFileTypeKeys: [String: String] = [
        "pdf": "fileType.pdf",
        "txt": "fileType.txt",
        "md": "fileType.md",
        "jpg": "fileType.jpeg",
        "jpeg": "fileType.jpeg",
        "png": "fileType.png",
        "heic": "fileType.heic",
        "svg": "fileType.svg",
        "zip": "fileType.zip",
        "json": "fileType.json",
        "csv": "fileType.csv",
        "docx": "fileType.docx",
        "xlsx": "fileType.xlsx",
        "pptx": "fileType.pptx",
        "html": "fileType.html",
        "htm": "fileType.html",
        "mp3": "fileType.mp3",
        "mp4": "fileType.mp4"
    ]

    static func string(_ key: String) -> String {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        let language = AppLanguage(rawValue: saved ?? "") ?? .system
        return string(key, language: language)
    }

    static func string(_ key: String, language: AppLanguage) -> String {
        localizedBundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    static func fileTypeDisplayName(systemName: String,
                                    extensions: [String],
                                    identifier: String) -> String {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        let language = AppLanguage(rawValue: saved ?? "") ?? .system
        if let fileExtension = extensions.first?.lowercased(),
           let key = curatedFileTypeKeys[fileExtension] {
            return string(key, language: language)
        }
        guard language == .english, systemName.containsCJK else { return systemName }
        if let first = extensions.first, !first.isEmpty {
            return "\(first.uppercased()) File"
        }
        return identifier
    }

    private static var locale: Locale {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        return (AppLanguage(rawValue: saved ?? "") ?? .system).locale
    }

    private static func localizedBundle(for language: AppLanguage) -> Bundle {
        let localization: String?
        switch language {
        case .system:
            localization = Bundle.preferredLocalizations(from: Bundle.main.localizations).first
        case .simplifiedChinese:
            localization = "zh-Hans"
        case .english:
            localization = "en"
        }
        guard let localization,
              let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

private extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: Self { self }

    var displayNameKey: String {
        switch self {
        case .system: "跟随系统"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        }
    }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    static let changedNotification = Notification.Name("DefaultOpenLanguageChanged")
    static let showSettingsNotification = Notification.Name("DefaultOpenShowSettings")

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: storageKey)
            revision += 1
            NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        }
    }
    @Published private(set) var revision = 0

    private let storageKey = "appLanguage"

    private init() {
        let saved = UserDefaults.standard.string(forKey: storageKey)
        language = AppLanguage(rawValue: saved ?? "") ?? .system
    }

    func string(_ key: String) -> String {
        L10n.string(key, language: language)
    }
}
