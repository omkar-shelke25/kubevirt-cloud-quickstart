# kubevirt-cloud-quickstart

Run KubeVirt virtual machines on managed Kubernetes: Google GKE, Amazon EKS, and Azure AKS. The same manifests also work on kubeadm, on-prem, and other clusters.

The upstream KubeVirt install manifests only schedule their core components on control plane nodes. Managed Kubernetes services never expose control plane nodes, so a default install stays `Pending` forever. This repo ships the KubeVirt **v1.9.0** manifests patched to schedule on a node label (`kubevirt=true`) instead.

## Repository layout

```
.
├── README.md
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

A value such as `1k` in the `KVM` column means hardware virtualization works. An empty value means nested virtualization is not active on that node.

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

## No hardware virtualization: use emulation

If your nodes cannot expose `/dev/kvm` (for example GKE `e2` or EKS `t3`), turn on software emulation after the CR is applied:

```bash
kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
  --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
```

> [!WARNING]
> Emulation runs the whole guest in software. VMs boot and run, but much slower. Use it for learning only.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `virt-operator` is `Pending` | No node has the `kubevirt=true` label | `kubectl label node <node-name> kubevirt=true` |
| `virt-api` or `virt-controller` is `Pending` | The CR was applied without `spec.infra.nodePlacement` | Apply `manifests/kubevirt-cr.yaml` from this repo |
| `KVM` column is empty in Step 3 | Nested virtualization is off on the node | Recreate the node or node pool with a supported type, or use emulation |
| VMI events show `Insufficient devices.kubevirt.io/kvm` | Same as above | Same as above |
| `kubectl apply` of a VM times out on a webhook (private GKE cluster) | The control plane cannot reach `virt-api` on port 8443 | Add a firewall rule that allows the control plane CIDR to reach the nodes on `tcp:8443` |

## Clean up

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

- [KubeVirt quickstart with cloud providers](https://kubevirt.io/quickstart_cloud/)
- [GKE: Use nested VMs with Standard clusters](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nested-virtualization)
- [EC2: Use nested virtualization](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html)
- [AKS blog: Deploying KubeVirt on AKS](https://blog.aks.azure.com/2026/02/06/kubevirt-on-aks)
