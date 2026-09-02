# RHWA Lab: Reprovisionable Workers + SSH Power Channel — Design Spec

**Date:** 2026-09-02
**Status:** Draft for review
**Owner:** jmontleo
**Supersedes (in part):** `2026-08-19-rhwa-redfish-lab-design.md` — install method,
BMH handling, sushy config, and the network definition change here.

## 1. Purpose

The 2026-08-19 lab stands up RHWA + `fence_redfish` and proves single-node fencing.
But four RHWA test classes still cannot run on it, all for the same structural reason:
**the workers are `externallyProvisioned: true` (agent-ISO welded on as a cdrom), so
metal3/ironic only power-manages them and can never (re)provision one.** That blocks:

- **MDR (destructive)** — needs a node it can deprovision and redeploy in place.
- **SNR scale-down `OCP-50780`** — needs to remove a worker and get it back.
- **SNR scale-up `OCP-51155`** — needs to provision a new worker on demand.
- **Quorum-losing `OCP-56071`** — needs an out-of-band power-ON after the API dies.

This spec redesigns the lab so those tests run, via two independent changes:

1. **Born-managed, reprovisionable workers** — provision workers through
   metal3/ironic virtual-media at install time, not by patching a running cluster.
2. **An SSH → host → virsh/sushy power channel** exposed to the test suite, giving a
   real out-of-band power path that survives etcd quorum loss.

### Goals
- Workers are fully metal3-managed: metal3 can deprovision (clean) and redeploy any
  worker; a spare can be provisioned on demand.
- The test host can power any node on/off out-of-band even when the cluster API is down.
- Masters remain installed the way they are today (ABI). Only workers change.
- `create` still stands the whole thing up in one command; fencing still works.

### Non-goals
- No change to the AWS/host/DNS/haproxy layers, or to the RHWA OLM install.
- Not switching masters away from ABI.
- Not adding auto-TTL teardown or IPMI/cloud fence paths.

## 2. Validation already done (spike, 2026-09-02)

Proven on the expendable `jmontleo-rhwa-lab` cluster: an empty `spike-0` domain went
empty → inspected (`available`) → RHCOS written to `/dev/vda` → BMH `provisioned` →
node `Ready` as a 4th worker, via metal3 virtual-media against the sushy BMC.
Provisioning was blocked ONLY by four trivial, permanent config gaps (all fixed live):

| # | Gap | Fix |
|---|---|---|
| 1 | sushy `InsertMedia` stages media into a pool literally named `default`; host pool was `images` → HTTP 500 | Use ONE libvirt pool named `default` at `/var/lib/libvirt/images` |
| 2 | provisioned node boots generic IPA ramdisk needing DHCP; `rhwa` net had none | Add a DHCP range to the `rhwa` network |
| 3 | `SUSHY_EMULATOR_IGNORE_BOOT_DEVICE=True` drops ironic's boot override → boot collapses to `fd`, deploy ramdisk never boots, disk stays 1M | Set it to `False` (per-device `<boot order>` then honored: cdrom 1, disk 2) |
| 4 | metal3 defaults `rootDeviceHints` to `/dev/sda` (absent on virtio) | Set `rootDeviceHints.deviceName: /dev/vda` |

The SSH power channel was likewise verified: `ssh fedora@<eip>` reaches `sudo virsh`
and sushy at `192.168.126.1:8000` and the whole `192.168.126.0/24`.

This spec turns those four live hacks into permanent, install-time configuration, and
formalizes the SSH channel as a test-facing interface.

## 3. Key decisions (proposed)

