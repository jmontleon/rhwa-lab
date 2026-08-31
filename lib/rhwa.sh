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

# Populate each node's BareMetalHost with its sushy-tools Redfish BMC address
# and credentials so metal3/ironic power-manages the node (and so test suites
# that expect .spec.bmc.address find it). The BMC address reuses the exact
# node -> libvirt-UUID map and sushy creds that FAR's fence_redfish uses.
#
# Address scheme is redfish-virtualmedia:// (metal3's virtual-media driver);
# the VMs are UEFI with a cdrom device, which that driver requires. Because the
# hosts stay externallyProvisioned (see below), ironic only power-manages them
# and never actually inserts media, and sushy is configured with
# SUSHY_EMULATOR_IGNORE_BOOT_DEVICE=True so a boot-device override can never
# divert a FAR-triggered reboot into the still-attached agent ISO.
#
# Agent-based installs create these BMHs as externally provisioned with no BMC.
# We add the BMC block but deliberately do NOT flip externallyProvisioned or
# touch bootMACAddress: clearing externallyProvisioned would make ironic try to
# (re)provision — i.e. wipe — the already-running node.
rhwa_configure_bmh() {
  compute_nodes
  local mapi="openshift-machine-api"
  log "Configuring BareMetalHost BMC address + credentials for each node"
  local i name uuid addr secret
  for i in "${!NODE_HOST[@]}"; do
    name="${NODE_HOST[$i]}"
    uuid="$(state_get "uuid_${NODE_NAME[$i]}")"
    if [[ -z "$uuid" ]]; then
      warn "no libvirt UUID for ${name}; skipping BMH BMC config"
      continue
    fi
    addr="redfish-virtualmedia://${NET_GATEWAY}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"
    secret="${name}-bmc-secret"

    # Per-node BMC credentials Secret (metal3 reads keys 'username'/'password').
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

    if oc -n "$mapi" get baremetalhost "$name" >/dev/null 2>&1; then
      # Existing (installer-created) BMH: add only the BMC block + online; leave
      # externallyProvisioned / bootMACAddress untouched (see note above). sushy
      # serves a self-signed cert, so disable verification.
      oc -n "$mapi" patch baremetalhost "$name" --type merge -p \
        "{\"spec\":{\"online\":true,\"bmc\":{\"address\":\"${addr}\",\"credentialsName\":\"${secret}\",\"disableCertificateVerification\":true}}}"
      ok "BMH ${name}: BMC set -> ${addr}"
    else
      # No installer BMH (unexpected on baremetal ABI): create a power-only,
      # externally provisioned host so ironic manages power without provisioning.
      warn "BareMetalHost ${name} not found; creating an externally-provisioned one"
      oc apply -f - <<EOF
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${name}
  namespace: ${mapi}
spec:
  online: true
  externallyProvisioned: true
  bootMACAddress: ${NODE_MAC[$i]}
  bmc:
    address: ${addr}
    credentialsName: ${secret}
    disableCertificateVerification: true
EOF
      ok "BMH ${name}: created with BMC ${addr}"
    fi
  done
}

rhwa_setup() {
  rhwa_install_operators
  rhwa_configure_fencing
  rhwa_configure_bmh
}
