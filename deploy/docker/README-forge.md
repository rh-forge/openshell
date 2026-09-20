# rh-forge build of the ODH OpenShell images

`Dockerfile.gha.{gateway,supervisor,cli}` are GitHub Actions ports of the
Konflux Dockerfiles (`Dockerfile.konflux.*`) at `v0.0.116-rhaiv.0`. They keep
the same UBI 9.8 base images, packages, cargo features, static-linking flags,
binary paths, users and labels. The only differences:

- The Rust 1.92.0 toolchain and the Z3 4.16.0 source are downloaded from the
  URLs pinned in `deploy/konflux/*/generic-fetcher.yaml` and verified against
  the same sha256, instead of being read from the Hermeto prefetch directory.
  The Konflux gateway image takes Rust from the UBI AppStream `rust`/`cargo`
  RPMs (also 1.92.0); the GitHub Actions gateway uses the same upstream
  tarball as the supervisor and CLI so all three binaries share one compiler
  regardless of UBI repository drift, and installs `xz` to extract it.
- Cargo registry and target directories use BuildKit cache mounts.
- Gateway and supervisor build with `--locked`.

`.github/workflows/publish-odh-images.yml` builds all three for `linux/amd64`
on tag pushes matching `v*-forge.*` (or by dispatch) and publishes
`ghcr.io/rh-forge/odh-openshell-{gateway,supervisor,cli}:<tag>` plus
`:sha-<commit>`. The tag, minus the leading `v`, is stamped into every binary
through `OPENSHELL_VERSION`, so all three report the same version string.

## Forward connection sweep (`forward-sweep.yml`)

`.github/workflows/forward-sweep.yml` (manual dispatch) measures the cost of
`openshell forward service` connections end to end on a hosted runner, once
with the published opendatahub images (`quay.io/opendatahub/odh-openshell-*`,
baseline: SQLite rollback journal) and once with a gateway that carries the
patch under test (SQLite store in WAL + `synchronous=NORMAL`), then prints a
before/after table in the run summary. It is the evidence for
[NVIDIA/OpenShell#3494](https://github.com/NVIDIA/OpenShell/issues/3494).

The patched gateway comes from one of two places, chosen by the
`patched_source` input:

- `build` (default, needs no credentials, so anyone with a fork can run it):
  the gateway image is built on the runner from the checkout with
  `deploy/docker/Dockerfile.gha.gateway` (about 30-60 min cold on 4 vCPU) and
  tagged `localhost/odh-openshell-gateway:patched`. The patched set then uses
  that gateway with the public baseline CLI and supervisor images. All of them
  come from the same source commit; only the gateway differs, which is exactly
  the change under test.
- `image`: pull `ghcr.io/rh-forge/odh-openshell-{gateway,supervisor,cli}:<patched_tag>`
  (org-internal packages, so this only works from the rh-forge organisation).

Both sets run back to back on the same runner, each with a fresh state
directory (`scripts/forward-sweep/run-set.sh`), so the disk commit cost is the
same for both. Per set: the gateway and CLI binaries are extracted from the
images; a single-node gateway runs on the runner with the Docker compute
driver, mTLS from `openshell-gateway generate-certs`, and a file-backed SQLite
database on the runner disk; the set's supervisor image is pre-pulled (the
gateway extracts the supervisor through the Docker API, which has no registry
credentials); a sandbox built from `python:3.13-slim` plus `iproute2` serves
loopback HTTP; `scripts/forward-sweep/sweep.py` then opens bursts of 1, 6, 16,
32 and 64 simultaneous connections (twice each) plus 10 sequential ones
through the forward and records wall time, completions and mean latency. The
job also reports the raw `fdatasync`/`dd oflag=dsync` cost of the runner disk,
the number of `connection limit reached` refusals in the forward log, the
`PRAGMA journal_mode` of the gateway database (`delete` for baseline, `wal`
for patched) and the number of sqlx `slow statement` warnings the gateway
logged. Raw logs and `results.json` are uploaded as one artifact; the final
step merges both sets into one table in the run summary.

### Running it by hand

`scripts/forward-sweep/run-set.sh` runs on any x86-64 Linux host with Docker,
`python3`, `curl` and `file`; it needs nothing else from the repository except
`sweep.py` next to it. It binds 127.0.0.1:17670/17671 (gateway) and
127.0.0.1:43152 (forward) and cleans up its sandbox and gateway on exit. Images
that already exist locally are used as they are, so a locally built gateway
image works too:

```sh
# Optional: build the patched gateway from this checkout instead of pulling it.
docker buildx build --load -t localhost/odh-openshell-gateway:patched \
  --build-arg OPENSHELL_VERSION=v0.0.116-rhaiv.0-patched \
  -f deploy/docker/Dockerfile.gha.gateway .

SET_NAME=baseline OUT_DIR=/tmp/sweep/baseline \
  GATEWAY_IMAGE=quay.io/opendatahub/odh-openshell-gateway:v0.0.116-rhaiv.0 \
  SUPERVISOR_IMAGE=quay.io/opendatahub/odh-openshell-supervisor:v0.0.116-rhaiv.0 \
  CLI_IMAGE=quay.io/opendatahub/odh-openshell-cli:v0.0.116-rhaiv.0 \
  scripts/forward-sweep/run-set.sh

SET_NAME=patched OUT_DIR=/tmp/sweep/patched \
  GATEWAY_IMAGE=localhost/odh-openshell-gateway:patched \
  SUPERVISOR_IMAGE=quay.io/opendatahub/odh-openshell-supervisor:v0.0.116-rhaiv.0 \
  CLI_IMAGE=quay.io/opendatahub/odh-openshell-cli:v0.0.116-rhaiv.0 \
  scripts/forward-sweep/run-set.sh

python3 scripts/forward-sweep/report.py \
  --baseline /tmp/sweep/baseline/results.json \
  --patched /tmp/sweep/patched/results.json
```

Each `OUT_DIR` receives `results.json`, `summary.md`, `gateway.log`,
`forward.log` and the generated `gateway.toml`.
