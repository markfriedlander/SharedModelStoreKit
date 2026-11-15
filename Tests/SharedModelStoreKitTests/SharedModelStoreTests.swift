import XCTest
@testable import SharedModelStoreKit

/// These tests exercise the properties that MUST hold for the rollout to be safe,
/// using an isolated temp directory as the store root and planting `manifest.json`
/// by hand to simulate other apps and older formats. The bar: never wipe the ledger,
/// never wrongly delete a model another app still claims, reap ONLY on proven staleness.
final class SharedModelStoreTests: XCTestCase {

    var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("smstest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        SharedModelStore.rootOverride = tempRoot
        SharedModelStore.registeredPins = [:]   // isolate pin registrations per test
    }

    override func tearDownWithError() throws {
        SharedModelStore.rootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Write a raw manifest.json into the temp root (bypasses the private API so we
    /// can plant arbitrary claimants/heartbeats, i.e. "other apps").
    private func writeManifest(_ json: String) throws {
        let url = tempRoot.appendingPathComponent("manifest.json")
        try json.data(using: .utf8)!.write(to: url)
    }

    private func now() -> Double { Date().timeIntervalSince1970 }
    private let day: Double = 24 * 60 * 60

    // 1. An OLD manifest (no `heartbeats` key at all) must read fine and preserve
    //    every claim — a decode failure here would be read as an empty ledger and
    //    wipe everyone's claims.
    func testOldManifestWithoutHeartbeatsPreservesClaims() throws {
        try writeManifest(#"""
        {"version":1,"models":{"org/repoX":{"claimedBy":["com.x.A","com.x.B"]}}}
        """#)
        let claimants = SharedModelStore.claimants(modelID: "org/repoX")
        XCTAssertEqual(Set(claimants), ["com.x.A", "com.x.B"],
                       "old-format manifest must decode and keep all claims; missing heartbeat ⇒ live")
    }

    // 2. Reaping is conservative: a proven-stale claimant is dropped, a fresh one is
    //    kept, and a claimant with NO heartbeat is kept (unknown ⇒ live).
    func testReapDropsStaleKeepsFreshAndUnknown() throws {
        let hbStale = now() - 40 * day     // > 30-day lease
        let hbFresh = now() - 1 * day
        try writeManifest("""
        {"version":1,"models":{"org/repoX":{"claimedBy":["stale","fresh","nohb"]}},
         "heartbeats":{"stale":\(hbStale),"fresh":\(hbFresh)}}
        """)
        let live = SharedModelStore.claimants(modelID: "org/repoX")
        XCTAssertEqual(Set(live), ["fresh", "nohb"],
                       "stale reaped; fresh kept; missing-heartbeat kept (conservative)")
    }

    // 3. releaseClaim reaps a stale co-claimant and reports safe-to-delete when no
    //    LIVE claimant remains.
    func testReleaseReapsStaleAndReportsSafeToDelete() throws {
        let me = SharedModelStore.thisAppID
        let hbStale = now() - 40 * day
        try writeManifest("""
        {"version":1,"models":{"org/repoX":{"claimedBy":["\(me)","stale"]}},
         "heartbeats":{"stale":\(hbStale)}}
        """)
        let safe = SharedModelStore.releaseClaim(modelID: "org/repoX")
        XCTAssertTrue(safe, "after we release and the only other claimant is stale, it's safe to delete")
        XCTAssertTrue(SharedModelStore.claimants(modelID: "org/repoX").isEmpty,
                      "the model entry should be gone")
    }

    // 4. The core invariant: never report safe-to-delete while another LIVE app claims.
    func testReleaseDoesNotDeleteWhileLiveCoOwnerRemains() throws {
        let me = SharedModelStore.thisAppID
        let hbFresh = now() - 1 * day
        try writeManifest("""
        {"version":1,"models":{"org/repoX":{"claimedBy":["\(me)","liveApp"]}},
         "heartbeats":{"liveApp":\(hbFresh)}}
        """)
        let safe = SharedModelStore.releaseClaim(modelID: "org/repoX")
        XCTAssertFalse(safe, "a live co-owner must keep the files safe")
        XCTAssertEqual(SharedModelStore.claimants(modelID: "org/repoX"), ["liveApp"])
    }

    // 5. Plain round-trip on an empty store: claim → we're a claimant → release → gone.
    func testClaimReleaseRoundTrip() throws {
        SharedModelStore.claim(modelID: "org/repoY", repo: "org/repoY", sizeBytes: 123)
        XCTAssertTrue(SharedModelStore.claimants(modelID: "org/repoY").contains(SharedModelStore.thisAppID))
        XCTAssertTrue(SharedModelStore.modelsClaimedByThisApp().contains("org/repoY"))
        let safe = SharedModelStore.releaseClaim(modelID: "org/repoY")
        XCTAssertTrue(safe, "we were the only claimant, so it's safe to delete")
        XCTAssertTrue(SharedModelStore.claimants(modelID: "org/repoY").isEmpty)
    }

    // 6. touchHeartbeat stamps us without creating any claim.
    func testTouchHeartbeatKeepsOurClaimsAlive() throws {
        SharedModelStore.claim(modelID: "org/repoZ")
        SharedModelStore.touchHeartbeat()   // should not throw / should not add claims
        XCTAssertEqual(SharedModelStore.modelsClaimedByThisApp(), ["org/repoZ"])
    }

    // 7b. configure(appGroupID:) sets the app-supplied group id (generic library).
    func testConfigureSetsAppGroupID() {
        SharedModelStore.configure(appGroupID: "group.com.example.test")
        XCTAssertEqual(SharedModelStore.appGroupID, "group.com.example.test")
    }

    // 7. Revision pin resolves baseline pinned vs unpinned.
    func testRevisionPin() {
        XCTAssertEqual(SharedModelStore.revision(forRepoID: "mlx-community/gemma-4-e2b-it-4bit"),
                       "2c3e507453b4f218d05fe3cc97bea5c5a654257e")
        XCTAssertEqual(SharedModelStore.revision(forRepoID: "some/unpinned-repo"), "main")
    }

    // 8. A registered pin merges over the baseline; a re-registered identical SHA is a
    //    harmless no-op. (The conflicting-SHA path asserts by design, so it isn't unit
    //    tested here — asserting would crash the debug test runner.)
    func testRegisterPinMergesAndSameSHAIsNoOp() {
        SharedModelStore.registerPinnedRevisions(["some/new-repo": "deadbeef"])
        XCTAssertEqual(SharedModelStore.revision(forRepoID: "some/new-repo"), "deadbeef")
        // baseline still resolves
        XCTAssertEqual(SharedModelStore.revision(forRepoID: "mlx-community/gemma-4-e2b-it-4bit"),
                       "2c3e507453b4f218d05fe3cc97bea5c5a654257e")
        // re-registering the SAME sha is fine (no conflict)
        SharedModelStore.registerPinnedRevisions(["some/new-repo": "deadbeef"])
        XCTAssertEqual(SharedModelStore.revision(forRepoID: "some/new-repo"), "deadbeef")
        XCTAssertTrue(SharedModelStore.pinnedRevisions["some/new-repo"] == "deadbeef")
    }

    // 9. Identity folds the locked commit into a pinned repo's id, and leaves an
    //    unpinned repo bare (legacy behavior).
    func testModelIdentity() {
        let gemma = "mlx-community/gemma-4-e2b-it-4bit"
        XCTAssertEqual(SharedModelStore.requiredIdentity(forRepoID: gemma),
                       "\(gemma)@2c3e507453b4f218d05fe3cc97bea5c5a654257e")
        XCTAssertEqual(SharedModelStore.requiredIdentity(forRepoID: "some/unpinned"), "some/unpinned")
        XCTAssertEqual(SharedModelStore.modelIdentity("a/b", revision: "main"), "a/b")
        XCTAssertEqual(SharedModelStore.modelIdentity("a/b", revision: ""), "a/b")
        XCTAssertEqual(SharedModelStore.modelIdentity("a/b", revision: "abc123"), "a/b@abc123")
    }

    // 9b. Plain-folder models (a library loads them by plain name) keep their BARE id from
    //     requiredIdentity even though they are pinned, so they file under their plain folder.
    //     The pin still applies to the download URL; a normal pinned repo still folds its commit.
    func testPlainFolderReposStayBare() {
        let sdTurbo = "stabilityai/sd-turbo"
        let nomic = "nomic-ai/nomic-embed-text-v1.5"
        // They ARE pinned (the pin still governs which commit is downloaded) ...
        XCTAssertNotEqual(SharedModelStore.revision(forRepoID: sdTurbo), "main")
        XCTAssertNotEqual(SharedModelStore.revision(forRepoID: nomic), "main")
        // ... but their storage identity stays the plain repo id (no @sha folder).
        XCTAssertEqual(SharedModelStore.requiredIdentity(forRepoID: sdTurbo), sdTurbo)
        XCTAssertEqual(SharedModelStore.requiredIdentity(forRepoID: nomic), nomic)
        // So there is no stamped-vs-legacy split for them.
        XCTAssertFalse(SharedModelStore.hasLegacyUnversionedCopy(forRepoID: sdTurbo))
        // A normal pinned repo still stamps its commit.
        let gemma = "mlx-community/gemma-4-e2b-it-4bit"
        XCTAssertEqual(SharedModelStore.requiredIdentity(forRepoID: gemma),
                       "\(gemma)@2c3e507453b4f218d05fe3cc97bea5c5a654257e")
    }

    // 10. The locked copy is "ready" only when the required-commit identity's sentinel is
    //     present; a bare plain-name copy of a pinned repo is a legacy/unknown copy that
    //     does NOT satisfy the lock.
    func testLockedCopyReadyAndLegacyDetection() {
        let gemma = "mlx-community/gemma-4-e2b-it-4bit"
        // nothing on disk yet
        XCTAssertFalse(SharedModelStore.isLockedCopyReady(forRepoID: gemma))
        XCTAssertFalse(SharedModelStore.hasLegacyUnversionedCopy(forRepoID: gemma))
        // simulate a legacy plain-name copy (unknown commit)
        try? FileManager.default.createDirectory(at: SharedModelStore.mlxModelDir(gemma),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: SharedModelStore.mlxModelDir(gemma).appendingPathComponent("weights.bin").path,
            contents: Data([0x01]))
        XCTAssertTrue(SharedModelStore.hasLegacyUnversionedCopy(forRepoID: gemma))
        XCTAssertFalse(SharedModelStore.isLockedCopyReady(forRepoID: gemma), "legacy copy must not satisfy the lock")
        // now the locked identity finishes downloading
        SharedModelStore.markRepoComplete(SharedModelStore.requiredIdentity(forRepoID: gemma))
        XCTAssertTrue(SharedModelStore.isLockedCopyReady(forRepoID: gemma))
    }

    // 1.4.0: isRepoReady is the one answer to "can a person choose it / can it load".
    // The case that motivated it: a download cut off by a kill left a partial folder every app
    // read as installed (AI Camera on Mark's Mac, 2026-11-13; Hal 4 item 53 before that).
    func testReadyNeedsAFinishedOrLegacyCopyAndNothingInFlight() throws {
        let repo = "stabilityai/sd-turbo"
        let dir = SharedModelStore.mlxModelDir(repo)
        // 2. nothing on disk
        XCTAssertFalse(SharedModelStore.isRepoReady(repo))
        // a download starts: only the marker is there, which is not a model file
        SharedModelStore.markDownloadStarted(repo)
        XCTAssertTrue(SharedModelStore.isDownloadUnfinished(repo))
        XCTAssertFalse(SharedModelStore.isRepoDownloaded(repo), "the store's own marker is not a model file")
        XCTAssertFalse(SharedModelStore.isRepoReady(repo))
        // 3. some files land, then the app is killed: files on disk, marker still there
        FileManager.default.createFile(atPath: dir.appendingPathComponent("unet.safetensors").path, contents: Data([1]))
        XCTAssertTrue(SharedModelStore.isRepoDownloaded(repo), "files are on disk")
        XCTAssertFalse(SharedModelStore.isRepoReady(repo), "a cut-off download must not read ready")
        // 1. the download finishes: sentinel written, marker cleared
        SharedModelStore.markRepoComplete(repo)
        XCTAssertFalse(SharedModelStore.isDownloadUnfinished(repo))
        XCTAssertTrue(SharedModelStore.isRepoReady(repo))
    }

    func testLegacyCopyWithoutMarkersStaysReadyUnlessSomeoneIsFetchingIt() throws {
        let repo = "mlx-community/legacy-model"
        try plantModelFile(repo)          // 5. files, no sentinel, no marker: from before markers
        XCTAssertTrue(SharedModelStore.isRepoReady(repo), "a loadable legacy copy is not taken away")
        // 4. another app holds a fresh download lock on it: not ready while it is being fetched
        SharedModelStore.debugPlantForeignLock(modelID: repo, holder: "com.example.sibling", ageSeconds: 5)
        XCTAssertFalse(SharedModelStore.isRepoReady(repo))
        // a stale lock (its holder died long ago) no longer blocks it
        SharedModelStore.debugPlantForeignLock(modelID: repo, holder: "com.example.sibling",
                                               ageSeconds: SharedModelStore.downloadLockStaleSeconds + 60)
        XCTAssertTrue(SharedModelStore.isRepoReady(repo))
    }

    // 1.5.0: a declared file list makes "finished" mean every file whole, checked by the store itself.
    // The case that motivated it: AI Camera's downloader (a copy of Hal's) wrote the sentinel after a
    // relaunch when only the first of several files had landed (independent review, 2026-11-14).
    func testCompleteIsRefusedUntilEveryDeclaredFileIsWhole() throws {
        let repo = "mlx-community/declared-model"
        let dir = SharedModelStore.mlxModelDir(repo)
        SharedModelStore.markDownloadStarted(repo, expecting: ["config.json": 3, "model.safetensors": 5, "tokenizer.json": 0])
        XCTAssertEqual(SharedModelStore.expectedFiles(repo)?.count, 3)
        XCTAssertEqual(SharedModelStore.problemFiles(repo).count, 3)
        // the first file lands; the downloader wrongly believes it is done
        FileManager.default.createFile(atPath: dir.appendingPathComponent("config.json").path, contents: Data([1, 2, 3]))
        XCTAssertFalse(SharedModelStore.markRepoComplete(repo), "two files are still missing")
        XCTAssertFalse(SharedModelStore.isRepoComplete(repo))
        XCTAssertTrue(SharedModelStore.isDownloadUnfinished(repo), "the folder stays begun, not finished")
        XCTAssertFalse(SharedModelStore.isRepoReady(repo))
        // an error page saved in place of the weights: the wrong size
        FileManager.default.createFile(atPath: dir.appendingPathComponent("model.safetensors").path, contents: Data([9]))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("tokenizer.json").path, contents: Data([7]))
        XCTAssertEqual(SharedModelStore.problemFiles(repo), ["model.safetensors": "1 bytes, expected 5"])
        XCTAssertFalse(SharedModelStore.markRepoComplete(repo))
        // the real weights arrive: whole, so finished
        FileManager.default.createFile(atPath: dir.appendingPathComponent("model.safetensors").path, contents: Data([1, 2, 3, 4, 5]))
        XCTAssertTrue(SharedModelStore.markRepoComplete(repo))
        XCTAssertTrue(SharedModelStore.isRepoReady(repo))
        // later a file goes missing from the finished copy: not ready, so no app loads a broken model
        try FileManager.default.removeItem(at: dir.appendingPathComponent("tokenizer.json"))
        XCTAssertTrue(SharedModelStore.isRepoComplete(repo), "the sentinel is still there")
        XCTAssertFalse(SharedModelStore.isRepoReady(repo))
        XCTAssertEqual(SharedModelStore.problemFiles(repo), ["tokenizer.json": "missing"])
    }

    // An app on an older downloader starts the same folder with no list: the old list must not judge
    // its file set (which may differ), so the plain start removes it and completion works as in 1.4.0.
    func testPlainStartDropsAStaleListAndCompletesAsBefore() throws {
        let repo = "mlx-community/shared-folder"
        SharedModelStore.markDownloadStarted(repo, expecting: ["only-in-the-first-apps-list.bin": 10])
        SharedModelStore.markDownloadStarted(repo)
        XCTAssertNil(SharedModelStore.expectedFiles(repo))
        try plantModelFile(repo)
        XCTAssertTrue(SharedModelStore.markRepoComplete(repo))
        XCTAssertTrue(SharedModelStore.isRepoReady(repo))
    }

    // The list is a dot-file: not a model file, so it never makes an empty folder read "downloaded".
    func testDeclaredListAloneIsNotAModel() {
        let repo = "mlx-community/list-only"
        SharedModelStore.markDownloadStarted(repo, expecting: ["a.bin": 1])
        XCTAssertFalse(SharedModelStore.isRepoDownloaded(repo))
        XCTAssertTrue(SharedModelStore.installedRepos().isEmpty)
    }

    // MARK: - active launch maintenance (dead-app cleanup)

    /// Plant a non-empty model dir on disk so isRepoDownloaded == true.
    private func plantModelFile(_ repoID: String) throws {
        let dir = SharedModelStore.mlxModelDir(repoID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("weights.bin").path,
                                       contents: Data([0x01]))
    }

    /// Read the raw manifest.json back as a dictionary (heartbeats/models are private).
    private func rawManifest() throws -> [String: Any] {
        let url = tempRoot.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // reapStaleClaims: a model claimed ONLY by a stale app has its files deleted and its
    // entry removed; a model with a fresh, or a missing-heartbeat, claimant is untouched.
    func testReapDeletesStaleOnlyModelAndKeepsOthers() throws {
        let hbStale = now() - 40 * day
        let hbFresh = now() - 1 * day
        try writeManifest("""
        {"version":1,"models":{
          "org/dead":{"claimedBy":["ghost"]},
          "org/live":{"claimedBy":["liveApp"]},
          "org/unknown":{"claimedBy":["nohbApp"]}},
         "heartbeats":{"ghost":\(hbStale),"liveApp":\(hbFresh)}}
        """)
        try plantModelFile("org/dead")
        try plantModelFile("org/live")
        try plantModelFile("org/unknown")

        let deleted = SharedModelStore.reapStaleClaims()

        XCTAssertEqual(deleted, ["org/dead"], "only the stale-only model is reaped")
        XCTAssertFalse(SharedModelStore.isRepoDownloaded("org/dead"), "dead model files removed")
        XCTAssertTrue(SharedModelStore.isRepoDownloaded("org/live"), "live model kept")
        XCTAssertTrue(SharedModelStore.isRepoDownloaded("org/unknown"),
                      "missing-heartbeat model kept, grace handles it, not the reap")
    }

    // reapStaleClaims must NOT reap a model with a live co-claimant; it just drops the stale one.
    func testReapKeepsModelWithLiveCoClaimant() throws {
        let hbStale = now() - 40 * day
        let hbFresh = now() - 1 * day
        try writeManifest("""
        {"version":1,"models":{"org/repoX":{"claimedBy":["ghost","liveApp"]}},
         "heartbeats":{"ghost":\(hbStale),"liveApp":\(hbFresh)}}
        """)
        try plantModelFile("org/repoX")
        let deleted = SharedModelStore.reapStaleClaims()
        XCTAssertTrue(deleted.isEmpty, "a live co-claimant keeps the model")
        XCTAssertTrue(SharedModelStore.isRepoDownloaded("org/repoX"))
        XCTAssertEqual(SharedModelStore.claimants(modelID: "org/repoX"), ["liveApp"],
                       "stale co-claimant dropped")
    }

    // graceStampMissingHeartbeats stamps a heartbeat-less claimant so it's no longer immortal.
    func testGraceStampWritesHeartbeatForMissing() throws {
        try writeManifest(#"""
        {"version":1,"models":{"org/repoX":{"claimedBy":["nohbApp"]}}}
        """#)
        SharedModelStore.graceStampMissingHeartbeats()
        let hb = try rawManifest()["heartbeats"] as? [String: Any] ?? [:]
        XCTAssertNotNil(hb["nohbApp"], "grace-stamp gives the pre-lease claimant a heartbeat")
        if let stamp = (hb["nohbApp"] as? NSNumber)?.doubleValue {
            XCTAssertEqual(stamp, now(), accuracy: 5, "stamped ~now")
        }
        // Freshly stamped ⇒ still live, so an immediate reap must NOT drop it.
        try plantModelFile("org/repoX")
        XCTAssertTrue(SharedModelStore.reapStaleClaims().isEmpty,
                      "a freshly grace-stamped claim survives the reap")
    }

    // clearEntireSharedStore deletes ALL model files AND empties the manifest (no ghosts).
    func testClearEntireSharedStoreWipesFilesAndManifest() throws {
        try writeManifest("""
        {"version":1,"models":{
          "org/a":{"claimedBy":["appA"]},
          "org/b":{"claimedBy":["appB"]}},
         "heartbeats":{"appA":\(now()),"appB":\(now())}}
        """)
        try plantModelFile("org/a")
        try plantModelFile("org/b")

        let count = SharedModelStore.clearEntireSharedStore()

        XCTAssertEqual(count, 2, "reports both repos removed")
        XCTAssertFalse(SharedModelStore.isRepoDownloaded("org/a"))
        XCTAssertFalse(SharedModelStore.isRepoDownloaded("org/b"))
        let manifest = try rawManifest()
        XCTAssertEqual((manifest["models"] as? [String: Any])?.count, 0, "manifest models emptied")
        XCTAssertEqual((manifest["heartbeats"] as? [String: Any])?.count, 0, "heartbeats emptied")
    }

    // The one "keep out of the device backup" routine: sets the mark on any file, clears it
    // on request, and leaves a path that does not exist alone.
    func testExcludeFromBackupSetsClearsAndSkipsMissing() throws {
        let file = tempRoot.appendingPathComponent("some-app-file.sqlite")
        try Data("x".utf8).write(to: file)
        func mark() throws -> Bool? {
            try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        }
        XCTAssertTrue(try SharedModelStore.excludeFromBackup(file))
        XCTAssertEqual(try mark(), true, "mark set")
        XCTAssertTrue(try SharedModelStore.excludeFromBackup(file, excluded: false))
        XCTAssertEqual(try mark(), false, "mark cleared")
        let missing = tempRoot.appendingPathComponent("not-there-yet")
        XCTAssertFalse(try SharedModelStore.excludeFromBackup(missing), "missing path is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "nothing was created")
    }
}
