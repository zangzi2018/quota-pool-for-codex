import SwiftUI
import UIKit

enum Theme {
    static let cardRadius: CGFloat = 20
    static let compactRadius: CGFloat = 16
    static let cobalt = Color.accentColor
    static let accentSoft = Color(light: 0xE7EBFF, dark: 0x20294D)
    static let track = Color(light: 0xDDE2EA, dark: 0x2A303B)
    static let canvas = Color(light: 0xF4F5F7, dark: 0x000000)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let surface2 = Color(light: 0xEEF0F4, dark: 0x2C2C2E)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
        })
    }
}

struct CardModifier: ViewModifier {
    var emphasized = false
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                if emphasized { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.cobalt, lineWidth: 1.5) }
            }
    }
}

extension View { func card(emphasized: Bool = false) -> some View { modifier(CardModifier(emphasized: emphasized)) } }
