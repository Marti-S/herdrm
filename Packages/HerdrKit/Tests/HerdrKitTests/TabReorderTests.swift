import XCTest
@testable import HerdrKit

final class TabReorderTests: XCTestCase {
    private let order = ["t1", "t2", "t3"]

    func testDropOnEarlierRowInsertsBeforeIt() {
        XCTAssertEqual(
            TabReorder.insertIndex(moving: "t2", onto: "t1", placeAfter: false, orderedIDs: order),
            0
        )
    }

    func testDropOnLowerHalfOfLastRowAppends() {
        XCTAssertEqual(
            TabReorder.insertIndex(moving: "t1", onto: "t3", placeAfter: true, orderedIDs: order),
            2
        )
    }

    func testDropOnLowerHalfWhenNextIsTheDraggedRowIsNoOp() {
        XCTAssertNil(
            TabReorder.insertIndex(moving: "t2", onto: "t1", placeAfter: true, orderedIDs: order)
        )
    }

    func testAlreadyImmediatelyBeforeTheTargetIsNoOp() {
        XCTAssertNil(
            TabReorder.insertIndex(moving: "t1", onto: "t2", placeAfter: false, orderedIDs: order)
        )
    }

    func testMoveLastToFront() {
        XCTAssertEqual(
            TabReorder.insertIndex(moving: "t3", onto: "t1", placeAfter: false, orderedIDs: order),
            0
        )
    }
}
