#!/usr/bin/env bash
# rhwa.sh - install RHWA operators (Node Health Check, Fence Agents
# Remediation, Self Node Remediation, Node Maintenance) from the Red Hat
# catalog via OLM, then wire fence_redfish against the sushy-tools emulated
# BMCs.

# Wait for a CSV whose name starts with <prefix> to reach Succeeded.
_wait_csv() {
  local prefix="$1" i phase
  for ((i=0; i<60; i++)); do
    phase="$(oc -n "$RHWA_NAMESPACE" get csv -o json 2>/dev/null \
      | jq -r --arg p "$prefix" '.items[] | select(.metadata.name|startswith($p)) | .status.phase' \
      | head -1)"
    [[ "$phase" == "Succeeded" ]] && { ok "CSV ${prefix}* Succeeded"; return 0; }
    sleep 15
  done
  warn "CSV ${prefix}* did not reach Succeeded (last: ${phase:-none})"
  return 1
}

rhwa_install_operators() {
  log "Installing RHWA operators from Red Hat catalog"
  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RHWA_NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhwa-operatorgroup
  namespace: ${RHWA_NAMESPACE}
# Empty spec = AllNamespaces install mode. NHC and FAR are AllNamespaces-only
# operators; a targetNamespaces (OwnNamespace/SingleNamespace) OperatorGroup
# makes OLM reject their CSVs with "UnsupportedOperatorGroup / OwnNamespace
# InstallModeType not supported".
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: node-healthcheck-operator
  namespace: ${RHWA_NAMESPACE}
spec:
  channel: ${RHWA_CHANNEL}
  name: node-healthcheck-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: fence-agents-remediation
  namespace: ${RHWA_NAMESPACE}
spec:
  channel: ${RHWA_CHANNEL}
  name: fence-agents-remediation
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: self-node-remediation
  namespace: ${RHWA_NAMESPACE}
spec:
  channel: ${RHWA_CHANNEL}
  name: self-node-remediation
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: node-maintenance-operator
  namespace: ${RHWA_NAMESPACE}
spec:
  channel: ${RHWA_CHANNEL}
  name: node-maintenance-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
  # Non-fatal: warn and continue so `test` can surface any real problem.
  _wait_csv "node-healthcheck-operator" || true
  _wait_csv "fence-agents-remediation" || true
  _wait_csv "self-node-remediation" || true
  # NMO has no singleton config/DaemonSet; it just watches NodeMaintenance CRs.
  _wait_csv "node-maintenance-operator" || true
  # SNR auto-creates a default SelfNodeRemediationConfig on startup; confirm it
  # appears so consumers (and SNR test suites) find it configured.
  _wait_snr_config || true
}

# Wait for SNR's default SelfNodeRemediationConfig CR to be created by the
# operator (it manages this singleton itself; we don't create it).
_wait_snr_config() {
  local i
  for ((i=0; i<40; i++)); do
    if oc -n "$RHWA_NAMESPACE" get selfnoderemediationconfig self-node-remediation-config \
         >/dev/null 2>&1; then
      ok "SelfNodeRemediationConfig 'self-node-remediation-config' exists"
      return 0
    fi
    sleep 15
  done
  warn "SelfNodeRemediationConfig did not appear; check the self-node-remediation operator."
  return 1
}

# Build the per-node "--systems-uri" nodeparameters block (Node name -> URI).
_far_nodeparams() {
  compute_nodes
  local i uuid
  echo "        \"--systems-uri\":"
  for i in "${!NODE_NAME[@]}"; do
    uuid="$(state_get "uuid_${NODE_NAME[$i]}")"
    # Key is the Kubernetes Node name (= hostname we assigned).
    echo "          \"${NODE_HOST[$i]}\": \"/redfish/v1/Systems/${uuid}\""
  done
}

