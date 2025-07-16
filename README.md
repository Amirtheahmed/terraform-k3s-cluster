# Terraform k3s on Bare Metal

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
- **Extensible**: Easily add your own manifests and Helm charts using Kustomize.

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

## Adding Extras (Custom Manifests)

You can easily deploy your own applications, Helm charts, and other Kubernetes manifests by creating a folder (default: `extra-manifests`) next to your `kube.tf` file.

1.  **Create the folder**:
    ```sh
    mkdir extra-manifests
    ```

2.  **Add your manifests**: Place any number of `.yaml` or `.yaml.tpl` files in this folder. The module will automatically upload and apply them. Files ending in `.tpl` will be rendered as Terraform templates.

3.  **Create a `kustomization.yaml.tpl`**: This file is required at the root of your `extra-manifests` folder to tie everything together.

    **Example `extra-manifests/kustomization.yaml.tpl`**:
    ```yaml
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - argocd.yaml
      - my-app-namespace.yaml
    ```

4.  **(Optional) Pass Parameters**: You can pass variables to your templates using the `extra_kustomize_parameters` variable in your `kube.tf`.

    **Example `extra-manifests/my-app.yaml.tpl`**:
    ```yaml
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ${app_namespace}
    ```
    **In `kube.tf`**:
    ```terraform
    module "k3s_bare_metal" {
      # ...
      extra_kustomize_parameters = {
        app_namespace = "production"
      }
    }
    ```

5.  **(Optional) Run Post-Deploy Commands**: For complex applications like ArgoCD that require waiting for CRDs, use the `extra_kustomize_deployment_commands` variable.

    **In `kube.tf`**:
    ```terraform
    module "k3s_bare_metal" {
      # ...
      extra_kustomize_deployment_commands = "kubectl wait --for condition=established --timeout=120s crd/applications.argoproj.io"
    }
    ```

## Module Variables
*(See `variables.tf` for a full list)*