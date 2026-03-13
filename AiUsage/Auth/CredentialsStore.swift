import Foundation

@MainActor
final class CredentialsStore {
    private let service = "aiusage.gamojo.com.credentials"
    private let claudeAccountsService = "aiusage.gamojo.com.claude_accounts"

    func load(for provider: ProviderID) -> ProviderCredentials? {
        do {
            guard let data = try KeychainStore.load(service: service, account: provider.rawValue) else {
                return nil
            }
            return try JSONDecoder().decode(ProviderCredentials.self, from: data)
        } catch {
            return nil
        }
    }

    func save(_ credentials: ProviderCredentials, for provider: ProviderID) throws {
        let data = try JSONEncoder().encode(credentials)
        try KeychainStore.save(data: data, service: service, account: provider.rawValue)
    }

    func delete(for provider: ProviderID) throws {
        try KeychainStore.delete(service: service, account: provider.rawValue)
    }

    // MARK: - Claude multi-account

    func loadClaudeAccounts() -> [LabeledCredentials] {
        do {
            guard let data = try KeychainStore.load(service: claudeAccountsService, account: "accounts") else {
                return []
            }
            return try JSONDecoder().decode([LabeledCredentials].self, from: data)
        } catch {
            return []
        }
    }

    func saveClaudeAccounts(_ accounts: [LabeledCredentials]) throws {
        let data = try JSONEncoder().encode(accounts)
        try KeychainStore.save(data: data, service: claudeAccountsService, account: "accounts")
    }
}

struct LabeledCredentials: Codable, Identifiable, Sendable {
    let id: String // stable UUID
    var label: String
    var credentials: ProviderCredentials

    init(label: String, credentials: ProviderCredentials) {
        self.id = UUID().uuidString
        self.label = label
        self.credentials = credentials
    }
}
