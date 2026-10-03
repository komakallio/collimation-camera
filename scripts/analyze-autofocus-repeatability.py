"""Summarise every attempted old/new shared-engine autofocus run.

Position spread, starting-side difference, failures, recovery and temporal
trend are primary. HFR alone is not a focus-repeatability acceptance metric.
"""
import csv
import json
import statistics as stats
import sys
from datetime import datetime
from pathlib import Path


def analyse(path):
    record = json.loads(path.read_text(encoding="utf-8"))
    rows = []
    for i, attempt in enumerate(record["attempts"]):
        result = attempt.get("result")
        diagnostics = attempt.get("diagnostics", {})
        fit = diagnostics.get("fit", {})
        row = dict(index=i + 1, policy=attempt["policy"], start=attempt["startPosition"],
                   side="low" if attempt["startPosition"] < record["reference"] else "high",
                   time=attempt["startedAt"], duration=attempt["duration"],
                   position=result["position"] if result else None,
                   hfr=result.get("hfr") if result else None,
                   exposure_us=result["exposureMicroseconds"] if result else None,
                   uncertainty_steps=fit.get("uncertaintySteps"),
                   fitted_position=fit.get("position"),
                   loo_steps=fit.get("leaveOneOutMaximumSteps"), model=fit.get("model"),
                   verification_policy=diagnostics.get("verificationPolicy"),
                   recovery_fitted_position=diagnostics.get("recoveryFittedPosition"),
                   recovery=diagnostics.get("recoveryOutcome"), error=attempt.get("error"))
        final_blocks = diagnostics.get("verification", [])
        row["attempted_final_position"] = result["position"] if result else (final_blocks[-1]["position"] if final_blocks else None)
        curves = diagnostics.get("curves", [])
        samples = [sample for curve in curves for sample in curve]
        exposures = [sample["exposureMicroseconds"] for sample in samples
                     if sample.get("exposureMicroseconds") is not None]
        row["minimum_curve_exposure_us"] = min(exposures) if exposures else None
        row["maximum_curve_exposure_us"] = max(exposures) if exposures else None
        row["curve_attempts"] = len(curves)
        row["verification_blocks"] = len(diagnostics.get("verification", []))
        row["unavailable_final_hfr_blocks"] = len(diagnostics.get("finalMeasurementIssues", []))
        row["unavailable_final_hfr_blocks"] = len(diagnostics.get("finalMeasurementIssues", []))
        row["rejected_frames"] = sum(sample.get("rejectedFrames", 0) for sample in samples)
        rows.append(row)
    summaries = []
    for policy in ("legacy", "production"):
        attempted = [r for r in rows if r["policy"] == policy]
        successful = [r for r in attempted if r["position"] is not None]
        positions = [r["position"] for r in successful]
        low = [r["position"] for r in successful if r["side"] == "low"]
        high = [r["position"] for r in successful if r["side"] == "high"]
        summary = dict(policy=policy, attempts=len(attempted), successes=len(successful),
                       failures=len(attempted) - len(successful),
                       recovery_attempts=sum(bool(r["recovery"]) for r in attempted),
                       recovery_successes=sum(bool(r["recovery"]) for r in successful),
                       mean_duration_seconds=stats.mean(r["duration"] for r in attempted) if attempted else None,
                       mean_position=stats.mean(positions) if positions else None,
                       sd_position=stats.stdev(positions) if len(positions) > 1 else None,
                       min_position=min(positions) if positions else None,
                       max_position=max(positions) if positions else None,
                       high_minus_low_mean=stats.mean(high) - stats.mean(low) if high and low else None,
                       low_successes=len(low), high_successes=len(high))
        if len(successful) > 2:
            times = [datetime.fromisoformat(r["time"].replace("Z", "+00:00")).timestamp() for r in successful]
            origin = times[0]
            x = [(t - origin) / 60 for t in times]
            xm, ym = stats.mean(x), stats.mean(positions)
            denominator = sum((v - xm)**2 for v in x)
            slope = sum((v - xm)*(p - ym) for v, p in zip(x, positions)) / denominator if denominator else 0
            summary["temporal_slope_steps_per_minute"] = slope
            summary["detrended_sd_steps"] = stats.stdev(p - slope*(v - xm) for p, v in zip(positions, x))
            summary["first_half_mean"] = stats.mean(positions[:len(positions)//2])
            summary["second_half_mean"] = stats.mean(positions[len(positions)//2:])
        targets = [r["attempted_final_position"] for r in attempted if r["attempted_final_position"] is not None]
        summary["all_measured_final_targets_count"] = len(targets)
        summary["all_measured_final_targets_sd_steps"] = stats.stdev(targets) if len(targets) > 1 else None
        uncertainty = [r["uncertainty_steps"] for r in successful if r["uncertainty_steps"] is not None]
        summary["mean_fitted_uncertainty_steps"] = stats.mean(uncertainty) if uncertainty else None
        fitted = [r["fitted_position"] for r in attempted if r["fitted_position"] is not None]
        summary["all_fitted_positions_sd_steps"] = stats.stdev(fitted) if len(fitted) > 1 else None
        exposures = [r[key] for r in attempted for key in
                     ("minimum_curve_exposure_us", "maximum_curve_exposure_us") if r[key] is not None]
        summary["minimum_curve_exposure_us"] = min(exposures) if exposures else None
        summary["maximum_curve_exposure_us"] = max(exposures) if exposures else None
        summary["minimum_duration_seconds"] = min((r["duration"] for r in attempted), default=None)
        summary["maximum_duration_seconds"] = max((r["duration"] for r in attempted), default=None)
        summaries.append(summary)
    analysis = dict(status=record["status"], reference=record.get("reference"), step=record["step"],
                    take_up=record["takeUp"], mount_unchanged=record.get("mountAfter") == record["mountBefore"],
                    restored=record.get("restoredPosition") == record.get("reference") and record.get("restoredMoving") is False,
                    summaries=summaries,
                    limitation="Small-sample descriptive comparison; temporal trend is not proof of drift or a calibrated confidence interval.")
    output = path.with_name(path.stem + "-analysis.json")
    output.write_text(json.dumps(analysis, indent=2) + "\n", encoding="utf-8")
    if rows:
        with path.with_name(path.stem + "-attempts.csv").open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(file, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    print(json.dumps(analysis, indent=2))
    return analysis


if __name__ == "__main__":
    analyse(Path(sys.argv[1]))
