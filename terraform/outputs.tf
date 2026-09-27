output "instance_id" {
  value = linode_instance.gpu.id
}

output "ip_address" {
  value = local.public_ip
}

output "plan" {
  value = var.plan
}

output "region" {
  value = var.region
}

output "ssh_command" {
  value = "ssh -o StrictHostKeyChecking=accept-new root@${local.public_ip}"
}

output "tunnel_command" {
  description = "Forward the engine port to the operator machine without opening it in the firewall."
  value       = "ssh -N -L 8000:127.0.0.1:8000 root@${local.public_ip}"
}
