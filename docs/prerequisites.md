# Prerequisites and independent reproduction guide

This guide is for an engineer outside the project who wants to check the
numbers in a published REPORT.md by running the same harness on an account
they control. Nothing in the results depends on access to the original
environment: the instance type, image digests, model, workload files and
load generator version are all recorded in the run directory, and every step
below uses public services and the code in this repository.

Expected effort: about one hour of setup spread over one to two days
(GPU plan access on a new account is granted by support, not instantly), then
15 minutes for a smoke run and about two hours unattended for the default
suite. Expected spend at list price: under 2 USD for the default suite.

## Contents

- [Scope of a valid reproduction](#scope-of-a-valid-reproduction)
- [1. Akamai Cloud account](#1-akamai-cloud-account)
- [2. GPU plan access](#2-gpu-plan-access)
- [3. Personal Access Token](#3-personal-access-token)
- [4. Hugging Face account and model license](#4-hugging-face-account-and-model-license)
- [5. NVIDIA NGC key (NIM engine only)](#5-nvidia-ngc-key-nim-engine-only)
- [6. Operator machine tooling](#6-operator-machine-tooling)
- [7. SSH key](#7-ssh-key)
- [8. Terraform variables](#8-terraform-variables)
- [9. Environment variables](#9-environment-variables)
- [10. Region and plan selection](#10-region-and-plan-selection)
- [11. Budget and time expectations](#11-budget-and-time-expectations)
- [12. Preflight](#12-preflight)
- [13. First-run order](#13-first-run-order)
- [14. Expected first-run failures](#14-expected-first-run-failures)
- [15. Comparing against published results](#15-comparing-against-published-results)
- [16. Reporting a discrepancy](#16-reporting-a-discrepancy)
- [Checklist](#checklist)

## Scope of a valid reproduction

A reproduction is comparable to a published run only when the controlled
variables match. Take these from the published run directory
(`run.json`, `<engine>/meta.json`, `<engine>/<workload>/workload.json`):

| Variable | Where it is recorded | Must match |
| --- | --- | --- |
| Plan type and region | run.json | Yes. Same GPU SKU; region does not change price or hardware but keep it for driver parity |
| Engine image digest | meta.json image_digest | Yes. Pin the tag env var (VLLM_TAG and so on) to the digest or the tag that resolves to it |
| Model id and precision | meta.json model, precision | Yes |
| Context length | meta.json max_model_len | Yes |
| Workload files | workload.json | Yes. Use the copies from the published run, not edited ones |
| guidellm version | guidellm-version.txt | Yes. Set guidellm_version in tfvars |
| Driver and kernel | nvidia-smi-q.txt, uname.txt | Record; differences are expected over time and should be stated, not hidden |
| Repetitions | run.json repeat | Same or higher |

Anything else (operator machine, network path, time of day) is outside the
measurement because the load generator runs on the GPU host over loopback.

## 1. Akamai Cloud account

Create the account at https://cloud.linode.com (Akamai Cloud, formerly
Linode). A payment card is required at signup. New accounts have at times
received a promotional credit (for example 100 USD for 60 days); check the
current offer, since it would cover several full suite runs.

Check: Cloud Manager loads and the Billing page shows an active payment method.

## 2. GPU plan access

GPU plans are not deployable on a new account until Akamai support enables
them. This is an account attribute, not something the repository can set.
Open a ticket in Cloud Manager (Support, Open New Ticket) with:

- Plan requested: g2-gpu-rtx4000a1-s (RTX 4000 Ada x1 Small)
- Region: us-ord (or the region chosen in section 10)
- Purpose: short-lived single instance to reproduce a published LLM
  serving engine benchmark, destroyed after each run
- Expected usage: a few hours per session

Turnaround is typically hours to one business day. The RTX PRO 6000
Blackwell plans are a separate limited-availability request; do not include
them in the first ticket.

Check: support confirms GPU plans are enabled. Until then, terraform apply
fails at instance creation with a plan availability error (see section 14).

## 3. Personal Access Token

Cloud Manager, profile menu, API Tokens, Create a Personal Access Token.

| Scope | Access | Used by |
| --- | --- | --- |
| Linodes | Read/Write | terraform (instance) |
| Firewalls | Read/Write | terraform (cloud firewall) |
| SSH Keys | Read/Write | terraform (operator key) |
| Account | Read Only | preflight (profile check) |
| Everything else | None | |

Set an expiry (30 days is enough for this work). Copy the token once; it is
not shown again. Store it in a password manager, never in a file in this
repository.

Check: `curl -H "Authorization: Bearer $LINODE_TOKEN" https://api.linode.com/v4/profile`
returns the account username.

## 4. Hugging Face account and model license

The default model, meta-llama/Llama-3.1-8B-Instruct, is gated.

1. Create an account at https://huggingface.co.
2. Open the model page and accept Meta's license. Approval is usually
   minutes, occasionally longer.
3. Settings, Access Tokens, create a token with Read access.

Fallback while approval is pending: Qwen/Qwen2.5-7B-Instruct is ungated.
Pass `--model Qwen/Qwen2.5-7B-Instruct` to run-suite.sh and set
LLAMACPP_HF_REPO and OLLAMA_MODEL to matching GGUF builds (see
[engines.md](engines.md)).

Check: `curl -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/models/meta-llama/Llama-3.1-8B-Instruct`
returns model metadata rather than a 401 or gated error.

## 5. NVIDIA NGC key (NIM engine only)

Optional. Needed only to run the nim engine profile.

1. Create an account at https://ngc.nvidia.com and generate an API key.
2. NIM containers require an NVIDIA AI Enterprise entitlement or a
   developer program membership; confirm the account can pull from
   nvcr.io/nim before planning a NIM run.
3. Export TF_VAR_ngc_api_key before provision so cloud-init writes it to
   /opt/bench/env on the host.

Check: `echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin`
succeeds on any machine with Docker.

## 6. Operator machine tooling

| Tool | Minimum | Install (macOS) | Purpose |
| --- | --- | --- | --- |
| terraform | 1.6 | `brew install terraform` | provision and destroy |
| jq | 1.6 | `brew install jq` | JSON in scripts |
| rsync | 3.x | `brew install rsync` | sync harness and fetch results |
| ssh | OpenSSH 8+ | included | remote execution |
| python3 | 3.10 | `brew install python` | analysis tools (standard library only) |
| curl | any | included | preflight API checks |
| make | any | Xcode command line tools | entry points |
| shellcheck | optional | `brew install shellcheck` | `make lint` |
| mmdc | optional | `npm i -g @mermaid-js/mermaid-cli` | render diagrams in `make lint` |

No Python packages are required on the operator machine. guidellm is
installed on the GPU host by cloud-init.

Check: `make lint` completes without errors (shellcheck and mmdc steps are
skipped when absent).

## 7. SSH key

Terraform uploads the public key in `ssh_public_key_path` (default
~/.ssh/id_ed25519.pub) and cloud-init disables password login. Generate one
if none exists:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

The private key must be loaded in the agent or be the default identity, since
bin/ scripts call plain `ssh root@<ip>`.

Check: `ssh-add -l` lists the key, or `ls ~/.ssh/id_ed25519*` shows both files.

## 8. Terraform variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit:

| Variable | Set to |
| --- | --- |
| allowed_cidrs | Operator public IPv4 with /32. Find it with `curl -4 -s https://ifconfig.me`. Validation rejects 0.0.0.0/0. |
| region | The region in the published run.json, or any region meeting section 10 |
| plan | The plan in the published run.json (default g2-gpu-rtx4000a1-s) |
| ssh_public_key_path | Path from section 7 |
| expose_engine_port | false; use `bin/ssh.sh --tunnel` instead |
| guidellm_version | The value in the published guidellm-version.txt |

terraform.tfvars is gitignored. Tokens never go in it.

Check: `terraform -chdir=terraform validate` reports success.

## 9. Environment variables

Set in the shell for each session. Nothing in this repository writes them to
disk on the operator machine.

```bash
export LINODE_TOKEN=...          # section 3, required
export TF_VAR_hf_token=...       # section 4, required for gated models
export TF_VAR_ngc_api_key=...    # section 5, NIM only
```

Home network IP changes (DHCP, VPN) invalidate allowed_cidrs; re-run
preflight and `terraform apply` to update the firewall rule.

Check: `env | grep -c -E 'LINODE_TOKEN|TF_VAR_hf_token'` returns 2.

## 10. Region and plan selection

Requirements for the region:

- "GPU Linodes" capability (GPU plans are offered in a subset of regions)
- "Metadata" capability (cloud-init user_data; without it the instance boots
  without drivers or Docker)

us-ord (Chicago) satisfies both and is the region used in Akamai's own CLI
examples. Pricing is uniform across regions. Latency from the operator to the
region does not affect measurements because the load generator runs on the
host.

Plan guidance for a Llama 3.1 8B FP16 comparison: the 20 GB RTX 4000 Ada
holds the model with a 4096 context and roughly 2 GB of KV cache. Larger
RTX 4000 Ada plans add CPU and RAM, not VRAM. The RTX PRO 6000 Blackwell
plan (96 GB) is the step up when the 49B model or high concurrency matters.

Check: preflight prints both capabilities for the chosen region and the plan
details with an hourly price.

## 11. Budget and time expectations

| Phase | Wall time | Billed at 0.52 USD/hr |
| --- | --- | --- |
| provision, driver install, reboot | 8 to 12 min | 0.10 |
| smoke (vLLM, tiny workload, first model pull) | 10 to 15 min | 0.12 |
| default suite (5 engines x 2 workloads, image and model pulls) | 90 to 150 min | 0.80 to 1.30 |
| full suite (5 engines x 4 workloads x 3 repeats) | 6 to 8 h | 3.10 to 4.20 |

Powered-off instances bill at the full plan rate. Only destroy stops
charges. Start `make guard HOURS=<n>` in a second terminal immediately after
provision, every time.

Outbound transfer: engine images (5 to 15 GB each) and model weights (16 GB)
are inbound and free. Results fetched back are megabytes.

## 12. Preflight

```bash
make preflight
```

Confirms: token valid, plan exists with live price (warns if
profiles/pricing.json disagrees), region has GPU Linodes and Metadata,
local tools present, and prints the operator public IP for allowed_cidrs.

Check: last line is `PREFLIGHT: OK`.

## 13. First-run order

1. `make provision` (wait for the driver line: GPU name, memory, driver version)
2. `make guard HOURS=2` in a second terminal
3. `make smoke` then `make log` until `SUITE-EXIT`
4. `make fetch && make analyze RUN=smoke`; open results/smoke/REPORT.md
5. Fix anything section 14 predicts, `make sync`, repeat the smoke
6. Export the engine tag pins from the published meta.json files, for example
   `export VLLM_TAG=v0.11.0 SGLANG_TAG=...`, then `make suite` (or the exact
   `bin/run-remote.sh` arguments listed in the published run.json: engines,
   workloads, repeat)
7. `make fetch && make analyze`, then section 15
8. `make destroy`

## 14. Expected first-run failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| terraform apply: plan not available or insufficient permissions on create | GPU access not yet enabled on the account (section 2) | Wait for the ticket; nothing to change |
| terraform apply: region does not support the requested plan | Region without GPU plans | Change region (section 10) |
| provision waits 25 min then fails | cloud-init still installing, or driver build failed | `bin/ssh.sh cat /var/log/bench-bootstrap.log`; check `nvidia-smi` |
| engine start: 401 or gated from Hugging Face | License not accepted or token missing | Section 4; confirm HF_TOKEN in /opt/bench/env on the host |
| run-bench: guidellm usage error | CLI flag names differ in the installed guidellm release | `bin/ssh.sh /opt/bench/venv/bin/guidellm run --help`; adjust host/run-bench.sh |
| engine start: image pull failed | Unpinned or wrong tag | Set SGLANG_TAG, TGI_TAG, OLLAMA_TAG, LLAMACPP_TAG to published tags |
| vLLM: CUDA out of memory at start | Context too large for 20 GB | Lower MAX_MODEL_LEN or GPU_MEM_UTIL, or use FP8 |
| NIM: no compatible profile | 20 GB GPU has no optimized profile for the model | Skip NIM on this plan |
| ssh: connection refused after IP change | allowed_cidrs stale | Update tfvars, `terraform apply` |

## 15. Comparing against published results

Place the two run directories side by side and compare `cost.csv` rows with
the same (engine, workload, concurrency). Read the Engines table in both
REPORT.md files first: if a digest or precision differs, the rows are not
comparable and the difference should be stated before any number.

Expected agreement for a faithful reproduction on the same plan:

| Metric | Typical run-to-run spread | Treat as a discrepancy above |
| --- | --- | --- |
| Output tokens/s at fixed concurrency | 3 to 8 percent | 15 percent |
| TTFT p50 | 5 to 10 percent | 25 percent |
| TTFT p99 | 15 to 30 percent (queueing noise) | 50 percent |
| TPOT p50 | 3 to 8 percent | 15 percent |
| USD per 1M output tokens | Follows tokens/s exactly; also check the price used | 15 percent |
| GPU utilization mean | 5 points | 15 points |

Points at or beyond saturation (errors greater than zero, or concurrency past
the KV cache limit described in [engines.md](engines.md)) vary more and
should be compared on error count and direction, not exact throughput.

Three repetitions on both sides are required before calling a difference real.

## 16. Reporting a discrepancy

Open an issue or send the following; it is enough to diagnose without access
to either environment:

1. The reproduction's `run.json`, every `meta.json`, `guidellm-version.txt`,
   `nvidia-smi-q.txt`, and `cost.csv`
2. The published run id being compared against
3. The specific rows that disagree and by how much
4. `results/<run-id>/<engine>/engine-start.log` for any engine that failed
5. The output of `bin/preflight.sh` (prices and capabilities at run time)

A `--debug` bundle from `analyze/cost.py` or `analyze/report.py` contains
items 1 and 5 in one archive.

## Checklist

- [ ] Akamai Cloud account with payment method
- [ ] GPU plan access confirmed by support
- [ ] Personal Access Token with Linodes, Firewalls, SSH Keys read/write
- [ ] Hugging Face token and Llama 3.1 license accepted (or ungated fallback chosen)
- [ ] NGC key, only if running NIM
- [ ] terraform, jq, rsync, ssh, python3, make installed
- [ ] SSH key present and loaded
- [ ] terraform/terraform.tfvars created with allowed_cidrs set to the operator IP
- [ ] LINODE_TOKEN and TF_VAR_hf_token exported
- [ ] `make preflight` prints PREFLIGHT: OK
- [ ] Budget guard planned for every session
- [ ] Published run directory at hand for plan, digests, workloads and guidellm version
