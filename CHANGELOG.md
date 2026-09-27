# Changelog

All notable changes to this project.

## [Unreleased]

### Added
- MIT license.
- Terraform for a single Akamai Cloud GPU instance (RTX 4000 Ada default) with Cloud Firewall, SSH key, and cloud-init that installs NVIDIA open kernel modules, Docker, the NVIDIA Container Toolkit, and guidellm.
- Serving engine profiles: vLLM, SGLang, TGI, Ollama, llama.cpp server, NVIDIA NIM. Each exposes an OpenAI-compatible endpoint on port 8000.
- Host-side suite runner: starts each engine, waits for health, warms up, runs guidellm at fixed concurrency levels per workload, samples GPU metrics with nvidia-smi, stops the engine.
- Workload profiles including a replica of the 200 input / 200 output token shape used in Akamai's published RTX PRO 6000 Blackwell benchmark.
- Offline analysis: cost per million output tokens from plan pricing, and a markdown comparison report with Mermaid charts.
- Operator scripts: preflight (plan and region availability via Linode API), provision, sync, run, fetch, destroy, and a budget guard that destroys the instance after a time limit.
- Prerequisites and reproduction guide for outside engineers: scope of a valid reproduction, account setup, GPU plan access request, token scopes, model license, tooling, budget table, first-run order, expected first-run failures, comparison tolerances, discrepancy reporting.
- Documentation: architecture, methodology and controlled variables, engine notes, cost model, OSS landscape, references (Akamai's published benchmark, plan and price sources, project links).
