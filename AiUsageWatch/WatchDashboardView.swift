import Combine
import SwiftUI

struct WatchDashboardView: View {
    var sessionManager: WatchSessionManager
    @State private var now = Date()
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = sessionManager.snapshot, !snapshot.providers.isEmpty {
                    providerList(snapshot)
                } else {
                    emptyState
                }
            }
            .navigationTitle("AiUsage")
            .onReceive(ticker) { now = $0 }
        }
    }

    private func providerList(_ snapshot: WidgetSnapshot) -> some View {
        List {
            ForEach(snapshot.providers) { provider in
                NavigationLink(value: provider) {
                    WatchProviderRow(provider: provider)
                }
            }

            footer
        }
        .navigationDestination(for: ProviderUsageSnapshot.self) { provider in
            WatchProviderDetailView(provider: provider)
        }
        .refreshable {
            sessionManager.requestRefresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lastUpdated = sessionManager.lastUpdated {
                let minutesAgo = max(0, Int(now.timeIntervalSince(lastUpdated) / 60))
                let isStale = minutesAgo >= 10
                HStack(spacing: 4) {
                    if isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(minutesAgo < 1 ? "Updated just now" : "Updated \(minutesAgo) min ago")
                }
                .font(.caption2)
                .foregroundStyle(isStale ? .orange : .secondary)
            }
            if sessionManager.isRefreshing {
                HStack(spacing: 4) {
                    ProgressView()
                    Text("Refreshing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if !sessionManager.isPhoneReachable {
                HStack(spacing: 4) {
                    Image(systemName: "iphone.slash")
                        .font(.caption2)
                    Text("iPhone unavailable")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.right.inward")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Set up providers in\nthe iPhone app")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct WatchProviderRow: View {
    let provider: ProviderUsageSnapshot

    var body: some View {
        HStack(spacing: 8) {
            ProviderIconImage(
                provider: provider.provider,
                size: 18,
                tint: provider.provider.barColors.first ?? .white
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.provider.displayName)
                    .font(.footnote.weight(.semibold))
                quotaSummary
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var quotaSummary: some View {
        let items = quotaItems
        if items.isEmpty {
            Text("No data")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(items, id: \.label) { item in
                    HStack(spacing: 2) {
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(Int(item.percent))%")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(colorForPercent(item.percent))
                    }
                }
            }
        }
    }

    private struct QuotaItem {
        let label: String
        let percent: Double
    }

    private var quotaItems: [QuotaItem] {
        var items: [QuotaItem] = []
        if let p = provider.resolvedSessionRemainingPercent {
            items.append(QuotaItem(label: provider.provider.primaryBarTitle, percent: p))
        }
        if let p = provider.resolvedWeeklyRemainingPercent {
            items.append(QuotaItem(label: provider.provider.secondaryBarTitle, percent: p))
        }
        if let p = provider.resolvedTertiaryRemainingPercent {
            items.append(QuotaItem(label: provider.provider.tertiaryBarTitle, percent: p))
        }
        return items
    }

    private func colorForPercent(_ percent: Double) -> Color {
        if percent > 50 { return .green }
        if percent > 20 { return .yellow }
        return .red
    }
}

// MARK: - Previews

#Preview("Dashboard") {
    let manager = WatchSessionManager.shared
    let _ = { manager.applyPreview(PreviewData.snapshot) }()
    WatchDashboardView(sessionManager: manager)
}

#Preview("Provider Row") {
    List {
        WatchProviderRow(provider: PreviewData.claude)
    }
}
