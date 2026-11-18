import SwiftUI
import WidgetKit
#if canImport(AppIntents)
import AppIntents
#endif

private let aiUsageWidgetKind = "AiUsageWidgetV3"

private struct WidgetReferenceDateKey: EnvironmentKey {
    static let defaultValue = Date.distantPast
}

private extension EnvironmentValues {
    var widgetReferenceDate: Date {
        get { self[WidgetReferenceDateKey.self] }
        set { self[WidgetReferenceDateKey.self] = newValue }
    }
}

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
    case grok
    case gemini
    case copilot
    case kimi

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static var caseDisplayRepresentations: [ProviderOption: DisplayRepresentation] {
        [
            .none: "None",
            .codex: "OpenAI Codex",
            .claude: "Claude",
            .grok: "Grok",
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
        case .grok: return .grok
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
        let snapshot = WidgetSnapshotStore.load() ?? (context.isPreview ? .preview : .empty)
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
            let fallbackSnapshot = storedSnapshot ?? .empty
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
            snapshot: snapshot.includingGeminiWebUsage(),
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
    return ProviderWidgetVisibilityStore.enabledProviders(in: orderedProviders)
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
        let limit: Int

        switch family {
        case .systemSmall:
            source = entry.smallProviders
            limit = 1
        case .systemMedium:
            source = entry.mediumProviders
            limit = 4
        default:
            source = entry.largeProviders
            limit = 6
        }

        let snapshots = source.compactMap { provider in
            entry.snapshot.providers.first(where: { $0.provider == provider })
        }
        var visible = Array(snapshots.prefix(limit))
        if family == .systemMedium,
           let geminiIndex = snapshots.firstIndex(where: { $0.isGeminiWebUsage == true }),
           geminiIndex >= limit {
            visible[limit - 1] = snapshots[geminiIndex]
        }
        return visible
    }

    var body: some View {
        let snapshots = selectedSnapshots
        ZStack(alignment: .bottomLeading) {
            VStack {
                switch family {
                case .systemSmall:
                    SmallLayout(snapshot: snapshots.first, provider: entry.smallProviders.first, palette: palette)
                case .systemMedium:
                    MediumLayout(snapshots: snapshots, palette: palette)
                default:
                    LargeLayout(snapshots: snapshots, palette: palette)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !snapshots.isEmpty {
                let gemini = snapshots.first { $0.isGeminiWebUsage == true }
                let timestamp = gemini.map { Text("Gemini synced \(Text($0.updatedAt, style: .relative)) ago") }
                    ?? Text("Updated \(Text(entry.snapshot.generatedAt, style: .relative))")
                timestamp
                    .font(.system(size: 9))
                    .foregroundStyle(palette.tertiaryText)
                    .opacity(0.6)
                    .frame(maxWidth: .infinity, alignment: family == .systemMedium ? .center : .leading)
                    .offset(x: family == .systemMedium ? 0 : 5, y: 12)
            }
        }
        .environment(\.widgetReferenceDate, entry.date)
        .widgetURL(family == .systemSmall && entry.smallProviders.first == .gemini ? GeminiSyncRequest.appURL : nil)
        .widgetContainerBackground(palette)
    }
}

private struct SmallLayout: View {
    let snapshot: ProviderUsageSnapshot?
    let provider: ProviderID?
    let palette: WidgetPalette

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 6) {
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
            if provider == .gemini {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Google Gemini", systemImage: "sparkle")
                        .font(.caption.weight(.semibold))
                    Text("Tap to sync quota")
                        .font(.caption)
                }
                .foregroundStyle(palette.secondaryText)
            } else {
                Text("No provider data")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
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
            } else if visibleSnapshots.count <= 2 {
                let gap: CGFloat = 8
                let tileWidth = visibleSnapshots.count == 1 ? proxy.size.width : (proxy.size.width - gap) / 2
                let inlineResets = visibleSnapshots.contains { $0.widgetBars.count > 2 }
                HStack(alignment: .top, spacing: gap) {
                    ForEach(visibleSnapshots) { snapshot in
                        GeminiWidgetLink(snapshot: snapshot) {
                            MediumTile(
                                snapshot: snapshot,
                                palette: palette,
                                width: tileWidth,
                                height: proxy.size.height,
                                isEmphasized: true,
                                inlineResets: inlineResets
                            )
                        }
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
                        GeminiWidgetLink(snapshot: snapshot) {
                            MediumTile(snapshot: snapshot, palette: palette, height: rowHeight)
                        }
                    }
                }
            }
        }
    }
}

