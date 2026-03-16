import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var watchSession = WatchSessionManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var tokenVisible: [ProviderID: Bool] = [:]
    @FocusState private var focusedTokenProvider: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    if ProcessInfo.processInfo.isDebugUIEnabled {
                        Toggle("Use Mock Data (debug)", isOn: Binding(
                            get: { model.useMockData },
                            set: { value in
                                Task { await model.setMockDataEnabled(value) }
                            }
                        ))

                        Toggle("Show providers as disconnected (debug)", isOn: Binding(
                            get: { model.debugShowDisconnectedProviderUI },
                            set: { value in
                                model.setDebugShowDisconnectedProviderUI(value)
                            }
                        ))
                    }

                    Button("Refresh All Providers") {
                        Task { await model.refreshAll() }
                    }
                }

                Section("Apple Watch") {
                    let status = watchSession.watchStatus
                    Label(status.label, systemImage: status.systemImage)
                        .foregroundStyle(status == .connected ? .green : .primary)
                    if let hint = status.hint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Provider Order") {
                    Text("Drag using the right handle to reorder. This controls dashboard order and medium/large widget order.")
                        .font(.footnote)
                    ForEach(model.providerOrder) { provider in
                        HStack(spacing: 10) {
                            DragDotsHandle()
                            ProviderIconImage(provider: provider, size: 15, tint: .primary)
                            Text(provider.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("Widget")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Toggle(
                                "Show in Widget",
                                isOn: Binding(
                                    get: { model.isProviderVisibleInWidget(provider) },
                                    set: { model.setProviderVisibleInWidget(provider, isVisible: $0) }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                    .onMove(perform: moveProviders)
                }
                .environment(\.editMode, .constant(.active))

                ForEach(model.providerOrder) { provider in
                    providerSection(provider)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func providerSection(_ provider: ProviderID) -> some View {
        let isAuthenticated = model.hasToken(for: provider)
        let showDisconnectedUI = model.debugShowDisconnectedProviderUI
        let isAuthenticatedForUI = isAuthenticated && !showDisconnectedUI

        return Section {
            HStack(spacing: 10) {
                Image(systemName: isAuthenticatedForUI ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(isAuthenticatedForUI ? .green : .secondary)
                Text(isAuthenticatedForUI ? "Authenticated" : "Disconnected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.refresh(provider) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!isAuthenticatedForUI)

                Spacer()

                if let usageURL = provider.usageDashboardURL {
                    Button {
                        openURL(usageURL)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Claude uses the subscription flow instead of the generic token field
            if !isAuthenticatedForUI, provider != .claude {
                HStack(spacing: 8) {
                    tokenField(for: provider)
                    if provider != .codex && provider != .gemini {
                        Button {
                            tokenVisible[provider] = !(tokenVisible[provider] ?? false)
                        } label: {
                            Image(systemName: (tokenVisible[provider] ?? false) ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let helpURL = provider.tokenHelpURL, shouldShowGetTokenButton(for: provider) {
                    Button("Get token") {
                        openURL(helpURL)
                    }
                    .font(.footnote)
                }
            }

            if provider == .codex || provider == .gemini {
                Button(isAuthenticatedForUI ? "Disconnect" : "Sign in", role: isAuthenticatedForUI ? .destructive : nil) {
                    Task {
                        await performPrimaryAction(for: provider, isAuthenticated: isAuthenticatedForUI)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !isAuthenticatedForUI &&
                    ((provider == .codex && model.codexLoginState?.isWorking == true) ||
                    (provider == .gemini && model.geminiLoginState?.isWorking == true))
                )
            } else if isAuthenticatedForUI {
                if provider != .claude {
                    Button("Disconnect", role: .destructive) {
                        Task {
                            await performPrimaryAction(for: provider, isAuthenticated: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if provider != .claude {
                Button("Save token") {
                    Task { await submitProviderInput(for: provider) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.tokenDrafts[provider, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !isAuthenticatedForUI, provider != .claude {
                Text(signInInstructions(for: provider))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if provider == .codex,
               let status = model.codexLoginState?.message,
               !status.isEmpty
            {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if provider == .gemini,
               let status = model.geminiLoginState?.message,
               !status.isEmpty
            {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if provider == .codex,
               let verificationURI = model.codexLoginState?.verificationURI,
               let url = URL(string: verificationURI),
               !isAuthenticatedForUI
            {
                Link("Open login link again", destination: url)
                    .font(.footnote)
            }

            if provider == .gemini,
               let verificationURI = model.geminiLoginState?.verificationURI,
               let url = URL(string: verificationURI),
               !isAuthenticatedForUI
            {
                Link("Open login link again", destination: url)
                    .font(.footnote)
            }

            if let error = model.errors[provider], !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            // Claude multi-account management
            if provider == .claude {
                claudeAccountsSection
            }
        } header: {
            providerHeader(provider)
        }
    }

    @State private var newClaudeAccountLabel = ""
    @State private var newClaudeAccountToken = ""
    @State private var showAddClaudeAccount = false

    @ViewBuilder
    private var claudeAccountsSection: some View {
        if !model.claudeAccounts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Subscriptions")
                    .font(.footnote.weight(.semibold))
                ForEach(model.claudeAccounts) { account in
                    HStack {
                        Image(systemName: "person.circle")
                            .foregroundStyle(.secondary)
                        Text(account.label)
                            .font(.subheadline)
                        Spacer()
                        if account.snapshot != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        Button(role: .destructive) {
                            model.removeClaudeAccount(id: account.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        if !model.claudeAccounts.isEmpty {
            Button {
                showAddClaudeAccount.toggle()
            } label: {
                Label("Add subscription", systemImage: "plus.circle")
                    .font(.subheadline)
            }
        }

        if showAddClaudeAccount || model.claudeAccounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Label (e.g. Personal, Company)", text: $newClaudeAccountLabel)
                    .textFieldStyle(.roundedBorder)
                SecureField("Claude token or sessionKey cookie", text: $newClaudeAccountToken)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button(model.claudeAccounts.isEmpty ? "Save" : "Add") {
                    let label = newClaudeAccountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    let token = newClaudeAccountToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty, !token.isEmpty else { return }
                    Task {
                        await model.addClaudeAccount(label: label, input: token)
                        newClaudeAccountLabel = ""
                        newClaudeAccountToken = ""
                        showAddClaudeAccount = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    newClaudeAccountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    newClaudeAccountToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Text("Go to claude.ai/settings → Developer Console → Application → Cookies → Copy sessionKey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func providerHeader(_ provider: ProviderID) -> some View {
        HStack(spacing: 6) {
            ProviderIconImage(provider: provider, size: 16, tint: .primary)
            Text(provider.displayName)
        }
    }

    private func shouldShowGetTokenButton(for provider: ProviderID) -> Bool {
        switch provider {
        case .gemini, .copilot, .kimi:
            return false
        case .codex, .claude:
            return true
        }
    }

    private func moveProviders(from source: IndexSet, to destination: Int) {
        model.moveProviders(fromOffsets: source, toOffset: destination)
    }

    @ViewBuilder
    private func tokenField(for provider: ProviderID) -> some View {
        let binding = Binding(
            get: { model.tokenDrafts[provider, default: ""] },
            set: { model.tokenDrafts[provider] = $0 }
        )
        let placeholder = tokenPlaceholder(for: provider)
        let alwaysVisibleInput = provider == .codex || provider == .gemini

        if alwaysVisibleInput || (tokenVisible[provider] ?? false) {
            TextField(placeholder, text: binding)
                .focused($focusedTokenProvider, equals: provider.rawValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.none)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, minHeight: 44)
                .onSubmit {
                    Task { await submitProviderInput(for: provider) }
                }
        } else {
            SecureField(placeholder, text: binding)
                .focused($focusedTokenProvider, equals: provider.rawValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.none)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, minHeight: 44)
                .onSubmit {
                    Task { await submitProviderInput(for: provider) }
                }
        }
    }

    private func performPrimaryAction(for provider: ProviderID, isAuthenticated: Bool) async {
        if isAuthenticated {
            if provider == .codex {
                await model.disconnectCodex()
            } else if provider == .gemini {
                await model.disconnectGemini()
            } else {
                model.tokenDrafts[provider] = ""
                await model.saveToken(for: provider)
            }
            return
        }

        if provider == .codex {
            let draft = model.tokenDrafts[provider, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if model.hasPendingCodexAuthURL(), !draft.isEmpty {
                await model.exchangeCodexAuthorizationCodeFromDraft()
                return
            }
            await model.prepareCodexLoginLink()
            if let verificationURI = model.codexLoginState?.verificationURI,
               let url = URL(string: verificationURI)
            {
                openURL(url)
            }
            return
        }
        if provider == .gemini {
            let draft = model.tokenDrafts[provider, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if model.hasPendingGeminiAuthURL(), !draft.isEmpty {
                await model.exchangeGeminiAuthorizationCodeFromDraft()
                return
            }
            await model.prepareGeminiLoginLink()
            if let verificationURI = model.geminiLoginState?.verificationURI,
               let url = URL(string: verificationURI)
            {
                openURL(url)
            }
            return
        }

        let draft = model.tokenDrafts[provider, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            model.errors[provider] = emptyTokenMessage(for: provider)
            return
        }

        await model.saveToken(for: provider)
    }

    private func submitProviderInput(for provider: ProviderID) async {
        if provider == .codex, model.hasPendingCodexAuthURL() {
            await model.exchangeCodexAuthorizationCodeFromDraft()
            return
        }
        if provider == .gemini, model.hasPendingGeminiAuthURL() {
            await model.exchangeGeminiAuthorizationCodeFromDraft()
            return
        }
        let draft = model.tokenDrafts[provider, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if provider != .codex && provider != .gemini, draft.isEmpty {
            model.errors[provider] = emptyTokenMessage(for: provider)
            return
        }
        await model.saveToken(for: provider)
    }

    private func tokenPlaceholder(for provider: ProviderID) -> String {
        switch provider {
        case .codex:
            return "Paste callback URL here (contains code=...)"
        case .claude:
            return "Claude token (sk-ant-oat... or sessionKey=...)"
        case .gemini:
            return "Paste callback url here..."
        case .copilot:
            return "GitHub token (ghu_... / github_pat_...)"
        case .kimi:
            return "Kimi token or kimi-auth cookie"
        }
    }

    private func emptyTokenMessage(for provider: ProviderID) -> String {
        switch provider {
        case .codex:
            return "Paste your callback URL first, then tap Sign in."
        case .claude:
            return "Paste a Claude token (`sk-ant...`) or `sessionKey` cookie first, then press return."
        case .gemini:
            return "Paste your callback URL first, then tap Sign in."
        case .copilot:
            return "Paste a GitHub token first, then press return."
        case .kimi:
            return "Paste your Kimi token or `kimi-auth` cookie first, then press return."
        }
    }

    private func signInInstructions(for provider: ProviderID) -> String {
        if provider == .codex {
            return "- Tap Sign in.\n- Complete browser login.\n- Copy callback URL.\n- Paste callback URL above and press return."
        }
        if provider == .claude {
            return "- Go to https://claude.ai/settings/usage on your computer.\n- Open Developer Console > Application > Cookies.\n- Look for http://claude.ai sessionKey.\n- Copy/Paste the sk-ant token here."
        }
        if provider == .gemini {
            return "- Tap Sign in.\n- Complete browser login.\n- Copy callback URL.\n- Paste callback URL above and press return."
        }
        if provider == .copilot {
            return "- On your computer Terminal run: `gh auth token`.\n- Paste that token here.\n- (If you don't have gh, install it with `brew install gh` and run `gh auth login`.)"
        }
        if provider == .kimi {
            return "- Go to https://www.kimi.com/code/console.\n- Open Developer Console > Application > Cookies.\n- Copy `kimi-auth`.\n- Paste token above and press enter."
        }
        return "- Paste your token above."
    }
}

private struct DragDotsHandle: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2) {
                    Circle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 3, height: 3)
                    Circle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 3, height: 3)
                }
            }
        }
        .frame(width: 10, height: 16)
        .padding(.trailing, 2)
    }
}

extension ProcessInfo {
    var isDebugUIEnabled: Bool {
        guard let rawValue = environment["DEBUG_UI"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else {
            return false
        }
        return rawValue == "true" || rawValue == "1" || rawValue == "yes" || rawValue == "on"
    }
}
