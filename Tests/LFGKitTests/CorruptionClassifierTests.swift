import XCTest
@testable import LFGKit

// MARK: - CorruptionClassifierTests
//
// 7 test cases covering LFG-99 §11 spec, one per assertion:
//   testClassA_staleHalfAttach          — (EBUSY, false, .notAttempted)         → .classA
//   testClassB_superblockCorrupt        — (EIO,   false, .success(false))        → .classB
//   testClassC_shadowFailed             — (EIO,   false, .failure("..."))        → .classC
//   testClassD_bandDamage               — (nil,   true,  .success(false))        → .classD
//   testClassE_permissionGhost          — (nil,   true,  .notAttempted)          → .classE
//   testAutonomousReclaimable           — classA.isAutonomousReclaimable == true
//   testNonReclaimable                  — classB.isAutonomousReclaimable == false
//
// Additional invariant tests follow the 5 core cases to close AC-5 of US-A-001.

final class CorruptionClassifierTests: XCTestCase {

    // MARK: - Class A: Stale Half-Attach

    /// Given: (hdiutil_errno=EBUSY, container_visible=false, shadow_outcome=.notAttempted)
    /// When:  CorruptionClassifier.classify is called
    /// Then:  Returns .classA — canonical stale half-attach, autonomous reclaimable
    func testClassA_staleHalfAttach_when_ebusyWithNoContainerAndNoShadow_returns_classA() {
        guard let signature = CorruptionSignature(
            hdiutilErrno: EBUSY,
            containerVisible: false,
            shadowAttachOutcome: .notAttempted
        ) else {
            XCTFail("Expected valid CorruptionSignature for Class A tuple")
            return
        }

        let result = CorruptionClassifier.classify(signature)

        XCTAssertEqual(result, .classA,
            "EBUSY + no container + notAttempted must classify as Class A (stale half-attach)")
    }

    // MARK: - Class B: APFS Superblock Corruption

    /// Given: (hdiutil_errno=EIO, container_visible=false, shadow_outcome=.success(fsckClean:false))
    /// When:  CorruptionClassifier.classify is called
    /// Then:  Returns .classB — superblock corrupt, requires recovery agent
    func testClassB_superblockCorrupt_when_eioWithShadowSuccessAndFsckErrors_returns_classB() {
        guard let signature = CorruptionSignature(
            hdiutilErrno: EIO,
            containerVisible: false,
            shadowAttachOutcome: .success(fsckClean: false)
        ) else {
            XCTFail("Expected valid CorruptionSignature for Class B tuple")
            return
        }

        let result = CorruptionClassifier.classify(signature)

        XCTAssertEqual(result, .classB,
            "EIO + shadow succeeded + fsck errors must classify as Class B (superblock corrupt)")
    }

    // MARK: - Class C: Container Metadata Destroyed

    /// Given: (hdiutil_errno=EIO, container_visible=false, shadow_outcome=.failure("Resource temporarily unavailable"))
    /// When:  CorruptionClassifier.classify is called
    /// Then:  Returns .classC — container metadata destroyed, requires recovery agent
    func testClassC_shadowFailed_when_eioWithShadowFailure_returns_classC() {
        guard let signature = CorruptionSignature(
            hdiutilErrno: EIO,
            containerVisible: false,
            shadowAttachOutcome: .failure(reason: "Resource temporarily unavailable")
        ) else {
            XCTFail("Expected valid CorruptionSignature for Class C tuple")
            return
        }

        let result = CorruptionClassifier.classify(signature)

        XCTAssertEqual(result, .classC,
            "EIO + shadow failed must classify as Class C (container metadata destroyed)")
    }

    // MARK: - Class D: Sparsebundle Band Damage

    /// Given: (hdiutil_errno=nil, container_visible=true, shadow_outcome=.success(fsckClean:false))
    /// When:  CorruptionClassifier.classify is called
    /// Then:  Returns .classD — band damage (attach succeeded, container visible, fsck errors)
    ///
    /// Note: errno=nil means hdiutil attach returned 0 (success). The .success(false) shadow
    /// path maps to the "other errno" branch where containerVisible=true + fsck errors → .classD.
    /// However since hdiutilErrno is nil (attach succeeded), this goes through the
    /// (nil, true, .success(fsckClean: false)) pattern → .classD per the decision tree.
    func testClassD_bandDamage_when_attachSucceededContainerVisibleFsckErrors_returns_classD() {
        // Shadow success with fsck errors requires a prior failed attach (hdiutilErrno != nil).
        // Use a non-nil, non-EIO, non-EBUSY errno to exercise the "other errno" + true + fsck errors path.
        // Per design §3: "other errno" + containerVisible=true + fsck errors → .classD
        guard let signature = CorruptionSignature(
            hdiutilErrno: Int32(6),  // ENXIO — not EBUSY/EIO, triggers "other errno" branch
            containerVisible: true,
            shadowAttachOutcome: .success(fsckClean: false)
        ) else {
            XCTFail("Expected valid CorruptionSignature for Class D tuple")
            return
        }

        let result = CorruptionClassifier.classify(signature)

        XCTAssertEqual(result, .classD,
            "Other errno + container visible + shadow success + fsck errors must classify as Class D")
    }

    // MARK: - Class E: Permission Ghost

