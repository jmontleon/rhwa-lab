# rhwa-lab

Scripted, disposable lab for testing **Red Hat Workload Availability (RHWA)**
node remediation — the **Fence Agents Remediation (FAR)** operator driven by
**NodeHealthCheck (NHC)** using the **`fence_redfish`** fence agent — against
emulated BMCs, with no physical hardware.

It runs a "bare metal" OpenShift cluster as libvirt VMs on a single
nested-virtualization-capable AWS `m8i` instance, with
[sushy-tools](https://github.com/openstack/sushy-tools) providing an emulated
Redfish BMC per VM.

## Status

Design phase. See the design spec:
[`docs/superpowers/specs/2026-08-19-rhwa-redfish-lab-design.md`](docs/superpowers/specs/2026-08-19-rhwa-redfish-lab-design.md).

Implementation has not started yet.

## Planned usage

```bash
# All inputs come from environment variables (no config/secrets file).
export AWS_ACCESS_KEY_ID=...   AWS_SECRET_ACCESS_KEY=...   AWS_REGION=...
export ROUTE53_ZONE_ID=...
export PULL_SECRET="$(cat ~/pull-secret.json)"

./rhwa-lab create     # provision AWS host, VMs, Redfish, OpenShift, RHWA
./rhwa-lab test       # trigger and verify a fence_redfish remediation
./rhwa-lab status     # show endpoints, kubeconfig, uptime
./rhwa-lab destroy    # tear everything down, including Route53 records
```
