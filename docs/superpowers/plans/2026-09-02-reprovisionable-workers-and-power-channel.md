# Reprovisionable Workers + SSH Power Channel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rhwa-lab workers born metal3-managed (reprovisionable) at install time and expose an SSH→host→virsh power channel to tests, unblocking MDR, SNR scale (OCP-50780/OCP-51155), and quorum-loss (OCP-56071).

**Architecture:** ABI installs the 3 masters exactly as today. Workers are defined as libvirt domains with NO agent ISO, backed by provisionable BareMetalHosts (real BMC, `rootDeviceHints /dev/vda`), and provisioned post-install by a MachineSet via metal3 virtual-media against sushy-tools. Four permanent config fixes (pool named `default`, DHCP range, `IGNORE_BOOT_DEVICE=False`, `/dev/vda`) make virtual-media provisioning work. A `lib/power.sh` wraps `ssh_host sudo virsh` for out-of-band power that survives etcd quorum loss.

**Tech Stack:** Bash (dispatcher + sourced `lib/*.sh`), libvirt/virsh, sushy-tools (podman), metal3/ironic, OpenShift Agent-Based Installer, `oc`.

**Spec:** `docs/superpowers/specs/2026-09-02-reprovisionable-workers-and-power-channel.md`

## Global Constraints

- **Approach A1 only** (ABI masters + MachineSet-provisioned workers). Masters' install path is UNCHANGED.
- **Never presume the SSH key.** The key is `SSH_PUBLIC_KEY_FILE` (private = `PRIV_KEY=${SSH_PUBLIC_KEY_FILE%.pub}`, common.sh) and varies per user/env. No `id_rsa`/`id_ed25519`/any default may appear in power helpers or emitted test config. Resolve from state.
- **Never delete/clobber** `fenceagentsremediationtemplate-default` or `rhwa-nhc`.
- **Never reprovision a master.** Keep the guard that masters stay `externallyProvisioned` with BMC only.
- **Deprovision by Machine, never by MachineSet `scale`.** `oc -n openshift-machine-api delete machine <name>` or the `machine.openshift.io/cluster-api-delete-machine` annotation before scaling — a plain `scale --replicas=N` deletes an arbitrary worker.
- **sushy config values that must hold:** `SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False`; storage pool named `default` at `/var/lib/libvirt/images`; worker `rootDeviceHints.deviceName: /dev/vda`.
- **Commit trailer** on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Commit only; do NOT push unless the user asks.

## Test harness convention

The repo has no test framework and most logic emits shell/heredocs executed over SSH. Tests are bash scripts under `tests/` that **source a lib with `ssh_host`/`oc` stubbed to echo their stdin/args**, call the target function, and assert on the captured text. This exercises the real rendering logic without AWS. Integration tasks (8, 10) are verified live against a rebuilt cluster and are explicitly marked.

`tests/lib.sh` (created in Task 0) provides: `stub_ssh_host` (captures heredoc/body to `$STUB_OUT`), minimal state stubs, and `assert_contains`/`assert_not_contains`.

---

### Task 0: Test harness + state key for the SSH channel

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/state_channel_test.sh`
- Modify: `lib/common.sh` (add `state`-backed channel recording helper + export resolved values)

**Interfaces:**
- Produces: `record_ssh_channel()` — writes `host_ip`, `host_user`, `ssh_key_path` to state (via `state_set`), reading `HOST_SSH_USER` and `PRIV_KEY`. Consumed by Task 9 and the create flow.
- Produces (test lib): `stub_ssh_host`, `assert_contains "<haystack-file>" "<needle>"`, `assert_not_contains`, `STUB_OUT`.

- [ ] **Step 1: Write the failing test** — `tests/state_channel_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"

# Arrange: fake state + config. common.sh defines host_ip()=`state_get eip`, so
# seed eip in the fake state and define the state stubs AFTER sourcing common.sh
# (otherwise common.sh's host_ip would shadow a stub and record "").
export CLUSTER_NAME=t HOST_SSH_USER=fedora
export SSH_PUBLIC_KEY_FILE=/tmp/somekey.pub          # private => /tmp/somekey
source "${DIR}/../lib/common.sh" 2>/dev/null || true  # defines host_ip + record_ssh_channel
declare -A _STATE=([eip]=203.0.113.9)
state_set(){ _STATE["$1"]="$2"; }; state_get(){ echo "${_STATE[$1]:-}"; }
PRIV_KEY="${SSH_PUBLIC_KEY_FILE%.pub}"

record_ssh_channel

