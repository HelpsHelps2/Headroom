import SwiftUI

struct TopBar<Leading: View, Title: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var leading: Leading
    @ViewBuilder var title: Title
    @ViewBuilder var trailing: Trailing
    var body: some View {
        ZStack {
            title
            HStack { leading; Spacer(); trailing }
        }
        .frame(height: 22)
        .padding(.horizontal, 14).padding(.top, 2)
        .foregroundStyle(theme.muted)
    }
}

struct Brand: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "internaldrive").font(.sans(12, .semibold)).foregroundStyle(theme.accent)
            Text("Headroom").font(.sans(13, .semibold)).foregroundStyle(theme.ink)
        }
    }
}

struct IconButton: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.sans(13, .medium)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(theme.muted).help(help).accessibilityLabel(help)
    }
}

/// Scan now. The arrow spins in the accent color while any scan runs, including scheduled ones.
struct ScanButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var body: some View {
        let scanning = model.scanning
        Button { Task { await model.scan() } } label: {
            TimelineView(.animation(paused: !scanning)) { context in
                Image(systemName: "arrow.clockwise").font(.sans(13, .medium))
                    .rotationEffect(.degrees(scanning ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360 : 0))
            }
            .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(scanning ? theme.accent : theme.muted)
        .allowsHitTesting(!scanning && !model.demo && !model.preferences.roots.isEmpty)
        .keyboardShortcut("r", modifiers: .command)
        .help(scanning ? (model.scanProgress.total > 0 ? "Scanning \(model.scanProgress.done) of \(model.scanProgress.total)" : "Scanning") : "Scan now")
        .accessibilityLabel(scanning ? "Scanning" : "Scan now")
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct Tabs: View {
    @Environment(\.theme) private var theme
    @Binding var selection: AppTab
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab } } label: {
                    Text(tab.rawValue).font(.sans(11.5, .medium))
                        .foregroundStyle(selection == tab ? theme.ink : theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 6).fill(theme.segmentOn)
                                    .shadow(color: .black.opacity(theme.dark ? 0.25 : 0.08), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(AppTab.allCases.firstIndex(of: tab)! + 1)")), modifiers: .command)
            }
        }
        .padding(2)
        .background(theme.segment, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14).padding(.top, 12)
    }
}

struct StatusPill: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    var calm = false
    @State private var breathing = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().frame(width: 6, height: 6)
                .scaleEffect(breathing ? 1.2 : 1).opacity(breathing ? 1 : 0.35)
            Text(text.uppercased()).font(.mono(10, .semibold)).tracking(0.8)
        }
        .foregroundStyle(calm ? theme.muted : theme.accent)
        .onAppear {
            guard !reduceMotion, !calm else { breathing = true; return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

/// The disk ring: everything else on disk, then the highlighted arc (stale output), then free space as bare track.
struct DiskRing<Core: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var capacity: Int64
    var available: Int64
    var highlight: Int64
    var size: CGFloat = 250
    var lineWidth: CGFloat = 9
    var ticks = true
    var tickSpeed: Double = 90
    var active = false
    @ViewBuilder var core: Core

    var body: some View {
        let total = Double(max(capacity, 1))
        let marked = min(Double(max(highlight, 0)) / total, 1)
        let usedAll = capacity > 0 ? min(Double(max(capacity - available, 0)) / total, 1) : 0
        let other = max(usedAll - marked, 0)
        let gap = marked > 0 && other > 0 ? 0.012 : 0
        let radius = size * 104 / 250
        ZStack {
            if ticks {
                TimelineView(.animation(paused: !active || reduceMotion)) { context in
                    let rotation = active && !reduceMotion ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: tickSpeed) / tickSpeed * 360 : 0
                    Circle()
                        .stroke(theme.track, style: StrokeStyle(lineWidth: size * 3 / 250, dash: [1.2, 6.4]))
                        .frame(width: radius * 2 + size * 34 / 250, height: radius * 2 + size * 34 / 250)
                        .rotationEffect(.degrees(rotation))
                }
            }
            Group {
                Circle().stroke(theme.track, lineWidth: lineWidth)
                Circle().trim(from: 0, to: other).stroke(theme.used, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle().trim(from: other + gap, to: min(other + gap + marked, 1))
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .frame(width: radius * 2, height: radius * 2)
            .rotationEffect(.degrees(-90))
            .animation(.spring(response: 0.8, dampingFraction: 0.9), value: marked)
            core
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
    }
}

struct CoreDisc<Content: View>: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 156
    var success = false
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Circle().fill(theme.coreFill)
                .overlay(Circle().fill(success ? theme.success.opacity(theme.dark ? 0.25 : 0.14) : .clear))
                .overlay(Circle().strokeBorder(theme.dark ? Color.white.opacity(0.05) : Color.black.opacity(0.06), lineWidth: 1))
                .overlay(alignment: .top) {
                    if theme.dark { Circle().trim(from: 0.42, to: 0.58).stroke(.white.opacity(0.09), lineWidth: 1).rotationEffect(.degrees(180)) }
                }
                .shadow(color: .black.opacity(theme.dark ? 0.55 : 0.18), radius: 16, y: 12)
            content
        }
        .frame(width: size, height: size)
    }
}

struct BigBytes: View {
    @Environment(\.theme) private var theme
    let bytes: Int64
    var size: CGFloat = 27
    var body: some View {
        let parts = Format.parts(bytes)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.number).font(.mono(size, .medium)).tracking(-size * 0.03)
                .contentTransition(.numericText(value: Double(bytes)))
            Text(parts.unit).font(.mono(size * 0.48)).foregroundStyle(theme.muted)
        }
        .monospacedDigit()
    }
}

struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.surfaceStroke, lineWidth: 1))
            .shadow(color: theme.dark ? .clear : .black.opacity(0.04), radius: 1, y: 1)
    }
}

struct Switch: View {
    @Environment(\.theme) private var theme
    let isOn: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Capsule().fill(isOn ? theme.accent : theme.dark ? theme.used : theme.track)
                .frame(width: 26, height: 15)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? theme.accentInk : theme.dark ? Color(hex: 0xC8CBD0) : .white).frame(width: 11, height: 11).padding(2)
                        .shadow(color: .black.opacity(isOn ? 0 : 0.15), radius: 1, y: 0.5)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct PrimaryButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let title: String
    var detail: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.sans(12.5, .semibold))
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.mono(12, .medium)).opacity(0.75) }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .foregroundStyle(enabled ? theme.accentInk : theme.dim)
            .background(enabled ? theme.accent : theme.segment, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(enabled ? 0.18 : 0), lineWidth: 1).mask(alignment: .top) { Rectangle().frame(height: 1) })
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct GhostButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.sans(12, .medium)).padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(theme.ink)
    }
}

struct SectionLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.mono(9.5, .semibold)).tracking(1).foregroundStyle(theme.dim)
    }
}

extension View {
    func hairline(_ edge: Edge = .top) -> some View { modifier(Hairline(edge: edge)) }
}

private struct Hairline: ViewModifier {
    @Environment(\.theme) private var theme
    let edge: Edge
    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .top ? .top : .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
    }
}
