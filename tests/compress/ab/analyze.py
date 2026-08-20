#!/usr/bin/env python3
"""Paired analysis for the frozen-corpus A/B (compression plan §5.3).

Reads results.jsonl written by run-ab.sh, pairs each fixture+rep's control call
with its guarded call, and reports MEDIAN paired deltas of provider-reported
input/output tokens with bootstrap 95% confidence intervals, overall and per
task category.

Honesty rules honoured here:
  * ground truth only — every number is provider-reported usage; no byte
    estimates, no dollars, no mixing of accounting classes;
  * pairs are dropped (and counted) if either arm failed, lacked usage fields,
    or the ledger recorded a different arm than requested — a call that did not
    demonstrably run guarded is never credited to the guarded arm;
  * medians + bootstrap CIs, never bare averages (plan §5.3);
  * small samples are labelled indicative, not claimable.

stdlib only. Deterministic (fixed bootstrap seed).
"""

import json
import random
import sys

BOOTSTRAP_ITERATIONS = 2000
BOOTSTRAP_SEED = 1234
CLAIM_THRESHOLD = 30  # matches accounting.minimum_claim_samples default


def median(values):
    ordered = sorted(values)
    count = len(ordered)
    mid = count // 2
    if count % 2:
        return float(ordered[mid])
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def bootstrap_ci_of_median(values, iterations=BOOTSTRAP_ITERATIONS):
    """Percentile bootstrap 95% CI for the median of paired deltas."""
    rng = random.Random(BOOTSTRAP_SEED)
    stats = sorted(
        median(rng.choices(values, k=len(values))) for _ in range(iterations)
    )
    lower = stats[int(0.025 * (iterations - 1))]
    upper = stats[int(0.975 * (iterations - 1))]
    return lower, upper


def load_pairs(path):
    rows = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))

    by_key = {}
    dropped = []
    for row in rows:
        reasons = []
        if row.get("exit") != 0:
            reasons.append("non-zero exit")
        if row.get("input_tokens") is None or row.get("output_tokens") is None:
            reasons.append("usage missing")
        if row.get("ledger_arm") is not None and row.get("ledger_arm") != row.get("arm"):
            reasons.append(
                "arm mismatch (asked %s, ledger says %s)"
                % (row.get("arm"), row.get("ledger_arm"))
            )
        if reasons:
            dropped.append((row, "; ".join(reasons)))
            continue
        by_key.setdefault((row["fixture"], row["rep"]), {})[row["arm"]] = row

    pairs = []
    for key in sorted(by_key):
        arms = by_key[key]
        if "control" in arms and "guarded" in arms:
            pairs.append((key, arms["control"], arms["guarded"]))
        else:
            only = next(iter(arms.values()))
            dropped.append((only, "unpaired (other arm unusable)"))
    return pairs, dropped


def deltas(pairs):
    out = {"in_abs": [], "out_abs": [], "in_pct": [], "out_pct": []}
    for _, control, guarded in pairs:
        d_in = guarded["input_tokens"] - control["input_tokens"]
        d_out = guarded["output_tokens"] - control["output_tokens"]
        out["in_abs"].append(d_in)
        out["out_abs"].append(d_out)
        if control["input_tokens"] > 0:
            out["in_pct"].append(100.0 * d_in / control["input_tokens"])
        if control["output_tokens"] > 0:
            out["out_pct"].append(100.0 * d_out / control["output_tokens"])
    return out


def describe(label, pairs):
    stats = deltas(pairs)
    lines = ["  %s (n=%d pairs)" % (label, len(pairs))]
    for name, abs_key, pct_key in (
        ("output tokens/call", "out_abs", "out_pct"),
        ("input tokens/call ", "in_abs", "in_pct"),
    ):
        abs_values = stats[abs_key]
        pct_values = stats[pct_key]
        if not abs_values:
            lines.append("    %s: no usable pairs" % name)
            continue
        lo, hi = bootstrap_ci_of_median(abs_values)
        pct = " (%+.1f%% median)" % median(pct_values) if pct_values else ""
        lines.append(
            "    %s: median delta %+.1f%s, 95%% CI [%+.1f, %+.1f]"
            % (name, median(abs_values), pct, lo, hi)
        )
    return "\n".join(lines)


def main():
    if len(sys.argv) != 2:
        print("usage: analyze.py <results.jsonl>", file=sys.stderr)
        return 2
    pairs, dropped = load_pairs(sys.argv[1])

    print("Frozen-corpus A/B — provider ground-truth usage (guarded vs control, paired)")
    print(
        "pairs: %d usable, %d rows dropped%s"
        % (len(pairs), len(dropped), "" if not dropped else " (see below)")
    )
    if not pairs:
        print("no usable pairs — nothing to report")
        return 1

    models = sorted({p[1].get("provider_model") or "?" for p in pairs})
    print("provider model(s): %s" % ", ".join(models))
    truncated = {
        arm: sum(
            1 for _, c, g in pairs
            if (c if arm == "control" else g).get("stop_reason") == "max_tokens"
        )
        for arm in ("control", "guarded")
    }
    if truncated["control"] or truncated["guarded"]:
        print(
            "truncated (max_tokens) calls: control %d, guarded %d — a truncated"
            % (truncated["control"], truncated["guarded"])
        )
        print("control call understates the true output delta (conservative).")
    print()
    print("overall")
    print(describe("all categories", pairs))
    print()
    print("by task category")
    categories = sorted({p[1]["category"] for p in pairs})
    for category in categories:
        subset = [p for p in pairs if p[1]["category"] == category]
        print(describe(category, subset))
    print()
    if len(pairs) < CLAIM_THRESHOLD:
        print(
            "NOTE: %d pairs < %d per arm — treat these numbers as indicative, not a"
            % (len(pairs), CLAIM_THRESHOLD)
        )
        print("claimable saving (plan §5.3 minimum claim threshold).")
    if dropped:
        print("dropped rows:")
        for row, reason in dropped:
            print(
                "  %s rep=%s %s — %s"
                % (row.get("fixture"), row.get("rep"), row.get("arm"), reason)
            )

    report = {
        "pairs": len(pairs),
        "dropped": len(dropped),
        "truncated_calls": truncated,
        "claim_threshold": CLAIM_THRESHOLD,
        "claimable": len(pairs) >= CLAIM_THRESHOLD,
        "overall": stats_json(pairs),
        "categories": {
            category: stats_json([p for p in pairs if p[1]["category"] == category])
            for category in categories
        },
    }
    report_path = sys.argv[1].rsplit("/", 1)[0] + "/report.json"
    with open(report_path, "w") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")
    return 0


def stats_json(pairs):
    stats = deltas(pairs)
    result = {"pairs": len(pairs)}
    for key, values in stats.items():
        if not values:
            continue
        entry = {"median": median(values)}
        if key.endswith("_abs"):
            lo, hi = bootstrap_ci_of_median(values)
            entry["ci95"] = [lo, hi]
        result[key] = entry
    return result


if __name__ == "__main__":
    sys.exit(main())
