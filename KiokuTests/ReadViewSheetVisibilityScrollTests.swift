import CoreGraphics
import XCTest
@testable import Kioku

final class ReadViewSheetVisibilityScrollTests: XCTestCase {
    func testAdjustmentReturnsNilWhenSegmentAlreadyInsideVisibleBand() {
        let context = ReadViewSheetVisibilityScrollContext(
            currentOffsetY: 100,
            minOffsetY: -8,
            maxOffsetY: 500,
            viewportHeight: 800,
            adjustedTopInset: 8,
            selectedSegmentRectInContent: CGRect(x: 0, y: 250, width: 40, height: 24),
            estimatedSheetHeight: 360,
            estimatedRelativeCoverage: 0.64,
            maximumCoveredHeightRatio: 0.5,
            topPadding: 24,
            bottomPadding: 16
        )

        XCTAssertNil(ReadViewSheetVisibilityScrollPlanner.adjustment(for: context))
    }

    func testAdjustmentScrollsDownOnlyEnoughToClearSheetEdge() throws {
        let context = ReadViewSheetVisibilityScrollContext(
            currentOffsetY: 100,
            minOffsetY: -8,
            maxOffsetY: 500,
            viewportHeight: 800,
            adjustedTopInset: 8,
            selectedSegmentRectInContent: CGRect(x: 0, y: 500, width: 40, height: 20),
            estimatedSheetHeight: 360,
            estimatedRelativeCoverage: 0.64,
            maximumCoveredHeightRatio: 0.5,
            topPadding: 24,
            bottomPadding: 16
        )

        let adjustment = try XCTUnwrap(ReadViewSheetVisibilityScrollPlanner.adjustment(for: context))
        XCTAssertEqual(adjustment.targetOffsetY, 136, accuracy: 0.001)
        XCTAssertEqual(adjustment.temporaryBottomInset, 0, accuracy: 0.001)
    }

    func testAdjustmentScrollsUpWhenSegmentMovesAboveVisibleBand() throws {
        let context = ReadViewSheetVisibilityScrollContext(
            currentOffsetY: 200,
            minOffsetY: -8,
            maxOffsetY: 500,
            viewportHeight: 800,
            adjustedTopInset: 8,
            selectedSegmentRectInContent: CGRect(x: 0, y: 180, width: 40, height: 20),
            estimatedSheetHeight: 360,
            estimatedRelativeCoverage: 0.64,
            maximumCoveredHeightRatio: 0.5,
            topPadding: 24,
            bottomPadding: 16
        )

        let adjustment = try XCTUnwrap(ReadViewSheetVisibilityScrollPlanner.adjustment(for: context))
        XCTAssertEqual(adjustment.targetOffsetY, 148, accuracy: 0.001)
        XCTAssertEqual(adjustment.temporaryBottomInset, 0, accuracy: 0.001)
    }

    func testAdjustmentAllowsTemporaryBottomOverscrollNearEndOfShortNote() throws {
        let context = ReadViewSheetVisibilityScrollContext(
            currentOffsetY: 300,
            minOffsetY: -8,
            maxOffsetY: 320,
            viewportHeight: 800,
            adjustedTopInset: 8,
            selectedSegmentRectInContent: CGRect(x: 0, y: 700, width: 40, height: 20),
            estimatedSheetHeight: 360,
            estimatedRelativeCoverage: 0.64,
            maximumCoveredHeightRatio: 0.5,
            topPadding: 24,
            bottomPadding: 16
        )

        let adjustment = try XCTUnwrap(ReadViewSheetVisibilityScrollPlanner.adjustment(for: context))
        XCTAssertEqual(adjustment.targetOffsetY, 336, accuracy: 0.001)
        // 336 sits 16pt past maxOffsetY=320; the planner asks for exactly that much extra
        // contentInset.bottom so the scroll view can rest at 336 without bouncing back.
        XCTAssertEqual(adjustment.temporaryBottomInset, 16, accuracy: 0.001)
    }

    func testDismissalTargetTrimsOnlyTemporaryBottomOverscroll() throws {
        let targetOffsetY = try XCTUnwrap(
            ReadViewSheetVisibilityScrollPlanner.dismissalTargetOffsetY(
                currentOffsetY: 336,
                minOffsetY: -8,
                maxOffsetY: 320
            )
        )
        XCTAssertEqual(targetOffsetY, 320, accuracy: 0.001)
    }

    func testDismissalTargetPreservesOffsetsAlreadyWithinNormalRange() {
        XCTAssertNil(
            ReadViewSheetVisibilityScrollPlanner.dismissalTargetOffsetY(
                currentOffsetY: 280,
                minOffsetY: -8,
                maxOffsetY: 320
            )
        )
    }
}
