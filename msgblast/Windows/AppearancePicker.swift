import SwiftUI
import msgblastCore

/// System / Light / Dark choice with small window previews, like System Settings.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.defaultsKey) private var selection = AppAppearance.system

    var body: some View {
        LabeledContent("Appearance") {
            HStack(spacing: 14) {
                ForEach(AppAppearance.allCases) { option in
                    Button { selection = option } label: { tile(option) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-appearance-\(option.rawValue)")
                        .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
        }
        .onChange(of: selection, initial: true) { _, value in NSApp.appearance = value.nsAppearance }
    }

    private func tile(_ option: AppAppearance) -> some View {
        VStack(spacing: 6) {
            preview(option)
                .frame(width: 76, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.15)))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3).opacity(selection == option ? 1 : 0))
            Text(option.title).font(.callout)
                .fontWeight(selection == option ? .semibold : .regular)
                .foregroundStyle(selection == option ? .primary : .secondary)
        }
    }

    @ViewBuilder private func preview(_ option: AppAppearance) -> some View {
        switch option {
        case .light: miniWindow(dark: false)
        case .dark: miniWindow(dark: true)
        case .system:
            HStack(spacing: 0) {
                miniWindow(dark: false).frame(width: 38, alignment: .leading).clipped()
                miniWindow(dark: true).frame(width: 38, alignment: .trailing).clipped()
            }
        }
    }

    private func miniWindow(dark: Bool) -> some View {
        let line = dark ? Color.white.opacity(0.3) : Color.black.opacity(0.18)
        return VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(line).frame(width: 30, height: 6).frame(maxWidth: .infinity, alignment: .trailing)
            Capsule().fill(line).frame(width: 44, height: 3)
            Capsule().fill(line).frame(width: 30, height: 3)
            Spacer(minLength: 0)
            Capsule().fill(dark ? Color.white.opacity(0.15) : Color.white).frame(height: 8)
                .overlay(Circle().fill(Color.accentColor).frame(width: 6).padding(.trailing, 2), alignment: .trailing)
        }
        .padding(6)
        .frame(width: 76, height: 50)
        .background(dark ? Color(white: 0.16) : Color(white: 0.95))
    }
}
