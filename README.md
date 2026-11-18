# AiUsage

Track AI usage quotas from your iPhone, with an optional home-screen widget.

![Widget](readme_images/widgets.png)
![Dashboard](readme_images/dashboard.png)
![Settings](readme_images/settings.png)

- no app backend
- provider requests are in `Shared/ProviderAPIClients.swift`
- the app saves credentials in the iOS Keychain (`AiUsage/Auth/CredentialsStore.swift`). The widget uses access tokens shared by the app to refresh usage.

## Supported providers

| Provider | Auth method |
|---|---|
| OpenAI Codex | OAuth or session cookie |
| Claude (including Fable when reported by your plan) | OAuth token or session cookie |
| Grok | Grok account sign-in with a device code |
| Gemini | Import the five-hour and weekly limits from Safari. Eligible legacy Code Assist accounts use OAuth for Code Assist quotas. |
| GitHub Copilot | Personal access token |
| Kimi | Session cookie |

## Requirements

- Xcode 26.2+
- iPhone or simulator on iOS 26.2+
- Apple Developer account (free personal team works)

## Install on your iPhone (Xcode)

1. Clone this repo and open `AiUsage.xcodeproj`.
2. Plug in your iPhone (or use wireless debugging), then select it as the run destination.
3. In **Targets**, open `AiUsage`, `AiUsageWidgetExtension`, and `GeminiSafariSync`:
   - **Signing & Capabilities** → set your **Team**
   - keep **Automatically manage signing** enabled
4. If signing fails, make IDs unique to your team:
   - bundle IDs for all three targets, with extension IDs prefixed by the app ID
   - `Config/AiUsageWidget-Info.plist` (`WKAppBundleIdentifier`)
   - App Group in `Config/AiUsage.entitlements`, `Config/AiUsageWidget.entitlements`, and `Shared/GeminiWebUsage.swift`
5. On first device run, enable Developer Mode on iPhone if prompted.
6. Press **Run** (`Cmd+R`). Xcode installs directly to your phone.

## Use the app

1. Open **Settings** (gear icon).
2. Pick a provider and follow the inline sign-in instructions. For Grok, tap **Sign in with Grok**, approve the device code on xAI’s sign-in page, then return to the app.
3. Tap **Refresh All Providers**.
4. To see usage on your Home Screen, add the AI Usage widget and choose the provider in widget settings.

### Sync Gemini usage

1. In iPhone **Settings → Apps → Safari → Extensions**, enable **AI Usage Gemini Sync**.
2. Open [Gemini Usage Limits](https://gemini.google.com/usage) in Safari and sign in. In Safari’s **Page Menu**, open **AI Usage Gemini Sync** and allow access to `gemini.google.com` if prompted.
3. Use **Sync Gemini Quota** in AI Usage settings or tap the **Gemini Usage** widget. The tap opens the signed-in Safari page for one quota read. The app and widget show the saved reading until the next sync.

Add **Gemini Usage** from the widget gallery for a standalone small widget. An existing small AI Usage widget can also show Gemini via **Edit Widget → Small Provider → Google Gemini**. Medium and large widgets include Gemini after the first sync when its **Widget** toggle is on under **Provider Order**.

## Enable/Disable `DEBUG_UI` in Xcode 26

1. In Xcode: **Product → Scheme → Edit Scheme...**
2. Select **Run** → **Arguments**.
3. Under **Environment Variables**, add:
   - Name: `DEBUG_UI`
   - Value: `true` (also accepts `1`, `yes`, `on`)
4. Run the app. Debug toggles appear in Settings.

To disable it, uncheck/remove `DEBUG_UI` (or set it to `false`).

## Add a new provider (quick checklist)

1. Add provider metadata in `Shared/ProviderID.swift` (case, name, icon, bar labels, URLs).
2. Add API client + factory mapping in `Shared/ProviderAPIClients.swift`.
3. Update credential parsing/display/validation in `AiUsage/AppModel.swift` (`parseCredentialsInput`, `hasToken`, `displayToken`, refresh logic if needed).
4. Update provider setup UI copy in `AiUsage/ContentView.swift` (`tokenPlaceholder`, `emptyTokenMessage`, `signInInstructions`).
5. Add icon asset in `Shared/ProviderAssets.xcassets`.
6. Update widget enums/rendering in `AiUsageWidget/AiUsageWidget.swift` (`ProviderOption`, `widgetBars`).
7. Add mock entries in `Shared/MockSnapshots.swift` and `Shared/MockSnapshotsSecondary.swift`.

If your provider needs extra credential fields, extend `Shared/Credentials.swift` (`ProviderCredentials`).

## License

MIT. See [LICENSE](LICENSE).
