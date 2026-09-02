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
