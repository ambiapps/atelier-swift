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
}
```

Reads are synchronous and never block: they resolve against the current
snapshot (disk-cache-first, refreshed in the background), falling back
to the compiled-in default. The default should equal current shipped
behavior, so "Atelier unreachable" is indistinguishable from "nothing
changed".

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
