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
export PULL_SECRET="$(cat ~/pull-secret.json)"
# optional: ROUTE53_ZONE_ID accepts a zone id (Z...) OR a domain name; if unset
# it is resolved from BASE_DOMAIN (default migration.redhat.com).
# export ROUTE53_ZONE_ID=migration.redhat.com
# optional: point at a non-default SSH key (private key is the same path w/o .pub)
# export SSH_PUBLIC_KEY_FILE=$HOME/.ssh/id_ed25519.pub
# other optional overrides: CLUSTER_NAME, INSTANCE_TYPE, OCP_VERSION ...

./rhwa-lab create     # provision AWS host, VMs, Redfish, OpenShift, RHWA (~1.5-2.5h)
./rhwa-lab monitor    # live, phase-aware install progress (safe to run any time)
./rhwa-lab status     # show endpoints, credentials, uptime
./rhwa-lab test       # trigger and verify a fence_redfish remediation
./rhwa-lab install-config > install-config.yaml  # sanitized config (no pull secret or SSH key)
./rhwa-lab destroy    # tear everything down, including Route53 records
```

`create` is resumable-ish: it records AWS resource IDs to `state/<cluster>.state`
as it goes, so `destroy` always cleans up what was created even after a partial
run. The agent ISO is built **exactly once** per lab (`agent_image_built` marker)
because rebuilding regenerates the cluster's certs — see rough edge #7.

### Watching the install

`create` prints live, phase-aware progress and blocks until the cluster is up.
`./rhwa-lab monitor` shows the same view on demand. It reads ground truth from a
master node's recovery kubeconfig (booted-node count → control-plane rollout
revisions → clusterversion/operators/nodes), so it stays informative even during
the window where `openshift-install`'s own log is stuck on "Agent Rest API never
initialized. Bootstrap Kube API never initialized" (that message is expected: the
agent REST API has shut down and the admin kubeconfig isn't accepted yet).

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
6. **Host distro** — the EC2 host runs **Fedora Cloud Base** (owner
   `125523088429`, release `FEDORA_RELEASE`, default 44), which ships the full
   virtualization stack; AL2023 does not. Override the image with `HOST_AMI`
   (and set `HOST_SSH_USER` to that image's default cloud user).
7. **Agent ISO is built once (cert generation)** — every `openshift-install
   agent create image` mints a *fresh* set of cluster certs, and `work/auth/`
   holds the only copy of the matching kubeconfig + kubeadmin password.
   Rebuilding after the nodes have booted orphans those credentials (`oc` gets
   "must provide credentials"; `openshift-install wait-for` hangs on its own
   dead kubeconfig). `os_build_image` therefore builds once and reuses; to
   rebuild, `destroy` and `create` again. As a safety net, `os_wait_install`
   verifies the fetched kubeconfig actually authenticates and, if not, recovers
   a working cluster-admin kubeconfig from a master's recovery kubeconfig.
