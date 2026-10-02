# Exploring virtctl

A hands-on tour of `virtctl`, the KubeVirt command line client. You create one Ubuntu VM and use it to try every common `virtctl` command: lifecycle, console, SSH, file copy, port forwarding, guest agent queries, and services.

All commands were checked against `virtctl` **v1.9.0**.

## What you will learn

| Part | Commands |
|---|---|
| [1. Create a VM](#part-1-create-a-vm) | `create vm` |
| [2. Lifecycle](#part-2-lifecycle) | `start`, `stop`, `restart`, `pause`, `unpause`, `soft-reboot` |
| [3. Console and VNC](#part-3-console-and-vnc) | `console`, `vnc screenshot`, `vnc --proxy-only` |
| [4. SSH and file copy](#part-4-ssh-and-file-copy) | `ssh`, `scp` |
| [5. Reach apps inside the VM](#part-5-reach-apps-inside-the-vm) | `port-forward`, `expose` |
| [6. Ask the guest agent](#part-6-ask-the-guest-agent) | `guestosinfo`, `fslist`, `userlist` |
| [7. Inspect and administer](#part-7-inspect-and-administer) | `objectgraph`, `version`, `adm log-verbosity` |

## Before you start

- KubeVirt is installed and `Available` ([README Step 2](../README.md#step-2-install-kubevirt))
- `virtctl` is installed and matches the cluster version ([README Step 4](../README.md#step-4-install-virtctl))
- You have an SSH key pair. This tutorial uses `~/.ssh/id_ed25519`. Create one with `ssh-keygen -t ed25519` if needed.

> [!NOTE]
> If your nodes have no `/dev/kvm` and KubeVirt runs with `useEmulation: true`, every command still works, but the VM is much slower. Expect about 3 minutes to boot and several more for cloud-init to install packages.

## How virtctl fits with kubectl

A VM is a normal Kubernetes object, so you **list and inspect** it with `kubectl`:

```bash
kubectl get vm
kubectl get vmi
kubectl describe vm lab
```

You use `virtctl` to **act on** the VM: power it on and off, connect to its console, SSH into it, and expose its ports. `virtctl` has no `get` command.

| Object | Short name | Exists when |
|---|---|---|
| `VirtualMachine` | `vm` | Always, from create until delete. It is the definition. |
| `VirtualMachineInstance` | `vmi` | Only while the VM is running |

Keep a second terminal open with this watch command to see each change as you go:

```bash
kubectl get vm,vmi -w
```

## Part 1: Create a VM

`virtctl create vm` does not create anything in the cluster. It prints a `VirtualMachine` manifest, which you then apply with `kubectl`.

### 1.1 See what virtctl generates

```bash
virtctl create vm --name=lab --memory=1Gi --volume-containerdisk=src:quay.io/containerdisks/ubuntu:24.04
```

Read the output. You will see `runStrategy: Always`, a `containerDisk` volume with the Ubuntu image, and `memory.guest: 1Gi`.

### 1.2 Write the cloud-init config

The VM needs a user with your SSH key, the QEMU guest agent (used in Part 6), and nginx (used in Part 5).

Print your public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

Create a file named `lab-user-data.yaml`. Replace `<YOUR_PUBLIC_KEY>` with the line printed above.

```yaml
#cloud-config
user: ubuntu
ssh_authorized_keys:
  - <YOUR_PUBLIC_KEY>
packages:
  - qemu-guest-agent
  - nginx
runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now nginx
```

> [!IMPORTANT]
> `--user` and `--ssh-key` cannot be combined with `--cloud-init-user-data`. When you need more than a user and a key, put everything in your own cloud-init file, as above.

### 1.3 Create the VM

```bash
virtctl create vm --name=lab --memory=1Gi --volume-containerdisk=src:quay.io/containerdisks/ubuntu:24.04 --cloud-init-user-data=$(base64 -w0 lab-user-data.yaml) > lab-vm.yaml
```

```bash
kubectl apply -f lab-vm.yaml
```

```bash
kubectl wait vmi lab --for=condition=Ready --timeout=10m
```

```bash
kubectl get vmi lab -o wide
```

`Ready` means the VM is booted. Cloud-init keeps installing packages for a while after that.

## Part 2: Lifecycle

Watch the `STATUS` column in your second terminal after each command.

### 2.1 Stop and start

```bash
virtctl stop lab
```

The VMI is deleted and the VM status becomes `Stopped`. The VM object stays.

```bash
kubectl get vm lab -o jsonpath='{.spec.runStrategy}{"\n"}'
```

This prints `Halted`. `virtctl stop` changes the run strategy, which keeps the VM off until you start it again.

```bash
virtctl start lab
```

The run strategy goes back to `Always` and a new VMI is created.

> [!NOTE]
> A stopped VM using a containerdisk boots from a fresh copy of the image. Anything written to its disk is lost, but cloud-init runs again and reinstalls the packages.

### 2.2 Restart

```bash
virtctl restart lab
```

This deletes the VMI and creates a new one. Run `kubectl get vmi lab` and look at `AGE`: it starts again from zero.

### 2.3 Pause and unpause

```bash
virtctl pause vm lab
```

The VM status becomes `Paused`. The guest is frozen in memory, and the VMI and its pod keep running.

```bash
virtctl unpause vm lab
```

The guest continues from where it stopped. Nothing restarts.

### 2.4 Soft reboot

```bash
virtctl soft-reboot lab
```

This asks the guest OS to reboot itself, like running `reboot` inside it. The VMI stays the same. Compare with `restart`, where the VMI is replaced.

> [!TIP]
> `soft-reboot` needs the guest agent, or ACPI support in the guest. If it fails right after boot, wait until cloud-init has installed `qemu-guest-agent`.

### 2.5 Start paused

```bash
virtctl stop lab
```

```bash
virtctl start lab --paused
```

The VMI is created but the guest does not run until you unpause it:

```bash
virtctl unpause vm lab
```

### Lifecycle summary

| Command | VMI replaced? | Guest state |
|---|---|---|
| `stop` | Deleted | Gone |
| `start` | Created | Fresh boot |
| `restart` | Yes | Fresh boot |
| `pause` / `unpause` | No | Frozen, then continues |
| `soft-reboot` | No | Guest reboots itself |

## Part 3: Console and VNC

### 3.1 Serial console

```bash
virtctl console lab
```

Press Enter if the screen is blank. You see the Ubuntu login prompt and kernel messages. The `ubuntu` user has no password, so use SSH (Part 4) to log in.

Press `Ctrl+]` to leave the console.

> [!TIP]
> The serial console works even when networking inside the VM is broken. It is the first place to look when SSH fails.

### 3.2 VNC screenshot

A VNC viewer needs a desktop, but a screenshot works from any terminal:

```bash
virtctl vnc screenshot lab -f lab.png
```

Open `lab.png`. It shows the VM's graphical screen. The Ubuntu cloud image has no desktop, so you see a text login screen.

### 3.3 VNC proxy

This command starts a local proxy and prints a port that any VNC viewer can connect to:

```bash
virtctl vnc lab --proxy-only
```

Connect a VNC viewer on the same machine to `127.0.0.1:<port>`. Press `Ctrl+C` to stop the proxy.

> [!WARNING]
> The proxy listens on `127.0.0.1` by default. `--address=0.0.0.0` makes the VM's screen reachable by anyone who can reach that machine, with no password.

## Part 4: SSH and file copy

`virtctl ssh` and `virtctl scp` tunnel through the Kubernetes API, so they work without a Service, NodePort, or firewall rule.

### 4.1 Open a shell

```bash
virtctl ssh ubuntu@vm/lab -i ~/.ssh/id_ed25519
```

Type `yes` at the host key prompt the first time. Inside the VM, check cloud-init:

```bash
cloud-init status
```

Wait until it prints `status: done`, then type `exit`.

The target format is `user@vm/name`. Use `vmi/name` to target the running instance, or `vm/name/namespace` for another namespace.

### 4.2 Run one command

```bash
virtctl ssh ubuntu@vm/lab -i ~/.ssh/id_ed25519 --command "systemctl is-active nginx qemu-guest-agent"
```

Both lines should print `active`.

### 4.3 Copy files

Create a file and copy it into the VM:

```bash
echo "hello from outside" > notes.txt
```

```bash
virtctl scp -i ~/.ssh/id_ed25519 notes.txt ubuntu@vm/lab:notes.txt
```

Copy a file out of the VM:

```bash
virtctl scp -i ~/.ssh/id_ed25519 ubuntu@vm/lab:/etc/os-release ./lab-os-release
```

```bash
cat lab-os-release
```

## Part 5: Reach apps inside the VM

nginx is listening on port 80 inside the VM.

### 5.1 Port forward (no Service needed)

```bash
virtctl port-forward vm/lab 8080:80
```

In another terminal:

```bash
curl -s localhost:8080 | grep -i title
```

This prints `<title>Welcome to nginx!</title>`. Press `Ctrl+C` in the first terminal to stop forwarding.

Like `virtctl ssh`, the traffic goes through the Kubernetes API, so it works only from where you run `virtctl`.

### 5.2 ClusterIP Service (reachable from other pods)

```bash
virtctl expose vm lab --name=lab-http --port=80
```

```bash
kubectl get svc lab-http
```

Test it from a temporary pod:

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- curl -s lab-http
```

`virtctl expose` creates a normal Kubernetes Service whose selector matches the VM's `virt-launcher` pod.

### 5.3 NodePort Service (reachable from outside the cluster)

```bash
virtctl expose vm lab --name=lab-http-np --port=80 --type=NodePort
```

```bash
kubectl get svc lab-http-np
```

The NodePort is the number after `80:` in the `PORT(S)` column. Find a node's external IP:

```bash
kubectl get nodes -o wide
```

Then open `http://<node-external-ip>:<nodeport>` in a browser.

> [!WARNING]
> On GKE, EKS, and AKS, cloud firewalls block NodePorts from the internet by default. Allow the NodePort only from your own IP. For GKE:
> `gcloud compute firewall-rules create allow-lab-http --network=default --allow=tcp:<nodeport> --target-tags=<node-network-tag> --source-ranges=<your-ip>/32`

## Part 6: Ask the guest agent

These commands read information from inside the guest through `qemu-guest-agent`. They fail if the agent is not running.

Check that KubeVirt sees the agent:

```bash
kubectl get vmi lab -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}{"\n"}'
```

It should print `True`.

```bash
virtctl guestosinfo lab
```

This returns the OS name, version, kernel, and hostname as JSON.

```bash
virtctl fslist lab
```

This lists the guest's file systems, with mount points and used and total bytes.

```bash
virtctl userlist lab
```

This lists users logged in to the guest. Open a `virtctl ssh` session in another terminal, then run it again to see `ubuntu` appear.

## Part 7: Inspect and administer

### 7.1 Object graph

```bash
virtctl objectgraph lab -o yaml
```

This shows every object the VM depends on, such as its VMI, the `virt-launcher` pod, and its volumes. It is useful for understanding what to clean up or back up.

### 7.2 Versions

```bash
virtctl version
```

The client and server versions should match. A mismatch is the first thing to check when a `virtctl` command fails in an unexpected way.

### 7.3 Component log verbosity

```bash
virtctl adm log-verbosity --all
```

This shows the log level of each KubeVirt component. The default is `2`. You can raise it for one component while debugging:

```bash
virtctl adm log-verbosity --virt-handler=4
```

```bash
virtctl adm log-verbosity --reset
```

Always reset it afterwards, because higher levels produce a lot of logs.

## Clean up

```bash
kubectl delete svc lab-http lab-http-np
```

```bash
kubectl delete vm lab
```

```bash
rm -f lab-vm.yaml lab-user-data.yaml lab.png notes.txt lab-os-release
```

If you created a firewall rule for the NodePort, delete it too:

```bash
gcloud compute firewall-rules delete allow-lab-http --quiet
```

## Quick reference

| Task | Command |
|---|---|
| Generate a VM manifest | `virtctl create vm --name=<vm> --volume-containerdisk=src:<image>` |
| Start / stop / restart | `virtctl start <vm>` / `virtctl stop <vm>` / `virtctl restart <vm>` |
| Pause / unpause | `virtctl pause vm <vm>` / `virtctl unpause vm <vm>` |
| Reboot from inside the guest | `virtctl soft-reboot <vmi>` |
| Serial console | `virtctl console <vmi>` (leave with `Ctrl+]`) |
| VNC screenshot | `virtctl vnc screenshot <vmi> -f out.png` |
| VNC proxy for any viewer | `virtctl vnc <vmi> --proxy-only` |
| SSH | `virtctl ssh <user>@vm/<vm> -i <key>` |
| Copy files | `virtctl scp -i <key> <src> <user>@vm/<vm>:<dst>` |
| Forward a port | `virtctl port-forward vm/<vm> <local>:<remote>` |
| Create a Service | `virtctl expose vm <vm> --name=<svc> --port=<port> [--type=NodePort]` |
| Guest OS info | `virtctl guestosinfo <vmi>` |
| Guest file systems | `virtctl fslist <vmi>` |
| Logged-in users | `virtctl userlist <vmi>` |
| Dependency graph | `virtctl objectgraph <vm>` |
| Versions | `virtctl version` |
| Help for any command | `virtctl <command> --help` |
