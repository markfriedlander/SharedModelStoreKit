# SharedModelStoreKit

A tiny, dependency-free Swift package for **co-owning large downloaded model files
across a family of apps** that share an App Group container on iOS/macOS.

If you ship more than one app that each want to use the same on-device model (an MLX
LLM, an embedding model, etc.), you don't want each app downloading its own multi-GB
copy, and you don't want one app's "delete model" to yank the files out from under
another. This package is the shared bookkeeping that makes a single downloaded copy
safely shared: a claim ledger, a download lock, and pinned model revisions, all stored
in the common App Group container and coordinated with `NSFileCoordinator`.

It was built for one such family but contains no app-specific identifiers — you supply
your own App Group id.

## What it gives you

- **One on-disk layout** every app agrees on: `<AppGroup>/Models/huggingface/models/<repoID>/`.
- **A co-ownership ledger** (`manifest.json`): each app records a claim on every model it
  uses; a model's files are deleted only when **no** app still claims it.
- **Lease-based claims.** Each app stamps a "last seen" heartbeat; a claim from an app
  not seen in 30 days is reaped, so an *uninstalled* app can't pin shared models forever.
  Reaping is conservative: it fires only on a heartbeat that is present **and** provably
  stale, never on a missing one.
- **Forward-compatible on disk.** The manifest is only ever extended, and added fields
  are optional, so an older, un-updated app that rewrites the file can never wipe the
  ledger or cause a wrongful delete. Safe to roll out to an already-shipped app.
- **A cross-app download lock** (`download-locks.json`) so two apps don't fetch the same
  repo at once; the loser waits and adopts the finished copy.
- **Pinned model revisions** so an upstream re-conversion can't silently break a shipped
  build, and no sibling can download a bad revision that another app then adopts.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/<owner>/SharedModelStoreKit.git", from: "1.0.0")
```

Every app in the family must use the **same App Group id** and have the App Group
capability enabled in its entitlements.

## Use

Call `configure` once at launch, before any store access, then stamp a heartbeat:

```swift
import SharedModelStoreKit

// At app launch:
SharedModelStore.configure(appGroupID: "group.com.yourcompany.yourfamily")
SharedModelStore.touchHeartbeat()   // "this app is alive" — keeps its claims fresh
```

Where you store models:

```swift
let dir = SharedModelStore.mlxModelDir("mlx-community/some-model")   // where to download
if SharedModelStore.isRepoDownloaded("mlx-community/some-model") { /* already present */ }
```

On a completed download (and when adopting a model a sibling already fetched):

```swift
SharedModelStore.claim(modelID: repoID, repo: repoID, sizeBytes: bytes)
SharedModelStore.excludeFromBackup(repoID)   // App Groups ARE iCloud-backed by default
```

On delete — only remove files when it's safe:

```swift
if SharedModelStore.releaseClaim(modelID: repoID) {
    try? FileManager.default.removeItem(at: SharedModelStore.mlxModelDir(repoID))
}
```

Download lock (optional but recommended when two apps might fetch the same repo):

```swift
if SharedModelStore.acquireDownloadLock(modelID: repoID) {
    // download…; call refreshDownloadLock(modelID:) from your progress loop
    SharedModelStore.releaseDownloadLock(modelID: repoID)   // on complete/cancel/fail
} else {
    // another app is downloading it — wait and adopt its copy
}
```

Pinned revisions — download a repo at a fixed commit so an upstream re-conversion can't
break your build:

```swift
let rev = SharedModelStore.revision(forRepoID: repoID)   // pinned SHA, or "main"
// pass `rev` to your downloader as the revision to fetch
```

The package ships a baked-in baseline of pins. To add your own (as an outside consumer,
or to extend the set), register them at launch:

```swift
SharedModelStore.registerPinnedRevisions(["your-org/your-model": "<commit-sha>"])
```

Registrations merge over the baseline. Pinning the same repo to a *different* SHA than an
existing pin is a conflict (it would recreate the very collision pins prevent): it asserts
in debug, logs in release, and is refused. Every app that downloads a pinned repo must call
`revision(forRepoID:)`, or it fetches HEAD and can collide with a pinned sibling.

If the App Group is unavailable (missing entitlement, `configure` not called), the store
degrades to per-app Caches: the app keeps working, just without cross-app sharing (and logs
a one-time warning so the misconfiguration is visible).

## Testing

The store reads/writes fixed container paths, so tests point `root` at a temp directory
via an internal hook. Run them with a scratch path **outside** any iCloud-synced folder
(iCloud stamps extended attributes on build products, which breaks test-bundle signing):

```
swift test --scratch-path /tmp/sms-build
```

## License

MIT © 2026 Mark Friedlander
