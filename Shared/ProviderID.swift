import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case grok
    case gemini
    case copilot
    case kimi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "OpenAI Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .gemini: return "Google Gemini"
        case .copilot: return "GitHub Copilot"
        case .kimi: return "Kimi"
        }
    }

    public var symbolName: String {
        switch self {
        case .codex:
            return "sparkles.rectangle.stack"
        case .claude:
            return "bubble.left.and.bubble.right"
        case .grok:
            return "circle.lefthalf.filled"
        case .gemini:
            return "diamond"
        case .copilot:
            return "sailboat"
        case .kimi:
            return "bolt.horizontal"
        }
    }

    public var brandIconResourceName: String? {
        switch self {
        case .codex: return "ProviderIcon-codex"
        case .claude: return "ProviderIcon-claude"
        case .grok: return nil
        case .gemini: return "ProviderIcon-gemini"
        case .copilot: return "ProviderIcon-copilot"
        case .kimi: return "ProviderIcon-kimi"
        }
    }

    public var tokenHelpURL: URL? {
        switch self {
        case .codex:
            return nil
        case .claude:
            return nil
        case .grok:
            return nil
        case .gemini:
            return URL(string: "https://aistudio.google.com/app/apikey")
        case .copilot:
            return URL(string: "https://github.com/settings/copilot")
        case .kimi:
            return URL(string: "https://www.kimi.com/")
        }
    }

    public var usageDashboardURL: URL? {
        switch self {
        case .codex:
            return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .claude:
            return URL(string: "https://claude.ai/settings/usage")
        case .grok:
            return URL(string: "https://grok.com/dashboard/usage")
        case .gemini:
            return URL(string: "https://gemini.google.com/usage")
        case .copilot:
            return URL(string: "https://github.com/settings/copilot/features")
        case .kimi:
            return URL(string: "https://www.kimi.com/code/console")
        }
    }

    public var primaryBarTitle: String {
        switch self {
        case .codex: return "Session"
        case .claude: return "5h"
        case .grok: return "Session"
        case .gemini: return "Pro"
        case .copilot: return "Premium"
        case .kimi: return "Session"
        }
    }

    public var secondaryBarTitle: String {
        switch self {
        case .codex: return "Weekly"
        case .claude: return "7d"
        case .grok: return "Weekly"
        case .gemini: return "Flash"
        case .copilot: return "Chat"
        case .kimi: return "Weekly"
        }
    }

    public var tertiaryBarTitle: String {
        switch self {
        case .codex: return "Code Review"
        case .claude, .grok, .gemini, .copilot, .kimi: return "Extra"
        }
    }
}

#if canImport(SwiftUI)
public extension ProviderID {
    var barColors: [Color] {
        switch self {
        case .codex:
            return [
                Color(red: 97.0 / 255.0, green: 161.0 / 255.0, blue: 174.0 / 255.0),
                Color(red: 97.0 / 255.0, green: 161.0 / 255.0, blue: 174.0 / 255.0),
            ]
        case .claude:
            return [
                Color(red: 193.0 / 255.0, green: 128.0 / 255.0, blue: 100.0 / 255.0),
                Color(red: 193.0 / 255.0, green: 128.0 / 255.0, blue: 100.0 / 255.0),
            ]
        case .grok:
            return [Color(red: 0.48, green: 0.57, blue: 0.65), Color(red: 0.62, green: 0.69, blue: 0.76)]
        case .gemini:
            return [
                Color(red: 159.0 / 255.0, green: 124.0 / 255.0, blue: 226.0 / 255.0),
                Color(red: 159.0 / 255.0, green: 124.0 / 255.0, blue: 226.0 / 255.0),
            ]
        case .copilot:
            return [
                Color(red: 155.0 / 255.0, green: 75.0 / 255.0, blue: 239.0 / 255.0),
                Color(red: 155.0 / 255.0, green: 75.0 / 255.0, blue: 239.0 / 255.0),
            ]
        case .kimi:
            return [
                Color(red: 255.0 / 255.0, green: 79.0 / 255.0, blue: 57.0 / 255.0),
                Color(red: 255.0 / 255.0, green: 79.0 / 255.0, blue: 57.0 / 255.0),
            ]
        }
    }
}

public struct ProviderIconImage: View {
    public let provider: ProviderID
    public let size: CGFloat
    public let tint: Color

    public init(provider: ProviderID, size: CGFloat, tint: Color) {
        self.provider = provider
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        if let resourceName = provider.brandIconResourceName {
            Image(resourceName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.symbolName)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }
}
#endif
