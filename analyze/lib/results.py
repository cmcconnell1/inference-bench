"""Load a benchmark run directory into plain dicts.

Layout produced by host/run-suite.sh:

    <run>/run.json
    <run>/<engine>/meta.json
    <run>/<engine>/<workload>/workload.json
    <run>/<engine>/<workload>/c<N>[/r<K>]/guidellm.json, run.json, gpu.csv

guidellm's JSON schema has changed across releases. Metric extraction here is
defensive: it walks the document for known metric names and accepts either
{"successful": {"mean":..., "percentiles": {...}}} or flat {"mean":..., "p99":...}.
Standard library only.
"""
from __future__ import annotations

import csv
import json
import statistics
from pathlib import Path
from typing import Any, Iterator

# Canonical metric name -> aliases seen across guidellm releases. The first
# alias found while walking the JSON wins. Add an alias here, not in callers,
# when a new guidellm version renames a field.
METRIC_KEYS = {
    "ttft_ms": ("time_to_first_token_ms", "ttft_ms", "time_to_first_token"),
    "itl_ms": ("inter_token_latency_ms", "itl_ms", "inter_token_latency"),
    "tpot_ms": ("time_per_output_token_ms", "tpot_ms", "time_per_output_token"),
    "request_latency_s": ("request_latency", "request_latency_s", "e2e_latency"),
    "output_tps": ("output_tokens_per_second", "output_token_throughput", "output_tps"),
    "total_tps": ("tokens_per_second", "total_token_throughput", "total_tps"),
    "rps": ("requests_per_second", "request_throughput", "rps"),
    "concurrency": ("request_concurrency", "concurrency"),
    "output_tokens": ("output_token_count", "output_tokens"),
    "prompt_tokens": ("prompt_token_count", "prompt_tokens"),
}


def _walk(obj: Any) -> Iterator[tuple[str, Any]]:
    """Depth-first (key, value) pairs over nested dicts and lists."""
    # Recursion is fine here: guidellm documents are a few levels deep.
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield k, v
            yield from _walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk(v)


def _stat(node: Any) -> dict[str, float | None]:
    """Normalise a guidellm distribution node to mean/median/p95/p99."""
    # A bare number (older schema) carries only a mean.
    if isinstance(node, (int, float)):
        return {"mean": float(node), "median": None, "p95": None, "p99": None}
    if not isinstance(node, dict):
        return {"mean": None, "median": None, "p95": None, "p99": None}
    # Newer schema splits each metric by request outcome; only successful
    # requests count toward latency and throughput.
    if "successful" in node and isinstance(node["successful"], dict):
        node = node["successful"]
    pct = node.get("percentiles", {}) if isinstance(node.get("percentiles"), dict) else {}

    def pick(*names):
        # Look for a value at the top level first, then inside percentiles.
        for n in names:
            if n in node and isinstance(node[n], (int, float)):
                return float(node[n])
            if n in pct and isinstance(pct[n], (int, float)):
                return float(pct[n])
        return None

    return {
        "mean": pick("mean"),
        "median": pick("median", "p50"),
        "p95": pick("p95"),
        "p99": pick("p99"),
    }


def extract_metrics(doc: Any) -> dict[str, dict[str, float | None]]:
    """Return {metric: {mean, median, p95, p99}} from any guidellm JSON."""
    found: dict[str, Any] = {}
    # Each concurrency point is one guidellm invocation, so a document should
    # hold exactly one benchmark. Prefer the first "benchmarks[0].metrics" block if present.
    benches = doc.get("benchmarks") if isinstance(doc, dict) else None
    scope = benches[0] if isinstance(benches, list) and benches else doc
    for key, aliases in METRIC_KEYS.items():
        for k, v in _walk(scope):
            if k in aliases:
                found[key] = _stat(v)
                break
    # Success / error counts live under request_totals (0.3) or totals
    # (later). Errors at a point usually mean the engine was saturated.
    counts = {"successful": None, "errored": None, "incomplete": None}
    for k, v in _walk(scope):
        if k in ("request_totals", "totals") and isinstance(v, dict):
            for c in counts:
                if isinstance(v.get(c), (int, float)):
                    counts[c] = int(v[c])
            break
    found["_counts"] = counts  # type: ignore[assignment]
    return found


