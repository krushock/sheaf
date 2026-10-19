import AppKit
import SheafKit
import SwiftUI

// The look of the controls that float over the pages: a strip of tools at the side, a panel
// of options beside it, and the zoom. Taken from Inkpage (SNotes), where they read more
// clearly than rows of tools under the toolbar.

/// A label that appears beside a control once the pointer has rested on it, saying what it
/// is. The system's tooltip is set as well; this one is drawn in the window, so it shows at
/// once and is not lost behind the glass.
private struct HoverLabel: ViewModifier {
    let text: String
    let above: Bool
    @State private var visible = false
    @State private var waiting: Task<Void, Never>?
    @Environment(\.toolsOnLeft) private var onLeft

    private var label: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                waiting?.cancel()
                if inside {
                    waiting = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { visible = true } }
                    }
                } else {
                    visible = false
                }
            }
            // Beside the control, on the side away from the window's edge, or above it.
            .overlay(alignment: above ? .top : onLeft ? .trailing : .leading) {
                if visible {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .overlay(alignment: above ? .bottom : onLeft ? .leading : .trailing) {
                            label.offset(x: above ? 0 : onLeft ? 10 : -10, y: above ? -8 : 0)
                        }
                }
            }
            .help(text)
    }
}

private struct ToolsOnLeftKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The strip of tools stands at the left edge of the pages, not the right.
    var toolsOnLeft: Bool {
        get { self[ToolsOnLeftKey.self] }
        set { self[ToolsOnLeftKey.self] = newValue }
    }
}

/// A control of a floating bar lights up under the pointer, so that it is seen to be a
/// button and which one a press would reach.
private struct HoverHighlight: ViewModifier {
    let radius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.1 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// Laid behind a bar that floats over the pages. The page view reaches under the bar, and
/// without this it would go on choosing the pointer's shape there (the text's I-beam over a
/// button) and take the presses that fall between the buttons.
struct BarShield: NSViewRepresentable {
    final class Shield: NSView {
        private var tracking: NSTrackingArea?

        override func mouseDown(with event: NSEvent) {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        private func show(_ event: NSEvent) {
            let content = window?.contentView
            let over = (content?.superview ?? content)?.hitTest(event.locationInWindow)
            if over is NSTextField || over is NSTextView { return }
            NSCursor.arrow.set()
        }

        override func mouseMoved(with event: NSEvent) { show(event) }
        override func mouseEntered(with event: NSEvent) { show(event) }
        override func cursorUpdate(with event: NSEvent) { show(event) }
    }

    func makeNSView(context: Context) -> Shield { Shield() }
    func updateNSView(_ view: Shield, context: Context) {}
}

extension View {
    /// Names a control: a tooltip, a label drawn beside it (or above it), and the accessibility label.
    func named(_ text: String, above: Bool = false) -> some View {
        modifier(HoverLabel(text: text, above: above)).accessibilityLabel(text)
    }

    /// For a button or menu of a floating bar: it lights up under the pointer.
    func hoverHighlight(radius: CGFloat = 9) -> some View { modifier(HoverHighlight(radius: radius)) }

    /// For a bar of controls floating over the pages: the pointer is an arrow over it, and a
    /// press between its controls stays with it.
    func floatingBar() -> some View { background { BarShield() } }

    /// The glass of a floating bar or panel.
    func floatingGlass(cornerRadius: CGFloat = 22) -> some View {
        floatingBar().glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// The glass of a panel of settings that lies over the page: tinted with the window's
    /// own colour, so that what is on the page does not show through its words.
    func floatingPanelGlass(cornerRadius: CGFloat = 22) -> some View {
        floatingBar().glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.88)), in: .rect(cornerRadius: cornerRadius))
    }
}

/// An action in a panel of settings, as a row of its own: its symbol and its name, the
/// whole width taking the click, lit under the pointer, as the actions in Inkpage's panels
/// are. A destructive one is red; one at work shows a spinner at its end.
struct ActionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var role: ButtonRole?
    var isWorking = false
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, role: ButtonRole? = nil, isWorking: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isWorking = isWorking
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(title)
                Spacer(minLength: 0)
                if isWorking { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 6)
    }
}

/// A heading inside a floating panel.
struct PanelHeading: View {
    let title: LocalizedStringKey
    var systemImage: String?

    init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
    }
}

