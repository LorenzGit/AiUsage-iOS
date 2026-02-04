import Foundation

@MainActor
final class CredentialsStore {
    private let service = "aiusage.gamojo.com.credentials"

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
}
