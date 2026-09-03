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
#
# Both installed cluster nodes AND spare workers are emitted. The test suite
# treats this descriptor as the single source of truth for worker capacity
# (get_num_of_provisioned_workers counts role=="worker" entries), so the
# unconsumed available BMHs must appear here for the OCP-51155 scale-up guard
# to see capacity > running workers. No test power-targets a spare, but mapping
# them costs nothing and keeps count and power views consistent.
emit_vms_definitions() {
  compute_nodes
  compute_spares
  local i nodes="" comma=""
  _emit_node() {   # <name> <host> <ip> <mac> <role>
    nodes+="${comma}$(jq -n \
      --arg name "$1" --arg host "$2" \
      --arg domain "$1" --arg uuid "$(state_get "uuid_$1")" \
      --arg ip "$3" --arg mac "$4" --arg role "$5" \
      '{name:$name,host:$host,domain:$domain,uuid:$uuid,ip:$ip,mac:$mac,role:$role}')"
    comma=","
  }
  for i in "${!NODE_NAME[@]}"; do
    _emit_node "${NODE_NAME[$i]}" "${NODE_HOST[$i]}" "${NODE_IP[$i]}" "${NODE_MAC[$i]}" "${NODE_ROLE[$i]}"
  done
  for i in "${!SPARE_NAME[@]}"; do
    _emit_node "${SPARE_NAME[$i]}" "${SPARE_HOST[$i]}" "${SPARE_IP[$i]}" "${SPARE_MAC[$i]}" "${SPARE_ROLE[$i]}"
  done
  jq -n \
    --arg ip "$(state_get host_ip)" --arg user "$(state_get host_user)" \
    --arg key "$(state_get ssh_key_path)" --argjson nodes "[${nodes}]" \
    '{host:{ip:$ip,user:$user,ssh_key_path:$key},nodes:$nodes}'
}
