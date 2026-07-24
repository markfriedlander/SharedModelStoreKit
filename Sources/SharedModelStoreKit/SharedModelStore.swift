// SharedModelStore.swift
// SharedModelStoreKit
//
// The ONE shared cross-app model-sharing contract for the AI family (Hal, Posey,
// AI Camera). This package replaces the three hand-copied clones of this file that
// had drifted apart (different ages, missing pieces, subtly different comments) —
// that drift is what caused the `clearHubCache` bug. Every app now imports this
// single module, so the App-Group id, the on-disk layout, the `manifest.json`
// format, the download-lock format, and the pinned revisions can never disagree.
//
// The shared container:
//   <AppGroup>/Models/huggingface/models/<repoID>/   <- MLX models + embedder assets
//   <AppGroup>/Models/manifest.json                  <- co-ownership ledger
//   <AppGroup>/Models/download-locks.json            <- one-app-downloads-at-a-time
//
// Model identity is the PLAIN HF repo id (e.g. "mlx-community/gemma-4-e2b-it-4bit"),
// used as BOTH the on-disk folder AND the manifest key — matching what every app
// already has on disk, so adopting this package needs no migration. Version safety
// (everyone downloads the same revision) comes from `pinnedRevisions`, not from a
// richer key. See Docs/Shared_Store_Package_Design_2026-07-24.md (in the Hal repo).
//
// ── The forward-compatibility rule (READ THIS before touching the on-disk format) ──
// Hal is already live. An un-updated app that writes the manifest will silently DROP
// any field it doesn't know (Swift Codable omits unknown keys on re-encode). So:
//   1. ONLY ADD fields, never remove or rename.
//   2. Any ADDED field MUST be Optional. A non-optional new field throws on decode of
//      an older manifest that lacks it, and `readManifest` treats a decode failure as
//      an EMPTY ledger — which would wipe every existing claim. Optional decodes as nil.
//   3. `claimedBy` stays the sole authority for delete-safety and is NEVER removed, so
//      an old app can't cause a wrongful delete no matter what it strips.

import Foundation

// MARK: - App-Group paths & on-disk presence

public enum SharedModelStore {

    // The App Group identifier is supplied by the CONSUMING APP, not hard-coded, so
    // this library is generic (reusable by any app family, not tied to one). Each app
    // calls `configure(appGroupID:)` ONCE at launch before touching the store. Until
    // it's set, the container is treated as unavailable and the store falls back to
    // per-app Caches (no sharing) rather than crashing. `nonisolated(unsafe)` because
    // it's a write-once-at-launch value read from anywhere; the launch-time contract,
    // not a lock, is what keeps it safe.
    nonisolated(unsafe) private static var _appGroupID: String = ""

    /// The shared App Group identifier this app was configured with. Empty until
    /// `configure(appGroupID:)` is called.
    public static var appGroupID: String { _appGroupID }

    /// Set the shared App Group id. Call once at app launch, before any store use.
    public static func configure(appGroupID: String) { _appGroupID = appGroupID }

    /// This app's stable identity for ownership claims. In practice the bundle id.
    public static var thisAppID: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    /// Whether the shared App-Group container is actually available to this app
    /// (entitlement present, not a bare Simulator, etc.). When false, `root` falls
    /// back to per-app Caches and cross-app sharing is simply off — never a crash.
    public static var isSharing: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    /// Test-only override of the store root. Internal (not part of the public
    /// contract) so tests can point every path at an isolated temp directory instead
    /// of the real App-Group container. `nil` in production. See the package tests.
    internal static var rootOverride: URL?

