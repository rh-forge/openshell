#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Bring up a single-node OpenShell gateway from a published image set on this
# host (Docker compute driver, mTLS, file-backed SQLite), create a sandbox that
# serves loopback HTTP, run `openshell forward service` against it and measure
# the per-connection cost with scripts/forward-sweep/sweep.py.
#
# Required environment:
#   SET_NAME          label for this image set (baseline | patched)
#   GATEWAY_IMAGE     image providing /usr/local/bin/openshell-gateway
#   SUPERVISOR_IMAGE  image providing /openshell-sandbox (referenced by the gateway)
#   CLI_IMAGE         image providing /usr/local/bin/openshell
#   OUT_DIR           directory that receives results.json, logs and summary.md
# Optional:
#   WORK_DIR          scratch/state root (default: mktemp under $RUNNER_TEMP or /tmp)
#   GATEWAY_PORT      default 17670   HEALTH_PORT default 17671
#   TARGET_PORT       loopback HTTP port inside the sandbox, default 63152
#   LOCAL_PORT        local forward port, default 43152

set -Eeuo pipefail

: "${SET_NAME:?}" "${GATEWAY_IMAGE:?}" "${SUPERVISOR_IMAGE:?}" "${CLI_IMAGE:?}" "${OUT_DIR:?}"
GATEWAY_PORT="${GATEWAY_PORT:-17670}"
HEALTH_PORT="${HEALTH_PORT:-17671}"
TARGET_PORT="${TARGET_PORT:-63152}"
LOCAL_PORT="${LOCAL_PORT:-43152}"
SANDBOX_NAME="probe"
SANDBOX_NAMESPACE="forward-sweep"
PROBE_IMAGE="localhost/openshell-forward-probe:sweep"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="${WORK_DIR:-$(mktemp -d "${RUNNER_TEMP:-/tmp}/forward-sweep-${SET_NAME}.XXXXXX")}"
BIN="${WORK_DIR}/bin"
TLS="${WORK_DIR}/tls"
export XDG_CONFIG_HOME="${WORK_DIR}/config"
export XDG_STATE_HOME="${WORK_DIR}/state"
export XDG_DATA_HOME="${WORK_DIR}/data"
export OPENSHELL_TELEMETRY_ENABLED=false
DB_DIR="${XDG_STATE_HOME}/openshell/gateway"
DB_PATH="${DB_DIR}/openshell.db"
GATEWAY_LOG="${WORK_DIR}/gateway.log"
FORWARD_LOG="${WORK_DIR}/forward.log"
mkdir -p "${BIN}" "${XDG_CONFIG_HOME}" "${XDG_STATE_HOME}" "${XDG_DATA_HOME}" "${DB_DIR}" "${OUT_DIR}"

GATEWAY_PID=""
FORWARD_PID=""
GW="${BIN}/openshell-gateway"
CLI="${BIN}/openshell"

log() { printf '\n==> %s\n' "$*"; }

