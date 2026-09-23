import SwiftUI

/// Every text style used in this app, +2pt over the system default (default point sizes on
/// macOS: title2 17, headline/body 13, subheadline 11, caption/caption2 10).
enum AppFont {
    static let title2 = Font.system(size: 19)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 15)
    static let subheadline = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let caption2 = Font.system(size: 12)
    /// The main search box's own text — deliberately larger than everything else, so it reads
    /// as the app's primary control rather than a chat text field.
    static let searchBox = Font.system(size: 20)
}

/// "Classic" — a Netscape Navigator-era A/B alternative to the app's Modern look: beveled 3D
/// chrome, a gray toolbar, a punchier accent, on the same layout. Toggled in Settings
/// (`AppModel.isClassicTheme`), never forced — this is a look, not a replacement.
enum ClassicTheme {
    static let chrome = Color(red: 0.78, green: 0.78, blue: 0.75)          // classic Motif/Win95 gray
    static let chromeLight = Color(red: 0.94, green: 0.94, blue: 0.92)     // raised-edge highlight
    static let chromeDark = Color(red: 0.45, green: 0.45, blue: 0.43)      // sunken-edge shadow
    static let accent = Color(red: 0.42, green: 0.09, blue: 0.55)          // Navigator "N" purple
    static let link = Color(red: 0, green: 0, blue: 0.933)                 // classic <a> blue, #0000EE

    /// A sunken (inset) bevel — light edge bottom/right, dark edge top/left — the look of a
    /// classic single-line text field you're about to type into.
    struct SunkenBevel: ViewModifier {
        var cornerRadius: CGFloat = 2
        func body(content: Content) -> some View {
            content
                .background(Color.white, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(chromeDark, lineWidth: 1.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(chromeLight, lineWidth: 1)
                        .padding(1)
                )
        }
    }

    /// A raised (outset) bevel — the look of a classic pushable button.
    struct RaisedBevel: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(configuration.isPressed ? chrome.opacity(0.7) : chrome)
                .overlay(
                    Rectangle()
                        .strokeBorder(configuration.isPressed ? chromeDark : chromeLight, lineWidth: 1.5)
                        .padding(0.75)
                )
                .overlay(Rectangle().strokeBorder(chromeDark, lineWidth: 1))
        }
    }
}

extension View {
    func classicSunken(cornerRadius: CGFloat = 2) -> some View {
        modifier(ClassicTheme.SunkenBevel(cornerRadius: cornerRadius))
    }
}