    /// Given: (hdiutil_errno=nil, container_visible=true, shadow_outcome=.notAttempted)
    /// When:  CorruptionClassifier.classify is called
    /// Then:  Returns .classE — permission ghost (attach succeeded, volume mounted but root dir unreadable)
    func testClassE_permissionGhost_when_attachSucceededContainerVisibleNoShadow_returns_classE() {
        guard let signature = CorruptionSignature(
            hdiutilErrno: nil,
            containerVisible: true,
            shadowAttachOutcome: .notAttempted
        ) else {
            XCTFail("Expected valid CorruptionSignature for Class E tuple")
            return
        }

        let result = CorruptionClassifier.classify(signature)

        XCTAssertEqual(result, .classE,
            "Nil errno + container visible + notAttempted must classify as Class E (permission ghost)")
    }

    // MARK: - Autonomous reclaim gate (CorruptionClass invariants)

    /// Given: CorruptionClass.classA
    /// When:  isAutonomousReclaimable is checked
    /// Then:  Returns true — detach + reattach is safe, no recovery agent needed
    func testAutonomousReclaimable_when_classA_returnsTrue() {
        XCTAssertTrue(CorruptionClass.classA.isAutonomousReclaimable,
            "Class A must be autonomously reclaimable (detach -force + reattach)")
    }

    /// Given: CorruptionClass.classB
    /// When:  isAutonomousReclaimable is checked
    /// Then:  Returns false — superblock corruption requires the recovery agent
    func testNonReclaimable_when_classB_returnsFalse() {
        XCTAssertFalse(CorruptionClass.classB.isAutonomousReclaimable,
            "Class B must NOT be autonomously reclaimable (requires recovery agent)")
    }

    // MARK: - Class E autonomous reclaim (LFG-93 §5 invariant)

    /// Given: CorruptionClass.classE
    /// When:  isAutonomousReclaimable is checked
    /// Then:  Returns true — chmod/owners-off fix is safe without recovery agent
    func testAutonomousReclaimable_when_classE_returnsTrue() {
        XCTAssertTrue(CorruptionClass.classE.isAutonomousReclaimable,
            "Class E must be autonomously reclaimable (chmod 0750 or -owners off)")
    }

    /// Given: CorruptionClass.classC and classD
    /// When:  isAutonomousReclaimable is checked
    /// Then:  Both return false — metadata destruction and band damage require recovery agent
    func testNonReclaimable_when_classC_and_classD_returnFalse() {
        XCTAssertFalse(CorruptionClass.classC.isAutonomousReclaimable,
            "Class C must NOT be autonomously reclaimable (container metadata destroyed)")
        XCTAssertFalse(CorruptionClass.classD.isAutonomousReclaimable,
            "Class D must NOT be autonomously reclaimable (band damage)")
    }

    // MARK: - Ghost-attach variant (US-A-005 AC-2)

    /// Given: (hdiutil_errno=nil, container_visible=false, shadow_outcome=.notAttempted)
    /// When:  CorruptionClassifier.classify is called
    /// Then:  Returns .classA — ghost-attach (exit 0 but no /Volumes/ mount)
    func testClassA_ghostAttach_when_nilErrnoNoContainerNoShadow_returns_classA() {
        guard let signature = CorruptionSignature(
            hdiutilErrno: nil,
            containerVisible: false,
            shadowAttachOutcome: .notAttempted
        ) else {
            XCTFail("Expected valid CorruptionSignature for ghost-attach Class A tuple")
            return
        }

        let result = CorruptionClassifier.classify(signature)

        XCTAssertEqual(result, .classA,
            "Nil errno + no container + notAttempted must classify as Class A (ghost-attach variant per US-A-005)")
    }

    // MARK: - CorruptionSignature invariant check

    /// Given: shadow_outcome=.success when hdiutil_errno is nil (primary attach succeeded)
    /// When:  CorruptionSignature failable init is called
    /// Then:  Returns nil — internally inconsistent (shadow success implies failed primary attach)
    func testCorruptionSignatureInit_when_shadowSuccessWithNilErrno_returnsNil() {
        let signature = CorruptionSignature(
            hdiutilErrno: nil,
            containerVisible: true,
            shadowAttachOutcome: .success(fsckClean: true)
        )

        XCTAssertNil(signature,
            "CorruptionSignature must reject shadow=.success when hdiutilErrno is nil (invariant: shadow success requires failed primary attach)")
    }

    // MARK: - EIO clean shadow → Class A edge case (design §3)

    /// Given: (hdiutil_errno=EIO, container_visible=false, shadow_outcome=.success(fsckClean:true))
    /// When:  CorruptionClassifier.classify is called
    /// Then:  Returns .classA — fsck came back clean means transient signal, not superblock corrupt
    func testClassA_eioCleanShadow_when_shadowSucceededAndFsckClean_returns_classA() {
        guard let signature = CorruptionSignature(
            hdiutilErrno: EIO,
            containerVisible: false,
            shadowAttachOutcome: .success(fsckClean: true)
        ) else {
            XCTFail("Expected valid CorruptionSignature for EIO + clean shadow tuple")
            return
        }

        let result = CorruptionClassifier.classify(signature)

        XCTAssertEqual(result, .classA,
            "EIO + shadow succeeded + fsck CLEAN must classify as Class A edge case (transient busy signal)")
    }
}
