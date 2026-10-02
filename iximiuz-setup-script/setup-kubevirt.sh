#!/usr/bin/env bash
#
# Set up KubeVirt on an existing Kubernetes cluster using this repo's manifests.
#
# Built for small lab clusters such as the iximiuz Labs k8s-omni playground,
# but works on any cluster where kubectl already points at the right context.
#
# What it does, as separate named tasks:
#   1. wait_for_nodes      wait until every node is Ready
#   2. disable_selinuxfs   unmount /sys/fs/selinux on nodes where SELinux has no policy loaded
#   3. label_nodes         label worker nodes kubevirt=true (all nodes if there are no workers)
#   4. install_operator    apply manifests/kubevirt-operator.yaml and wait for virt-operator
#   5. install_kubevirt    apply manifests/kubevirt-cr.yaml and wait until KubeVirt is Available
#   6. configure_emulation turn on useEmulation when no labeled node exposes /dev/kvm
#   7. install_virtctl     install the virtctl version that matches the cluster
#   8. create_test_vm      optional, start manifests/testvm.yaml and wait until it is Ready
#
# Safe to run again: every task checks the current state first.
#
# Usage:
#   ./iximiuz-setup-script/setup-kubevirt.sh
#
# Optional environment variables:
#   KUBEVIRT_NODES="node-01 node-02"   label these nodes instead of auto-detecting workers
#   FORCE_EMULATION=true               turn on emulation even if KVM is present
#   CREATE_TEST_VM=true                also run task 8
#   SKIP_SELINUX_FIX=true              skip task 2
#   WAIT_TIMEOUT=900                   seconds to wait for KubeVirt to become Available

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

KUBEVIRT_NODES="${KUBEVIRT_NODES:-}"
FORCE_EMULATION="${FORCE_EMULATION:-false}"
CREATE_TEST_VM="${CREATE_TEST_VM:-false}"
SKIP_SELINUX_FIX="${SKIP_SELINUX_FIX:-false}"
HELPER_IMAGE="${HELPER_IMAGE:-busybox:1.36}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"

NODE_LABEL_KEY="kubevirt"
NODE_LABEL_VALUE="true"

