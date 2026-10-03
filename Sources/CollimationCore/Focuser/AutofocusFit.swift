import Foundation

public enum AutofocusFitModel: String, Codable, Sendable { case symmetric, asymmetric }

public struct AutofocusFit: Equatable, Sendable, Codable {
    public let model: AutofocusFitModel
    public let position: Int
    public let origin: Int
    public let scale: Double
    public let center: Double
    public let h0: Double
    public let k: Double
    public let tilt: Double
    public let residualRMS: Double
    /// Approximate local model sensitivity, enlarged by leave-one-out variation.
    /// This is not an empirically calibrated confidence interval.
    public let uncertaintySteps: Double
    public let leaveOneOutPositions: [Int]
    public let leaveOneOutMaximumSteps: Double
    public let weights: [Double]
    public let blockUncertainties: [Double]
    public let downweightedIndices: [Int]
    public let predictions: [Double]

    public func predict(at position: Int) -> Double {
        let u = Double(position - origin) / scale - center
        return hypot(h0, k * u) + tilt * u
    }


}

/// Normalised, bounded nonlinear least squares with one Huber reweighting pass.
/// No point deletion or repeated pruning. Damped QR avoids normal equations.
/// Asymmetry is restrained to |t/k| <= 0.45 and needs an AICc improvement > 6
/// plus stable leave-one-out fits. Both candidates must support both flanks.
public enum AutofocusFitter {
    private struct Candidate {
        var p: [Double] // h0, k, centre, t/k
        var weights: [Double]
        var predictions: [Double]
        var rms: Double
        var score: Double
        var minimum: Double { p[2] - p[3] * p[0] / (p[1] * sqrt(1 - p[3] * p[3])) }
    }

    public static func fit(_ samples: [AutofocusSample], settings: AutofocusSettings = AutofocusSettings(),
                           maximumIterations: Int = 100) throws -> AutofocusFit {
        guard samples.count == 9, settings.step > 0,
              settings.absoluteHFRFloor.isFinite, settings.absoluteHFRFloor > 0,
              settings.relativeHFRFloor.isFinite, settings.relativeHFRFloor > 0,
              samples.allSatisfy({ $0.position >= 0 && $0.hfr.isFinite && $0.hfr > 0
                  && ($0.scatter == nil || ($0.scatter!.isFinite && $0.scatter! >= 0)) }),
              zip(samples, samples.dropFirst()).allSatisfy({ $0.position < $1.position }),
              samples.allSatisfy({ $0.exposureMicroseconds == samples[0].exposureMicroseconds && $0.gain == samples[0].gain })
        else { throw AutofocusError.noStar }
        let y = samples.map(\.hfr)
        let best = y.indices.min { y[$0] < y[$1] }!
        guard y.max()! > y[best] * 1.05 else { throw AutofocusError.flatCurve }
        // Keep the existing supported-edge search. A bad edge spike is rejected
        // by AutofocusSearch's median thirds and pairwise trend checks.
        guard best > 0 && best < 8 else { throw AutofocusError.minimumNotBracketed }
        let origin = samples[4].position
        let scale = Double(samples.last!.position - samples.first!.position) / 2
        let x = samples.map { Double($0.position - origin) / scale }
        let sigma = samples.map { $0.uncertainty(settings: settings) }
        guard maximumIterations > 0 else { throw AutofocusError.unstableFit }
        let symmetric = try candidate(x: x, y: y, sigma: sigma, asymmetric: false, iterations: maximumIterations)
        let asymmetric = try? candidate(x: x, y: y, sigma: sigma, asymmetric: true, iterations: maximumIterations)
        var selected = symmetric
        var isAsymmetric = false
        if let asymmetric, asymmetric.score < symmetric.score - 6,
           (try? support(asymmetric, x: x, y: y, sigma: sigma)) != nil,
           (try? sensitivity(asymmetric, x: x, y: y, sigma: sigma, asymmetric: true,
                             iterations: maximumIterations, stepScale: Double(settings.step) / scale)) != nil {
            selected = asymmetric; isAsymmetric = true
        }
        try support(selected, x: x, y: y, sigma: sigma)
        let (loo, uncertainty) = try sensitivity(selected, x: x, y: y, sigma: sigma, asymmetric: isAsymmetric,
                                                iterations: maximumIterations, stepScale: Double(settings.step) / scale)
        func motor(_ value: Double) throws -> Int {
            let offset = value * scale
            guard offset.isFinite, offset > Double(Int.min), offset < Double(Int.max) else { throw AutofocusError.unstableFit }
            let (position, overflow) = origin.addingReportingOverflow(Int(offset.rounded()))
            guard !overflow, position >= samples.first!.position, position <= samples.last!.position else {
                throw AutofocusError.unstableFit
            }
            return position
        }
        let positions = try loo.map(motor)
        return AutofocusFit(model: isAsymmetric ? .asymmetric : .symmetric, position: try motor(selected.minimum),
            origin: origin, scale: scale, center: selected.p[2], h0: selected.p[0], k: selected.p[1],
            tilt: selected.p[1] * selected.p[3], residualRMS: selected.rms,
            uncertaintySteps: uncertainty * scale, leaveOneOutPositions: positions,
            leaveOneOutMaximumSteps: loo.map { abs($0 - selected.minimum) * scale }.max()!,
            weights: selected.weights, blockUncertainties: sigma,
            downweightedIndices: selected.weights.indices.filter { selected.weights[$0] < 0.8 },
            predictions: selected.predictions)
    }

