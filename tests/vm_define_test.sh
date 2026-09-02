#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t NODE_DISK_GB=120 LIBVIRT_NET=rhwa
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
