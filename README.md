# kubevirt-cloud-quickstart

Run KubeVirt virtual machines on managed Kubernetes: Google GKE, Amazon EKS, and Azure AKS. The same manifests also work on kubeadm, on-prem, and other clusters.

The upstream KubeVirt install manifests only schedule their core components on control plane nodes. Managed Kubernetes services never expose control plane nodes, so a default install stays `Pending` forever. This repo ships the KubeVirt **v1.9.0** manifests patched to schedule on a node label (`kubevirt=true`) instead.

## Repository layout

```
.
├── README.md
├── docs/
│   └── virtctl-tutorial.md      # hands-on tour of every common virtctl command
├── manifests/
│   ├── kubevirt-operator.yaml   # upstream v1.9.0, virt-operator placement patched
│   ├── kubevirt-cr.yaml         # KubeVirt CR with infra and workload placement
│   └── testvm.yaml              # small cirros VM to test the install
└── clusters/
    └── eks/
        ├── launch-template.json # EC2 launch template with nested virtualization
        └── cluster.yaml         # eksctl cluster config
```

## How it works

KubeVirt needs two things from a cluster, on any cloud:

1. **Hardware virtualization on the nodes.** Each node that runs VMs must expose `/dev/kvm`. On cloud VMs this means nested virtualization must be enabled. Bare metal nodes have it by default. If neither is possible, KubeVirt can fall back to software emulation (see [No hardware virtualization](#no-hardware-virtualization-use-emulation)).
2. **Somewhere to schedule its own components.** This repo uses the node label `kubevirt=true` for that.

### Why the upstream manifests fail on managed Kubernetes

There are two places that require control plane nodes:

| Component | Where the rule lives | Rule |
|---|---|---|
| `virt-operator` | `kubevirt-operator.yaml`, Deployment `spec.template.spec.affinity` | Required node affinity on `node-role.kubernetes.io/control-plane` or `node-role.kubernetes.io/master` |
| `virt-api`, `virt-controller` | Not in any YAML. The operator creates them at runtime. | Same required affinity, applied whenever `spec.infra.nodePlacement` is empty in the KubeVirt CR |

On kubeadm or on-prem clusters this works, because the control plane runs on nodes inside the cluster and those nodes carry the `node-role.kubernetes.io/control-plane` label.

On managed Kubernetes it fails, because the cloud provider runs the control plane outside your cluster. `kubectl get nodes` lists only worker nodes, and none of them carry a control plane label. Every node shows `<none>` (or a provider role) in the `ROLES` column:

```
$ kubectl get nodes
NAME                                          STATUS   ROLES    AGE   VERSION
gke-kubevirt-lab-default-pool-3f1c2a9b-x7kq   Ready    <none>   12m   v1.33.4-gke.1245000
```

The result is that `virt-operator` stays `Pending` with an event like this:

```
0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector.
```

### Each cloud labels its nodes differently

Every provider adds its own labels to nodes, and none of them mean "control plane":

| Cloud | Node pool label | Other provider labels |
|---|---|---|
| GKE | `cloud.google.com/gke-nodepool=<pool>` | `cloud.google.com/machine-family`, `cloud.google.com/gke-os-distribution` |
| EKS | `eks.amazonaws.com/nodegroup=<nodegroup>` | `eks.amazonaws.com/capacityType`, `alpha.eksctl.io/nodegroup-name` |
| AKS | `kubernetes.azure.com/agentpool=<pool>` | `kubernetes.azure.com/mode`, `kubernetes.azure.com/os-sku` |

All three also set the standard Kubernetes labels such as `kubernetes.io/os`, `node.kubernetes.io/instance-type`, and `topology.kubernetes.io/zone`.

To see the labels on your own nodes, run:

```bash
kubectl get nodes --show-labels
```

### Why this repo uses a custom `kubevirt=true` label

- **One set of manifests for every cloud.** Provider labels have different keys on each cloud, so a manifest built on `cloud.google.com/gke-nodepool` would only work on GKE. `kubevirt=true` is the same everywhere.
- **It marks the nodes that can run VMs.** Only nodes created with nested virtualization get the label, so KubeVirt components and VMs never land on a node without `/dev/kvm`.
- **It is set on the node pool, not with `kubectl label`.** Managed services replace nodes during upgrades, auto-repair, and autoscaling. A label added with `kubectl label node` is lost when that node is replaced. A label set with `--node-labels` (GKE), `labels:` in eksctl (EKS), or `--nodepool-labels` / `--labels` (AKS) is applied to every new node automatically.

> [!WARNING]
> Some guides work around this by adding a fake control plane label with `kubectl label node <node> node-role.kubernetes.io/control-plane=`. Avoid this. The node is not a control plane node, other tools may treat it as one, and the label disappears as soon as the cloud replaces the node.

> [!TIP]
> To use a provider label instead of `kubevirt=true`, change the `nodeSelector` key and value in both `kubevirt-operator.yaml` and `kubevirt-cr.yaml`. For example, use `cloud.google.com/gke-nodepool: kubevirt-pool` on GKE.

### What was changed

**`manifests/kubevirt-operator.yaml`** (only the `virt-operator` Deployment at the end of the file)

| Field | Upstream | This repo |
|---|---|---|
| `spec.replicas` | `2` | `1` |
| `affinity.nodeAffinity` | Requires control plane, prefers non-worker | Removed |
| `nodeSelector` | `kubernetes.io/os: linux` | Adds `kubevirt: "true"` |
| `tolerations` | `CriticalAddonsOnly`, control-plane, master | `CriticalAddonsOnly` only |

**`manifests/kubevirt-cr.yaml`**

```yaml
  infra:                    # virt-api, virt-controller
    replicas: 1
    nodePlacement:
      nodeSelector:
        kubevirt: "true"
  workloads:                # virt-handler DaemonSet
    nodePlacement:
      nodeSelector:
        kubevirt: "true"
```

When `spec.infra.nodePlacement` is set, the operator uses it in place of the control plane default.

> [!NOTE]
> `replicas: 1` suits a single node lab. For a multi-node cluster, set `spec.replicas` in the operator Deployment and `spec.infra.replicas` in the CR back to `2`.

## Node types per cloud

| Cloud | How nested virtualization is enabled | Example node type | Not supported |
|---|---|---|---|
| GKE | `--enable-nested-virtualization` flag on the cluster or node pool | `n2-standard-2` | `e2` machine types |
| EKS | `CpuOptions.NestedVirtualization=enabled` in an EC2 launch template | `m8i.large` | Anything outside the C8i, M8i, and R8i families (except `*.metal`), Graviton |
| AKS | Built into the VM size, no flag needed | `Standard_D2s_v5` | Sizes without nested virtualization in their "Feature support" section |

> [!IMPORTANT]
> Nested virtualization is set when a node is created. You cannot turn it on later for an existing node or node pool. Create a new one instead.

## Prerequisites

- `kubectl`
- The CLI for your cloud: `gcloud`, `aws` with `eksctl`, or `az`
- `virtctl` (installed in [Step 4](#step-4-install-virtctl))

## Step 1: Create a cluster

Pick one cloud. Every example creates a single node cluster labeled `kubevirt=true`.

### GKE

Before creating the cluster, check that your project allows nested virtualization:

```bash
gcloud resource-manager org-policies describe compute.disableNestedVirtualization --effective
```

If the output shows `enforced: true`, nested virtualization is blocked for the whole project and nodes will have no `/dev/kvm`. You can still run VMs, but only with [emulation](#no-hardware-virtualization-use-emulation).

```bash
gcloud container clusters create kubevirt-lab \
  --zone=us-central1-a \
  --machine-type=n2-standard-2 \
  --num-nodes=1 \
  --disk-size=50GB \
  --enable-nested-virtualization \
  --node-labels=kubevirt=true
```

`gcloud` writes the kubeconfig automatically.

> [!WARNING]
> If a zone has no free `n2` capacity, the node never starts. The cluster stays `PROVISIONING` for about 35 minutes and then fails with `GCE_STOCKOUT` / `ZONE_RESOURCE_POOL_EXHAUSTED`. A running create cannot be cancelled, so check for errors while it runs with `gcloud compute instance-groups managed list-errors <group-name> --zone=<zone>`. If you see a stockout, start a new cluster with a different name in another zone right away, and delete the failed one once its create operation ends.

To add KubeVirt to an existing GKE cluster, create a new node pool instead:

```bash
gcloud container node-pools create kubevirt-pool \
  --cluster=<cluster-name> \
  --zone=us-central1-a \
  --machine-type=n2-standard-2 \
  --num-nodes=1 \
  --enable-nested-virtualization \
  --node-labels=kubevirt=true
```

### EKS

> [!WARNING]
> Neither `eksctl` nor the EKS node group API has a nested virtualization flag. It can only be enabled through `CpuOptions.NestedVirtualization` in an EC2 launch template, and only on the C8i, M8i, and R8i instance families. A node group created without this launch template cannot be changed later. Create a new node group with it instead.

Create the launch template and copy the ID it prints:

```bash
aws ec2 create-launch-template \
  --region us-east-1 \
  --launch-template-name kubevirt-nested \
  --launch-template-data file://clusters/eks/launch-template.json \
  --query 'LaunchTemplate.LaunchTemplateId' \
  --output text
```

Replace `lt-REPLACE_ME` in `clusters/eks/cluster.yaml` with that ID, then create the cluster:

```bash
eksctl create cluster -f clusters/eks/cluster.yaml
```

`eksctl` writes the kubeconfig automatically.

> [!NOTE]
> The launch template sets the instance type (`m8i.large`) and a 50 GiB root disk. Do not add `instanceType` or `volumeSize` to `cluster.yaml` as well, because a managed node group with a launch template takes them from the template.

### AKS

AKS needs no extra flag. Choosing a VM size that supports nested virtualization is enough.

```bash
az group create --name kubevirt-lab-rg --location eastus

az aks create \
  --resource-group kubevirt-lab-rg \
  --name kubevirt-lab \
  --node-count 1 \
  --node-vm-size Standard_D2s_v5 \
  --nodepool-labels kubevirt=true \
  --generate-ssh-keys

az aks get-credentials --resource-group kubevirt-lab-rg --name kubevirt-lab
```

To add KubeVirt to an existing AKS cluster, add a node pool instead:

```bash
az aks nodepool add \
  --resource-group <resource-group> \
  --cluster-name <cluster-name> \
  --name kubevirt \
  --node-count 1 \
  --node-vm-size Standard_D2s_v5 \
  --labels kubevirt=true
```

### Any other cluster

Label every node that should run KubeVirt:

```bash
kubectl label node <node-name> kubevirt=true
```

Then check that the node exposes KVM. Run this on the node itself:

```bash
ls -l /dev/kvm
```

If `/dev/kvm` is missing, enable nested virtualization in your hypervisor or cloud, or use [emulation](#no-hardware-virtualization-use-emulation).

## Step 2: Install KubeVirt

```bash
kubectl create -f manifests/kubevirt-operator.yaml
kubectl -n kubevirt rollout status deploy/virt-operator
kubectl create -f manifests/kubevirt-cr.yaml
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=10m
```

## Step 3: Verify

Check that all KubeVirt pods are running on the labeled node:

```bash
kubectl get pods -n kubevirt -o wide
```

Check that the node has KVM available:

```bash
kubectl get nodes -l kubevirt=true -o custom-columns=NAME:.metadata.name,KVM:.status.allocatable.devices\.kubevirt\.io/kvm
```

A value such as `1k` in the `KVM` column means hardware virtualization works. An empty value or `0` means the node has no `/dev/kvm`. VMs will stay `Pending` until you fix nested virtualization or turn on [emulation](#no-hardware-virtualization-use-emulation).

## Step 4: Install virtctl

`virtctl` is the KubeVirt command line client. `kubectl` can create and delete VMs, but you need `virtctl` to start and stop them, open the serial console or VNC, SSH into them, and expose their ports.

Install the version that matches the cluster. A mismatched client can fail against the cluster API.

### Linux and macOS

```bash
VERSION=$(kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.observedKubeVirtVersion}")
ARCH=$(uname -s | tr A-Z a-z)-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
echo "${VERSION} ${ARCH}"
curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-${ARCH}
sudo install -m 0755 virtctl /usr/local/bin
rm virtctl
```

The `echo` line should print something like `v1.9.0 linux-amd64`. If `VERSION` is empty, KubeVirt is not installed yet. Finish [Step 2](#step-2-install-kubevirt) first.

> [!NOTE]
> Release binaries exist for `linux-amd64`, `linux-arm64`, `darwin-amd64`, `darwin-arm64`, and `windows-amd64.exe`.

### Windows

Download `virtctl-<version>-windows-amd64.exe` from the [KubeVirt releases page](https://github.com/kubevirt/kubevirt/releases), rename it to `virtctl.exe`, and place it in a folder on your `PATH`.

### As a kubectl plugin (krew)

If you use [krew](https://krew.sigs.k8s.io/):

```bash
kubectl krew install virt
```

With the plugin, every `virtctl <command>` in this README becomes `kubectl virt <command>`.

> [!WARNING]
> The krew plugin installs the latest `virtctl`, not the version of your cluster. Use the binary install above if your cluster runs an older KubeVirt release.

### Verify

```bash
virtctl version
```

The output shows both the client version and the server version. They should match.

## Step 5: Run a test VM

Create the VM:

```bash
kubectl apply -f manifests/testvm.yaml
```

`testvm.yaml` uses `runStrategy: Always`, so the VM starts as soon as it is created. Wait until it reports `Running`:

```bash
kubectl get vm testvm
kubectl get vmi testvm
```

A `VirtualMachine` (`vm`) is the definition. A `VirtualMachineInstance` (`vmi`) exists only while the VM is running.

Open the serial console:

```bash
virtctl console testvm
```

Log in with user `cirros` and password `gocubsgo`. Press `Ctrl+]` to leave the console.

### Common virtctl commands

| Task | Command |
|---|---|
| Start a stopped VM | `virtctl start testvm` |
| Stop a running VM | `virtctl stop testvm` |
| Restart a VM | `virtctl restart testvm` |
| Pause and resume a VM | `virtctl pause vm testvm` / `virtctl unpause vm testvm` |
| Serial console | `virtctl console testvm` |
| Graphical console (needs `remote-viewer` installed locally) | `virtctl vnc testvm` |
| SSH into the VM (needs an SSH key in the guest) | `virtctl ssh cirros@vm/testvm` |
| Expose SSH as a Kubernetes Service | `virtctl expose vm testvm --name testvm-ssh --port 22 --type ClusterIP` |
| Show client and server versions | `virtctl version` |

> [!NOTE]
> `virtctl stop` changes the VM's `runStrategy` to `Halted`. The VM stays stopped until you run `virtctl start`, even if its node restarts.

### Remove the VM

```bash
kubectl delete -f manifests/testvm.yaml
```

To try every common `virtctl` command (lifecycle, console, SSH, file copy, port forwarding, and guest agent queries), follow [Exploring virtctl](docs/virtctl-tutorial.md).

## Optional: Install CDI

CDI (Containerized Data Importer) adds persistent disks to KubeVirt. It imports VM images into PersistentVolumeClaims and manages `DataVolume` objects. You need it for:

- VMs whose disk survives a restart (a containerdisk is reset on every start)
- `virtctl create vm --volume-import`, `virtctl image-upload`, and VM cloning and snapshots
- Disk and volume pages in web UIs such as [KubeVirt Manager](#optional-web-ui-with-kubevirt-manager), which shows `CDI (Containerized Data Importer) not found!` without it

Unlike KubeVirt, CDI's manifests need no changes on managed Kubernetes. Its operator only uses a `kubernetes.io/os: linux` node selector and does not require control plane nodes.

### Check the StorageClass

CDI creates PVCs, so the cluster needs a default StorageClass that allows volume expansion:

```bash
kubectl get storageclass
```

Look for `(default)` next to one class and `true` in the `ALLOWVOLUMEEXPANSION` column.

| Cloud | Default StorageClass |
|---|---|
| GKE | `standard-rwo` (Persistent Disk CSI driver, enabled by default) |
| AKS | `managed-csi` (Azure Disk CSI driver, enabled by default) |
| EKS | None that works out of the box. Install the Amazon EBS CSI driver add-on and mark a `gp3` StorageClass as default first. |

### Install

```bash
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/v1.66.1/cdi-operator.yaml
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/v1.66.1/cdi-cr.yaml
kubectl wait cdi cdi --for condition=Available --timeout=10m
```

### Verify

```bash
kubectl get pods -n cdi
```

You should see `cdi-operator`, `cdi-apiserver`, `cdi-deployment`, and `cdi-uploadproxy` all `Running`.

> [!NOTE]
> The default `cdi-cr.yaml` already enables the `HonorWaitForFirstConsumer` feature gate. With it, a disk is created in the same zone as the node that runs the VM.

## Optional: Web UI with KubeVirt Manager

[KubeVirt Manager](https://kubevirt-manager.io/) is an open-source web UI for KubeVirt. It lists and controls VMs and opens a VNC console in the browser through noVNC.

Requirements:

- KubeVirt from this repo (its `ExpandDisks` feature gate is GA in v1.9.0, so nothing to enable)
- [CDI](#optional-install-cdi), for the disk and volume pages. The VM list, power actions, and console work without it.

### Install

```bash
kubectl apply -f https://raw.githubusercontent.com/kubevirt-manager/kubevirt-manager/main/kubernetes/bundled.yaml
kubectl -n kubevirt-manager rollout status deploy/kubevirt-manager
```

### Open the UI

```bash
kubectl -n kubevirt-manager port-forward svc/kubevirt-manager 8080:8080
```

Open `http://localhost:8080`. To reach it from another machine (for example a cloud playground that exposes ports through its own UI), add `--address 0.0.0.0` to the port-forward.

> [!WARNING]
> KubeVirt Manager has no login by default, and its ClusterRole can manage resources across the whole cluster. Anyone who can reach the UI controls your VMs. Keep it behind `port-forward`. Do not expose it with a NodePort or a public LoadBalancer.

### Graphical desktop in the VNC console

The VNC console shows the VM's own screen. Cloud images such as Ubuntu have no desktop, so you see a text login. To get a graphical login, the guest needs a desktop and a display manager, for example with cloud-init:

```yaml
runcmd:
  - DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xfce4 xfce4-terminal dbus-x11 lightdm lightdm-gtk-greeter
  - systemctl start lightdm
```

## No hardware virtualization: use emulation

KubeVirt normally runs VMs with KVM, which needs `/dev/kvm` on the node. When a node has no KVM, KubeVirt can run VMs with QEMU software emulation instead.

### When you need it

| Situation | Example |
|---|---|
| The machine type has no nested virtualization | GKE `e2`, EKS `t3`, Graviton |
| An organization policy blocks nested virtualization | GCP `constraints/compute.disableNestedVirtualization` enforced, common in training and sandbox lab accounts |
| The hypervisor under your nodes does not pass through VMX/SVM | Some on-prem VMs and nested lab setups |

### How to detect it

| Check | Command | No KVM looks like |
|---|---|---|
| VM pod events | `kubectl describe pod -l kubevirt.io=virt-launcher` | `Insufficient devices.kubevirt.io/kvm` |
| Node resources | `kubectl get nodes -o custom-columns=NAME:.metadata.name,KVM:.status.allocatable.devices\.kubevirt\.io/kvm` | `0` or empty |
| virt-handler logs | `kubectl -n kubevirt logs ds/virt-handler \| grep -i kvm` | `open /dev/kvm: no such file or directory` |
| GCP org policy | `gcloud resource-manager org-policies describe compute.disableNestedVirtualization --effective` | `enforced: true` |

> [!IMPORTANT]
> On GCP, an enforced org policy wins over `--enable-nested-virtualization`. GKE accepts the flag and shows it in the node pool config, but GCP hides the VMX CPU flag from the node, so `/dev/kvm` never appears. Nothing fails at create time. You only notice when VMs stay `Pending`.

### Turn it on

```bash
kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
  --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
```

Confirm it is set:

```bash
kubectl -n kubevirt get kubevirt kubevirt -o jsonpath='{.spec.configuration.developerConfiguration.useEmulation}{"\n"}'
```

This prints `true`.

VMs that were already `Pending` keep their old pod, which still asks for KVM. Restart each one so its pod is recreated without the KVM request:

```bash
virtctl restart <vm-name>
```

### What to expect

> [!WARNING]
> Emulation runs every guest CPU instruction in software. Use it for learning and testing only.

| Task (Ubuntu 24.04, 1 vCPU, n2-standard-2 node) | Approximate time under emulation |
|---|---|
| Boot to login prompt | 3 minutes |
| Cloud-init `apt-get update` | 1 to 2 minutes |
| Install XFCE and xrdp with cloud-init | 10 minutes |
| Cloud-init finished, ready to log in | About 14 minutes after start |

Expect a slow desktop, slow package installs, and short console timeouts. Give `kubectl wait` and `virtctl console --timeout` longer timeouts than usual.

### Turn it off

When you move to nodes that have KVM, set `useEmulation` back to `false` and restart your VMs:

```bash
kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
  --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":false}}}}'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `virt-operator` is `Pending` | No node has the `kubevirt=true` label | `kubectl label node <node-name> kubevirt=true` |
| `virt-api` or `virt-controller` is `Pending` | The CR was applied without `spec.infra.nodePlacement` | Apply `manifests/kubevirt-cr.yaml` from this repo |
| `KVM` column is empty in Step 3 | Nested virtualization is off on the node | Recreate the node or node pool with a supported type, or use emulation |
| VMI events show `Insufficient devices.kubevirt.io/kvm` | Same as above | Same as above |
| `KVM` is `0` even though the node pool has `enableNestedVirtualization: true` | A GCP org policy blocks nested virtualization | Check `compute.disableNestedVirtualization`. If enforced, use [emulation](#no-hardware-virtualization-use-emulation) or another project |
| VM still `Pending` after turning on emulation | Its pod was created before the change and still requests KVM | `virtctl restart <vm-name>` |
| GKE cluster stuck in `PROVISIONING`, then `GCE_STOCKOUT` | No free capacity for the machine type in that zone | Create the cluster in another zone (see the warning in [GKE](#gke)) |
| Web UI shows `CDI (Containerized Data Importer) not found!` | CDI is not installed | [Install CDI](#optional-install-cdi) |
| `kubectl apply` of a VM times out on a webhook (private GKE cluster) | The control plane cannot reach `virt-api` on port 8443 | Add a firewall rule that allows the control plane CIDR to reach the nodes on `tcp:8443` |

## Clean up

Remove the optional add-ons first, if you installed them:

```bash
kubectl delete -f https://raw.githubusercontent.com/kubevirt-manager/kubevirt-manager/main/kubernetes/bundled.yaml
kubectl delete cdi cdi
kubectl delete -f https://github.com/kubevirt/containerized-data-importer/releases/download/v1.66.1/cdi-operator.yaml
```

GKE:

```bash
gcloud container clusters delete kubevirt-lab --zone=us-central1-a
```

EKS:

```bash
eksctl delete cluster -f clusters/eks/cluster.yaml
aws ec2 delete-launch-template --region us-east-1 --launch-template-name kubevirt-nested
```

AKS:

```bash
az group delete --name kubevirt-lab-rg
```

## Upgrading to a newer KubeVirt version

The manifests are pinned to v1.9.0. To move to a newer release:

1. Download `kubevirt-operator.yaml` and `kubevirt-cr.yaml` from the [KubeVirt releases page](https://github.com/kubevirt/kubevirt/releases).
2. Apply the four `virt-operator` edits listed in [What was changed](#what-was-changed).
3. Add the `infra` and `workloads` blocks to the CR.

## References

- [CDI (Containerized Data Importer)](https://github.com/kubevirt/containerized-data-importer)
- [KubeVirt Manager](https://github.com/kubevirt-manager/kubevirt-manager)
- [KubeVirt quickstart with cloud providers](https://kubevirt.io/quickstart_cloud/)
- [GKE: Use nested VMs with Standard clusters](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nested-virtualization)
- [EC2: Use nested virtualization](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html)
- [AKS blog: Deploying KubeVirt on AKS](https://blog.aks.azure.com/2026/02/06/kubevirt-on-aks)