| Decision | Choice | Rationale |
|---|---|---|
| Master install | Unchanged — **ABI** | Works today; masters are never (re)provisioned by tests |
| Worker install | **metal3-managed** (born reprovisionable) | The whole point; enables MDR/scale |
| sushy `IGNORE_BOOT_DEVICE` | **`False`** (was `True`) | Provisioning needs the boot override honored (spike gap #3) |
| Storage pool | Single pool named **`default`** | sushy requires it by name (gap #1) |
| Worker root disk hint | **`/dev/vda`** | virtio disk (gap #4) |
| Worker net | **DHCP range** added to `rhwa` net | IPA ramdisk needs DHCP (gap #2) |
| Power channel | **ssh → host → `virsh`** helper, exposed to tests | Survives quorum loss; direct host→BMC path unreachable from test host |

### Worker provisioning shape — DECIDED (2026-09-02): **A1** (§4)
ABI masters + MachineSet-provisioned workers. Approved by owner.

## 4. Worker provisioning approaches (pick one)

**A1 — ABI masters + metal3-provisioned workers (RECOMMENDED).**
Install-config declares `controlPlane.replicas: 3`, `compute[worker].replicas: 0`.
Masters install via the agent ISO as today. Workers are defined as BMHs with a real
BMC + `bootMACAddress` and **no agent ISO cdrom**, left `available`; a MachineSet
(replicas = WORKER_COUNT) then drives ironic to provision them from the machine-os
image. Result: every worker is metal3-managed and reprovisionable from day one.
- Pro: minimal deviation from today; masters path untouched; matches the proven spike
  exactly (spike-0 was provisioned this way).
- Con: workers join a few minutes after masters (MachineSet-driven), lengthening
  `create`'s wait.

**A2 — full IPI (`platform.baremetal.hosts[]`).**
Declare all hosts (masters + workers) in install-config; installer provisions
everything through metal3.
- Pro: everything born-managed by one installer flow.
- Con: larger rewrite of the install path (masters too), more moving parts to get
  right, and the spike did not exercise it. Higher risk for no extra test capability.

**B — ABI + empty-disk spare pool (REJECTED).**
Keep externallyProvisioned workers, add empty-disk spares that "provision via UEFI
fallthrough." The spike DISPROVED the premise: with `IGNORE_BOOT_DEVICE=False` (now
required) spares provision fine, and with `True` they don't — so there's no reason to
keep externallyProvisioned workers. B adds a parallel spare code path for no benefit.

**Recommendation: A1.** Lowest-risk change that delivers all four blocked classes.

## 5. rhwa-lab changes (Approach A1)

### 5.1 `lib/host.sh` — network + storage
- **Storage pool** named `default` at `/var/lib/libvirt/images` (define/start/autostart
  in `host_provision`). Today no pool is defined by the script; the AMI's `images` pool
  is what sushy trips over. Make the name deterministic.
- **`host_libvirt_network()`**: add a `<dhcp>` block to the `rhwa` net with (a) a
  dynamic range for the IPA ramdisk (e.g. `.100`–`.199`) and (b) **static
  MAC→IP reservations** for every node/spare (from `compute_nodes`/`compute_spares`) so
  provisioned workers keep their pinned IPs. Masters keep static nmstate via ABI;
  reservations make DHCP and nmstate agree.

### 5.2 `lib/vms.sh` — domains + sushy
- **No agent-ISO cdrom on managed workers.** `_vm_define_domain()` must attach the
  `agent.iso` cdrom + `--boot ...,cdrom` ONLY to masters (and the ABI rendezvous set).
  Managed workers get an empty root disk + an empty cdrom (for ironic to insert media)
  and UEFI boot with per-device order. Keep secure-boot as today.
- **`vms_sushy()`**: write `SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False`. Update the
  now-wrong comment block. Everything else (podman run, host net, privileged, libvirt
  socket mount) unchanged.

### 5.3 `lib/openshift.sh` — install-config
- `compute[worker].replicas: 0` (workers come from the MachineSet post-install), or add
  `platform.baremetal.hosts[]` if A2 is chosen instead. `controlPlane.replicas` and the
  master `agent-config.yaml` hosts stay as they are.
- `agent-config.yaml` `hosts:` lists masters only (workers are not part of the agent
  rendezvous under A1).

### 5.4a `lib/rhwa.sh` — install the MDR operator
Add a `machine-deletion-remediation` Subscription to `rhwa_install_operators` (same
`openshift-workload-availability` namespace + OperatorGroup, channel `stable`, source
`redhat-operators`, Automatic approval) and wait for its CSV. This is the ONLY lab-side
gap for the MDR test suite (`test_mdr_cli.py`): the tests bring their own
`MachineDeletionRemediationTemplate`/`MachineDeletionRemediation`/NHC CRs, so no template
wiring is needed. MDR's functional path (delete a worker's Machine → node reprovisioned
with a new creation timestamp) is delivered by the reprovisionable workers in §5.4/§4.
Verify the `machine-deletion-remediation-controller-manager` pod becomes Ready.

### 5.4 `lib/rhwa.sh` — BMH handling (the core change)
- **`rhwa_configure_bmh()`**: for workers, create **provisionable** BMHs — real BMC +
  `bootMACAddress` + `rootDeviceHints.deviceName: /dev/vda`, `online: true`,
  `externallyProvisioned` **false/absent**. Masters stay externally-provisioned + BMC
  (never reprovisioned; clearing it would wipe a running master — keep that guard).
- **Retire `rhwa_configure_spare_bmh()`'s paused/empty-disk model** (Approach B). Under
  A1 a "spare" is just an extra `available` managed BMH not yet consumed by a Machine;
  scale-up (`OCP-51155`) consumes it by scaling the MachineSet. Keep `SPARE_WORKER_COUNT`
  as "how many extra available BMHs to define beyond WORKER_COUNT."
- Preserve the standing guard: never delete/clobber
  `fenceagentsremediationtemplate-default` or `rhwa-nhc`.

### 5.5 Deprovision discipline (documented, used by tests)
Reclaiming a specific worker (MDR-in-place, scale-down) MUST target that worker's
**Machine** — `oc -n openshift-machine-api delete machine <name>` or annotate
`machine.openshift.io/cluster-api-delete-machine` before scaling. NEVER plain
`oc scale machineset --replicas=N`, which lets the controller delete an arbitrary worker.

## 6. SSH power channel (test-facing interface)

The lab already has `ssh_host` / `ssh_node` (common.sh) and knows `eip` + `PRIV_KEY`.
Formalize a small power API and a way to hand it to the ocp-edge test suite.

- **Lab side:** add `lib/power.sh` (or extend common.sh) with `node_power_on/off/reset
  <domain>` = `ssh_host "sudo virsh {start|destroy|reset} <domain>"`, resolving node
  name → libvirt domain via the state UUID map. A `./rhwa-lab power <on|off|reset>
  <node>` subcommand for manual use.
- **Test side (ocp-edge):** emit an SSH config + a small `vms_definitions.json`
  (node → domain/UUID, host IP, ssh user, key path) so the suite's `suspend_kvm` /
  `resume_kvm` helpers are revived as ssh→virsh calls. This un-blocks `OCP-56071`:
  after quorum loss, power masters back on through the host.
- **SSH key is user/env-chosen — never presumed.** The key is whatever
  `SSH_PUBLIC_KEY_FILE` was set to at provision time; the private key is
  `PRIV_KEY=${SSH_PUBLIC_KEY_FILE%.pub}` (common.sh). Do NOT hardcode `id_rsa`,
  `id_ed25519`, or any default anywhere in the power helpers or the emitted test
  config. Persist the resolved key path (and host user/IP) to state at create time so
  the power API and any exported `vms_definitions.json`/ssh-config look it up from state
  rather than guessing. A different operator or env may use a completely different key.
- **Secret handling:** the key material itself is never committed; only its path (as
  configured) is recorded. The sanitized `install-config` path is unchanged.

## 7. Fencing re-validation (must pass after the change)

`IGNORE_BOOT_DEVICE=False` is the one change that could regress fencing. Expected safe:
existing nodes boot `hd` first (order 1) and `fence_redfish` sends `ForceRestart` with
**no** boot-device override, so a fence reboot returns to disk, not media. Re-run
`./rhwa-lab test` (and the FAR CLI suite's fence path) after implementation to confirm
bootID changes and the node rejoins `Ready`. This is a required acceptance gate, not
optional.

## 8. Acceptance criteria

1. `./rhwa-lab create` yields 3 masters + WORKER_COUNT workers, **all workers BMH
   `provisioned` and metal3-managed** (not externallyProvisioned).
2. `./rhwa-lab test` still fences a worker successfully (bootID change + rejoin).
3. Deprovisioning a worker's Machine cleans its disk and the BMH returns to `available`;
   redeploy restores it to `Ready` (MDR / scale-down→up mechanism).
4. Scaling the MachineSet up consumes a spare `available` BMH → new `Ready` worker.
5. `./rhwa-lab power off <master>` then `power on` works with the API down (quorum path).
6. The `machine-deletion-remediation` CSV is `Succeeded` and its controller pod is Ready;
   `test_mdr_cli.py` functional remediation reprovisions a worker (new node timestamp).

## 9. Risks / open items

1. ~~A1 vs A2~~ — DECIDED: A1 (§4).
2. **Worker join latency in `create`** — MachineSet provisioning adds minutes; extend
   `os_wait_*`/add a `wait-for workers Ready` gate.
3. **DHCP vs static nmstate coexistence** — masters use ABI static nmstate; workers use
   DHCP reservations. Reservations must match `compute_nodes` IPs to avoid drift.
4. **Idempotency of the `default` pool rename** on existing hosts (the AMI ships
   `images`) — `create` should define `default` from scratch on a fresh host; the live
   rename done in the spike is a one-off, not part of the flow.
5. **Fencing regression from `IGNORE_BOOT_DEVICE=False`** — low risk, but §7 gate is
   mandatory.

## 10. Cross-references
- Live findings: memory `rhwa-lab-metal3-provisioning-proven`.
- Power channel: memory `lab-no-oob-power-channel` (updated 2026-09-02).
- Test-side work tracked under the FAR CLI modernization branch.
