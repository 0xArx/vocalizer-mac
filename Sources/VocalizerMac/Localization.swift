// User-facing text goes through L(): the English text is the key, and Resources/Localization/<lang>.lproj/
// Localizable.strings holds the translations (Arabic today). Placeholders are %@ (pass Strings). SwiftUI lays
// the menu out right to left by itself when the Mac's language is Arabic.
import Foundation

func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}

import SwiftUI

/// Right to left when the app is showing a right-to-left language (Arabic), so the menu mirrors properly.
let appLayoutDirection: LayoutDirection = {
    let lang = Bundle.main.preferredLocalizations.first ?? "en"
    return Locale.Language(identifier: lang).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
}()
