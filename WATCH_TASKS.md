# Apple Watch App — Task List

## Architecture decision

The Watch app receives usage snapshots from the iPhone app via **WatchConnectivity** and caches them locally. It does **not** make provider API calls directly — the auth flows and token refresh logic are complex and phone-dependent. When the phone is unreachable, the Watch shows the last cached snapshot with a staleness indicator.

This keeps the Watch app thin and avoids duplicating networking/auth code onto watchOS.

---

## Phase 1: Xcode project setup

- [x] **1.1** Add a watchOS App target (`AiUsageWatch`) to the Xcode project
  - Product type: watchOS App (SwiftUI lifecycle, no storyboard)
  - Deployment target: watchOS 26.2 (matches iOS 26.2)
  - Bundle ID: `aiusage.gamojo.com.watchkitapp`
- [x] **1.2** Add the same App Group entitlement (`group.aiusage.gamojo.com`) — not strictly needed for Watch Connectivity but useful if sharing UserDefaults for provider order
- [x] **1.3** Add the same `keychain-access-groups` entitlement (`$(AppIdentifierPrefix)aiusage.gamojo.com.shared`) for potential future credential sharing
- [x] **1.4** Add Shared sources to the Watch target's build:
  - `Shared/ProviderID.swift` (already uses `#if canImport` guards for UIKit)
  - `Shared/Snapshots.swift` (pure Codable, no platform deps)
  - `Shared/MockSnapshots.swift` + `MockSnapshotsSecondary.swift` (for previews)
  - `Shared/ProviderAssets.xcassets` (SVG icons render on watchOS)
  - **Do not** include `Shared/WidgetSnapshotStore.swift` (App Group file/keychain storage is iPhone-side only)
- [x] **1.5** Verify the Watch target builds with the shared sources (check `canImport` guards compile cleanly on watchOS)
  - Fixed: `MockSnapshots.swift` `WidgetSnapshotStore` reference guarded with `#if os(watchOS)`

## Phase 2: WatchConnectivity — iPhone side

- [ ] **2.1** Create `AiUsage/WatchSessionManager.swift`
  - Singleton `WCSessionDelegate` activated in `AiUsageApp.swift`
  - Activates `WCSession` on app launch
- [ ] **2.2** Send snapshot to Watch whenever `persistWidgetSnapshot()` runs
  - Use `WCSession.default.transferUserInfo(_:)` for reliable background delivery
  - Payload: JSON-encoded `WidgetSnapshot` + provider order array
  - Also send via `updateApplicationContext(_:)` so the Watch always has the latest on launch
- [ ] **2.3** Handle `session(_:didReceiveMessage:)` for Watch-initiated refresh requests
  - When Watch sends a "refresh" message, trigger `refreshAll()` and reply with the new snapshot
- [ ] **2.4** Guard all WatchConnectivity calls behind `WCSession.isSupported()` (no-op on simulator without paired Watch)

## Phase 3: WatchConnectivity — Watch side

- [ ] **3.1** Create `AiUsageWatch/WatchSessionManager.swift`
  - Singleton `WCSessionDelegate` activated in the Watch app entry point
  - Activates `WCSession` on launch
- [ ] **3.2** Receive snapshots from `didReceiveUserInfo` and `didReceiveApplicationContext`
  - Decode `WidgetSnapshot` from the payload
  - Store in a local `@Published` observable for SwiftUI binding
  - Persist to `UserDefaults` (watch-local) so cached data survives app termination
- [ ] **3.3** Implement "request refresh" — send a message to the phone asking it to refresh and reply with fresh data
  - Use `WCSession.default.sendMessage(_:replyHandler:errorHandler:)`
  - Show a brief loading indicator while waiting

## Phase 4: Watch app UI

- [ ] **4.1** Create `AiUsageWatch/AiUsageWatchApp.swift` — SwiftUI `@main` entry point
- [ ] **4.2** Create `AiUsageWatch/WatchDashboardView.swift` — main view
  - `NavigationStack` with a `List` of provider rows
  - Each row: provider icon + name + primary remaining % + secondary remaining %
  - Tapping a row navigates to a detail view
  - Pull-to-refresh triggers a refresh request to the phone
  - "Updated X ago" footer text
  - If no data and phone unreachable: "Open AiUsage on iPhone" message
