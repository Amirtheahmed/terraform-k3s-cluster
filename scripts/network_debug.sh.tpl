#!/bin/bash
# K3s Network Debugging Script for MicroOS/Netcup Setup
# This script performs comprehensive network diagnostics

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Start debugging
echo -e "${BLUE}K3s Network Debugging Script - Starting diagnostics...${NC}"
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo "Server IP: ${SERVER_IP:-152.53.141.98}"
echo ""

# 1. System Information
print_header "System Information"
echo "OS Release:"
cat /etc/os-release | grep -E "^(NAME|VERSION)" || true
echo ""
echo "Kernel:"
uname -r
echo ""
echo "SELinux Status:"
getenforce 2>/dev/null || echo "SELinux not available"

# 2. Network Interfaces
print_header "Network Interfaces"
echo "All interfaces:"
ip -br addr show
echo ""
echo "Interface details for ens3:"
ip addr show ens3 2>/dev/null || print_warning "Interface ens3 not found"
echo ""
echo "Routes:"
ip route show
echo ""
echo "Default route:"
ip route show default

# 3. DNS Configuration
print_header "DNS Configuration"
echo "System DNS (resolv.conf):"
cat /etc/resolv.conf
echo ""
echo "SystemD resolved status:"
systemctl status systemd-resolved --no-pager 2>/dev/null || echo "systemd-resolved not running"
echo ""
echo "Testing DNS resolution:"
for domain in "google.com" "github.com" "helm.sh" "charts.jetstack.io"; do
    if host $domain >/dev/null 2>&1; then
        print_success "DNS resolution for $domain works"
    else
        print_error "DNS resolution for $domain failed"
    fi
done

# 4. K3s Status
print_header "K3s Status"
echo "K3s service status:"
systemctl status k3s --no-pager | head -20
echo ""
echo "K3s version:"
k3s --version 2>/dev/null || kubectl version --short
echo ""
echo "Node status:"
kubectl get nodes -o wide

# 5. Pod Network Status
print_header "Pod Network Status"
echo "All pods status:"
kubectl get pods -A | grep -v "Running\|Completed" || print_success "All pods appear to be running"
echo ""
echo "CoreDNS pods:"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
echo ""
echo "Flannel pods:"
kubectl get pods -n kube-system -l app=flannel -o wide 2>/dev/null || echo "No flannel pods found"

# 6. Network Policies
print_header "Network Policies"
echo "Checking for network policies:"
kubectl get networkpolicies -A

# 7. Firewall Status
print_header "Firewall Status"
echo "Firewalld status:"
systemctl status firewalld --no-pager 2>/dev/null | head -10 || echo "firewalld not active"
echo ""
echo "Iptables rules (filter table):"
iptables -L -n -v | head -50
echo ""
echo "Iptables NAT rules:"
iptables -t nat -L -n -v | head -50

# 8. MTU Configuration
print_header "MTU Configuration"
echo "Interface MTUs:"
ip link show | grep -E "^[0-9]+:|mtu"
echo ""
echo "Flannel configuration:"
kubectl get configmap -n kube-system kube-flannel-cfg -o yaml 2>/dev/null | grep -A5 -B5 "mtu\|MTU" || echo "Flannel config not found"

# 9. Test Pod Connectivity
print_header "Test Pod Connectivity"
echo "Creating test pod for network diagnostics..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: network-debug
  namespace: default
spec:
  containers:
  - name: debug
    image: nicolaka/netshoot:latest
    command: ['sh', '-c', 'sleep 3600']
  restartPolicy: Never
EOF

echo "Waiting for test pod to be ready..."
kubectl wait --for=condition=Ready pod/network-debug -n default --timeout=60s 2>/dev/null || print_warning "Test pod not ready"

