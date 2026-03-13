import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Configuration Intent

enum WatchProviderOption: String, AppEnum, CaseIterable {
    case codex, claude, gemini, copilot, kimi

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static var caseDisplayRepresentations: [WatchProviderOption: DisplayRepresentation] {
        [
            .codex: "Codex",
            .claude: "Claude",
            .gemini: "Gemini",
            .copilot: "Copilot",
            .kimi: "Kimi",
        ]
    }

    var providerID: ProviderID {
        switch self {
        case .codex: return .codex
        case .claude: return .claude
        case .gemini: return .gemini
        case .copilot: return .copilot
        case .kimi: return .kimi
        }
    }
}

struct WatchComplicationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "AI Usage"
    static var description = IntentDescription("Show a provider's usage on your watch face.")

    @Parameter(title: "Provider", default: .codex)
    var provider: WatchProviderOption
}

// MARK: - Timeline

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let providerID: ProviderID
    let snapshot: ProviderUsageSnapshot?
}

struct WatchComplicationProvider: AppIntentTimelineProvider {
    typealias Entry = WatchComplicationEntry
    typealias Intent = WatchComplicationIntent

    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, providerID: .codex, snapshot: nil)
    }

    func snapshot(for configuration: WatchComplicationIntent, in context: Context) async -> WatchComplicationEntry {
        let snap = loadCached(for: configuration.provider.providerID)
        return WatchComplicationEntry(date: .now, providerID: configuration.provider.providerID, snapshot: snap)
    }

    func timeline(for configuration: WatchComplicationIntent, in context: Context) async -> Timeline<WatchComplicationEntry> {
        let snap = loadCached(for: configuration.provider.providerID)
        let entry = WatchComplicationEntry(date: .now, providerID: configuration.provider.providerID, snapshot: snap)
        // Refresh in 15 minutes; WatchSessionManager calls reloadAllTimelines on new data
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        return Timeline(entries: [entry], policy: .after(next))
    }

    func recommendations() -> [AppIntentRecommendation<WatchComplicationIntent>] {
        WatchProviderOption.allCases.map { option in
            let intent = WatchComplicationIntent()
            intent.provider = option
            return AppIntentRecommendation(intent: intent, description: option.providerID.displayName)
        }
    }

    private func loadCached(for provider: ProviderID) -> ProviderUsageSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: "aiusage.watch.cached_snapshot"),
              let widget = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return nil
        }
        return widget.providers.first(where: { $0.provider == provider })
    }
}

// MARK: - Views

struct CircularComplicationView: View {
    let entry: WatchComplicationEntry

    var body: some View {
        if let snap = entry.snapshot, let pct = snap.resolvedSessionRemainingPercent {
            Gauge(value: pct, in: 0...100) {
                Text(entry.providerID.displayName.prefix(2))
                    .font(.system(.caption2, weight: .bold))
            } currentValueLabel: {
                Text("\(Int(pct))")
                    .font(.system(.body, weight: .bold))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(colorForPercent(pct))
        } else {
            Gauge(value: 0, in: 0...100) {
                Text(entry.providerID.displayName.prefix(2))
                    .font(.system(.caption2, weight: .bold))
            } currentValueLabel: {
                Text("–")
            }
            .gaugeStyle(.accessoryCircular)
        }
    }
}

struct CornerComplicationView: View {
    let entry: WatchComplicationEntry

    var body: some View {
        if let snap = entry.snapshot, let pct = snap.resolvedSessionRemainingPercent {
            Text("\(Int(pct))%")
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(colorForPercent(pct))
                .widgetLabel {
                    Text(entry.providerID.displayName)
                }
        } else {
            Text("–")
                .widgetLabel {
                    Text(entry.providerID.displayName)
                }
        }
    }
}

struct RectangularComplicationView: View {
    let entry: WatchComplicationEntry

    var body: some View {
        if let snap = entry.snapshot {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.providerID.displayName)
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()

                if let pct = snap.resolvedSessionRemainingPercent {
                    barRow(title: entry.providerID.primaryBarTitle, pct: pct)
                }
                if let pct = snap.resolvedWeeklyRemainingPercent {
                    barRow(title: entry.providerID.secondaryBarTitle, pct: pct)
                }
            }
        } else {
            VStack(alignment: .leading) {
                Text(entry.providerID.displayName)
                    .font(.caption.weight(.semibold))
                Text("No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func barRow(title: String, pct: Double) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(.caption2))
                .frame(width: 38, alignment: .leading)
            Gauge(value: pct, in: 0...100) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(colorForPercent(pct))
            Text("\(Int(pct))%")
                .font(.system(.caption2, weight: .medium))
                .frame(width: 28, alignment: .trailing)
        }
    }
}

struct InlineComplicationView: View {
    let entry: WatchComplicationEntry

    var body: some View {
        if let snap = entry.snapshot, let pct = snap.resolvedSessionRemainingPercent {
            Text("\(entry.providerID.displayName) \(Int(pct))%")
        } else {
            Text("\(entry.providerID.displayName) –")
        }
    }
}

// MARK: - Widget

struct AiUsageWatchComplication: Widget {
    let kind = "AiUsageWatchComplication"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: WatchComplicationIntent.self,
            provider: WatchComplicationProvider()
        ) { entry in
            complicationView(for: entry)
        }
        .configurationDisplayName("AI Usage")
        .description("Provider usage on your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }

    @ViewBuilder
    private func complicationView(for entry: WatchComplicationEntry) -> some View {
        WatchComplicationEntryView(entry: entry)
    }
}

private struct WatchComplicationEntryView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularComplicationView(entry: entry)
        case .accessoryCorner:
            CornerComplicationView(entry: entry)
        case .accessoryRectangular:
            RectangularComplicationView(entry: entry)
        case .accessoryInline:
            InlineComplicationView(entry: entry)
        default:
            CircularComplicationView(entry: entry)
        }
    }
}

// MARK: - Helpers

private func colorForPercent(_ percent: Double) -> Color {
    if percent > 50 { return .green }
    if percent > 20 { return .yellow }
    return .red
}

// MARK: - Previews

private let previewEntry = WatchComplicationEntry(
    date: .now,
    providerID: .claude,
    snapshot: PreviewData.claude
)

#Preview("Circular", as: .accessoryCircular) {
    AiUsageWatchComplication()
} timeline: {
    previewEntry
}

#Preview("Corner", as: .accessoryCorner) {
    AiUsageWatchComplication()
} timeline: {
    previewEntry
}

#Preview("Rectangular", as: .accessoryRectangular) {
    AiUsageWatchComplication()
} timeline: {
    previewEntry
}

#Preview("Inline", as: .accessoryInline) {
    AiUsageWatchComplication()
} timeline: {
    previewEntry
}