- [ ] **4.3** Create `AiUsageWatch/WatchProviderDetailView.swift`
  - Full-screen detail for one provider
  - Show all quota bars (primary, secondary, tertiary) with labels and percentages
  - Reset time for each bar
  - Codex weekly pace deficit warning (reuse `codexWeeklyPaceEstimate()` from Snapshots.swift)
- [ ] **4.4** Create `AiUsageWatch/WatchProviderRow.swift` — list row component
  - Compact layout: icon, name, two small gauge rings or inline bars
- [ ] **4.5** Add color palette for Watch (derive from existing `ProviderID.barColors`)
  - Watch backgrounds are always dark; only need one palette variant
- [ ] **4.6** Support mock data for SwiftUI previews using `MockSnapshotCycle`

## Phase 5: Watch complications

- [ ] **5.1** Create a `CLKComplicationDataSource` (or WidgetKit `Widget` for watchOS 10+)
  - Use WidgetKit since the project targets watchOS 26.2
  - Reuse the same `WidgetSnapshot` data model
- [ ] **5.2** Define complication families:
  - **Circular** (`.accessoryCircular`): single provider gauge ring with % label
  - **Corner** (`.accessoryCorner`): provider name + remaining %
  - **Rectangular** (`.accessoryRectangular`): 1–2 providers with inline bars (similar to small iOS widget)
  - **Inline** (`.accessoryInline`): "Codex 72% · Claude 58%"
- [ ] **5.3** Add `AppIntentConfiguration` for complication provider selection (which provider to show)
  - Reuse `ProviderOption` enum pattern from the iOS widget
- [ ] **5.4** Timeline provider reads cached `WidgetSnapshot` from Watch-local `UserDefaults`
  - Timeline entries refresh when WatchConnectivity delivers new data
  - Call `WidgetCenter.shared.reloadAllTimelines()` when new snapshot arrives
- [ ] **5.5** Add complication previews

## Phase 6: Polish & edge cases

- [ ] **6.1** Handle "phone not reachable" gracefully — show cached data with staleness indicator, disable refresh button or show "iPhone unavailable"
- [ ] **6.2** Handle first launch with no data — show onboarding text: "Set up providers in the iPhone app"
- [ ] **6.3** Respect `providerOrder` and `widgetVisibility` from the phone (sent alongside snapshots)
- [ ] **6.4** Accessibility: ensure VoiceOver labels on gauge rings and bars
- [ ] **6.5** Test on real Watch hardware — WatchConnectivity behaves differently on device vs simulator
- [ ] **6.6** Add the Watch app screenshot to `README.md`

## Files to create

```
AiUsageWatch/
  AiUsageWatchApp.swift              — @main entry point
  WatchSessionManager.swift          — WCSessionDelegate, snapshot caching
  WatchDashboardView.swift           — main provider list
  WatchProviderDetailView.swift      — per-provider detail screen
  WatchProviderRow.swift             — compact list row component
  WatchComplication.swift            — WidgetKit complications
  Assets.xcassets/                   — watch app icon

AiUsage/
  WatchSessionManager.swift          — iPhone-side WCSessionDelegate
```

## Files to modify

```
AiUsage/AiUsageApp.swift             — activate WCSession on launch
AiUsage/AppModel.swift               — call watch session manager from persistWidgetSnapshot()
Shared/ProviderID.swift              — verify all #if canImport guards work on watchOS
AiUsage.xcodeproj/project.pbxproj   — new Watch target + shared source membership
Config/                              — Watch entitlements file
README.md                            — add Watch setup instructions + screenshot
```

## What NOT to do

- **Don't duplicate API clients on the Watch.** The auth flows (OAuth PKCE, cookie sessions, token refresh) are complex and phone-centric. Pushing snapshots via WatchConnectivity is simpler and more reliable.
- **Don't use App Group file sharing for Watch.** watchOS apps don't share an App Group container with the iPhone app. WatchConnectivity is the correct transport.
- **Don't build a Watch-specific credential store.** All credential management stays on the phone.