[[ "$(state_get host_ip)"      == "203.0.113.9" ]] || { echo "FAIL host_ip"; exit 1; }
[[ "$(state_get host_user)"    == "fedora"      ]] || { echo "FAIL host_user"; exit 1; }
[[ "$(state_get ssh_key_path)" == "/tmp/somekey" ]] || { echo "FAIL ssh_key_path (must not presume id_rsa)"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Write `tests/lib.sh`** (harness used by all render tests)

```bash
#!/usr/bin/env bash
# Shared test helpers: stub ssh_host/oc to capture what they'd send.
STUB_OUT="$(mktemp)"
stub_ssh_host() {
  # Captures a heredoc body (stdin) AND args into $STUB_OUT.
  ssh_host() { printf '%s\n' "$*" >>"$STUB_OUT"; cat >>"$STUB_OUT" 2>/dev/null || true; }
}
assert_contains()     { grep -qF -- "$2" "$1" || { echo "FAIL: expected to find: $2"; exit 1; }; }
assert_not_contains() { grep -qF -- "$2" "$1" && { echo "FAIL: should NOT find: $2"; exit 1; } || true; }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/state_channel_test.sh`
Expected: FAIL — `record_ssh_channel: command not found` (function not yet defined).

- [ ] **Step 4: Implement `record_ssh_channel` in `lib/common.sh`**

Add after the SSH helpers block (after `ssh_node`):

```bash
# Persist the values a test needs to reach the host's virsh/sushy out-of-band.
# The SSH key is whatever the operator configured (SSH_PUBLIC_KEY_FILE); never
# assume a default key name. Recorded so lib/power.sh and any exported test
# config look it up instead of guessing.
record_ssh_channel() {
  state_set host_ip      "$(host_ip)"
  state_set host_user    "${HOST_SSH_USER}"
  state_set ssh_key_path "${PRIV_KEY}"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/state_channel_test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add tests/lib.sh tests/state_channel_test.sh lib/common.sh
git commit -m "test+feat: record operator-chosen SSH channel (host ip/user/key) in state

SSH key path comes from SSH_PUBLIC_KEY_FILE, never a presumed default.
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 1: Deterministic libvirt storage pool named `default`

**Files:**
- Modify: `lib/host.sh` (add `host_storage_pool`, call from `host_provision`)
- Test: `tests/host_pool_test.sh`

**Interfaces:**
- Produces: `host_storage_pool()` — defines/starts/autostarts a dir pool named `default` at `/var/lib/libvirt/images`. Consumed by sushy `InsertMedia` (needs a pool named `default`).

- [ ] **Step 1: Write the failing test** — `tests/host_pool_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
stub_ssh_host
host_ip(){ echo x; }; log(){ :; }; ok(){ :; }; warn(){ :; }
source "${DIR}/../lib/host.sh"
host_storage_pool
assert_contains "$STUB_OUT" "pool-define-as default dir"
assert_contains "$STUB_OUT" "/var/lib/libvirt/images"
assert_contains "$STUB_OUT" "pool-autostart default"
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/host_pool_test.sh`
Expected: FAIL — `host_storage_pool: command not found`.

- [ ] **Step 3: Implement `host_storage_pool` in `lib/host.sh`**

Add above `host_provision`:

```bash
# Ensure a libvirt storage pool literally named 'default' exists. sushy-tools'
# InsertMedia stages virtual media into a pool named 'default'; if the only pool
# is named something else (e.g. the AMI's 'images'), InsertMedia 500s with
# "no storage pool with matching name 'default'". Idempotent.
host_storage_pool() {
  log "Ensuring libvirt storage pool 'default' (/var/lib/libvirt/images)"
  ssh_host "sudo bash -c '
    mkdir -p /var/lib/libvirt/images
    virsh pool-info default >/dev/null 2>&1 || virsh pool-define-as default dir --target /var/lib/libvirt/images
    virsh pool-autostart default 2>/dev/null || true
    virsh pool-start default 2>/dev/null || true
    virsh pool-refresh default 2>/dev/null || true'"
  ok "Storage pool 'default' ready"
}
```

- [ ] **Step 4: Call it from `host_provision`** (`lib/host.sh`)

```bash
host_provision() {
  host_install_packages
  host_storage_pool
  host_libvirt_network
  host_haproxy
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/host_pool_test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/host.sh tests/host_pool_test.sh
git commit -m "feat(host): define libvirt pool named 'default' for sushy InsertMedia

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: DHCP range + static MAC→IP reservations on the rhwa network

**Files:**
- Modify: `lib/host.sh` (`host_libvirt_network`)
- Test: `tests/host_network_test.sh`

**Interfaces:**
- Consumes: `compute_nodes`/`compute_spares` arrays (`NODE_MAC`/`NODE_IP`, `SPARE_MAC`/`SPARE_IP`) from common.sh.
- Produces: an `rhwa` network XML containing a `<dhcp>` block with a dynamic range AND one `<host mac=.. ip=..>` reservation per node+spare.

- [ ] **Step 1: Write the failing test** — `tests/host_network_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
stub_ssh_host
log(){ :; }; ok(){ :; }; warn(){ :; }
export CLUSTER_NAME=t NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       LIBVIRT_NET=rhwa CONTROL_PLANE_COUNT=3 WORKER_COUNT=3 SPARE_WORKER_COUNT=1 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/host.sh"
host_libvirt_network
assert_contains "$STUB_OUT" "<dhcp>"
assert_contains "$STUB_OUT" "range start='192.168.126.100'"
# master-0 reservation (52:54:00:6a:01:00 -> .11)
assert_contains "$STUB_OUT" "52:54:00:6a:01:00"
assert_contains "$STUB_OUT" "192.168.126.11"
# spare-0 reservation (idx=3 -> .24, mac ...:02:03)
assert_contains "$STUB_OUT" "52:54:00:6a:02:03"
assert_contains "$STUB_OUT" "192.168.126.24"
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/host_network_test.sh`
Expected: FAIL — no `<dhcp>` in the emitted XML.

- [ ] **Step 3: Implement in `lib/host.sh`** — replace the network XML render in `host_libvirt_network`

```bash
host_libvirt_network() {
  log "Defining libvirt network ${LIBVIRT_NET} (${NET_CIDR})"
  compute_nodes; compute_spares
  local net3="${NET_CIDR%.*}" reservations="" i
  for i in "${!NODE_MAC[@]}"; do
    reservations+="      <host mac='${NODE_MAC[$i]}' name='${NODE_HOST[$i]}' ip='${NODE_IP[$i]}'/>"$'\n'
  done
  for i in "${!SPARE_MAC[@]}"; do
    reservations+="      <host mac='${SPARE_MAC[$i]}' name='${SPARE_HOST[$i]}' ip='${SPARE_IP[$i]}'/>"$'\n'
  done
  ssh_host "cat > /tmp/${LIBVIRT_NET}.xml" <<EOX
<network>
  <name>${LIBVIRT_NET}</name>
  <forward mode='nat'/>
  <bridge name='virbr-rhwa' stp='on' delay='0'/>
  <ip address='${NET_GATEWAY}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${net3}.100' end='${net3}.199'/>
${reservations}    </dhcp>
  </ip>
</network>
EOX
  # DHCP range is required so a metal3-provisioned worker's generic IPA ramdisk
  # gets an address; static reservations pin each node/spare to its known IP so
  # DHCP and the masters' agent-config nmstate agree.
  ssh_host "sudo bash -c '
    virsh net-info ${LIBVIRT_NET} >/dev/null 2>&1 || virsh net-define /tmp/${LIBVIRT_NET}.xml
    virsh net-autostart ${LIBVIRT_NET} 2>/dev/null || true
    virsh net-start ${LIBVIRT_NET} 2>/dev/null || true'"
  ok "libvirt network ready (gateway/host bridge IP ${NET_GATEWAY}, DHCP + reservations)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/host_network_test.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/host.sh tests/host_network_test.sh
git commit -m "feat(host): add DHCP range + static reservations to rhwa network

Provisioned workers' IPA ramdisk needs DHCP; reservations keep pinned IPs.
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: sushy `IGNORE_BOOT_DEVICE = False`

**Files:**
- Modify: `lib/vms.sh` (`vms_sushy` config heredoc + comment)
- Test: `tests/sushy_config_test.sh`

**Interfaces:**
- Produces: sushy-emulator.conf containing `SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False`.

- [ ] **Step 1: Write the failing test** — `tests/sushy_config_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
stub_ssh_host
log(){ :; }; ok(){ :; }; warn(){ :; }; retry(){ return 0; }
export SUSHY_PORT=8000 SUSHY_USER=admin SUSHY_PASS=password NET_GATEWAY=192.168.126.1
source "${DIR}/../lib/vms.sh"
vms_sushy
assert_contains     "$STUB_OUT" "SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False"
assert_not_contains "$STUB_OUT" "SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = True"
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/sushy_config_test.sh`
Expected: FAIL — config still has `= True`.

- [ ] **Step 3: Implement in `lib/vms.sh`** — replace the boot-device block in `vms_sushy`'s heredoc

```bash
# Honor ironic's per-request boot-device override. Provisioning REQUIRES this:
# with it ignored, the deploy ramdisk's "boot from CD" is dropped, boot order
# collapses to floppy, and the root disk is never written. Existing nodes still
# boot disk-first (libvirt uefi,hd order) and fence_redfish sends ForceRestart
# with no boot override, so fencing returns to disk, not the (absent) media.
SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/sushy_config_test.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/vms.sh tests/sushy_config_test.sh
git commit -m "fix(sushy): honor boot-device override (IGNORE_BOOT_DEVICE=False)

Required for metal3 virtual-media provisioning; fencing unaffected.
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: No agent-ISO cdrom on managed workers

**Files:**
- Modify: `lib/vms.sh` (`_vm_define_domain` signature + domain XML; `vms_define` call sites)
- Test: `tests/vm_define_test.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `_vm_define_domain <name> <ram_gb> <vcpu> <mac> <role>` — role `master` attaches the agent ISO cdrom + `--boot uefi,hd,cdrom`; role `worker` attaches an EMPTY cdrom (for ironic to insert media) + `--boot uefi,hd,cdrom`. Empty cdrom = `--disk device=cdrom,bus=sata` (no source path).

- [ ] **Step 1: Write the failing test** — `tests/vm_define_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t NODE_DISK_GB=120
log(){ :; }; ok(){ :; }; warn(){ :; }

# master keeps the agent ISO
stub_ssh_host; : >"$STUB_OUT"
source "${DIR}/../lib/vms.sh"
_vm_define_domain t-master-0 20 8 52:54:00:6a:01:00 master
assert_contains "$STUB_OUT" "t-agent.iso,device=cdrom"

# worker gets an EMPTY cdrom, NOT the agent ISO
: >"$STUB_OUT"
_vm_define_domain t-worker-0 16 4 52:54:00:6a:02:00 worker
assert_not_contains "$STUB_OUT" "t-agent.iso"
assert_contains     "$STUB_OUT" "device=cdrom"
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/vm_define_test.sh`
Expected: FAIL — worker still gets `t-agent.iso`.

- [ ] **Step 3: Implement in `lib/vms.sh`** — replace `_vm_define_domain`

```bash
# Define one libvirt domain (empty root disk, UEFI, pinned MAC), NOT started.
#   $1=name  $2=ram_gb  $3=vcpu  $4=mac  $5=role (master|worker)
# masters boot the agent ISO (ABI); workers get an EMPTY cdrom so ironic can
# insert virtual media at provision time (no agent ISO welded on).
_vm_define_domain() {
  local name="$1" ram_gb="$2" vcpu="$3" mac="$4" role="$5" ram_mb=$(( $2 * 1024 ))
  local cdrom
  if [[ "$role" == "master" ]]; then
    cdrom="--disk path=/var/lib/libvirt/images/${CLUSTER_NAME}-agent.iso,device=cdrom"
  else
    cdrom="--disk device=cdrom,bus=sata"   # empty tray for ironic virtual-media
  fi
  ssh_host "sudo bash -s" <<EOS
set -e
if virsh dominfo '${name}' >/dev/null 2>&1; then
  echo "domain ${name} exists, skipping"
else
  qemu-img create -f qcow2 /var/lib/libvirt/images/${name}.qcow2 ${NODE_DISK_GB}G >/dev/null
  virt-install \
    --name '${name}' \
    --memory ${ram_mb} \
    --vcpus ${vcpu} \
    --cpu host-passthrough \
    --os-variant rhel9.4 \
    --disk path=/var/lib/libvirt/images/${name}.qcow2,bus=virtio \
    ${cdrom} \
    --network network=${LIBVIRT_NET},mac='${mac}',model=virtio \
    --boot uefi,hd,cdrom \
    --graphics none --noautoconsole --import --print-xml 1 > /tmp/${name}.xml
  virsh define /tmp/${name}.xml >/dev/null
fi
EOS
}
```

- [ ] **Step 4: Update call sites in `vms_define`** (`lib/vms.sh`) to pass the role

```bash
  for i in "${!NODE_NAME[@]}"; do
    _vm_define_domain "${NODE_NAME[$i]}" "${NODE_RAM[$i]}" "${NODE_VCPU[$i]}" "${NODE_MAC[$i]}" "${NODE_ROLE[$i]}"
  done
  for i in "${!SPARE_NAME[@]}"; do
    _vm_define_domain "${SPARE_NAME[$i]}" "${SPARE_RAM[$i]}" "${SPARE_VCPU[$i]}" "${SPARE_MAC[$i]}" "${SPARE_ROLE[$i]}"
  done
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/vm_define_test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/vms.sh tests/vm_define_test.sh
git commit -m "feat(vms): agent ISO on masters only; empty cdrom on workers

Workers are provisioned by metal3 virtual-media, not the welded agent ISO.
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: install-config workers=0; agent-config masters-only

**Files:**
- Modify: `lib/openshift.sh` (`_emit_install_config` compute replicas; `os_render_configs` agent-config host loop)
- Test: `tests/install_config_test.sh`

**Interfaces:**
- Consumes: `compute_nodes` arrays.
- Produces: install-config with `compute[worker].replicas: 0`; agent-config `hosts:` listing masters only (workers join later via MachineSet).

- [ ] **Step 1: Write the failing test** — `tests/install_config_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t BASE_DOMAIN=example.com OCP_VERSION=stable-4.22 \
       NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       API_VIP=192.168.126.5 INGRESS_VIP=192.168.126.6 \
       CONTROL_PLANE_COUNT=3 WORKER_COUNT=3 SPARE_WORKER_COUNT=1 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16 \
       SSH_PUBLIC_KEY_FILE=/nonexistent.pub
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/openshift.sh"
out="$(_emit_install_config '{"auths":{}}' 'ssh-ed25519 AAAA test')"
echo "$out" | grep -A2 '^compute:' | grep -q 'replicas: 0' || { echo "FAIL compute replicas"; exit 1; }
echo "$out" | grep -q 'replicas: 3' || { echo "FAIL controlPlane replicas"; exit 1; }  # masters unchanged
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/install_config_test.sh`
Expected: FAIL — compute replicas is `${WORKER_COUNT}` (3), not 0.

- [ ] **Step 3: Implement in `lib/openshift.sh`** — in `_emit_install_config`, change the compute block

```yaml
compute:
- name: worker
  replicas: 0
```

(Leave `controlPlane.replicas: ${CONTROL_PLANE_COUNT}` unchanged. Add an inline comment above `compute:` — `# Workers are provisioned post-install by a MachineSet via metal3 (Approach A1).`)

- [ ] **Step 4: Restrict agent-config hosts to masters** (`os_render_configs`, `lib/openshift.sh`)

Change the host loop so only masters are emitted into `agent-config.yaml`:

```bash
    for i in "${!NODE_NAME[@]}"; do
      [[ "${NODE_ROLE[$i]}" == "master" ]] || continue   # workers join via MachineSet, not ABI rendezvous
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
```

- [ ] **Step 5: Add an agent-config masters-only assertion to the test** — append to `tests/install_config_test.sh`

```bash
# Render agent-config via os_render_configs into a temp CLUSTER_DIR and assert masters-only.
export PULL_SECRET='{"auths":{}}'
tmp="$(mktemp -d)"; export STATE_DIR="$tmp" CLUSTER_DIR="$tmp/t"
scp_to(){ :; }   # not used here
os_render_configs
grep -q 'hostname: master-0' "$tmp/t/install/agent-config.yaml" || { echo "FAIL master missing"; exit 1; }
grep -q 'hostname: worker-'  "$tmp/t/install/agent-config.yaml" && { echo "FAIL worker present in agent-config"; exit 1; }
echo "PASS agent-config"
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/install_config_test.sh`
Expected: PASS (both `PASS` and `PASS agent-config`)

- [ ] **Step 7: Commit**

```bash
git add lib/openshift.sh tests/install_config_test.sh
git commit -m "feat(openshift): install masters via ABI, workers=0 (MachineSet later)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Provisionable worker BMHs (rootDeviceHints /dev/vda); retire paused-spare model

**Files:**
- Modify: `lib/rhwa.sh` (`rhwa_configure_bmh`; delete `rhwa_configure_spare_bmh` + its call in `rhwa_setup`)
- Test: `tests/bmh_test.sh`

**Interfaces:**
- Consumes: `compute_nodes` (`NODE_ROLE`, `NODE_MAC`, `NODE_HOST`), state `uuid_*`.
- Produces: for masters — BMH patched with BMC only (externallyProvisioned untouched); for workers — a **provisionable** BMH (BMC + `bootMACAddress` + `rootDeviceHints.deviceName: /dev/vda`, `online: true`, NOT externallyProvisioned) created if absent.

- [ ] **Step 1: Write the failing test** — `tests/bmh_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export CLUSTER_NAME=t NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       SUSHY_PORT=8000 SUSHY_USER=admin SUSHY_PASS=password \
       CONTROL_PLANE_COUNT=3 WORKER_COUNT=3 SPARE_WORKER_COUNT=1 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16
source "${DIR}/../lib/common.sh"
state_get(){ echo "uuid-$RANDOM"; }   # every node has a uuid
# Capture oc apply payloads + patch args.
OUT="$(mktemp)"
oc(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true;
      case "$*" in *"get baremetalhost worker-"*) return 1;; *"get baremetalhost master-"*) return 0;; esac; return 0; }
