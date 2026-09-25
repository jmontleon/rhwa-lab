#!/usr/bin/env bash
# Node domains: masters keep the agent ISO, workers get an empty cdrom, and each
# node's ROOT is its own dedicated NODE_DISK_GB volume discovered by size and
# passed raw (distinct disk per node index) -- with a qcow2 fallback when
# NODE_ATTACH_EBS=false.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t NODE_DISK_GB=120 LIBVIRT_NET=rhwa NODE_ATTACH_EBS=true
log(){ :; }; ok(){ :; }; warn(){ :; }
source "${DIR}/../lib/vms.sh"

# master (node index 0) keeps the agent ISO; root is a raw dedicated disk by size
stub_ssh_host; : >"$STUB_OUT"
_vm_define_domain t-master-0 20 8 52:54:00:6a:01:00 master 0
assert_contains "$STUB_OUT" "t-agent.iso,device=cdrom"
assert_contains "$STUB_OUT" "lsblk -dbn -o NAME,TYPE,SIZE"                          # size-based disk id
assert_contains "$STUB_OUT" "120 * 1024 * 1024 * 1024"                             # NODE_DISK_GB filter
assert_contains "$STUB_OUT" "device=disk,bus=virtio,cache=none,io=native,format=raw"  # raw passthrough
assert_contains "$STUB_OUT" '$(( 0 + 1 ))p'                                        # index 0 -> 1st node disk

# worker (node index 5) gets an EMPTY cdrom, NOT the agent ISO; picks the 6th disk
: >"$STUB_OUT"
_vm_define_domain t-worker-3 16 4 52:54:00:6a:02:03 worker 5
assert_not_contains "$STUB_OUT" "t-agent.iso"
assert_contains     "$STUB_OUT" "device=cdrom"
assert_contains     "$STUB_OUT" '$(( 5 + 1 ))p'                                    # index 5 -> 6th node disk
# qcow2 fallback (NODE_ATTACH_EBS=false) is available in the emitted script
assert_contains     "$STUB_OUT" "qemu-img create -f qcow2 /var/lib/libvirt/images/t-worker-3.qcow2"
echo "PASS"
