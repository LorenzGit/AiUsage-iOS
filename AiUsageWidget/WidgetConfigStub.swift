import Foundation

// Widget extension does not need auth bootstrap config; token refresh paths fall back.
struct Config: Codable {
    let gc: String
    let gcs: String
    let cx: String
}

func getConfig() -> Config? {
    nil
}

func parseChatGPTAccountID(fromIDToken idToken: String?) -> String? {
    guard let idToken else { return nil }
    let parts = idToken.split(separator: ".")
    guard parts.count >= 2 else { return nil }

    var payload = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder > 0 {
        payload += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accountID = json["chatgpt_account_id"] as? String,
          !accountID.isEmpty
    else {
        return nil
    }

    return accountID
}