source "${DIR}/../lib/rhwa.sh"
rhwa_configure_bmh
# worker BMH created with vda hint and NOT externallyProvisioned
grep -q 'deviceName: /dev/vda' "$OUT" || { echo "FAIL vda hint"; exit 1; }
grep -q 'externallyProvisioned: true' "$OUT" && { echo "FAIL worker must not be externallyProvisioned"; exit 1; }
# spare worker gets a provisionable BMH too (available/unconsumed -> OCP-51155 scale-up)
grep -q 'name: worker-spare-0' "$OUT" || { echo "FAIL spare BMH not created"; exit 1; }
# spare function must be gone
declare -F rhwa_configure_spare_bmh && { echo "FAIL spare fn still defined"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/bmh_test.sh`
Expected: FAIL — no `/dev/vda` hint; `rhwa_configure_spare_bmh` still defined.

- [ ] **Step 3: Rewrite `rhwa_configure_bmh` in `lib/rhwa.sh`** — branch on role

Add a shared helper for provisionable worker BMHs (used by both cluster workers and spares — DRY), then branch on role. Masters get the existing patch-only path:

```bash
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
```

- [ ] **Step 4: Delete `rhwa_configure_spare_bmh` and drop its call** (`lib/rhwa.sh`)

Remove the entire `rhwa_configure_spare_bmh() { ... }` function (the paused/empty-disk model is disproven — spares are just extra `available` managed BMHs), and update `rhwa_setup`:

```bash
rhwa_setup() {
  rhwa_install_operators
  rhwa_configure_fencing
  rhwa_configure_bmh
}
```

> Note: `rhwa_configure_bmh` (Step 3) now also loops over `SPARE_*` (via `compute_spares`) and gives each spare an identical provisionable BMH via `_apply_worker_bmh`. Spares are left `available`/unconsumed (no Machine references them) so a scale-up test (OCP-51155) grows the MachineSet onto a spare with zero extra setup. `SPARE_WORKER_COUNT` still means "how many extra available BMHs beyond WORKER_COUNT."

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/bmh_test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/rhwa.sh tests/bmh_test.sh
git commit -m "feat(rhwa): provisionable worker BMHs (/dev/vda); retire paused-spare model

Masters stay BMC-only externally-provisioned; workers become metal3-managed.
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6b: Install the Machine Deletion Remediation (MDR) operator

**Files:**
- Modify: `lib/rhwa.sh` (`rhwa_install_operators` — add Subscription + CSV wait)
- Test: `tests/mdr_operator_test.sh`

**Interfaces:**
- Consumes: `RHWA_NAMESPACE`, `RHWA_CHANNEL` (common.sh).
- Produces: a `machine-deletion-remediation` Subscription in the existing RHWA namespace/OperatorGroup. Unblocks `test_mdr_cli.py` (tests supply their own MDRT/MDR/NHC CRs; only the operator was missing). MDR's functional reprovision path is delivered by Tasks 6+7.

- [ ] **Step 1: Write the failing test** — `tests/mdr_operator_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export RHWA_NAMESPACE=openshift-workload-availability RHWA_CHANNEL=stable
OUT="$(mktemp)"
oc(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true; }
_wait_csv(){ printf 'wait_csv %s\n' "$1" >>"$OUT"; }
_wait_snr_config(){ :; }
source "${DIR}/../lib/rhwa.sh"
rhwa_install_operators
assert_contains "$OUT" "name: machine-deletion-remediation"
assert_contains "$OUT" "wait_csv machine-deletion-remediation"
# existing operators still present (no regression)
assert_contains "$OUT" "name: node-healthcheck-operator"
assert_contains "$OUT" "name: self-node-remediation"
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/mdr_operator_test.sh`
Expected: FAIL — no `machine-deletion-remediation` Subscription emitted.

- [ ] **Step 3: Add the Subscription in `lib/rhwa.sh`** — inside `rhwa_install_operators`'s `oc apply -f -` heredoc, append after the `node-maintenance-operator` Subscription block

```yaml
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: machine-deletion-remediation
  namespace: ${RHWA_NAMESPACE}
spec:
  channel: ${RHWA_CHANNEL}
  name: machine-deletion-remediation
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

- [ ] **Step 4: Wait for its CSV** — add after the `node-maintenance-operator` wait line in `rhwa_install_operators`

```bash
  # MDR reprovisions unhealthy nodes via the Machine API; test_mdr_cli.py brings
  # its own MDRT/MDR/NHC CRs, so only the operator install is needed here.
  _wait_csv "machine-deletion-remediation" || true
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/mdr_operator_test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/rhwa.sh tests/mdr_operator_test.sh
git commit -m "feat(rhwa): install Machine Deletion Remediation operator

Unblocks test_mdr_cli.py; tests supply their own MDRT/MDR/NHC CRs.
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Provision workers post-install via MachineSet + wait Ready

**Files:**
- Modify: `lib/openshift.sh` (add `os_provision_workers`)
- Modify: `rhwa-lab` (`cmd_create` call order)
- Test: `tests/provision_workers_test.sh` (unit: scaling logic/args) + LIVE acceptance

**Interfaces:**
- Consumes: `WORKER_COUNT`, provisionable worker BMHs from Task 6, `oc()` wrapper.
- Produces: `os_provision_workers()` — discovers the baremetal MachineSet and scales it to `WORKER_COUNT`, then waits until `WORKER_COUNT` worker nodes are `Ready`. **Uses `oc scale` only to scale UP** (never for targeted removal).

- [ ] **Step 1: Write the failing test** — `tests/provision_workers_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "die: $*"; exit 3; }
export WORKER_COUNT=3
OUT="$(mktemp)"
# Stub oc: return a machineset name; record scale; report 3 ready workers.
oc(){ printf '%s\n' "$*" >>"$OUT"
  case "$*" in
    *"get machineset"*) echo "t-abc-worker-0";;
    *"get nodes"*)      printf 'worker-0 Ready\nworker-1 Ready\nworker-2 Ready\n';;
  esac; }
