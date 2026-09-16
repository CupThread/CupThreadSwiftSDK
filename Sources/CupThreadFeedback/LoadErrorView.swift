import SwiftUI

/// Friendly load-failure placeholder with a retry action, shared by all SDK views.
/// Shown when a network request fails; the retry closure re-runs the load,
/// which flips the view back to its loading state.
struct LoadErrorView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(Color.secondary.opacity(0.08), in: Circle())
                .accessibilityHidden(true)

            Text(CupThreadStrings.tr("cupthread.error.could_not_load"))
                .font(.headline)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await retry() }
            } label: {
                Label(CupThreadStrings.tr("cupthread.error.try_again"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CupThreadStrings.tr("cupthread.error.accessibility_failed", message))
    }
}

/// Transient inline warning notice — e.g. for a failed reload whose previous
/// results stay on screen (non-destructive failure), or a failed vote.
struct InlineNoticeBanner: View {
    var icon: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
