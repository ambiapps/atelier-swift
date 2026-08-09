# Atelier Swift SDK

Swift client for [Ambi](https://ambi.se) Atelier, ambi's feature-flag
service: kill switches, staged percentage rollouts, per-version gating,
and attribute-based targeting — evaluated on-device.

Zero third-party dependencies: `URLSession` for fetch, `CryptoKit` for
SHA-256, `Foundation` for storage.

Platforms: iOS 16+, macOS 13+, watchOS 9+, tvOS 16+, visionOS 1+.

## Installation

Add the package in Xcode or in your `Package.swift`:

```swift
.package(url: "https://github.com/ambiapps/atelier-swift", from: "1.0.0")
```

## Usage

Declare flags in one typed namespace so call sites don't scatter string
keys, and defaults live in one reviewed place:

```swift
import Atelier

enum Flags {
    static let client = AtelierClient(
        configuration: AtelierConfiguration(organization: "acme", product: "myapp"))

    static var groceryV2: Bool { client.isEnabled("grocery_v2", default: false) }

    // A flag can carry a typed value instead of a bare on/off: the same
    // targeting decides on or off, and the flag says what each is worth.
    static var importBatchSize: Int { client.value("import_batch_size", default: 10) }
}
```

Reads are synchronous and never block: they resolve against the current
snapshot (disk-cache-first, refreshed in the background), falling back
to the compiled-in default. The default should equal current shipped
behavior, so "Atelier unreachable" is indistinguishable from "nothing
changed".

`value(_:default:)` reads `Bool`, `Int`, `Double` and `String`. Reads
are exact: asking for a type the flag does not declare — including a
`Double` from an integer flag — gives the compiled-in default, as does
a flag that has been retyped since your build shipped. `isEnabled`
works on a flag of any type and reports its on/off resolution.

On OSes with the Observation framework (iOS 17, macOS 14, …), a flag
read inside a SwiftUI `body` subscribes the view — it re-renders when
the value changes, with no wiring at the call site:

```swift
struct GroceryHome: View {
    var body: some View {
        if Flags.groceryV2 {        // re-renders when the flag flips
            GroceryV2View()
        } else {
            GroceryLegacyView()
        }
    }
}
```

Outside SwiftUI (or on older OSes), observe through streams:

```swift
for await enabled in Flags.client.observeIsEnabled("grocery_v2", default: false) {
    // current value immediately, then every change
}
```

Set the evaluation context on sign-in/out; raw emails never leave the
device (they are SHA-256-hashed before any comparison or transmission):

```swift
await Flags.client.setContext(
    FlagContext(
        userId: user.id,
        email: user.email,
        build: 9042,
        appVersion: "5.2.0",
        platform: "ios",
        osVersion: osVersion,
        locale: locale))
```

### Push poke (optional)

Admins can opt to wake installed apps right after saving a flag change
("Push to devices now" in the Atelier UI) instead of waiting for the
next refresh. Two app-delegate forwards make the app reachable; both
are best-effort — skipping this wiring just means the app stays on the
ordinary refresh cadence:

```swift
func application(_ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { await Flags.client.registerDeviceToken(deviceToken) }
}

func application(_ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
    -> UIBackgroundFetchResult {
    await Flags.client.handlePushNotification(userInfo) ? .newData : .noData
}
```

The app needs the remote-notification background mode and a
`registerForRemoteNotifications()` call (silent pushes need no
user-facing permission). Pokes carry no flag values — the SDK just
refetches through the normal path. `handlePushNotification` returns
`false` for payloads that aren't Atelier pokes, so it composes with
your own pushes. `registerDeviceToken`'s default environment maps
debug builds to the APNs sandbox and release builds to production;
pass an explicit `PushEnvironment` if your build setup differs.

## Manage flags from your coding agent

Atelier's console speaks [MCP](https://modelcontextprotocol.io), so the
agent you already code with can read your flags — what exists, what
each one is set to, what it would resolve to for a given user — and
create, target and ramp them, without you explaining your setup first:

```sh
claude mcp add --transport http atelier \
  https://idsbxaiaunsbqegapzib.supabase.co/functions/v1/mcp
```

Adding it opens your browser to sign in and approve; there is no API
key to copy anywhere. The agent then acts with your own access — the
projects you can reach — and every change it makes is recorded in the
audit log under your name.

The same command, and the endpoint on its own, are shown in the console
under **Organizations**.

## Design guarantees

1. **Never blocks launch.** Initialization reads the disk cache and
   returns; network refresh is fire-and-forget in the background.
2. **Last-good wins.** A failed or malformed fetch changes nothing;
   the cache is replaced atomically only by a valid document.
3. **Deterministic evaluation.** Stable SHA-256 bucketing — the same
   user sees the same rollout decision on every platform.
4. **Fail-safe.** Unknown config constructs resolve the whole flag to
   its compiled-in default, so shipped builds stay correct as new
   targeting features are added server-side.

## Demo

```sh
swift run AtelierDemo
```

Cold boot → cached values → background refresh. Run it twice to see the
disk cache serve instantly on the second "launch".

## License

[MIT](LICENSE)
