import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var palette: DashboardPalette {
        DashboardPalette.forColorScheme(colorScheme)
    }

    private var visibleProviders: [ProviderID] {
        if model.useMockData {
            return model.providerOrder
        }
        return model.providerOrder.filter { model.hasToken(for: $0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    dashboardHeader

                    if visibleProviders.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleProviders) { provider in
                            if provider == .claude, model.hasMultipleClaudeAccounts {
                                ClaudeMultiAccountCard(
                                    accounts: model.claudeAccounts,
                                    palette: palette,
                                    onRefresh: { id in
                                        Task { await model.refreshClaudeAccount(id: id) }
                                    },
                                    onRefreshAll: {
                                        Task { await model.refreshAllClaudeAccounts() }
                                    }
                                )
                            } else {
                                ProviderDashboardCard(
                                    provider: provider,
                                    snapshot: model.snapshots[provider],
                                    error: model.errors[provider],
                                    isLoading: model.loadingProviders.contains(provider),
                                    palette: palette,
                                    onRefresh: {
                                        if provider == .claude, model.hasAnyClaudeAccount {
                                            Task { await model.refreshAllClaudeAccounts() }
                                        } else {
                                            Task { await model.refresh(provider) }
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .background(dashboardBackground.ignoresSafeArea())
            .navigationTitle("AiUsage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(model: model)
            }
        }
        .task {
            await model.load()
            WatchSessionManager.shared.onRefreshRequest = { [weak model] in
                guard let model else {
                    return WidgetSnapshot(generatedAt: Date(), isMockData: false, providers: [])
                }
                await model.refreshAll()
                let items = model.providerOrder.compactMap { model.snapshots[$0] }
                return WidgetSnapshot(generatedAt: Date(), isMockData: model.useMockData, providers: items)
            }
        }
        .task(id: model.useMockData) {
            await runPollingLoop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await model.refreshAllIfNeeded() }
        }
    }

    /// Polls in foreground to keep dashboard numbers reasonably fresh.
    private func runPollingLoop() async {
        while !Task.isCancelled {
            let intervalSeconds: UInt64 = model.useMockData ? 2 : 60
            do {
                try await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            } catch {
                return
            }
            guard scenePhase == .active else { continue }
            await model.refreshAllIfNeeded()
        }
    }

    private var dashboardHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage Dashboard")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(palette.titleText)
                if model.useMockData {
                    Text("Mock data enabled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange.opacity(0.95))
                } else {
                    Text("Live provider data")
                        .font(.caption)
                        .foregroundStyle(palette.subtitleText)
                }
            }

            Spacer()

            Button {
                Task { await model.refreshAll() }
            } label: {
                HStack(spacing: 6) {
                    if !model.loadingProviders.isEmpty {
                        ProgressView()
                            .tint(palette.buttonText)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .foregroundStyle(palette.buttonText)
            .background(palette.buttonFill, in: Capsule())
        }
        .padding(14)
        .background(palette.sectionBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No providers configured")
                .font(.headline)
                .foregroundStyle(palette.titleText)
            Text("Open Settings and connect at least one provider to populate the dashboard.")
                .font(.subheadline)
                .foregroundStyle(palette.subtitleText)
            Button("Open Settings") {
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.buttonFill)
            .foregroundStyle(palette.buttonText)
        }
        .padding(14)
        .background(palette.sectionBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var dashboardBackground: some View {
        LinearGradient(
            colors: palette.backgroundGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct DashboardPalette {
    let backgroundGradient: [Color]
    let sectionBackground: Color
    let buttonFill: Color
    let buttonText: Color
    let titleText: Color
    let subtitleText: Color
    let cardGradient: [Color]
    let cardBorder: Color
    let cardIconTint: Color
    let cardTitleText: Color
    let cardBodyText: Color
    let cardSecondaryText: Color
    let meterTrack: Color

    static func forColorScheme(_ colorScheme: ColorScheme) -> DashboardPalette {
        switch colorScheme {
        case .light:
            return DashboardPalette(
                backgroundGradient: [
                    Color(red: 0.96, green: 0.98, blue: 1.0),
                    Color(red: 0.91, green: 0.95, blue: 1.0),
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                ],
                sectionBackground: .black.opacity(0.05),
                buttonFill: Color(red: 0.20, green: 0.33, blue: 0.60).opacity(0.18),
                buttonText: Color(red: 0.12, green: 0.17, blue: 0.27),
                titleText: Color(red: 0.11, green: 0.15, blue: 0.24),
                subtitleText: Color(red: 0.30, green: 0.35, blue: 0.45),
                cardGradient: [
                    .black.opacity(0.06),
                    .black.opacity(0.04),
                ],
                cardBorder: .black.opacity(0.11),
                cardIconTint: Color(red: 0.22, green: 0.29, blue: 0.43),
                cardTitleText: Color(red: 0.13, green: 0.18, blue: 0.28),
                cardBodyText: Color(red: 0.15, green: 0.20, blue: 0.30),
                cardSecondaryText: Color(red: 0.35, green: 0.40, blue: 0.50),
                meterTrack: .black.opacity(0.14)
            )
        default:
            return DashboardPalette(
                backgroundGradient: [
                    Color(red: 0.04, green: 0.05, blue: 0.11),
                    Color(red: 0.08, green: 0.09, blue: 0.20),
                    Color(red: 0.06, green: 0.07, blue: 0.16),
                ],
                sectionBackground: .white.opacity(0.08),
                buttonFill: .white.opacity(0.16),
                buttonText: .white,
                titleText: .white,
                subtitleText: .white.opacity(0.7),
                cardGradient: [
                    .white.opacity(0.11),
                    .white.opacity(0.07),
                ],
                cardBorder: .white.opacity(0.12),
                cardIconTint: .white.opacity(0.92),
                cardTitleText: .white,
                cardBodyText: .white.opacity(0.96),
                cardSecondaryText: .white.opacity(0.68),
                meterTrack: .white.opacity(0.14)
            )
        }
    }
}

private struct ProviderDashboardCard: View {
    let provider: ProviderID
    let snapshot: ProviderUsageSnapshot?
    let error: String?
    let isLoading: Bool
    let palette: DashboardPalette
    let onRefresh: () -> Void

    private struct QuotaRowModel: Identifiable {
        let id: String
        let title: String
        let remainingPercent: Double
        let resetAt: Date?
        let runsOutAt: Date?
        let deficitPercent: Double?
        let deficitMarkerPercent: Double?
    }

    private var quotaRows: [QuotaRowModel] {
        guard let snapshot else { return [] }

        var rows: [QuotaRowModel] = []

        if let session = snapshot.resolvedSessionRemainingPercent {
            rows.append(
                QuotaRowModel(
                    id: "session",
                    title: provider.primaryBarTitle,
                    remainingPercent: session,
                    resetAt: snapshot.sessionResetsAt,
                    runsOutAt: snapshot.sessionRunsOutAt,
                    deficitPercent: nil,
                    deficitMarkerPercent: nil
                )
            )
        }

        if let weekly = snapshot.resolvedWeeklyRemainingPercent {
            let pace = snapshot.codexWeeklyPaceEstimate()
            rows.append(
                QuotaRowModel(
                    id: "weekly",
                    title: provider.secondaryBarTitle,
                    remainingPercent: weekly,
                    resetAt: snapshot.weeklyResetsAt,
                    runsOutAt: snapshot.weeklyRunsOutAt ?? pace?.runsOutAt,
                    deficitPercent: pace?.deficitPercent,
                    deficitMarkerPercent: pace?.expectedRemainingPercent
                )
            )
        }

        if let tertiary = snapshot.resolvedTertiaryRemainingPercent {
            rows.append(
                QuotaRowModel(
                    id: "tertiary",
                    title: provider.tertiaryBarTitle,
                    remainingPercent: tertiary,
                    resetAt: snapshot.tertiaryResetsAt,
                    runsOutAt: snapshot.tertiaryRunsOutAt,
                    deficitPercent: nil,
                    deficitMarkerPercent: nil
                )
            )
        }

        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderIconImage(provider: provider, size: 15, tint: palette.cardIconTint)
                Text(provider.displayName)
                    .font(.headline)
                    .foregroundStyle(palette.cardTitleText)
                Spacer()
                Button(action: onRefresh) {
                    Group {
                        if isLoading {
                            ProgressView()
                                .tint(palette.cardBodyText)
                        } else {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.cardBodyText)
            }

            if let snapshot {
                ForEach(self.quotaRows) { row in
                    QuotaSectionRow(
                        title: row.title,
                        remainingPercent: row.remainingPercent,
                        resetAt: row.resetAt,
                        runsOutAt: row.runsOutAt,
                        barColors: provider.barColors,
                        deficitPercent: row.deficitPercent,
                        deficitMarkerPercent: row.deficitMarkerPercent,
                        palette: palette
                    )
                }

                if error != nil {
                    Text("Stale · \(snapshot.statusText)")
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.85))
                } else {
                    Text(snapshot.statusText)
                        .font(.caption)
                        .foregroundStyle(palette.cardSecondaryText)
                }
            } else {
                Text("No data yet. Configure this provider in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(palette.cardSecondaryText)
            }

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.92))
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: palette.cardGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
    }
}

private struct QuotaSectionRow: View {
    let title: String
    let remainingPercent: Double
    let resetAt: Date?
    let runsOutAt: Date?
    let barColors: [Color]
    let deficitPercent: Double?
    let deficitMarkerPercent: Double?
    let palette: DashboardPalette

    private var clampedRemaining: Double { min(max(remainingPercent, 0), 100) }
    private var displayDeficitPercent: Double { max(0, deficitPercent ?? max(0, -remainingPercent)) }
    private var clampedDeficitMarkerPercent: Double? {
        guard let deficitMarkerPercent else { return nil }
        return min(max(deficitMarkerPercent, 0), 100)
    }
    private var deficitMarkerIsVisible: Bool {
        guard let marker = clampedDeficitMarkerPercent else { return false }
        return marker > clampedRemaining + 0.1
    }
    private var deficitMarkerXPercent: Double {
        clampedDeficitMarkerPercent ?? clampedRemaining
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.cardBodyText)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.meterTrack)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: barColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * (clampedRemaining / 100))
                    if deficitMarkerIsVisible {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Color.red.opacity(0.92))
                            .frame(width: 2, height: 11)
                            .offset(x: max(0, min(proxy.size.width - 2, (proxy.size.width * (deficitMarkerXPercent / 100)) - 1)))
                    }
                }
            }
            .frame(height: 11)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(clampedRemaining.rounded()))% left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.cardBodyText)
                    if displayDeficitPercent > 0 {
                        Text("\(Int(displayDeficitPercent.rounded()))% in deficit")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if let resetAt {
                        Text("Resets \(RelativeDateText.abbreviated(from: resetAt))")
                    }
                    if let runsOutAt {
                        Text("Runs out \(RelativeDateText.abbreviated(from: runsOutAt))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(palette.cardSecondaryText)
            }
        }
    }
}

