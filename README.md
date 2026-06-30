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

`Maivo CI Gate Mode` checks out `lwmacct/260522-maivo` and runs
`task ci:test:setup` with `MAIVO_GATE_MODE=ci`, which verifies that the daemon
can start on standard GitHub-hosted runners without active BPF LSM.

Because `lwmacct/260522-maivo` is private, configure repository secret
`MAIVO_REPO_TOKEN` before running `Maivo CI Gate Mode`. A fine-grained GitHub
token with read-only Contents permission on `lwmacct/260522-maivo` is enough.
The workflow is manual-only so pushes to this public probe repository do not
fail before the secret exists.

The Maivo workflow restores an explicit warm Go cache before building:

- `cache-warmup-go` stores Go modules and build cache keyed by the Maivo
  `go.sum` and resolved Go version.

Task is installed with `go-task/setup-task@v2`. If a manual Maivo run succeeds
with the Go cache missing, it triggers the warmup workflow for the next run.
The warmup workflow can also be run manually.
