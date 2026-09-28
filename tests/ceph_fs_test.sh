#!/usr/bin/env bash
# CephFS (filesystem / RWX) StorageClass, ON by default. When CEPH_FS_ENABLED is
# true the bootstrap creates a CephFS + MDS on the external Ceph and the exporter
# advertises it (--cephfs-filesystem-name); ODF then auto-creates the cephfs
# StorageClass. When CEPH_FS_ENABLED=false, NONE of that is emitted.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "DIE: $*"; exit 1; }
source "${DIR}/../lib/odf.sh"
state_get(){ echo ""; }; state_set(){ :; }; _ceph_wait_ssh(){ :; }

common_env() {
  export CEPH_ENABLED=true CEPH_RELEASE=squid CEPH_IMAGE=quay.io/ceph/ceph:v19 \
         CEPH_IP=192.168.126.10 CEPH_HOST=ceph-0 CEPH_SSH_USER=cloud-user \
         CEPH_OSD_COUNT=3 CEPH_POOL_REPLICA=3 CEPH_POOL_USABLE_GB=200 \
         CEPH_RBD_POOL=ocs-storagepool ODF_NAMESPACE=openshift-storage \
         CEPH_EXPORTER_URL=https://example.test/exporter.py
}

# ---- bootstrap: CephFS ENABLED ---------------------------------------------
common_env; export CEPH_FS_ENABLED=true CEPH_FS_NAME=ocs-storagefs
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
_ssh_ceph(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true; }
odf_ceph_bootstrap
# The RBD pool is still created (CephFS is additive, not a replacement).
assert_contains "$OUT" "osd pool create 'ocs-storagepool'"
# CephFS volume + single-daemon MDS placement.
assert_contains "$OUT" "ceph fs volume create 'ocs-storagefs' --placement='1'"
# Data pool gets the same replica policy as the RBD pool (resolved dynamically).
assert_contains "$OUT" "ceph fs ls -f json"
assert_contains "$OUT" 'osd pool set "${fsdata}" size 3'
assert_contains "$OUT" 'osd pool set "${fsdata}" min_size 2'
# Wait for an active MDS before the exporter runs.
assert_contains "$OUT" "ceph fs status 'ocs-storagefs'"

# ---- bootstrap: CephFS DISABLED (default) ----------------------------------
common_env; export CEPH_FS_ENABLED=false
: >"$OUT"
odf_ceph_bootstrap
assert_contains     "$OUT" "osd pool create 'ocs-storagepool'"   # RBD unchanged
assert_not_contains "$OUT" "fs volume create"                    # nothing CephFS
assert_not_contains "$OUT" "fs status"

# ---- exporter: CephFS ENABLED advertises the filesystem --------------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
export CLUSTER_DIR="$tmp" CEPH_FS_ENABLED=true CEPH_FS_NAME=ocs-storagefs
CAP="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
_ssh_ceph(){ cat >>"$CAP"; printf '%s' '[{"name":"rook-ceph-mon","kind":"Secret","data":{}}]'; }
odf_ceph_export
assert_contains "$CAP" "--rbd-data-pool-name 'ocs-storagepool'"
assert_contains "$CAP" "--cephfs-filesystem-name 'ocs-storagefs'"
# The exporter must still run as a single piped python3 invocation (not --mount).
assert_contains     "$CAP" 'shell -- python3 -'
assert_not_contains "$CAP" "--mount"

# ---- exporter: CephFS DISABLED omits the flag ------------------------------
export CEPH_FS_ENABLED=false CLUSTER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
: >"$CAP"
odf_ceph_export
assert_contains     "$CAP" "--rbd-data-pool-name 'ocs-storagepool'"
assert_not_contains "$CAP" "--cephfs-filesystem-name"

echo "PASS"
