import XCTest
import UIKit
@testable import Kioku

// Exercises ownership across the asynchronous lookup preparation used by nested component sheets.
@MainActor
final class SegmentLookupPresentationTests: XCTestCase {
    // A component coordinator is local to its caller; presentation must keep it alive until the
    // controller takes ownership, then release it after dismissal rather than leaking callbacks.
    func testLocalCoordinatorSurvivesPreparationAndReleasesAfterDismissal() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first {
            $0.activationState == .foregroundActive
        } as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        let prepared = expectation(description: "component lookup prepared")
        weak var coordinator: SegmentLookupSheet?
        do {
            let sheet = SegmentLookupSheet()
            coordinator = sheet
            sheet.presentSurfaceSheet(
                surface: "突く", leftNeighborSurface: nil, rightNeighborSurface: nil,
                onSelectPrevious: nil, onSelectNext: nil, onMergeLeft: nil,
                onMergeRight: nil, onSplitApply: nil,
                sheetReadingsProvider: { prepared.fulfill(); return ["つく"] },
                sheetSublatticeProvider: { [] }, segmentRangeProvider: { nil },
                sheetLexiconDebugProvider: { "" }, onDismiss: nil
            )
        }
        await fulfillment(of: [prepared], timeout: 3)
        var controller: SurfaceSheetViewController? = try XCTUnwrap(root.presentedViewController as? SurfaceSheetViewController)
        XCTAssertNotNil(coordinator)
        XCTAssertTrue(controller?.sheet === coordinator)
        let appeared = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak controller] _, _ in
                MainActor.assumeIsolated { controller?.isBeingPresented == false }
            }, object: nil
        )
        await fulfillment(of: [appeared], timeout: 3)
        let dismissed = expectation(description: "component lookup dismissed")
        coordinator?.dismissSheet { dismissed.fulfill() }
        await fulfillment(of: [dismissed], timeout: 3)
        XCTAssertNil(root.presentedViewController)
        controller = nil
        XCTAssertNil(coordinator)
    }
}
