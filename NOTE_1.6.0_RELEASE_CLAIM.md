# SharedModelStoreKit 1.6.0: releasing another app's claim. Note for the Thomas (AI Camera) team

**Date:** 2026-11-18 · **Made by:** Hal 4's session, a cross-family change, at Mark's decision.
**Status:** committed locally in the store's repo; tag 1.6.0 is NOT pushed yet (publishing waits for Mark).
**AI Camera is untouched.** Nothing in its code changed. If it does not adopt 1.6.0, nothing changes for it.

## Why (Mark, 2026-11-18)

Hal's Model Library offers "Release the claim of Posey" beside Delete, for an app the person has deleted. The store let an
app release only its own claim, so Hal's writer edited the store's `manifest.json` directly inside Hal. That is the kind
of drift the shared code exists to prevent. Mark: "If there's something missing from the code that is shared between
Thomas and Hal that covers the shared resources. We should have it fixed in both apps. ... The way to do that is to update
the shared code. And you should leave a note for the Thomas team so that they can make whatever changes they need to."

## What was added (additive; the existing API is unchanged)

```swift
@discardableResult
public static func releaseClaim(ofApp appID: String, modelID: String) -> Bool
```

- Releases the claim of the app whose bundle id is `appID` on `modelID`, in the store's own coordinated manifest write
  (`mutateManifest`, the same one `claim` and `releaseClaim` use). There is no second way to write the manifest.
- Returns `true` iff NO app still *live*ly claims the model afterwards, so its files are now no one's. The same answer
  `releaseClaim(modelID:)` gives.
- **It never deletes files**, exactly like `releaseClaim`. The store's existing rule is that the caller deletes, and only on
  `true`. (`reapStaleClaims` and `clearEntireSharedStore` are the only store functions that delete.)
- Same self-healing as `releaseClaim`: claimants whose heartbeat is provably stale are reaped in the same write; a missing
  heartbeat is never reaped. This app's heartbeat is stamped.
- An `appID` that holds no claim changes nothing; the answer is still whether a live claim remains. A model nobody claims
  returns `true`.
- `releaseClaim(modelID:)` now just calls `releaseClaim(ofApp: thisAppID, modelID:)`: one release path.
- Releasing a live app's claim is the caller's decision. That app claims the model again the next time it uses it.

## How an app adopts it

Only an app with UI for "release the claim of an app that is gone" needs it. Before calling, ask `claimants(modelID:)` so
the person can be told who holds the model and whether the files will go:

```swift
if SharedModelStore.releaseClaim(ofApp: appID, modelID: repoID) {   // true: no live claim left
    try? FileManager.default.removeItem(at: SharedModelStore.mlxModelDir(repoID))   // the app's own delete, once, after saying so
}
```

Move the package dependency to 1.6.0 once Mark has published the tag. Nothing else is required.

## Migration from an app-side workaround

If an app edits `manifest.json` itself (Hal 4 does, in `SharedModelClaims.release`), replace that body with the call
above and delete the hand-written JSON code. Behaviour differences to know: the store's write goes through its `Manifest`
type, which keeps every field the store knows (`models`, `claimedBy`, `repo`, `sizeBytes`, `heartbeats`); keys the store
does not know are not carried through a write by the store, as for every other store write today. Hal's workaround
preserved unknown keys by hand; the store's forward-compatibility rule is that fields are only ever added and are optional,
so there are none today.

## Tests

Six new tests in `SharedModelStoreTests.swift` (another app's claim released; the last claim, files left alone; an unknown
app and an unclaimed model; stale reaping; releasing one's own claim by name; twelve concurrent releases all land).
`swift test --scratch-path /tmp/sms-build`: 28 tests, 0 failures.