dump_diagnostics() {
  log "sandbox containers (namespace ${SANDBOX_NAMESPACE})"
  local ids
  ids="$(docker ps -aq --filter "label=openshell.ai/sandbox-namespace=${SANDBOX_NAMESPACE}" 2>/dev/null || true)"
  for id in ${ids}; do
    docker inspect --format '{{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' "${id}" || true
    docker logs --tail 80 "${id}" 2>&1 || true
  done
  log "gateway log (tail)"; tail -n 120 "${GATEWAY_LOG}" 2>/dev/null || true
  log "forward log (tail)"; tail -n 40 "${FORWARD_LOG}" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  set +e
  if [ "${rc}" -ne 0 ]; then dump_diagnostics; fi
  if [ -n "${FORWARD_PID}" ]; then kill "${FORWARD_PID}" 2>/dev/null; wait "${FORWARD_PID}" 2>/dev/null; fi
  if [ -n "${GATEWAY_PID}" ] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    timeout 60 "${CLI}" sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1
    kill "${GATEWAY_PID}" 2>/dev/null
    for _ in $(seq 1 60); do kill -0 "${GATEWAY_PID}" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "${GATEWAY_PID}" 2>/dev/null
    wait "${GATEWAY_PID}" 2>/dev/null
  fi
  local stale
  stale="$(docker ps -aq --filter "label=openshell.ai/sandbox-namespace=${SANDBOX_NAMESPACE}" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [ -n "${stale}" ] && docker rm -f ${stale} >/dev/null 2>&1
  cp -f "${GATEWAY_LOG}" "${FORWARD_LOG}" "${WORK_DIR}"/*.json "${WORK_DIR}/gateway.toml" "${OUT_DIR}/" 2>/dev/null
  exit "${rc}"
}
trap cleanup EXIT

extract() {
  local image=$1 path=$2 dest=$3 cid
  cid="$(docker create "${image}")"
  docker cp "${cid}:${path}" "${dest}"
  docker rm -f "${cid}" >/dev/null
  chmod +x "${dest}"
}

log "pulling ${SET_NAME} images"
docker pull --platform linux/amd64 "${GATEWAY_IMAGE}"
docker pull --platform linux/amd64 "${CLI_IMAGE}"
# The gateway extracts the supervisor from this image through the Docker API,
# which carries no registry credentials, so it must already be present locally.
docker pull --platform linux/amd64 "${SUPERVISOR_IMAGE}"

log "extracting binaries"
extract "${GATEWAY_IMAGE}" /usr/local/bin/openshell-gateway "${GW}"
extract "${CLI_IMAGE}" /usr/local/bin/openshell "${CLI}"
file "${GW}" "${CLI}"
ldd "${GW}" || true
GATEWAY_VERSION="$("${GW}" --version)"
CLI_VERSION="$("${CLI}" --version)"
echo "${GATEWAY_VERSION} / ${CLI_VERSION}"

log "building probe sandbox image ${PROBE_IMAGE}"
# Same shape as the e2e custom-image fixtures: python slim plus iproute2 (the
# supervisor needs it for network-namespace setup) and a non-root user.
mkdir -p "${WORK_DIR}/probe"
cat >"${WORK_DIR}/probe/Dockerfile" <<'EOF'
FROM public.ecr.aws/docker/library/python:3.13-slim
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1235 appstaff && useradd -m -u 1234 -g appstaff app
WORKDIR /workspace/project
RUN chown app:appstaff .
USER app
CMD ["sleep", "infinity"]
EOF
docker build -q -t "${PROBE_IMAGE}" "${WORK_DIR}/probe"

log "raw disk commit cost on ${DB_DIR}"
python3 - "${DB_DIR}" >"${WORK_DIR}/fsync.json" <<'PY'
import json, os, statistics, sys, time
path = os.path.join(sys.argv[1], "fsync-probe.bin")
fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
samples = []
block = b"\0" * 4096
for _ in range(200):
    t = time.perf_counter()
    os.write(fd, block)
    os.fdatasync(fd)
    samples.append((time.perf_counter() - t) * 1000)
os.close(fd)
os.unlink(path)
print(json.dumps({"fdatasync_mean_ms": round(statistics.fmean(samples), 3),
                  "fdatasync_p50_ms": round(statistics.median(samples), 3),
                  "fdatasync_max_ms": round(max(samples), 3)}))
PY
cat "${WORK_DIR}/fsync.json"
DD_OUT="$( { dd if=/dev/zero of="${DB_DIR}/dd-probe.bin" bs=4k count=200 oflag=dsync; } 2>&1 | tail -n 1 )"
rm -f "${DB_DIR}/dd-probe.bin"
echo "dd: ${DD_OUT}"
df -hT "${DB_DIR}" | tail -n 1

log "generating mTLS material and registering the CLI gateway"
"${GW}" generate-certs --output-dir "${TLS}" --server-san host.openshell.internal
GW_CONF="${XDG_CONFIG_HOME}/openshell/gateways/openshell"
mkdir -p "${GW_CONF}/mtls"
for f in ca.crt tls.crt tls.key; do
  if [ ! -f "${GW_CONF}/mtls/${f}" ]; then
    case "${f}" in
      ca.crt) cp "${TLS}/ca.crt" "${GW_CONF}/mtls/${f}" ;;
      *) cp "${TLS}/client/${f}" "${GW_CONF}/mtls/${f}" ;;
    esac
  fi
done
cat >"${GW_CONF}/metadata.json" <<EOF
{"name":"openshell","gateway_endpoint":"https://127.0.0.1:${GATEWAY_PORT}","is_remote":false,"gateway_port":${GATEWAY_PORT},"auth_mode":"mtls"}
EOF
printf '%s' openshell >"${XDG_CONFIG_HOME}/openshell/active_gateway"
export OPENSHELL_GATEWAY=openshell

cat >"${WORK_DIR}/gateway.toml" <<EOF
[openshell]
version = 1

[openshell.gateway]
log_level = "info"
compute_drivers = ["docker"]

[openshell.gateway.mtls_auth]
enabled = true

[openshell.drivers.docker]
default_image = "${PROBE_IMAGE}"
image_pull_policy = "IfNotPresent"
sandbox_namespace = "${SANDBOX_NAMESPACE}"
supervisor_image = "${SUPERVISOR_IMAGE}"
grpc_endpoint = "https://host.openshell.internal:${GATEWAY_PORT}"
guest_tls_ca = "${TLS}/ca.crt"
guest_tls_cert = "${TLS}/client/tls.crt"
guest_tls_key = "${TLS}/client/tls.key"
EOF

log "starting gateway (${GATEWAY_IMAGE})"
OPENSHELL_LOCAL_TLS_DIR="${TLS}" OPENSHELL_DRIVERS=docker \
  "${GW}" --config "${WORK_DIR}/gateway.toml" \
    --bind-address 127.0.0.1 --port "${GATEWAY_PORT}" --health-port "${HEALTH_PORT}" \
    --db-url "sqlite:${DB_PATH}?mode=rwc" \
    >"${GATEWAY_LOG}" 2>&1 &
GATEWAY_PID=$!
for i in $(seq 1 120); do
  kill -0 "${GATEWAY_PID}" 2>/dev/null || { echo "gateway exited"; exit 1; }
  curl -sf "http://127.0.0.1:${HEALTH_PORT}/healthz" >/dev/null 2>&1 && { echo "healthy after ${i}s"; break; }
  [ "${i}" -eq 120 ] && { echo "gateway not healthy after 120s"; exit 1; }
  sleep 1
done
"${CLI}" sandbox list

log "creating sandbox ${SANDBOX_NAME} serving HTTP on 127.0.0.1:${TARGET_PORT}"
timeout 600 "${CLI}" sandbox create --name "${SANDBOX_NAME}" --from "${PROBE_IMAGE}" \
  --no-auto-providers --detach -- \
  sh -lc "exec python3 -m http.server ${TARGET_PORT} --bind 127.0.0.1"
for i in $(seq 1 180); do
  phase="$("${CLI}" sandbox get "${SANDBOX_NAME}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("phase",""))' 2>/dev/null || true)"
  [ "${phase}" = "Ready" ] && { echo "sandbox Ready after ${i}s"; break; }
  [ "${i}" -eq 180 ] && { echo "sandbox phase '${phase}' after 180s"; exit 1; }
  sleep 1
done

log "starting forward 127.0.0.1:${LOCAL_PORT} -> sandbox 127.0.0.1:${TARGET_PORT}"
"${CLI}" forward service "${SANDBOX_NAME}" --target-host 127.0.0.1 --target-port "${TARGET_PORT}" \
  --local "127.0.0.1:${LOCAL_PORT}" >"${FORWARD_LOG}" 2>&1 &
FORWARD_PID=$!
for i in $(seq 1 90); do
  kill -0 "${FORWARD_PID}" 2>/dev/null || { echo "forward exited"; exit 1; }
  curl -sf -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/" && { echo "forward serving after ${i}s"; break; }
  [ "${i}" -eq 90 ] && { echo "forward not serving after 90s"; exit 1; }
  sleep 1
done
sleep 3

log "sweep"
python3 "${HERE}/sweep.py" --port "${LOCAL_PORT}" --out "${WORK_DIR}/sweep.json" | tee "${WORK_DIR}/sweep.txt"
sleep 3

log "post-run evidence"
LIMIT_HITS="$(grep -c 'connection limit reached' "${FORWARD_LOG}" || true)"
FORWARD_WARNINGS="$(grep -c 'service forward' "${FORWARD_LOG}" || true)"
echo "connection limit reached: ${LIMIT_HITS} (forward warnings: ${FORWARD_WARNINGS})"
ls -la "${DB_DIR}"
JOURNAL_MODE="$(python3 -c '
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(conn.execute("PRAGMA journal_mode").fetchone()[0])
' "${DB_PATH}")"
SIDECARS="$(find "${DB_DIR}" -maxdepth 1 -name 'openshell.db*' -printf '%f\n' | sort | tr '\n' ' ')"
echo "journal_mode=${JOURNAL_MODE} sidecars=${SIDECARS}"

SET_NAME="${SET_NAME}" GATEWAY_IMAGE="${GATEWAY_IMAGE}" SUPERVISOR_IMAGE="${SUPERVISOR_IMAGE}" \
CLI_IMAGE="${CLI_IMAGE}" GATEWAY_VERSION="${GATEWAY_VERSION}" CLI_VERSION="${CLI_VERSION}" \
JOURNAL_MODE="${JOURNAL_MODE}" SIDECARS="${SIDECARS}" DD_OUT="${DD_OUT}" \
LIMIT_HITS="${LIMIT_HITS}" FORWARD_WARNINGS="${FORWARD_WARNINGS}" \
python3 - "${WORK_DIR}" "${OUT_DIR}" <<'PY'
import json, os, platform, sys
work, out = sys.argv[1], sys.argv[2]
env = os.environ
fsync = json.load(open(os.path.join(work, "fsync.json")))
sweep = json.load(open(os.path.join(work, "sweep.json")))
result = {
    "set": env["SET_NAME"],
    "gateway_image": env["GATEWAY_IMAGE"],
    "supervisor_image": env["SUPERVISOR_IMAGE"],
    "cli_image": env["CLI_IMAGE"],
    "gateway_version": env["GATEWAY_VERSION"],
    "cli_version": env["CLI_VERSION"],
    "journal_mode": env["JOURNAL_MODE"],
    "db_sidecars": env["SIDECARS"].strip(),
    "fsync_mean_ms": fsync["fdatasync_mean_ms"],
    "fsync_p50_ms": fsync["fdatasync_p50_ms"],
    "fsync_max_ms": fsync["fdatasync_max_ms"],
    "dd_dsync": env["DD_OUT"],
    "limit_hits": int(env["LIMIT_HITS"] or 0),
    "forward_warnings": int(env["FORWARD_WARNINGS"] or 0),
    "runner": f"{platform.node()} {platform.release()}",
    "sweep": sweep,
}
json.dump(result, open(os.path.join(out, "results.json"), "w"), indent=2)
lines = [
    f"### {result['set']}: {result['gateway_image']}",
    "",
    f"- gateway: `{result['gateway_version']}`, journal_mode: **{result['journal_mode']}**, sidecars: `{result['db_sidecars']}`",
    f"- fdatasync 4 KiB: mean {result['fsync_mean_ms']} ms, p50 {result['fsync_p50_ms']} ms, max {result['fsync_max_ms']} ms; dd oflag=dsync: {result['dd_dsync']}",
    f"- `connection limit reached` in forward log: {result['limit_hits']}",
    "",
]
lines += open(os.path.join(work, "sweep.txt")).read().split("\n\n", 1)[1].splitlines()
lines.append("")
summary = "\n".join(lines)
open(os.path.join(out, "summary.md"), "w").write(summary)
step = os.environ.get("GITHUB_STEP_SUMMARY")
if step:
    open(step, "a").write(summary + "\n")
print(summary)
PY