    private static func prediction(_ p: [Double], _ x: Double) -> Double {
        let u = x - p[2]
        return hypot(p[0], p[1] * u) + p[1] * p[3] * u
    }

    private static func candidate(x: [Double], y: [Double], sigma: [Double], asymmetric: Bool,
                                  iterations: Int) throws -> Candidate {
        let p = try optimise(x: x, y: y, sigma: sigma, weights: Array(repeating: 1, count: x.count),
                             asymmetric: asymmetric, iterations: iterations)
        let weights = x.indices.map { i -> Double in
            let z = abs(y[i] - prediction(p, x[i])) / sigma[i]
            return max(0.05, min(1, 2.5 / max(2.5, z)))
        }
        let robust = try optimise(x: x, y: y, sigma: sigma, weights: weights,
                                  asymmetric: asymmetric, iterations: iterations, initial: p)
        let predictions = x.map { prediction(robust, $0) }
        let rss = x.indices.reduce(0.0) { $0 + weights[$1] * pow((y[$1] - predictions[$1]) / sigma[$1], 2) }
        let rms = sqrt(x.indices.reduce(0.0) { $0 + weights[$1] * pow(y[$1] - predictions[$1], 2) } / weights.reduce(0, +))
        let n = Double(x.count), parameters = asymmetric ? 4.0 : 3.0
        let score = n * log(max(1e-12, rss / n)) + 2 * parameters + 2 * parameters * (parameters + 1) / (n - parameters - 1)
        return Candidate(p: robust, weights: weights, predictions: predictions, rms: rms, score: score)
    }

    private static func support(_ c: Candidate, x: [Double], y: [Double], sigma: [Double]) throws {
        guard c.p.allSatisfy(\.isFinite), c.p[0] > 0, c.p[1] > 0, abs(c.p[3]) < 0.45,
              c.predictions.allSatisfy({ $0.isFinite && $0 > 0 }), c.minimum > x.first!, c.minimum < x.last!
        else { throw AutofocusError.unstableFit }
        let low = prediction(c.p, c.minimum)
        let rise = max(0.05 * low, 2 * AutofocusPlan.median(sigma))
        let left = x.indices.filter { x[$0] < c.minimum && c.weights[$0] >= 0.5 }
        let right = x.indices.filter { x[$0] > c.minimum && c.weights[$0] >= 0.5 }
        guard left.count >= 2, right.count >= 2,
              c.predictions[left.first!] - low > rise, c.predictions[right.last!] - low > rise,
              AutofocusPlan.median(left.map { y[$0] }) > low,
              AutofocusPlan.median(right.map { y[$0] }) > low else { throw AutofocusError.flatCurve }
        guard c.weights.filter({ $0 < 0.5 }).count <= 1,
              c.rms <= max(0.12 * low, 2.5 * AutofocusPlan.median(sigma)) else { throw AutofocusError.unstableFit }
    }

    private static func sensitivity(_ c: Candidate, x: [Double], y: [Double], sigma: [Double],
                                    asymmetric: Bool, iterations: Int, stepScale: Double) throws -> ([Double], Double) {
        var minima: [Double] = []
        for omitted in x.indices {
            let indices = x.indices.filter { $0 != omitted }
            // Fixed robust weights: omissions cannot start a new pruning process.
            let p = try optimise(x: indices.map { x[$0] }, y: indices.map { y[$0] },
                sigma: indices.map { sigma[$0] }, weights: indices.map { c.weights[$0] },
                asymmetric: asymmetric, iterations: iterations, initial: c.p)
            let minimum = p[2] - p[3] * p[0] / (p[1] * sqrt(1 - p[3] * p[3]))
            guard minimum.isFinite, minimum > x.first!, minimum < x.last!,
                  abs(minimum - c.minimum) <= stepScale * 0.75 else { throw AutofocusError.unstableFit }
            minima.append(minimum)
        }
        let mean = minima.reduce(0, +) / Double(minima.count)
        let jackknife = sqrt(Double(minima.count - 1) / Double(minima.count) * minima.reduce(0) { $0 + pow($1 - mean, 2) })
        // Linearised covariance from QR, with the block uncertainty floor retained
        // even for noiseless curves. No division by sqrt(frame count).
        let count = asymmetric ? 4 : 3
        let jac = jacobian(c.p, x: x, count: count)
        let columns = (0..<count).map { j in x.indices.map { jac[$0][j] * sqrt(c.weights[$0]) / sigma[$0] } }
        var variance = 0.0
        let gradient = (0..<count).map { j -> Double in
            var plus = c.p, minus = c.p
            let d = 1e-5 * max(1, abs(c.p[j])); plus[j] += d; minus[j] -= d
            func minimum(_ p: [Double]) -> Double { p[2] - p[3] * p[0] / (p[1] * sqrt(1 - p[3] * p[3])) }
            return (minimum(plus) - minimum(minus)) / (2 * d)
        }
        for i in x.indices {
            let rhs = x.indices.map { $0 == i ? 1.0 : 0.0 }
            guard let change = qrSolve(columns: columns, rhs: rhs) else { throw AutofocusError.unstableFit }
            variance += pow(zip(change, gradient).reduce(0) { $0 + $1.0 * $1.1 }, 2)
        }
        let uncertainty = max(sqrt(variance), jackknife)
        guard uncertainty.isFinite, uncertainty <= stepScale else { throw AutofocusError.unstableFit }
        return (minima, uncertainty)
    }

