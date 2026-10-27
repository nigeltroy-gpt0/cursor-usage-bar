import SwiftUI

/// Design tokens. Font sizes and spacing are multiples of 4, except the header and amount section
/// and the panel padding, which match production v1.4.0 (see below).
enum Theme {
    enum FontSize {
        /// Body text, captions, and every control (buttons, pickers, checkboxes).
        static let body: CGFloat = 12
        /// Key stats (history window).
        static let heading: CGFloat = 16

    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    /// Dropdown panel size and padding, matching production v1.4.0.
    static let panelWidth: CGFloat = 300
    static let panelPadding: CGFloat = 14
    /// Height of every label/value row, so rows with a button keep the same rhythm as plain rows.
    static let rowHeight: CGFloat = 24
}

extension Font {
    static let appBody = Font.system(size: Theme.FontSize.body)
    static let appBodyEmphasis = Font.system(size: Theme.FontSize.body, weight: .semibold)
    static let appHeading = Font.system(size: Theme.FontSize.heading, weight: .semibold)

    // The header and amount section deliberately keeps production v1.4.0's system styles
    // (the user's preference), instead of the 4-pt scale.
    /// Page titles ("Cursor Usage Bar", "Settings"): 13pt bold.
    static let appTitle = Font.headline
    /// The version next to the title: 10pt.
    static let appVersion = Font.caption
    /// The main spend amount: 17pt rounded semibold.
    static let appHero = Font.system(.title2, design: .rounded).weight(.semibold)
    /// "of $1,500.00", the percentage, and the header icons: 13pt.
    static let appHeroDetail = Font.body
}
