"""Summarise continuous HFR measurements made with the focuser held fixed.

Uses disjoint groups of consecutive frames for the five-frame medians used
by autofocus. Groups containing a rejected measurement are omitted rather
than treating separated frames as consecutive. Reported spreads are empirical
variability, not confidence intervals for a best-focus estimate.
"""
import csv
import json
from pathlib import Path
import statistics as stats
import sys


def percentile(values, fraction):
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (index - lower) * (ordered[upper] - ordered[lower])


def summary(values):
    median = stats.median(values)
    mean = stats.mean(values)
    deviation = stats.stdev(values) if len(values) > 1 else 0.0
    return dict(count=len(values), mean_px=mean, median_px=median,
                standard_deviation_px=deviation,
                coefficient_of_variation_percent=100 * deviation / mean,
                mad_px=stats.median(abs(v - median) for v in values),
                minimum_px=min(values), maximum_px=max(values),
                p05_px=percentile(values, .05), p95_px=percentile(values, .95))


def stack_comparison(record, path):
    blocks = record.get("stackBlocks", [])
    fields = ("medianIndividualHFR", "unregisteredStackHFR", "registeredStackHFR")
    paired = [b for b in blocks if all(b.get(k) is not None for k in fields)]
    if not paired:
        return None
    for block in paired:
        start = block["firstFrame"]
        frames = record["frames"][start:start + block["frameCount"]]
        assert len(frames) == 15 and all(f.get("hfr") is not None for f in frames)
        assert abs(stats.median(f["hfr"] for f in frames) - block["medianIndividualHFR"]) < 1e-10
    methods = {}
    reference = [b["medianIndividualHFR"] for b in paired]
    baseline_deviation = stats.stdev(reference)
    for field in fields:
        values = [b[field] for b in paired]
        comparisons = [100 * (b[field] / a[field] - 1) for a, b in zip(paired, paired[1:])
                       if b["firstFrame"] == a["firstFrame"] + 15]
        ten_second_medians = []
        for start in range(0, int(record["requestedSeconds"]), 10):
            group = [b[field] for b in paired if start <= b["elapsedSeconds"] < start + 10]
            if group:
                ten_second_medians.append(dict(start_seconds=start, median_hfr_px=stats.median(group)))
        methods[field] = dict(summary=summary(values),
            mean_paired_difference_px=stats.mean(v - r for v, r in zip(values, reference)),
            absolute_sd_reduction_percent=100 * (1 - stats.stdev(values) / baseline_deviation) if baseline_deviation else None,
            adjacent_comparisons=len(comparisons),
            adjacent_increases_over_15_percent=sum(v > 15 for v in comparisons),
            largest_adjacent_increase_percent=max(comparisons) if comparisons else None,
            ten_second_medians=ten_second_medians)
    with path.with_name(path.stem + "-stack-comparison.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        columns = ("firstFrame", "elapsedSeconds", "frameCount", *fields,
                   "centroidSpanX", "centroidSpanY", "referenceCentroidX", "referenceCentroidY", "rejection")
        writer.writerow(columns)
        writer.writerows([b.get(k) for k in columns] for b in blocks)
    return dict(paired_blocks=len(paired), recorded_blocks=len(blocks),
                incomplete_trailing_frames=len(record["frames"]) % 15,
                methods=methods,
                note="Both pixel stacks average exactly the same 15 frames as the median HFR. Registered stacks use bilinear shifts onto the first-frame centroid; pixels stay at original ADU scale.")


