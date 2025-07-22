# outputs.tf

data "remote_file" "remote_kubeconfig_file" {
  depends_on = [null_resource.kustomization]

  conn {
    host        = var.server_ip
    port        = var.ssh_port
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }
  path = "/etc/rancher/k3s/k3s.yaml"
}

locals {
  kubeconfig_external = replace(replace(data.remote_file.remote_kubeconfig_file.content, "127.0.0.1", var.server_ip), "default", var.node_name)
  kubeconfig_parsed   = yamldecode(local.kubeconfig_external)
  kubeconfig_data = {
    host                   = local.kubeconfig_parsed["clusters"][0]["cluster"]["server"]
    client_certificate     = base64decode(local.kubeconfig_parsed["users"][0]["user"]["client-certificate-data"])
    client_key             = base64decode(local.kubeconfig_parsed["users"][0]["user"]["client-key-data"])
    cluster_ca_certificate = base64decode(local.kubeconfig_parsed["clusters"][0]["cluster"]["certificate-authority-data"])
    # cluster_name           = var.cluster_name
  }
}

resource "local_sensitive_file" "kubeconfig" {
  count           = 1
  content         = local.kubeconfig_external
  filename        = "kubeconfig.yaml"
  file_permission = "600"
}

output "kubeconfig_data" {
  description = "Structured kubeconfig data to supply to other providers"
  value       = local.kubeconfig_data
  sensitive   = true
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