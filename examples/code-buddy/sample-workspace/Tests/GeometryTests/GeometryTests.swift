import XCTest
@testable import Geometry

final class GeometryTests: XCTestCase {
    func testArea() {
        XCTAssertEqual(Rectangle(width: 3, height: 4).area, 12)
    }

    func testPerimeter() {
        XCTAssertEqual(Rectangle(width: 3, height: 4).perimeter, 14)
    }

    func testIsSquare() {
        XCTAssertTrue(isSquare(Rectangle(width: 5, height: 5)))
        XCTAssertFalse(isSquare(Rectangle(width: 5, height: 6)))
    }

    func testScaledScalesBothDimensions() {
        let bigger = scaled(Rectangle(width: 2, height: 3), by: 2)
        XCTAssertEqual(bigger.width, 4, "width should double")
        XCTAssertEqual(bigger.height, 6, "height should double too")
    }
}
