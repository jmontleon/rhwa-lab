#!/usr/bin/env bash
# testfence.sh - induce an unhealthy worker and verify NHC -> FAR ->
# fence_redfish -> sushy-tools reboots it and it rejoins.

_node_bootid() { oc get node "$1" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null; }
_node_ready()  { oc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }

test_fence() {
  [[ "$(state_get cluster_installed)" == "yes" ]] || die "No installed cluster in state; run 'create' first."
  os_local_oc
  compute_nodes
  local target="${NODE_HOST[$CONTROL_PLANE_COUNT]}"   # first worker
  [[ -n "$target" ]] || die "No worker node to target."

  log "Fencing test target: ${target}"
  oc get node "$target" >/dev/null 2>&1 || die "Node ${target} not found."
  local boot0; boot0="$(_node_bootid "$target")"
  log "Current bootID: ${boot0:-unknown}"

  log "Inducing unhealth: stopping kubelet on ${target}"
  # oc debug pod dies as kubelet stops; ignore its exit status.
  oc debug "node/${target}" -- chroot /host bash -c 'systemctl stop kubelet' >/dev/null 2>&1 || true

  log "Waiting for ${target} to go NotReady..."
  local i
  for ((i=0; i<30; i++)); do
    [[ "$(_node_ready "$target")" != "True" ]] && { ok "${target} is NotReady"; break; }
    sleep 10
  done

  log "Waiting for NodeHealthCheck to create a FenceAgentsRemediation (unhealthy duration is 60s)..."
  local far=""
  for ((i=0; i<40; i++)); do
    far="$(oc get fenceagentsremediation.fence-agents-remediation.medik8s.io -A \
           -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
    [[ -n "$far" ]] && { ok "FenceAgentsRemediation created: ${far}"; break; }
    sleep 15
  done
  [[ -z "$far" ]] && warn "No FenceAgentsRemediation appeared; check NHC status and FAR operator logs."

  log "Waiting for ${target} to reboot (bootID change) and return Ready..."
  local boot1 recovered=no
  for ((i=0; i<40; i++)); do
    boot1="$(_node_bootid "$target")"
    if [[ -n "$boot1" && "$boot1" != "$boot0" && "$(_node_ready "$target")" == "True" ]]; then
      recovered=yes; break
    fi
    sleep 15
  done

  if [[ "$recovered" == "yes" ]]; then
    ok "SUCCESS: ${target} was fenced via fence_redfish and rejoined (bootID ${boot0} -> ${boot1})."
  else
    warn "Node did not confirm reboot+recovery in time. Diagnostics:"
    echo "--- FAR pods ---" >&2
    oc -n "$RHWA_NAMESPACE" get pods 2>/dev/null >&2 || true
    echo "--- FAR operator logs (tail) ---" >&2
    oc -n "$RHWA_NAMESPACE" logs deploy/fence-agents-remediation-controller-manager --tail=40 2>/dev/null >&2 || true
    echo "--- sushy-tools logs (tail) ---" >&2
    ssh_host 'sudo podman logs --tail 40 sushy' 2>/dev/null >&2 || true
    die "Fencing test did not complete successfully."
  fi
}
