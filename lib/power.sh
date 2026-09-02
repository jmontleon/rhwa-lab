#!/usr/bin/env bash
# power.sh - out-of-band power control for lab nodes via ssh -> host -> virsh.
# This is the OOB channel that survives etcd quorum loss: even when the cluster
# API is down, virsh on the EC2 host can power any domain on/off. Tests reach it
# with the operator-configured SSH key (recorded in state; never a presumed
# default key name).

# node_power <on|off|reset> <node-host>
#   node-host is e.g. master-0 / worker-1; the libvirt domain is
#   ${CLUSTER_NAME}-<node-host>.
node_power() {
  [[ -n "${1:-}" && -n "${2:-}" ]] || die "node_power: usage: node_power <on|off|reset> <node>"
  local action="$1" host="$2" domain="${CLUSTER_NAME}-$2" verb
  case "$action" in
    on)    verb="start" ;;
    off)   verb="destroy" ;;
    reset) verb="reset" ;;
    *) die "node_power: unknown action '$action' (use on|off|reset)" ;;
  esac
  log "Power ${action} ${host} (virsh ${verb} ${domain})"
  ssh_host "sudo virsh ${verb} '${domain}'"
  ok "Power ${action} issued for ${host}"
}
