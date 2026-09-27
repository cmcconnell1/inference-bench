# OSS landscape: what exists, what this repository adds

Do not build a load generator. Several exist, are maintained, and are what
the industry quotes. This repository is glue around them: infrastructure,
engine lifecycle, orchestration, cost, and reporting.

## Load generators and harnesses

| Project | Maintainer | Fit | Used here |
| --- | --- | --- | --- |
| guidellm | vLLM project (originated at Neural Magic, Red Hat) | Engine-agnostic OpenAI-compatible client; concurrent, constant, Poisson, sweep profiles; synthetic or dataset prompts; JSON/CSV/HTML output; TTFT, ITL, TPOT, throughput | Yes, primary |
| vllm bench serve | vLLM | Ships inside the vLLM image; same metric set; dataset support | Optional cross-check from inside the vLLM container |
| inference-perf | Kubernetes SIG Serving | YAML-configured, Kubernetes job friendly, goodput and SLO support, dataset replay, multimodal | Recommended when the target moves to LKE; same metrics |
| GenAI-Perf / AIPerf | NVIDIA | Triton and NIM oriented; the tool behind NVIDIA and partner benchmark blogs | Use when reproducing an NVIDIA or Akamai NIM number exactly |
| llmperf | Anyscale | Early standard; less active | No |
| InferenceX (formerly InferenceMAX) | SemiAnalysis | Continuous nightly benchmarks of vLLM, SGLang, TensorRT-LLM across datacenter GPUs; public dashboard | Reference for methodology and for comparing against published curves; targets multi-GPU datacenter SKUs, not a single 20 GB card |
| MLPerf Inference | MLCommons | Formal submission rules, audited | Too heavy for this scope; its rules on warmup and accuracy targets are worth reading |

## Provisioning

| Project | Fit | Used here |
| --- | --- | --- |
| terraform-provider-linode | Official provider; instance, firewall, SSH key, metadata user_data | Yes |
| akamai-developers/akamai-gpu-ollama | Akamai's own Terraform plus cloud-init for a hardened Ollama GPU Linode | Pattern reference for the firewall and hardening; this repo uses containers instead of bare Ollama |
| NVIDIA GPU Operator, DCGM exporter, kube-prometheus-stack | Kubernetes GPU observability | The LKE version of gpu-sampler.sh when the harness moves to Kubernetes |
| KAITO, KServe, llm-d, NVIDIA Dynamo | Kubernetes model serving operators | Out of scope for a single-node engine comparison; relevant for a platform comparison |

Links for every project above are in [references.md](references.md).

## What is original here

- Engine profiles as a ten-variable contract so six engines run through one
  code path.
- Terraform plus cloud-init for a disposable GPU node with a destroy-based
  budget guard.
- Suite orchestration with per-point GPU sampling and per-engine digest and
  precision capture.
- Cost per million tokens from plan pricing, with an explicit list of what
  the formula omits.
- A report that generates its own caveats from the data (mixed precision,
  failed engines, low repetition).

That glue is roughly 1,500 lines. The load generator it wraps is tens of
thousands. The ratio is the point.
