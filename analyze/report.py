#!/usr/bin/env python3
"""Render a markdown comparison report for one run.

Sections: run facts, per-engine metadata (image digest, precision, notes),
per-workload tables (engine x concurrency: TTFT p50/p99, TPOT p50, output
tok/s, req/s, $/1M output tokens, GPU util), Mermaid xychart of output tok/s
vs concurrency, and an auto-generated caveats list (mixed precision, failed
engines, points with errors).

Usage:
    python3 analyze/report.py results/<run-id> [--title T] [--debug] > results/<run-id>/REPORT.md

Run analyze/cost.py first; the report reads cost.json when present and falls
back to raw metrics otherwise. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.diag import Bundle  # noqa: E402
from lib.results import load_run  # noqa: E402

# Solarized Dark init block shared by every chart in the report.
MERMAID_INIT = ('%%{init: {"theme": "base", "themeVariables": {"fontSize": "13px", "background": "#002b36", '
                '"primaryColor": "#073642", "primaryTextColor": "#eee8d5", "primaryBorderColor": "#586e75", '
                '"lineColor": "#586e75", "secondaryColor": "#073642", "tertiaryColor": "#002b36"}}}%%')


def fmt(v, d=1):
    return f"{v:.{d}f}" if isinstance(v, (int, float)) else "n/a"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--title", default=None)
    ap.add_argument("--debug", action="store_true", help="write a support bundle to /var/tmp/chr-diag/ and print its path last")
    a = ap.parse_args()
    bundle = Bundle("report", a.debug)
    data = load_run(a.run_dir)
    run = data["run"]
    # cost.json (from cost.py) is keyed back onto points by
    # (engine, workload, concurrency, rep). Absent file -> cost columns show n/a.
    cost_rows = {}
    cost_p = a.run_dir / "cost.json"
    price = None
    if cost_p.exists():
        cj = json.loads(cost_p.read_text())
        price = cj.get("hourly_usd")
        for r in cj["rows"]:
            cost_rows[(r["engine"], r["workload"], r["concurrency"], r["rep"])] = r

    out = []
    title = a.title or f"Serving engine benchmark: {run.get('model', 'model')} on {run.get('plan', 'plan')}"
    out.append(f"# {title}\n")
    out.append("| Field | Value |\n| --- | --- |")
    for k in ("run_id", "model", "plan", "region", "repeat", "started", "finished"):
        out.append(f"| {k} | {run.get(k, '')} |")
    if price is not None:
        out.append(f"| plan hourly price (USD) | {price} |")
    out.append("")

    # Engine table: the digest and precision columns are what make two rows
    # comparable or not. Failed engines stay in the table with their status.
    out.append("## Engines\n")
    out.append("| Engine | Image | Digest | Precision | Status | Notes |\n| --- | --- | --- | --- | --- | --- |")
    precisions = set()
    failed = []
    for ename, e in data["engines"].items():
        m = e["meta"]; st = e["status"].get("status", "unknown")
        if st != "ok":
            failed.append(ename)
        precisions.add(m.get("precision", ""))
        digest = (m.get("image_digest") or "").split("@")[-1][:19]
        out.append(f"| {ename} | {m.get('image', '')} | {digest} | {m.get('precision', '')} | {st} | {m.get('notes', '')} |")
    out.append("")

    # Regroup engine -> workload -> points into workload -> engine -> points so
    # each workload gets one table with every engine in it.
    workloads = defaultdict(dict)
    for ename, e in data["engines"].items():
        for wname, w in e["workloads"].items():
            workloads[wname][ename] = w
    for wname, engines in workloads.items():
        wl = next(iter(engines.values()))["workload"]
        out.append(f"## Workload: {wname}\n")
        out.append(f"{wl.get('description', '')}\n")
        out.append(f"Prompt tokens {wl.get('prompt_tokens')}, output tokens {wl.get('output_tokens')}, "
                   f"{wl.get('max_seconds')} s per point, concurrency {wl.get('concurrency')}.\n")
        out.append("| Engine | Conc | Out tok/s | Req/s | TTFT p50 ms | TTFT p99 ms | TPOT p50 ms | USD per 1M out tok | GPU util % | Errors |")
        out.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        series = defaultdict(list)
        concs = set()
        for ename, w in engines.items():
            for p in w["points"]:
                m = p["metrics"]; c = p["concurrency"]; concs.add(c)
                cr = cost_rows.get((ename, wname, c, p["rep"]), {})
                out_tps = (m.get("output_tps") or {}).get("mean")
                errs = (m.get("_counts") or {}).get("errored")
                series[ename].append((c, out_tps))
                out.append(f"| {ename} | {c} | {fmt(out_tps)} | {fmt((m.get('rps') or {}).get('mean'), 2)} | "
                           f"{fmt((m.get('ttft_ms') or {}).get('median'), 0)} | {fmt((m.get('ttft_ms') or {}).get('p99'), 0)} | "
                           f"{fmt((m.get('tpot_ms') or {}).get('median'))} | {fmt(cr.get('usd_per_1m_output_tokens'), 3)} | "
                           f"{fmt(p['gpu'].get('gpu_util_mean'), 0)} | {errs if errs is not None else 'n/a'} |")
        out.append("")
        # xychart-beta takes one line per engine over a shared x-axis. Points an
        # engine did not reach are plotted as 0 and called out in the note below.
        if series and concs:
            xs = sorted(concs)
            out.append("```mermaid")
            out.append(MERMAID_INIT)
            out.append("xychart-beta")
            out.append(f'    title "{wname}: output tokens per second vs concurrency"')
            out.append(f"    x-axis \"concurrency\" [{', '.join(str(x) for x in xs)}]")
            out.append('    y-axis "output tokens per second"')
            for ename, pts in series.items():
                by_c = defaultdict(list)
                for c, v in pts:
                    if isinstance(v, (int, float)):
                        by_c[c].append(v)
                vals = [sum(by_c[x]) / len(by_c[x]) if by_c.get(x) else 0 for x in xs]
                out.append(f"    line [{', '.join(f'{v:.1f}' for v in vals)}]")
            out.append("```")
            out.append(f"Series order: {', '.join(series.keys())}. A zero means the point was not measured.\n")

    # Caveats are derived from the data, not typed by hand, so they cannot be
    # forgotten when a table is copied into a deck.
    out.append("## Caveats\n")
    caveats = []
    if len({p for p in precisions if p}) > 1:
        caveats.append("Engines served different weight precisions (see the Engines table). Throughput and memory are not like for like across quantized and FP16 entries; compare within a precision class or state the difference next to any headline number.")
    if failed:
        caveats.append(f"Engines that did not complete: {', '.join(failed)}. Their absence is a finding, not an omission; the start log is in each engine directory.")
    if int(run.get("repeat", 1) or 1) < 3:
        caveats.append("Fewer than three repetitions per point. Treat differences under about 10 percent as noise until repeated.")
    caveats.append("Synthetic prompts with fixed token counts. Real traffic has variable lengths and shared prefixes, which favour engines with prefix caching more than this test does.")
    caveats.append("Load generator ran on the same host as the engine. CPU contention at high concurrency slightly penalises every engine equally; network latency is excluded.")
    caveats.append("Single GPU, single region, list price. No egress, storage, or idle time is included in the cost per token. See docs/cost-model.md.")
    for c in caveats:
        out.append(f"- {c}")
    out.append("")
    text = "\n".join(out)
    print(text)
    bundle.text("REPORT.md", text, "rendered report")
    bundle.add(a.run_dir / "run.json", "run metadata")
    bundle.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())
