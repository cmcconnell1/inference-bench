# Serving engines

Six profiles under profiles/engines/. Every one exposes an OpenAI-compatible
chat completions endpoint that guidellm can drive without engine-specific
code. Pin an image tag via the listed environment variable before a
reportable run; the RepoDigest is recorded in meta.json either way.

| Profile | Image | Pin var | Precision served | Role in the comparison |
| --- | --- | --- | --- | --- |
| vllm | vllm/vllm-openai | VLLM_TAG (default v0.11.0) | FP16/BF16 (dtype auto) | Reference production engine; continuous batching, paged KV, prefix caching |
| sglang | lmsysorg/sglang | SGLANG_TAG | FP16/BF16 | Production engine with RadixAttention prefix cache; often leads on throughput |
| tgi | ghcr.io/huggingface/text-generation-inference | TGI_TAG | FP16/BF16 | Hugging Face's server; common in enterprise deployments |
| ollama | ollama/ollama | OLLAMA_TAG | Q4_K_M GGUF by default | What developers run locally; shows the gap between a laptop tool and a server |
| llamacpp | ghcr.io/ggml-org/llama.cpp:server-cuda | LLAMACPP_TAG | Q8_0 GGUF by default | The engine under Ollama, with explicit control of slots and quantization |
| nim | nvcr.io/nim/meta/llama-3.1-8b-instruct | NIM_TAG | TensorRT-LLM profile chosen by NIM | What Akamai's own Blackwell benchmark used; needs NGC_API_KEY; may not fit 20 GB |

## Model choice

Default: meta-llama/Llama-3.1-8B-Instruct. It fits a 20 GB GPU in FP16 with a
4096 context, is the reference model most vendor benchmarks quote, and has GGUF quantizations
for the llama.cpp and Ollama profiles. Requires accepting Meta's license on
Hugging Face and an HF_TOKEN.

Ungated fallback: Qwen/Qwen2.5-7B-Instruct (set --model on run-suite.sh and
LLAMACPP_HF_REPO plus OLLAMA_MODEL for the GGUF engines).

Mistral: mistralai/Mistral-7B-Instruct-v0.3, also gated. Same flow.

## Memory on a 20 GB GPU

| Item | Approx GB |
| --- | --- |
| Llama 3.1 8B weights FP16 | 16.1 |
| CUDA context, activations, engine overhead | 1 to 1.5 |
| KV cache remaining at 0.90 utilization | 1 to 2 |
| KV per token (Llama 3.1 8B, GQA, FP16) | 0.000128 (128 KB) |

Roughly 8k to 16k cached tokens total: about 40 concurrent 400-token
requests before preemption. This is why the 200x200 workload saturates at
C = 100. Options if headroom matters more than fidelity: FP8 weights on
Ada (VLLM_EXTRA_ARGS="--quantization fp8"), or the RTX PRO 6000 plan.

## Engine-specific notes

**vLLM**: --gpu-memory-utilization 0.90 leaves margin for the sampler and
CUDA graphs. Prefix caching is on by default in recent versions; the
synthetic prompts share little, so it rarely helps here.

**SGLang**: --mem-fraction-static 0.85. Health path /health. Started with an
explicit python3 entrypoint because the image default is a shell.

**TGI**: listens on 80 inside the container. Requests must use the full HF
model id as the model name. --max-batch-prefill-tokens bounds prefill
batches; raise it for the rag-long-prompt workload if it errors.

**Ollama**: OLLAMA_NUM_PARALLEL sets the max concurrent sequences; the
default (1 to 4) would serialize the load test. Set to at least the highest
concurrency in the workload. Pulls the model after the container is healthy.
Quantized by default; state it in every comparison.

**llama.cpp**: -np is the number of parallel slots and -c is total context
shared across slots, so -c is MAX_MODEL_LEN x LLAMACPP_PARALLEL. -ngl 99
offloads all layers.

**NIM**: authenticates to nvcr.io with the NGC key, then selects a
TensorRT-LLM engine profile for the detected GPU. First start downloads the
optimized engine (several GB). Not in the default engine list; add it with
--engines when NGC_API_KEY is present.

## Adding an engine

Copy an existing profile, set the ten variables, and confirm three things
by hand: the health path returns 200, /v1/models lists the served name, and
a streaming chat completion returns token deltas. Then add it to the
default list in host/run-suite.sh if it should run by default.
