# Cost model

## Formula

    USD per 1M output tokens = hourly_price / (output_tokens_per_second x 3600) x 1e6

analyze/cost.py applies it to every measured point using the plan price from
profiles/pricing.json (or --price-per-hour). Total-token and per-1k-request
variants are in cost.csv.

Example at list price 0.52 USD/hr:

| Output tok/s | USD per 1M output tokens |
| ---: | ---: |
| 200 | 0.722 |
| 500 | 0.289 |
| 1000 | 0.144 |
| 2000 | 0.072 |

## What the formula omits, and how to add it

| Cost | Why it is excluded from the per-point number | How to include |
| --- | --- | --- |
| Egress | Depends on response size and the plan's included transfer; Akamai's pitch is low egress, so it belongs in a provider comparison, not an engine comparison | Add USD per GB and average response bytes to a provider profile |
| Storage | Model cache lives on the instance disk included in the plan | Add block storage price if weights move to a volume |
| Idle time | Utilization below 100 percent multiplies the effective price | Report cost at measured throughput and at a stated utilization (for example 40 percent) |
| Provisioning time | Driver install and model download are billed minutes with zero tokens | Record from provision.sh timestamps; amortize over the run |
| Power at the wall | Not billed separately on cloud, but recorded (nvidia-smi power.draw) for energy per token comparisons | tokens per joule from gpu.csv |
| Commit discounts | Cloud providers quote on-demand; reserved pricing changes the ranking | Separate pricing profiles per commitment level |

## Comparing to hyperscalers and neoclouds

Use the same formula with their hourly price for a comparable GPU and the
same engine and workload. Two rules:

1. Compare identical GPU SKUs where possible (L4 vs L4, RTX 4000 Ada has no
   hyperscaler twin; the honest comparison is cost per token, not per GPU
   hour).
2. State on-demand vs committed pricing and the price date on every table.

Akamai's published claim for Cloud Inference is 86 percent lower cost than
hyperscalers. This harness produces the per-workload numbers needed to verify
that statement, with the inputs recorded so a reader can check them.

## Price sources

profiles/pricing.json carries the list prices used, a verification date,
and notes. bin/preflight.sh reads the live price from the Linode API and
warns if the file has drifted. Update the file, not the report.