private struct MediumTile: View {
    let snapshot: ProviderUsageSnapshot
    let palette: WidgetPalette
    var width: CGFloat?
    let height: CGFloat
    var isEmphasized = false
    var inlineResets = false

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
                        inlineReset: inlineResets
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
        .frame(width: width, height: height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(palette.tileBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LargeLayout: View {
    let snapshots: [ProviderUsageSnapshot]
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(snapshots.prefix(6)) { snapshot in
                GeminiWidgetLink(snapshot: snapshot) {
                    LargeRow(snapshot: snapshot, palette: palette)
                }
            }
        }
    }
}

private struct GeminiWidgetLink<Content: View>: View {
    let snapshot: ProviderUsageSnapshot
    @ViewBuilder let content: () -> Content

    var body: some View {
        if snapshot.isGeminiWebUsage == true {
            Link(destination: GeminiSyncRequest.appURL, label: content)
                .buttonStyle(.plain)
                .accessibilityHint("Syncs Gemini quota in Safari")
        } else {
            content()
        }
    }
}

private struct LargeRow: View {
    let snapshot: ProviderUsageSnapshot
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ProviderIconImage(provider: snapshot.provider, size: 12, tint: palette.primaryText)
                Text(snapshot.provider.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.caption.weight(.semibold))
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
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(palette.tileBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct QuotaBarLine: View {
    let label: String
    let remainingPercent: Double?
    let colors: [Color]
    let resetAt: Date?
    let deficitMarkerPercent: Double?
    let palette: WidgetPalette
    var isCompact: Bool = false
    var inlineReset: Bool = false
    @Environment(\.widgetReferenceDate) private var referenceDate

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact || inlineReset ? 2 : 4) {
            HStack(spacing: 4) {
                Text(label)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                if inlineReset, let resetAt {
                    resetText(resetAt)
                }
                Text(remainingPercent.map { "\(Int($0.rounded()))%" } ?? "N/A")
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.primaryText)
                    .fixedSize()
            }
            .font(isCompact ? .system(size: 9) : .caption2)

            if let remainingPercent {
                InlineMeter(
                    remainingPercent: remainingPercent,
                    colors: colors,
                    deficitMarkerPercent: deficitMarkerPercent,
                    palette: palette
                )
                .frame(height: 4)
            }

            if !inlineReset, let resetAt {
                resetText(resetAt)
            }
        }
    }

    private func resetText(_ date: Date) -> some View {
        let countdown = QuotaCountdownFormat(date: date, compact: isCompact || inlineReset)
        return Text(countdown.format(referenceDate))
            .font(.system(size: isCompact ? 8 : 10).monospacedDigit())
            .foregroundStyle(palette.tertiaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityLabel(QuotaCountdownFormat(date: date).format(referenceDate))
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
        GeminiUsageWidget()
    }
}

private struct GeminiUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GeminiUsageWidget", provider: GeminiUsageTimelineProvider()) { entry in
            AiUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Gemini Usage")
        .description("See your Gemini Apps quota. Tap the widget to sync it.")
        .supportedFamilies([.systemSmall])
    }
}