/// A slider as Inkpage draws sizes: minus, a track of growing dots with the number in the
/// knob, plus.
struct LevelSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 1...20
    var step: Double = 1
    let label: String
    /// How the number in the knob is written.
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    private func set(_ new: Double) {
        value = min(max((new / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    private func nudge(_ symbol: String, _ by: Double, _ name: String) -> some View {
        Button { set(value + by) } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 22, height: 26).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(name)
        .accessibilityLabel(name)
    }

    var body: some View {
        HStack(spacing: 6) {
            nudge("minus", -step, String(localized: "Less"))
            GeometryReader { geometry in
                let side = 28.0, run = max(geometry.size.width - side, 1)
                let share = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001)
                ZStack(alignment: .leading) {
                    ZStack {
                        Capsule().fill(.quaternary.opacity(0.7))
                        HStack(spacing: 0) {
                            ForEach(0..<9, id: \.self) { index in
                                Circle().fill(.secondary.opacity(0.55))
                                    .frame(width: 1.5 + Double(index) * 0.6, height: 1.5 + Double(index) * 0.6)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(height: 20)
                    .clipShape(.capsule)
                    Circle().fill(.white).shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                        .overlay { Text(format(value)).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(.black) }
                        .frame(width: side, height: side)
                        .offset(x: share * run)
                }
                .frame(height: side)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    set(range.lowerBound + (drag.location.x - side / 2) / run * (range.upperBound - range.lowerBound))
                })
            }
            .frame(height: 28)
            nudge("plus", step, String(localized: "More"))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in set(value + (direction == .increment ? step : -step)) }
    }
}

/// Colours to choose one from, as round swatches in rows, with any colour at the end.
struct ColorSwatches: View {
    let colors: [PDFColor]
    let chosen: PDFColor?
    /// For a colour that can be taken away, such as a fill: the first place is "none".
    var none: (() -> Void)?
    let pick: (PDFColor) -> Void

    static let side = 22.0

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.side), spacing: 8), count: 8), alignment: .leading, spacing: 8) {
            if let none {
                Button(action: none) {
                    Circle().fill(.white).frame(width: Self.side, height: Self.side)
                        .overlay { Circle().strokeBorder(.primary.opacity(0.18)) }
                        .overlay { Image(systemName: "line.diagonal").font(.system(size: 11)).foregroundStyle(.red) }
                        .overlay { if chosen == nil { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                }
                .buttonStyle(.plain)
                .help("None")
                .accessibilityLabel("None")
            }
            ForEach(colors, id: \.self) { color in
                Button { pick(color) } label: {
                    Circle().fill(color.color).frame(width: Self.side, height: Self.side)
                        .overlay { Circle().strokeBorder(.primary.opacity(0.12)) }
                        .overlay {
                            if chosen == color {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(color.isLight ? Color.black.opacity(0.7) : .white)
                            }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(color.name)
                .accessibilityLabel(color.name)
                .accessibilityAddTraits(chosen == color ? .isSelected : [])
            }
            // Any colour at all, from the system's colour panel.
            Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                .overlay { Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: 9)) }
                .frame(width: Self.side, height: Self.side)
                .overlay {
                    ColorPicker("Any Color", selection: Binding(get: { (chosen ?? .black).color }, set: { pick(PDFColor($0)) }), supportsOpacity: false)
                        .labelsHidden()
                        .opacity(0.02)
                }
                .help("Any Color")
                .accessibilityLabel("Any Color")
        }
    }
}

nonisolated extension PDFColor {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Whether dark marks show better than light ones on the colour.
    var isLight: Bool { 0.299 * red + 0.587 * green + 0.114 * blue > 0.72 }

    /// The colour's name for VoiceOver and tooltips: its hexadecimal value.
    var name: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// The colours for pens, shapes and text: with any colour at the end, three rows of eight, as in Inkpage.
    static let swatches: [PDFColor] = [
        0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x00C7BE, 0x007AFF, 0x5856D6, 0x1C1C1E,
        0xFF2D55, 0xA2845E, 0xFFE066, 0xA8E6A1, 0x64D2FF, 0x9EC1FF, 0xAF52DE, 0x8E8E93,
        0x8B1A1A, 0xC46200, 0x8D6E00, 0x1E7B34, 0x0B6E70, 0x0A3D91, 0xFFFFFF,
    ].map(PDFColor.init(hex:))

    /// The colours for marking text: light ones, which the text shows through.
    static let markers: [PDFColor] = [
        0xFFE14D, 0x8EF09A, 0x8FD3FF, 0xFF9EC4, 0xFFC27A, 0xC6A8FF, 0xFF6B6B,
    ].map(PDFColor.init(hex:))
}