source "${DIR}/../lib/openshift.sh"
os_provision_workers
grep -q 'scale machineset t-abc-worker-0 --replicas=3' "$OUT" || { echo "FAIL scale args"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/provision_workers_test.sh`
Expected: FAIL — `os_provision_workers: command not found`.

- [ ] **Step 3: Implement `os_provision_workers` in `lib/openshift.sh`**

```bash
# Provision the metal3-managed workers post-install: scale the baremetal
# MachineSet up to WORKER_COUNT (consuming the provisionable worker BMHs) and
# wait for that many worker Nodes to be Ready. Scale is used ONLY to add
# workers; targeted removal in tests must delete a specific Machine instead.
os_provision_workers() {
  local mapi="openshift-machine-api" ms i ready
  ms="$(oc -n "$mapi" get machineset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$ms" ]] || die "no baremetal MachineSet found; cannot provision workers"
  log "Scaling MachineSet ${ms} to ${WORKER_COUNT} workers"
  oc -n "$mapi" scale machineset "$ms" --replicas="${WORKER_COUNT}"
  log "Waiting for ${WORKER_COUNT} worker nodes to reach Ready (metal3 provisioning)"
  for ((i=0; i<120; i++)); do
    ready="$(oc get nodes -l node-role.kubernetes.io/worker='' --no-headers 2>/dev/null \
             | awk '$2=="Ready"' | wc -l)"
    if (( ready >= WORKER_COUNT )); then ok "${ready} worker nodes Ready"; return 0; fi
    sleep 30
  done
  warn "workers did not all reach Ready; check 'oc get bmh -n ${mapi}' and metal3 logs"
  return 1
}
```

- [ ] **Step 4: Wire into `cmd_create`** (`rhwa-lab`) — after `rhwa_setup`, before `report`

```bash
  rhwa_setup
  os_provision_workers
  record_ssh_channel
