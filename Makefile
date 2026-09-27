# Operator entry points. Every script also supports -h and --debug.
SHELL := /bin/bash
.DEFAULT_GOAL := help
# RUN defaults to the newest run directory under results/; override with RUN=<id>.
RUN ?= $(shell ls -1t results 2>/dev/null | grep -v -e instance.json -e suite.log -e .gitkeep | head -1)
HOURS ?= 3

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

preflight: ## Validate token, plan, region, local tools
	bin/preflight.sh

provision: ## terraform apply and wait for the GPU driver (billing starts)
	bin/provision.sh

guard: ## Destroy automatically after HOURS (default 3); run in a second terminal
	bin/budget-guard.sh --hours $(HOURS)

sync: ## Copy the harness to /opt/bench on the instance
	bin/sync.sh

smoke: sync ## 2-minute sanity run: vLLM only, tiny workload
	bin/run-remote.sh --engines vllm --workloads smoke --run-id smoke

suite: sync ## Default suite: five engines, two workloads, one repetition
	bin/run-remote.sh

suite-full: sync ## Reportable suite: five engines, four workloads, three repetitions
	bin/run-remote.sh --workloads akamai-blog-200x200,chat-short,rag-long-prompt,codegen --repeat 3

log: ## Tail the remote suite log
	bin/ssh.sh tail -f /var/lib/bench/suite.log

fetch: ## Pull results back to ./results
	bin/fetch-results.sh

analyze: ## Cost table and REPORT.md for RUN (default: newest)
	@test -n "$(RUN)" || { echo "no run under results/"; exit 1; }
	python3 analyze/cost.py results/$(RUN)
	python3 analyze/report.py results/$(RUN) > results/$(RUN)/REPORT.md
	@echo "wrote results/$(RUN)/REPORT.md"

destroy: ## Fetch results then terraform destroy (stops billing)
	bin/destroy.sh

lint: ## shellcheck, terraform fmt/validate, python compile, mermaid render
	@command -v shellcheck >/dev/null && shellcheck -x bin/*.sh host/*.sh lib/common.sh || echo "shellcheck not installed"
	terraform -chdir=terraform fmt -check -diff
	terraform -chdir=terraform init -backend=false -input=false >/dev/null && terraform -chdir=terraform validate
	python3 -m py_compile analyze/*.py analyze/lib/*.py
	@command -v mmdc >/dev/null && for f in docs/diagrams/*.mmd; do mmdc -q -i "$$f" -o /tmp/$$(basename "$$f" .mmd).svg || exit 1; done && echo "mermaid ok" || true

.PHONY: help preflight provision guard sync smoke suite suite-full log fetch analyze destroy lint
