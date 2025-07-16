# Terraform k3s on Bare Metal / Root Server with openSUSE MicroOS

A lightweight, provider-agnostic Terraform module to deploy a single-node k3s cluster on any bare-metal server or VM running **openSUSE MicroOS**.

This project is a stripped-down version of the excellent [kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner) module, adapted to be cloud-independent. It retains the core principles of an optimized, auto-upgrading, and secure k3s setup.

## Features

- **Provider Agnostic**: Deploy on any bare-metal server, root server (like Netcup, Hetzner Robot), or VM.
- **MicroOS Base**: Leverages the security and transactional-update features of openSUSE MicroOS.
- **k3s Powered**: Uses the lightweight, certified Kubernetes distribution from Rancher.
- **Automated Setup**: Installs k3s and essential addons with a single `terraform apply`.
- **Essential Addons**: Comes with pre-configured setups for:
  - **Kured**: For safe, automated node reboots after OS updates.
  - **System Upgrade Controller**: For automated k3s version upgrades.
  - **Cert-Manager**: For automated TLS certificate management.
  - **ExternalDNS** (Optional): For automated DNS record management.
- **Choice of CNI**: Supports both lightweight `Flannel` (default) and feature-rich `Cilium`.

## Prerequisites

1.  **A Server**: You need a server with **openSUSE MicroOS** already installed. This module **does not** install the operating system.
2.  **SSH Access**: You must have root SSH access to the server using a private key.
3.  **Terraform**: [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli) (or [OpenTofu](https://opentofu.org/docs/intro/install/)) must be installed on your local machine.

## Getting Started

1.  **Clone or Download this Module**: Place the module files in a directory on your local machine.

2.  **Create a `kube.tf` file**: In the same directory (or a parent directory), create a file to call the module. See `kube.tf.example` for a starting point.

    ```terraform
    module "k3s_bare_metal" {
      source = "./path/to/module" # Or just "./" if in the same directory

      # --- Server & SSH Configuration ---
      server_ip       = "203.0.113.10" # <-- Set your server's public IP
      ssh_private_key = file("~/.ssh/id_ed25519") # <-- Set path to your private key

      # --- (Optional) Addon Configuration ---
      enable_external_dns        = true
      external_dns_provider      = "cloudflare"
      external_dns_domain_filter = "your-domain.com" # <-- Set your domain
    }

    output "kubeconfig" {
      value     = module.k3s_bare_metal.kubeconfig
      sensitive = true
    }
    ```

3.  **Deploy the Cluster**:
    ```sh
    terraform init
    terraform apply
    ```
    The process will take several minutes. It involves installing packages, rebooting the server once, and then setting up k3s and all the addons.

4.  **Access Your Cluster**: Once the apply is complete, the `kubeconfig` will be printed as an output.
    ```sh
    terraform output -raw kubeconfig > kubeconfig.yaml
    export KUBECONFIG=$(pwd)/kubeconfig.yaml
    kubectl get nodes
    ```

## Module Variables

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `server_ip` | **Required.** The public IP address of the server. | `string` | - |
| `ssh_private_key` | **Required.** The content of the SSH private key. | `string` | - |
| `ssh_user` | The user for SSH connections. | `string` | `"root"` |
| `ssh_port` | The port for SSH connections. | `number` | `22` |
| `node_name` | The name for the Kubernetes node. | `string` | `"bare-metal-k3s"` |
| `cni_plugin` | CNI to use: `flannel` or `cilium`. | `string` | `"flannel"` |
| `enable_cert_manager` | If true, installs Cert-Manager. | `bool` | `true` |
| `enable_external_dns` | If true, installs ExternalDNS. | `bool` | `false` |
| `external_dns_provider` | DNS provider for ExternalDNS (e.g., `cloudflare`). | `string` | `"cloudflare"` |
| `external_dns_domain_filter` | Domain to manage with ExternalDNS. | `string` | `""` |
| ... | *(See `variables.tf` for a full list)* | ... | ... |

## Notes

- **ExternalDNS Secret**: If you enable ExternalDNS, you must create a Kubernetes secret containing the API token for your DNS provider. The module does not handle this for security reasons.
- **Idempotency**: The setup scripts are designed to be as idempotent as possible. Re-running `terraform apply` should bring the server to the desired state without errors.
- **OS Updates**: MicroOS performs transactional updates automatically. Kured ensures that the node is safely drained and rebooted when required.