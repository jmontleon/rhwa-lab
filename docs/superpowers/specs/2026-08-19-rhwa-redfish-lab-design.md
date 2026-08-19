# RHWA + fence_redfish Lab on AWS — Design Spec

**Date:** 2026-08-19
**Status:** Draft for review
**Owner:** jmontleo

## 1. Purpose

Provide a scripted, disposable lab for testing **Red Hat Workload
Availability (RHWA)** node remediation — specifically the **Fence Agents
Remediation (FAR)** operator driven by **NodeHealthCheck (NHC)** using the
**`fence_redfish`** fence agent — without any physical BMC hardware.

The lab runs a "bare metal" OpenShift cluster as libvirt VMs on a single
nested-virtualization-capable AWS `m8i` instance, with **sushy-tools**
providing an emulated Redfish BMC per VM. FAR's `fence_redfish` agent then
power-cycles nodes through those emulated BMCs exactly as it would against
real hardware.

### Goals
- One command to stand up the full environment end-to-end.
- One command to destroy everything cleanly (no orphaned AWS resources or
  public DNS records).
- A test command that demonstrably triggers and verifies a `fence_redfish`
  remediation.
- Cluster API/console reachable over the public internet via
  `*.migration.redhat.com` DNS.

### Non-goals
- Not production-grade; sushy-tools is explicitly dev/test only.
- Not testing IPMI (`fence_ipmilan`) or cloud (`fence_aws`) paths — Redfish
  only. (The structure would extend to those later.)
- No auto-TTL teardown; teardown is an explicit user action.

## 2. Key decisions (approved)

| Decision | Choice |
|---|---|
| Install method | **Agent-based Installer (ABI)**, `platform: baremetal` |
| Lifecycle | Explicit `create` / `destroy`; no forced TTL |
| Public access | **Open to the internet** (0.0.0.0/0 on 6443/443/80) |
| RHWA source | **Red Hat operator catalog** via OLM |
| Implementation | **Bash** (dispatcher + sourced modules); no Ansible |
| Configuration | **Environment variables only**; no committed config/secrets file |
| Default OCP version | `stable-4.22` |

### Note on "open to the internet"
The OpenShift console/API login will be reachable by anyone on a public
`redhat.com` name. `create` will surface the auto-generated `kubeadmin`
password prominently and recommend rotating/removing it after use. This is
the user's explicit choice.

## 3. Architecture

Single AWS `m8i` instance (nested virt enabled) hosts everything:

```
                 Internet
                    │  (api:6443, apps:443/80)
                    ▼
            Elastic IP  ──► EC2 m8i instance (L1 KVM host)
                    │        ├─ haproxy  (6443→API VIP, 443/80→Ingress VIP)
                    │        ├─ sushy-tools (podman) ── Redfish ──┐
                    │        └─ libvirt (qemu:///system)          │
                    ▼                                             ▼
   Route53: api.<cluster>.migration.redhat.com          6 libvirt domains (L2):
            *.apps.<cluster>.migration.redhat.com          cp-0..2, worker-0..2
                                                            (OpenShift nodes)
```

- **L0**: AWS Nitro passes Intel VT-x into the instance (`NestedVirtualization=enabled`).
- **L1**: the EC2 instance runs KVM/libvirt.
- **L2**: 6 libvirt VMs are the OpenShift "bare metal" nodes.
- FAR fences a node by calling `fence_redfish` against
  `https://<host>:<port>/redfish/v1/Systems/<vm-name>`; sushy-tools
  translates that to a libvirt `reset` on the matching domain.

### Fence data flow
```
NHC detects unhealthy Node
  → creates FenceAgentsRemediation CR (from template)
    → FAR pod runs: fence_redfish --ip <host> --plug <vm> --action reboot ...
      → sushy-tools → libvirt reset <domain>
        → VM reboots → kubelet rejoins → Node Ready
```

## 4. Components (bash modules)

