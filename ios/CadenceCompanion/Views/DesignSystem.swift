import SwiftUI

/// A quiet graphite canvas, readable mint accents, and generous touch targets.
/// Shared by the wearer screens and aligned with the public experience.
public enum CadenceTheme {
    public static let accent = Color(red: 0.72, green: 0.89, blue: 0.77)
    public static let calm = Color(red: 0.62, green: 0.82, blue: 0.69)
    public static let caution = Color(red: 0.95, green: 0.58, blue: 0.08)
    public static let danger = Color(red: 0.98, green: 0.38, blue: 0.40)
    public static let cardRadius: CGFloat = 24
    public static let controlRadius: CGFloat = 18
    /// Minimum touch target, per the Human Interface Guidelines.
    public static let minimumTapHeight: CGFloat = 44
    /// What this app uses for anything the wearer taps: a trembling finger
    /// needs a wide landing zone and dead space around it.
    public static let bigTapHeight: CGFloat = 72
    /// The one action a screen is for, and the help button.
    public static let giantTapHeight: CGFloat = 88
    /// Vertical gap between tappable things, so a miss lands on nothing.
    public static let tapGap: CGFloat = 20

    public static let background = Color(red: 0.035, green: 0.035, blue: 0.04)
    public static let card = Color(red: 0.075, green: 0.075, blue: 0.08)
    public static let subtleFill = Color.white.opacity(0.08)

    /// Bright semantic fills use dark ink to preserve readable contrast.
    static func ink(on tint: Color) -> Color {
        tint == accent || tint == calm || tint == caution || tint == danger ? background : .white
    }

}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CadenceTheme.cardRadius, style: .continuous)
                    .fill(CadenceTheme.card)
                    .overlay(RoundedRectangle(cornerRadius: CadenceTheme.cardRadius, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            )
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

/// Full-width filled button for the one thing a screen asks you to do.
public struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = CadenceTheme.accent

    public init(tint: Color = CadenceTheme.accent) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundColor(CadenceTheme.ink(on: tint))
            .background(
                RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.75 : 1.0))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet tinted button for secondary choices.
public struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = CadenceTheme.accent

    public init(tint: Color = CadenceTheme.accent) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundColor(tint)
            .background(
                RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.22 : 0.12))
            )
    }
}

/// A full-width button sized for a hard hour: 72–88 pt tall, debounced so a
/// double tap counts once, with a haptic on every accepted tap.
struct GuardedButton<Label: View>: View {
    enum Size { case big, giant }
    enum Style { case filled(Color), tinted(Color) }

    let size: Size
    let style: Style
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var guardRail = TapGuard()
    @State private var pressed = false

    init(
        size: Size = .big,
        style: Style = .filled(CadenceTheme.accent),
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.size = size
        self.style = style
        self.action = action
        self.label = label
    }

    private var height: CGFloat {
        size == .giant ? CadenceTheme.giantTapHeight : CadenceTheme.bigTapHeight
    }

    private var background: Color {
        switch style {
        case let .filled(c): return c
        case let .tinted(c): return c.opacity(0.14)
        }
    }

    private var foreground: Color {
        switch style {
        case let .filled(c): return CadenceTheme.ink(on: c)
        case let .tinted(c): return c
        }
    }

    var body: some View {
        Button {
            guardRail.perform {
                Haptics.tap()
                action()
            }
        } label: {
            label()
                .font(size == .giant ? .title2.weight(.bold) : .title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: height)
                .padding(.horizontal, 16)
                .foregroundColor(foreground)
                .background(
                    RoundedRectangle(cornerRadius: CadenceTheme.cardRadius, style: .continuous)
                        .fill(background.opacity(pressed ? 0.75 : 1.0))
                )
                .scaleEffect(pressed ? 0.98 : 1.0)
                .animation(.easeOut(duration: 0.12), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

/// Icon + word + colour, never colour alone.
struct StatusBadge: View {
    let systemImage: String
    let word: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.headline)
            Text(word)
                .font(.headline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundColor(color)
        .background(
            RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous)
                .fill(color.opacity(0.14))
        )
        .accessibilityElement(children: .combine)
    }
}

/// A big switch card: the whole row is the tap target, the state is spelled out.
struct SwitchCard: View {
    let title: String
    let detail: String
    let isOn: Bool
    let onColor: Color
    let action: () -> Void
    @State private var guardRail = TapGuard()

    var body: some View {
        Button {
            guardRail.perform {
                Haptics.tap()
                action()
            }
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                StatusBadge(
                    systemImage: isOn ? "checkmark.circle.fill" : "circle",
                    word: isOn ? "On" : "Off",
                    color: isOn ? onColor : .secondary
                )
            }
            .frame(minHeight: CadenceTheme.bigTapHeight)
            .card(padding: 18)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(isOn ? "on" : "off")")
        .accessibilityHint("Double tap to turn \(isOn ? "off" : "on")")
    }
}

/// Uppercase section label used above groups of cards.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .tracking(0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Small rounded status chip.
struct StatusPill: View {
    let text: String
    let color: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(filled ? CadenceTheme.ink(on: color) : color)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
    }
}

/// Circular icon badge used at the head of a card.
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundColor(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

/// A single number with a label, used in rows of three.
struct MetricTile: View {
    let value: String
    let label: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous)
                .fill(CadenceTheme.subtleFill)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A tappable action card with an icon, title and one-line description.
struct ActionRow: View {
    let systemName: String
    let color: Color
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(systemName: systemName, color: color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color.secondary.opacity(0.6))
            }
            .card(padding: 16)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Inline message for something that did not work, written for the wearer.
struct InlineNotice: View {
    let text: String
    var color: Color = CadenceTheme.caution
    var systemName: String = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemName)
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous)
                .fill(color.opacity(0.12))
        )
    }
}

/// Horizontal level meter for microphone input.
struct LevelMeter: View {
    /// 0...1
    let level: Double
    var color: Color = CadenceTheme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CadenceTheme.subtleFill)
                Capsule()
                    .fill(color)
                    .frame(width: max(6, geo.size.width * CGFloat(min(max(level, 0), 1))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Voice level")
        .accessibilityValue("\(Int((min(max(level, 0), 1)) * 100)) percent")
    }
}

/// Numbered step indicator for guided flows.
struct StepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(index <= current ? CadenceTheme.accent : CadenceTheme.subtleFill)
                    .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}
