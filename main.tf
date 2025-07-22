# main.tf

resource "random_password" "k3s_token" {
  count   = var.k3s_token == null ? 1 : 0
  length  = 48
  special = false
}

# Resource to handle OS prep, optimization, and the required reboot.
resource "null_resource" "os_setup" {
  triggers = {
    server_ip       = var.server_ip
    swap_size       = var.swap_size
    disable_selinux = var.disable_selinux
    script_sha1     = sha1(local.os_setup_script)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_private_key
    port        = var.ssh_port
  }

  # Upload the OS setup script
  provisioner "file" {
    content     = local.os_setup_script
    destination = "/tmp/os_setup.sh"
  }

  # Execute the script, which ends in a reboot.
  # We use '|| true' to prevent Terraform from erroring on the expected disconnect.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/os_setup.sh",
      "/tmp/os_setup.sh || true",
    ]
    on_failure = continue
  }

  # Wait for the server to come back online after the reboot.
  # Terraform's connection block will retry until it succeeds.
  provisioner "remote-exec" {
    inline = ["echo 'Server is back online after OS configuration.'"]
  }
}

resource "null_resource" "k3s_registries_upload" {
  count = var.k3s_registries != "" ? 1 : 0

  depends_on = [null_resource.os_setup]

  triggers = {
    # Re-run if the content of the registries file changes.
    registries_content = var.k3s_registries
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_private_key
    port        = var.ssh_port
  }

  # Provisioner to upload the k3s registries configuration.
  provisioner "file" {
    content     = var.k3s_registries
    destination = "/tmp/registries.yaml"
  }
}

resource "null_resource" "network_config" {
  depends_on = [null_resource.os_setup]

  triggers = {
    server_ip = var.server_ip
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_private_key
    port        = var.ssh_port
  }

  # Create network configuration files
  provisioner "file" {
    content = templatefile("${path.module}/templates/flannel-conf.json.tpl", {})
    destination = "/tmp/flannel-conf.json"
  }

  # Create custom resolv.conf for k3s
  provisioner "file" {
    content = <<-EOT
      nameserver 10.43.0.10
      nameserver 1.1.1.1
      nameserver 8.8.8.8
      search cluster.local svc.cluster.local
      options ndots:5
    EOT
    destination = "/tmp/k3s-resolv.conf"
  }

  # Apply network fixes
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /etc/rancher/k3s",
      "mv /tmp/flannel-conf.json /etc/rancher/k3s/flannel-conf.json",
      "mv /tmp/k3s-resolv.conf /etc/rancher/k3s/resolv.conf",

      # Apply sysctl settings
      "cat > /etc/sysctl.d/99-k3s-network.conf <<EOF",
      "net.bridge.bridge-nf-call-iptables = 1",
      "net.bridge.bridge-nf-call-ip6tables = 1",
      "net.ipv4.ip_forward = 1",
      "net.ipv4.conf.all.forwarding = 1",
      "net.ipv6.conf.all.forwarding = 1",
      "net.core.rmem_max = 134217728",
      "net.core.wmem_max = 134217728",
      "net.ipv4.tcp_rmem = 4096 87380 134217728",
      "net.ipv4.tcp_wmem = 4096 65536 134217728",
      "net.core.netdev_max_backlog = 5000",
      "EOF",
      "sysctl -p /etc/sysctl.d/99-k3s-network.conf",

      # Load required kernel modules
      "modprobe br_netfilter || true",
      "modprobe nf_conntrack || true",
      "echo 'br_netfilter' > /etc/modules-load.d/k3s.conf",
      "echo 'nf_conntrack' >> /etc/modules-load.d/k3s.conf"
    ]
  }
}

# This resource handles the complete setup of the k3s server on the now-prepared machine.
resource "null_resource" "k3s_server_setup" {
  depends_on = [null_resource.os_setup]

  triggers = {
    os_setup_id            = null_resource.os_setup.id
    k3s_version_or_channel = coalesce(var.install_k3s_version, var.initial_k3s_channel)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_private_key
    port        = var.ssh_port
  }

  # Provisioner to upload the main k3s configuration file.
  provisioner "file" {
    content     = yamlencode(local.k3s_config)
    destination = "/tmp/config.yaml"
  }

  # Provisioner to run the k3s installation script.
  provisioner "remote-exec" {
    inline = local.install_k3s_server
  }

  # Start k3s and wait for it to be ready.
  provisioner "remote-exec" {
    inline = [
      "systemctl start k3s",
      # Add kubectl alias and completion for convenience
      "echo 'alias k=kubectl' > /etc/profile.d/00-kubectl.sh",
      "echo 'if command -v kubectl &>/dev/null; then source <(kubectl completion bash); complete -o default -F __start_kubectl k; fi' >> /etc/profile.d/00-kubectl.sh",
      # Wait for k3s to be ready
      <<-EOT
      timeout 120 bash <<EOF
        until [ -e /etc/rancher/k3s/k3s.yaml ]; do
          echo "Waiting for kubectl config..."
          sleep 2
        done
        until [[ "$(kubectl get --raw='/readyz' 2> /dev/null)" == "ok" ]]; do
          echo "Waiting for the cluster to become ready..."
          sleep 2
        done
      EOF
      EOT
    ]
  }
}

