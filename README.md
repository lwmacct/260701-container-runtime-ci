# Container Runtime CI Probe

This public repository probes whether GitHub-hosted runners can execute
host-level container runtime tests.

The workflow intentionally does not mirror any product repository CI. It checks
only the resources needed by runtime validation:

- passwordless sudo and systemd-managed Docker
- Docker daemon restart and custom runtime registration
- privileged container mount behavior
- BTF, bpffs, and active BPF LSM
- ID-mapped bind mounts and overlayfs on top of the mapped mount

When manually dispatching the workflow, enable `debug_tmate` to open an SSH
session on the GitHub-hosted runner before the probe runs.

`Maivo CI Gate Mode` validates binaries extracted from a public GHCR image,
for example `ghcr.io/lwmacct/260522-maivo:v0.33.260701`. The runtime setup,
gate check, diagnostics, and workload flow live in this repository under
`scripts/maivo-ci.sh` and `ci/runtime/test/`.

All migrated runtime workloads are stored in `ci/runtime/test/workloads/`.
The workflow runs workloads as a GitHub Actions matrix, so every workload gets
its own runner, Docker daemon, systemd services, logs, and artifact.

The default group runs `procfs-cpu`, `procfs-memory`, and
`seccomp-notify-concurrency`. Manual runs can select `extended`, `all`, or
`custom` with a space-separated `workloads` value.

The workflow is manual-only. It does not need access to the private Maivo
source repository. It installs ORAS, fetches the selected linux/amd64 image
manifest and layers, extracts `/usr/local/bin/maivo-daemon` and
`/usr/local/bin/maivo-runtime`, then installs those binaries on the runner.
