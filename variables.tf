# variables.tf

# --- Server & SSH Configuration ---
variable "server_ip" {
  description = "The public IP address of the bare-metal server."
  type        = string
}

variable "ssh_user" {
  description = "The user for SSH connections (e.g., 'root')."
  type        = string
  default     = "root"
}

variable "ssh_port" {
  description = "The port for SSH connections."
  type        = number
  default     = 22
}

variable "ssh_private_key" {
  description = "The content of the SSH private key for authentication."
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "The name for the Kubernetes node."
  type        = string
  default     = "bare-metal-k3s"
}

variable "network_interface" {
  description = "The network interface k3s should use for its flannel CNI."
  type        = string
  default     = "eth0"
}

# --- OS Configuration ---
variable "swap_size" {
  description = "Size of the swap file to create (e.g., '2G', '512M'). Leave empty to disable."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^$|^[1-9][0-9]{0,3}(G|M)$", var.swap_size))
    error_message = "Invalid swap size. Examples: 512M, 2G."
  }
}

variable "disable_selinux" {
  description = "If true, disables SELinux instead of applying custom policies. Not recommended."
  type        = bool
  default     = false
}

# --- k3s Configuration ---
variable "k3s_token" {
  description = "A secret token for k3s. If not provided, a random one will be generated. Must be provided for multi-node setups in the future."
  type        = string
  sensitive   = true
  default     = null
}

variable "initial_k3s_channel" {
  description = "The k3s channel to install from (e.g., 'stable', 'latest', 'v1.29')."
  type        = string
  default     = "stable"
}

variable "install_k3s_version" {
  description = "A specific k3s version to install (e.g., 'v1.29.4+k3s1'). Overrides initial_k3s_channel."
  type        = string
  default     = ""
}

variable "kubelet_args" {
  description = "A list of extra arguments to pass to the kubelet."
  type        = list(string)
  default     = ["kube-reserved=cpu=100m,memory=500Mi", "system-reserved=cpu=100m,memory=500Mi"]
}

variable "k3s_registries" {
  description = "Content for the /etc/rancher/k3s/registries.yaml file for private registry access."
  type        = string
  default     = ""
}

# --- CNI Configuration ---
variable "cni_plugin" {
  description = "The CNI plugin to use. 'flannel' is lightweight. 'cilium' offers advanced features."
  type        = string
  default     = "flannel"
  validation {
    condition     = contains(["flannel", "cilium"], var.cni_plugin)
    error_message = "Allowed values are 'flannel' or 'cilium'."
  }
}

variable "cilium_version" {
  description = "Version of the Cilium Helm chart to install."
  type        = string
  default     = "1.15.1"
}

variable "cilium_values" {
  description = "Custom values.yaml content for the Cilium Helm chart."
  type        = string
  default     = ""
}

# --- Addon Configuration ---
variable "sys_upgrade_controller_version" {
  description = "Version of the System Upgrade Controller."
  type        = string
  default     = "v0.14.0"
}

variable "kured_version" {
  description = "Version of Kured to install."
  type        = string
  default     = "1.14.2"
}

variable "kured_options" {
  description = "A map of additional options for Kured."
  type        = map(string)
  default     = {}
}

variable "enable_cert_manager" {
  description = "If true, installs Cert-Manager for automated TLS certificates."
  type        = bool
  default     = true
}

variable "cert_manager_version" {
  description = "Version of the Cert-Manager Helm chart."
  type        = string
  default     = "v1.14.4"
}

variable "cert_manager_values" {
  description = "Custom values.yaml content for the Cert-Manager Helm chart."
  type        = string
  default     = ""
}

variable "enable_external_dns" {
  description = "If true, installs ExternalDNS for automated DNS record management."
  type        = bool
  default     = false
}

variable "external_dns_provider" {
  description = "The DNS provider for ExternalDNS (e.g., 'cloudflare', 'aws')."
  type        = string
  default     = "cloudflare"
}

variable "external_dns_domain_filter" {
  description = "The domain for which ExternalDNS should manage records."
  type        = string
  default     = ""
}

variable "external_dns_env_secret_name" {
  description = "The name of the environment variable holding the API token for the DNS provider."
  type        = string
  default     = "CF_API_TOKEN"
}

variable "external_dns_values" {
  description = "Custom values.yaml content for the ExternalDNS Helm chart."
  type        = string
  default     = ""
}

# --- Extra Manifests Configuration ---
variable "extra_kustomize_folder" {
  description = "Folder from where to upload extra manifests and templates."
  type        = string
  default     = "extra-manifests"
}

variable "extra_kustomize_parameters" {
  description = "A map of values to pass to the user-provided templates."
  type        = any
  default     = {}
}

variable "extra_kustomize_deployment_commands" {
  description = "Shell commands to execute after applying the user-provided kustomization."
  type        = string
  default     = ""
}