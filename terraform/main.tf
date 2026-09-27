# Single GPU instance for serving-engine benchmarking.
# Everything here is ephemeral. Destroy when the run is complete: powered-off
# instances continue to bill at the plan rate.

# Root password is required by the API but never used: SSH is key-only and
# password authentication is disabled by cloud-init.
resource "random_password" "root" {
  length  = 32
  special = true
}

resource "linode_sshkey" "operator" {
  label   = "${var.label}-operator"
  ssh_key = chomp(file(pathexpand(var.ssh_public_key_path)))
}

# Render cloud-init once; ignore_changes on metadata below prevents a
# template edit from forcing instance replacement.
locals {
  public_ip = tolist(linode_instance.gpu.ipv4)[0]

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    guidellm_version = var.guidellm_version
    hf_token         = var.hf_token
    ngc_api_key      = var.ngc_api_key
    plan             = var.plan
    region           = var.region
  })
}

resource "linode_instance" "gpu" {
  label           = var.label
  region          = var.region
  type            = var.plan
  image           = var.image
  root_pass       = random_password.root.result
  authorized_keys = [linode_sshkey.operator.ssh_key]
  private_ip      = false
  booted          = true
  tags            = var.tags

  metadata {
    user_data = base64encode(local.cloud_init)
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}

# Inbound DROP by default. SSH from the operator CIDRs; engine port only when
# expose_engine_port is true (default is an SSH tunnel instead).
resource "linode_firewall" "gpu" {
  label           = "${var.label}-fw"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  tags            = var.tags
  linodes         = [linode_instance.gpu.id]

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = [for c in var.allowed_cidrs : c if !can(regex(":", c))]
    ipv6     = [for c in var.allowed_cidrs : c if can(regex(":", c))]
  }

  dynamic "inbound" {
    for_each = var.expose_engine_port ? [1] : []
    content {
      label    = "engine"
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = "8000"
      ipv4     = [for c in var.allowed_cidrs : c if !can(regex(":", c))]
      ipv6     = [for c in var.allowed_cidrs : c if can(regex(":", c))]
    }
  }
}
