"""Estimate direction-dependent focus hysteresis from matched curve flanks.

Interpolate equal-HFR crossings on each flank. Bracket each inward scan with
outward scans and interpolate their crossing positions in time, so a linear
focus drift does not masquerade as backlash. The signed offset is inward minus
outward motor position. Individual-frame bootstrap measures frame noise only;
flank disagreement and cycle-to-cycle variation are reported separately.
Both flanks have equal weight, even if their usable HFR ranges differ.
"""
import csv
import json
from pathlib import Path
import random
import statistics as stats
import sys

LEVELS = [1.5 + i * 0.1 for i in range(12)]


def crossing(curve, level, side):
    points = sorted(curve, key=lambda p: p["position"])
    best = min(range(len(points)), key=lambda i: points[i]["hfr"])
    flank = points[:best + 1] if side == "left" else points[best:]
    matches = []
    for a, b in zip(flank, flank[1:]):
        if min(a["hfr"], b["hfr"]) < level <= max(a["hfr"], b["hfr"]):
            fraction = (level - a["hfr"]) / (b["hfr"] - a["hfr"])
            matches.append((a["position"] + fraction * (b["position"] - a["position"]),
                            a["timestamp"] + fraction * (b["timestamp"] - a["timestamp"])))
    return matches[0] if len(matches) == 1 else None


def paired_shifts(before, inward, after):
    shifts = []
    for side in ("left", "right"):
        for level in LEVELS:
            a, b, c = (crossing(curve, level, side) for curve in (before, inward, after))
            if a is None or b is None or c is None or not a[1] < b[1] < c[1]:
                continue
            fraction = (b[1] - a[1]) / (c[1] - a[1])
            reference = a[0] + fraction * (c[0] - a[0])
            shifts.append(dict(side=side, level=level, shift=b[0] - reference,
                               inward_position=b[0], reference_position=reference,
                               outward_drift=c[0] - a[0]))
    return shifts


def estimate(shifts):
    if any(sum(s["side"] == side for s in shifts) < 3 for side in ("left", "right")):
        raise ValueError("Not enough unambiguous crossings on both focus flanks")
    return stats.mean(stats.median(s["shift"] for s in shifts if s["side"] == side)
                      for side in ("left", "right"))


def synthetic_check(offset):
    import math
    curves = []
    for j, direction in enumerate(("out", "in", "out")):
        values = list(range(-2500, 2501, 250))
        if direction == "in":
            values.reverse()
        curve = []
        for i, position in enumerate(values):
            timestamp = 30 * j + i
            best = 2 * timestamp + (offset if direction == "in" else 0)
            curve.append(dict(position=position, timestamp=timestamp,
                              hfr=math.sqrt(1 + ((position - best) / 800) ** 2)))
        curves.append(curve)
    measured = estimate(paired_shifts(*curves))
    assert abs(measured - offset) < 40, (offset, measured)


