import SwiftUI
import WidgetKit
#if canImport(AppIntents)
import AppIntents
#endif

private let aiUsageWidgetKind = "AiUsageWidgetV3"

struct AiUsageTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let smallProviders: [ProviderID]
    let mediumProviders: [ProviderID]
    let largeProviders: [ProviderID]
}

#if canImport(AppIntents)
enum ProviderOption: String, AppEnum, CaseIterable {
    case none
    case codex
    case claude
    case gemini
    case copilot
    case kimi

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static var caseDisplayRepresentations: [ProviderOption: DisplayRepresentation] {
        [
            .none: "None",
            .codex: "OpenAI Codex",
            .claude: "Claude",
            .gemini: "Google Gemini",
            .copilot: "GitHub Copilot",
            .kimi: "Kimi",
        ]
    }

    var providerID: ProviderID? {
        switch self {
        case .none: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .gemini: return .gemini
        case .copilot: return .copilot
        case .kimi: return .kimi
        }
    }
}

struct AiUsageWidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "AiUsage Widget"
    static var description = IntentDescription("Choose the provider shown in the small layout. Medium and large follow your app sorting order and widget toggles.")

    @Parameter(title: "Small Provider")
    var smallProvider: ProviderOption?

    init() {
        smallProvider = .codex
    }

    var selectedSmallProviders: [ProviderID] {
        deduplicatedProviders([smallProvider])
    }
}

struct AiUsageIntentTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AiUsageTimelineEntry {
        let providerSource = orderedWidgetProviders()
        return AiUsageTimelineEntry(
            date: Date(),
            snapshot: .preview,
            smallProviders: Array(providerSource.prefix(1)),
            mediumProviders: providerSource,
            largeProviders: providerSource
        )
    }

    func snapshot(for configuration: AiUsageWidgetConfigIntent, in context: Context) async -> AiUsageTimelineEntry {
        let snapshot = WidgetSnapshotStore.load() ?? .preview
        return makeEntry(snapshot: snapshot, configuration: configuration)
    }

    func timeline(for configuration: AiUsageWidgetConfigIntent, in context: Context) async -> Timeline<AiUsageTimelineEntry> {
        let storedSnapshot = WidgetSnapshotStore.load()
        let isMockData = storedSnapshot?.isMockData ?? false
        let snapshot: WidgetSnapshot

        if isMockData {
            snapshot = MockSnapshotCycle.next()
            WidgetSnapshotStore.save(snapshot)
        } else {
            let fallbackSnapshot = storedSnapshot ?? .preview
            snapshot = await refreshedSnapshotForWidgetView(fallback: fallbackSnapshot)
        }

        let entry = makeEntry(snapshot: snapshot, configuration: configuration)
        if isMockData {
            return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(2)))
        }
        // Ask again soon so "viewing the widget" gets frequent refresh opportunities,
        // while still avoiding aggressive constant updates.
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
    }

    private func makeEntry(snapshot: WidgetSnapshot, configuration: AiUsageWidgetConfigIntent) -> AiUsageTimelineEntry {
        let providerSource = orderedWidgetProviders()
        let selectedSmallProvider = configuration.selectedSmallProviders.first
        let selectedSmall: [ProviderID]
        if let selectedSmallProvider,
           ProviderWidgetVisibilityStore.isEnabled(selectedSmallProvider)
        {
            selectedSmall = [selectedSmallProvider]
        } else {
            selectedSmall = Array(providerSource.prefix(1))
        }
        return AiUsageTimelineEntry(
            date: Date(),
            snapshot: snapshot,
            smallProviders: selectedSmall,
            mediumProviders: providerSource,
            largeProviders: providerSource
        )
    }
}

@available(iOSApplicationExtension 17.0, *)
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh AI Usage"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        if WidgetSnapshotStore.load()?.isMockData == true {
            WidgetSnapshotStore.save(MockSnapshotCycle.next())
        }
        WidgetCenter.shared.reloadTimelines(ofKind: aiUsageWidgetKind)
        return .result()
    }
}

private func deduplicatedProviders(_ options: [ProviderOption?]) -> [ProviderID] {
    var seen = Set<ProviderID>()
    return options.compactMap { $0?.providerID }.filter { seen.insert($0).inserted }
}

#endif

