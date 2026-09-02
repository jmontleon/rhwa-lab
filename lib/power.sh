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

# Emit a JSON descriptor tests use to reach nodes' power OOB. The SSH key path
# is the operator-configured key recorded in state — never a presumed default.
emit_vms_definitions() {
  compute_nodes
  local i nodes="" comma=""
  for i in "${!NODE_NAME[@]}"; do
    nodes+="${comma}$(jq -n \
      --arg name "${NODE_NAME[$i]}" --arg host "${NODE_HOST[$i]}" \
      --arg domain "${NODE_NAME[$i]}" --arg uuid "$(state_get "uuid_${NODE_NAME[$i]}")" \
      --arg ip "${NODE_IP[$i]}" --arg mac "${NODE_MAC[$i]}" --arg role "${NODE_ROLE[$i]}" \
      '{name:$name,host:$host,domain:$domain,uuid:$uuid,ip:$ip,mac:$mac,role:$role}')"
    comma=","
  done
  jq -n \
    --arg ip "$(state_get host_ip)" --arg user "$(state_get host_user)" \
    --arg key "$(state_get ssh_key_path)" --argjson nodes "[${nodes}]" \
    '{host:{ip:$ip,user:$user,ssh_key_path:$key},nodes:$nodes}'
}
