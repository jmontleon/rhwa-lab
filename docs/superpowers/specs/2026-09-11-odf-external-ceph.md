# ODF (external mode) + single-VM Ceph — Design Spec

**Date:** 2026-09-11
**Status:** Draft for review
**Owner:** jmontleo

## 1. Purpose

Extend the RHWA lab with **OpenShift Data Foundation (ODF) in external mode**,
backed by a **single-node Ceph cluster** running on its own libvirt VM with 3
extra disks (one OSD each). The Ceph RBD data pool must provide **~200 GB of
usable storage** to the OpenShift cluster.

This gives the lab real dynamic block storage (RWO PVCs via the
`ocs-external-storagecluster-ceph-rbd` StorageClass) without adding storage
roles to the OpenShift nodes themselves — external mode keeps Ceph off-cluster,
exactly as a customer would run ODF against an existing Ceph.

### Goals
- One extra VM hosts a complete, self-contained Ceph cluster.
- The RBD pool consumed by ODF provides ≥ 200 GB usable.
- Wired into `create`/`destroy` with the same one-command lifecycle; toggleable.
- No change to the OpenShift install path or the RHWA/fencing behavior.

### Non-goals
- Not production-grade or HA — one host, one mon/mgr, replicas across OSDs.
- CephFS and RGW (object) are out of scope; RBD block only. The exporter and
  StorageCluster extend to them later.
- The Ceph VM is not an OpenShift node and is never fenced.

## 2. Key decisions

| Decision | Choice |
|---|---|
| ODF mode | **External** (`StorageCluster.spec.externalStorage.enable: true`) |
| Ceph deploy | **cephadm** `bootstrap --single-host-defaults` on one VM |
| Ceph host OS | CentOS-Stream 9 GenericCloud (stable image, first-class cephadm) |
| OSD layout | **One OSD per extra disk**, `CEPH_OSD_COUNT` disks (default 3) |
| Redundancy | Replicated pool, `size = CEPH_POOL_REPLICA` (default 3), failure domain **OSD** |
| Usable sizing | Disk size **derived** from the usable target (see §4) |
| Enablement | `ODF_ENABLED=true` by default; `false` skips everything |
| Import method | Reproduce the OCP console external-details import via `jq` + `oc apply` |

## 3. Architecture

The Ceph VM joins the existing `rhwa` libvirt network (only reachable from the
EC2 host), so all Ceph commands hop `ssh_host → ceph VM`.

```
   EC2 m8i host (L1 KVM)
     ├─ 3 masters + 3 workers (OpenShift "bare metal")  .11+/.21+
     ├─ ceph-0 VM  .10   ── 3x virtio OSD disks ── single-host Ceph (cephadm)
     │                        └─ RBD pool 'ocs-storagepool' (replica 3)
     └─ oc  ──►  ODF operator (openshift-storage)
                   └─ external StorageCluster ──(rook-ceph-* secrets)──► ceph-0
```

`fence_redfish` / metal3 never touch `ceph-0`: it has no BareMetalHost and is
absent from `compute_nodes` / `compute_spares`.

## 4. Sizing math (the "200 GB usable" requirement)

For a replicated pool, `usable ≈ raw / replica`. With `N` equal OSDs of size `S`
and replica `R`, the pool's `MAX AVAIL ≈ (N·S · full_ratio) / R`. Solving for `S`
against a usable target `U`, with headroom `h` for `full_ratio (~0.95)` +
BlueStore overhead:

```
S = U · R / N · h          (h = 1.18)
  = 200 · 3 / 3 · 1.18  ≈  236 GB per disk
  raw = N·S = 708 GB  →  MAX AVAIL ≈ 708·0.95/3 ≈ 224 GB usable  ✓ ≥ 200
```

`CEPH_OSD_DISK_GB` defaults to this derived value; `CEPH_OSD_COUNT`,
`CEPH_POOL_REPLICA`, and `CEPH_POOL_USABLE_GB` are the knobs. `--single-host-defaults`
sets the CRUSH failure domain to OSD so replica-3 fits on one host.

