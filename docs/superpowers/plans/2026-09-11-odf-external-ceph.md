# ODF (external) + single-VM Ceph — Implementation Plan

**Goal:** Enable ODF in external mode against a single-node Ceph cluster running
on its own libvirt VM with 3 extra disks, sized so the RBD pool provides ~200 GB
usable. One PR, no change to the OpenShift install or RHWA/fencing paths.

**Spec:** `docs/superpowers/specs/2026-09-11-odf-external-ceph.md`

**Tech stack:** Bash (`lib/*.sh`), libvirt/virt-install, cloud-init, cephadm,
OLM, `oc`. Same conventions as the rest of the lab.

## Global constraints

- **The Ceph VM is not an OpenShift node.** No BMH, no fencing, absent from
  `compute_nodes`/`compute_spares`. Role byte `03` in its MAC (`52:54:00:6a:03:00`)
  can never collide with masters (`01`) or workers (`02`); IP `.10`.
- **Never re-bootstrap a live Ceph** — guard with a `ceph_bootstrapped` state marker.
- **Usable = raw/replica.** Derive `CEPH_OSD_DISK_GB` from the usable target; do
  not hard-code disk size independent of replica/OSD count.
- **Never presume the SSH key** — inject `SSH_PUBLIC_KEY_FILE` via cloud-init;
  reach the VM as `CEPH_SSH_USER@CEPH_IP` through the host jump.
- **Toggleable** — `ODF_ENABLED=false` (and `CEPH_ENABLED=false`) make every
  entry point a no-op.
- **Commit trailer** on every commit:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Test harness

Same as the existing suite: stub `ssh_host`/`_ssh_ceph`/`oc` to capture heredocs
+ args, call the render function, assert on the captured text. No AWS/cluster.

## Tasks

- [x] **Task 1 — Config + topology** (`lib/common.sh`)
  - ODF/Ceph defaults; `ODF_CHANNEL` derived from `OCP_VERSION`.
  - `CEPH_OSD_DISK_GB` derived: `usable*replica/osd_count*1.18`.
  - `CEPH_*` node identity (`.10`, MAC role `03`); `EC2_VOLUME_SIZE_GB` bumped by
    the raw OSD footprint when ODF is enabled.

- [x] **Task 2 — Ceph VM** (`lib/odf.sh: odf_ceph_define_vm`, `lib/host.sh`)
  - COW root off a cached CentOS-Stream base + N blank virtio OSD disks;
    `virt-install --cloud-init` (SSH key + package user-data); start.
  - DHCP reservation for `ceph-0` in `host_libvirt_network`.
  - Test: `tests/ceph_vm_test.sh` (3 disks at derived size, backing file,
    cloud-init key/user-data, MAC/network, no agent ISO / redfish, disabled=no-op),
    `tests/host_network_test.sh` (reservation).

- [x] **Task 3 — Ceph bootstrap + pool** (`lib/odf.sh: odf_ceph_bootstrap`)
  - cephadm `--single-host-defaults`; one OSD per disk; replicated RBD pool at
    `size=replica`, `min_size 2`, `application enable rbd`, `rbd pool init`;
    enable mgr prometheus. Idempotent via `ceph_bootstrapped`.
  - Test: `tests/ceph_pool_test.sh`.

- [x] **Task 4 — External details export** (`lib/odf.sh: odf_ceph_export`)
  - Run `ceph-external-cluster-details-exporter.py` in a `cephadm shell`; capture
    JSON to `state/<cluster>/ceph-external.json` (0600); validate with jq.

- [x] **Task 5 — ODF operator** (`lib/odf.sh: odf_install_operator`)
  - Namespace (`cluster-monitoring` label) + OperatorGroup + `odf-operator`
    Subscription; wait for `odf-operator`/`ocs-operator` CSVs.
  - Test: `tests/odf_operator_test.sh`.

- [x] **Task 6 — Import + external StorageCluster** (`odf_import_external`,
  `odf_create_storagecluster`)
  - jq-map `Secret`/`ConfigMap` elements → objects in `openshift-storage`
    (console importer behavior); create external-mode StorageCluster; wait Ready.
  - Test: `tests/odf_external_test.sh`.

- [x] **Task 7 — Wire-up + teardown + docs**
  - `rhwa-lab`: source `lib/odf.sh`, call `odf_setup` after `os_provision_workers`,
    add an ODF line to `report`.
  - `vms_teardown` lists the Ceph domain.
  - `tests/odf_disabled_test.sh`; README section + rough edges #9–#11; this spec + plan.

## Verification

- [x] `bash -n` on every changed file.
- [x] All `tests/*_test.sh` pass (11 pre-existing + 5 new).
- [ ] **Live** (not yet run e2e, consistent with lab status): `create` on AWS,
      confirm `oc -n openshift-storage get storagecluster` is `Ready`, the
      `ocs-external-storagecluster-ceph-rbd` StorageClass exists, a PVC binds,
      and `ceph df` on `ceph-0` shows the pool `MAX AVAIL` ≥ 200 GB.
