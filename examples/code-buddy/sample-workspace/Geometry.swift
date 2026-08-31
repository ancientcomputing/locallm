// A tiny geometry helper, deliberately left undocumented — the starting point for the
// code-buddy walkthrough in ../README.md. Ask code-buddy to "add a doc comment to every
// public function", then `git diff` to see what it changed.

import Foundation

public struct Rectangle {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var area: Double {
        width * height
    }

    public var perimeter: Double {
        2 * (width + height)
    }
}

public func isSquare(_ rectangle: Rectangle) -> Bool {
    rectangle.width == rectangle.height
}

public func scaled(_ rectangle: Rectangle, by factor: Double) -> Rectangle {
    Rectangle(width: rectangle.width * factor, height: rectangle.height * factor)
}