rhwa_configure_fencing() {
  log "Creating FenceAgentsRemediationTemplate (fence_redfish) + NodeHealthCheck"
  oc apply -f - <<EOF
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  name: fenceagentsremediationtemplate-default
  namespace: ${RHWA_NAMESPACE}
spec:
  template:
    spec:
      agent: fence_redfish
      remediationStrategy: ResourceDeletion
      sharedparameters:
        "--ip": "${NET_GATEWAY}"
        "--ipport": "${SUSHY_PORT}"
        "--username": "${SUSHY_USER}"
        "--password": "${SUSHY_PASS}"
        "--ssl-insecure": "1"
      nodeparameters:
$(_far_nodeparams)
EOF

  oc apply -f - <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: rhwa-nhc
spec:
  minHealthy: "51%"
  selector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
    - key: node-role.kubernetes.io/control-plane
      operator: DoesNotExist
  remediationTemplate:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    name: fenceagentsremediationtemplate-default
    namespace: ${RHWA_NAMESPACE}
  unhealthyConditions:
  - type: Ready
    status: "False"
    duration: 60s
  - type: Ready
    status: Unknown
    duration: 60s
EOF
  ok "RHWA fencing configured (fence_redfish -> https://${NET_GATEWAY}:${SUSHY_PORT})"
}

# Emit a provisionable worker BMH (+ its BMC secret). Shared by cluster workers
# and spares: NOT externallyProvisioned; rootDeviceHints pins the virtio root
# disk (/dev/vda — metal3 defaults to /dev/sda, which is absent on virtio).
_apply_worker_bmh() {
  local name="$1" mac="$2" uuid="$3" mapi="openshift-machine-api"
  local addr="redfish-virtualmedia://${NET_GATEWAY}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"
  local secret="${name}-bmc-secret"
  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret}
  namespace: ${mapi}
type: Opaque
stringData:
  username: "${SUSHY_USER}"
  password: "${SUSHY_PASS}"
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${name}
  namespace: ${mapi}
spec:
  online: true
  bootMACAddress: ${mac}
  rootDeviceHints:
    deviceName: /dev/vda
  bmc:
    address: ${addr}
    credentialsName: ${secret}
    disableCertificateVerification: true
EOF
  ok "BMH ${name} (worker): provisionable -> ${addr}"
}

rhwa_configure_bmh() {
  compute_nodes; compute_spares
  local mapi="openshift-machine-api"
  log "Configuring BareMetalHost BMC (+ provisionable workers/spares)"
  local i name role uuid addr secret
  for i in "${!NODE_HOST[@]}"; do
    name="${NODE_HOST[$i]}"; role="${NODE_ROLE[$i]}"
    uuid="$(state_get "uuid_${NODE_NAME[$i]}")"
    if [[ -z "$uuid" ]]; then warn "no libvirt UUID for ${name}; skipping"; continue; fi
    if [[ "$role" == "master" ]]; then
      addr="redfish-virtualmedia://${NET_GATEWAY}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"
      secret="${name}-bmc-secret"
      oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret}
  namespace: ${mapi}
type: Opaque
stringData:
  username: "${SUSHY_USER}"
  password: "${SUSHY_PASS}"
EOF
      # Masters install via ABI and must NEVER be reprovisioned: add BMC only,
      # leave externallyProvisioned / bootMACAddress untouched.
      oc -n "$mapi" patch baremetalhost "$name" --type merge -p \
        "{\"spec\":{\"online\":true,\"bmc\":{\"address\":\"${addr}\",\"credentialsName\":\"${secret}\",\"disableCertificateVerification\":true}}}"
      ok "BMH ${name} (master): BMC set -> ${addr}"
    else
      _apply_worker_bmh "$name" "${NODE_MAC[$i]}" "$uuid"
    fi
  done
  # Spare workers: provisionable BMHs left available (unconsumed) so a scale-up
  # test (OCP-51155) can grow the MachineSet onto them.
  for i in "${!SPARE_HOST[@]}"; do
    uuid="$(state_get "uuid_${SPARE_NAME[$i]}")"
    if [[ -z "$uuid" ]]; then warn "no libvirt UUID for spare ${SPARE_HOST[$i]}; skipping"; continue; fi
    _apply_worker_bmh "${SPARE_HOST[$i]}" "${SPARE_MAC[$i]}" "$uuid"
  done
}


rhwa_setup() {
  rhwa_install_operators
  rhwa_configure_fencing
  rhwa_configure_bmh
}
