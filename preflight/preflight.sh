#!/usr/bin/env bash
# clusterfactory preflight (ADR 0014): the executable contract between the
# forge package and any cluster. Runs as a Zarf action on the operator's
# machine using `./zarf tools kubectl`; also runnable by hand:
#   ZARF=zarf preflight/preflight.sh
#
# Every check is one line `# CHECK: <id> | <class> | <what must hold>`
# so PREREQUISITES.md is generated from this file (hack/gen-prerequisites.py).
# Classes: contract (never bypassable), advisory (skipped with
# PREFLIGHT_STRICT=false), profile (hard or soft depending on the active
# policy profile; soft without one).
#
# Results: one `ok|FAIL|WARN <id> - <detail>` line per check, a JSON summary
# on stdout, the same JSON in ConfigMap cf-system/cf-preflight-result, and
# a non-zero exit if any hard check failed.
set -uo pipefail

ZARF="${ZARF:-./zarf}"
K() { "$ZARF" tools kubectl "$@"; }
STRICT="${PREFLIGHT_STRICT:-true}"
IMAGE="${PREFLIGHT_IMAGE:?PREFLIGHT_IMAGE (the test image listed in the package) is required}"
NS="cf-preflight-$RANDOM"
MIN_K8S_MINOR=30
RESULTS=()   # "id|class|status|detail"
FAILED_HARD=0

profile_value() {  # profile_value <key> <default>: read from the policy profile ConfigMap if present
  local v
  v=$(K get configmap cf-policy-profile -n cf-system -o "jsonpath={.data.$1}" 2>/dev/null || true)
  echo "${v:-$2}"
}

record() {  # record <id> <class> <status ok|FAIL|WARN> <detail>
  RESULTS+=("$1|$2|$3|$4")
  printf '%-4s %-26s - %s\n' "$3" "$1" "$4"
}

check() {  # check <id> <class> <detail-on-success> <detail-on-failure> <command...>
  local id="$1" class="$2" okmsg="$3" failmsg="$4"; shift 4
  if "$@" >/dev/null 2>&1; then
    record "$id" "$class" ok "$okmsg"
  else
    local status=FAIL
    case "$class" in
      advisory) [[ "$STRICT" == "true" ]] || status=WARN ;;
      profile-soft) status=WARN ;;
    esac
    [[ "$status" == FAIL ]] && FAILED_HARD=1
    record "$id" "$class" "$status" "$failmsg"
  fi
}

# Restricted-compliant throwaway pod; prints its last log line, exits non-zero if the command failed.
pod_run() {  # pod_run <name> <sh -c command>
  local name="$1" cmd="$2"
  K run "$name" -n "$NS" --restart=Never --quiet --image="$IMAGE" --image-pull-policy=IfNotPresent \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"runAsGroup":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"t","image":"'"$IMAGE"'","command":["sh","-c",'"$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"'],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null 2>&1 || return 2
  local phase=""
  for _ in $(seq 1 45); do
    phase=$(K get pod "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 2
  done
  K logs "$name" -n "$NS" 2>/dev/null | tail -1
  [[ "$phase" == Succeeded ]]
}

cleanup() { K delete namespace "$NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== clusterfactory preflight (strict=$STRICT, image=$IMAGE)"
K create namespace "$NS" >/dev/null 2>&1 || { echo "FAIL cannot create a namespace - is the cluster reachable and are you cluster-admin?"; exit 1; }
K create namespace cf-system >/dev/null 2>&1 || true
# The Zarf agent rewrites the test image to the internal registry and adds the
# `private-registry` pull secret reference, but that Secret only exists in
# namespaces Zarf has deployed into. Copy it into the throwaway namespace.
K get secret private-registry -n zarf -o json 2>/dev/null \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); s["metadata"]={"name":"private-registry"}; print(json.dumps(s))' \
  | K apply -n "$NS" -f - >/dev/null 2>&1 || true

# CHECK: kubernetes-version | contract | Kubernetes >= 1.30 and the API server reachable
minor=$(K version -o json 2>/dev/null | python3 -c 'import json,sys;print(int(json.load(sys.stdin)["serverVersion"]["minor"].rstrip("+")))' 2>/dev/null || echo 0)
check kubernetes-version contract "server minor $minor" "server minor '$minor' < $MIN_K8S_MINOR or unreachable" test "$minor" -ge "$MIN_K8S_MINOR"

# CHECK: node-ready | contract | at least one node Ready
ready=$(K get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null | grep -c True)
check node-ready contract "$ready node(s) Ready" "no Ready node" test "$ready" -ge 1

# CHECK: zarf-init | contract | zarf init done (zarf-state present) and the Zarf registry reachable from a pod
reg_host=$(K get secret zarf-state -n zarf -o jsonpath='{.data.state}' 2>/dev/null | base64 -d 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["registryInfo"]["address"])' 2>/dev/null || true)
if [[ -z "$reg_host" ]]; then
  record zarf-init contract FAIL "zarf-state secret missing - run zarf init first"; FAILED_HARD=1
else
  check zarf-init contract "registry $reg_host, reachable from a pod" "registry $reg_host not reachable from a pod (agent rewrites images to it)" \
    pod_run reg 'nc -z -w 5 zarf-docker-registry.zarf.svc.cluster.local 5000 && echo reachable'
fi

# CHECK: cluster-dns | contract | cluster DNS resolves Service names from a pod
# busybox nslookup ignores the search list, so build the FQDN from the pod's resolv.conf (cluster domain may not be cluster.local)
check cluster-dns contract "kubernetes.default.svc.<cluster-domain> resolves" "kubernetes.default.svc does not resolve from a pod" \
  pod_run dns 'd=$(awk "/^search/{for(i=2;i<=NF;i++) if(\$i ~ /^svc\./){print substr(\$i,5); exit}}" /etc/resolv.conf); nslookup "kubernetes.default.svc.${d:-cluster.local}" >/dev/null && echo resolved'

# CHECK: default-storageclass | contract | a default StorageClass exists and a 1Gi PVC binds
sc=$(K get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
pvc_binds() {
  [[ -n "$sc" ]] || return 1
  # A consumer pod mounting the claim: WaitForFirstConsumer provisioners bind only then.
  K apply -f - >/dev/null 2>&1 <<YAML || return 1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: t, namespace: $NS}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: pvc, namespace: $NS}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: t
      image: "$IMAGE"
      command: ["sh", "-c", "touch /data/ok && echo mounted"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: t}}]
