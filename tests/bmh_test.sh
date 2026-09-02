#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export CLUSTER_NAME=t NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       SUSHY_PORT=8000 SUSHY_USER=admin SUSHY_PASS=password \
       CONTROL_PLANE_COUNT=3 WORKER_COUNT=3 SPARE_WORKER_COUNT=1 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16
source "${DIR}/../lib/common.sh"
state_get(){ echo "uuid-$RANDOM"; }   # every node has a uuid
# Capture oc apply payloads + patch args.
OUT="$(mktemp)"
oc(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true;
      case "$*" in *"get baremetalhost worker-"*) return 1;; *"get baremetalhost master-"*) return 0;; esac; return 0; }
source "${DIR}/../lib/rhwa.sh"
rhwa_configure_bmh
# worker BMH created with vda hint and NOT externallyProvisioned
grep -q 'deviceName: /dev/vda' "$OUT" || { echo "FAIL vda hint"; exit 1; }
grep -q 'externallyProvisioned: true' "$OUT" && { echo "FAIL worker must not be externallyProvisioned"; exit 1; }
# spare worker gets a provisionable BMH too (available/unconsumed -> OCP-51155 scale-up)
grep -q 'name: worker-spare-0' "$OUT" || { echo "FAIL spare BMH not created"; exit 1; }
# spare function must be gone
declare -F rhwa_configure_spare_bmh && { echo "FAIL spare fn still defined"; exit 1; }
echo "PASS"
