# Version-Locked Adoption & Migration — Implementation Spec (all teams)
**Date:** 2026-07-24. For the CCs of Hal, Posey, and AI Camera. This is the contract every app
must implement so the shared store is version-safe. The package provides the mechanism; each app
must call it. Do NOT deviate per app — the whole point is that all three behave identically.

## The core rule
A model's identity is **repo id + exact commit SHA**, never just the repo id, and never "main".
An app may only use an on-disk copy if it can prove that copy is the exact commit it requires.
"The folder exists" is NOT proof and must never again be treated as adoption.

## What the package provides (BUILT — v-locked API, tests green; call these)
The store already keys paths, claims, the refcount manifest, and the sentinel on an opaque
`modelID` string, so version safety is achieved simply by using the IDENTITY (repo + commit) as
that id. No core rewrite; the apps switch which string they pass.
1. `revision(forRepoID:)` — the required commit for a curated repo (its locked SHA), else "main".
2. `modelIdentity(repo, revision:)` — folds the commit into the id: `repo@<sha>` when pinned, bare
   `repo` when unpinned/main (so legacy plain-name copies still resolve).
3. `requiredIdentity(forRepoID:)` — the identity an app SHOULD use for a curated repo (its locked
   commit folded in). **This is the one call that makes an app version-safe.** Use its return value
   as the `modelID` for EVERY store call: `mlxModelDir`, `claim`/`releaseClaim`,
   `markRepoComplete`/`isRepoComplete`, `sizeOnDisk`, `excludeFromBackup`. Two commits then become
   two folders, two claims, two sentinels — automatically.
4. `isLockedCopyReady(forRepoID:)` — the adoption gate: true only when the exact locked-commit copy
   has finished. Use a copy only when this is true, never because "a folder exists."
5. `hasLegacyUnversionedCopy(forRepoID:)` — detects a pre-existing plain-name copy of unknown
   commit, for the migration step below.

## What each app must change
1. **Use the identity, not the bare repo id.** Everywhere you currently pass a repo id to the store
   (paths, claim/release, sentinel, size, backup-exclude), pass
   `SharedModelStore.requiredIdentity(forRepoID: repo)` instead. That single swap folds the locked
   commit into the id, so the whole store becomes version-aware with no other bookkeeping.
2. **Download at the locked commit.** Every HF URL (tree-listing AND file-resolve) must use
   `SharedModelStore.revision(forRepoID: repo)`, not "main". **AI Camera: this is your required
   fix — you currently hard-code `main` in both the tree URL and the resolve URL, so you ignore the
   pins entirely. Replace both.** Write the sentinel at the identity path
   (`markRepoComplete(requiredIdentity(...))`) when the download verifies complete.
3. **Adopt only on a version match.** Gate use/adoption on
   `SharedModelStore.isLockedCopyReady(forRepoID: repo)`, never on "the folder exists." If it's not
   ready, download the locked identity into its own folder — do not adopt a bare/other-version copy.
4. **Reap the orphan.** After switching to the locked copy, release the old copy's claim (call
   `releaseClaim` with the OLD id); when a copy has zero claimants the package deletes it. This is
   what collapses the transient two-copy state (old wrong version + new locked) back to one copy.

## Legacy installs (already-downloaded, no recorded commit)
Preserve the existing plain-name folder and refcount it as **"legacy / unknown commit."** Never let
an unknown copy satisfy a locked SHA. The first time an app needs that model under the locked list,
it downloads the locked commit as a new `repo@<sha>` copy; once every app has moved over, the legacy
copy is orphaned and reaped. Nothing is force-deleted out from under a running app; no user loses a
model or eats a surprise re-download beyond the one locked model that needed it.

## How to test (each app, on a real device — not just compile)
1. Put a wrong-version copy on disk, then have the app need that model; confirm it downloads the
   locked commit and switches to it instead of adopting the wrong one.
2. Two apps on the same locked commit: confirm they share ONE copy (second app adopts, zero re-download).
3. Legacy copy present: confirm it's preserved, not trusted for a pin, and reaped once orphaned.

## Distribution
The package goes private and the reference (the tag/branch all apps point at) moves in place, so every
app re-adopts the fixed store on its next resolve with NO per-app dependency edit. Coordinate the
cut-over so all three land on the same package commit.
