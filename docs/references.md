# References

Sources behind the defaults in this repository, checked 2026-09-27. Re-verify
prices and plan IDs with bin/preflight.sh before quoting them.

## Akamai's published inference benchmark (the reference to reproduce)

Akamai benchmarked the NVIDIA RTX PRO 6000 Blackwell Server Edition on
Akamai Cloud (LAX) against an H100 in NVIDIA LaunchPad.

| Item | Value |
| --- | --- |
| Serving stack | NVIDIA NIM with TensorRT-LLM profiles: `tensorrt_llm-rtx6000_blackwell_sv-fp8-tp1-pp1-throughput` and the `nvfp4` variant |
| Model | Llama-3.3-Nemotron-Super-49B-v1.5 |
| Request shape | 200 input tokens, 200 output tokens |
| Concurrency | 1, 100, 200 |
| Metrics | TTFT (ms), tokens per second |
| Headline results | 3,030 tokens/s at C=100 (FP4); FP4 1.32x faster than FP8 on the same GPU; RTX PRO 6000 FP4 1.63x the H100 FP8 at C=100 |

The akamai-blog-200x200 workload profile copies the request shape and
concurrency framing. The nim engine profile is the same serving stack. A
faithful reproduction needs the g3-gpu-rtxpro6000-blackwell-1 plan and the
49B model; on the 20 GB default plan the same profile runs an 8B model and
saturates far earlier, which is itself a useful data point about GPU sizing.

Source: [Benchmarking NVIDIA RTX Pro 6000 Blackwell on Akamai Cloud](https://www.akamai.com/blog/cloud/benchmarking-nvidia-rtx-pro-6000-blackwell-akamai-cloud)

## Akamai Cloud plans, pricing, and provisioning

| Topic | Source |
| --- | --- |
| RTX 4000 Ada plans, 0.52 USD/hr entry price, six launch regions | [Just Right: New GPUs Now Available](https://www.linode.com/blog/compute/new-gpus-nvidia-rtx-4000-ada-generation/) |
| GPU plan overview and region availability | [GPU Linodes](https://techdocs.akamai.com/cloud-computing/docs/gpu-compute-instances) |
| RTX PRO 6000 Blackwell plan ID `g3-gpu-rtxpro6000-blackwell-1`, limited availability | [Blackwell GPU onboarding](https://techdocs.akamai.com/cloud-computing/docs/nvidia-rtx-pro-6000-blackwell-gpu-onboarding) |
| Blackwell known limitations (slow delete, no live migration) | [Known limitations](https://techdocs.akamai.com/cloud-computing/docs/known-limitations-you-may-encounter-with-nvidia-rtx-pro-6000-blackwell-server-edition-gpu-linodes) |
| CLI examples for GPU Linodes (`--type g2-gpu-rtx4000a1-s --image linode/ubuntu24.04`) | [Linode instances commands](https://techdocs.akamai.com/cloud-computing/docs/linode-instances-commands) |
| GPUs on LKE (the Kubernetes variant of this harness) | [Using GPUs on LKE](https://techdocs.akamai.com/cloud-computing/docs/gpus-on-lke) |
| Akamai's own Terraform plus cloud-init for a hardened GPU Linode | [akamai-developers/akamai-gpu-ollama](https://github.com/akamai-developers/akamai-gpu-ollama/) |
| Terraform provider | [linode/linode on the Terraform Registry](https://registry.terraform.io/providers/linode/linode/latest/docs) |
| Cross-provider RTX 4000 Ada price comparison | [getdeploying.com](https://getdeploying.com/gpus/nvidia-rtx-4000-ada), [gpus.io](https://gpus.io/en/gpus/4000ada) |

## Load generators and benchmark harnesses

| Project | Link | Role here |
| --- | --- | --- |
| guidellm | [vllm-project/guidellm](https://github.com/vllm-project/guidellm), [PyPI](https://pypi.org/project/guidellm/) | Primary load generator, pinned 0.7.4 |
| inference-perf | [kubernetes-sigs/inference-perf](https://github.com/kubernetes-sigs/inference-perf) | Kubernetes-native alternative for the LKE variant |
| InferenceX (formerly InferenceMAX) | [SemiAnalysisAI/InferenceX](https://github.com/SemiAnalysisAI/InferenceX), [dashboard](https://inferencex.com) | Industry reference curves for vLLM, SGLang, TensorRT-LLM on datacenter GPUs |
| NVIDIA GenAI-Perf | [triton-inference-server/perf_analyzer](https://github.com/triton-inference-server/perf_analyzer) | Tool of record for NIM and TensorRT-LLM numbers |
| MLPerf Inference | [mlcommons/inference](https://github.com/mlcommons/inference) | Rules on warmup and accuracy worth borrowing |

## Serving engines

| Engine | Link |
| --- | --- |
| vLLM | [vllm-project/vllm](https://github.com/vllm-project/vllm), image `vllm/vllm-openai` |
| SGLang | [sgl-project/sglang](https://github.com/sgl-project/sglang), image `lmsysorg/sglang` |
| TGI | [huggingface/text-generation-inference](https://github.com/huggingface/text-generation-inference) |
| Ollama | [ollama/ollama](https://github.com/ollama/ollama) |
| llama.cpp server | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp), image `ghcr.io/ggml-org/llama.cpp:server-cuda` |
| NVIDIA NIM | [NIM for LLMs docs](https://docs.nvidia.com/nim/large-language-models/latest/), image `nvcr.io/nim/meta/llama-3.1-8b-instruct` |

## NVIDIA host stack

| Component | Link |
| --- | --- |
| CUDA apt repository and `nvidia-open` meta-package (Ubuntu 24.04) | [CUDA Installation Guide for Linux](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/) |
| NVIDIA Container Toolkit | [Installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) |
| DCGM exporter (for the LKE variant) | [NVIDIA/dcgm-exporter](https://github.com/NVIDIA/dcgm-exporter) |

## Akamai inference strategy (context for the comparison)

| Item | Source |
| --- | --- |
| Akamai Cloud Inference launch, March 2025: claims 3x throughput, 60 percent lower latency, 86 percent lower cost vs hyperscalers | [Press release](https://www.finansavisen.no/borsmeldinger/2025/03/27/4bbe141c-7fad-428f-9e82-6ac80c120b85/akamai-sharpens-its-ai-edge-with-launch-of-akamai-cloud-inference) |
| Akamai Inference Cloud with NVIDIA, October 2025 | [Announcement](https://www.barchart.com/story/news/35736341/akamai-inference-cloud-transforms-ai-from-core-to-edge-with-nvidia) |
| NVIDIA AI Grid across 4,400 plus edge locations, March 2026 | [Announcement](https://www.barchart.com/story/news/779663/akamai-launches-ai-grid-intelligent-orchestration-for-distributed-inference-across-4-400-edge-locations) |
| Cloud infrastructure growth guidance 45 to 50 percent | [Conference coverage](https://www.marketbeat.com/instant-alerts/akamai-technologies-ceo-details-ai-inference-cloud-push-45-50-cloud-growth-at-conference-2026-03-04/) |

Claims like the 86 percent cost figure are what this harness is built to
verify: run the same engine and workload on a hyperscaler GPU at its list
price and compare cost per million tokens, then publish both numbers with
their inputs.