# This resource handles the deployment of Kubernetes addons like Kured, Cert-Manager, etc.
resource "null_resource" "kustomization" {
  depends_on = [null_resource.k3s_server_setup]

  triggers = {
    # Re-run if the main setup resource is recreated.
    setup_id = null_resource.k3s_server_setup.id
    # Re-run if addon values change.
    helm_values_yaml = join("---\n", [
      local.traefik_values,
      local.cilium_values,
      local.cert_manager_values,
      local.external_dns_values,
      local.longhorn_values,
    ])
    # Redeploy when versions of addons need to be updated
    versions = join("\n", [
      coalesce(var.initial_k3s_channel, "N/A"),
      coalesce(var.install_k3s_version, "N/A"),
      coalesce(var.kured_version, "N/A"),
      coalesce(var.cilium_version, "N/A"),
      coalesce(var.traefik_version, "N/A"),
      coalesce(var.cert_manager_version, "N/A"),
      coalesce(var.longhorn_version, "N/A"),
      coalesce(var.sys_upgrade_controller_version, "N/A"),
    ])
    options = join("\n", [
      for option, value in local.kured_options : "${option}=${value}"
    ])
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_private_key
    port        = var.ssh_port
  }

  # Create directory for addon manifests
  provisioner "remote-exec" {
    inline = ["mkdir -p /var/post_install"]
  }

  # Upload all necessary manifest and Helm chart files.
  provisioner "file" {
    content     = local.kustomization_yaml
    destination = "/var/post_install/kustomization.yaml"
  }

  provisioner "file" {
    content     = file("${path.module}/kustomize/system-upgrade-controller.yaml")
    destination = "/var/post_install/system-upgrade-controller.yaml"
  }

  provisioner "file" {
    content     = templatefile("${path.module}/templates/kured.yaml.tpl", { options = local.kured_options })
    destination = "/var/post_install/kured.yaml"
  }

  # Upload the flannel RBAC fix
  provisioner "file" {
    content     = file("${path.module}/kustomize/flannel-rbac.yaml")
    destination = "/var/post_install/flannel-rbac.yaml"
  }

  provisioner "file" {
    content = var.ingress_controller == "traefik" ? templatefile("${path.module}/templates/traefik_ingress.yaml.tpl", {
      version          = var.traefik_version
      values           = indent(4, local.traefik_values)
      target_namespace = var.ingress_target_namespace
    }) : ""
    destination = "/var/post_install/traefik_ingress.yaml"
  }

  provisioner "file" {
    content = var.cni_plugin == "cilium" ? templatefile("${path.module}/templates/cilium.yaml.tpl", {
      values  = indent(4, local.cilium_values)
      version = var.cilium_version
    }) : ""
    destination = "/var/post_install/cilium.yaml"
  }

  provisioner "file" {
    content = var.enable_cert_manager ? templatefile("${path.module}/templates/cert_manager.yaml.tpl", {
      version   = var.cert_manager_version,
      values    = indent(4, local.cert_manager_values)
      bootstrap = false
    }) : ""
    destination = "/var/post_install/cert_manager.yaml"
  }

  provisioner "file" {
    content = var.enable_external_dns ? templatefile("${path.module}/templates/external_dns.yaml.tpl", {
      values = indent(4, local.external_dns_values)
    }) : ""
    destination = "/var/post_install/external_dns.yaml"
  }

  provisioner "file" {
    content = !var.disable_longhorn ? templatefile("${path.module}/templates/longhorn.yaml.tpl", {
      values = indent(4, local.longhorn_values)
      longhorn_namespace  = var.longhorn_namespace
      longhorn_repository = var.longhorn_repository
      version             = var.longhorn_version
      bootstrap           = var.longhorn_helmchart_bootstrap
    }) : ""
    destination = "/var/post_install/longhorn.yaml"
  }

  # Apply all manifests using Kustomize.
  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -ex

      # This ugly hack is here, because terraform serializes the
      # embedded yaml files with "- |2", when there is more than
      # one yamldocument in the embedded file. Kustomize does not understand
      # that syntax and tries to parse the blocks content as a file, resulting
      # in weird errors. so gnu sed with funny escaping is used to
      # replace lines like "- |3" by "- |" (yaml block syntax).
      # due to indendation this should not changes the embedded
      # manifests themselves
      sed -i 's/^- |[0-9]\\+$/- |/g' /var/post_install/kustomization.yaml


      # Wait for the cluster to be ready before applying addons.
      timeout 180 bash <<'BASH_EOF'
        until [[ "$(kubectl get --raw='/readyz' 2> /dev/null)" == "ok" ]]; do
          echo "Waiting for the cluster to become ready for addons..."
          sleep 2
        done
      BASH_EOF

      echo 'Remove legacy ccm manifests if they exist'
      kubectl delete serviceaccount,deployment -n kube-system --field-selector 'metadata.name=hcloud-cloud-controller-manager' --selector='app.kubernetes.io/managed-by!=Helm'
      kubectl delete clusterrolebinding -n kube-system --field-selector 'metadata.name=system:hcloud-cloud-controller-manager' --selector='app.kubernetes.io/managed-by!=Helm'

      # Apply the main kustomization file.
      kubectl apply -k /var/post_install

      # Wait for system-upgrade-controller to be available before applying plans.
      echo 'Waiting for the system-upgrade-controller deployment to become available...'
      kubectl -n system-upgrade wait --for=condition=available --timeout=360s deployment/system-upgrade-controller
      sleep 5
      #kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/${var.sys_upgrade_controller_version}/plans.yaml
      EOT
    ]
  }
}