    private static func jacobian(_ p: [Double], x: [Double], count: Int) -> [[Double]] {
        x.map { value in (0..<count).map { j in
            var plus = p, minus = p
            let d = 1e-5 * max(1, abs(p[j])); plus[j] += d; minus[j] -= d
            return (prediction(plus, value) - prediction(minus, value)) / (2 * d)
        } }
    }

    private static func optimise(x: [Double], y: [Double], sigma: [Double], weights: [Double],
                                 asymmetric: Bool, iterations: Int, initial: [Double]? = nil) throws -> [Double] {
        let count = asymmetric ? 4 : 3
        let minY = y.min()!, maxY = y.max()!
        let bounds = [(minY * 0.1, maxY * 1.5), (0.001, maxY * 10), (-1.5, 1.5), (-0.45, 0.45)]
        func cost(_ p: [Double]) -> Double {
            x.indices.reduce(0) { $0 + weights[$1] * pow((y[$1] - prediction(p, x[$1])) / sigma[$1], 2) }
        }
        let seeds: [[Double]]
        if let initial { seeds = [initial] }
        else { seeds = [-0.5, 0.0, 0.5].map { [minY, max(0.1, maxY - minY), $0, 0.0] } }
        var best: [Double]?, bestCost = Double.infinity
        for seed in seeds {
            var p = seed, lambda = 0.001, converged = false
            for _ in 0..<iterations {
                let jac = jacobian(p, x: x, count: count)
                let columns: [[Double]] = (0..<count).map { j in
                    let measurements: [Double] = x.indices.map { jac[$0][j] * sqrt(weights[$0]) / sigma[$0] }
                    let damping: [Double] = (0..<count).map { $0 == j ? sqrt(lambda) : 0.0 }
                    return measurements + damping
                }
                let rhs = x.indices.map { (y[$0] - prediction(p, x[$0])) * sqrt(weights[$0]) / sigma[$0] }
                    + Array(repeating: 0.0, count: count)
                guard let delta = qrSolve(columns: columns, rhs: rhs) else { break }
                var proposed = p
                for j in 0..<count { proposed[j] = max(bounds[j].0, min(bounds[j].1, p[j] + delta[j])) }
                let old = cost(p), next = cost(proposed)
                if next.isFinite && next <= old {
                    let change = (0..<count).map { abs(proposed[$0] - p[$0]) / max(1, abs(p[$0])) }.max()!
                    p = proposed; lambda = max(1e-9, lambda / 3)
                    if change < 1e-7 || abs(old - next) < 1e-9 * max(1, old) { converged = true; break }
                } else { lambda *= 10; if lambda > 1e12 { break } }
            }
            if converged, p.allSatisfy(\.isFinite), cost(p) < bestCost { best = p; bestCost = cost(p) }
        }
        guard let best else { throw AutofocusError.unstableFit }
        return best
    }

    private static func qrSolve(columns: [[Double]], rhs: [Double]) -> [Double]? {
        let n = columns.count
        var q: [[Double]] = [], r = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for j in 0..<n {
            var v = columns[j]
            for _ in 0..<2 {
                for i in 0..<j {
                    let a = zip(q[i], v).reduce(0) { $0 + $1.0 * $1.1 }; r[i][j] += a
                    for k in v.indices { v[k] -= a * q[i][k] }
                }
            }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 1e-10 else { return nil }
            r[j][j] = norm; q.append(v.map { $0 / norm })
        }
        var result = q.map { zip($0, rhs).reduce(0) { $0 + $1.0 * $1.1 } }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in (i + 1)..<n { result[i] -= r[i][j] * result[j] }
            result[i] /= r[i][i]
        }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}

