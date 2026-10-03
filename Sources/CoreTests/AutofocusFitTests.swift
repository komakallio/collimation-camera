import CollimationCore
import CollimationUI
import Foundation

func testAutofocusFullCurveFit() throws {
    let plan = try AutofocusPlan(position: 316750, maximum: 731000, step: 500)
    let settings = AutofocusSettings(step: 500)
    func curve(center: Double = 0.075, h0: Double = 1.4, k: Double = 3.2, t: Double = 0,
               noise: [Double] = Array(repeating: 0, count: 9)) -> [AutofocusSample] {
        plan.positions.enumerated().map { i, position in
            let u = Double(position - 316750) / 2000 - center
            return AutofocusSample(position: position, hfr: hypot(h0, k * u) + t * u + noise[i])
        }
    }
    let symmetric = try plan.fit(samples: curve())
    try expectUI(symmetric.model == .symmetric && abs(symmetric.position - 316900) <= 1,
                 "full symmetric curve recovers known sub-step focus")
    try expectUI(symmetric.residualRMS < 1e-6 && symmetric.uncertaintySteps > 0,
                 "even a perfect curve retains the uncertainty floor")
    try expectUI(symmetric.leaveOneOutPositions.count == 9 && symmetric.leaveOneOutMaximumSteps < 1,
                 "all nine omissions reported")
    let asymmetric = try plan.fit(samples: curve(center: 0.15, h0: 1.4, k: 3.2, t: 0.9))
    let expectedMinimum = 0.15 - 0.9 * 1.4 / (3.2 * sqrt(3.2 * 3.2 - 0.9 * 0.9))
    try expectUI(asymmetric.model == .asymmetric && abs(asymmetric.position - (316750 + Int((2000 * expectedMinimum).rounded()))) <= 1,
                 "asymmetric minimum differs from fitted centre and matches calculus")
    try expectUI(abs(asymmetric.predict(at: asymmetric.position) - 1.4 * sqrt(1 - pow(0.9 / 3.2, 2))) < 1e-5,
                 "actual asymmetric minimum HFR")
    let noise = [0.04, -0.03, 0.02, 0.04, -0.08, 0.05, -0.02, 0.03, -0.02]
    let noisy = try plan.fit(samples: curve(noise: noise))
    try expectUI(abs(noisy.position - 316900) < 150 && noisy.uncertaintySteps > 0
        && noisy.leaveOneOutMaximumSteps > symmetric.leaveOneOutMaximumSteps,
                 "near-focus noise increases omission sensitivity without destabilising the solution")
    var isolated = curve(); isolated[2] = AutofocusSample(position: isolated[2].position, hfr: isolated[2].hfr + 0.8)
    let robust = try plan.fit(samples: isolated)
    try expectUI(abs(robust.position - 316900) < 120 && robust.downweightedIndices.contains(2),
                 "one isolated outlier is bounded and reported")
    var unequal = curve(noise: noise); unequal[1] = AutofocusSample(position: unequal[1].position, hfr: unequal[1].hfr + 0.2)
    unequal[1].scatter = 0.5
    let weighted = try plan.fit(samples: unequal)
    try expectUI(abs(weighted.position - 316900) < 150, "unequal point scatter is retained in weighted fit")
    var tinyScatter = curve(); for i in tinyScatter.indices { tinyScatter[i].scatter = 1e-10 }
    let floored = try plan.fit(samples: tinyScatter)
    try expectUI(abs(floored.uncertaintySteps - symmetric.uncertaintySteps) < 0.01,
                 "near-zero scatter cannot create unlimited weight")
    try expectUI(settings.takeUp > settings.step && plan.preloadPosition == plan.positions[0] - 4000,
                 "scan spacing can be smaller than take-up")
    for values in [Array(repeating: 2.0, count: 9), [2, 2.01, 2, 1.99, 1.98, 2.01, 2, 2, 2],
                   [9, 8, 7, 6, 5, 4, 3, 2, 1], [1, 4, 2, 5, 1, 5, 2, 4, 3],
                   [3, 3, 3, 3, Double.nan, 3, 3, 3, 3], [3, 3, 3, 3, Double.infinity, 3, 3, 3, 3]] {
        do {
            _ = try plan.fit(samples: zip(plan.positions, values).map { AutofocusSample(position: $0, hfr: $1) })
            throw UIModelExpectation(description: "unsupported curve accepted: \(values)")
        } catch is AutofocusError { }
    }
    do { _ = try AutofocusFitter.fit(curve(), maximumIterations: 1); throw UIModelExpectation(description: "unconverged fit accepted") }
    catch AutofocusError.unstableFit { }
    let largeOrigin = Int.max / 2
    let large = try AutofocusPlan(position: largeOrigin, maximum: Int.max, step: 500)
    let largeSamples = zip(large.positions, curve()).map { AutofocusSample(position: $0, hfr: $1.hfr) }
    try expectUI(try large.solution(samples: largeSamples) == largeOrigin + 150, "large absolute positions preserve sub-step solution")
    for (target, maximum, takeUp) in [(3999, 731000, 4000), (Int.min, Int.max, 4000), (Int.max, Int.max - 1, 4000), (5000, 10000, Int.max)] {
        do { _ = try AutofocusPlan.approach(target: target, maximum: maximum, takeUp: takeUp); throw UIModelExpectation(description: "unsafe take-up accepted") }
        catch AutofocusError.invalidRange { }
    }
}

func testAutofocusUISettings() throws {
    for path in ["Sources/CollimationApp/SidebarView.swift", "Sources/CollimationPortableApp/UI/Sidebar.swift"] {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent(path), encoding: .utf8)
        try expectUI(source.contains("autofocusTakeUpSteps") && source.contains("HelpText.autofocusTakeUp")
            && source.contains("MetricText.focusUncertainty"), "both sidebars expose shared settings and uncertainty")
    }
    try expectUI(MetricText.autofocus(.recordingFinalHFR(position: 123, block: 2), samples: 9).contains("2/3"), "shared final diagnostic status")
    try expectUI(HelpText.autofocus.contains("diagnostic only") && !HelpText.autofocus.contains("local bracket"), "final HFR is not an acceptance rule")
    try expectUI(!HelpText.autofocusStep.contains("larger than backlash"), "sampling spacing has independent guidance")
}
