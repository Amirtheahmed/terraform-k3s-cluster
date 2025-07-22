# scripts/os_setup.sh.tpl

#!/bin/bash
set -ex

echo "--- Starting OS setup and optimization ---"

# Use transactional-update to apply all changes atomically.
# The system will be pristine until the next reboot.
transactional-update --continue shell <<'EOF'
set -ex

# 1. Install prerequisite packages
echo "Installing packages: ${needed_packages}"
# CORRECT: Use zypper directly inside the transactional-update shell
zypper -n in ${needed_packages}

# 2. Harden SSH configuration
echo "Hardening SSH..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/90-kh-custom.conf <<EOC
Port ${ssh_port}
PasswordAuthentication no
X11Forwarding no
MaxAuthTries ${ssh_max_auth_tries}
AllowTcpForwarding no
AllowAgentForwarding no
AuthorizedKeysFile .ssh/authorized_keys
EOC

# 3. Configure for Kured-based reboots
echo "Configuring for Kured..."
echo "REBOOT_METHOD=kured" > /etc/transactional-update.conf

# 4. Configure SELinux
%{~ if !disable_selinux ~}
echo "Configuring SELinux..."
cat > /root/k3s_custom_selinux.te <<'EOC'
${selinux_policy}
EOC
checkmodule -M -m -o /root/k3s_custom_selinux.mod /root/k3s_custom_selinux.te
semodule_package -o /root/k3s_custom_selinux.pp -m /root/k3s_custom_selinux.mod
semodule -i /root/k3s_custom_selinux.pp
setsebool -P virt_use_samba 1
setsebool -P domain_kernel_load_modules 1
%{~ else ~}
echo "Disabling SELinux as requested..."
sed -i -E 's/^SELINUX=[a-z]+/SELINUX=disabled/' /etc/selinux/config
setenforce 0
%{~ endif ~}

# 5. Optimize log and snapshot retention
echo "Optimizing log and snapshot retention..."
sed -i 's/#SystemMaxUse=/SystemMaxUse=2G/g' /etc/systemd/journald.conf
sed -i 's/#MaxRetentionSec=/MaxRetentionSec=2week/g' /etc/systemd/journald.conf
sed -i 's/NUMBER_LIMIT="[0-9-]*"/NUMBER_LIMIT="4"/g' /etc/snapper/configs/root
sed -i 's/NUMBER_LIMIT_IMPORTANT="[0-9-]*"/NUMBER_LIMIT_IMPORTANT="2"/g' /etc/snapper/configs/root

# 6. Disable rebootmgr service
echo "Disabling rebootmgr..."
systemctl disable --now rebootmgr.service

# 7. Create swap file if specified
%{~ if swap_size != "" ~}
echo "Creating ${swap_size} swap file..."
if [ ! -f /swapfile ]; then
  fallocate -l ${swap_size} /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi
%{~ endif ~}

EOF
# End of transactional-update block. The shell exits and stages the changes.

echo "--- OS setup staged. Rebooting to apply changes. ---"
reboot