private struct GeminiUsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> AiUsageTimelineEntry {
        entry(snapshot: .preview, date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (AiUsageTimelineEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : WidgetSnapshot.empty.includingGeminiWebUsage()
        completion(entry(snapshot: snapshot, date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AiUsageTimelineEntry>) -> Void) {
        let snapshot = WidgetSnapshot.empty.includingGeminiWebUsage()
        let date = Date()
        guard !snapshot.providers.isEmpty else {
            completion(Timeline(entries: [entry(snapshot: snapshot, date: date)], policy: .never))
            return
        }
        // WidgetKit can advance reset timestamps without making quota requests.
        let entries = (0..<48).map { entry(snapshot: snapshot, date: date.addingTimeInterval(Double($0 * 900))) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(snapshot: WidgetSnapshot, date: Date) -> AiUsageTimelineEntry {
        AiUsageTimelineEntry(date: date, snapshot: snapshot, smallProviders: [.gemini], mediumProviders: [], largeProviders: [])
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
    static var empty: WidgetSnapshot {
        WidgetSnapshot(generatedAt: .now, providers: [])
    }

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
        let snapshot = WidgetSnapshotStore.load() ?? (context.isPreview ? .preview : .empty)
        let providerSource = orderedWidgetProviders()
        completion(
            AiUsageTimelineEntry(
                date: Date(),
                snapshot: snapshot.includingGeminiWebUsage(),
                smallProviders: Array(providerSource.prefix(1)),
                mediumProviders: providerSource,
                largeProviders: providerSource
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AiUsageTimelineEntry>) -> Void) {
        let storedSnapshot = WidgetSnapshotStore.load() ?? .empty
        Task {
            let snapshot = await refreshedSnapshotForWidgetView(fallback: storedSnapshot)
            let providerSource = orderedWidgetProviders()
            let entry = AiUsageTimelineEntry(
                date: Date(),
                snapshot: snapshot.includingGeminiWebUsage(),
                smallProviders: Array(providerSource.prefix(1)),
                mediumProviders: providerSource,
                largeProviders: providerSource
            )
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
        }
    }
}

private extension WidgetSnapshot {
    func includingGeminiWebUsage() -> WidgetSnapshot {
        guard !isMockData, let gemini = GeminiWebUsageStore.load()?.snapshot else { return self }
        return WidgetSnapshot(
            generatedAt: generatedAt,
            providers: providers.filter { $0.provider != .gemini } + [gemini]
        )
    }
}

private func refreshedSnapshotForWidgetView(fallback: WidgetSnapshot) async -> WidgetSnapshot {
    let credentialsByProvider = WidgetSnapshotStore.loadRefreshCredentials()
    if credentialsByProvider.isEmpty { return fallback }

    let providerOrder = orderedWidgetProviders()
    let hasGeminiWebUsage = GeminiWebUsageStore.load() != nil
    var refreshedByProvider: [ProviderID: ProviderUsageSnapshot] = [:]

    await withTaskGroup(of: (ProviderID, ProviderUsageSnapshot?).self) { group in
        for provider in providerOrder {
            if provider == .gemini, hasGeminiWebUsage { continue }
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
    let remainingPercent: Double?
    let resetAt: Date?
    let deficitMarkerPercent: Double?
}

private extension ProviderUsageSnapshot {
    var widgetBars: [WidgetQuotaBar] {
        [
            makeBar(label: primaryQuotaTitle, percent: resolvedSessionRemainingPercent, resetAt: sessionResetsAt),
            makeBar(
                label: secondaryQuotaTitle,
                percent: resolvedWeeklyRemainingPercent,
                resetAt: weeklyResetsAt,
                deficitMarkerPercent: codexWeeklyDeficitMarkerPercent()
            ),
            makeBar(label: "Fable", percent: fableRemainingPercent, resetAt: fableResetsAt),
        ].compactMap { $0 }
    }

    private func makeBar(
        label: String,
        percent: Double?,
        resetAt: Date?,
        deficitMarkerPercent: Double? = nil
    ) -> WidgetQuotaBar? {
        guard percent != nil || resetAt != nil else { return nil }
        let clamped = percent.map { min(max($0, 0), 100) }
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