```

(Place `record_ssh_channel` here so state has host_ip/user/key once the cluster exists.)

- [ ] **Step 5: Run unit test to verify it passes**

Run: `bash tests/provision_workers_test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/openshift.sh rhwa-lab tests/provision_workers_test.sh
git commit -m "feat(openshift): provision workers via MachineSet + wait Ready

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: SSH power channel — `lib/power.sh` + `rhwa-lab power`

**Files:**
- Create: `lib/power.sh`
- Modify: `rhwa-lab` (source it; add `power` subcommand + usage line)
- Test: `tests/power_test.sh`

**Interfaces:**
- Consumes: state `uuid_*` (node→domain map is by name; domain name == `${CLUSTER_NAME}-<host>`), `ssh_host`, resolved key from state (`record_ssh_channel`, Task 0).
- Produces: `node_power on|off|reset <node-host>` → `ssh_host "sudo virsh {start|destroy|reset} <domain>"`. `<node-host>` is e.g. `master-0`; domain is `${CLUSTER_NAME}-master-0`.

- [ ] **Step 1: Write the failing test** — `tests/power_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "die: $*"; exit 3; }
export CLUSTER_NAME=t
stub_ssh_host
source "${DIR}/../lib/power.sh"
node_power off master-0
assert_contains "$STUB_OUT" "virsh destroy t-master-0"
: >"$STUB_OUT"; node_power on master-0
assert_contains "$STUB_OUT" "virsh start t-master-0"
: >"$STUB_OUT"; node_power reset worker-1
assert_contains "$STUB_OUT" "virsh reset t-worker-1"
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/power_test.sh`
Expected: FAIL — `lib/power.sh` does not exist.

