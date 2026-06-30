#!/bin/sh
set -eu

__check_cgroup() {
	if ! awk '$5 == "/sys/fs/cgroup" {
		for (i = 1; i <= NF; i++) {
			if ($i == "-" && $(i + 1) == "cgroup2" && $4 == "/" && $6 ~ /(^|,)rw(,|$)/) {
				found = 1
			}
		}
	} END { exit !found }' /proc/self/mountinfo; then
		echo "/sys/fs/cgroup is not a rw cgroup2 mount rooted at the cgroup namespace root" >&2
		exit 1
	fi
	_cg_path="$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup)"
	case "$_cg_path" in
		*docker*|*containerd*|*kubepods*|*system.slice*)
			echo "/proc/self/cgroup leaked host cgroup path: $_cg_path" >&2
			exit 1
			;;
	esac
	[ -d /sys/fs/cgroup/init.scope ]
	_test_cg="/sys/fs/cgroup/maivo-ci-delegation-$$"
	trap 'rmdir "$_test_cg" 2>/dev/null || true' EXIT
	mkdir "$_test_cg"
	[ -d "$_test_cg" ]
	rmdir "$_test_cg"
	echo "cgroup-subtree-ok"
}

__check_resources() {
	_base="/tmp/maivo-ci-resource-negative-$$"
	trap 'umount "$_base"/unsafe-* "$_base/cgroup-rw" "$_base/cgroup-root-bind" "$_base/overlay2/id/merged/dev/kmsg" "$_base/netns/not-net" 2>/dev/null || true; rm -rf "$_base"' EXIT
	mkdir -p "$_base/cgroup-rw" "$_base/cgroup-root-bind" "$_base/overlay2/id/merged/dev" "$_base/netns"
	: >"$_base/overlay2/id/merged/dev/kmsg"
	: >"$_base/netns/not-net"

	for _fs in securityfs debugfs tracefs configfs; do
		_target="$_base/unsafe-$_fs"
		mkdir -p "$_target"
		if mount -t "$_fs" "$_fs" "$_target" 2>"$_base/$_fs.err"; then
			echo "$_fs mount unexpectedly succeeded" >&2
			exit 1
		fi
	done

	if mount -t cgroup2 cgroup "$_base/cgroup-rw" 2>"$_base/cgroup-rw.err"; then
		echo "writable cgroup2 mount unexpectedly succeeded" >&2
		exit 1
	fi

	if mount --bind /sys/fs/cgroup "$_base/cgroup-root-bind" 2>"$_base/cgroup-root-bind.err"; then
		echo "host cgroup root bind unexpectedly succeeded" >&2
		exit 1
	fi

	if mount --bind /dev/null "$_base/overlay2/id/merged/dev/kmsg" 2>"$_base/device.err"; then
		echo "invalid device bind unexpectedly succeeded" >&2
		exit 1
	fi

	if mount --bind /proc/self/ns/mnt "$_base/netns/not-net" 2>"$_base/netns.err"; then
		echo "non-netns namespace bind unexpectedly succeeded" >&2
		exit 1
	fi

	echo "resource-negative-policy-ok"
}

__check_cgroup_subtree_mount_policy() {
	_base="/tmp/maivo-ci-cgroup-subtree-$$"
	_leaf="/sys/fs/cgroup/maivo-ci-bpf-subtree-$$"
	trap 'printf "%s\n" "$$" >/sys/fs/cgroup/cgroup.procs 2>/dev/null || true; umount "$_base"/unsafe-* 2>/dev/null || true; rmdir "$_leaf" 2>/dev/null || true; rm -rf "$_base"' EXIT
	mkdir -p "$_base" "$_leaf"
	printf '%s\n' "$$" >"$_leaf/cgroup.procs"

	for _fs in securityfs debugfs tracefs configfs; do
		_target="$_base/unsafe-$_fs"
		mkdir -p "$_target"
		if mount -t "$_fs" "$_fs" "$_target" 2>"$_base/$_fs.err"; then
			echo "$_fs mount unexpectedly succeeded from delegated child cgroup" >&2
			exit 1
		fi
	done

	echo "cgroup-subtree-mount-policy-ok"
}

__expect_eperm_path() {
	_path="$1"
	_marker="$2"
	_status=0
	set +e
	python3 - "$_path" <<'PY'
import errno
import os
import sys

path = sys.argv[1]
flags = os.O_RDONLY | os.O_CLOEXEC
if os.path.basename(path) == "sysrq-trigger":
    flags = os.O_WRONLY | os.O_CLOEXEC
try:
    fd = os.open(path, flags)
except OSError as exc:
    if exc.errno == errno.ENOENT:
        sys.exit(10)
    if exc.errno == errno.EPERM:
        sys.exit(0)
    print(f"{path}: errno {exc.errno}, want EPERM", file=sys.stderr)
    sys.exit(1)
else:
    os.close(fd)
    print(f"{path}: access unexpectedly succeeded", file=sys.stderr)
    sys.exit(2)
PY
	_status="$?"
	set -e
	if [ "$_status" -eq 0 ]; then
		echo "kernel-interface-denied $_marker"
		return 0
	fi
	if [ "$_status" -eq 10 ]; then
		return 0
	fi
	exit "$_status"
}

