import SwiftUI

/// Vaulthalla's design tokens, ported from the web console (`web/src/app/globals.css`). Dark only: the near-black
/// canvas with one cyan accent is the product's identity. Status colors live on `StatusTone`, because only the
/// backend decides which one applies.
enum Theme {
    /// Controls, small chips.
    static let radiusControl: CGFloat = 8
    /// Cards and tiles (`--radius-card`).
    static let radiusCard: CGFloat = 14
    /// Large panels (`--radius-panel`).
    static let radiusPanel: CGFloat = 20

    /// Detail pages use one gutter so panels line up across sections.
    static let pagePadding: CGFloat = 28
    static let stackSpacing: CGFloat = 16
    /// The longest a line of prose gets (about 90 characters): pages use the whole window, sentences don't.
    static let proseWidth: CGFloat = 720
}

extension Color {
    fileprivate init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    // Canvas
    static let canvas = Color(hex: 0x05080D)
    static let canvasRaised = Color(hex: 0x0A0F16)

    // Surfaces: translucent steps over the canvas.
    static let surface1 = Color.white.opacity(0.028)
    static let surface2 = Color.white.opacity(0.05)
    static let surface3 = Color.white.opacity(0.08)
    static let surfaceSolid = Color(hex: 0x0B1119)

    // Lines
    static let line = Color.white.opacity(0.08)
    static let lineStrong = Color.white.opacity(0.15)

    // Foreground
    static let fg = Color(hex: 0xE6EDF5)
    static let fgMuted = Color(hex: 0xE6EDF5, opacity: 0.72)
    static let fgSubtle = Color(hex: 0xE6EDF5, opacity: 0.52)
    static let fgFaint = Color(hex: 0xE6EDF5, opacity: 0.34)

    // The one brand cyan. Text uses `accentText` (higher contrast); fills use `accentFill` with `accentInk` on top.
    static let accentFill = Color(hex: 0x22D3EE)
    static let accentText = Color(hex: 0x67E8F9)
    static let accentInk = Color(hex: 0x031318)
    static let accentSoft = Color(hex: 0x22D3EE, opacity: 0.12)
    static let accentLine = Color(hex: 0x22D3EE, opacity: 0.36)
    static let accentGlow = Color(hex: 0x22D3EE, opacity: 0.35)
}

extension ShapeStyle where Self == Color {
    static var canvas: Color { .canvas }
    static var canvasRaised: Color { .canvasRaised }
    static var surface1: Color { .surface1 }
    static var surface2: Color { .surface2 }
    static var surface3: Color { .surface3 }
    static var surfaceSolid: Color { .surfaceSolid }
    static var line: Color { .line }
    static var lineStrong: Color { .lineStrong }
    static var fg: Color { .fg }
    static var fgMuted: Color { .fgMuted }
    static var fgSubtle: Color { .fgSubtle }
    static var fgFaint: Color { .fgFaint }
    static var accentFill: Color { .accentFill }
    static var accentText: Color { .accentText }
    static var accentInk: Color { .accentInk }
    static var accentSoft: Color { .accentSoft }
    static var accentLine: Color { .accentLine }
}

/// The detail canvas: near-black with the web's faint cyan bloom from the top left.
struct CanvasBackground: View {
    var body: some View {
        ZStack {
            Color.canvas
            RadialGradient(
                colors: [Color(.sRGB, red: 34 / 255, green: 211 / 255, blue: 238 / 255, opacity: 0.075), .clear],
                center: UnitPoint(x: 0.12, y: -0.12),
                startRadius: 0,
                endRadius: 760
            )
            RadialGradient(
                colors: [Color(.sRGB, red: 56 / 255, green: 189 / 255, blue: 248 / 255, opacity: 0.04), .clear],
                center: UnitPoint(x: 1, y: -0.08),
                startRadius: 0,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Places a page on the Vaulthalla canvas.
    func vaulthallaCanvas() -> some View {
        background { CanvasBackground() }
    }
}