private func orderedWidgetProviders() -> [ProviderID] {
    let orderedProviders = ProviderOrderStore.load()
    let enabledProviders = ProviderWidgetVisibilityStore.enabledProviders(in: orderedProviders)
    return enabledProviders.isEmpty ? orderedProviders : enabledProviders
}

struct AiUsageWidgetView: View {
    let entry: AiUsageTimelineEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WidgetPalette {
        WidgetPalette.forColorScheme(colorScheme)
    }

    private var selectedSnapshots: [ProviderUsageSnapshot] {
        let source: [ProviderID]

        switch family {
        case .systemSmall:
            source = entry.smallProviders
        case .systemMedium:
            source = entry.mediumProviders
        default:
            source = entry.largeProviders
        }

        return source.compactMap { provider in
            entry.snapshot.providers.first(where: { $0.provider == provider })
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack {
                switch family {
                case .systemSmall:
                    SmallLayout(snapshot: selectedSnapshots.first, palette: palette)
                case .systemMedium:
                    MediumLayout(snapshots: Array(selectedSnapshots.prefix(4)), palette: palette)
                default:
                    LargeLayout(snapshots: Array(selectedSnapshots.prefix(6)), palette: palette)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Updated \(Text(entry.snapshot.generatedAt, style: .relative))")
                .font(.system(size: 9))
                .foregroundStyle(palette.tertiaryText)
                .opacity(0.6)
                .offset(x:5, y: 12)
        }
        .widgetContainerBackground(palette)
    }
}

private struct SmallLayout: View {
    let snapshot: ProviderUsageSnapshot?
    let palette: WidgetPalette

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ProviderIconImage(provider: snapshot.provider, size: 11, tint: palette.headerIconTint)
                    Text(snapshot.provider.displayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondaryText)

                ForEach(snapshot.widgetBars) { bar in
                    QuotaBarLine(
                        label: bar.label,
                        remainingPercent: bar.remainingPercent,
                        colors: snapshot.provider.barColors,
                        resetAt: bar.resetAt,
                        deficitMarkerPercent: bar.deficitMarkerPercent,
                        palette: palette
                    )
                }
            }
        } else {
            Text("No provider data")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
    }
}

private struct MediumLayout: View {
    let snapshots: [ProviderUsageSnapshot]
    let palette: WidgetPalette

    var body: some View {
        GeometryReader { proxy in
            let visibleSnapshots = Array(snapshots.prefix(4))
            if visibleSnapshots.isEmpty {
                Text("No provider data")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if visibleSnapshots.count == 1 {
                MediumTile(snapshot: visibleSnapshots[0], isEmphasized: true, palette: palette)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else if visibleSnapshots.count == 2 {
                HStack(spacing: 8) {
                    ForEach(visibleSnapshots) { snapshot in
                        MediumTile(snapshot: snapshot, isEmphasized: true, palette: palette)
                            .frame(width: (proxy.size.width - 8) / 2, height: proxy.size.height)
                    }
                }
            } else {
                let columns = [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ]
                let rowHeight = max(40, (proxy.size.height - 8) / 2)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(visibleSnapshots) { snapshot in
                        MediumTile(snapshot: snapshot, isEmphasized: false, palette: palette)
                            .frame(height: rowHeight)
                    }
                }
            }
        }
    }
}

private struct MediumTile: View {
    let snapshot: ProviderUsageSnapshot
    let isEmphasized: Bool
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: isEmphasized ? 6 : 4) {
            HStack(spacing: 4) {
                ProviderIconImage(provider: snapshot.provider, size: isEmphasized ? 11 : 9, tint: palette.headerIconTint)
                Text(snapshot.provider.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .font((isEmphasized ? Font.caption : Font.system(size: 10)).weight(.semibold))
            .foregroundStyle(palette.secondaryText)

            if isEmphasized {
                ForEach(snapshot.widgetBars) { bar in
                    QuotaBarLine(
                        label: bar.label,
                        remainingPercent: bar.remainingPercent,
                        colors: snapshot.provider.barColors,
                        resetAt: bar.resetAt,
                        deficitMarkerPercent: bar.deficitMarkerPercent,
                        palette: palette,
                        isCompact: false
                    )
                }
            } else {
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(snapshot.widgetBars) { bar in
                        QuotaBarLine(
                            label: bar.label,
                            remainingPercent: bar.remainingPercent,
                            colors: snapshot.provider.barColors,
                            resetAt: bar.resetAt,
                            deficitMarkerPercent: bar.deficitMarkerPercent,
                            palette: palette,
                            isCompact: true
                        )
                    }
                }
            }
        }
        .padding(isEmphasized ? 10 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.tileBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LargeLayout: View {
    let snapshots: [ProviderUsageSnapshot]
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshots.prefix(6)) { snapshot in
                LargeRow(snapshot: snapshot, palette: palette)
            }
        }
    }
}

