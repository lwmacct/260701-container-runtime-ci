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
