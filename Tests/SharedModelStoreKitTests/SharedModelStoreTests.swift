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
}