def analyse(path):
    record = json.loads(path.read_text(encoding="utf-8"))
    if record["status"] != "complete":
        raise ValueError("Recording did not complete: " + record["status"])
    if record["initialPosition"] != record["finalPosition"] or record["finalMotorMoving"]:
        raise ValueError("Focuser did not remain at its stopped initial position")
    frames = record["frames"]
    valid = [f for f in frames if f.get("hfr") is not None]
    if len(valid) < 100:
        raise ValueError("Too few valid HFR measurements")
    groups = {}
    for size in (5, 15):
        medians = []
        for i in range(0, len(frames) - size + 1, size):
            block = frames[i:i + size]
            if all(f.get("hfr") is not None for f in block):
                medians.append(dict(first_frame=i, elapsed_seconds=block[0]["elapsedSeconds"],
                                    median_hfr_px=stats.median(f["hfr"] for f in block)))
        groups[str(size)] = dict(summary=summary([b["median_hfr_px"] for b in medians]),
                                 blocks=medians)
    bins = []
    for start in range(0, int(record["requestedSeconds"]), 10):
        values = [f["hfr"] for f in valid if start <= f["elapsedSeconds"] < start + 10]
        if values:
            bins.append(dict(start_seconds=start, **summary(values)))
    minute_bins = []
    for start in range(0, int(record["requestedSeconds"]), 60):
        values = [f["hfr"] for f in valid if start <= f["elapsedSeconds"] < start + 60]
        if len(values) >= 100:
            minute_bins.append(dict(start_seconds=start, **summary(values)))
    five = groups["5"]["blocks"]
    comparisons = []
    for a, b in zip(five, five[1:]):
        if b["first_frame"] != a["first_frame"] + 5:
            continue
        comparisons.append(100 * (b["median_hfr_px"] / a["median_hfr_px"] - 1))
    durations = [b["timestamp"] - a["timestamp"] for a, b in zip(frames, frames[1:])]
    # Serial status is read before and after recording; capture is continuous
    # during the measurement, with no autofocus or take-up moves.
    values = [f["hfr"] for f in valid]
    mean = stats.mean(values)
    lag_numerator = sum((a - mean) * (b - mean) for a, b in zip(values, values[1:]))
    lag_denominator = sum((v - mean) ** 2 for v in values)
    result = dict(method="Continuous frames with fixed focus; empirical disjoint-block medians",
                  position_steps=record["initialPosition"], final_position_steps=record["finalPosition"],
                  exposure_microseconds=record["exposureMicroseconds"], gain=record["gain"],
                  duration_seconds=frames[-1]["elapsedSeconds"] - frames[0]["elapsedSeconds"],
                  recorded_frames=len(frames), rejected_frames=len(frames) - len(valid),
                  frames_per_second=1 / stats.mean(durations),
                  frame_interval_ms_p50=1000 * percentile(durations, .5),
                  frame_interval_ms_p95=1000 * percentile(durations, .95),
                  individual_frames=summary(values),
                  lag1_hfr_correlation=lag_numerator / lag_denominator if lag_denominator else 0,
                  block_medians=groups, ten_second_bins=bins,
                  sixty_second_bins=minute_bins,
                  first_to_second_minute_median_change_percent=(100 * (minute_bins[1]["median_px"] / minute_bins[0]["median_px"] - 1)
                      if len(minute_bins) >= 2 else None),
                  restored_position_steps=record.get("restoredPosition"),
                  adjacent_five_frame_comparisons=len(comparisons),
                  adjacent_five_frame_increases_over_15_percent=sum(v > 15 for v in comparisons),
                  adjacent_five_frame_absolute_changes_over_15_percent=sum(abs(v) > 15 for v in comparisons),
                  sensor_x_range=[min(f["sensorX"] for f in valid), max(f["sensorX"] for f in valid)],
                  sensor_y_range=[min(f["sensorY"] for f in valid), max(f["sensorY"] for f in valid)],
                  peak_adu_range=[min(f["peak"] for f in valid), max(f["peak"] for f in valid)],
                  note="Spread includes optical and image variations with motors held fixed; it is not solely estimator noise.")
    paired_stacks = stack_comparison(record, path)
    if paired_stacks is not None:
        result["stack_comparison"] = paired_stacks
    path.with_name(path.stem + "-analysis.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    with path.with_suffix(".csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        columns = ("index", "elapsedSeconds", "timestamp", "hfr", "sensorX", "sensorY", "peak", "snr", "rejection")
        writer.writerow(columns)
        writer.writerows([f.get(k) for k in columns] for f in frames)
    compact = dict(result)
    compact["block_medians"] = {n: group["summary"] for n, group in groups.items()}
    print(json.dumps(compact, indent=2))


if __name__ == "__main__":
    analyse(Path(sys.argv[1]))
