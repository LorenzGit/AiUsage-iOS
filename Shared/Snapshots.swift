import Foundation

public struct ProviderUsageSnapshot: Codable, Identifiable, Sendable {
    public let provider: ProviderID
    public let usedPercent: Double?
    public let secondaryUsedPercent: Double?
    public let tertiaryUsedPercent: Double?
    public let sessionRemainingPercent: Double?
    public let weeklyRemainingPercent: Double?
    public let tertiaryRemainingPercent: Double?
    public let sessionResetsAt: Date?
    public let weeklyResetsAt: Date?
    public let tertiaryResetsAt: Date?
    public let sessionRunsOutAt: Date?
    public let weeklyRunsOutAt: Date?
    public let tertiaryRunsOutAt: Date?
    public let statusText: String
    public let updatedAt: Date

    public var id: ProviderID { provider }

    public init(
        provider: ProviderID,
        usedPercent: Double?,
        secondaryUsedPercent: Double?,
        tertiaryUsedPercent: Double? = nil,
        sessionRemainingPercent: Double? = nil,
        weeklyRemainingPercent: Double? = nil,
        tertiaryRemainingPercent: Double? = nil,
        sessionResetsAt: Date? = nil,
        weeklyResetsAt: Date? = nil,
        tertiaryResetsAt: Date? = nil,
        sessionRunsOutAt: Date? = nil,
        weeklyRunsOutAt: Date? = nil,
        tertiaryRunsOutAt: Date? = nil,
        statusText: String,
        updatedAt: Date
    ) {
        self.provider = provider
        self.usedPercent = usedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.tertiaryUsedPercent = tertiaryUsedPercent
        self.sessionRemainingPercent = sessionRemainingPercent
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.tertiaryRemainingPercent = tertiaryRemainingPercent
        self.sessionResetsAt = sessionResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.tertiaryResetsAt = tertiaryResetsAt
        self.sessionRunsOutAt = sessionRunsOutAt
        self.weeklyRunsOutAt = weeklyRunsOutAt
        self.tertiaryRunsOutAt = tertiaryRunsOutAt
        self.statusText = statusText
        self.updatedAt = updatedAt
    }

    public var resolvedSessionRemainingPercent: Double? {
        if let sessionRemainingPercent { return sessionRemainingPercent }
        guard let usedPercent else { return nil }
        return 100 - usedPercent
    }

    public var resolvedWeeklyRemainingPercent: Double? {
        if let weeklyRemainingPercent { return weeklyRemainingPercent }
        guard let secondaryUsedPercent else { return nil }
        return 100 - secondaryUsedPercent
    }

    public var resolvedTertiaryRemainingPercent: Double? {
        if let tertiaryRemainingPercent { return tertiaryRemainingPercent }
        guard let tertiaryUsedPercent else { return nil }
        return 100 - tertiaryUsedPercent
    }
}

public struct WidgetSnapshot: Codable, Sendable {
    public let generatedAt: Date
    public let isMockData: Bool
    public let providers: [ProviderUsageSnapshot]

    public init(generatedAt: Date, isMockData: Bool = false, providers: [ProviderUsageSnapshot]) {
        self.generatedAt = generatedAt
        self.isMockData = isMockData
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case isMockData
        case providers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        isMockData = try container.decodeIfPresent(Bool.self, forKey: .isMockData) ?? false
        providers = try container.decode([ProviderUsageSnapshot].self, forKey: .providers)
    }
}

public struct CodexWeeklyPaceEstimate: Sendable {
    public let expectedRemainingPercent: Double
    public let deficitPercent: Double
    public let runsOutAt: Date?
}

public extension ProviderUsageSnapshot {
    /// Estimates Codex weekly pacing, including deficit and projected run-out time.
    func codexWeeklyPaceEstimate(now: Date = Date()) -> CodexWeeklyPaceEstimate? {
        guard provider == .codex else { return nil }
        guard let weeklyRemainingPercent = resolvedWeeklyRemainingPercent else { return nil }
        guard let resetAt = weeklyResetsAt else { return nil }

        let totalWindowSeconds: TimeInterval = 7 * 24 * 60 * 60
        let secondsUntilReset = resetAt.timeIntervalSince(now)
        guard secondsUntilReset > 0, secondsUntilReset <= totalWindowSeconds else { return nil }

        let elapsedSeconds = max(0, totalWindowSeconds - secondsUntilReset)
        guard elapsedSeconds > 0 else { return nil }

        let expectedUsedPercent = min(max((elapsedSeconds / totalWindowSeconds) * 100, 0), 100)
        // Too early in the window to extrapolate reliably; skip until ≥ 3 % has elapsed.
        guard expectedUsedPercent >= 3 else { return nil }

        let actualUsedPercent = min(max(100 - weeklyRemainingPercent, 0), 100)
        let deltaPercent = actualUsedPercent - expectedUsedPercent
        // Only surface the warning when usage leads the linear pace by > 2 percentage points.
        guard deltaPercent > 2 else { return nil }

        let remainingPercent = min(max(weeklyRemainingPercent, 0), 100)
        var runsOutAt: Date?
        if actualUsedPercent > 0 {
            let burnRate = actualUsedPercent / elapsedSeconds
            if burnRate > 0 {
                let etaSeconds = remainingPercent / burnRate
                if etaSeconds < secondsUntilReset {
                    runsOutAt = now.addingTimeInterval(etaSeconds)
                }
            }
        }

        return CodexWeeklyPaceEstimate(
            expectedRemainingPercent: max(remainingPercent, 100 - expectedUsedPercent),
            deficitPercent: deltaPercent,
            runsOutAt: runsOutAt
        )
    }
}

public enum RelativeDateText {
    public static func abbreviated(from date: Date, relativeTo reference: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}
