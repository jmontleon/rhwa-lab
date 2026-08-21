#!/usr/bin/env bash
# host.sh - provision the EC2 host: KVM/libvirt, podman, haproxy, libvirt net.

host_install_packages() {
  log "Installing virtualization stack on host"
  # Fedora: all of these are in the default repos (unlike AL2023).
  ssh_host 'sudo bash -s' <<'EOS'
set -euo pipefail
sudo dnf -y install qemu-kvm libvirt virt-install libvirt-client \
     podman haproxy jq httpd-tools openssl bind-utils nmstate >/dev/null
sudo systemctl enable --now libvirtd
# Nested KVM sanity: /dev/kvm must exist (L0 passes VT-x when NestedVirtualization=enabled)
if [[ ! -e /dev/kvm ]]; then echo "ERROR: /dev/kvm missing - nested virt not active"; exit 1; fi
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
# SELinux: allow haproxy to reach arbitrary backends (VIPs) if enforcing
sudo setsebool -P haproxy_connect_any 1 2>/dev/null || true
echo "host packages OK"
EOS
  ok "Host virtualization stack installed"
}

host_libvirt_network() {
  log "Defining libvirt network ${LIBVIRT_NET} (${NET_CIDR})"
  local net3="${NET_CIDR%.*}"
  ssh_host "cat > /tmp/${LIBVIRT_NET}.xml" <<EOX
<network>
  <name>${LIBVIRT_NET}</name>
  <forward mode='nat'/>
  <bridge name='virbr-rhwa' stp='on' delay='0'/>
  <ip address='${NET_GATEWAY}' netmask='255.255.255.0'>
  </ip>
</network>
EOX
  # No DHCP range: nodes get static IPs from agent-config nmstate.
  ssh_host "sudo bash -c '
    virsh net-info ${LIBVIRT_NET} >/dev/null 2>&1 || virsh net-define /tmp/${LIBVIRT_NET}.xml
    virsh net-autostart ${LIBVIRT_NET} 2>/dev/null || true
    virsh net-start ${LIBVIRT_NET} 2>/dev/null || true'"
  ok "libvirt network ready (gateway/host bridge IP ${NET_GATEWAY})"
}

host_haproxy() {
  log "Configuring haproxy (EIP -> VIPs)"
  ssh_host "sudo tee /etc/haproxy/haproxy.cfg >/dev/null" <<EOC
global
    log /dev/log local0
    maxconn 4000
defaults
    mode tcp
    log global
    option tcplog
    timeout connect 10s
    timeout client 5m
    timeout server 5m
frontend api
    bind *:6443
    default_backend api
backend api
    server apivip ${API_VIP}:6443 check
frontend ingress_https
    bind *:443
    default_backend ingress_https
backend ingress_https
    server ingressvip ${INGRESS_VIP}:443 check
frontend ingress_http
    bind *:80
    default_backend ingress_http
backend ingress_http
    server ingressvip ${INGRESS_VIP}:80 check
EOC
  ssh_host "sudo systemctl enable --now haproxy && sudo systemctl restart haproxy"
  ok "haproxy forwarding 6443->${API_VIP}, 443/80->${INGRESS_VIP}"
}

host_provision() {
  host_install_packages
  host_libvirt_network
  host_haproxy
}
