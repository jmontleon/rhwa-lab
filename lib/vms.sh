#!/usr/bin/env bash
# vms.sh - define libvirt domains for the OpenShift nodes and run sushy-tools
# (emulated Redfish BMC) in front of them.

# Define one libvirt domain (empty disk, UEFI, pinned MAC), NOT started.
#   $1=name  $2=ram_gb  $3=vcpu  $4=mac
_vm_define_domain() {
  local name="$1" ram_gb="$2" vcpu="$3" mac="$4" ram_mb=$(( $2 * 1024 ))
  ssh_host "sudo bash -s" <<EOS
set -e
if virsh dominfo '${name}' >/dev/null 2>&1; then
  echo "domain ${name} exists, skipping"
else
  qemu-img create -f qcow2 /var/lib/libvirt/images/${name}.qcow2 ${NODE_DISK_GB}G >/dev/null
  # Generate domain XML and define WITHOUT starting (--print-xml + virsh define).
  virt-install \
    --name '${name}' \
    --memory ${ram_mb} \
    --vcpus ${vcpu} \
    --cpu host-passthrough \
    --os-variant rhel9.4 \
    --disk path=/var/lib/libvirt/images/${name}.qcow2,bus=virtio \
    --disk path=/var/lib/libvirt/images/${CLUSTER_NAME}-agent.iso,device=cdrom \
    --network network=${LIBVIRT_NET},mac='${mac}',model=virtio \
    --boot uefi,hd,cdrom \
    --graphics none --noautoconsole --import --print-xml 1 > /tmp/${name}.xml
  virsh define /tmp/${name}.xml >/dev/null
fi
EOS
  # ITERATE: the cdrom target dev name (sda vs hda) and interface name
  # (enp1s0) inside RHCOS depend on machine type; verify on first boot.
}

# Record a domain's UUID into state (sushy uses it as the Redfish System id).
# Must use sudo: the domains live in qemu:///system (root); an unprivileged
# `virsh` would query the empty qemu:///session. Trailing `|| true` keeps a
# lookup failure from tripping set -e / pipefail.
_vm_record_uuid() {
  local name="$1" uuid
  uuid="$(ssh_host "sudo virsh domuuid '${name}'" 2>/dev/null | tr -d '\r' | head -1 || true)"
  [[ -n "$uuid" ]] || warn "could not read UUID for ${name} (fencing/BMC wiring will be incomplete)"
  state_set "uuid_${name}" "$uuid"
}