__check_kernel_interface_files() {
	__expect_eperm_path /sys/kernel/security/lsm lsm
	awk '
		{
			sep = 0
			for (i = 1; i <= NF; i++) {
				if ($i == "-") {
					sep = i
					break
				}
			}
			if (!sep) {
				next
			}
			fstype = $(sep + 1)
			if (fstype == "securityfs" || fstype == "debugfs" || fstype == "tracefs" || fstype == "configfs") {
				print fstype " " $5
			}
		}
	' /proc/self/mountinfo | while read -r _fs _path; do
		__expect_eperm_path "$_path" "$_fs"
	done
	echo "kernel-interface-file-policy-ok"
}

__check_cgroup_subtree_kernel_interface_files() {
	_leaf="/sys/fs/cgroup/maivo-ci-bpf-file-subtree-$$"
	trap 'printf "%s\n" "$$" >/sys/fs/cgroup/cgroup.procs 2>/dev/null || true; rmdir "$_leaf" 2>/dev/null || true' EXIT
	mkdir -p "$_leaf"
	printf '%s\n' "$$" >"$_leaf/cgroup.procs"
	__check_kernel_interface_files
	echo "cgroup-subtree-kernel-interface-file-policy-ok"
}

__check_xattr_negative_policy() {
	python3 - <<'PY'
import errno
import os
import sys

base = f"/tmp/maivo-ci-xattr-negative-{os.getpid()}"
path = os.path.join(base, "target")
name = b"user.maivo_ci_denied"

os.makedirs(base, exist_ok=True)
with open(path, "wb") as f:
    f.write(b"data")

checks = (
    ("setxattr", lambda: os.setxattr(path, name, b"blocked")),
    ("getxattr", lambda: os.getxattr(path, name)),
    ("removexattr", lambda: os.removexattr(path, name)),
)
for op, fn in checks:
    try:
        fn()
    except OSError as exc:
        if exc.errno == errno.EPERM:
            continue
        print(f"{op} returned errno {exc.errno}, want EPERM", file=sys.stderr)
        raise
    raise RuntimeError(f"{op} unexpectedly succeeded for non-whitelisted xattr")

print("xattr-negative-policy-ok")
PY
}

__check_xattr_trusted_overlay_policy() {
	python3 - <<'PY'
import errno
import os
import shutil

base = f"/var/lib/docker/overlay2/maivo-ci-xattr-{os.getpid()}"
diff = os.path.join(base, "diff")
name = b"trusted.overlay.origin"
value = b"y"

try:
    os.makedirs(diff, exist_ok=True)
    try:
        os.setxattr(diff, name, value)
    except OSError as exc:
        if exc.errno == errno.EPERM:
            raise RuntimeError("trusted overlay xattr was denied by BPF policy") from exc
    try:
        os.getxattr(diff, name)
    except OSError as exc:
        if exc.errno == errno.EPERM:
            raise RuntimeError("trusted overlay xattr read was denied by BPF policy") from exc
    try:
        os.removexattr(diff, name)
    except OSError as exc:
        if exc.errno == errno.EPERM:
            raise RuntimeError("trusted overlay xattr removal was denied by BPF policy") from exc
finally:
    shutil.rmtree(base, ignore_errors=True)

print("xattr-trusted-overlay-policy-ok")
PY
}

__reject_write() {
	_path="$1"
	[ -e "$_path" ] || return 0
	if ! awk -v target="$_path" '$5 == target && $6 ~ /(^|,)ro($|,)/ { found = 1 } END { exit !found }' /proc/self/mountinfo; then
		echo "host-global sysctl deny path is not a readonly mount: $_path" >&2
		exit 1
	fi
	_value="$(cat "$_path" 2>/dev/null || true)"
	if sh -c 'printf "%s\n" "$1" > "$2"' sh "$_value" "$_path" 2>/tmp/maivo-sysctl-write.err; then
		echo "host-global sysctl write unexpectedly succeeded: $_path" >&2
		exit 1
	fi
}

__check_proc_sys() {
	if mount | grep -q "maivofs on /proc/sys "; then
		echo "unexpected maivofs mount on /proc/sys" >&2
		exit 1
	fi
	for _path in ${real_namespaced_sysctls:-}; do
		[ -e "$_path" ] || continue
		cat "$_path" >/dev/null
	done
	for _path in ${host_global_deny_sysctls:-}; do
		__reject_write "$_path"
	done
	echo "proc-sys-security-ok"
}

__main() {
	case "${1:-}" in
		cgroup-delegation)
			__check_cgroup
			;;
		privileged-resource-negative-policy)
			__check_resources
			;;
		cgroup-subtree-mount-policy)
			__check_cgroup_subtree_mount_policy
			;;
		kernel-interface-file-policy)
			__check_kernel_interface_files
			;;
		cgroup-subtree-kernel-interface-file-policy)
			__check_cgroup_subtree_kernel_interface_files
			;;
		xattr-negative-policy)
			__check_xattr_negative_policy
			;;
		xattr-trusted-overlay-policy)
			__check_xattr_trusted_overlay_policy
			;;
		proc-sys-policy)
			__check_proc_sys
			;;
		*)
			echo "usage: $0 {cgroup-delegation|privileged-resource-negative-policy|cgroup-subtree-mount-policy|kernel-interface-file-policy|cgroup-subtree-kernel-interface-file-policy|xattr-negative-policy|xattr-trusted-overlay-policy|proc-sys-policy}" >&2
			exit 2
			;;
	esac
}

__main "$@"
