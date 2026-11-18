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
    public let fableUsedPercent: Double?
    public let fableResetsAt: Date?
    public let isGeminiWebUsage: Bool?
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
        fableUsedPercent: Double? = nil,
        fableResetsAt: Date? = nil,
        isGeminiWebUsage: Bool? = nil,
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
        self.fableUsedPercent = fableUsedPercent
        self.fableResetsAt = fableResetsAt
        self.isGeminiWebUsage = isGeminiWebUsage
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

    public var fableRemainingPercent: Double? {
        fableUsedPercent.map { 100 - $0 }
    }

    var primaryQuotaTitle: String {
        isGeminiWebUsage == true ? "5h" : provider.primaryBarTitle
    }

    var secondaryQuotaTitle: String {
        isGeminiWebUsage == true ? "Weekly" : provider.secondaryBarTitle
    }
}

extension GeminiWebUsage {
    var snapshot: ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: .gemini,
            usedPercent: session.usedPercent,
            secondaryUsedPercent: weekly.usedPercent,
            sessionResetsAt: session.resetsAt,
            weeklyResetsAt: weekly.resetsAt,
            isGeminiWebUsage: true,
            statusText: "Gemini Apps",
            updatedAt: importedAt
        )
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

struct QuotaCountdownFormat: DiscreteFormatStyle {
    private static let secondsPerHour: TimeInterval = 3600
    private static let secondsPerDay = 24 * secondsPerHour

    enum Event: String, Codable {
        case reset
        case runOut
    }

    let date: Date
    var event: Event = .reset
    var compact = false

    func format(_ now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else {
            return event == .reset ? "Reset due" : "Runs out now"
        }
        let remaining: String
        if seconds > Self.secondsPerDay {
            let hours = Int(seconds / Self.secondsPerHour)
            remaining = "\(hours / 24)d \(hours % 24)h"
        } else {
            let minutes = minutesLeft(at: now)
            remaining = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        }
        if compact { return remaining }
        return event == .reset ? "Resets in \(remaining)" : "Runs out in \(remaining)"
    }

    func discreteInput(after input: Date) -> Date? {
        let seconds = date.timeIntervalSince(input)
        if seconds > Self.secondsPerDay {
            let hours = Int(seconds / Self.secondsPerHour)
            let boundary = date.addingTimeInterval(-Double(hours) * Self.secondsPerHour)
            // Whole hours count down just after the boundary. At 24h the format changes at the boundary.
            return hours == 24 ? boundary : Date(timeIntervalSinceReferenceDate: boundary.timeIntervalSinceReferenceDate.nextUp)
        }
        let minutes = minutesLeft(at: input)
        guard minutes > 0 else { return nil }
        return date.addingTimeInterval(-Double(minutes - 1) * 60)
    }

    func discreteInput(before input: Date) -> Date? {
        let seconds = date.timeIntervalSince(input)
        if seconds > Self.secondsPerDay {
            let hours = Int(seconds / Self.secondsPerHour)
            return date.addingTimeInterval(-Double(hours + 1) * Self.secondsPerHour)
        }
        let boundary = date.addingTimeInterval(-Double(minutesLeft(at: input)) * 60)
        return Date(timeIntervalSinceReferenceDate: boundary.timeIntervalSinceReferenceDate.nextDown)
    }

    private func minutesLeft(at now: Date) -> Int {
        Int(ceil(max(0, date.timeIntervalSince(now)) / 60))
    }
}