# Create all domains (cluster nodes + any spare workers), NOT started yet.
# Spares are defined and BMC-addressable but never booted here, so they take no
# part in the install; a post-install test powers/provisions them.
vms_define() {
  compute_nodes; compute_spares
  local total=$(( ${#NODE_NAME[@]} + ${#SPARE_NAME[@]} ))
  log "Defining ${total} libvirt domains (${#SPARE_NAME[@]} spare, not booted during install)"
  local i
  for i in "${!NODE_NAME[@]}"; do
    _vm_define_domain "${NODE_NAME[$i]}" "${NODE_RAM[$i]}" "${NODE_VCPU[$i]}" "${NODE_MAC[$i]}"
  done
  for i in "${!SPARE_NAME[@]}"; do
    _vm_define_domain "${SPARE_NAME[$i]}" "${SPARE_RAM[$i]}" "${SPARE_VCPU[$i]}" "${SPARE_MAC[$i]}"
  done
  ok "Domains defined"

  for i in "${!NODE_NAME[@]}";  do _vm_record_uuid "${NODE_NAME[$i]}";  done
  for i in "${!SPARE_NAME[@]}"; do _vm_record_uuid "${SPARE_NAME[$i]}"; done
}

# Boot all domains from the agent ISO (called after the ISO exists on host).
vms_boot() {
  compute_nodes
  log "Powering on all domains (boot from agent ISO)"
  local i name st
  for i in "${!NODE_NAME[@]}"; do
    name="${NODE_NAME[$i]}"
    st="$(ssh_host "sudo virsh domstate '${name}'" 2>/dev/null | tr -d '\r' | head -1 || true)"
    if [[ "$st" == "running" ]]; then
      log "${name} already running"
    elif ssh_host "sudo virsh start '${name}'" >/dev/null 2>&1; then
      log "${name} started"
    else
      warn "start ${name} failed"
    fi
  done
  ok "All domains powered on (installing from agent ISO)"
}

# Run sushy-tools as a podman container serving Redfish over TLS on SUSHY_PORT.
vms_sushy() {
  log "Starting sushy-tools (emulated Redfish BMC)"
  ssh_host 'sudo bash -s' <<EOS
set -euo pipefail
sudo mkdir -p /etc/rhwa-sushy
# Self-signed cert for the host bridge IP; fence_redfish uses --ssl-insecure.
if [[ ! -f /etc/rhwa-sushy/cert.pem ]]; then
  sudo openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/rhwa-sushy/key.pem -out /etc/rhwa-sushy/cert.pem \
    -days 3650 -subj "/CN=${NET_GATEWAY}" >/dev/null 2>&1
fi
# Basic-auth file so fence_redfish credentials are honored.
# sushy-tools ONLY accepts bcrypt-hashed entries (-B); the Apache-MD5 default
# makes the emulator refuse to start with "Only bcrypt digested passwords...".
sudo htpasswd -bcB /etc/rhwa-sushy/htpasswd '${SUSHY_USER}' '${SUSHY_PASS}' >/dev/null 2>&1
sudo tee /etc/rhwa-sushy/sushy-emulator.conf >/dev/null <<CONF
SUSHY_EMULATOR_LISTEN_IP = u'0.0.0.0'
SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_PORT}
SUSHY_EMULATOR_LIBVIRT_URI = u'qemu:///system'
# Keep boot-device overrides ignored: BMHs use the redfish-virtualmedia driver,
# and honoring a "boot from CD" override could divert a FAR-triggered reboot
# into the still-attached agent ISO instead of the installed disk. With this
# True, reboots always follow libvirt's uefi,hd,cdrom order (-> disk).
SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = True
# Don't verify TLS of remote image URLs on virtual-media insert (ironic serves
# images with a self-signed cert). Only exercised if a host is ever managed for
# provisioning; harmless otherwise.
SUSHY_EMULATOR_VMEDIA_VERIFY_SSL = False
SUSHY_EMULATOR_SSL_CERT = u'/etc/sushy/cert.pem'
SUSHY_EMULATOR_SSL_KEY = u'/etc/sushy/key.pem'
SUSHY_EMULATOR_AUTH_FILE = u'/etc/sushy/htpasswd'
CONF
sudo podman rm -f sushy >/dev/null 2>&1 || true
sudo podman run -d --name sushy --restart always \
  --net host --privileged \
  -v /var/run/libvirt:/var/run/libvirt \
  -v /etc/rhwa-sushy:/etc/sushy:ro \
  quay.io/metal3-io/sushy-tools:latest \
  sushy-emulator --config /etc/sushy/sushy-emulator.conf >/dev/null
echo "sushy started"
EOS
  # Verify it answers; a dead BMC layer means fencing (and the install's
  # power control) cannot work, so fail hard with the container logs.
  if retry 12 5 -- ssh_host "curl -sk -u '${SUSHY_USER}:${SUSHY_PASS}' https://${NET_GATEWAY}:${SUSHY_PORT}/redfish/v1/Systems >/dev/null"; then
    ok "sushy-tools serving Redfish at https://${NET_GATEWAY}:${SUSHY_PORT}"
  else
    warn "sushy-tools did not answer; last container logs:"
    ssh_host "sudo podman logs --tail 30 sushy 2>&1 || true" >&2 || true
    die "sushy-tools is not serving Redfish on ${NET_GATEWAY}:${SUSHY_PORT}."
  fi
}

vms_teardown() {
  compute_nodes; compute_spares
  ssh_host 'sudo podman rm -f sushy >/dev/null 2>&1 || true' || true
  local name
  for name in "${NODE_NAME[@]}" "${SPARE_NAME[@]}"; do
    ssh_host "sudo bash -c '
      virsh destroy \"${name}\" 2>/dev/null || true
      virsh undefine \"${name}\" --nvram --remove-all-storage 2>/dev/null || true'" || true
  done
}
