import SwiftUI
import AppKit

// MARK: - Remote Button Styles

struct RemoteButtonStyle: ButtonStyle {
    var bg: Color = Color(white: 0.20)
    var fg: Color = Color(white: 0.95)
    var height: CGFloat = 40
    var cornerRadius: CGFloat = 10
    var border: Color = Color(white: 0.28)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(fg)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(configuration.isPressed ? bg.opacity(0.65) : bg)
                    .shadow(color: Color.black.opacity(configuration.isPressed ? 0.1 : 0.35), radius: 2, x: 0, y: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(configuration.isPressed ? Color.white.opacity(0.3) : border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Power button: red when it will switch the TV off, green when it will switch it on.
struct PowerButtonStyle: ButtonStyle {
    var turnsOn: Bool = false

    private var tint: Color {
        turnsOn ? Color(red: 0.13, green: 0.55, blue: 0.27) : Color(red: 0.78, green: 0.12, blue: 0.12)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(configuration.isPressed ? tint.opacity(0.7) : tint)
                    .shadow(color: tint.opacity(0.35), radius: 4, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct ColorKeyStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(configuration.isPressed ? color.opacity(0.7) : color)
            .frame(height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: color.opacity(0.3), radius: 2, y: 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Icon over a short caption, so a button says what it is instead of relying on memory.
struct ControlLabel: View {
    let help: ControlHelp

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: help.symbol)
                .font(.system(size: 14, weight: .semibold))
            Text(help.label)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 2)
    }
}

/// Small card grouping related controls under a title.
struct RemoteSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Color(white: 0.48))
                .padding(.leading, 2)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.16))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(white: 0.24), lineWidth: 1)
        )
    }
}

// MARK: - Circular D-Pad Layout

struct DPadView: View {
    let onKey: (TVKey) -> Void

    var body: some View {
        ZStack {
            // Background disc
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.22), Color(white: 0.16)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 174, height: 174)
                .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 4)
                .overlay(Circle().stroke(Color(white: 0.28), lineWidth: 1.5))

            arrow(.up, rotation: 0, size: CGSize(width: 60, height: 42), offset: CGSize(width: 0, height: -54))
            arrow(.down, rotation: 180, size: CGSize(width: 60, height: 42), offset: CGSize(width: 0, height: 54))
            arrow(.left, rotation: -90, size: CGSize(width: 42, height: 60), offset: CGSize(width: -54, height: 0))
            arrow(.right, rotation: 90, size: CGSize(width: 42, height: 60), offset: CGSize(width: 54, height: 0))

            // Center OK button
            Button(action: { onKey(.ok) }) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.12, green: 0.38, blue: 0.65), Color(red: 0.08, green: 0.28, blue: 0.52)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.black.opacity(0.3), radius: 3, x: 0, y: 2)
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))

                    Text("OK")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle())
            .controlHelp(Help.ok)
        }
        .frame(width: 180, height: 180)
    }

    private func arrow(_ key: TVKey, rotation: Double, size: CGSize, offset: CGSize) -> some View {
        Button(action: { onKey(key) }) {
            Image(systemName: "triangle.fill")
                .rotationEffect(.degrees(rotation))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color(white: 0.9))
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .controlHelp(Help.arrows)
        .offset(offset)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeInOut(duration: 0.07), value: configuration.isPressed)
    }
}

// MARK: - Rocker Switch Component (Volume / Channel)

struct RockerSwitchView: View {
    let title: String
    let upSymbol: String
    let downSymbol: String
    let upKey: TVKey
    let downKey: TVKey
    let upHelp: ControlHelp
    let downHelp: ControlHelp
    let onKey: (TVKey) -> Void

    var body: some View {
        VStack(spacing: 0) {
            half(symbol: upSymbol, key: upKey, help: upHelp)

            Divider()
                .background(Color(white: 0.3))

            half(symbol: downSymbol, key: downKey, help: downHelp)
        }
        .frame(width: 66)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(white: 0.32), lineWidth: 1)
        )
        .overlay(
            // The name sits on the seam, so it reads as one control with two ends.
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundColor(Color(white: 0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(white: 0.17)))
                .overlay(Capsule().stroke(Color(white: 0.32), lineWidth: 1))
                .allowsHitTesting(false)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 3, y: 2)
    }

    private func half(symbol: String, key: TVKey, help: ControlHelp) -> some View {
        Button(action: { onKey(key) }) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color(white: 0.22))
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .controlHelp(help)
    }
}