Because qcow2 OSD files are sparse, `EC2_VOLUME_SIZE_GB` is bumped by the raw OSD
footprint (`1000 + N·S`) so the host disk *can* hold a full pool without paying
for it up front.

## 5. Environment-variable contract (additions)

| Var | Default | Meaning |
|---|---|---|
| `ODF_ENABLED` | `true` | Master switch for the whole feature |
| `ODF_NAMESPACE` | `openshift-storage` | ODF operator + StorageCluster namespace |
| `ODF_CHANNEL` | derived from `OCP_VERSION` (`stable-4.NN`) | odf-operator catalog channel |
| `CEPH_ENABLED` | = `ODF_ENABLED` | Build the Ceph VM |
| `CEPH_RELEASE` | `squid` | ceph release train; drives the SIG package `centos-release-ceph-<release>` (installs cephadm) AND the container image, so cephadm and the running ceph match. Must be a version ODF's rook supports (reef, squid, …). Not the release-agnostic `umbrella` package (dev cephadm/image ODF can't parse) |
| `CEPH_IMAGE` | derived from `CEPH_RELEASE` (squid→`quay.io/ceph/ceph:v19`) | container image the cluster runs; override only for a mirror/air-gapped registry |
| `CEPH_CLOUD_IMAGE_URL` / `CEPH_SSH_USER` | CentOS-Stream 9 / `cloud-user` | Ceph VM OS |
| `CEPH_VCPU` / `CEPH_RAM_GB` / `CEPH_ROOT_DISK_GB` | `4` / `16` / `40` | Ceph VM sizing |
| `CEPH_OSD_COUNT` | `3` | Extra disks == OSDs |
| `CEPH_POOL_REPLICA` | `3` | Replicated pool size |
| `CEPH_POOL_USABLE_GB` | `200` | Usable target driving disk size |
| `CEPH_OSD_DISK_GB` | derived (≈236) | Per-OSD raw disk size |
| `CEPH_RBD_POOL` | `ocs-storagepool` | RBD data pool ODF consumes |

## 6. Lifecycle

`create` runs `odf_setup` after workers are provisioned (ODF pods and the
StorageCluster need schedulable workers):

1. `odf_ceph_define_vm` — cache the cloud image, create COW root + N blank OSD
   disks, `virt-install --cloud-init` (inject SSH key, install podman/python3/
   lvm2/chrony), start it.
2. `odf_ceph_bootstrap` — cephadm single-host bootstrap; add one OSD per disk;
   create + size the replicated RBD pool; enable the mgr prometheus module.
   Idempotent via a `ceph_bootstrapped` state marker (never re-bootstraps).
3. `odf_ceph_export` — run `ceph-external-cluster-details-exporter.py` on the VM;
   capture the connection JSON to `state/<cluster>/ceph-external.json` (0600).
4. `odf_install_operator` — Namespace + OperatorGroup + `odf-operator` Subscription.
5. `odf_import_external` — jq-map every `Secret`/`ConfigMap` element of the JSON
   into `openshift-storage` (the console's importer behavior).
6. `odf_create_storagecluster` — external-mode StorageCluster; wait for `Ready`.

`destroy` needs no new logic: terminating the instance removes the Ceph VM and
its disks; `vms_teardown` also lists the Ceph domain for completeness.

## 7. Risks / open items

1. **ODF channel** may lag OCP; derived `stable-4.NN` might not exist. Override.
2. **Exporter path/flags** vary by ceph/ODF version — `odf_ceph_export` probes a
   couple of paths + an upstream fallback; `odf_import_external`'s mapping mirrors
   the console and may need extending for newer ODF.
3. **Resource budget** — the Ceph VM adds ~4 vCPU / 16 GB; still within the
   `m8i.12xlarge` envelope (~40 vCPU / 124 GB committed).
4. **Nested-virt performance** — cephadm image pulls + OSD bring-up add minutes
   to `create`; not run end-to-end yet (consistent with the lab's status).
