import SwiftUI

// MARK: - FeatureRequestsView support views
//
// Module-internal pieces extracted from FeatureRequestsView.swift to keep the
// surface file within the library file-size budget.

// MARK: Transient notice auto-clear

/// Clears a transient inline notice a few seconds after it appears.
///
/// Equivalent to the per-notice `.task(id:)` blocks it replaces: each new
/// value restarts the task, so a fresh notice always gets its full display
/// window and a cleared one cancels the pending sleep.
private struct AutoClearNoticeModifier: ViewModifier {
    @Binding var notice: String?
    let after: Duration

    func body(content: Content) -> some View {
        content.task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: after)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                notice = nil
            }
        }
    }
}

extension View {
    /// Auto-clears an optional-string notice `after` it appears.
    func autoClearNotice(_ notice: Binding<String?>, after: Duration = .seconds(4)) -> some View {
        modifier(AutoClearNoticeModifier(notice: notice, after: after))
    }
}

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

// MARK: Empty state + compose toolbar (permission-aware)

struct FeatureRequestsEmptyState: View {
    let searchText: String
    let allowsAnonymousFeedback: Bool
    let onCompose: () -> Void

    var body: some View {
        if searchText.isEmpty {
            ContentUnavailableView {
                Label(CupThreadStrings.tr("cupthread.features.empty_title"), systemImage: "lightbulb")
            } description: {
                Text(CupThreadStrings.tr("cupthread.features.empty_description"))
            } actions: {
                if allowsAnonymousFeedback {
                    Button(CupThreadStrings.tr("cupthread.features.request_a_feature"), action: onCompose)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }
}

func featureRequestsEmptyStateText(searchText: String) -> String {
    if !searchText.isEmpty {
        return CupThreadStrings.tr("cupthread.features.empty_with_query", searchText)
    }
    return CupThreadStrings.tr("cupthread.features.empty_no_requests")
}

@ToolbarContentBuilder
func featureRequestsComposeToolbar(
    allowsAnonymousFeedback: Bool,
    onCompose: @escaping () -> Void
) -> some ToolbarContent {
    if allowsAnonymousFeedback {
        ToolbarItem(placement: .primaryAction) {
            Button(action: onCompose) {
                Label(CupThreadStrings.tr("cupthread.features.request_a_feature"), systemImage: "plus")
            }
            .accessibilityHint(CupThreadStrings.tr("cupthread.features.request_a_feature_hint"))
            .accessibilityIdentifier("cupthread.features.compose")
        }
    }
}
