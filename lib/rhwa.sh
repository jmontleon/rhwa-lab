#!/usr/bin/env bash
# rhwa.sh - install RHWA operators (Fence Agents Remediation + Node Health
# Check) from the Red Hat catalog via OLM, then wire fence_redfish against
# the sushy-tools emulated BMCs.

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
spec:
  targetNamespaces:
  - ${RHWA_NAMESPACE}
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
EOF
  # Non-fatal: warn and continue so `test` can surface any real problem.
  _wait_csv "node-healthcheck-operator" || true
  _wait_csv "fence-agents-remediation" || true
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
        "--ssl-insecure": ""
      nodeparameters:
$(_far_nodeparams)
EOF
  # ITERATE: valueless flags (--ssl-insecure) and exact param names for
  # fence_redfish may need tuning; check the FAR pod logs on first test.

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
    duration: 300s
  - type: Ready
    status: Unknown
    duration: 300s
EOF
  ok "RHWA fencing configured (fence_redfish -> https://${NET_GATEWAY}:${SUSHY_PORT})"
}

rhwa_setup() {
  rhwa_install_operators
  rhwa_configure_fencing
}
