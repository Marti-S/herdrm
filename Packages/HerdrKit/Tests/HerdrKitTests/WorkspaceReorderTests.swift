import XCTest
@testable import HerdrKit

final class WorkspaceReorderTests: XCTestCase {
    private let order = ["A", "B", "C"]

    func testDropOnEarlierRowInsertsBeforeIt() {
        let plan = WorkspaceReorder.plan(
            moving: "B", onto: "A", placeAfter: false, orderedIDs: order
        )
        XCTAssertEqual(plan, WorkspaceReorder.Plan(workspaceIDs: ["B"], beforeWorkspaceID: "A"))
        XCTAssertEqual(WorkspaceReorder.applying(order, id: { $0 }, plan: plan!), ["B", "A", "C"])
    }

    func testDropOnLowerHalfOfLastRowAppends() {
        let plan = WorkspaceReorder.plan(
            moving: "A", onto: "C", placeAfter: true, orderedIDs: order
        )
        XCTAssertEqual(plan, WorkspaceReorder.Plan(workspaceIDs: ["A"], beforeWorkspaceID: nil))
        XCTAssertEqual(WorkspaceReorder.applying(order, id: { $0 }, plan: plan!), ["B", "C", "A"])
    }

    func testDropOnLowerHalfWhenNextIsTheDraggedRowIsNoOp() {
        XCTAssertNil(WorkspaceReorder.plan(
            moving: "B", onto: "A", placeAfter: true, orderedIDs: order
        ))
    }

    func testAlreadyImmediatelyBeforeTheTargetIsNoOp() {
        XCTAssertNil(WorkspaceReorder.plan(
            moving: "A", onto: "B", placeAfter: false, orderedIDs: order
        ))
        XCTAssertNil(WorkspaceReorder.plan(
            moving: "C", onto: "C", placeAfter: false, orderedIDs: order
        ))
        XCTAssertNil(WorkspaceReorder.plan(
            moving: "C", onto: "C", placeAfter: true, orderedIDs: order
        ))
    }

    func testMoveLastToFront() {
        let plan = WorkspaceReorder.plan(
            moving: "C", onto: "A", placeAfter: false, orderedIDs: order
        )
        XCTAssertEqual(plan, WorkspaceReorder.Plan(workspaceIDs: ["C"], beforeWorkspaceID: "A"))
        XCTAssertEqual(WorkspaceReorder.applying(order, id: { $0 }, plan: plan!), ["C", "A", "B"])
    }

    func testUnknownIdsAreRejected() {
        XCTAssertNil(WorkspaceReorder.plan(
            moving: "A", onto: "Z", placeAfter: false, orderedIDs: order
        ))
        XCTAssertNil(WorkspaceReorder.plan(
            moving: "Z", onto: "A", placeAfter: false, orderedIDs: order
        ))
    }
}
