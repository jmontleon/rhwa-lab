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

**First-draft implementation — not yet run end-to-end.** Bash syntax passes;
no live AWS test has been performed. Expect to iterate. Design spec:
[`docs/superpowers/specs/2026-08-19-rhwa-redfish-lab-design.md`](docs/superpowers/specs/2026-08-19-rhwa-redfish-lab-design.md).

## Prerequisites (your machine)

`bash`, `aws` CLI v2, `jq`, `curl`, `ssh`/`scp`, `tar`, `openssl`, and an SSH
keypair (`~/.ssh/id_rsa[.pub]` by default). `oc`/`openshift-install` are
downloaded automatically. An AWS account allowed to manage EC2/EIP/Route53
with enough On-Demand vCPU quota (~48). A Red Hat pull secret with Red Hat
registry entitlement.

## Usage

```bash
# All inputs come from environment variables (no config/secrets file).
export AWS_ACCESS_KEY_ID=...   AWS_SECRET_ACCESS_KEY=...   AWS_REGION=us-east-2
export ROUTE53_ZONE_ID=Z...                 # hosted zone for migration.redhat.com
export PULL_SECRET="$(cat ~/pull-secret.json)"
# optional overrides: CLUSTER_NAME, INSTANCE_TYPE, OCP_VERSION, SSH_PUBLIC_KEY_FILE ...

./rhwa-lab create     # provision AWS host, VMs, Redfish, OpenShift, RHWA (~1.5-2.5h)
./rhwa-lab status     # show endpoints, credentials, uptime
./rhwa-lab test       # trigger and verify a fence_redfish remediation
./rhwa-lab destroy    # tear everything down, including Route53 records
```

`create` is resumable-ish: it records AWS resource IDs to `state/<cluster>.state`
as it goes, so `destroy` always cleans up what was created even after a partial
run.

## Known rough edges (search the code for `# ITERATE:`)

These are the spots most likely to need a fix on the first real run:

1. **Nested-virt L2 performance** on `m8i.12xlarge` — installs may be slow;
   bump `INSTANCE_TYPE` (incl. `m8i.metal-*`) if flaky.
2. **RHCOS NIC name** — agent-config assumes `enp1s0`; may differ by machine
   type (nmstate matches by MAC as a hedge).
3. **cdrom target dev** for the agent ISO in libvirt (`sda` vs `hda`).
4. **`fence_redfish` valueless flags** — `--ssl-insecure` is passed with an
   empty value; FAR's parameter handling may need adjustment (check FAR pod
   logs during `test`).
5. **Operator package names/channels** in the Red Hat catalog
   (`fence-agents-remediation`, `node-healthcheck-operator`, channel `stable`).
6. **AL2023 libvirt/virt-install availability** — package set assumed present.
