import SwiftUI

// MARK: - FeatureRequestsView support views
//
// Module-internal pieces extracted from FeatureRequestsView.swift to keep the
// surface file within the library file-size budget.

// MARK: Load-more row

/// Sentinel row at the end of the list. Appears once more pages exist and
/// auto-loads the next page as the user scrolls near the end; after a page
/// failure it shows the error and turns into an explicit retry button.
struct LoadMoreRow: View {
    let pageError: String?
    let isLoadingNextPage: Bool
    let onRetry: () -> Void
    let onNearEnd: () -> Void

    private var title: String {
        CupThreadStrings.tr(pageError == nil ? "cupthread.features.load_more" : "cupthread.error.try_again")
    }

    var body: some View {
        VStack(spacing: 8) {
            if let pageError {
                Text(pageError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("cupthread.features.page_error")
            }
            Button {
                onRetry()
            } label: {
                HStack(spacing: 8) {
                    if isLoadingNextPage {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(title)
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingNextPage)
            .accessibilityHint(CupThreadStrings.tr("cupthread.features.load_more_hint"))
        }
        .task { onNearEnd() }
    }
}

// MARK: Version filter menu

struct VersionFilterMenu: View {
    @Binding var selectedVersionID: String?
    let versions: [AppVersion]

    var body: some View {
        Menu {
            Picker(CupThreadStrings.tr("cupthread.features.version_picker"), selection: $selectedVersionID) {
                Text(CupThreadStrings.tr("cupthread.features.all_versions")).tag(String?.none)
                ForEach(versions) { version in
                    Text(version.label).tag(String?.some(version.id))
                }
            }
        } label: {
            Label(
                selectedVersionID.flatMap { id in versions.first(where: { $0.id == id })?.label }
                    ?? CupThreadStrings.tr("cupthread.features.all_versions"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .disabled(versions.isEmpty)
        .accessibilityLabel(CupThreadStrings.tr("cupthread.features.filter_by_version"))
    }
}

// MARK: Submitted banner

struct SubmittedBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(CupThreadStrings.tr("cupthread.features.submitted_banner"))
                .font(.footnote.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
