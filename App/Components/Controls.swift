import SwiftUI
import SeshCore

/**
 One button shape, five roles.

 The web app has exactly this set and no more, and the restraint is the point:
 when every button is the same shape, the only thing distinguishing the one you
 want is its weight on the page.
 */
enum ButtonRole2 {
    /// The accent fill. One per screen, at most.
    case primary
    /// Ink on ground — the heaviest thing available, for "Finish".
    case ink
    /// A quiet filled surface.
    case tonal
    /// Text only.
    case quiet
    /// Destructive, and never the lead.
    case warn
}

struct SeshButtonStyle: ButtonStyle {
    let role: ButtonRole2
    var size: CGFloat = 48
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.font(size >= 44 ? 15 : 13.5, .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: size)
            .padding(.horizontal, 16)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay {
                if role == .quiet {
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .stroke(theme.palette.line, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: return theme.accentInk
        case .ink: return theme.palette.background
        case .tonal, .quiet: return theme.palette.text
        case .warn: return theme.palette.warn
        }
    }

    private var background: Color {
        switch role {
        case .primary: return theme.accent
        case .ink: return theme.palette.text
        case .tonal: return theme.palette.fill2
        case .quiet, .warn: return .clear
        }
    }
}

extension View {
    func seshButton(_ role: ButtonRole2, size: CGFloat = 48) -> some View {
        buttonStyle(SeshButtonStyle(role: role, size: size))
    }
}

/**
 One cell of a segmented control.

 A named struct rather than a tuple: a bare `nil` in a tuple literal inside a
 `map` has no contextual type to take, and tuple labels have to line up exactly
 at every call site. A struct with a defaulted `detail` sidesteps both.
 */
struct SegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var detail: String?

    var id: Value { value }

    init(_ value: Value, _ label: String, _ detail: String? = nil) {
        self.value = value
        self.label = label
        self.detail = detail
    }
}

/// A sliding segmented control — tonal track, surface thumb.
struct SeshSegmented<Value: Hashable>: View {
    let options: [SegmentOption<Value>]
    @Binding var selection: Value
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                Button {
                    Haptics.light()
                    withAnimation(Motion.standard) { selection = option.value }
                } label: {
                    VStack(spacing: 1) {
                        Text(option.label).font(Typeface.font(13, .semibold))
                        if let detail = option.detail {
                            Text(detail).font(Typeface.font(11)).foregroundStyle(theme.palette.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == option.value ? theme.palette.text : theme.palette.textSecondary)
                .background {
                    if selection == option.value {
                        RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                            .fill(theme.palette.surface)
                            .shadow(color: .black.opacity(theme.isDark ? 0 : 0.06), radius: 3, y: 1)
                            // The thumb slides between cells rather than fading.
                            .matchedGeometryEffect(id: "segment", in: namespace)
                    }
                }
            }
        }
        .padding(3)
        .background(theme.palette.fill1, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    @Namespace private var namespace
}

/// The 44×26 pill. Widens its knob while pressed, like the web one.
struct SeshToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var isEnabled: Bool = true
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            guard isEnabled else { return }
            Haptics.light()
            withAnimation(Motion.spring) { isOn.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).rowTitleStyle().foregroundStyle(theme.palette.text)
                    if let detail {
                        Text(detail).metaStyle().foregroundStyle(theme.palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Capsule()
                    .fill(isOn ? theme.accent : theme.palette.fill3)
                    .frame(width: 44, height: 26)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 20, height: 20)
                            .padding(3)
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
    }
}

/// − value + , for the durations.
struct SeshStepper: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 5
    var unit: String = "min"
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(title).rowTitleStyle().foregroundStyle(theme.palette.text)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                stepButton("minus") { adjust(-step) }
                Text("\(value)\(unit.isEmpty ? "" : " \(unit)")")
                    .numeralStyle(14)
                    .frame(minWidth: 64)
                    .foregroundStyle(theme.palette.text)
                stepButton("plus") { adjust(step) }
            }
            .padding(3)
            .background(theme.palette.fill1, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
    }

    private func adjust(_ delta: Int) {
        let next = min(range.upperBound, max(range.lowerBound, value + delta))
        guard next != value else { return }
        Haptics.light()
        value = next
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.palette.text)
    }
}

/// A category chip. The chosen one fills with its own colour.
struct CategoryChip: View {
    let label: String
    let color: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Typeface.font(13, .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color(hex: Accent.readableInk(color)) : theme.palette.textSecondary)
                .background(
                    isSelected ? Color(hex: color) : theme.palette.fill1,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

/// A hairline that stops short of the edge, the way an iOS list separator does.
struct Hairline: View {
    var inset: CGFloat = 0
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.palette.line)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

struct Eyebrow: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .eyebrowStyle()
            .foregroundStyle(theme.palette.textSecondary)
    }
}

/// An underlined field, the hairline taking the accent on focus.
struct UnderlinedField: View {
    let placeholder: String
    @Binding var text: String
    var size: CGFloat = 22
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .font(Typeface.font(size, .medium))
                .foregroundStyle(theme.palette.text)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { focused = false; onCommit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { onCommit() }
                }
            Rectangle()
                .fill(focused ? theme.accent : theme.palette.line)
                .frame(height: focused ? 1.5 : 1)
                .animation(Motion.quick, value: focused)
        }
    }
}
