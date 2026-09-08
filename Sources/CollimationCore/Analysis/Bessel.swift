import Foundation

/// First-order Bessel function of the first kind.
///
/// The Airy renderer used `j1` from Darwin. The Windows CRT exports it only as
/// `_j1` and the POSIX name imports as deprecated, so the core carries its own
/// implementation: the Numerical Recipes `bessj1` rational approximations, a
/// polynomial below |x| = 8 and the asymptotic form above. Worst-case error is
/// about 1.4e-8, measured against the power series near x = 8.
public func besselJ1(_ x: Double) -> Double {
    let ax = abs(x)
    if ax < 8.0 {
        let y = x * x
        let numerator = x * (72_362_614_232.0
            + y * (-7_895_059_235.0
            + y * (242_396_853.1
            + y * (-2_972_611.439
            + y * (15_704.482_60
            + y * (-30.160_366_06))))))
        let denominator = 144_725_228_442.0
            + y * (2_300_535_178.0
            + y * (18_583_304.74
            + y * (99_447.433_94
            + y * (376.999_139_7
            + y * 1.0))))
        return numerator / denominator
    }

    let z = 8.0 / ax
    let y = z * z
    let phase = ax - 2.356_194_491
    let amplitudeTerm = 1.0
        + y * (0.183_105e-2
        + y * (-0.351_639_6e-4
        + y * (0.245_752_0e-5
        + y * (-0.240_337e-6
        + y * 0.636_186e-7))))
    let phaseTerm = 0.046_874_999_95
        + y * (-0.200_269_0e-3
        + y * (0.844_919_9e-5
        + y * (-0.882_289_87e-6
        + y * 0.105_787_412e-6)))
    let value = (0.636_619_772 / ax).squareRoot()
        * (cos(phase) * amplitudeTerm - z * sin(phase) * phaseTerm)
    return x < 0 ? -value : value
}
