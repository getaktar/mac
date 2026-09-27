import SwiftUI

/// Shared page chrome for a Settings tab: a title, a one-line subtitle, and
/// left-aligned, top-anchored content (never vertically centered).
struct SettingsPage<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            content
        }
    }
}

/// A rounded, bordered container that groups related rows, matching the
/// "card" grouping used throughout Settings.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Divider().padding(.leading, 12)
    }
}

struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(12)
    }
}