```
rhwa-lab/
  rhwa-lab                 # entrypoint: create | test | destroy | status | help
  lib/
    common.sh              # logging, require_env, ssh helpers, ret/backoff
    state.sh               # read/write state/<cluster>.state (key=val)
    aws.sh                 # instance, EIP, SG, keypair, Route53 records, quota check
    host.sh                # remote provisioning of the EC2 host
    vms.sh                 # define libvirt domains + sushy-tools config
    openshift.sh           # render configs, build agent ISO, boot, wait
    rhwa.sh                # OLM subs + fence secrets + FAR/NHC CRs
    testfence.sh           # induce unhealthy node, verify remediation
  config/
    templates/
      install-config.yaml.tmpl
      agent-config.yaml.tmpl
      haproxy.cfg.tmpl
      sushy-emulator.conf.tmpl
      far-secret.yaml.tmpl
      far-template.yaml.tmpl
      nodehealthcheck.yaml.tmpl
      olm-subscription.yaml.tmpl
  state/                   # git-ignored; per-cluster state + rendered secrets (0600)
  .gitignore               # ignores state/
```

Templates are plain files with `${VAR}` placeholders rendered by
`envsubst` (or a small bash render helper) — no Jinja/Ansible.

## 5. Environment-variable contract

**Required** (`create` aborts, listing all missing at once; secret values
never echoed):
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (or `AWS_PROFILE`;
  `AWS_SESSION_TOKEN` honored)
- `AWS_REGION`
- `ROUTE53_ZONE_ID`
- `PULL_SECRET` (JSON string; `export PULL_SECRET="$(cat pull-secret.json)"`)

**Optional (defaults):**
- `CLUSTER_NAME=rhwa-lab`
- `BASE_DOMAIN=migration.redhat.com`
- `OCP_VERSION=stable-4.22`
- `INSTANCE_TYPE=m8i.12xlarge`
- `SSH_PUBLIC_KEY_FILE=~/.ssh/id_rsa.pub`
- `CONTROL_PLANE_COUNT=3`, `WORKER_COUNT=3`
- `EC2_VOLUME_SIZE_GB=1000`
- Per-node sizing: `CP_VCPU=8`, `CP_RAM_GB=20`, `WK_VCPU=4`, `WK_RAM_GB=16`

## 6. Lifecycle commands

### `rhwa-lab create`
1. **Preflight** — validate env vars; `aws sts get-caller-identity`; check
   EC2 On-Demand vCPU quota ≥ instance need; verify region offers the
   instance type; confirm Route53 zone exists.
2. **AWS host** (`aws.sh`) — create/reuse keypair + security group
   (22 from caller IP; 6443/443/80 from 0.0.0.0/0); launch `m8i` with
   `CpuOptions=NestedVirtualization=enabled` and a `${EC2_VOLUME_SIZE_GB}`
   gp3 root volume; allocate + associate an Elastic IP. Record all IDs to
   state.
3. **Host provisioning** (`host.sh`, over SSH) — install `@virtualization`
   / `libvirt` / `qemu-kvm` / `podman` / `haproxy` / `virt-install`;
   enable libvirtd; verify KVM acceleration (`kvm-ok`/`/dev/kvm`); create a
   libvirt network for the cluster.
4. **VMs + Redfish** (`vms.sh`) — define `${CONTROL_PLANE_COUNT}` +
   `${WORKER_COUNT}` domains (empty disks, UEFI, mac pinned); write
   sushy-tools config mapping domains → Redfish Systems; run sushy-tools as
   a podman container bound to `qemu:///system`; verify each System is
   queryable.
5. **DNS + haproxy** (`aws.sh` + `host.sh`) — pick API/Ingress VIPs on the
   libvirt network; render + start haproxy (6443→API VIP, 443/80→Ingress
   VIP); UPSERT Route53 A records `api.<cluster>` and `*.apps.<cluster>` →
   Elastic IP. Record record-ids/values to state for clean deletion.
6. **OpenShift** (`openshift.sh`) — download `openshift-install` +
   `oc` for `${OCP_VERSION}`; render `install-config.yaml` (baremetal
   platform, VIPs, pull secret, ssh key) and `agent-config.yaml` (per-node
   MACs/roles/rendezvous IP); `openshift-install agent create image`; attach
   ISO + power on all VMs via sushy-tools (Redfish `Boot` from CD, then set
   next boot disk); `openshift-install agent wait-for install-complete`.
7. **RHWA** (`rhwa.sh`) — see §7.
8. **Report** — print console URL, API URL, kubeconfig path, kubeadmin
   password, and the `test`/`destroy` hints.

### `rhwa-lab test`
See §8.

### `rhwa-lab destroy`
Consume state file and remove **in reverse order**: Route53 records → EIP
(disassociate + release) → EC2 instance → security group → keypair (if we
created it) → local cluster dir + state file. Idempotent: missing resources
are skipped with a warning, never a hard failure.

