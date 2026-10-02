"""Summarise five-frame HFR medians from repeated compensated focus jumps.

The primary spread is between visits at each fixed target. It includes image
variation and focus drift as well as mechanical return repeatability. Raw
frame scatter within a visit is reported separately, without pooling the
two target positions into one distribution.
"""
import csv
import json
from pathlib import Path
import statistics as stats
import sys


def analyse(path):
    record = json.loads(path.read_text(encoding="utf-8"))
    if record.get("experiment") != "alternating-defocus-jumps" or record["status"] != "complete":
        raise ValueError("Expected a completed alternating-jump experiment")
    if record["samplesPerPoint"] != 5 or record["finalPosition"] != record["scanCenter"]:
        raise ValueError("Incorrect measurement size or unrestored reference")
    visits = record["visitsPerPosition"]
    samples = [p for p in record["points"] if p["pass"] not in ("baseline", "restore")]
    expected_names = [f"{side}{cycle}" for cycle in range(1, visits + 1) for side in ("low", "high")]
    if [p["pass"] for p in samples] != expected_names:
        raise ValueError("Missing visits or non-alternating sequence")
    rows = []
    for point in samples:
        side = "low" if point["pass"].startswith("low") else "high"
        offset = -record["halfSpan"] if side == "low" else record["halfSpan"]
        values = [f["hfr"] for f in point["frames"]]
        assert len(values) == 5 and abs(stats.median(values) - point["hfr"]) < 1e-10
        assert point["position"] == record["scanCenter"] + offset
        assert point["direction"] == "outward"
        rows.append(dict(location=side, cycle=int(point["pass"][len(side):]),
            position_steps=point["position"], offset_steps=offset,
            timestamp_unix=point["timestamp"], median_hfr_px=point["hfr"],
            within_visit_frame_sd_px=stats.stdev(values),
            peak_adu_max=max(f["peak"] for f in point["frames"]),
            sensor_x=stats.mean(f["sensorX"] for f in point["frames"]),
            sensor_y=stats.mean(f["sensorY"] for f in point["frames"])))
    summaries = []
    for side in ("low", "high"):
        selected = [p for p in rows if p["location"] == side]
        values = [p["median_hfr_px"] for p in selected]
        mean = stats.mean(values)
        median = stats.median(values)
        sd = stats.stdev(values)
        half = len(values) // 2
        first, second = stats.mean(values[:half]), stats.mean(values[half:])
        changes = [100 * (b / a - 1) for a, b in zip(values, values[1:])]
        summaries.append(dict(location=side, position_steps=selected[0]["position_steps"],
            offset_steps=selected[0]["offset_steps"], visits=len(values),
            mean_hfr_px=mean, median_hfr_px=median, between_visits_sd_px=sd,
            between_visits_cv_percent=100 * sd / mean,
            between_visits_mad_px=stats.median(abs(v - median) for v in values),
            minimum_hfr_px=min(values), maximum_hfr_px=max(values),
            mean_within_visit_frame_sd_px=stats.mean(p["within_visit_frame_sd_px"] for p in selected),
            first_half_mean_px=first, second_half_mean_px=second,
            second_vs_first_half_change_percent=100 * (second / first - 1),
            successive_visit_increases_over_15_percent=sum(v > 15 for v in changes),
            largest_successive_visit_increase_percent=max(changes)))
    result = dict(method="One five-frame median after each compensated target return; sample SD across visits at each location",
        reference_position_steps=record["scanCenter"], preload_steps=record["preload"], approach_direction="outward",
        settle_seconds=record["settleSeconds"], samples_per_visit=5,
        exposure_microseconds=record["exposureMicroseconds"], gain=record["gain"],
        target_visits=len(rows), target_frames=5 * len(rows),
        elapsed_visit_seconds=rows[-1]["timestamp_unix"] - rows[0]["timestamp_unix"],
        max_target_peak_adu=max(p["peak_adu_max"] for p in rows),
        final_position_steps=record["finalPosition"],
        summaries=summaries,
        note="Spread includes image variation, focus drift and mechanical return repeatability; these are not isolated by this experiment.")
    path.with_name(path.stem + "-analysis.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    for suffix, values in (("-visits.csv", rows), ("-summary.csv", summaries)):
        with path.with_name(path.stem + suffix).open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(values[0]))
            writer.writeheader()
            writer.writerows(values)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    analyse(Path(sys.argv[1]))
