# Version-Locked Models: The Shared Design (all three apps)

**Date:** 2026-07-24 (revised). For the implementers of Hal, Posey, and AI Camera.
This is the single contract all three apps follow so the shared model store is
version-safe. It **supersedes the earlier 2026-07-24 draft**, which described only the
strict path and did not account for Hal already having real users. If any app's behavior
disagrees with this document, the document is right and the code is wrong.

## The one rule that never bends
A model's identity is its **repo id plus its exact commit SHA**, never the bare repo id
and never "main". An app may use an on-disk copy only if it can prove that copy is the
exact commit it requires. "The folder exists" is not proof and is never again treated as
adoption.

## Where all three apps end up (identical)
Every app keys the store on the version-stamped identity for curated models, downloads at
the locked commit, and therefore shares exactly one copy of each locked version. Nothing
curated tracks a moving "main" again. **This destination is the same for all three.** The
only thing that differs is how each app gets there from where it stands today, and that
difference is invisible to sharing, because everyone lands on the same identities.

## The curated list is the whole guarantee
The package carries one list of supported models, each locked to one commit
(`baselinePinnedRevisions` in `SharedModelStore.swift`). Those are the only models the
family guarantees. Anything off the list is experimental: it still downloads and runs, but
the family does not manage its version or promise it loads.

## What the package already provides (built, tests green, call these)
The store keys paths, claims, the refcount manifest, and the sentinel on an opaque
`modelID` string, so version safety is achieved simply by passing the identity as that id.
1. `revision(forRepoID:)` — the locked commit for a curated repo, else "main".
2. `requiredIdentity(forRepoID:)` — the identity an app should use (locked commit folded in
   as `repo@sha`; bare repo id when unpinned). Pass this as the `modelID` to **every** store
   call (paths, claim/release, sentinel, size, backup-exclude) and the whole store becomes
   version-aware. This is the one call that makes an app version-safe.
3. `isLockedCopyReady(forRepoID:)` — true only when the exact locked copy has finished
   downloading. The adoption gate. Use a copy only when this is true.
4. `hasLegacyUnversionedCopy(forRepoID:)` — detects a pre-existing plain-name copy of
   unknown commit. For Hal's migration only.

## The hash is plumbing, never shown to a user
The `repo@sha` identity is a **storage key only**: it names the folder on disk and the entry
in the manifest, and it is what the code passes to the store. It is **never shown to a user.**
Every user-facing surface (the Model Library, the model picker, any status text) shows the
model's common name from the catalog, for example "Gemma 4 E2B" or "Qwen 3.5 2B", exactly as
today. The raw repo id and the commit hash stay out of the UI entirely. This holds for all
three apps.

## Plain-folder models (loaded by a library that uses plain names)
The stamped `repo@sha` folder exists for two reasons: to stop two apps colliding over a shared
model, and to tell a proven pinned copy apart from an old, unknown legacy copy. Some curated
models cannot use it: they are loaded by a library that finds the model by its PLAIN folder name
and cannot be pointed at a `repo@sha` folder. Those keep their plain `repo` folder and get their
version-safety from the download pin alone (they still fetch their locked commit; the pin applies
to the URL regardless of the folder name).

This is enforced in ONE place, the package: `SharedModelStore.plainFolderRepos`.
`requiredIdentity(forRepoID:)` returns the bare repo id for anything in that set, so every app
files these under the plain folder automatically, with no per-app special-casing (that per-app
divergence is exactly what caused the original drift). The set today:
- **sd-turbo** — AI Camera's drawer, loaded through a vendored Stable Diffusion library that
  resolves the plain folder name (`Load.swift`: `Hub.Repo(id:)` then `localRepoLocation`).
- **nomic-embed-text-v1.5** and **mxbai-embed-large-v1** — the embedders, loaded through the
  external `swift-embeddings` library (`loadModelBundle(from:downloadBase:)`), which likewise
  resolves the plain folder name.

Safe because two apps sharing a plain-folder model must agree on one version, which this single
curated list already guarantees, so a stamped folder would buy nothing.

