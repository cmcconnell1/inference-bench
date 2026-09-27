variable "label" {
  description = "Instance label. Also used as the firewall and SSH key label prefix."
  type        = string
  default     = "inference-bench"
}

variable "region" {
  description = "Akamai Cloud region with GPU plans and the Metadata service. Confirm with bin/preflight.sh."
  type        = string
  default     = "us-ord"
}

variable "plan" {
  description = "GPU plan type ID. RTX 4000 Ada x1 Small (g2-gpu-rtx4000a1-s) is the cheapest 20 GB option. RTX PRO 6000 Blackwell: g3-gpu-rtxpro6000-blackwell-1 (limited availability)."
  type        = string
  default     = "g2-gpu-rtx4000a1-s"
}

variable "image" {
  description = "Distribution image. Ubuntu 24.04 is the tested target for the cloud-init driver install."
  type        = string
  default     = "linode/ubuntu24.04"
}

variable "ssh_public_key_path" {
  description = "Path to the operator's SSH public key. Root login is key-only."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_cidrs" {
  description = "Source CIDRs allowed to reach SSH. Set to the operator's public IP with /32. Do not use 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "allowed_cidrs must list at least one CIDR and must not contain 0.0.0.0/0."
  }
}

variable "expose_engine_port" {
  description = "Open TCP 8000 to allowed_cidrs. Default false: reach the engine through an SSH tunnel instead."
  type        = bool
  default     = false
}

variable "guidellm_version" {
  description = "Exact guidellm version installed on the host."
  type        = string
  default     = "0.7.4"
}

variable "hf_token" {
  description = "Hugging Face token for gated models (Llama, Mistral). Written to /opt/bench/env on the host with mode 0600. Leave empty for ungated models."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ngc_api_key" {
  description = "NVIDIA NGC API key, only needed for the NIM engine profile."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to the instance and firewall."
  type        = list(string)
  default     = ["inference-bench", "ephemeral"]
}
