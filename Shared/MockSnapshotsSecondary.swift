import Foundation

extension MockSnapshotCycle {
    static func secondary(now: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now,
            isMockData: true,
            providers: [
                ProviderUsageSnapshot(
                    provider: .codex,
                    usedPercent: 22,
                    secondaryUsedPercent: 61,
                    tertiaryUsedPercent: 44,
                    sessionRemainingPercent: 78,
                    weeklyRemainingPercent: 20,
                    tertiaryRemainingPercent: 56,
                    sessionResetsAt: now.addingTimeInterval(2 * 60 * 60 + 45 * 60),
                    weeklyResetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                    tertiaryResetsAt: now.addingTimeInterval(36 * 60 * 60),
                    sessionRunsOutAt: now.addingTimeInterval(10 * 60 * 60),
                    statusText: "Mock B",
                    updatedAt: now
                ),
                ProviderUsageSnapshot(
                    provider: .claude,
                    usedPercent: 51,
                    secondaryUsedPercent: 72,
                    sessionRemainingPercent: 49,
                    weeklyRemainingPercent: 28,
                    sessionResetsAt: now.addingTimeInterval(90 * 60),
                    weeklyResetsAt: now.addingTimeInterval(1 * 24 * 60 * 60 + 18 * 60 * 60),
                    statusText: "Mock B",
                    updatedAt: now
                ),
                ProviderUsageSnapshot(
                    provider: .gemini,
                    usedPercent: 41,
                    secondaryUsedPercent: 49,
                    sessionRemainingPercent: 59,
                    weeklyRemainingPercent: 51,
                    sessionResetsAt: now.addingTimeInterval(3 * 60 * 60),
                    weeklyResetsAt: now.addingTimeInterval(4 * 24 * 60 * 60 + 4 * 60 * 60),
                    statusText: "Mock B",
                    updatedAt: now
                ),
                ProviderUsageSnapshot(
                    provider: .copilot,
                    usedPercent: 34,
                    secondaryUsedPercent: 52,
                    sessionRemainingPercent: 66,
                    weeklyRemainingPercent: 48,
                    sessionResetsAt: now.addingTimeInterval(5 * 60 * 60),
                    weeklyResetsAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 16 * 60 * 60),
                    statusText: "Mock B",
                    updatedAt: now
                ),
                ProviderUsageSnapshot(
                    provider: .kimi,
                    usedPercent: 67,
                    secondaryUsedPercent: 81,
                    sessionRemainingPercent: 33,
                    weeklyRemainingPercent: 19,
                    sessionResetsAt: now.addingTimeInterval(45 * 60),
                    weeklyResetsAt: now.addingTimeInterval(2 * 24 * 60 * 60 + 6 * 60 * 60),
                    statusText: "Mock B",
                    updatedAt: now
                ),
            ]
        )
    }
}
