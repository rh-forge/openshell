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