### `rhwa-lab status`
Print instance state, public IP, cluster endpoints, whether the API
answers, and a "running since" hint for cost awareness.

## 7. RHWA install & fence_redfish wiring (`rhwa.sh`)

1. Install operators via OLM from the **Red Hat catalog** (redhat-operators
   CatalogSource): create Namespace + OperatorGroup + Subscription for
   **Fence Agents Remediation** and **Node Health Check**; wait for CSVs to
   reach `Succeeded`.
2. For each cluster Node, create a fencing **Secret** holding the emulated
   BMC credentials (sushy-tools default creds, or configured ones).
3. Create a **`FenceAgentsRemediationTemplate`** (or per-node
   `FenceAgentsRemediation` config) with:
   - `agent: fence_redfish`
   - shared params: `--ssl-insecure` (self-signed emulator),
     `--systems-uri=/redfish/v1/Systems/<vm>`, `--ip=<host>`,
     `--ipport=<sushy-port>`, action `reboot`.
   - per-node override mapping each Node → its libvirt domain / System id.
4. Create a **`NodeHealthCheck`** CR selecting the worker nodes, with its
   `remediationTemplate` pointing at the FAR template.
5. Validate: operators healthy, template accepted, secrets present.

Node → domain → Redfish-System mapping is recorded in state so `rhwa.sh`
and `testfence.sh` agree on identifiers.

## 8. Fencing test procedure (`testfence.sh`)

1. Pick a target worker Node; record its libvirt domain.
2. Snapshot current state (Node `Ready`, VM running, boot generation).
3. Induce unhealth in a way NHC detects — default: stop the kubelet /
   sever the node so NHC's unhealthy conditions trip (exact method chosen
   during implementation and TDD; must be reversible and not rely on the
   remediation itself to recover state).
4. Observe: NHC creates a `FenceAgentsRemediation` CR → FAR pod runs
   `fence_redfish` → sushy-tools issues libvirt `reset` (verify VM reboot
   via libvirt event / uptime) → Node returns to `Ready`.
5. Assert success (Node Ready again, remediation CR completed) or fail with
   collected diagnostics (FAR pod logs, sushy-tools logs, `oc describe`
   of the CRs).

## 9. State management

`state/<cluster>.state` (git-ignored, `0600`) holds: instance-id,
eip-alloc-id, sg-id, keypair-name (+ whether we created it), route53
record identifiers, VIPs, libvirt domain↔node↔system map, cluster dir path.
Every `create` sub-step writes as it succeeds so a partial `create` is
still fully destroyable.

## 10. Cost & sizing

- `m8i.12xlarge` = 48 vCPU / 192 GB. Guest commit ~36 vCPU (oversubscription
  OK) / ~108 GB, leaving headroom for host + sushy-tools + haproxy.
- ~1 TB gp3 for 6 × ~120 GB qcow2 + agent ISO + RHCOS images.
- **~$2.30–2.70/hr on-demand while running** (verify per region); `destroy`
  stops billing. `status` surfaces uptime for cost awareness.

## 11. Risks / open items

1. **Nested-virt L2 performance** — AWS steers latency-sensitive work to
   bare metal. If installs are too slow/flaky on `m8i.12xlarge`, bump size
   or fall back to an `m8i.metal-*` instance (same script, different type).
2. **EC2 vCPU quota** — 48-vCPU launch may need a quota increase; preflight
   fails fast with guidance.
3. **Agent-ISO boot via Redfish** — need sushy-tools `vmedia`/`full`
   feature set and correct boot-order handling; a known integration point
   to validate early (spike-worthy).
4. **RHWA catalog entitlement** — pull secret must reach the Red Hat
   registry; otherwise fall back to upstream medik8s (deferred, not in
   scope now).
5. **NHC unhealthy-trigger method** — must be reliable and reversible;
   finalized during TDD.
6. **Region/instance availability** — m8i + nested virt not in every
   region; preflight validates.

## 12. Prerequisites (operator's machine)

`bash`, `aws` CLI v2, `jq`, `ssh`, and internet access. `oc` and
`openshift-install` are downloaded by the script. AWS account with rights
to manage EC2/EIP/Route53 and sufficient vCPU quota. A Red Hat pull secret
with catalog entitlement.
