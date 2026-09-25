#!/usr/bin/env bash
# run-instances block-device-mappings: the (shrunk) root/OS volume plus one
# DEDICATED volume for every VM disk -- OSDs, the Ceph VM root, and one per
# OpenShift node (masters+workers+spares) -- so nothing shares the root volume's
# IOPS. gp3 carries Iops+Throughput, io2 carries Iops only, and the *_ATTACH_EBS
# knobs turn each class off.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t
source "${DIR}/../lib/common.sh"   # defaults: ODF/CEPH on; 3 OSD, 3 cp, 3 wk, 3 spare
source "${DIR}/../lib/aws.sh"
OUT="$(mktemp)"

# default: root + 3 OSD + 1 ceph-root + 9 node volumes = 14
_ebs_block_device_mappings /dev/sda1 > "$OUT"
n=$(wc -l < "$OUT")
[[ "$n" -eq 14 ]] || { echo "FAIL: expected 14 mappings (root+3 OSD+1 ceph-root+9 node), got $n"; cat "$OUT"; exit 1; }
assert_contains "$OUT" "DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3"   # shrunk host root
assert_contains "$OUT" "VolumeSize=236,VolumeType=gp3"                             # OSD volume
assert_contains "$OUT" "VolumeSize=40,VolumeType=gp3"                              # ceph VM root volume
assert_contains "$OUT" "VolumeSize=120,VolumeType=gp3"                             # node root volume
assert_contains "$OUT" "Iops=3000"
assert_contains "$OUT" "Throughput=125"
assert_contains "$OUT" "DeleteOnTermination=true"
# exactly 9 node (120 GiB) volumes for 3 masters + 3 workers + 3 spares
[[ "$(grep -c 'VolumeSize=120,' "$OUT")" -eq 9 ]] || { echo "FAIL: expected 9 node volumes"; cat "$OUT"; exit 1; }

# io2 OSDs (with node/ceph-root attach off) -> Iops only, no Throughput anywhere
CEPH_OSD_VOLUME_TYPE=io2 CEPH_OSD_VOLUME_IOPS=20000 NODE_ATTACH_EBS=false CEPH_ROOT_ATTACH_EBS=false \
  _ebs_block_device_mappings /dev/sda1 > "$OUT"
assert_contains     "$OUT" "VolumeType=io2"
assert_contains     "$OUT" "Iops=20000"
assert_not_contains "$OUT" "Throughput"

# everything opted out -> only the root mapping
CEPH_OSD_ATTACH_EBS=false CEPH_ROOT_ATTACH_EBS=false NODE_ATTACH_EBS=false \
  _ebs_block_device_mappings /dev/sda1 > "$OUT"
[[ "$(wc -l < "$OUT")" -eq 1 ]] || { echo "FAIL: expected only the root mapping when all *_ATTACH_EBS=false"; cat "$OUT"; exit 1; }
echo "PASS"
