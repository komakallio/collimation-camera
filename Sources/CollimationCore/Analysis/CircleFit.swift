import Foundation

public struct FittedCircle: Equatable, Sendable {
    public var center: SIMD2<Double>
    public var radius: Double

    public init(center: SIMD2<Double>, radius: Double) {
        self.center = center
        self.radius = radius
    }

    public func translated(by delta: SIMD2<Double>) -> FittedCircle {
        FittedCircle(center: center + delta, radius: radius)
    }
}

public enum CircleFit {
    /// Algebraic (Kåsa) least-squares circle fit.
    public static func fit(points: [SIMD2<Double>]) -> FittedCircle? {
        let n = Double(points.count)
        guard points.count >= 3 else { return nil }

        var sumX = 0.0, sumY = 0.0
        var sumX2 = 0.0, sumY2 = 0.0, sumXY = 0.0
        var sumX3 = 0.0, sumY3 = 0.0, sumX2Y = 0.0, sumXY2 = 0.0

        for p in points {
            let x = p.x
            let y = p.y
            let x2 = x * x
            let y2 = y * y
            sumX += x
            sumY += y
            sumX2 += x2
            sumY2 += y2
            sumXY += x * y
            sumX3 += x2 * x
            sumY3 += y2 * y
            sumX2Y += x2 * y
            sumXY2 += x * y2
        }

        // Solve [x^2+y^2 + D x + E y + F = 0] via normal equations.
        let a11 = sumX2
        let a12 = sumXY
        let a13 = sumX
        let a21 = sumXY
        let a22 = sumY2
        let a23 = sumY
        let a31 = sumX
        let a32 = sumY
        let a33 = n
        let b1 = -(sumX3 + sumXY2)
        let b2 = -(sumX2Y + sumY3)
        let b3 = -(sumX2 + sumY2)

        guard let sol = solve3x3(
            a11, a12, a13, b1,
            a21, a22, a23, b2,
            a31, a32, a33, b3
        ) else { return nil }

        let d = sol.0
        let e = sol.1
        let f = sol.2
        let cx = -d / 2
        let cy = -e / 2
        let r2 = cx * cx + cy * cy - f
        guard r2 > 1, r2.isFinite, cx.isFinite, cy.isFinite else { return nil }
        return FittedCircle(center: SIMD2(cx, cy), radius: sqrt(r2))
    }

    private static func solve3x3(
        _ a11: Double, _ a12: Double, _ a13: Double, _ b1: Double,
        _ a21: Double, _ a22: Double, _ a23: Double, _ b2: Double,
        _ a31: Double, _ a32: Double, _ a33: Double, _ b3: Double
    ) -> (Double, Double, Double)? {
        let det =
            a11 * (a22 * a33 - a23 * a32)
            - a12 * (a21 * a33 - a23 * a31)
            + a13 * (a21 * a32 - a22 * a31)
        guard abs(det) > 1e-12 else { return nil }

        let detX =
            b1 * (a22 * a33 - a23 * a32)
            - a12 * (b2 * a33 - a23 * b3)
            + a13 * (b2 * a32 - a22 * b3)
        let detY =
            a11 * (b2 * a33 - a23 * b3)
            - b1 * (a21 * a33 - a23 * a31)
            + a13 * (a21 * b3 - b2 * a31)
        let detZ =
            a11 * (a22 * b3 - b2 * a32)
            - a12 * (a21 * b3 - b2 * a31)
            + b1 * (a21 * a32 - a22 * a31)
        return (detX / det, detY / det, detZ / det)
    }
}
