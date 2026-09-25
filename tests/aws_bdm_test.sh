#!/usr/bin/env bash
# run-instances block-device-mappings: the root/OS volume plus one DEDICATED EBS
# volume per OSD (so OSDs don't share the root volume's IOPS). gp3 carries
# Iops+Throughput, io2 carries Iops only, and CEPH_OSD_ATTACH_EBS=false attaches
# none (use instance-store instead).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t
source "${DIR}/../lib/common.sh"   # ODF_ENABLED/CEPH_ENABLED=true, OSD size 236, root 1000 by default
source "${DIR}/../lib/aws.sh"
OUT="$(mktemp)"

# default: gp3, root + 3 OSD volumes
_ebs_block_device_mappings /dev/sda1 > "$OUT"
[[ "$(wc -l < "$OUT")" -eq 4 ]] || { echo "FAIL: expected 4 mappings (root+3 OSD), got $(wc -l < "$OUT")"; cat "$OUT"; exit 1; }
assert_contains "$OUT" "DeviceName=/dev/sda1,Ebs={VolumeSize=1000,VolumeType=gp3"   # root, shrunk
assert_contains "$OUT" "DeviceName=/dev/sdb,Ebs={VolumeSize=236,VolumeType=gp3"     # first OSD volume
assert_contains "$OUT" "DeviceName=/dev/sdd,"                                        # third OSD volume
assert_contains "$OUT" "Iops=3000"
assert_contains "$OUT" "Throughput=125"
assert_contains "$OUT" "DeleteOnTermination=true"

# io2 -> Iops only, no Throughput field anywhere
CEPH_OSD_VOLUME_TYPE=io2 CEPH_OSD_VOLUME_IOPS=20000 _ebs_block_device_mappings /dev/sda1 > "$OUT"
assert_contains     "$OUT" "VolumeType=io2"
assert_contains     "$OUT" "Iops=20000"
assert_not_contains "$OUT" "Throughput"

# opt out of dedicated volumes -> only the root mapping
CEPH_OSD_ATTACH_EBS=false _ebs_block_device_mappings /dev/sda1 > "$OUT"
[[ "$(wc -l < "$OUT")" -eq 1 ]] || { echo "FAIL: expected only the root mapping when CEPH_OSD_ATTACH_EBS=false"; cat "$OUT"; exit 1; }
echo "PASS"