- [ ] **Step 3: Create `lib/power.sh`**

```bash
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
```

- [ ] **Step 4: Wire the subcommand into `rhwa-lab`**

Source it with the other libs:

```bash
source "${SELF_DIR}/lib/power.sh"
```

Add a dispatcher case and handler:

```bash
cmd_power() {
  state_init
  [[ -n "$(state_get eip)" ]] || die "No instance for '${CLUSTER_NAME}'; run create first."
  local action="${1:-}" node="${2:-}"
  [[ -n "$action" && -n "$node" ]] || die "usage: rhwa-lab power <on|off|reset> <node-host>"
  node_power "$action" "$node"
}
```

```bash
    power)   cmd_power "$@" ;;
```

Add a usage line in the header comment block (line ~13, before `destroy`):

```bash
#   ./rhwa-lab power <on|off|reset> <node>  Out-of-band power via ssh->virsh
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/power_test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/power.sh rhwa-lab tests/power_test.sh
git commit -m "feat(power): OOB node power via ssh->host->virsh (survives quorum loss)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Export the test-side SSH/vms definitions (ocp-edge consumption)

**Files:**
- Modify: `lib/power.sh` (add `emit_vms_definitions`)
- Modify: `rhwa-lab` (add `vms-definitions` subcommand + usage)
- Test: `tests/vms_definitions_test.sh`

**Interfaces:**
- Consumes: `compute_nodes`, state (`host_ip`/`host_user`/`ssh_key_path` from `record_ssh_channel`, `uuid_*`).
- Produces: `emit_vms_definitions()` → prints JSON to stdout: `{ "host": {ip,user,ssh_key_path}, "nodes": [ {name,host,domain,uuid,ip,mac,role} ... ] }`. The `ssh_key_path` is the recorded operator key — NOT a hardcoded default.

- [ ] **Step 1: Write the failing test** — `tests/vms_definitions_test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export CLUSTER_NAME=t NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       CONTROL_PLANE_COUNT=1 WORKER_COUNT=1 SPARE_WORKER_COUNT=0 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16
source "${DIR}/../lib/common.sh"
declare -A S=([host_ip]=203.0.113.9 [host_user]=fedora [ssh_key_path]=/tmp/opkey \
              [uuid_t-master-0]=uu-m [uuid_t-worker-0]=uu-w)
