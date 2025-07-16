# outputs.tf

data "remote_file" "kubeconfig" {
  depends_on = [null_resource.kustomization_user_deploy]

  conn {
    host        = var.server_ip
    port        = var.ssh_port
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }
  path = "/etc/rancher/k3s/k3s.yaml"
}

locals {
  kubeconfig_external = replace(replace(data.remote_file.kubeconfig.content, "127.0.0.1", var.server_ip), "default", var.node_name)
}

output "kubeconfig" {
  value       = local.kubeconfig_external
  description = "Kubeconfig content to access the cluster."
  sensitive   = true
}

output "k3s_token" {
  value       = local.k3s_token
  description = "The token used to join nodes to the cluster."
  sensitive   = true
}