    /// Container root for shared models, under a `Models/` subfolder (part of the
    /// contract — every app must match it exactly). Fallback to per-app Caches if the
    /// container is unavailable, so the app keeps working without sharing.
    public static var root: URL {
        if let rootOverride { return rootOverride }
        #if DEBUG
        assert(!_appGroupID.isEmpty,
               "SharedModelStore.configure(appGroupID:) must be called at launch before using the store")
        #endif
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("Models", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// The HuggingFace-style cache root. What `HubApi(downloadBase:)` points at.
    public static var huggingFaceRoot: URL {
        root.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Directory for one MLX model id (`huggingface/models/<modelID>`).
    public static func mlxModelDir(_ modelID: String) -> URL {
        huggingFaceRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    /// "Is this repo present on disk?" — a non-empty repo directory. Truth-on-disk,
    /// independent of which app fetched it. A partial (mid-download) dir reads present,
    /// so callers that care also consult the downloader's in-flight state.
    public static func isRepoDownloaded(_ repo: String) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mlxModelDir(repo).path)) ?? []
        return !contents.isEmpty
    }

    /// Every repo id currently present on disk (org/name pairs with non-empty dirs).
    /// Skips dot-entries. Used by UI that lists installed models.
    public static func installedRepos() -> [String] {
        let base = huggingFaceRoot.appendingPathComponent("models", isDirectory: true)
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        var found: [String] = []
        for org in orgs where !org.hasPrefix(".") {
            let orgDir = base.appendingPathComponent(org, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: orgDir.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let repo = "\(org)/\(name)"
                if isRepoDownloaded(repo) { found.append(repo) }
            }
        }
        return found.sorted()
    }

    /// Total bytes a repo occupies on disk (recursive). Used by UI that shows sizes.
    public static func sizeOnDisk(_ repo: String) -> Int64 {
        let dir = mlxModelDir(repo)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: completion sentinel
    //
    // A dot-file written into a model's dir the instant its download is verified
    // complete. Its PRESENCE is the durable "this finished" signal (distinct from
    // `isRepoDownloaded`, which is true for a merely non-empty/partial dir). NOT a
    // load-gate: a model fetched by a sibling app is loadable even without a sentinel.
    //
    // Filename kept as `.hal-download-complete` for COMPATIBILITY: Hal has already
    // written sentinels by this name on live devices; renaming would orphan them and
    // make already-downloaded models re-read as incomplete. Shared now, legacy name.
    public static let completeSentinelName = ".hal-download-complete"

    /// Mark a model VERIFIED COMPLETE (call only from the success finalizer).
    public static func markRepoComplete(_ repo: String) {
        let dir = mlxModelDir(repo)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sentinel = dir.appendingPathComponent(completeSentinelName)
        FileManager.default.createFile(atPath: sentinel.path, contents: Data())
    }

    /// Whether a model's download actually COMPLETED (sentinel present).
    public static func isRepoComplete(_ repo: String) -> Bool {
        let sentinel = mlxModelDir(repo).appendingPathComponent(completeSentinelName)
        return FileManager.default.fileExists(atPath: sentinel.path)
    }

    /// Exclude a model dir from iCloud backup. MANDATORY for App-Group containers
    /// (unlike Caches, they ARE backed up by default → multi-GB quota burn, App
    /// Review 2.5.1). Idempotent.
    public static func excludeFromBackup(_ modelID: String) {
        var dir = mlxModelDir(modelID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}

// MARK: - Refcount manifest + LEASES

extension SharedModelStore {

    /// How long since an app was last seen before its claims may be reaped. 30 days
    /// (Mark, 2026-07-24): an app in genuine use is opened at least monthly (each
    /// launch refreshes its heartbeat), so this only catches uninstalled/abandoned
    /// apps. If we ever guess wrong, the sole consequence is a re-download — never
    /// lost data. Lives here so all apps agree on it.
    public static let leaseTTLSeconds: TimeInterval = 30 * 24 * 60 * 60

    private static var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    private struct Manifest: Codable {
        var version: Int = 1
        var models: [String: Entry] = [:]
        /// NEW (leases): appID → epoch seconds of that app's last launch/touch.
        /// OPTIONAL on purpose — see the forward-compatibility rule up top; a missing
        /// key must decode as nil, not throw. Absence = "we have no liveness info,"
        /// which the reap rule treats conservatively (never reap).
        var heartbeats: [String: Double]?

        struct Entry: Codable {
            var claimedBy: [String] = []   // bundle ids — the delete-safety authority
            var repo: String?              // hf repo id (recorded for cross-app match)
            var sizeBytes: Int64?
        }
    }

    /// Record that THIS app uses `modelID`, and stamp our heartbeat. Called on a
    /// completed download and when the app first loads/adopts a model already present
    /// in the shared container. Idempotent.
    public static func claim(modelID: String, repo: String? = nil, sizeBytes: Int64? = nil) {
        mutateManifest { m in
            var e = m.models[modelID] ?? Manifest.Entry()
            if !e.claimedBy.contains(thisAppID) { e.claimedBy.append(thisAppID) }
            if let repo { e.repo = repo }
            if let sizeBytes { e.sizeBytes = sizeBytes }
            m.models[modelID] = e
            stampHeartbeat(&m)
        }
    }

    /// Release THIS app's claim on `modelID`. Returns `true` iff NO app still *live*ly
    /// claims it — i.e. it is now safe to delete the files. The caller deletes ONLY on
    /// `true`. Also self-heals: any claimant whose heartbeat is provably stale (older
    /// than the lease) is reaped here (the immortal-claim fix).
    @discardableResult
    public static func releaseClaim(modelID: String) -> Bool {
        var safeToDelete = false
        mutateManifest { m in
            stampHeartbeat(&m)   // we're alive right now
            guard var e = m.models[modelID] else { safeToDelete = true; return }
            e.claimedBy.removeAll { $0 == thisAppID }
            // Reap provably-dead claimants (stale heartbeat). Missing heartbeat is
            // NOT reaped — see the conservative rule in `isClaimantLive`.
            e.claimedBy.removeAll { !isClaimantLive($0, m.heartbeats) }
            if e.claimedBy.isEmpty {
                m.models.removeValue(forKey: modelID)
                safeToDelete = true
            } else {
                m.models[modelID] = e
            }
        }
        return safeToDelete
    }

    /// Read-only: which apps *live*ly claim `modelID` (stale ones filtered out). Used
    /// for diagnostics and "also used by …" UI. Never writes, so it doesn't reap.
    public static func claimants(modelID: String) -> [String] {
        let m = readManifest(NSFileCoordinator())
        guard let e = m.models[modelID] else { return [] }
        return e.claimedBy.filter { isClaimantLive($0, m.heartbeats) }
    }

    /// Read-only: every model id THIS app currently claims. The manifest is the
    /// authority here, never the disk — a model present in the container that this app
    /// hasn't claimed is not ours to release or delete.
    public static func modelsClaimedByThisApp() -> [String] {
        readManifest(NSFileCoordinator()).models
            .filter { $0.value.claimedBy.contains(thisAppID) }
            .map(\.key)
            .sorted()
    }

    /// Stamp THIS app's heartbeat without touching any claim. Call once on launch (or
    /// any time the app becomes active) so a busy app that isn't downloading still
    /// proves it's alive and keeps its existing claims from being reaped.
    public static func touchHeartbeat() {
        mutateManifest { m in stampHeartbeat(&m) }
    }

    /// A human display name for a family app's bundle id ("also used by AI Camera").
    /// Derived, not a table: every app is `com.MarkFriedlander.<AppName>`, so a new
    /// sibling names itself correctly the day it ships. Falls back to a generic phrase.
    public static func displayName(forAppID appID: String) -> String {
        guard let last = appID.split(separator: ".").last, !last.isEmpty else {
            return "another app"
        }
        return last.replacingOccurrences(of: "-", with: " ")
    }

    /// Optional-tolerant overload (some call sites pass an optional id).
    public static func displayName(forAppID appID: String?) -> String {
        guard let appID else { return "another app" }
        return displayName(forAppID: appID)
    }

    /// Short holder name for the "Downloading in …" status. Fully DERIVED from the
    /// bundle id (no hard-coded app table — that would tie this generic library to one
    /// family's names). "com.MarkFriedlander.Hal-Universal" → "Hal Universal", etc.
    public static func appDisplayName(_ bundleID: String?) -> String {
        displayName(forAppID: bundleID)
    }

    // MARK: lease helpers

    /// Whether a claimant should be treated as still present. CONSERVATIVE by design:
    /// reap ONLY on positive evidence of death (a heartbeat that exists AND is older
    /// than the lease). A MISSING heartbeat means "we don't know" — which happens
    /// right after an un-updated app wrote the manifest and stripped all heartbeats —
    /// and must NEVER trigger a reap, or an old app's write would cascade into
    /// wrongful deletions. Missing ⇒ live. This is what makes the rollout safe.
    private static func isClaimantLive(_ appID: String, _ heartbeats: [String: Double]?) -> Bool {
        guard let seen = heartbeats?[appID] else { return true }   // unknown ⇒ live
        return (nowEpoch() - seen) <= leaseTTLSeconds
    }

    private static func stampHeartbeat(_ m: inout Manifest) {
        var hb = m.heartbeats ?? [:]
        hb[thisAppID] = nowEpoch()
        m.heartbeats = hb
    }

    private static func nowEpoch() -> Double { Date().timeIntervalSince1970 }

    // MARK: coordinated read / write

    private static func readManifest(_ coordinator: NSFileCoordinator) -> Manifest {
        var result = Manifest()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: manifestURL, options: [], error: &coordError) { url in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    private static func mutateManifest(_ body: (inout Manifest) -> Void) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: manifestURL, options: [], error: &coordError) { url in
            var manifest = Manifest()
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(Manifest.self, from: data) {
                manifest = decoded
            }
            body(&manifest)
            if let out = try? JSONEncoder().encode(manifest) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - Cross-app download lock

extension SharedModelStore {

    /// A lock older than this (no refresh) is treated as abandoned. 10 minutes: long
    /// enough that a slow live background download isn't stolen, short enough that a
    /// genuine crash frees the slot in tolerable time. (Distinct from the claim lease
    /// above — this is the short-lived per-download slot, refreshed every progress tick.)
    public static let downloadLockStaleSeconds: TimeInterval = 600

    private static var downloadLocksURL: URL { root.appendingPathComponent("download-locks.json") }

    private struct DownloadLocks: Codable {
        var version: Int = 1
        var locks: [String: Lock] = [:]
        struct Lock: Codable {
            var holder: String   // bundle id of the app currently downloading
            var since: Double    // epoch seconds; refreshed by the live holder
        }
    }

    /// Current lock record for `modelID`, or nil if free. Does not consider staleness.
    public static func downloadLock(modelID: String) -> (holder: String, since: Double)? {
        guard let l = readDownloadLocks(NSFileCoordinator()).locks[modelID] else { return nil }
        return (l.holder, l.since)
    }

    /// Atomic test-and-set of the download slot for `modelID`. Granted if the slot is
    /// free, already ours, or the current lock is stale. False only when another app
    /// holds a fresh lock (caller should wait and adopt rather than duplicate).
    public static func acquireDownloadLock(modelID: String) -> Bool {
        var granted = false
        mutateDownloadLocks { db in
            if let l = db.locks[modelID],
               l.holder != thisAppID,
               (nowEpoch() - l.since) < downloadLockStaleSeconds {
                granted = false
                return
            }
            db.locks[modelID] = DownloadLocks.Lock(holder: thisAppID, since: nowEpoch())
            granted = true
        }
        return granted
    }

    /// Bump our lock's timestamp so a live foreground download isn't judged stale.
    public static func refreshDownloadLock(modelID: String) {
        mutateDownloadLocks { db in
            guard var l = db.locks[modelID], l.holder == thisAppID else { return }
            l.since = nowEpoch()
            db.locks[modelID] = l
        }
    }

    /// Release our lock (no-op if we don't hold it). Call on complete, cancel, failure.
    public static func releaseDownloadLock(modelID: String) {
        mutateDownloadLocks { db in
            if db.locks[modelID]?.holder == thisAppID {
                db.locks.removeValue(forKey: modelID)
            }
        }
    }

    // MARK: coordinated read / write (mirrors the manifest's discipline)

    private static func readDownloadLocks(_ coordinator: NSFileCoordinator) -> DownloadLocks {
        var result = DownloadLocks()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: downloadLocksURL, options: [], error: &coordError) { url in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(DownloadLocks.self, from: data) else { return }
            result = decoded
        }
        return result
    }

    private static func mutateDownloadLocks(_ body: (inout DownloadLocks) -> Void) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: downloadLocksURL, options: [], error: &coordError) { url in
            var db = DownloadLocks()
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(DownloadLocks.self, from: data) {
                db = decoded
            }
            body(&db)
            if let out = try? JSONEncoder().encode(db) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: test-only helpers (drive a DOWNLOAD_LOCK diagnostic verb)

    #if DEBUG
    /// Plant a "another app holds the lock" state to exercise the wait/adopt path
    /// on-device without a second real app. Production sharing never calls these.
    public static func debugPlantForeignLock(modelID: String, holder: String, ageSeconds: Double = 0) {
        mutateDownloadLocks { db in
            db.locks[modelID] = DownloadLocks.Lock(holder: holder, since: nowEpoch() - ageSeconds)
        }
    }

    public static func debugClearAllDownloadLocks() {
        mutateDownloadLocks { db in db.locks.removeAll() }
    }

    public static func debugAllDownloadLocks() -> [(modelID: String, holder: String, ageSeconds: Double)] {
        readDownloadLocks(NSFileCoordinator()).locks.map {
            ($0.key, $0.value.holder, nowEpoch() - $0.value.since)
        }
    }
    #endif
}

// MARK: - Pinned model revisions

extension SharedModelStore {

    // Curated models pinned to a specific HF revision (commit SHA) so an upstream
    // re-conversion can't silently break a shipped build — and, now that this lives in
    // the SHARED package, so no sibling can download a broken HEAD that another app
    // then adopts. Any repo not listed tracks `main` (HEAD). Moved here from Hal's
    // MLXModelDownloader; each app's downloader applies it via `revision(forRepoID:)`.
    public static let pinnedRevisions: [String: String] = [
        // gemma-4-e2b-it-4bit: last revision before the 2026-07-06 re-conversion
        // (2026-05-19) that broke loading. Full story: Hal HISTORY 2026-07-20.
        "mlx-community/gemma-4-e2b-it-4bit": "2c3e507453b4f218d05fe3cc97bea5c5a654257e"
    ]

    /// The HF revision to download `repoID` at: the pinned SHA if pinned, else "main".
    public static func revision(forRepoID repoID: String) -> String {
        pinnedRevisions[repoID] ?? "main"
    }
}
