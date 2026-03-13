import SwiftUI

struct WatchProviderDetailView: View {
    let provider: ProviderUsageSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(quotaBars) { bar in
                    QuotaBarView(bar: bar, color: provider.provider.barColors.first ?? .blue)
                }
                paceWarning
            }
            .padding(.horizontal)
        }
        .navigationTitle(provider.provider.displayName)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ProviderIconImage(
                provider: provider.provider,
                size: 20,
                tint: provider.provider.barColors.first ?? .white
            )
            Text(provider.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var paceWarning: some View {
        if let pace = provider.codexWeeklyPaceEstimate() {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Pace: \(String(format: "%.0f", pace.deficitPercent))% over")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
                if let runsOut = pace.runsOutAt {
                    Text("Runs out \(RelativeDateText.abbreviated(from: runsOut))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Bar data

    struct BarModel: Identifiable {
        let id: String
        let title: String
        let remainingPercent: Double
        let resetAt: Date?
    }

    private var quotaBars: [BarModel] {
        var bars: [BarModel] = []
        if let p = provider.resolvedSessionRemainingPercent {
            bars.append(BarModel(id: "primary", title: provider.provider.primaryBarTitle, remainingPercent: p, resetAt: provider.sessionResetsAt))
        }
        if let p = provider.resolvedWeeklyRemainingPercent {
            bars.append(BarModel(id: "secondary", title: provider.provider.secondaryBarTitle, remainingPercent: p, resetAt: provider.weeklyResetsAt))
        }
        if let p = provider.resolvedTertiaryRemainingPercent {
            bars.append(BarModel(id: "tertiary", title: provider.provider.tertiaryBarTitle, remainingPercent: p, resetAt: provider.tertiaryResetsAt))
        }
        return bars
    }
}

private struct QuotaBarView: View {
    let bar: WatchProviderDetailView.BarModel
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bar.title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(bar.remainingPercent))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(colorForPercent(bar.remainingPercent))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * bar.remainingPercent / 100))
                }
            }
            .frame(height: 8)

            if let resetAt = bar.resetAt {
                Text("Resets \(RelativeDateText.abbreviated(from: resetAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colorForPercent(_ percent: Double) -> Color {
        if percent > 50 { return .green }
        if percent > 20 { return .yellow }
        return .red
    }
}

// Make BarModel accessible to QuotaBarView
extension WatchProviderDetailView.BarModel: @retroactive Sendable {}
