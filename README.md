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

    // A flag can carry a typed value instead of a bare on/off: each
    // targeting rule serves a value, and users no rule matches keep the
    // default written right here.
    static var importBatchSize: Int { client.value("import_batch_size", default: 10) }
}
```

Reads are synchronous and never block: they resolve against the current
snapshot (disk-cache-first, refreshed in the background), falling back
to the compiled-in default. The default should equal current shipped
behavior, so "Atelier unreachable" is indistinguishable from "nothing
changed".

### Waiting for the first config (opt-in)

A first launch has no cache, so every read resolves to its default until
the first fetch lands — which puts every new install in an experiment's
control arm on its first screen. A host that would rather show a brief
loading state can wait, with a bound it chooses:

```swift
let resolved = await client.waitForFirstConfig(timeout: .seconds(3))
```

It returns as soon as a config is being served, as soon as the launch
refresh has failed (an offline launch does not sit out the timeout), or
at the timeout. With a usable cache it returns immediately, so only
first launches ever wait. `client.hasLoadedConfig` is the same answer
synchronously — tag exposures with it to tell "resolved against a
config" from "fell back because there was nothing to resolve against".

`waitForLaunchRefresh(timeout:)` is the stricter sibling: a usable cache
does not cut it short, so every cold start acts on the config as it is
now, and falls back to the cache (within `maximumCacheAge`) or the
defaults only when the fetch misses the timeout. It costs a round trip
on every launch.

Nothing in the SDK calls these and reads never wait; the guarantee below
is about the SDK, and this is the host deciding otherwise for one screen.

`AtelierConfiguration.maximumCacheAge` (default `nil`: last-good is
served however old) makes a cache older than the given age unusable at
cold boot, so reads fall back to compiled-in defaults until a refresh
succeeds. Use it when acting on a stale experiment arm is worse than
being in control; leave it unset when a kill switch must survive a long
time offline.

### Listing the config

`client.resolvedValues()` returns every flag in the current config
resolved for this user — the value a rule serves them, or `nil` where
nothing overrides them and the call site's own default applies. New
flags appear as soon as the config carrying them lands; archived flags
are gone. It is for analytics (tag events with the flag state the user
was in), not a read: no exposure, no observation tracking.

**A flag is an override, not a source of truth.** The default you pass
at the call site is what the code does unless a rule in the config
claims this particular user — and it is also what you get when the flag
is missing, when it is paused in the console, when the config carries
something this build cannot parse, and when Atelier is unreachable.
There is no configured "off value" anywhere.

`value(_:default:)` reads `Bool`, `Int`, `Double` and `String`. Reads
are exact: asking for a type the flag does not declare — including a
`Double` from an integer flag — gives the compiled-in default, as does
a flag that has been retyped since your build shipped. `isEnabled` is
the `Bool` overload of the same read.

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

## Verifying signed config (optional)

Flag config is public, and over TLS a third party cannot alter it — but
a user can point their own device at an intercepting proxy and rewrite
flag values in flight. If that matters for your app, have Atelier sign
your project's config and give the SDK the public key:

```swift
AtelierConfiguration(
    organization: "acme",
    product: "myapp",
    signingKeys: ["LJiVbQwvcjutcHA-Gzczw0wQUBn5UUUSERpSnHS86LEBrZRrBJXvIamUs9kRAztGdfb58-6DnCOzYkz10PgDPg"])
```

Copy the string from Project settings, which shows this whole call
ready to paste. Supplying no keys — the default — means this build does
not verify and reads config exactly as before.

A build with keys reads only the signed document and rejects anything
that does not verify: tampered, signed by another key, aimed at another
project, or an older revision replayed. Every rejection is an ordinary
refresh failure — last-good keeps serving, and launch is never blocked.

**Rotating means shipping first.** The key lives in your binary, so add
the new one to the array *alongside* the old, ship it, wait for
adoption, and only then switch Atelier over. Every key in the array is
tried, so a build carrying both verifies documents signed by either. The other order strands every install
that has not updated on last-good. This is also the remedy if a key
leaks: someone holding it can forge config only for devices they can
already intercept, which is where you were before signing, so rotate
through the overlap rather than pulling the key and breaking delivery.

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
5. **Nothing configured means nothing changes.** No rule matched, flag
   paused, flag deleted, backend down — every one of them is the app
   doing exactly what its own code says.
6. **Config can be signed.** A build carrying your project's
   verification key reads an ES256-signed document and rejects anything
   else, closing the obvious attack on a public config — a device
   pointed at a TLS-intercepting proxy that rewrites values in flight.
   Verification failure is an ordinary refresh failure (guarantee 2),
   never a blocked launch.

   It stops a proxy forging config. It does not stop a patched binary,
   and it cannot stop a device that simply refuses to fetch and keeps
   what it cached. **Flags gate product behavior, never authorization**
   — anything that must be enforced belongs in your backend.

## Demo

```sh
swift run AtelierDemo
```

Cold boot → cached values → background refresh. Run it twice to see the
disk cache serve instantly on the second "launch".

## License

[MIT](LICENSE)
