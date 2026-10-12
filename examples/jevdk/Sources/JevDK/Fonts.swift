import SwiftUI

/// JevDK's text sizes: macOS's standard sizes plus 2 pt, for readability at a desk.
/// (macOS doesn't scale its text styles from one setting, so every font in the app uses these.)
extension Font {
    static let jBody = Font.system(size: 15)
    static let jCallout = Font.system(size: 14)
    static let jCaption = Font.system(size: 12)
    static let jCaption2 = Font.system(size: 12)
    static let jHeadline = Font.system(size: 15, weight: .semibold)
    static let jTitle3 = Font.system(size: 17)
}