def gpu_summary(csv_path: Path) -> dict[str, float | None]:
    """Mean and max GPU utilization, max memory used, mean power from nvidia-smi CSV."""
    if not csv_path.exists():
        return {}
    # nvidia-smi CSV headers include the unit, for example
    # "utilization.gpu [%]"; values carry the unit as a suffix too.
    util, mem, power = [], [], []
    with csv_path.open(newline="") as fh:
        for row in csv.DictReader(fh, skipinitialspace=True):
            try:
                util.append(float(str(row.get("utilization.gpu [%]", "")).rstrip(" %")))
                mem.append(float(str(row.get("memory.used [MiB]", "")).rstrip(" MiB")))
                power.append(float(str(row.get("power.draw [W]", "")).rstrip(" W")))
            except ValueError:
                # Header repeats or blank lines from sampler start/stop.
                continue
    if not util:
        return {}
    return {
        "gpu_util_mean": round(statistics.fmean(util), 1),
        "gpu_util_max": max(util),
        "gpu_mem_used_max_mib": max(mem) if mem else None,
        "power_mean_w": round(statistics.fmean(power), 1) if power else None,
        "samples": len(util),
    }


def load_run(run_dir: Path) -> dict[str, Any]:
    """Read one run directory into {run, engines: {name: {meta, status, workloads}}}.

    Missing files degrade to empty dicts so a partially failed suite still
    produces a report; the report marks what is absent.
    """
    run = json.loads((run_dir / "run.json").read_text()) if (run_dir / "run.json").exists() else {}
    engines: dict[str, Any] = {}
    for edir in sorted(p for p in run_dir.iterdir() if p.is_dir()):
        meta_p = edir / "meta.json"
        status = json.loads((edir / "status.json").read_text()) if (edir / "status.json").exists() else {}
        meta = json.loads(meta_p.read_text()) if meta_p.exists() else {"engine": edir.name}
        workloads: dict[str, Any] = {}
        # Each workload directory holds c<N> points; with --repeat the point
        # directory holds r<K> repetition subdirectories instead of files.
        for wdir in sorted(p for p in edir.iterdir() if p.is_dir()):
            wl = json.loads((wdir / "workload.json").read_text()) if (wdir / "workload.json").exists() else {"name": wdir.name}
            points = []
            for cdir in sorted((p for p in wdir.iterdir() if p.is_dir() and p.name.startswith("c")),
                                key=lambda p: int(p.name[1:]) if p.name[1:].isdigit() else 0):
                reps = [cdir] if (cdir / "guidellm.json").exists() else sorted(p for p in cdir.iterdir() if p.is_dir())
                for rdir in reps:
                    gj = rdir / "guidellm.json"
                    if not gj.exists():
                        continue
                    try:
                        doc = json.loads(gj.read_text())
                    except json.JSONDecodeError:
                        continue
                    rj = json.loads((rdir / "run.json").read_text()) if (rdir / "run.json").exists() else {}
                    points.append({
                        "concurrency": rj.get("concurrency") or int(cdir.name[1:]),
                        "rep": rdir.name if rdir != cdir else "r1",
                        "path": str(rdir),
                        "metrics": extract_metrics(doc),
                        "gpu": gpu_summary(rdir / "gpu.csv"),
                        "run": rj,
                    })
            workloads[wdir.name] = {"workload": wl, "points": points}
        engines[edir.name] = {"meta": meta, "status": status, "workloads": workloads}
    return {"run": run, "engines": engines, "path": str(run_dir)}
