import Atelier
import Foundation

// Demo (M2 exit criterion): cold boot → cached values → background
// refresh. No backend configuration: the SDK locates the Atelier
// service itself (ADR 0008) — integrating apps only state who they
// are. Run from the repo root:
//
//   swift run AtelierDemo
//
// Optionally override the identity:
//
//   ATELIER_ORG=ambi ATELIER_PRODUCT=ambre swift run AtelierDemo
//
// First run: no cache, everything resolves to its compiled-in default,
// then the background refresh lands and values update. Second run: the
// disk cache serves the last-good values instantly at "launch".

let environment = ProcessInfo.processInfo.environment

let client = AtelierClient(
    configuration: AtelierConfiguration(
        organization: environment["ATELIER_ORG"] ?? "ambi",
        product: environment["ATELIER_PRODUCT"] ?? "ambre"))

await client.setContext(
    FlagContext(
        userId: environment["FLAGS_USER_ID"],
        build: 9042,
        appVersion: "5.2.0",
        platform: "macos",
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        locale: Locale.current.identifier.lowercased()))

let demoKeys = ["demo_banner", "grocery_v2"]

func printValues(_ label: String) {
    print("\(label):")
    for key in demoKeys {
        let value = client.isEnabled(key, default: false)
        print("  \(key) = \(value ? "ON" : "OFF (or default)")")
    }
}

// Cold boot: whatever the disk cache had, served synchronously.
printValues("At launch (cache or compiled-in defaults)")

// Every flag is observable: the streams yield the current value
// immediately, then again whenever a refresh changes the resolution —
// this is how an app reacts mid-session to a toggle flipped in the UI.
print("\nWatching for changes while the background refresh lands…")
let watchers = demoKeys.map { key in
    Task {
        var isFirst = true
        for await value in client.observeIsEnabled(key, default: false) {
            if isFirst {
                isFirst = false  // initial value already printed above
                continue
            }
            print("  [update] \(key) → \(value ? "ON" : "OFF")")
        }
    }
}
try? await Task.sleep(for: .seconds(3))
for watcher in watchers { watcher.cancel() }

printValues("\nAfter background refresh")
print("\nRun me again: the values above are now the disk cache a real app")
print("would see instantly at next cold boot.")
