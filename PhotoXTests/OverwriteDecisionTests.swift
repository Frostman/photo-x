import XCTest
@testable import PhotoX

/// Exhaustive table-driven coverage for the export overwrite-decision
/// function. Pure inputs → pure outputs, no IO. Every supported policy
/// is exercised across the full state matrix; XMP-specific behaviour
/// (never regress a newer sidecar) is tested separately.
final class OverwriteDecisionTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: helpers

    private func snap(size: Int64, mtimeOffset: TimeInterval) -> FileSnapshot {
        FileSnapshot(size: size, mtime: now.addingTimeInterval(mtimeOffset))
    }

    private func decide(
        src: FileSnapshot,
        dst: FileSnapshot,
        policy: ExportSettings.OverwritePolicy,
        isXMP: Bool = false
    ) -> CopyDecision {
        OverwriteDecision.decide(source: src, destination: dst, isXMP: isXMP, policy: policy)
    }

    // MARK: source missing → always skip (defensive)

    func test_sourceMissing_alwaysSkips_regardlessOfPolicy() {
        let dst = snap(size: 100, mtimeOffset: 0)
        for policy in ExportSettings.OverwritePolicy.allCases {
            XCTAssertEqual(decide(src: .missing, dst: dst, policy: policy), .skip,
                           "policy \(policy)")
        }
    }

    // MARK: destination missing → always write (no remove needed)

    func test_destMissing_alwaysWrites_noRemove_regardlessOfPolicy() {
        let src = snap(size: 100, mtimeOffset: 0)
        for policy in ExportSettings.OverwritePolicy.allCases {
            XCTAssertEqual(decide(src: src, dst: .missing, policy: policy),
                           .write(removeFirst: false),
                           "policy \(policy)")
        }
    }

    // MARK: universal same-size + mtime-within-1s → skip (every policy)

    func test_sameSize_sameMtime_alwaysSkips() {
        let src = snap(size: 100, mtimeOffset: 0)
        let dst = snap(size: 100, mtimeOffset: 0)
        for policy in ExportSettings.OverwritePolicy.allCases {
            XCTAssertEqual(decide(src: src, dst: dst, policy: policy), .skip)
        }
    }

    func test_sameSize_mtimeWithin1Second_skips() {
        let src = snap(size: 100, mtimeOffset: 0.0)
        let dst = snap(size: 100, mtimeOffset: 0.999)  // <1s diff
        for policy in ExportSettings.OverwritePolicy.allCases {
            XCTAssertEqual(decide(src: src, dst: dst, policy: policy), .skip)
        }
    }

    func test_sameSize_mtimeAtExactly1Second_doesNotSkip() {
        // 1.0s is the *boundary* — the tolerance is strictly less than 1s.
        let src = snap(size: 100, mtimeOffset: 0.0)
        let dst = snap(size: 100, mtimeOffset: 1.0)
        // src is newer? no — src mtime = 0, dst = +1s, so dst is newer
        XCTAssertEqual(decide(src: src, dst: dst, policy: .alwaysOverwrite),
                       .write(removeFirst: true))
    }

    // MARK: alwaysOverwrite

    func test_alwaysOverwrite_diffSize_writes() {
        XCTAssertEqual(
            decide(src: snap(size: 200, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 0),
                   policy: .alwaysOverwrite),
            .write(removeFirst: true))
    }

    func test_alwaysOverwrite_sameSizeDiffMtime_writes() {
        XCTAssertEqual(
            decide(src: snap(size: 100, mtimeOffset: 10),
                   dst: snap(size: 100, mtimeOffset: 0),
                   policy: .alwaysOverwrite),
            .write(removeFirst: true))
    }

    func test_alwaysOverwrite_sourceOlderThanDest_stillWrites() {
        XCTAssertEqual(
            decide(src: snap(size: 100, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 10),
                   policy: .alwaysOverwrite),
            .write(removeFirst: true))
    }

    // MARK: skipIfExists

    func test_skipIfExists_anyDifference_skips() {
        XCTAssertEqual(
            decide(src: snap(size: 200, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 0),
                   policy: .skipIfExists),
            .skip)
        XCTAssertEqual(
            decide(src: snap(size: 100, mtimeOffset: 10),
                   dst: snap(size: 100, mtimeOffset: 0),
                   policy: .skipIfExists),
            .skip)
    }

    // MARK: skipUnchangedElseOverwrite (default)

    func test_skipUnchangedElseOverwrite_diffSize_writes() {
        XCTAssertEqual(
            decide(src: snap(size: 200, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 0),
                   policy: .skipUnchangedElseOverwrite),
            .write(removeFirst: true))
    }

    func test_skipUnchangedElseOverwrite_sourceOlder_stillWrites() {
        XCTAssertEqual(
            decide(src: snap(size: 100, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 10),
                   policy: .skipUnchangedElseOverwrite),
            .write(removeFirst: true))
    }

    // MARK: skipUnchangedElseNewerOnly

    func test_skipUnchangedElseNewerOnly_sourceNewer_writes() {
        XCTAssertEqual(
            decide(src: snap(size: 100, mtimeOffset: 10),
                   dst: snap(size: 100, mtimeOffset: 0),
                   policy: .skipUnchangedElseNewerOnly),
            .write(removeFirst: true))
    }

    func test_skipUnchangedElseNewerOnly_sourceOlder_skips() {
        XCTAssertEqual(
            decide(src: snap(size: 100, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 10),
                   policy: .skipUnchangedElseNewerOnly),
            .skip)
    }

    func test_skipUnchangedElseNewerOnly_diffSizeSourceOlder_skips() {
        // Different size means content differs, but the policy still respects
        // mtime to avoid overwriting a more-recent destination version.
        XCTAssertEqual(
            decide(src: snap(size: 200, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 10),
                   policy: .skipUnchangedElseNewerOnly),
            .skip)
    }

    // MARK: XMP newer-only invariant (applies regardless of policy)

    func test_xmp_destNewer_alwaysOverwritePolicy_stillSkips() {
        XCTAssertEqual(
            decide(src: snap(size: 200, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 10),
                   policy: .alwaysOverwrite,
                   isXMP: true),
            .skip)
    }

    func test_xmp_destNewer_skipUnchangedPolicy_skips() {
        XCTAssertEqual(
            decide(src: snap(size: 200, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 10),
                   policy: .skipUnchangedElseOverwrite,
                   isXMP: true),
            .skip)
    }

    func test_xmp_sourceNewer_alwaysOverwritePolicy_writes() {
        XCTAssertEqual(
            decide(src: snap(size: 200, mtimeOffset: 10),
                   dst: snap(size: 100, mtimeOffset: 0),
                   policy: .alwaysOverwrite,
                   isXMP: true),
            .write(removeFirst: true))
    }

    func test_xmp_sourceNewer_skipUnchangedNewerOnlyPolicy_writes() {
        XCTAssertEqual(
            decide(src: snap(size: 200, mtimeOffset: 10),
                   dst: snap(size: 100, mtimeOffset: 0),
                   policy: .skipUnchangedElseNewerOnly,
                   isXMP: true),
            .write(removeFirst: true))
    }

    func test_xmp_sameSize_mtimeWithin1s_skips_perUniversalRule() {
        XCTAssertEqual(
            decide(src: snap(size: 100, mtimeOffset: 0),
                   dst: snap(size: 100, mtimeOffset: 0.5),
                   policy: .alwaysOverwrite,
                   isXMP: true),
            .skip)
    }

    func test_xmp_destMissing_alwaysWrites() {
        XCTAssertEqual(
            decide(src: snap(size: 100, mtimeOffset: 0),
                   dst: .missing,
                   policy: .alwaysOverwrite,
                   isXMP: true),
            .write(removeFirst: false))
    }
}
