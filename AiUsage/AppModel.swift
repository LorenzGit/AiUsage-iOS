import Foundation
import Combine

#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var useMockData = false
    @Published var debugShowDisconnectedProviderUI = false
    @Published var providerOrder: [ProviderID] = ProviderID.allCases
    @Published var widgetVisibility: [ProviderID: Bool] = [:]
    @Published var tokenDrafts: [ProviderID: String] = [:]
    @Published var savedTokens: [ProviderID: String] = [:]
    @Published var snapshots: [ProviderID: ProviderUsageSnapshot] = [:]
    @Published var errors: [ProviderID: String] = [:]
    @Published var loadingProviders: Set<ProviderID> = []
    @Published var codexLoginState: CodexLoginState?
    @Published var geminiLoginState: GeminiLoginState?

    let credentialsStore = CredentialsStore()
    let codexAuthService = CodexDeviceAuthService()
    let geminiAuthService = GeminiDeviceAuthService()
    let codexTokenRefresher = CodexTokenRefresher()
    let geminiTokenRefresher = GeminiTokenRefresher()
    var codexManualAuthSession: CodexManualAuthSession?
    var geminiManualAuthSession: GeminiManualAuthSession?
    var geminiLastRefreshAt: Date?
    var geminiLastRefreshedAccessToken: String?

    let clients: [ProviderID: any ProviderAPIClient] = {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderAPIClientFactory.client(for: $0)) })
    }()

    private let mockModeDefaultsKey = "aiusage.mock_mode_enabled"
    private let debugDisconnectedUIDefaultsKey = "aiusage.debug_show_disconnected_provider_ui"

    /// Loads persisted credentials and fetches provider usage when mock mode is off.
    func load() async {
        useMockData = UserDefaults.standard.bool(forKey: mockModeDefaultsKey)
        debugShowDisconnectedProviderUI = UserDefaults.standard.bool(forKey: debugDisconnectedUIDefaultsKey)
        providerOrder = ProviderOrderStore.load()
        widgetVisibility = ProviderWidgetVisibilityStore.load()

        for provider in ProviderID.allCases {
            let credentials = credentialsStore.load(for: provider)
            let token = credentials.map { displayToken(for: provider, credentials: $0) } ?? ""
            tokenDrafts[provider] = token
            savedTokens[provider] = token
        }

        if useMockData {
            applyMockSnapshots()
            persistWidgetSnapshot()
            return
        }

        await refreshAll()
    }

    func setDebugShowDisconnectedProviderUI(_ isEnabled: Bool) {
        debugShowDisconnectedProviderUI = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: debugDisconnectedUIDefaultsKey)
    }

    /// Persists the token draft for a provider and refreshes its usage data.
    func saveToken(for provider: ProviderID) async {
        let trimmed = normalizedToken(tokenDrafts[provider])

        if (provider == .codex || provider == .gemini),
           looksLikeAuthorizationCodeNotJSON(trimmed, for: provider)
        {
            let hasPendingSession = provider == .codex ? codexManualAuthSession != nil : geminiManualAuthSession != nil
            if hasPendingSession {
                errors[provider] = "That looks like an auth code/callback URL. Paste it, then press return to exchange."
            } else {
                errors[provider] = "That looks like a callback URL, but the sign-in session has expired. Tap Sign in again."
            }
            return
        }

        do {
            if trimmed.isEmpty {
                try credentialsStore.delete(for: provider)
                snapshots.removeValue(forKey: provider)
                errors[provider] = nil
                savedTokens[provider] = ""
            } else {
                let credentials = try parseCredentialsInput(for: provider, input: trimmed)
                try credentialsStore.save(credentials, for: provider)
                let display = displayToken(for: provider, credentials: credentials)
                tokenDrafts[provider] = display
                savedTokens[provider] = display
                await refresh(provider)
            }
        } catch {
            errors[provider] = error.localizedDescription
        }

        persistWidgetSnapshot()
    }

    /// Refreshes all authenticated providers in parallel.
    func refreshAll() async {
        if useMockData {
            applyMockSnapshots()
            persistWidgetSnapshot()
            return
        }

        let providersToRefresh = providerOrder.filter { hasToken(for: $0) }
        guard !providersToRefresh.isEmpty else {
            snapshots = [:]
            errors = [:]
            persistWidgetSnapshot()
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for provider in providersToRefresh {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.refresh(provider)
                }
            }
        }

        persistWidgetSnapshot()
    }

    /// Refreshes one provider and updates loading/error state.
    func refresh(_ provider: ProviderID) async {
        if useMockData {
            applyMockSnapshots()
            persistWidgetSnapshot()
            return
        }

        guard hasToken(for: provider) else {
            snapshots.removeValue(forKey: provider)
            errors[provider] = nil
            persistWidgetSnapshot()
            return
        }

        loadingProviders.insert(provider)
        defer { loadingProviders.remove(provider) }

        do {
            let credentials = try await resolveCredentials(for: provider)
            let snapshot = try await fetchUsage(for: provider, credentials: credentials)
            snapshots[provider] = snapshot
            errors[provider] = nil
        } catch {
            // Keep stale snapshot data so the dashboard still shows last-known usage
            // rather than going blank. The error message indicates the data is stale.
            errors[provider] = error.localizedDescription
        }
    }

    /// Toggles mock mode and refreshes snapshots accordingly.
    func setMockDataEnabled(_ isEnabled: Bool) async {
        useMockData = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: mockModeDefaultsKey)

        if isEnabled {
            applyMockSnapshots()
            persistWidgetSnapshot()
            return
        }

        snapshots = [:]
        errors = [:]
        await refreshAll()
    }

    /// Refreshes data when app returns to foreground.
    func refreshAllIfNeeded() async {
        guard useMockData || hasAnyToken() else { return }
        await refreshAll()
    }

    // MARK: - Token state queries

    func hasToken(for provider: ProviderID) -> Bool {
        guard let stored = credentialsStore.load(for: provider) else { return false }
        if provider == .codex || provider == .claude {
            return !normalizedToken(stored.accessToken).isEmpty || !normalizedToken(stored.cookieHeader).isEmpty
        }
        if provider == .gemini {
            let hasBearerToken = !normalizedToken(stored.accessToken).isEmpty
            let hasStudioHeaders = !normalizedToken(stored.cookieHeader).isEmpty &&
                !normalizedToken(stored.geminiAuthorizationHeader).isEmpty
            return hasBearerToken || hasStudioHeaders
        }
        return !normalizedToken(stored.accessToken).isEmpty
    }

    func hasAnyToken() -> Bool {
        ProviderID.allCases.contains { hasToken(for: $0) }
    }

    func isTokenModified(for provider: ProviderID) -> Bool {
        normalizedToken(tokenDrafts[provider]) != normalizedToken(savedTokens[provider])
    }

    // MARK: - Provider ordering & widget visibility

    func moveProviders(fromOffsets: IndexSet, toOffset: Int) {
        let sourceIndices = fromOffsets.sorted()
        guard !sourceIndices.isEmpty else { return }

        let movingProviders = sourceIndices.map { providerOrder[$0] }
        for index in sourceIndices.reversed() {
            providerOrder.remove(at: index)
        }

        let adjustedDestination = sourceIndices.reduce(toOffset) { current, index in
            index < toOffset ? current - 1 : current
        }
        let insertionIndex = max(0, min(adjustedDestination, providerOrder.count))
        providerOrder.insert(contentsOf: movingProviders, at: insertionIndex)
        providerOrder = ProviderOrderStore.normalized(providerOrder)
        ProviderOrderStore.save(providerOrder)
        persistWidgetSnapshot()
    }

    func isProviderVisibleInWidget(_ provider: ProviderID) -> Bool {
        widgetVisibility[provider] ?? true
    }

    func setProviderVisibleInWidget(_ provider: ProviderID, isVisible: Bool) {
        widgetVisibility[provider] = isVisible
        ProviderWidgetVisibilityStore.save(widgetVisibility)
        persistWidgetSnapshot()
    }

    // MARK: - Widget persistence

    func persistWidgetSnapshot() {
        let items = providerOrder.compactMap { snapshots[$0] }
        let snapshot = WidgetSnapshot(generatedAt: Date(), isMockData: useMockData, providers: items)
        WidgetSnapshotStore.save(snapshot)
        var refreshCredentials: [ProviderID: WidgetRefreshCredentials] = [:]
        for provider in ProviderID.allCases {
            guard let credentials = credentialsStore.load(for: provider) else { continue }
            refreshCredentials[provider] = WidgetRefreshCredentials(
                accessToken: credentials.accessToken,
                accountID: credentials.accountID,
                cookieHeader: credentials.cookieHeader,
                geminiAuthorizationHeader: credentials.geminiAuthorizationHeader,
                geminiAPIKey: credentials.geminiAPIKey
            )
        }
        WidgetSnapshotStore.saveRefreshCredentials(refreshCredentials)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        WatchSessionManager.shared.sendSnapshot(snapshot)
    }

    // MARK: - Mock data

    private func applyMockSnapshots() {
        let snapshot = MockSnapshotCycle.next()
        snapshots = Dictionary(uniqueKeysWithValues: snapshot.providers.map { provider in
            (provider.provider, provider)
        })
        errors = [:]
    }
}
