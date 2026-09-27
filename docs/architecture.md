# Architecture

## Components

Operator machine holds Terraform state, orchestration scripts and analysis.
The GPU instance holds only what a run needs and is destroyed afterwards.
The load generator runs on the instance, over loopback, so network latency
between operator and region never enters the measurements.

```mermaid
%%{init: {"theme": "base", "themeVariables": {"fontSize": "13px", "background": "#002b36", "primaryColor": "#073642", "primaryTextColor": "#eee8d5", "primaryBorderColor": "#586e75", "lineColor": "#586e75", "secondaryColor": "#073642", "tertiaryColor": "#002b36", "noteBkgColor": "#073642", "noteTextColor": "#eee8d5", "noteBorderColor": "#586e75"}}}%%
flowchart LR
    subgraph OP["Operator machine"]
        TF["terraform/<br/>instance, firewall, cloud-init"]
        BIN["bin/<br/>preflight, provision, sync,<br/>run-remote, fetch, destroy"]
        GUARD["budget-guard.sh<br/>destroy after N hours"]
        AN["analyze/<br/>cost.py, report.py"]
        RES["results/&lt;run-id&gt;/<br/>REPORT.md, cost.csv"]
    end

    subgraph AK["Akamai Cloud region"]
        FW["Cloud Firewall<br/>SSH from operator CIDR only"]
        subgraph GPU["GPU instance (Ubuntu 24.04)"]
            CI["cloud-init<br/>nvidia-open, Docker,<br/>container toolkit, guidellm"]
            SUITE["host/run-suite.sh"]
            ENG["bench-engine container<br/>vLLM | SGLang | TGI |<br/>Ollama | llama.cpp | NIM<br/>127.0.0.1:8000"]
            GL["guidellm<br/>concurrent streams"]
            SMI["gpu-sampler.sh<br/>nvidia-smi 1 Hz"]
            HF["/var/lib/bench/hf-cache<br/>model weights"]
            OUT["/var/lib/bench/results"]
        end
    end

    API["Linode API v4"]
    HUB["Hugging Face Hub<br/>NGC (NIM only)"]

    BIN --> TF
    TF -->|"LINODE_TOKEN"| API
    API --> FW
    API --> GPU
    BIN -->|"rsync over SSH"| SUITE
    SUITE -->|"start / stop"| ENG
    SUITE --> GL
    SUITE --> SMI
    GL -->|"/v1/chat/completions"| ENG
    ENG --> HF
    HF -.->|"first pull"| HUB
    GL --> OUT
    SMI --> OUT
    OUT -->|"fetch-results.sh"| RES
    RES --> AN
    GUARD -->|"terraform destroy"| API

    classDef primary  fill:#073642,stroke:#268bd2,stroke-width:2px,color:#eee8d5
    classDef success  fill:#073642,stroke:#859900,stroke-width:2px,color:#eee8d5
    classDef warning  fill:#073642,stroke:#b58900,stroke-width:2px,color:#eee8d5
    classDef error    fill:#073642,stroke:#dc322f,stroke-width:2px,color:#eee8d5
    classDef external fill:#073642,stroke:#2aa198,stroke-width:2px,color:#eee8d5
    classDef security fill:#073642,stroke:#6c71c4,stroke-width:2px,color:#eee8d5
    classDef accent   fill:#073642,stroke:#cb4b16,stroke-width:2px,color:#eee8d5
    classDef neutral  fill:#073642,stroke:#586e75,stroke-width:2px,color:#eee8d5

    class TF,BIN,SUITE primary
    class ENG,GL success
    class SMI,HF,OUT,RES,AN warning
    class GUARD error
    class API,HUB external
    class FW,CI security
    class OP,AK,GPU neutral
```

## Suite run sequence

```mermaid
%%{init: {"theme": "base", "themeVariables": {"fontSize": "13px", "background": "#002b36", "primaryColor": "#073642", "primaryTextColor": "#eee8d5", "primaryBorderColor": "#586e75", "lineColor": "#586e75", "secondaryColor": "#073642", "tertiaryColor": "#002b36", "noteBkgColor": "#073642", "noteTextColor": "#eee8d5", "noteBorderColor": "#586e75", "actorBkg": "#073642", "actorTextColor": "#eee8d5", "actorBorder": "#268bd2", "signalColor": "#93a1a1", "signalTextColor": "#eee8d5", "sequenceNumberColor": "#002b36", "activationBkgColor": "#073642", "activationBorderColor": "#b58900", "loopTextColor": "#eee8d5", "labelBoxBkgColor": "#073642", "labelBoxBorderColor": "#586e75", "labelTextColor": "#eee8d5"}}}%%
sequenceDiagram
    autonumber
    participant Op as Operator
    participant TF as Terraform / Linode API
    participant Host as GPU host
    participant Eng as bench-engine
    participant GL as guidellm
    participant SMI as gpu-sampler

    Op->>TF: preflight.sh (token, plan, region, price)
    Op->>TF: provision.sh (apply)
    TF-->>Host: create instance + firewall, cloud-init user_data
    Host->>Host: nvidia-open, Docker, toolkit, guidellm, reboot
    Op->>Host: wait for bootstrap-complete and nvidia-smi
    Op->>Host: sync.sh (rsync lib, host, profiles, analyze)
    Op->>Host: run-remote.sh (tmux run-suite.sh)

    loop for each engine profile
        Host->>Eng: docker run --gpus all (profile image and args)
        Host->>Eng: poll health path until 200
        Eng-->>Host: /v1/models lists served model
        Host->>Host: engine.sh meta -> meta.json (digest, precision, driver)
        loop for each workload
            Host->>Eng: warmup requests (30 s)
            loop for each concurrency level x repeat
                Host->>SMI: start gpu.csv
                Host->>GL: run-bench.sh (concurrent streams, fixed tokens, fixed seconds)
                GL->>Eng: streaming /v1/chat/completions
                Eng-->>GL: tokens (TTFT, ITL measured client side)
                GL-->>Host: guidellm.json
                Host->>SMI: stop
            end
        end
        Host->>Eng: docker rm -f
    end

    Op->>Host: fetch-results.sh
    Op->>Op: cost.py (USD per 1M tokens) then report.py (REPORT.md)
    Op->>TF: destroy.sh or budget-guard.sh (billing stops)
```

## Trust boundaries

| Boundary | Control |
| --- | --- |
| Operator to Linode API | LINODE_TOKEN from the environment; never in files |
| Internet to instance | Cloud Firewall: inbound DROP except TCP 22 from allowed_cidrs; optional TCP 8000 |
| Host to engine | Engine container port published on 127.0.0.1 only; ufw allows SSH only |
| Secrets on host | /opt/bench/env mode 0600, root only; destroyed with the instance |
| Model weights | Hugging Face cache on the instance disk; nothing copied back |
| Results | Fetched to results/ (gitignored); contain no secrets, only metrics and logs |

## Design choices

- **Containers per engine, not a Kubernetes cluster.** One node, one
  engine at a time, is the tightest control of variables and the cheapest
  way to compare engines. The Kubernetes variant (LKE plus inference-perf)
  is the next layer, not the first.
- **guidellm instead of a custom client.** See docs/oss-landscape.md.
- **Closed-loop concurrency.** Matches how vendors quote numbers
  (Akamai's Blackwell blog: C = 1, 100, 200) and is stable at saturation.
- **Collect on the host, analyze offline.** Same split as the rest of the
  platform toolkit: raw evidence is fetched once and can be re-analyzed
  without cluster or cloud access.
- **Destroy-based budget guard.** Powered-off instances bill; only destroy
  is a real stop.
