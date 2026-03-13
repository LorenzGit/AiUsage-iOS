import Foundation

/// Tracks per-account state for Claude multi-subscription support.
struct ClaudeAccountState: Identifiable {
    let id: String // matches LabeledCredentials.id
    var label: String
    var snapshot: ProviderUsageSnapshot?
    var error: String?
    var isLoading: Bool = false
}

extension AppModel {

    /// Loads Claude accounts from the credential store into published state.
    /// Auto-migrates a single existing Claude credential to the first account slot.
    func loadClaudeAccounts() {
        var stored = credentialsStore.loadClaudeAccounts()

        // Migrate: if there's a single Claude credential but no accounts yet, adopt it
        if stored.isEmpty, let existing = credentialsStore.load(for: .claude) {
            let hasToken = !normalizedToken(existing.accessToken).isEmpty ||
                           !normalizedToken(existing.cookieHeader).isEmpty
            if hasToken {
                let labeled = LabeledCredentials(label: "Claude", credentials: existing)
                stored = [labeled]
                try? credentialsStore.saveClaudeAccounts(stored)
            }
        }

        claudeAccounts = stored.map { account in
            ClaudeAccountState(id: account.id, label: account.label)
        }
    }

    /// Adds a new Claude account with the given label and raw token input.
    func addClaudeAccount(label: String, input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let credentials = try parseCredentialsInput(for: .claude, input: trimmed)
            var stored = credentialsStore.loadClaudeAccounts()
            let labeled = LabeledCredentials(label: label, credentials: credentials)
            stored.append(labeled)
            try credentialsStore.saveClaudeAccounts(stored)

            var state = ClaudeAccountState(id: labeled.id, label: label)
            claudeAccounts.append(state)

            // Also keep the primary Claude credential slot in sync (first account)
            if stored.count == 1 || credentialsStore.load(for: .claude) == nil {
                try credentialsStore.save(credentials, for: .claude)
                let display = displayToken(for: .claude, credentials: credentials)
                tokenDrafts[.claude] = display
                savedTokens[.claude] = display
            }

            await refreshClaudeAccount(id: labeled.id)
        } catch {
            errors[.claude] = error.localizedDescription
        }
    }

    /// Removes a Claude account by ID.
    func removeClaudeAccount(id: String) {
        var stored = credentialsStore.loadClaudeAccounts()
        stored.removeAll { $0.id == id }
        try? credentialsStore.saveClaudeAccounts(stored)
        claudeAccounts.removeAll { $0.id == id }

        // If no accounts left, clear the primary Claude slot too
        if stored.isEmpty {
            try? credentialsStore.delete(for: .claude)
            tokenDrafts[.claude] = ""
            savedTokens[.claude] = ""
            snapshots.removeValue(forKey: .claude)
            errors[.claude] = nil
        } else {
            // Sync primary slot to first remaining account
            if let first = stored.first {
                try? credentialsStore.save(first.credentials, for: .claude)
                let display = displayToken(for: .claude, credentials: first.credentials)
                tokenDrafts[.claude] = display
                savedTokens[.claude] = display
            }
            // Update the primary snapshot to worst-case across remaining accounts
            syncClaudePrimarySnapshot()
        }
        persistWidgetSnapshot()
    }

    /// Refreshes a single Claude account.
    func refreshClaudeAccount(id: String) async {
        guard let index = claudeAccounts.firstIndex(where: { $0.id == id }) else { return }
        let stored = credentialsStore.loadClaudeAccounts()
        guard let account = stored.first(where: { $0.id == id }) else { return }

        claudeAccounts[index].isLoading = true
        defer { claudeAccounts[index].isLoading = false }

        do {
            let client = ClaudeAPIClient()
            let snapshot = try await client.fetchUsage(using: account.credentials)
            // Tag the snapshot with the account label in statusText
            let labeled = ProviderUsageSnapshot(
                provider: .claude,
                usedPercent: snapshot.usedPercent,
                secondaryUsedPercent: snapshot.secondaryUsedPercent,
                tertiaryUsedPercent: snapshot.tertiaryUsedPercent,
                sessionRemainingPercent: snapshot.sessionRemainingPercent,
                weeklyRemainingPercent: snapshot.weeklyRemainingPercent,
                tertiaryRemainingPercent: snapshot.tertiaryRemainingPercent,
                sessionResetsAt: snapshot.sessionResetsAt,
                weeklyResetsAt: snapshot.weeklyResetsAt,
                tertiaryResetsAt: snapshot.tertiaryResetsAt,
                statusText: "\(account.label) · \(snapshot.statusText)",
                updatedAt: snapshot.updatedAt
            )
            claudeAccounts[index].snapshot = labeled
            claudeAccounts[index].error = nil
        } catch {
            claudeAccounts[index].error = error.localizedDescription
        }

        syncClaudePrimarySnapshot()
    }

    /// Refreshes all Claude accounts in parallel.
    func refreshAllClaudeAccounts() async {
        guard !claudeAccounts.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for account in claudeAccounts {
                group.addTask { [weak self] in
                    await self?.refreshClaudeAccount(id: account.id)
                }
            }
        }
    }

    /// Syncs the primary `snapshots[.claude]` to the worst-case account
    /// (lowest primary remaining %). This is what the widget/watch sees.
    func syncClaudePrimarySnapshot() {
        let accountSnapshots = claudeAccounts.compactMap(\.snapshot)
        guard !accountSnapshots.isEmpty else { return }

        // Pick the account with the lowest primary remaining %
        let worst = accountSnapshots.min(by: { a, b in
            (a.resolvedSessionRemainingPercent ?? 100) < (b.resolvedSessionRemainingPercent ?? 100)
        })
        if let worst {
            snapshots[.claude] = worst
        }
    }

    /// Whether Claude has multi-account mode active.
    var hasMultipleClaudeAccounts: Bool {
        claudeAccounts.count > 1
    }

    var hasAnyClaudeAccount: Bool {
        !claudeAccounts.isEmpty
    }
}
