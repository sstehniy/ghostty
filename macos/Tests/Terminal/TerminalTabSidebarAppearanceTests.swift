import AppKit
import Testing
@testable import Ghostty

struct TerminalTabSidebarAppearanceTests {
    private struct Components {
        let r: Int
        let g: Int
        let b: Int
        let a: CGFloat
    }

    private func components(_ color: NSColor) throws -> Components {
        let rgb = try #require(color.usingColorSpace(.sRGB))
        return Components(
            r: Int((rgb.redComponent * 255).rounded()),
            g: Int((rgb.greenComponent * 255).rounded()),
            b: Int((rgb.blueComponent * 255).rounded()),
            a: rgb.alphaComponent)
    }

    private func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
    }

    @Test func darkBackgroundBlendsTowardBlack() throws {
        // Gruvbox Dark Hard #1d2021 -> #141616.
        let chrome = try components(TerminalTabSidebarAppearance.chromeColor(for: srgb(0x1d2021)))
        #expect(chrome.r == 0x14)
        #expect(chrome.g == 0x16)
        #expect(chrome.b == 0x16)
        #expect(chrome.a == 1)
    }

    @Test func lightBackgroundBlendsSlightlyTowardBlack() throws {
        // #f5f3ef -> #e6e4e1.
        let chrome = try components(TerminalTabSidebarAppearance.chromeColor(for: srgb(0xf5f3ef)))
        #expect(chrome.r == 0xe6)
        #expect(chrome.g == 0xe4)
        #expect(chrome.b == 0xe1)
    }

    @Test func nearBlackBackgroundBlendsTowardWhite() throws {
        let background = srgb(0x000000)
        let chrome = TerminalTabSidebarAppearance.chromeColor(for: background)
        let parts = try components(chrome)
        // 7% toward white.
        #expect(parts.r == 18)
        #expect(parts.g == 18)
        #expect(parts.b == 18)
        #expect(chrome.luminance > background.luminance)
    }

    @Test func keepsAlpha() throws {
        let chrome = try components(TerminalTabSidebarAppearance.chromeColor(for: srgb(0x1d2021, alpha: 0.8)))
        #expect(abs(chrome.a - 0.8) < 0.001)
        #expect(chrome.r == 0x14)

        let opaque = try components(TerminalTabSidebarAppearance.chromeColor(for: srgb(0x1d2021, alpha: 0.8), opaque: true))
        #expect(opaque.a == 1)
    }
}