def analyse(path):
    for offset in (0, 700, -700):
        synthetic_check(offset)
    record = json.loads(path.read_text(encoding="utf-8"))
    assert record["status"] == "complete", record["status"]
    curves = {name: [p for p in record["points"] if p["pass"] == name]
              for name in ("out1", "in1", "out2", "in2", "out3")}
    count = 2 * record["halfSpan"] // record["step"] + 1
    assert all(len(c) == count for c in curves.values())
    pairs = [("out1", "in1", "out2"), ("out2", "in2", "out3")]
    results = []
    rng = random.Random(20261002)
    for names in pairs:
        shifts = paired_shifts(*(curves[n] for n in names))
        value = estimate(shifts)
        bootstrap = []
        for _ in range(1000):
            sampled = []
            for name in names:
                curve = []
                for p in curves[name]:
                    values = [f["hfr"] for f in p["frames"]]
                    curve.append(dict(p, hfr=stats.median(rng.choices(values, k=len(values)))))
                sampled.append(curve)
            try:
                bootstrap.append(estimate(paired_shifts(*sampled)))
            except ValueError:
                pass
        bootstrap.sort()
        ci = [bootstrap[int(len(bootstrap) * fraction)] for fraction in (.025, .975)]
        result = dict(inward_pass=names[1], signed_shift_steps=value,
                      frame_bootstrap_ci_95=ci, bootstrap_count=len(bootstrap),
                      pooled_crossing_median=stats.median(s["shift"] for s in shifts),
                      left_flank_median=stats.median(s["shift"] for s in shifts if s["side"] == "left"),
                      right_flank_median=stats.median(s["shift"] for s in shifts if s["side"] == "right"),
                      matched_crossings=shifts)
        results.append(result)
    combined = stats.mean(r["signed_shift_steps"] for r in results)
    frames = [f for p in record["points"] for f in p["frames"]]
    summary = dict(method="Time-bracketed equal-HFR crossings, mean of both flank medians; inward minus outward position",
                   signed_mean_steps=combined, effective_hysteresis_steps=abs(combined),
                   cycle_difference_steps=abs(results[0]["signed_shift_steps"] - results[1]["signed_shift_steps"]),
                   pairs=results, warning="Bootstrap intervals cover frame noise, not all systematic errors.",
                   scan_minima={name: {k: min(c, key=lambda p: p["hfr"])[k] for k in ("position", "hfr")}
                                for name, c in curves.items()},
                   total_points=len(record["points"]), total_frames=len(frames),
                   max_peak=max(f["peak"] for f in frames),
                   sensor_x_range=[min(f["sensorX"] for f in frames), max(f["sensorX"] for f in frames)],
                   sensor_y_range=[min(f["sensorY"] for f in frames), max(f["sensorY"] for f in frames)],
                   final_position=record["finalPosition"], final_hfr=record["finalHFR"],
                   final_warning=record.get("warning"))
    path.with_name(path.stem + "-analysis.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    with path.with_suffix(".csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["pass", "direction", "position_steps", "timestamp_unix", "median_hfr_px", "mad_hfr_px"])
        for point in record["points"]:
            writer.writerow([point[k] for k in ("pass", "direction", "position", "timestamp", "hfr", "mad")])
    print(json.dumps({k: v for k, v in summary.items() if k != "pairs"}, indent=2))
    for result in results:
        print(f'{result["inward_pass"]}: signed {result["signed_shift_steps"]:.1f} steps; '
              f'left {result["left_flank_median"]:.1f}, right {result["right_flank_median"]:.1f}; '
              f'frame bootstrap 95% {result["frame_bootstrap_ci_95"]}')
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("Plot library unavailable; CSV and analysis JSON saved.")
        return
    fig, axes = plt.subplots(1, 2, figsize=(12, 5), constrained_layout=True)
    colours = ["#1b4f8a", "#b13434", "#3b7eb7", "#e27735", "#55a8cb"]
    for (name, curve), colour in zip(curves.items(), colours):
        p = sorted(curve, key=lambda x: x["position"])
        axes[0].errorbar([v["position"] for v in p], [v["hfr"] for v in p],
                         yerr=[v["mad"] for v in p], color=colour,
                         linestyle="--" if name.startswith("in") else "-", marker=".", label=name)
    axes[0].set(xlabel="Reported focuser position (steps)", ylabel="Median HFR (sensor pixels)",
                title="Centre-star focus curves; error bars show frame MAD")
    axes[0].legend(ncol=3)
    axes[0].grid(alpha=.2)
    for result, colour, marker in zip(results, ("#b13434", "#e27735"), ("o", "s")):
        for side, filled in (("left", True), ("right", False)):
            values = [s for s in result["matched_crossings"] if s["side"] == side]
            axes[1].scatter([s["level"] for s in values], [s["shift"] for s in values],
                            marker=marker, facecolors=colour if filled else "none", edgecolors=colour,
                            label=result["inward_pass"] + " " + side + " flank")
        axes[1].axhline(result["signed_shift_steps"], color=colour, linestyle=":")
    axes[1].axhline(0, color="black", linewidth=.8)
    axes[1].set(xlabel="Matched HFR (sensor pixels)", ylabel="Inward minus outward position (steps)",
                title="Direction-dependent offset after bracketing focus drift")
    axes[1].legend(fontsize=8)
    axes[1].grid(alpha=.2)
    fig.suptitle("Focuser backlash estimate — centre star, COM4; mount stopped on COM10")
    fig.savefig(path.with_suffix(".png"), dpi=180)
    fig.savefig(path.with_suffix(".svg"))
    plt.close(fig)


if __name__ == "__main__":
    analyse(Path(sys.argv[1]))