YAML
  for _ in $(seq 1 45); do
    [[ "$(K get pvc t -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == Bound && "$(K get pod pvc -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == Succeeded ]] && return 0
    sleep 2
  done
  return 1
}
check default-storageclass contract "default StorageClass '$sc', PVC bound" "no default StorageClass or PVC did not bind (default: '${sc:-none}')" pvc_binds

# CHECK: pod-security-admission | contract | Pod Security Admission is active (a privileged pod is rejected under `restricted`)
psa_active() {
  K label namespace "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null 2>&1 || return 1
  out=$(printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: priv, namespace: %s}\nspec: {containers: [{name: p, image: "%s", securityContext: {privileged: true}}]}\n' "$NS" "$IMAGE" | K apply -f - 2>&1)
  K label namespace "$NS" pod-security.kubernetes.io/enforce- >/dev/null 2>&1 || true
  grep -q "violates PodSecurity" <<<"$out"
}
check pod-security-admission contract "privileged pod rejected under restricted" "privileged pod was admitted under a restricted label - PSA not enforcing" psa_active

# CHECK: apiserver-endpoint | contract | the kubernetes EndpointSlice resolves to IPv4 addresses the egress policy can allow by ipBlock
api_ip=$(K get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null)
api_port=$(K get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].ports[0].port}' 2>/dev/null)
check apiserver-endpoint contract "API server at $api_ip:$api_port" "no IPv4 API server endpoint found ('$api_ip')" bash -c '[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]' _ "$api_ip"

# CHECK: networkpolicy-enforcement | contract | the CNI enforces NetworkPolicy (positive control reaches the API server; after deny-all it must not)
np_enforced() {
  [[ -n "$api_ip" ]] || return 1
  pod_run np-control "nc -z -w 5 $api_ip $api_port && echo connected" | grep -q connected || return 1   # positive control
  printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: {name: deny-all, namespace: %s}\nspec: {podSelector: {}, policyTypes: [Egress]}\n' "$NS" | K apply -f - >/dev/null 2>&1 || return 1
  sleep 3
  ! pod_run np-denied "nc -z -w 5 $api_ip $api_port && echo connected" | grep -q connected
}
check networkpolicy-enforcement contract "deny-all blocked a connection that succeeded before" "NetworkPolicy is NOT enforced (or the positive control failed) - the airgap guarantees would be silently void" np_enforced

# CHECK: resources | advisory | allocatable >= 4 CPU and 8 GiB on the largest node
cpu=$(K get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' | sed 's/m$//' | sort -n | tail -1)
mem=$(K get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' | sed 's/Ki$//' | sort -n | tail -1)
mem_gib=$(( ${mem:-0} / 1048576 ))
cpu_cores=${cpu:-0}; [[ "$cpu_cores" =~ ^[0-9]+$ ]] && [[ ${#cpu_cores} -gt 3 ]] && cpu_cores=$(( cpu_cores / 1000 ))
check resources advisory "largest node: ${cpu_cores} CPU, ${mem_gib} GiB" "largest node has ${cpu_cores} CPU / ${mem_gib} GiB; Gitea + Jenkins + Nexus + a build want 4 CPU / 8 GiB" \
  bash -c '[[ "$1" -ge 4 && "$2" -ge 8 ]]' _ "$cpu_cores" "$mem_gib"

# CHECK: internet-unreachable | profile | pods cannot reach the internet (hard under a profile that says so, otherwise a warning)
cls=profile-soft; [[ "$(profile_value internetReachableIsFailure false)" == true ]] && cls=profile-hard
inet_unreachable() { ! pod_run inet 'nc -z -w 3 1.1.1.1 443 && echo reachable' | grep -q reachable; }
check internet-unreachable "$cls" "no route to the internet from a pod" "a pod reached the internet - this cluster is not airgapped" inet_unreachable

# ---- results
json=$(printf '%s\n' "${RESULTS[@]}" | python3 -c '
import json, sys, datetime
rows = [l.rstrip("\n").split("|", 3) for l in sys.stdin if l.strip()]
print(json.dumps({"strict": sys.argv[1] == "true", "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                  "hardFailures": sys.argv[2] == "1",
                  "checks": [{"id": r[0], "class": r[1], "status": r[2], "detail": r[3]} for r in rows]}, indent=1))' "$STRICT" "$FAILED_HARD")
echo "$json"
K create configmap cf-preflight-result -n cf-system --from-literal=result.json="$json" --dry-run=client -o yaml | K apply -f - >/dev/null 2>&1 || true
if [[ "$FAILED_HARD" == 1 ]]; then
  echo "FAIL: preflight found conditions the forge cannot deploy under (see above; PREREQUISITES.md)"; exit 1
fi
echo "ok: preflight passed"
