#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
stub_ssh_host
host_ip(){ echo x; }; log(){ :; }; ok(){ :; }; warn(){ :; }
source "${DIR}/../lib/host.sh"
host_storage_pool
assert_contains "$STUB_OUT" "pool-define-as default dir"
assert_contains "$STUB_OUT" "/var/lib/libvirt/images"
assert_contains "$STUB_OUT" "pool-autostart default"
echo "PASS"
