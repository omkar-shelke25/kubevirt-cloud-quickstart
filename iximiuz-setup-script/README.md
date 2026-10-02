# KubeVirt on iximiuz Labs

Run KubeVirt virtual machines on the iximiuz Labs [`k8s-omni`](https://labs.iximiuz.com/playgrounds/k8s-omni) playground with one script.

iximiuz playgrounds have no nested virtualization, so KubeVirt runs every VM with software emulation. VMs boot and work, but slowly. This setup is for learning KubeVirt, not for performance.

## Files

| File | Purpose |
|---|---|
| `setup-kubevirt.sh` | Installs KubeVirt from this repo's manifests, turns on emulation, installs `virtctl`, and optionally starts a test VM |
| `README.md` | This guide |

The script reads the manifests from `../manifests`, so run it from inside a clone of this repo.

## Before you start

### Why emulation

Playground VMs run on Firecracker, which does not pass Intel VMX or AMD SVM to the guest. Without those CPU features there is no `/dev/kvm`, so KubeVirt cannot use hardware virtualization.

> [!IMPORTANT]
> iximiuz Labs used to offer a `cloud-hypervisor` backend with nested virtualization. It has been disabled since July 13, 2026, after KVM guest-to-host escape vulnerabilities. A custom rootfs cannot change this, because CPU features come from the hypervisor, not the disk image. See [Nested Virtualization](https://labs.iximiuz.com/docs/playground-recipes/nested-virtualization) for the current status.

### SELinux on iximiuz nodes

The playground kernel has SELinux built in and mounts `/sys/fs/selinux`, but no SELinux policy is loaded. KubeVirt treats SELinux as active whenever `/sys/fs/selinux/enforce` exists. When a VM starts, KubeVirt tries to read the SELinux label of the VM's QEMU process so it can label the VM's network tap device. With no policy loaded, the kernel refuses that read, network setup fails, and the VM crashes about 3 seconds after starting:

```
failed to configure vmi network: setup failed, err: Critical network error:
could not retrieve pid 22479 selinux label: getxattr /proc/22479/attr/current: operation not supported
```

KubeVirt keeps restarting the VM, and it ends in `CrashLoopBackOff`. This happens to every VM, whatever the image.

The script's `disable_selinuxfs` task fixes this by unmounting `/sys/fs/selinux` on each node. KubeVirt then sees SELinux as disabled and skips the label step. It is safe here, because no policy is loaded and SELinux enforces nothing either way.

> [!NOTE]
> The task only unmounts `selinuxfs` when no policy is loaded (PID 1 still has the `kernel` label). Nodes with a real SELinux policy, such as Fedora or RHEL, are left alone.

> [!WARNING]
> The unmount does not survive a node restart. If VMs start crashing again, run the script again.

To do it by hand instead, run this on `cplane-01`, `node-01`, and `node-02`:

```bash
sudo umount /sys/fs/selinux
```

### The k8s-omni machines

| Machine | IP | Requested CPU / RAM | Role |
|---|---|---|---|
| `dev-machine` | 172.16.0.5 | 2 / 4 GiB | Your workstation. Run everything here. |
| `cplane-01` | 172.16.0.2 | 4 / 4 GiB | `kubeadm` control plane (untainted at startup) |
| `node-01` | 172.16.0.3 | 2 / 4 GiB | Worker |
| `node-02` | 172.16.0.4 | 2 / 4 GiB | Worker |

### Plan limits

The playground requests 10 vCPU and 16 GiB in total. iximiuz Labs scales requests down to fit your plan instead of rejecting them:

| Plan | Per playground | What each machine gets (about) |
|---|---|---|
| Free | 5 vCPU / 8 GiB | Half of the table above, so 2 GiB per machine |
| Paid | 10 vCPU / 16 GiB | The full table above |

> [!WARNING]
> On the free plan, each node has about 2 GiB. KubeVirt's own pods plus one 1 GiB VM can fill a worker. Stick to the cirros test VM (128 MiB) or one small Ubuntu VM per worker.

## 1. Start the playground

Start [`k8s-omni`](https://labs.iximiuz.com/playgrounds/k8s-omni) with the defaults: **containerd** as the runtime and **flannel** as the CNI.

## 2. Clone this repo

On `dev-machine`:

```bash
git clone https://github.com/omkar-shelke25/kubevirt-cloud-quickstart.git
```

```bash
cd kubevirt-cloud-quickstart
```

## 3. Check the cluster

```bash
kubectl get nodes
```

All three nodes should be `Ready`, with `cplane-01` showing `control-plane` under `ROLES`.

## 4. Run the setup script

```bash
CREATE_TEST_VM=true ./iximiuz-setup-script/setup-kubevirt.sh
```

The script runs eight tasks in order. Each one checks the current state first, so you can run it again if a step fails.

| Task | What happens on k8s-omni |
|---|---|
| `wait_for_nodes` | Waits until all nodes are `Ready` |
| `disable_selinuxfs` | Unmounts `/sys/fs/selinux` on every node. Without this, every VM crashes a few seconds after starting (see [SELinux on iximiuz nodes](#selinux-on-iximiuz-nodes)). |
| `label_nodes` | Labels `node-01` and `node-02` with `kubevirt=true`. `cplane-01` is left out, so KubeVirt doesn't compete with the control plane for memory. |
| `install_operator` | Applies `manifests/kubevirt-operator.yaml` and waits for `virt-operator` |
| `install_kubevirt` | Applies `manifests/kubevirt-cr.yaml` and waits until KubeVirt is `Available` |
| `configure_emulation` | Finds no KVM on the workers and turns on `useEmulation` |
| `install_virtctl` | Downloads the `virtctl` version that matches the cluster |
| `create_test_vm` | Starts `testvm` (cirros) and waits until it is `Ready` |

Optional settings:

| Variable | Default | Effect |
|---|---|---|
| `CREATE_TEST_VM` | `false` | `true` also runs `create_test_vm` |
| `KUBEVIRT_NODES` | Auto-detected workers | A space-separated list of nodes to label instead |
| `FORCE_EMULATION` | `false` | `true` turns on emulation without checking for KVM |
| `WAIT_TIMEOUT` | `900` | Seconds to wait for KubeVirt to become `Available` |
| `SKIP_SELINUX_FIX` | `false` | `true` skips `disable_selinuxfs` |
| `HELPER_IMAGE` | `busybox:1.36` | Image for the short-lived node pods used by `disable_selinuxfs` |

## 5. Verify

```bash
kubectl -n kubevirt get pods -o wide
```

| Pod | Runs on |
|---|---|
| `virt-operator`, `virt-api`, `virt-controller` (one of each) | `node-01` or `node-02` |
| `virt-handler` | `node-01` and `node-02` |

```bash
kubectl -n kubevirt get kubevirt kubevirt -o jsonpath='{.spec.configuration.developerConfiguration.useEmulation}{"\n"}'
```

This prints `true`.

```bash
kubectl get vmi testvm -o wide
```

The phase is `Running`.

## 6. Connect to the test VM

```bash
virtctl console testvm
```

Press Enter if the screen is blank. Log in as `cirros` with password `gocubsgo`. Press `Ctrl+]` to leave.

## 7. Run an Ubuntu VM with SSH

Create an SSH key if `dev-machine` doesn't have one:

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

Create the VM:

```bash
virtctl create vm --name=ubuntu --memory=1Gi --volume-containerdisk=src:quay.io/containerdisks/ubuntu:24.04 --user=ubuntu --ssh-key="$(cat ~/.ssh/id_ed25519.pub)" | kubectl apply -f -
```

```bash
kubectl wait vmi ubuntu --for=condition=Ready --timeout=15m
```

Under emulation it takes about 3 minutes to boot, and about a minute more before SSH accepts logins.

```bash
virtctl ssh ubuntu@vm/ubuntu -i ~/.ssh/id_ed25519
```

## 8. Reach a VM from outside the cluster

Expose a VM port as a NodePort:

```bash
virtctl expose vm ubuntu --name=ubuntu-ssh --port=22 --type=NodePort
```

```bash
kubectl get svc ubuntu-ssh
```

The NodePort is the number after `22:` in the `PORT(S)` column. There is no cloud firewall in a playground, so it works on any node IP from `dev-machine`:

```bash
ssh -i ~/.ssh/id_ed25519 -p <NODEPORT> ubuntu@172.16.0.3
```

For a web app inside a VM, expose its HTTP port the same way, then use the playground's **Expose HTTP port** option on `node-01` with the NodePort number. You get an HTTPS link that opens in your browser.

## 9. Optional: web UI

[KubeVirt Manager](https://kubevirt-manager.io/) gives you a browser UI with a VNC console for each VM.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubevirt-manager/kubevirt-manager/main/kubernetes/bundled.yaml
```

```bash
kubectl -n kubevirt-manager rollout status deploy/kubevirt-manager
```

```bash
kubectl -n kubevirt-manager port-forward svc/kubevirt-manager 8080:8080 --address 0.0.0.0
```

Keep the port-forward running. Then use the playground's **Expose HTTP port** option on `dev-machine` with port `8080`.

> [!WARNING]
> KubeVirt Manager has no login, and it can manage resources across the whole cluster. Anyone with the exposed link controls your VMs. Keep the link private and stop the port-forward when you are done.

The disk and volume pages need CDI. See [Optional: Install CDI](../README.md#optional-install-cdi) in the main README.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `virt-handler`, `virt-api`, or `virt-controller` stays `Pending` | The workers are out of memory or CPU, common on the free plan | `kubectl -n kubevirt describe pod <pod>`, then `kubectl describe node node-01 \| grep -A 8 "Allocated resources"`. Delete VMs to free memory. |
| Script stops at `install_kubevirt` with a timeout | A KubeVirt pod is `Pending` or still pulling images | `kubectl -n kubevirt get pods -o wide`, fix the stuck pod, then run the script again |
| VM pod events show `Insufficient devices.kubevirt.io/kvm` | Emulation was not on when the VM was created | Run the script again (it turns emulation on), then `virtctl restart <vm-name>` |
| VM pod events show `Insufficient memory` | The VM's memory plus about 250 MiB of overhead doesn't fit on a worker | Use less guest memory, or delete other VMs |
| VM boots very slowly | Expected under emulation | Wait. Allow about 3 minutes to boot. |
| VM crashes a few seconds after start, `CrashLoopBackOff`, event `could not retrieve pid ... selinux label` | `selinuxfs` is mounted again, for example after a node restart | Run the script again, or `sudo umount /sys/fs/selinux` on each node |
| `virtctl: command not found` | The `install_virtctl` task didn't run or failed | Run the script again |

## Clean up

```bash
kubectl delete vm testvm ubuntu
```

```bash
kubectl delete svc ubuntu-ssh
```

Or simply let the playground expire.
