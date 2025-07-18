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
      local.cilium_values,
      local.cert_manager_values,
      local.external_dns_values,
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
    content = file("${path.module}/kustomize/system-upgrade-controller.yaml")
    destination = "/var/post_install/system-upgrade-controller.yaml"
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/kured.yaml.tpl", { options = local.kured_options })
    destination = "/var/post_install/kured.yaml"
  }

  provisioner "file" {
    count       = var.cni_plugin == "cilium" ? 1 : 0
    content = templatefile("${path.module}/templates/cilium.yaml.tpl", {
      values = local.cilium_values, version = var.cilium_version
    })
    destination = "/var/post_install/cilium.yaml"
  }

  provisioner "file" {
    count       = var.enable_cert_manager ? 1 : 0
    content = templatefile("${path.module}/templates/cert_manager.yaml.tpl", {
      version = var.cert_manager_version, values = local.cert_manager_values, bootstrap = false
    })
    destination = "/var/post_install/cert_manager.yaml"
  }

  provisioner "file" {
    count       = var.enable_external_dns ? 1 : 0
    content = templatefile("${path.module}/templates/external_dns.yaml.tpl", { values = local.external_dns_values })
    destination = "/var/post_install/external_dns.yaml"
  }

  # Apply all manifests using Kustomize.
  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -ex
      # Wait for the cluster to be ready before applying addons.
      timeout 180 bash <<'BASH_EOF'
        until [[ "$(kubectl get --raw='/readyz' 2> /dev/null)" == "ok" ]]; do
          echo "Waiting for the cluster to become ready for addons..."
          sleep 2
        done
      BASH_EOF

      # Apply the main kustomization file.
      kubectl apply -k /var/post_install

      # Wait for system-upgrade-controller to be available before applying plans.
      echo 'Waiting for the system-upgrade-controller deployment to become available...'
      kubectl -n system-upgrade wait --for=condition=available --timeout=360s deployment/system-upgrade-controller
      sleep 5
      kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/${var.sys_upgrade_controller_version}/plans.yaml
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
    inline = ["mkdir -p /var/user_kustomize/$(dirname ${each.key})"]
  }

  # Render the template and upload it, removing the .tpl extension.
  provisioner "file" {
    content     = templatefile("${var.extra_kustomize_folder}/${each.key}", var.extra_kustomize_parameters)
    destination = "/var/user_kustomize/${trimsuffix(each.key, ".tpl")}"
  }
}

# This resource uploads user-provided manifests and templates.
# main.tf

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
  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e
      KUSTOMIZE_DIR="/var/user_kustomize"
      if [ ! -f "$KUSTOMIZE_DIR/kustomization.yaml" ] && [ ! -f "$KUSTOMIZE_DIR/Kustomization" ]; then
        echo "User kustomization file not found. Generating a default one."
        {
          echo "apiVersion: kustomize.config.k8s.io/v1beta1"
          echo "kind: Kustomization"
          echo "resources:"
          find "$KUSTOMIZE_DIR" -maxdepth 1 -type f \\( -name "*.yaml" -o -name "*.yml" \\) -printf "  - %f\\n"
        } > "$KUSTOMIZE_DIR/kustomization.yaml"
      fi

      echo 'Applying user kustomization...'
      kubectl apply -k /var/user_kustomize/

      ${var.extra_kustomize_deployment_commands}
      EOT
    ]
  }
}