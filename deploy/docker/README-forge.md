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
with the opendatahub images (`quay.io/opendatahub/odh-openshell-*`, baseline)
and once with the rh-forge images (`ghcr.io/rh-forge/odh-openshell-*`, patched:
SQLite store in WAL + `synchronous=NORMAL`), then prints a before/after table
in the run summary. It is the evidence for
[NVIDIA/OpenShell#3494](https://github.com/NVIDIA/OpenShell/issues/3494).

Each image set runs in its own job (`scripts/forward-sweep/run-set.sh`): the
gateway and CLI binaries are extracted from the images; a single-node gateway
runs on the runner with the Docker compute driver, mTLS from
`openshell-gateway generate-certs`, and a file-backed SQLite database on the
runner disk; the set's supervisor image is pre-pulled (the gateway extracts the
supervisor through the Docker API, which has no registry credentials); a
sandbox built from `python:3.13-slim` plus `iproute2` serves loopback HTTP;
`scripts/forward-sweep/sweep.py` then opens bursts of 1, 6, 16, 32 and 64
simultaneous connections (twice each) plus 10 sequential ones through the
forward and records wall time, completions and mean latency. The job also
reports the raw `fdatasync`/`dd oflag=dsync` cost of the runner disk, the
number of `connection limit reached` refusals in the forward log, and the
`PRAGMA journal_mode` of the gateway database (`delete` for baseline, `wal`
for patched). Raw logs and `results.json` are uploaded as artifacts; the
`report` job merges both into one table.
