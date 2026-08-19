#!/usr/bin/env bash
# openshift.sh - render agent-based install configs, build the agent ISO on
# the host, and drive the install to completion. `oc`/`openshift-install`
# for the cluster run on the HOST (node IPs are only reachable there);
# a local `oc` is fetched too for the RHWA/test phases (via public API).

MIRROR="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}"

# Download openshift-install + oc onto the EC2 host.
os_host_tools() {
  log "Fetching openshift-install + oc (${OCP_VERSION}) on host"
  ssh_host 'bash -s' <<EOS
set -euo pipefail
mkdir -p ~/bin
cd ~/bin
curl -fsSL '${MIRROR}/openshift-install-linux.tar.gz' | tar xz openshift-install
curl -fsSL '${MIRROR}/openshift-client-linux.tar.gz'  | tar xz oc kubectl
./openshift-install version
EOS
  ok "Installer tools present on host"
}

# Fetch a local oc for RHWA/test phases (talks to the public API endpoint).
os_local_oc() {
  mkdir -p "$BIN_DIR"
  [[ -x "${BIN_DIR}/oc" ]] && return 0
  log "Fetching local oc (${OCP_VERSION})"
  curl -fsSL "${MIRROR}/openshift-client-linux.tar.gz" | tar xz -C "$BIN_DIR" oc kubectl
  ok "Local oc at ${BIN_DIR}/oc"
}

# Render install-config.yaml + agent-config.yaml locally, then scp to host.
os_render_configs() {
  compute_nodes
  local dir="${CLUSTER_DIR}/install"
  mkdir -p "$dir"
  local sshkey; sshkey="$(<"$SSH_PUBLIC_KEY_FILE")"

  cat > "${dir}/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: ${NET_CIDR}
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
compute:
- name: worker
  replicas: ${WORKER_COUNT}
controlPlane:
  name: master
  replicas: ${CONTROL_PLANE_COUNT}
platform:
  baremetal:
    apiVIPs:
    - ${API_VIP}
    ingressVIPs:
    - ${INGRESS_VIP}
pullSecret: '${PULL_SECRET}'
sshKey: '${sshkey}'
EOF

  # agent-config with per-node static networking (nmstate).
  {
    cat <<EOF
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${RENDEZVOUS_IP}
hosts:
EOF
    local i
    for i in "${!NODE_NAME[@]}"; do
      cat <<EOF
- hostname: ${NODE_HOST[$i]}
  role: ${NODE_ROLE[$i]}
  interfaces:
  - name: enp1s0
    macAddress: ${NODE_MAC[$i]}
  networkConfig:
    interfaces:
    - name: enp1s0
      type: ethernet
      state: up
      mac-address: ${NODE_MAC[$i]}
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: ${NODE_IP[$i]}
          prefix-length: 24
    dns-resolver:
      config:
        server:
        - ${NET_GATEWAY}
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: ${NET_GATEWAY}
        next-hop-interface: enp1s0
EOF
    done
  } > "${dir}/agent-config.yaml"
  ok "Rendered install-config.yaml + agent-config.yaml"
  # ITERATE: interface name enp1s0 assumed for q35+virtio; if RHCOS names it
  # differently, agent-config nmstate should match by mac-address identifier.
}

# Build the agent ISO on the host and stage it for libvirt.
os_build_image() {
  local dir="${CLUSTER_DIR}/install"
  log "Uploading configs and building agent ISO on host"
  ssh_host 'mkdir -p ~/oc-install/orig ~/oc-install/work'
  scp_to "${dir}/install-config.yaml" '~/oc-install/orig/install-config.yaml'
  scp_to "${dir}/agent-config.yaml"   '~/oc-install/orig/agent-config.yaml'
  ssh_host 'bash -s' <<EOS
set -euo pipefail
cd ~/oc-install
cp -f orig/install-config.yaml orig/agent-config.yaml work/
~/bin/openshift-install --dir work agent create image --log-level=info
sudo cp work/agent.x86_64.iso /var/lib/libvirt/images/${CLUSTER_NAME}-agent.iso
sudo chmod 644 /var/lib/libvirt/images/${CLUSTER_NAME}-agent.iso
echo "agent ISO staged"
EOS
  ok "Agent ISO built and staged"
}

# Wait for the install to finish (runs on host; it can reach node IPs + API).
os_wait_install() {
  log "Waiting for bootstrap-complete (this can take a while)..."
  ssh_host '~/bin/openshift-install --dir ~/oc-install/work agent wait-for bootstrap-complete --log-level=info' \
    || warn "bootstrap-complete reported an error; continuing to install-complete"
  log "Waiting for install-complete..."
  ssh_host '~/bin/openshift-install --dir ~/oc-install/work agent wait-for install-complete --log-level=info' \
    || die "install-complete failed; inspect ~/oc-install/work/.openshift_install.log on the host"

  # Retrieve credentials
  scp_from '~/oc-install/work/auth/kubeconfig' "$KUBECONFIG_LOCAL"
  scp_from '~/oc-install/work/auth/kubeadmin-password' "${CLUSTER_DIR}/kubeadmin-password"
  chmod 600 "$KUBECONFIG_LOCAL" "${CLUSTER_DIR}/kubeadmin-password"
  state_set cluster_installed yes
  ok "OpenShift install complete; kubeconfig at ${KUBECONFIG_LOCAL}"
}

# Convenience wrapper for local oc calls against the installed cluster.
oc() { KUBECONFIG="$KUBECONFIG_LOCAL" "${BIN_DIR}/oc" "$@"; }

os_wait_cluster_ready() {
  log "Waiting for cluster operators to stabilize"
  local i
  for ((i=0; i<60; i++)); do
    if oc get clusterversion version >/dev/null 2>&1 \
       && oc wait --for=condition=Available=True clusterversion/version --timeout=30s >/dev/null 2>&1; then
      ok "ClusterVersion Available"; return 0
    fi
    sleep 20
  done
  warn "Cluster did not report Available in time; check 'oc get co'."
}
