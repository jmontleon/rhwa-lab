#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export CLUSTER_NAME=t NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       LIBVIRT_NET=rhwa CONTROL_PLANE_COUNT=3 WORKER_COUNT=3 SPARE_WORKER_COUNT=1 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/host.sh"
stub_ssh_host
host_ip(){ echo x; }
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
