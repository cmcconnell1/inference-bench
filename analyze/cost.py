#!/usr/bin/env python3
"""Compute cost per million tokens for every measured point in a run.

    cost_per_1M_output_tokens = hourly_price / (output_tokens_per_second * 3600) * 1e6

Inputs:  a run directory fetched by bin/fetch-results.sh and profiles/pricing.json
Outputs: <run>/cost.csv and <run>/cost.json (also printed as a table)

Usage:
    python3 analyze/cost.py results/<run-id> [--price-per-hour P] [--pricing profiles/pricing.json] [--debug]

Standard library only.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.diag import Bundle  # noqa: E402
from lib.results import load_run  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--price-per-hour", type=float, default=None, help="override plan hourly price (USD)")
    ap.add_argument("--pricing", type=Path, default=Path(__file__).resolve().parents[1] / "profiles" / "pricing.json")
    ap.add_argument("--debug", action="store_true", help="write a support bundle to /var/tmp/chr-diag/ and print its path last")
    a = ap.parse_args()
    bundle = Bundle("cost", a.debug)

    # Plan comes from run.json (written by run-suite.sh) or, for older runs,
    # from the first engine's meta.json.
    data = load_run(a.run_dir)
    plan = data["run"].get("plan") or next((e["meta"].get("plan") for e in data["engines"].values()), "")
    price = a.price_per_hour
    if price is None:
        pricing = json.loads(a.pricing.read_text())
        price = (pricing.get("plans", {}).get(plan) or {}).get("hourly_usd")
    if price is None:
        print(f"ERROR: no hourly price for plan '{plan}'; pass --price-per-hour", file=sys.stderr)
        return 2

    # One row per measured point. Cost fields are None when throughput is
    # missing (failed point) rather than zero, so they render as n/a.
    rows = []
    for ename, e in data["engines"].items():
        for wname, w in e["workloads"].items():
            for p in w["points"]:
                m = p["metrics"]
                out_tps = (m.get("output_tps") or {}).get("mean")
                tot_tps = (m.get("total_tps") or {}).get("mean")
                rps = (m.get("rps") or {}).get("mean")
                row = {
                    "engine": ename, "workload": wname, "concurrency": p["concurrency"], "rep": p["rep"],
                    "plan": plan, "hourly_usd": price,
                    "output_tps": out_tps, "total_tps": tot_tps, "rps": rps,
                    "ttft_p50_ms": (m.get("ttft_ms") or {}).get("median"),
                    "ttft_p99_ms": (m.get("ttft_ms") or {}).get("p99"),
                    "tpot_p50_ms": (m.get("tpot_ms") or {}).get("median"),
                    "itl_p50_ms": (m.get("itl_ms") or {}).get("median"),
                    "usd_per_1m_output_tokens": round(price / (out_tps * 3600) * 1e6, 4) if out_tps else None,
                    "usd_per_1m_total_tokens": round(price / (tot_tps * 3600) * 1e6, 4) if tot_tps else None,
                    "usd_per_1k_requests": round(price / (rps * 3600) * 1e3, 4) if rps else None,
                    "gpu_util_mean": p["gpu"].get("gpu_util_mean"),
                    "gpu_mem_used_max_mib": p["gpu"].get("gpu_mem_used_max_mib"),
                    "precision": e["meta"].get("precision"),
                }
                rows.append(row)

    if not rows:
        print("no measured points found", file=sys.stderr)
        return 1
    # Sort so engines at the same concurrency sit next to each other.
    rows.sort(key=lambda r: (r["workload"], r["concurrency"], r["engine"], r["rep"]))
    out_csv = a.run_dir / "cost.csv"
    with out_csv.open("w", newline="") as fh:
        wr = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        wr.writeheader(); wr.writerows(rows)
    (a.run_dir / "cost.json").write_text(json.dumps({"plan": plan, "hourly_usd": price, "rows": rows}, indent=2))

    # Fixed-width console table; CSV and JSON carry the full precision.
    def f(v, w=9, d=2):
        return f"{v:{w}.{d}f}" if isinstance(v, (int, float)) else f"{'n/a':>{w}}"

    print(f"plan={plan} price=${price}/hr")
    print(f"{'workload':<22}{'engine':<10}{'conc':>5}{'out tok/s':>10}{'TTFT p50':>10}{'TPOT p50':>10}{'$/1M out':>10}{'gpu%':>6}")
    for r in rows:
        print(f"{r['workload']:<22}{r['engine']:<10}{r['concurrency']:>5}{f(r['output_tps'],10,1)}{f(r['ttft_p50_ms'],10,0)}"
              f"{f(r['tpot_p50_ms'],10,1)}{f(r['usd_per_1m_output_tokens'],10,3)}{f(r['gpu_util_mean'],6,0)}")
    bundle.add(out_csv, "cost table")
    bundle.add(a.run_dir / "run.json", "run metadata")
    bundle.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())
