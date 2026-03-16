import Foundation

enum PreviewData {
    static let claude = ProviderUsageSnapshot(
        provider: .claude,
        usedPercent: 87,
        secondaryUsedPercent: 63,
        sessionRemainingPercent: 13,
        weeklyRemainingPercent: 37,
        sessionResetsAt: Date().addingTimeInterval(2.5 * 3600),
        weeklyResetsAt: Date().addingTimeInterval(4.2 * 86400),
        statusText: "Pro plan · 2 h 30 min left",
        updatedAt: Date().addingTimeInterval(-180)
    )

    static let snapshot = WidgetSnapshot(
        generatedAt: Date().addingTimeInterval(-180),
        providers: [claude]
    )
}