log()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Run "$@" until it succeeds or the timeout (seconds) passes.
wait_until() {
  local timeout="$1"; shift
  local waited=0
  until "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

preflight() {
  log "Preflight checks"
  command -v kubectl >/dev/null 2>&1 || fail "kubectl not found in PATH"
  command -v curl >/dev/null 2>&1 || fail "curl not found in PATH"
  kubectl cluster-info >/dev/null 2>&1 || fail "cannot reach the cluster, check your kubeconfig"
  for f in kubevirt-operator.yaml kubevirt-cr.yaml testvm.yaml; do
    [ -f "${MANIFEST_DIR}/${f}" ] || fail "missing ${MANIFEST_DIR}/${f}, run this script from inside the repo"
  done
  info "context: $(kubectl config current-context)"
}

all_nodes_ready() {
  local not_ready
  not_ready=$(kubectl get nodes --no-headers | awk '$2 != "Ready"' | wc -l)
  [ "$not_ready" -eq 0 ]
}

task_wait_for_nodes() {
  log "Task 1/8: wait_for_nodes"
  wait_until 300 all_nodes_ready || fail "not all nodes became Ready within 300s"
  kubectl get nodes
}

# Runs on one node, inside the host mount namespace.
# Unmounts selinuxfs only when it is mounted AND no SELinux policy is loaded
# (PID 1 still has the "kernel" label). Nodes with a real SELinux policy are left alone.
# shellcheck disable=SC2016  # expanded on the node, not here
SELINUX_FIX_CMD='if [ ! -f /sys/fs/selinux/enforce ]; then echo "not-mounted"; elif [ "$(tr -d "\0" < /proc/1/attr/current)" != "kernel" ]; then echo "policy-loaded"; else umount /sys/fs/selinux && echo "unmounted"; fi'

# Starts a short-lived privileged pod on the node and prints its result.
fix_selinuxfs_on_node() {
  local node="$1"
  local pod="kubevirt-selinux-fix-${node}"
  local result

  kubectl -n kube-system delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1

  kubectl -n kube-system apply -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  labels:
    app: kubevirt-selinux-fix
spec:
  nodeName: ${node}
  hostPID: true
  restartPolicy: Never
  tolerations:
  - operator: Exists
  containers:
  - name: fix
    image: ${HELPER_IMAGE}
    command:
    - chroot
    - /host
    - nsenter
    - -t
    - "1"
    - -m
    - --
    - sh
    - -c
    - |
      ${SELINUX_FIX_CMD}
    securityContext:
      privileged: true
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
EOF

  kubectl -n kube-system wait pod "$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null 2>&1
  result=$(kubectl -n kube-system logs "$pod" 2>/dev/null | tail -1)
  kubectl -n kube-system delete pod "$pod" --wait=false >/dev/null 2>&1

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

task_disable_selinuxfs() {
  log "Task 2/8: disable_selinuxfs"
  if [ "$SKIP_SELINUX_FIX" = "true" ]; then
    info "skipped, SKIP_SELINUX_FIX=true"
    return 0
  fi

  local node result changed=0
  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    result=$(fix_selinuxfs_on_node "$node") || fail "SELinux check failed on ${node}, check: kubectl -n kube-system describe pod kubevirt-selinux-fix-${node}"
    case "$result" in
      unmounted)     info "${node}: selinuxfs mounted with no policy loaded, unmounted it"; changed=1 ;;
      not-mounted)   info "${node}: selinuxfs not mounted, nothing to do" ;;
      policy-loaded) info "${node}: real SELinux policy loaded, left as is" ;;
      *)             fail "unexpected result on ${node}: ${result}" ;;
    esac
  done

  # virt-handler may have started while selinuxfs was still mounted.
  if [ "$changed" -eq 1 ] && kubectl -n kubevirt get ds virt-handler >/dev/null 2>&1; then
    info "restarting virt-handler so it picks up the change"
    kubectl -n kubevirt rollout restart ds/virt-handler >/dev/null
    kubectl -n kubevirt rollout status ds/virt-handler --timeout=300s >/dev/null \
      || fail "virt-handler did not restart, check: kubectl -n kubevirt get pods -l kubevirt.io=virt-handler"
  fi
}

task_label_nodes() {
  log "Task 3/8: label_nodes"
  local nodes="$KUBEVIRT_NODES"

  if [ -z "$nodes" ]; then
    nodes=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}')
  fi
  if [ -z "$nodes" ]; then
    info "no worker nodes found, labeling every node"
    nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
  fi

  for node in $nodes; do
    kubectl label node "$node" "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" --overwrite >/dev/null \
      || fail "could not label node ${node}"
    info "labeled ${node} ${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}"
  done
}

task_install_operator() {
  log "Task 4/8: install_operator"
  # Server-side apply: the KubeVirt CRDs are too large for client-side apply annotations,
  # and unlike "kubectl create" it can run again without AlreadyExists errors.
  kubectl apply --server-side --force-conflicts -f "${MANIFEST_DIR}/kubevirt-operator.yaml" >/dev/null \
    || fail "applying kubevirt-operator.yaml failed"
  info "operator manifests applied"
  kubectl -n kubevirt rollout status deploy/virt-operator --timeout=300s \
    || fail "virt-operator did not become ready, check: kubectl -n kubevirt describe pod -l kubevirt.io=virt-operator"
}

task_install_kubevirt() {
  log "Task 5/8: install_kubevirt"
  kubectl apply --server-side --force-conflicts -f "${MANIFEST_DIR}/kubevirt-cr.yaml" >/dev/null \
    || fail "applying kubevirt-cr.yaml failed"
  info "KubeVirt CR applied, waiting up to ${WAIT_TIMEOUT}s for Available"
  kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout="${WAIT_TIMEOUT}s" \
    || fail "KubeVirt not Available, check: kubectl -n kubevirt get pods -o wide"
  kubectl -n kubevirt get pods -o wide
}