state_get(){ echo "${S[$1]:-}"; }
source "${DIR}/../lib/power.sh"
json="$(emit_vms_definitions)"
echo "$json" | jq -e '.host.ssh_key_path=="/tmp/opkey"' >/dev/null || { echo "FAIL key path (no presumed default)"; exit 1; }
echo "$json" | jq -e '.host.ip=="203.0.113.9"' >/dev/null || { echo "FAIL host ip"; exit 1; }
echo "$json" | jq -e '[.nodes[].domain]|index("t-master-0")' >/dev/null || { echo "FAIL domain"; exit 1; }
echo "$json" | jq -e '.nodes[]|select(.host=="worker-0").uuid=="uu-w"' >/dev/null || { echo "FAIL uuid"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/vms_definitions_test.sh`
Expected: FAIL — `emit_vms_definitions: command not found`.

- [ ] **Step 3: Implement `emit_vms_definitions` in `lib/power.sh`**

```bash
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
```

- [ ] **Step 4: Wire `vms-definitions` subcommand into `rhwa-lab`**

```bash
cmd_vms_definitions() { state_init; emit_vms_definitions; }
```

```bash
    vms-definitions) cmd_vms_definitions "$@" ;;
```

Usage line (header): `#   ./rhwa-lab vms-definitions   Print node->domain/host JSON for test power control`

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/vms_definitions_test.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/power.sh rhwa-lab tests/vms_definitions_test.sh
git commit -m "feat(power): emit vms-definitions JSON for ocp-edge power helpers

