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

- [x] **2.1** Create `AiUsage/WatchSessionManager.swift`
  - Singleton `WCSessionDelegate` activated in `AiUsageApp.swift`
  - Activates `WCSession` on app launch
- [x] **2.2** Send snapshot to Watch whenever `persistWidgetSnapshot()` runs
  - Uses `updateApplicationContext` (latest-wins) and `transferUserInfo` (queued reliable delivery)
  - Payload: JSON-encoded `WidgetSnapshot`
- [x] **2.3** Handle `session(_:didReceiveMessage:)` for Watch-initiated refresh requests
  - When Watch sends `{"action": "refresh"}`, triggers `refreshAll()` and replies with new snapshot
  - Refresh handler wired in ContentView's `.task` block
- [x] **2.4** Guard all WatchConnectivity calls behind `WCSession.isSupported()` (no-op on simulator without paired Watch)

## Phase 3: WatchConnectivity — Watch side

- [x] **3.1** Create `AiUsageWatch/WatchSessionManager.swift`
  - `@Observable` singleton with separate `WCSessionDelegate` (avoids `@MainActor` conflict)
  - Activated in `AiUsageWatchApp.init()`
- [x] **3.2** Receive snapshots from `didReceiveUserInfo` and `didReceiveApplicationContext`
  - Decodes `WidgetSnapshot` from payload, stores in `@Observable` property
  - Persists to `UserDefaults` (watch-local) so cached data survives app termination
- [x] **3.3** Implement "request refresh" — sends `{"action": "refresh"}` to phone
  - Uses `sendMessage` with reply handler; sets `isRefreshing` for loading indicator

## Phase 4: Watch app UI

- [x] **4.1** Create `AiUsageWatch/AiUsageWatchApp.swift` — SwiftUI `@main` entry point
- [x] **4.2** Create `AiUsageWatch/WatchDashboardView.swift` — main view
  - `NavigationStack` with `List` of provider rows + pull-to-refresh
  - Footer shows "Updated X ago" + refreshing indicator
  - Empty state: "Set up providers in the iPhone app"
- [x] **4.3** Create `AiUsageWatch/WatchProviderDetailView.swift`
  - Quota bars with capsule progress, reset times, Codex pace warning
  - Color-coded percentages (green/yellow/red)
- [x] **4.4** `WatchProviderRow` (inline in `WatchDashboardView.swift`)
  - Provider icon + name + compact quota labels with colored percentages
- [x] **4.5** Colors derived from existing `ProviderID.barColors` — no separate palette needed
- [x] **4.6** SwiftUI previews with Claude mock data (13% 5h, 37% 7d) for dashboard, row, and detail

## Phase 5: Watch complications

- [x] **5.1** WidgetKit-based complications in `WatchComplication.swift`
  - Reuses `WidgetSnapshot` from UserDefaults cache
- [x] **5.2** Four complication families:
  - **Circular**: gauge ring with % label
  - **Corner**: bold % with provider name widget label
  - **Rectangular**: provider name + two linear gauge bars with labels
  - **Inline**: "Codex 72%"
- [x] **5.3** `WatchComplicationIntent` with `WatchProviderOption` enum + recommendations
- [x] **5.4** Timeline provider reads from UserDefaults cache, 15-min refresh policy
  - `WatchSessionManager` calls `reloadAllTimelines()` when new data arrives
- [ ] **5.5** Add complication previews

## Phase 6: Polish & edge cases

- [x] **6.1** Handle "phone not reachable" — shows "iPhone unavailable" in footer; stale data (>10 min) gets orange clock icon
- [x] **6.2** First launch with no data shows onboarding: "Set up providers in the iPhone app" (already in Phase 4)
- [x] **6.3** Provider order/visibility: Watch shows providers in the order the iPhone sends them in the snapshot (already respects iPhone ordering)
- [x] **6.4** Accessibility: VoiceOver labels on quota bars ("Session, 72 percent remaining")
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
