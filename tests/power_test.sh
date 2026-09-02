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