# 10. Pod-level Network Tests
print_header "Pod-level Network Tests"
echo "Testing DNS from within pod:"
kubectl exec -n default network-debug -- nslookup google.com 2>/dev/null || print_error "Pod DNS test failed"
echo ""
echo "Testing external connectivity from pod:"
kubectl exec -n default network-debug -- ping -c 3 8.8.8.8 2>/dev/null || print_error "Pod cannot reach 8.8.8.8"
echo ""
echo "Testing HTTPS connectivity to helm repos:"
for url in "https://charts.jetstack.io" "https://helm.cilium.io" "https://charts.bitnami.com"; do
    echo "Testing $url:"
    kubectl exec -n default network-debug -- curl -I --connect-timeout 5 $url 2>/dev/null | head -3 || print_error "Cannot reach $url"
    echo ""
done

# 11. CoreDNS Logs
print_header "CoreDNS Logs (last 50 lines)"
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50 2>/dev/null || echo "Cannot fetch CoreDNS logs"

# 12. K3s Agent Logs
print_header "K3s Logs (last 100 lines)"
journalctl -u k3s --no-pager -n 100 | grep -E "(error|Error|ERROR|warn|Warn|WARN|fail|Fail|FAIL)" || echo "No errors found in recent logs"

# 13. Specific Netcup/MicroOS Checks
print_header "Netcup/MicroOS Specific Checks"
echo "Checking for common Netcup network issues:"
echo ""
echo "IPv6 status:"
ip -6 addr show
echo ""
echo "Checking for duplicate default routes:"
ip route show default | wc -l
echo ""
echo "Checking conntrack modules:"
lsmod | grep -E "nf_conntrack|br_netfilter" || print_warning "Important kernel modules might be missing"
echo ""
echo "Sysctl network settings:"
sysctl net.ipv4.ip_forward
sysctl net.bridge.bridge-nf-call-iptables 2>/dev/null || echo "bridge-nf-call-iptables not set"
sysctl net.bridge.bridge-nf-call-ip6tables 2>/dev/null || echo "bridge-nf-call-ip6tables not set"

# 14. Flannel Specific Checks
print_header "Flannel Specific Checks"
echo "Flannel interface:"
ip addr show flannel.1 2>/dev/null || print_warning "flannel.1 interface not found"
echo ""
echo "Checking for Flannel subnet lease:"
cat /run/flannel/subnet.env 2>/dev/null || echo "Flannel subnet file not found"
echo ""
echo "CNI configuration:"
ls -la /etc/cni/net.d/ 2>/dev/null || echo "CNI config directory not found"
cat /etc/cni/net.d/10-flannel.conflist 2>/dev/null | head -20 || echo "Flannel CNI config not found"

# 15. External DNS Check
print_header "External Services Configuration"
echo "Checking external-dns configuration:"
kubectl get deployment -n external-dns external-dns -o wide 2>/dev/null || echo "external-dns not found"
echo ""
echo "Checking if Cloudflare tunnel is affecting connectivity:"
kubectl get pods -n traefik -l app=cloudflared -o wide 2>/dev/null || echo "Cloudflared not found"

# 16. Cleanup
print_header "Cleanup"
echo "Removing test pod..."
kubectl delete pod network-debug -n default --force --grace-period=0 2>/dev/null || true

# Summary
print_header "Debugging Summary"
echo "Common issues to check based on the diagnostics:"
echo ""
echo "1. DNS Issues:"
echo "   - Check if CoreDNS pods are running"
echo "   - Verify /etc/resolv.conf in pods points to cluster DNS"
echo "   - Check if firewall is blocking DNS (port 53)"
echo ""
echo "2. MTU Issues:"
echo "   - Netcup might require MTU less than 1500"
echo "   - Try setting Flannel MTU to 1450 or 1400"
echo ""
echo "3. Firewall/iptables:"
echo "   - Ensure firewalld is not blocking pod traffic"
echo "   - Check if MicroOS transactional updates changed firewall rules"
echo ""
echo "4. Missing kernel modules:"
echo "   - br_netfilter and ip_conntrack modules must be loaded"
echo "   - Check if SELinux is blocking network operations"
echo ""
echo "5. Flannel configuration:"
echo "   - Ensure Flannel is using the correct interface (ens3)"
echo "   - Check if Flannel subnet allocation is working"

print_header "Script Complete"