**The embedders' pin does NOT reach the download (known gap).** `swift-embeddings` exposes no
revision parameter and snapshots `main`, so the embedders currently track "latest," not their
listed commit. Truly locking an embedder version is a separate, deliberate change (control the
fetch ourselves, or vendor the library) and is flagged, not done. They are still claimed
(claim-on-adopt in each app's embedder loader) so the delete-safety hole is closed.

**Future note (Mark, 2026-07-24):** Hal may later gain drawing, and sd-turbo would be its first
drawer, making sd-turbo shared. That stays fine under this scheme as long as both apps agree on
one pinned commit (they will, from the curated list): neither app has any old sd-turbo copy, so
both freshly fetch the same approved version into the one plain folder and co-own it. The only
thing to solve THEN is a coordinated version bump while both apps are live (a plain folder can't
hold two versions at once): either coordinate that bump, or teach the drawing code to load from a
stamped folder at that point. Revisit when drawing lands in Hal.

## Posey and AI Camera: strict, from scratch
Neither app has released, so neither has users or existing installs to protect. They
implement the rule directly, with **no migration**:
1. Pass `requiredIdentity(forRepoID:)` everywhere a bare repo id used to go.
2. Download every model at `revision(forRepoID:)`, for **both** the tree-listing URL and
   the file-resolve URL. **AI Camera: this is your required fix. You hard-code "main" in both
   URLs today (resolve and tree), so you ignore every pin, including the one that keeps you
   off the broken Gemma. Replace both.**
3. Adopt only when `isLockedCopyReady` is true. If it is not, download the locked identity
   into its own folder. Never adopt a bare or other-version copy.
4. Posey's adoption code is already written but uncommitted and unbuilt. It gets reviewed,
   built, device-tested, and committed. No behavior change beyond finishing that.

## Hal: version-aware, but migrate gradually
Hal has real users with models already on disk. It reaches the **same** destination without
forcing anyone to re-download. New downloads store at the locked identity (so they match the
siblings and share). For a model Hal already has, it resolves in this order:
1. **If the locked copy is present (from any app), use it.** Adopt it, claim the locked
   identity, release any old plain-name claim. On a device that also runs Posey or AI Camera,
   this migrates Hal for free the moment a sibling has fetched the locked copy.
2. **Otherwise, if an old un-versioned copy exists and the model is not Gemma, use it.** It
   works; it is grandfathered. It upgrades itself the next time it is re-downloaded (the user
   offloads and re-adds it, or it comes down again for any reason). Old copies are reaped once
   nothing claims them.
3. **Otherwise, download the locked identity.**

So a Hal user re-downloads nothing on day one. Models move to the locked version one at a
time, on their own schedule, and duplicates exist only briefly, for one model at a time,
before the old copy is reaped.

## Gemma is the one active exception
A genuinely broken Gemma is in the wild: the 2026-07-06 re-conversion, held by users who
downloaded Gemma between 2026-07-06 and the 2026-07-20 pin. A broken copy will not trigger
its own replacement; left alone, Hal keeps falling back to the same bad copy (today it
quietly drops to Bonsai). So Gemma is excluded from step 2 above. If the only Gemma on disk
is an old un-versioned copy, Hal fetches the locked good commit instead of trusting it
(step 3). Still lazy, only triggered when Gemma is actually reached for, just never trusting
the bad copy.

## Why sharing still works even though Hal migrates differently
Siblings never create plain-name copies. Hal's grandfathered plain copies are Hal-only and
temporary. Both paths converge on the same `repo@sha` identities, so the moment Hal moves a
model to the locked version it shares that one copy with the siblings and its old copy is
reaped. The per-app difference is only in the starting migration, never in the destination.
This is the reconciliation of the two directions that caused the earlier confusion: the
identity rule and the end state do not deviate per app; only Hal's gentleness toward its
existing installs does, and that is invisible to everyone else.

## Telling the user (Hal only)
Only Hal has users, so only Hal communicates this, in Hal's existing visual language (the
privacy-lock and thermal-indicator patterns):
- **Per-model version status in the Model Library.** Each curated model reads as one of:
  current tested version; older version, still working, updates on next download; or needs
  refresh (the broken-Gemma case). A small indicator with a tap-to-explain.
- **A plain first-run note** the first time the updated Hal launches, one short paragraph:
  Hal now locks models to specific tested versions, your existing models keep working, and
  they update themselves the next time they are downloaded.

Nothing fabricates the user's voice. Any in-thread surfacing uses a real system-event style,
not a fake user line. The exact UI and the exact copy are finalized when Hal is built; the
copy is Mark's to word.

## How each app proves it (on a real device, not just a compile)
1. Put a wrong-version copy on disk, need that model, confirm the app fetches and switches to
   the locked commit instead of adopting the wrong one.
2. Two apps on the same locked commit share one copy (the second adopts, zero re-download).
3. Hal only: an old un-versioned copy is preserved and used for a non-Gemma model, and for
   Gemma it is refused and the good commit fetched; the old copy is reaped once orphaned.

## Distribution (current reality)
The package is published as **1.0.1** and all three apps point at it (`upToNextMajorVersion`
from 1.0.1); those version bumps are already done in each Xcode project. Future fixes publish
as 1.0.2 and flow in with no per-app dependency edit. The repo is public, which is fine for
an MIT utility and is Mark's call to change.

## Build order
AI Camera first (it is the only app actively wrong today, and free to fix). Then Posey
(finish, verify, commit). Then Hal (the migration plus the user-facing part). Each app is
built and verified on a real device before the next is touched.