private struct LargeRow: View {
    let snapshot: ProviderUsageSnapshot
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ProviderIconImage(provider: snapshot.provider, size: 12, tint: palette.primaryText)
                Text(snapshot.provider.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.system(size: 18).weight(.semibold))
            .foregroundStyle(palette.primaryText)

            HStack(alignment: .top, spacing: 6) {
                ForEach(snapshot.widgetBars) { bar in
                    QuotaBarLine(
                        label: bar.label,
                        remainingPercent: bar.remainingPercent,
                        colors: snapshot.provider.barColors,
                        resetAt: bar.resetAt,
                        deficitMarkerPercent: bar.deficitMarkerPercent,
                        palette: palette,
                        isCompact: true
                    )
                }
            }
        }
        .padding(5)
        .background(palette.tileBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct QuotaBarLine: View {
    let label: String
    let remainingPercent: Double
    let colors: [Color]
    let resetAt: Date?
    let deficitMarkerPercent: Double?
    let palette: WidgetPalette
    var isCompact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 2 : 4) {
            HStack {
                Text(label)
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 2)
                Text("\(Int(remainingPercent.rounded()))%")
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.primaryText)
            }
            .font(isCompact ? .system(size: 9) : .caption2)

            InlineMeter(
                remainingPercent: remainingPercent,
                colors: colors,
                deficitMarkerPercent: deficitMarkerPercent,
                palette: palette
            )
            .frame(height: 4)

            if let resetAt {
                Text("Resets \(RelativeDateText.abbreviated(from: resetAt))")
                    .font(.system(size: isCompact ? 8 : 10))
                    .foregroundStyle(palette.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct InlineMeter: View {
    let remainingPercent: Double
    let colors: [Color]
    let deficitMarkerPercent: Double?
    let palette: WidgetPalette

    private var clamped: Double {
        min(max(remainingPercent, 0), 100)
    }
    private var clampedDeficitMarkerPercent: Double? {
        guard let deficitMarkerPercent else { return nil }
        return min(max(deficitMarkerPercent, 0), 100)
    }
    private var deficitMarkerIsVisible: Bool {
        guard let marker = clampedDeficitMarkerPercent else { return false }
        return marker > clamped + 0.1
    }
    private var deficitMarkerXPercent: Double {
        clampedDeficitMarkerPercent ?? clamped
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.trackBackground)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * (clamped / 100))
                if deficitMarkerIsVisible {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.red.opacity(0.92))
                        .frame(width: 2)
                        .offset(x: max(0, min(proxy.size.width - 2, (proxy.size.width * (deficitMarkerXPercent / 100)) - 1)))
                }
            }
        }
    }
}

