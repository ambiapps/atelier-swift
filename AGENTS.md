# Agent Instructions

This repo is the Swift SDK for Ambi Atelier, ambi's feature-flag
service. The normative spec (data model, evaluation semantics, service
discovery) lives in the Atelier spec repository (`ambiapps/atelier`);
this repo must conform to it, not redefine it.

## Repository layout

```
Sources/Atelier/    The Atelier library (SPM product `Atelier`)
Tests/AtelierTests/ Unit + conformance tests
Demo/               Executable demo (`swift run AtelierDemo`)
spec/               Mirrored conformance test vectors (see below)
```

## Hard invariants

Violating any of these is a review-blocking bug:

1. **Clients never block launch on flags.** Disk-cache-first, network
   in background, last-good on any failure, compiled-in defaults
   underneath. No API on the hot path may await network.
   `waitForFirstConfig(timeout:)` and `waitForLaunchRefresh(timeout:)`
   are the deliberate exception: an
   opt-in, caller-bounded wait that nothing in the SDK calls and no
   read depends on. `maximumCacheAge` likewise narrows "last-good" only
   for hosts that set it; both default to the behavior above.
2. **Evaluation is deterministic and portable.** SHA-256 bucketing
   exactly as specified — never `Swift.Hasher`/`hashValue` or any
   process-seeded hash.
3. **Unknown config constructs resolve the whole flag to its
   compiled-in default** (not "skip the rule", not OFF).
4. **No raw PII leaves the device.** Emails are SHA-256-hashed
   client-side before any comparison or transmission.
5. **The evaluator must pass every vector in
   [spec/test-vectors.json](spec/test-vectors.json).** The canonical
   vectors live in the spec repository; the copy here is a mirror. Any
   change to evaluation semantics updates the spec repo (docs and
   vectors) and this repo (vectors and evaluator) in lockstep — never
   let the two copies diverge.
6. **Zero third-party dependencies.** `URLSession`, `CryptoKit`,
   `Foundation` only. In particular, no `supabase-swift` — the public
   API never names the backend; the service is located at runtime via
   the discovery document.
7. **Signature trust anchors come from the host app, never the
   network.** A build verifies against `AtelierConfiguration.signingKeys`
   and nothing else. Never resolve a `kid` against a downloaded JWKS:
   whoever can rewrite the config through a proxy can rewrite a JWKS
   from the same origin, and the SDK would be checking an attacker's
   document against an attacker's key. Equally: never dispatch on the
   token's own `alg` (pin `ES256`), and never let a verifying build
   fall back to the unsigned PostgREST path — either one hands the hole
   straight back. Empty `signingKeys` means this build does not verify,
   and must read the plain object exactly as before. Keys are per
   project and a build may carry several, each one base64url string;
   try them all. Never reduce the anchor set to a single key (rotation
   strands every install that has not updated), and never gate on
   `kid` — it is a label, not a selector, and a valid signature under
   an unfamiliar kid must still be accepted.
8. **`se.ambi.atelier.stable_id` (UserDefaults key) and the `Atelier`
   disk-cache directory name are frozen.** The stable ID seeds
   percentage-rollout bucketing; renaming either silently re-buckets
   every existing install.

## Delivery

- Work on a branch, open a PR, wait for the `swift test` check, merge
  with a regular merge commit. Never commit to `main` directly.
- **Never rebase and never squash-merge.** History is append-only: when
  a branch is behind or conflicts, merge `main` into it and resolve in
  the merge commit. PRs merge with `gh pr merge --merge` only.
- This is a public repository. No secrets, no internal URLs beyond the
  published discovery endpoint, no customer or user data — including in
  test fixtures and commit messages.
