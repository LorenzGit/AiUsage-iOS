import Foundation

public enum MockSnapshotCycle {
    private static let indexKey = "aiusage.mock_snapshot_cycle_index"

    public static func next(now: Date = Date()) -> WidgetSnapshot {
        let defaults = UserDefaults(suiteName: WidgetSnapshotStore.appGroupID) ?? .standard
        let nextIndex = (defaults.integer(forKey: indexKey) + 1) % 2
        defaults.set(nextIndex, forKey: indexKey)
        return snapshot(at: nextIndex, now: now)
    }

    public static func snapshot(at index: Int, now: Date = Date()) -> WidgetSnapshot {
        if index % 2 == 0 {
            return primary(now: now)
        }
        return secondary(now: now)
    }

    private static func primary(now: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now,
            isMockData: true,
            providers: [
                ProviderUsageSnapshot(
                    provider: .codex,
                    usedPercent: 8,
                    secondaryUsedPercent: 47,
                    tertiaryUsedPercent: 35,
                    sessionRemainingPercent: 92,
                    weeklyRemainingPercent: 24,
                    tertiaryRemainingPercent: 65,
                    sessionResetsAt: now.addingTimeInterval(4 * 60 * 60),
                    weeklyResetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                    tertiaryResetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                    sessionRunsOutAt: now.addingTimeInterval(20 * 60 * 60),
                    statusText: "Mock A",
                    updatedAt: now
                ),
                ProviderUsageSnapshot(
                    provider: .claude,
                    usedPercent: 36,
                    secondaryUsedPercent: 59,
                    sessionRemainingPercent: 64,
                    weeklyRemainingPercent: 41,
                    sessionResetsAt: now.addingTimeInterval(3 * 60 * 60),
                    weeklyResetsAt: now.addingTimeInterval(2 * 24 * 60 * 60 + 12 * 60 * 60),
                    statusText: "Mock A",
                    updatedAt: now
                ),
                ProviderUsageSnapshot(
                    provider: .gemini,
                    usedPercent: 28,
                    secondaryUsedPercent: 33,
                    sessionRemainingPercent: 72,
                    weeklyRemainingPercent: 67,
                    sessionResetsAt: now.addingTimeInterval(2 * 60 * 60),
                    weeklyResetsAt: now.addingTimeInterval(5 * 24 * 60 * 60),
                    statusText: "Mock A",
                    updatedAt: now
                ),
                ProviderUsageSnapshot(
                    provider: .copilot,
                    usedPercent: 17,
                    secondaryUsedPercent: 25,
                    sessionRemainingPercent: 83,
                    weeklyRemainingPercent: 75,
                    sessionResetsAt: now.addingTimeInterval(6 * 60 * 60),
                    weeklyResetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
                    statusText: "Mock A",
                    updatedAt: now
                ),
                ProviderUsageSnapshot(
                    provider: .kimi,
                    usedPercent: 52,
                    secondaryUsedPercent: 70,
                    sessionRemainingPercent: 48,
                    weeklyRemainingPercent: 30,
                    sessionResetsAt: now.addingTimeInterval(90 * 60),
                    weeklyResetsAt: now.addingTimeInterval(4 * 24 * 60 * 60 + 8 * 60 * 60),
                    statusText: "Mock A",
                    updatedAt: now
                ),
            ]
        )
    }

}
