# locals.tf

locals {
  k3s_token = coalesce(var.k3s_token, random_password.k3s_token[0].result)
  kured_version  = var.kured_version != null ? var.kured_version : data.github_release.kured[0].release_tag

  # Packages needed for MicroOS to run k3s and its addons smoothly.
  needed_packages = join(" ", [
    "restorecond", "policycoreutils", "policycoreutils-python-utils",
    "setools-console", "audit", "bind-utils", "wireguard-tools", "fuse",
    "open-iscsi", "nfs-client", "xfsprogs", "git", "cifs-utils",
    "bash-completion", "mtr", "tcpdump", "udica", "qemu-guest-agent", "iptables"
  ])

  # Script to perform all OS-level setup and optimizations.
  os_setup_script = templatefile("${path.module}/scripts/os_setup.sh.tpl", {
    needed_packages    = local.needed_packages
    selinux_policy     = local.selinux_policy
    disable_selinux    = var.disable_selinux
    swap_size          = var.swap_size
    ssh_port           = var.ssh_port
    ssh_max_auth_tries = 2
    # Add network fixes
    network_fixes      = true
  })

  # Base k3s configuration for a single-node cluster.
  k3s_config = merge(
    {
      "token"                       = local.k3s_token
      "cluster-init"                = true
      "disable-cloud-controller"    = true
      "disable-kube-proxy"          = var.cni_plugin == "cilium"
      "disable"                     = ["servicelb", "traefik", "local-storage"]
      "disable"                     = compact(["traefik", "local-storage", var.ingress_controller == "none" ? "servicelb" : ""]),
      "write-kubeconfig-mode"       = "0644"
      "node-name"                   = var.node_name
      "node-ip"                     = var.server_ip
      "advertise-address"           = var.server_ip
      "https-listen-port"           = 6443
      "tls-san"                     = [var.server_ip, var.node_name]
      "kubelet-arg"                 = var.kubelet_args
      "kube-apiserver-arg"          = []
      "kube-controller-manager-arg" = []

      "flannel-iface"               = var.network_interface
      "flannel-backend-options"     = "MTU=1500"
      "flannel-backend"             = "vxlan"
      "flannel-backend-type"        = "vxlan"
      "flannel-backend-vxlan-mtu"   = "1450"  # Reduced from 1500

      "tls-san"                     = [var.server_ip, var.node_name]

      # Enhanced kubelet args for better DNS and networking
      "kubelet-arg" = concat(var.kubelet_args, [
        "cluster-dns=10.43.0.10",
        "cluster-domain=cluster.local",
        "resolv-conf=/etc/rancher/k3s/resolv.conf",
        "max-pods=110"
      ])

      # API server args for better networking
      "kube-apiserver-arg" = [
        "enable-admission-plugins=NodeRestriction,ResourceQuota"
      ]
    },
    # CNI specific settings
    lookup({
      "flannel" = {
        "flannel-backend" = "vxlan",
        "flannel-conf" = "/etc/rancher/k3s/flannel-conf.json"
      }
      "cilium"  = {
        "flannel-backend" = "none",
        "disable-network-policy" = true
      }
    }, var.cni_plugin, {})
  )

  # Commands to install k3s server.
  install_k3s_server = [
    "set -ex",
    "mkdir -p /etc/rancher/k3s",
    "mv /tmp/config.yaml /etc/rancher/k3s/config.yaml",
    "chmod 0600 /etc/rancher/k3s/config.yaml",
    var.k3s_registries != "" ? "mv /tmp/registries.yaml /etc/rancher/k3s/registries.yaml" : "echo 'No private registries specified.'",
    "curl -sfL https://get.k3s.io | ${var.install_k3s_version == "" ? "INSTALL_K3S_CHANNEL=${var.initial_k3s_channel}" : "INSTALL_K3S_VERSION=${var.install_k3s_version}"} INSTALL_K3S_EXEC='server' sh -",
  ]

  # Kustomization manifest to deploy all addons.
  kustomization_yaml = yamlencode({
    apiVersion = "kustomize.config.k8s.io/v1beta1"
    kind       = "Kustomization"
    resources = concat(
      [
        "https://github.com/kubereboot/kured/releases/download/${local.kured_version}/kured-${local.kured_version}-dockerhub.yaml",
        "https://github.com/rancher/system-upgrade-controller/releases/download/${var.sys_upgrade_controller_version}/system-upgrade-controller.yaml",
        "https://github.com/rancher/system-upgrade-controller/releases/download/${var.sys_upgrade_controller_version}/crd.yaml"
      ],
      var.ingress_controller == "traefik" ? ["traefik_ingress.yaml"] : [],
      var.cni_plugin == "cilium" ? ["cilium.yaml"] : [],
      //var.enable_cert_manager ? ["https://github.com/cert-manager/cert-manager/releases/download/${var.cert_manager_version}/cert-manager.yaml"] : [],
      var.enable_cert_manager ? ["cert_manager.yaml"] : [],
      var.enable_external_dns ? ["external_dns.yaml"] : [],
      var.cni_plugin == "flannel" ? ["flannel-rbac.yaml"] : [],
      !var.disable_longhorn ? ["longhorn.yaml"] : [],
    ),
    patches = [
      {
        target = {
          group     = "apps"
          version   = "v1"
          kind      = "Deployment"
          name      = "system-upgrade-controller"
          namespace = "system-upgrade"
        }
        patch = file("${path.module}/kustomize/system-upgrade-controller.yaml")
      },
      {
        path = "kured.yaml"
      }
    ]
  })

  # Default options for Kured.
  kured_options = merge({
    "reboot-command" : "/usr/bin/systemctl reboot",
    "period" : "1h",
  }, var.kured_options)

  # Default values for Cilium Helm chart.
  cilium_values = var.cilium_values != "" ? var.cilium_values : <<EOT
ipam:
  mode: kubernetes
kubeProxyReplacement: partial
k8sServiceHost: ${var.server_ip}
k8sServicePort: 6443
hubble:
  relay:
    enabled: true
  ui:
    enabled: true
EOT

  # Default values for Cert-Manager Helm chart.
  cert_manager_values = var.cert_manager_values != "" ? var.cert_manager_values : <<EOT
installCRDs: true
replicaCount: 1
webhook:
  replicaCount: 1
cainjector:
  replicaCount: 1
EOT

  # Default values for ExternalDNS Helm chart.
  external_dns_values = var.external_dns_values != "" ? var.external_dns_values : <<EOT
provider: ${var.external_dns_provider}
domainFilters: ["${var.external_dns_domain_filter}"]
env:
- name: ${var.external_dns_env_secret_name}
  valueFrom:
    secretKeyRef:
      name: external-dns-secrets
      key: api_token
EOT

  # Default values for Traefik Helm chart.
  traefik_values = var.traefik_values != "" ? var.traefik_values : <<EOT
deployment:
  kind: Deployment
  replicas: 1
service:
  enabled: true
  type: LoadBalancer
ports:
  web:
    port: 80
    exposedPort: 80
  websecure:
    port: 443
    exposedPort: 443
    tls:
      enabled: true
additionalArguments:
  - "--providers.kubernetesingress.ingressendpoint.publishedservice=${var.ingress_target_namespace}/traefik"
EOT

  # Default values for Longhorn Helm chart.
  longhorn_values = var.longhorn_values != "" ? var.longhorn_values : <<EOT
defaultSettings:
  defaultDataPath: /var/longhorn
persistence:
  defaultFsType: ${var.longhorn_fstype}
  defaultClassReplicaCount: ${var.longhorn_replica_count}
EOT


  # SELinux policy for k3s and containers on MicroOS.
  selinux_policy = <<-EOT
    module k3s_custom_selinux 1.0;

    require {
        type kernel_t, bin_t, kernel_generic_helper_t, iscsid_t, iscsid_exec_t, var_run_t, var_lib_t,
            init_t, unlabeled_t, systemd_logind_t, systemd_hostnamed_t, container_t,
            cert_t, container_var_lib_t, etc_t, usr_t, container_file_t, container_log_t,
            container_share_t, container_runtime_exec_t, container_runtime_t, var_log_t, proc_t, io_uring_t, fuse_device_t, http_port_t,
            container_var_run_t;
        class key { read view };
        class file { open read execute execute_no_trans create link lock rename write append setattr unlink getattr watch };
        class sock_file { watch write create unlink };
        class unix_dgram_socket create;
        class unix_stream_socket { connectto read write };
        class dir { add_name create getattr link lock read rename remove_name reparent rmdir setattr unlink search write watch };
        class lnk_file { read create };
        class system module_request;
        class filesystem associate;
        class bpf map_create;
        class io_uring sqpoll;
        class anon_inode { create map read write };
        class tcp_socket name_connect;
        class chr_file { open read write };
    }

    #============= kernel_generic_helper_t ==============
    allow kernel_generic_helper_t bin_t:file execute_no_trans;
    allow kernel_generic_helper_t kernel_t:key { read view };
    allow kernel_generic_helper_t self:unix_dgram_socket create;

    #============= iscsid_t ==============
    allow iscsid_t iscsid_exec_t:file execute;
    allow iscsid_t var_run_t:sock_file write;
    allow iscsid_t var_run_t:unix_stream_socket connectto;

    #============= init_t ==============
    allow init_t unlabeled_t:dir { add_name remove_name rmdir search };
    allow init_t unlabeled_t:lnk_file create;
    allow init_t container_t:file { open read };
    allow init_t container_file_t:file { execute execute_no_trans };
    allow init_t fuse_device_t:chr_file { open read write };
    allow init_t http_port_t:tcp_socket name_connect;

    #============= systemd_logind_t ==============
    allow systemd_logind_t unlabeled_t:dir search;

    #============= systemd_hostnamed_t ==============
    allow systemd_hostnamed_t unlabeled_t:dir search;

    #============= container_t ==============
    allow container_t { cert_t container_log_t }:dir read;
    allow container_t { cert_t container_log_t }:lnk_file read;
    allow container_t cert_t:file { read open };
    allow container_t container_var_lib_t:dir { add_name remove_name write read create };
    allow container_t container_var_lib_t:file { append create open read write rename lock setattr getattr unlink };
    allow container_t etc_t:dir { add_name remove_name write create setattr watch };
    allow container_t etc_t:file { create setattr unlink write };
    allow container_t etc_t:sock_file { create unlink };
    allow container_t usr_t:dir { add_name create getattr link lock read rename remove_name reparent rmdir setattr unlink search write };
    allow container_t usr_t:file { append create execute getattr link lock read rename setattr unlink write };
    allow container_t container_file_t:file { open read write append getattr setattr lock };
    allow container_t container_file_t:sock_file watch;
    allow container_t container_log_t:file { open read write append getattr setattr watch };
    allow container_t container_share_t:dir { read write add_name remove_name };
    allow container_t container_share_t:file { read write create unlink };
    allow container_t container_runtime_exec_t:file { read execute execute_no_trans open };
    allow container_t container_runtime_t:unix_stream_socket { connectto read write };
    allow container_t kernel_t:system module_request;
    allow container_t var_log_t:dir { add_name write remove_name watch read };
    allow container_t var_log_t:file { create lock open read setattr write unlink getattr };
    allow container_t var_lib_t:dir { add_name remove_name write read create };
    allow container_t var_lib_t:file { append create open read write rename lock setattr getattr unlink };
    allow container_t proc_t:filesystem associate;
    allow container_t self:bpf map_create;
    allow container_t self:io_uring sqpoll;
    allow container_t io_uring_t:anon_inode { create map read write };
    allow container_t container_var_run_t:dir { add_name remove_name write };
    allow container_t container_var_run_t:file { create open read rename unlink write };
  EOT

  # Find all user-provided manifest templates.
  user_kustomization_templates = try(fileset(var.extra_kustomize_folder, "**/*.yaml.tpl"), toset([]))
}