// MARK: - Claude multi-account card

private struct ClaudeMultiAccountCard: View {
    let accounts: [ClaudeAccountState]
    let palette: DashboardPalette
    let onRefresh: (String) -> Void
    let onRefreshAll: () -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                ProviderIconImage(provider: .claude, size: 15, tint: palette.cardIconTint)
                Text("Claude")
                    .font(.headline)
                    .foregroundStyle(palette.cardTitleText)
                Text("(\(accounts.count) accounts)")
                    .font(.caption)
                    .foregroundStyle(palette.cardSecondaryText)
                Spacer()
                Button(action: onRefreshAll) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.cardBodyText)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.cardSecondaryText)
            }

            if isExpanded {
                ForEach(accounts) { account in
                    claudeAccountRow(account)
                    if account.id != accounts.last?.id {
                        Divider().overlay(palette.cardBorder)
                    }
                }
            } else {
                // Collapsed: show worst-case summary
                if let worst = worstAccount {
                    HStack {
                        Text(worst.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(palette.cardBodyText)
                        Spacer()
                        if let snap = worst.snapshot,
                           let pct = snap.resolvedSessionRemainingPercent {
                            Text("\(ProviderID.claude.primaryBarTitle) \(Int(pct))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.cardBodyText)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: palette.cardGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func claudeAccountRow(_ account: ClaudeAccountState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.cardBodyText)
                Spacer()
                if account.isLoading {
                    ProgressView()
                        .tint(palette.cardBodyText)
                } else {
                    Button { onRefresh(account.id) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.cardSecondaryText)
                }
            }

            if let snapshot = account.snapshot {
                quotaRow(title: ProviderID.claude.primaryBarTitle, percent: snapshot.resolvedSessionRemainingPercent, resetAt: snapshot.sessionResetsAt)
                quotaRow(title: ProviderID.claude.secondaryBarTitle, percent: snapshot.resolvedWeeklyRemainingPercent, resetAt: snapshot.weeklyResetsAt)
                if let tertiary = snapshot.resolvedTertiaryRemainingPercent {
                    quotaRow(title: ProviderID.claude.tertiaryBarTitle, percent: tertiary, resetAt: snapshot.tertiaryResetsAt)
                }
                Text(snapshot.statusText)
                    .font(.caption2)
                    .foregroundStyle(palette.cardSecondaryText)
            } else if account.error == nil {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(palette.cardSecondaryText)
            }

            if let error = account.error, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.92))
            }
        }
    }

    @ViewBuilder
    private func quotaRow(title: String, percent: Double?, resetAt: Date?) -> some View {
        if let percent {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(palette.cardSecondaryText)
                    .frame(width: 30, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.meterTrack)
                        Capsule()
                            .fill(LinearGradient(
                                colors: ProviderID.claude.barColors,
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: proxy.size.width * min(max(percent, 0), 100) / 100)
                    }
                }
                .frame(height: 8)
                Text("\(Int(percent.rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.cardBodyText)
                    .frame(width: 32, alignment: .trailing)
                if let resetAt {
                    Text(RelativeDateText.abbreviated(from: resetAt))
                        .font(.caption2)
                        .foregroundStyle(palette.cardSecondaryText)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
    }

    private var worstAccount: ClaudeAccountState? {
        accounts.min(by: { a, b in
            (a.snapshot?.resolvedSessionRemainingPercent ?? 100) <
            (b.snapshot?.resolvedSessionRemainingPercent ?? 100)
        })
    }
}