Key path is the operator-configured key from state, not a presumed default.
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: LIVE acceptance — full create, fencing re-validation, reprovision

**Files:**
- Modify: `README.md` (document `power` / `vms-definitions`, worker reprovisioning, the 4 config invariants)
- No new code; this task is the integration gate.

**Interfaces:** none (validation).

> This task requires AWS + a Red Hat pull secret and rebuilds the lab. It is the acceptance gate for the spec (§8). Run against an expendable cluster.

- [ ] **Step 1: Fresh create**

Run: `./rhwa-lab destroy && ./rhwa-lab create`
Expected: completes; `report` prints READY.

- [ ] **Step 2: Verify all workers are metal3-managed & Ready** (spec §8.1)

Run: `export KUBECONFIG=state/$CLUSTER_NAME/kubeconfig; bin/oc get nodes; bin/oc -n openshift-machine-api get bmh`
Expected: `WORKER_COUNT` workers `Ready`; every worker BMH `provisioned` with `EXTERNALLY PROVISIONED` empty/false; masters `externally provisioned`.

- [ ] **Step 3: Fencing re-validation** (spec §7 — mandatory gate)

Run: `./rhwa-lab test`
Expected: SUCCESS — target worker bootID changes and it rejoins `Ready` (confirms `IGNORE_BOOT_DEVICE=False` did not regress fencing).

- [ ] **Step 4: Reprovision (MDR/scale mechanism)** (spec §8.3)

Run (target a SPECIFIC worker's Machine — never `scale` for removal):
```bash
M=$(bin/oc -n openshift-machine-api get machine -o name | grep worker | head -1)
bin/oc -n openshift-machine-api delete "$M"
```
Expected: that BMH goes `deprovisioning`→cleaning (disk wiped)→`available`, then a replacement Machine reprovisions it back to `Ready`.

- [ ] **Step 5: OOB power over quorum-safe path** (spec §8.5)

Run: `./rhwa-lab power off worker-0 && sleep 10 && ./rhwa-lab power on worker-0`
Expected: `virsh` stops then starts the domain; node returns `Ready`. (Full quorum-loss drill is exercised by OCP-56071 on the test side.)

- [ ] **Step 5b: Verify the MDR operator is installed** (spec §8.6)

Run: `bin/oc -n openshift-workload-availability get csv | grep machine-deletion-remediation; bin/oc -n openshift-workload-availability get pod | grep machine-deletion-remediation-controller-manager`
Expected: CSV `Succeeded`; controller-manager pod `Running`. (Full MDR functional remediation is exercised by `test_mdr_cli.py` on the test side, reusing the reprovision mechanism from Step 4.)

- [ ] **Step 6: Verify vms-definitions uses the operator key**

Run: `./rhwa-lab vms-definitions | jq .host`
Expected: `ssh_key_path` equals the configured `${SSH_PUBLIC_KEY_FILE%.pub}` (NOT `id_rsa` unless that is what was configured).

- [ ] **Step 7: Update README + commit**

Document the `power` and `vms-definitions` subcommands, worker reprovisioning, and the four config invariants (pool `default`, DHCP, `IGNORE_BOOT_DEVICE=False`, `/dev/vda`).

```bash
git add README.md
git commit -m "docs: reprovisionable workers, OOB power channel, config invariants

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- §5.1 pool `default` → Task 1 ✓; DHCP + reservations → Task 2 ✓
- §5.2 no worker agent ISO → Task 4 ✓; `IGNORE_BOOT_DEVICE=False` → Task 3 ✓
- §5.3 install-config workers=0 + masters-only agent-config → Task 5 ✓
- §5.4a MDR operator install → Task 6b ✓
- §5.4 provisionable worker BMHs `/dev/vda` + retire spare model → Task 6 ✓
- §5.5 deprovision-by-Machine discipline → Global Constraints + Task 7 note + Task 10 Step 4 ✓
- §6 SSH power channel + key-from-state (never presumed) → Tasks 0, 8, 9 ✓
- §7 fencing re-validation → Task 10 Step 3 ✓
- §8 acceptance criteria → Task 10 Steps 2–6 ✓
- Worker provisioning at install time (A1) → Task 7 ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; all code steps carry real code. ✓

**Type/name consistency:** `record_ssh_channel` (Task 0) → used Task 7/9; `node_power <action> <host>` (Task 8) consistent with test; `emit_vms_definitions` (Task 9) matches subcommand; `os_provision_workers` (Task 7) matches call site; `_vm_define_domain` 5-arg signature (Task 4) matches `vms_define` call sites. State keys `host_ip`/`host_user`/`ssh_key_path`/`uuid_*` consistent across Tasks 0/8/9. ✓

**Note on test realism:** Render tests stub `ssh_host`/`oc` to capture emitted text; they validate the logic that builds configs/commands, not live libvirt/metal3. Behavior that only manifests on real hardware (actual provisioning, cleaning, fencing) is covered by the LIVE gate in Task 10.