# Prints one "node=<kvm device count>" line per labeled node.
# The count is empty until virt-handler on that node has reported it.
kvm_counts() {
  kubectl get nodes -l "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.allocatable.devices\.kubevirt\.io/kvm}{"\n"}{end}'
}

kvm_reported_on_all_labeled_nodes() {
  local counts
  counts=$(kvm_counts)
  [ -n "$counts" ] && ! printf '%s\n' "$counts" | grep -q '=$'
}

# True only when every labeled node reports a non-zero KVM device count.
labeled_nodes_have_kvm() {
  local counts
  counts=$(kvm_counts)
  [ -n "$counts" ] && ! printf '%s\n' "$counts" | grep -q -e '=$' -e '=0$'
}

emulation_enabled() {
  [ "$(kubectl -n kubevirt get kubevirt kubevirt \
    -o jsonpath='{.spec.configuration.developerConfiguration.useEmulation}')" = "true" ]
}

task_configure_emulation() {
  log "Task 6/8: configure_emulation"

  if emulation_enabled; then
    info "useEmulation is already true, nothing to do"
    return 0
  fi

  if [ "$FORCE_EMULATION" != "true" ]; then
    # virt-handler reports the KVM device a few seconds after it starts.
    wait_until 60 kvm_reported_on_all_labeled_nodes || info "KVM device count not reported yet, treating as 0"
    if labeled_nodes_have_kvm; then
      info "/dev/kvm found on the labeled nodes, emulation not needed"
      return 0
    fi
    info "no /dev/kvm on the labeled nodes"
  else
    info "FORCE_EMULATION=true"
  fi

  kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
    --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}' >/dev/null \
    || fail "could not turn on useEmulation"
  info "useEmulation turned on, VMs will run with software emulation (slow)"
}

task_install_virtctl() {
  log "Task 7/8: install_virtctl"
  local version os arch target

  version=$(kubectl -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.observedKubeVirtVersion}')
  [ -n "$version" ] || fail "could not read the KubeVirt version from the cluster"

  if command -v virtctl >/dev/null 2>&1 && virtctl version --client 2>/dev/null | grep -q "GitVersion:\"${version}\""; then
    info "virtctl ${version} already installed"
    return 0
  fi

  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in
    x86_64)        arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)             fail "unsupported CPU architecture: $(uname -m)" ;;
  esac

  target=$(mktemp)
  info "downloading virtctl ${version} for ${os}-${arch}"
  curl -fsSL -o "$target" \
    "https://github.com/kubevirt/kubevirt/releases/download/${version}/virtctl-${version}-${os}-${arch}" \
    || fail "virtctl download failed"

  if [ -w /usr/local/bin ]; then
    install -m 0755 "$target" /usr/local/bin/virtctl
  else
    sudo install -m 0755 "$target" /usr/local/bin/virtctl
  fi
  rm -f "$target"
  virtctl version --client
}

task_create_test_vm() {
  log "Task 8/8: create_test_vm"
  if [ "$CREATE_TEST_VM" != "true" ]; then
    info "skipped, set CREATE_TEST_VM=true to run it"
    return 0
  fi

  kubectl apply -f "${MANIFEST_DIR}/testvm.yaml" >/dev/null || fail "applying testvm.yaml failed"
  info "testvm applied, waiting up to 600s for it to be Ready"
  kubectl wait vmi testvm --for=condition=Ready --timeout=600s \
    || fail "testvm not Ready, check: kubectl describe vmi testvm"
  kubectl get vmi testvm -o wide
  info "connect with: virtctl console testvm   (user cirros, password gocubsgo, leave with Ctrl+])"
}

main() {
  preflight
  task_wait_for_nodes
  task_disable_selinuxfs
  task_label_nodes
  task_install_operator
  task_install_kubevirt
  task_configure_emulation
  task_install_virtctl
  task_create_test_vm
  log "Done"
  kubectl -n kubevirt get kubevirt kubevirt \
    -o custom-columns=PHASE:.status.phase,VERSION:.status.observedKubeVirtVersion,EMULATION:.spec.configuration.developerConfiguration.useEmulation
}

main "$@"
