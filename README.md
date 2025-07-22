# Terraform K3s Bare Metal Module

[![Terraform Version](https://img.shields.io/badge/terraform-%3E%3D1.5.0-blue)](https://www.terraform.io/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A production-ready, provider-agnostic Terraform module to deploy single-node or multi-node k3s clusters on bare-metal servers running **openSUSE MicroOS**.

This module is inspired by the excellent [kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner) project, adapted for cloud-independent deployments with enterprise-grade security and automation features.

## 🚀 Features

- **🔧 Provider Agnostic**: Deploy on any bare-metal server, VPS, or VM with SSH access
- **🔒 Security-First**: Leverages openSUSE MicroOS's transactional updates and immutable filesystem
- **☸️ K3s Optimized**: Lightweight Kubernetes with production-ready defaults
- **🔄 Auto-Updates**: Automated OS and k3s updates via Kured and System Upgrade Controller
- **📦 Essential Addons**: Pre-configured with critical cluster components
- **🌐 CNI Flexibility**: Choose between Flannel (simple) or Cilium (advanced)
- **🎨 Extensible**: Easy integration of custom manifests via Kustomize

## 📋 Prerequisites

- **Server**: A server with **openSUSE MicroOS** pre-installed
- **SSH Access**: Root SSH access via private key
- **Terraform**: Version >= 1.5.0 or [OpenTofu](https://opentofu.org/)
- **Network**: Server must have internet access for package installation

## 🏁 Quick Start

### Using as a Terraform Module

```hcl
module "k3s_cluster" {
  source  = "github.com/Amirtheahmed/terraform-k3s-bare-metal?ref=v1.0.0"
  
  # Required variables
  server_ip       = "203.0.113.10"
  ssh_private_key = file("~/.ssh/id_ed25519")
  
  # Optional: Enable external DNS
  enable_external_dns        = true
  external_dns_provider      = "cloudflare"
  external_dns_domain_filter = "example.com"
}

# Output the kubeconfig
output "kubeconfig" {
  value     = module.k3s_cluster.kubeconfig
  sensitive = true
}
```

### Deploy the Cluster

```bash
terraform init
terraform plan
terraform apply
```

### Access Your Cluster

```bash
# Save kubeconfig
terraform output -raw kubeconfig > ~/.kube/k3s-config
export KUBECONFIG=~/.kube/k3s-config

# Verify cluster
kubectl get nodes
kubectl get pods -A
```

## 📦 Included Components

| Component | Purpose | Default |
|-----------|---------|---------|
| **Kured** | Automated node reboots after OS updates | ✅ Enabled |
| **System Upgrade Controller** | Automated k3s version upgrades | ✅ Enabled |
| **Cert-Manager** | TLS certificate automation | ✅ Enabled |
| **External-DNS** | Automated DNS record management | ❌ Optional |
| **Longhorn** | Distributed block storage | ✅ Enabled |
| **Traefik** | Ingress controller | ✅ Enabled |

## 🛠️ Configuration Options

### Basic Configuration

```hcl
module "k3s_cluster" {
  source = "github.com/Amirtheahmed/terraform-k3s-bare-metal?ref=v1.0.0"
  
  # Server Configuration
  server_ip       = "203.0.113.10"
  ssh_user        = "root"
  ssh_port        = 22
  ssh_private_key = file("~/.ssh/id_ed25519")
  node_name       = "k3s-master-01"
  
  # K3s Configuration
  install_k3s_version = "v1.29.4+k3s1"  # Pin specific version
  initial_k3s_channel = "stable"        # Or use channel
  
  # Network Configuration
  cni_plugin        = "cilium"          # or "flannel" (default)
  network_interface = "eth0"
}
```

### Advanced Features

```hcl
module "k3s_cluster" {
  source = "github.com/Amirtheahmed/terraform-k3s-bare-metal?ref=v1.0.0"
  
  # ... basic config ...
  
  # Storage Configuration
  disable_longhorn      = false
  longhorn_replica_count = 3
  longhorn_fstype       = "xfs"
  
  # Ingress Configuration
  ingress_controller = "traefik"
  traefik_values     = file("traefik-values.yaml")
  
  # Security
  disable_selinux = false  # Keep SELinux enabled
  
  # Performance
  swap_size = "2G"
  kubelet_args = [
    "max-pods=250",
    "kube-reserved=cpu=200m,memory=1Gi"
  ]
}
```

## 🎯 Custom Manifests

Deploy your own applications alongside the cluster:

1. Create a directory for your manifests:
   ```bash
   mkdir extra-manifests
   ```

2. Add your Kubernetes manifests:
   ```yaml
   # extra-manifests/namespace.yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: my-app
   ```

3. Create a kustomization file:
   ```yaml
   # extra-manifests/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - namespace.yaml
   ```

4. Reference in your Terraform:
   ```hcl
   module "k3s_cluster" {
     source = "github.com/Amirtheahmed/terraform-k3s-bare-metal?ref=v1.0.0"
     
     # ... other config ...
     
     extra_kustomize_folder = "extra-manifests"
     extra_kustomize_parameters = {
       app_version = "1.2.3"
     }
   }
   ```

## 🔐 Security Considerations

- **SELinux**: Custom policies are applied by default for k3s compatibility
- **SSH**: Hardened configuration with key-only authentication
- **Firewall**: Ensure required ports are open:
  - 6443: Kubernetes API
  - 10250: Kubelet metrics
  - 80/443: HTTP/HTTPS (if using ingress)

## 🔄 Maintenance

### Automated Updates

The cluster automatically handles:
- **OS Updates**: Via MicroOS transactional-update + Kured
- **K3s Updates**: Via System Upgrade Controller

### Manual Interventions

```bash
# Check update status
kubectl get nodes
kubectl get plans -n system-upgrade

# Trigger immediate OS update
kubectl label node <node-name> kured-reboot-required=true

# Update k3s channel
kubectl edit plan k3s-server -n system-upgrade
```

## 📊 Module Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `server_ip` | Public IP of the server | `string` | - | ✅ |
| `ssh_private_key` | SSH private key content | `string` | - | ✅ |
| `ssh_user` | SSH username | `string` | `"root"` | ❌ |
| `node_name` | Kubernetes node name | `string` | `"bare-metal-k3s"` | ❌ |
| `cni_plugin` | CNI plugin choice | `string` | `"flannel"` | ❌ |
| `enable_cert_manager` | Install cert-manager | `bool` | `true` | ❌ |
| `enable_external_dns` | Install external-dns | `bool` | `false` | ❌ |

[View all inputs](variables.tf)

## 📤 Module Outputs

| Name | Description | Sensitive |
|------|-------------|-----------|
| `kubeconfig` | Kubeconfig for cluster access | ✅ |
| `k3s_token` | Token for joining additional nodes | ✅ |

## 🚀 Examples

### Minimal Setup

```hcl
module "k3s_minimal" {
  source = "github.com/Amirtheahmed/terraform-k3s-bare-metal?ref=v1.0.0"
  
  server_ip       = "10.0.0.10"
  ssh_private_key = file("~/.ssh/id_rsa")
}
```

### Production Setup

See [examples/production](examples/production) for a complete production configuration including:
- High availability setup
- Monitoring stack
- Backup configuration
- Security hardening

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner) - Inspiration and base concepts
- [k3s](https://k3s.io/) - Lightweight Kubernetes
- [openSUSE MicroOS](https://microos.opensuse.org/) - Immutable OS platform