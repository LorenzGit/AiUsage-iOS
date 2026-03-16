What your iPhone app might do:
detect whether a paired watch exists
detect whether the watch app is installed

adapt UI accordingly, for example:

“Open the Apple Watch app to install”
“Watch companion is installed”
“Pair an Apple Watch to use this feature”

That is a good UX pattern. But the app itself is not expected to directly force-install the companion watch app in the normal third-party app flow. Apple’s companion/independent watch app model keeps installation under system control.

A sensible iOS-side behavior is:

if WCSession.default.isPaired == false: show “Pair an Apple Watch”
if paired but isWatchAppInstalled == false: show “Install the watch app from the Watch app / system-managed install flow”
if installed: enable watch-related features