# This resource uploads user-provided manifests and templates.
resource "null_resource" "kustomization_user" {
  depends_on = [null_resource.kustomization]
  for_each   = local.user_kustomization_templates

  triggers = {
    manifest_sha1 = sha1(templatefile("${var.extra_kustomize_folder}/${each.key}", var.extra_kustomize_parameters))
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_private_key
    port        = var.ssh_port
  }

  # Create the directory structure on the remote server.
  provisioner "remote-exec" {
    inline = [
      "mkdir -p $(dirname /var/user_kustomize/${each.key})"
    ]
  }

  # Render the template and upload it, removing the .tpl extension.
  provisioner "file" {
    content     = templatefile("${var.extra_kustomize_folder}/${each.key}", var.extra_kustomize_parameters)
    destination = replace("/var/user_kustomize/${each.key}", ".yaml.tpl", ".yaml")
  }
}

# This resource applies the user-provided kustomization and runs extra commands.
resource "null_resource" "kustomization_user_deploy" {
  depends_on = [null_resource.kustomization_user]
  count      = length(local.user_kustomization_templates) > 0 ? 1 : 0

  triggers = {
    # This ensures the resource is re-triggered when any of the user templates change.
    manifest_ids = join(",", [for r in null_resource.kustomization_user : r.id])
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = var.ssh_private_key
    port        = var.ssh_port
  }

  # Apply the user's kustomization and run any post-deployment commands.
  # provisioner "remote-exec" {
  #   inline = [
  #     <<-EOT
  #     # Exit immediately if a command exits with a non-zero status.
  #     set -e
  #
  #     # Define the directory for kustomization files.
  #     KUSTOMIZE_DIR="/var/user_kustomize"
  #
  #     # Check if a kustomization file already exists. Kustomize looks for either name.
  #     if [ ! -f "$KUSTOMIZE_DIR/kustomization.yaml" ] && [ ! -f "$KUSTOMIZE_DIR/Kustomization" ]; then
  #         echo "User kustomization file not found. Generating a default one."
  #
  #         # The command group's output is redirected to create the new kustomization file.
  #         {
  #             echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  #             echo "kind: Kustomization"
  #             echo "resources:"
  #             # Find all .yaml and .yml files to add as resources.
  #             # CRITICAL FIX: We must exclude the kustomization files themselves to avoid a self-reference error.
  #             find "$KUSTOMIZE_DIR" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) -not \( -name "kustomization.yaml" -o -name "Kustomization" \) -printf "  - %f\n"
  #         } > "$KUSTOMIZE_DIR/kustomization.yaml"
  #     fi
  #
  #     echo 'Applying user kustomization...'
  #     # Apply the kustomization. Quoting the variable is a best practice.
  #     kubectl apply -k "$KUSTOMIZE_DIR"
  #
  #     ${var.extra_kustomize_deployment_commands}
  #     EOT
  #   ]
  # }

  provisioner "remote-exec" {
    # Debugging: "sh -c 'for file in $(find /var/user_kustomize -type f -name \"*.yaml\" | sort -n); do echo \"\n### Template $${file}.tpl after rendering:\" && cat $${file}; done'",
    inline = compact([
      "rm -f /var/user_kustomize/**/*.yaml.tpl",
      "echo 'Applying user kustomization...'",
      "kubectl apply -k /var/user_kustomize/ --wait=true",
      var.extra_kustomize_deployment_commands
    ])
  }

  lifecycle {
    replace_triggered_by = [
      null_resource.kustomization_user
    ]
  }
}