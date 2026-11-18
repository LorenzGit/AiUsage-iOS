import Foundation
import SafariServices
import WidgetKit

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let results = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": results.map(handle) ?? false]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func handle(_ message: [String: Any]) -> Bool {
        switch message["type"] as? String {
        case "check", "save":
            guard let rawID = message["requestID"] as? String, let id = UUID(uuidString: rawID) else { return false }
            if message["type"] as? String == "check" { return GeminiSyncRequest.isPending(id) }
            guard let results = message["usage"] as? [String: Any],
                  let usage = GeminiWebUsage(results: results),
                  GeminiSyncRequest.consume(id) else { return false }
            return save(usage)
        default:
            guard let usage = GeminiWebUsage(results: message) else { return false }
            return save(usage)
        }
    }

    private func save(_ usage: GeminiWebUsage) -> Bool {
        do {
            try GeminiWebUsageStore.save(usage)
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            return false
        }
    }
}
