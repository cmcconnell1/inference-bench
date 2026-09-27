# Methodology

The point of the harness is a defensible comparison. Every choice below exists
so a reader can reproduce a number or see why two numbers are not comparable.

## Controlled variables

| Variable | Control | Where |
| --- | --- | --- |
| Hardware | One plan type, one region, one instance for the whole run | terraform/variables.tf, run.json |
| Driver and kernel | Recorded per run (nvidia-smi -q, uname) | run directory |
| Engine build | Image tag pinned by env var; RepoDigest recorded whether or not the tag is pinned | meta.json |
| Model | Same Hugging Face id for vLLM, SGLang, TGI; GGUF and Ollama variants named explicitly with their quantization | meta.json precision field |
| Context length | MAX_MODEL_LEN passed to every engine that accepts it | profiles/engines |
| Request shape | Fixed prompt and output token counts, zero standard deviation, synthetic text | profiles/workloads |
| Load pattern | Closed loop: N always-open streams (concurrent mode). Not open-loop request rate | host/run-bench.sh |
| Duration | Fixed seconds per point, not fixed request count, so slow engines do not run longer | workload max_seconds |
| Warmup | 30 s of requests before the first measured point per workload | host/run-suite.sh |
| Client placement | guidellm on the same host as the engine, loopback | host/run-bench.sh |
| Tokenizer for prompt sizing | The base model tokenizer for every engine | --processor |
| Repetitions | --repeat 3 for any reportable number | host/run-suite.sh |

## Metrics

| Metric | Definition | Why it matters |
| --- | --- | --- |
| TTFT | Time from request send to first streamed token | Perceived responsiveness; prefill cost and queueing |
| ITL | Time between consecutive streamed tokens | Smoothness of streaming output |
| TPOT | (request latency minus TTFT) / output tokens | Decode speed per request |
| Output tokens/s | Aggregate across all streams | Capacity of the GPU under this engine |
| Requests/s | Completed requests per second | Capacity in request terms |
| Errors | Requests that failed or were cut off | Saturation and stability |
| GPU util, memory, power | nvidia-smi sampled at 1 Hz | Whether the engine actually uses the hardware; power for cost per token at the wall |
| USD per 1M output tokens | hourly price / (output tokens/s x 3600) x 1e6 | The number Sales asks for |

Goodput (requests meeting an SLO such as TTFT under 500 ms) is derived in the
report stage from the percentile columns; it is not a separate measurement.

## Why closed-loop concurrency

Cloud comparisons usually quote throughput at a stated concurrency (Akamai's
Blackwell blog: C = 1, 100, 200; details in [references.md](references.md)). A closed loop with N streams reproduces
that framing directly and is stable at saturation. Open-loop rates (requests
per second, Poisson) are better for capacity planning against a traffic model
and can be added as a workload field later; guidellm supports both.

## Saturation is a result

An 8B FP16 model on a 20 GB GPU has roughly 2 to 3 GB of KV cache. At
concurrency 100 or 200 with 200 output tokens, most engines will queue,
preempt, or error. The 200x200 workload keeps those points so the
saturation point is visible. Report it; do not trim it.

## Honesty checklist

Before a number leaves this repository:

1. The engine table in REPORT.md lists precision for every row. Do not
   compare a Q4 GGUF throughput against FP16 without saying so in the same
   sentence.
2. The digest column is filled for every engine.
3. Three repetitions, or the caveat stays in.
4. Any engine that failed to start is listed with its log, not dropped.
5. The cost figure names the price source and date.
6. State what was not measured: multi-GPU, network latency to a client,
   real prompt distributions, egress, idle time.

## Extending to a second provider

The methodology transfers unchanged. Swap terraform/ for the other
provider's GPU instance, keep the same image, model, workloads and guidellm
version, run the same suite. The report then compares provider x engine at
fixed concurrency. Differences in driver version and GPU SKU must be stated
in the Engines table. This is the natural next step once the single-provider
suite is stable.