struct AiUsageWidget: Widget {
    var body: some WidgetConfiguration {
        #if canImport(AppIntents)
        AppIntentConfiguration(
            kind: aiUsageWidgetKind,
            intent: AiUsageWidgetConfigIntent.self,
            provider: AiUsageIntentTimelineProvider()
        ) { entry in
            AiUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AiUsage")
        .description("Small provider is configurable here. Medium and large follow app order and widget toggles.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #else
        StaticConfiguration(kind: aiUsageWidgetKind, provider: LegacyProvider()) { entry in
            AiUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AiUsage")
        .description("Small provider is configurable here. Medium and large follow app order and widget toggles.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

@main
struct AiUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        AiUsageWidget()
    }
}

private struct WidgetPalette {
    let backgroundGradient: [Color]
    let tileBackground: Color
    let trackBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let headerIconTint: Color

    static func forColorScheme(_ colorScheme: ColorScheme) -> WidgetPalette {
        switch colorScheme {
        case .light:
            return WidgetPalette(
                backgroundGradient: [
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    Color(red: 0.89, green: 0.93, blue: 1.0),
                ],
                tileBackground: .black.opacity(0.06),
                trackBackground: .black.opacity(0.14),
                primaryText: Color(red: 0.14, green: 0.17, blue: 0.27),
                secondaryText: Color(red: 0.30, green: 0.35, blue: 0.45),
                tertiaryText: Color(red: 0.38, green: 0.43, blue: 0.52),
                headerIconTint: Color(red: 0.30, green: 0.35, blue: 0.45)
            )
        default:
            return WidgetPalette(
                backgroundGradient: [
                    Color(red: 0.05, green: 0.06, blue: 0.12),
                    Color(red: 0.08, green: 0.15, blue: 0.30),
                ],
                tileBackground: .white.opacity(0.08),
                trackBackground: .white.opacity(0.16),
                primaryText: .primary,
                secondaryText: .secondary,
                tertiaryText: .secondary.opacity(0.75),
                headerIconTint: .secondary
            )
        }
    }
}

private extension View {
    @ViewBuilder
    func widgetContainerBackground(_ palette: WidgetPalette) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(
                LinearGradient(
                    colors: palette.backgroundGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                for: .widget
            )
        } else {
            background(
                LinearGradient(
                    colors: palette.backgroundGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

private extension WidgetSnapshot {
    static var preview: WidgetSnapshot {
        MockSnapshotCycle.snapshot(at: 0, now: Date())
    }
}

private struct LegacyProvider: TimelineProvider {
    func placeholder(in context: Context) -> AiUsageTimelineEntry {
        let providerSource = orderedWidgetProviders()
        return AiUsageTimelineEntry(
            date: Date(),
            snapshot: .preview,
            smallProviders: Array(providerSource.prefix(1)),
            mediumProviders: providerSource,
            largeProviders: providerSource
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (AiUsageTimelineEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.load() ?? .preview
        let providerSource = orderedWidgetProviders()
        completion(
            AiUsageTimelineEntry(
                date: Date(),
                snapshot: snapshot,
                smallProviders: Array(providerSource.prefix(1)),
                mediumProviders: providerSource,
                largeProviders: providerSource
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AiUsageTimelineEntry>) -> Void) {
        let storedSnapshot = WidgetSnapshotStore.load() ?? .preview
        Task {
            let snapshot = await refreshedSnapshotForWidgetView(fallback: storedSnapshot)
            let providerSource = orderedWidgetProviders()
            let entry = AiUsageTimelineEntry(
                date: Date(),
                snapshot: snapshot,
                smallProviders: Array(providerSource.prefix(1)),
                mediumProviders: providerSource,
                largeProviders: providerSource
            )
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
        }
    }
}

private func refreshedSnapshotForWidgetView(fallback: WidgetSnapshot) async -> WidgetSnapshot {
    let credentialsByProvider = WidgetSnapshotStore.loadRefreshCredentials()
    if credentialsByProvider.isEmpty { return fallback }

    let providerOrder = orderedWidgetProviders()
    var refreshedByProvider: [ProviderID: ProviderUsageSnapshot] = [:]

    await withTaskGroup(of: (ProviderID, ProviderUsageSnapshot?).self) { group in
        for provider in providerOrder {
            guard let widgetCredentials = credentialsByProvider[provider] else { continue }
            let credentials = ProviderCredentials(
                accessToken: widgetCredentials.accessToken,
                refreshToken: nil,
                accountID: widgetCredentials.accountID,
                cookieHeader: widgetCredentials.cookieHeader,
                geminiAuthorizationHeader: widgetCredentials.geminiAuthorizationHeader,
                geminiAPIKey: widgetCredentials.geminiAPIKey
            )
            group.addTask {
                let snapshot = await fetchUsageWithTimeout(for: provider, credentials: credentials, timeoutSeconds: 8)
                return (provider, snapshot)
            }
        }

        for await (provider, snapshot) in group {
            if let snapshot {
                refreshedByProvider[provider] = snapshot
            }
        }
    }

    if refreshedByProvider.isEmpty { return fallback }

    let fallbackByProvider = Dictionary(uniqueKeysWithValues: fallback.providers.map { ($0.provider, $0) })
    let mergedProviders = providerOrder.compactMap { provider in
        refreshedByProvider[provider] ?? fallbackByProvider[provider]
    }

    if mergedProviders.isEmpty { return fallback }

    let refreshedSnapshot = WidgetSnapshot(generatedAt: Date(), isMockData: false, providers: mergedProviders)
    WidgetSnapshotStore.save(refreshedSnapshot)
    return refreshedSnapshot
}

private func fetchUsageWithTimeout(
    for provider: ProviderID,
    credentials: ProviderCredentials,
    timeoutSeconds: UInt64
) async -> ProviderUsageSnapshot? {
    await withTaskGroup(of: ProviderUsageSnapshot?.self) { group in
        group.addTask {
            let client = ProviderAPIClientFactory.client(for: provider)
            return try? await client.fetchUsage(using: credentials)
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            return nil
        }

        let firstResult = await group.next() ?? nil
        group.cancelAll()
        return firstResult
    }
}

private struct WidgetQuotaBar: Identifiable {
    let id: String
    let label: String
    let remainingPercent: Double
    let resetAt: Date?
    let deficitMarkerPercent: Double?
}

private extension ProviderUsageSnapshot {
    var widgetBars: [WidgetQuotaBar] {
        switch provider {
        case .codex:
            let weeklyDeficitMarker = codexWeeklyDeficitMarkerPercent()
            return [
                makeBar(label: provider.primaryBarTitle, percent: resolvedSessionRemainingPercent, resetAt: sessionResetsAt),
                makeBar(
                    label: provider.secondaryBarTitle,
                    percent: resolvedWeeklyRemainingPercent,
                    resetAt: weeklyResetsAt,
                    deficitMarkerPercent: weeklyDeficitMarker
                )
            ].compactMap { $0 }
        case .gemini:
            return [
                makeBar(label: provider.primaryBarTitle, percent: resolvedSessionRemainingPercent, resetAt: sessionResetsAt),
                makeBar(label: provider.secondaryBarTitle, percent: resolvedWeeklyRemainingPercent, resetAt: weeklyResetsAt),
            ].compactMap { $0 }
        case .claude:
            return [
                makeBar(label: provider.primaryBarTitle, percent: resolvedSessionRemainingPercent, resetAt: sessionResetsAt),
                makeBar(label: provider.secondaryBarTitle, percent: resolvedWeeklyRemainingPercent, resetAt: weeklyResetsAt),
            ].compactMap { $0 }
        case .copilot:
            return [
                makeBar(label: provider.primaryBarTitle, percent: resolvedSessionRemainingPercent, resetAt: sessionResetsAt),
                makeBar(label: provider.secondaryBarTitle, percent: resolvedWeeklyRemainingPercent, resetAt: weeklyResetsAt),
            ].compactMap { $0 }
        case .kimi:
            return [
                makeBar(label: provider.primaryBarTitle, percent: resolvedSessionRemainingPercent, resetAt: sessionResetsAt),
                makeBar(label: provider.secondaryBarTitle, percent: resolvedWeeklyRemainingPercent, resetAt: weeklyResetsAt),
            ].compactMap { $0 }
        }
    }

    private func makeBar(
        label: String,
        percent: Double?,
        resetAt: Date?,
        deficitMarkerPercent: Double? = nil
    ) -> WidgetQuotaBar? {
        guard let percent else { return nil }
        let clamped = min(max(percent, 0), 100)
        return WidgetQuotaBar(
            id: label,
            label: label,
            remainingPercent: clamped,
            resetAt: resetAt,
            deficitMarkerPercent: deficitMarkerPercent
        )
    }

    private func codexWeeklyDeficitMarkerPercent(now: Date = Date()) -> Double? {
        codexWeeklyPaceEstimate(now: now)?.expectedRemainingPercent
    }
    
}

// Canvas Previews

// MARK: - Previews

private var previewEntry: AiUsageTimelineEntry {
    AiUsageTimelineEntry(
        date: .now,
        snapshot: .preview,
        smallProviders: orderedWidgetProviders().prefix(1).map { $0 },
        mediumProviders: orderedWidgetProviders(),
        largeProviders: orderedWidgetProviders()
    )
}

// 1) REAL widget preview (no environment, correct chrome)
#Preview(as: .systemSmall) {
    AiUsageWidget()
} timeline: {
    previewEntry
}

// 2) DARK MODE view preview (for appearance testing)
#Preview("Small – Dark") {
    AiUsageWidgetView(entry: previewEntry)
        .environment(\.colorScheme, .dark)
        .frame(width: 155, height: 155)
}

// 3) LIGHT MODE view preview
#Preview("Small – Light") {
    AiUsageWidgetView(entry: previewEntry)
        .environment(\.colorScheme, .light)
        .frame(width: 155, height: 155)
}
