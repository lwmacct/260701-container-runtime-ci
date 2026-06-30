#!/usr/bin/env bash

__safe_resource_id() {
	local _value="$1"
	printf '%s' "$_value" | tr -c '[:alnum:]_.-' '-'
}

__image_tag() {
	local _repo="$1"
	local _default_tag="$2"

	if [[ -n "$_workload_resource_id" ]]; then
		printf '%s:%s\n' "$_repo" "$_workload_resource_id"
	else
		printf '%s:%s\n' "$_repo" "$_default_tag"
	fi
}

_test_root="${MAIVO_CI_TEST_ROOT:-/data/maivo}"
_workload_id="${MAIVO_WORKLOAD_ID:-}"
_workload_resource_id=""
_workload_run_root="$_test_root"
if [[ -n "$_workload_id" ]]; then
	_workload_resource_id="$(__safe_resource_id "$_workload_id")"
	_workload_run_root="${_test_root}/runs/${_workload_resource_id}"
fi

_image_cache_dir="${MAIVO_CI_IMAGE_CACHE_DIR:-${_test_root}/images}"
_volume_root="${MAIVO_CI_VOLUME_ROOT:-${_workload_run_root}/volumes}"
_log_root="${MAIVO_CI_LOG_ROOT:-${_workload_run_root}/logs}"

_docker_in_docker_name="${MAIVO_CI_DOCKER_IN_DOCKER_NAME:-maivo-docker-in-docker${_workload_resource_id:+-${_workload_resource_id}}}"
_docker_in_docker_network="${MAIVO_CI_DOCKER_IN_DOCKER_NETWORK:-maivo-docker-in-docker${_workload_resource_id:+-${_workload_resource_id}}}"
_docker_in_docker_base_image="${MAIVO_CI_DOCKER_IN_DOCKER_BASE_IMAGE:-ghcr.io/lwmacct/250210-cr-docker:29.4.0-dind-260408}"
_docker_in_docker_image="${MAIVO_CI_DOCKER_IN_DOCKER_IMAGE:-$(__image_tag maivo-ci/docker-in-docker latest)}"

_container_security_policy_name="${MAIVO_CI_CONTAINER_SECURITY_POLICY_NAME:-maivo-container-security-policy${_workload_resource_id:+-${_workload_resource_id}}}"
_container_security_policy_base_image="${MAIVO_CI_CONTAINER_SECURITY_POLICY_BASE_IMAGE:-docker.io/library/python:3.12-alpine}"
_container_security_policy_image="${MAIVO_CI_CONTAINER_SECURITY_POLICY_IMAGE:-$(__image_tag maivo-ci/container-security-policy latest)}"

_kubernetes_k3s_name="${MAIVO_CI_KUBERNETES_K3S_NAME:-maivo-kubernetes-k3s${_workload_resource_id:+-${_workload_resource_id}}}"
_kubernetes_k3s_base_image="${MAIVO_CI_KUBERNETES_K3S_BASE_IMAGE:-docker.io/rancher/k3s:v1.30.6-k3s1}"
_kubernetes_k3s_image="${MAIVO_CI_KUBERNETES_K3S_IMAGE:-$(__image_tag maivo-ci/kubernetes-k3s latest)}"
_kubernetes_k3s_pause_source_image="${MAIVO_CI_KUBERNETES_K3S_PAUSE_SOURCE_IMAGE:-docker.io/rancher/mirrored-pause:3.6}"
_kubernetes_k3s_pause_image="${MAIVO_CI_KUBERNETES_K3S_PAUSE_IMAGE:-docker.io/rancher/mirrored-pause:3.6}"
_kubernetes_k3s_pod_name="${MAIVO_CI_KUBERNETES_K3S_POD_NAME:-maivo-kubernetes-k3s-nginx${_workload_resource_id:+-${_workload_resource_id}}}"

_systemd_pid1_name="${MAIVO_CI_SYSTEMD_PID1_NAME:-maivo-systemd-pid1${_workload_resource_id:+-${_workload_resource_id}}}"
_systemd_pid1_unit="${MAIVO_CI_SYSTEMD_PID1_UNIT:-maivo-ci-systemd-pid1${_workload_resource_id:+-${_workload_resource_id}}}"
_systemd_pid1_base_image="${MAIVO_CI_SYSTEMD_PID1_BASE_IMAGE:-docker.io/library/ubuntu:24.04}"
_systemd_pid1_image="${MAIVO_CI_SYSTEMD_PID1_IMAGE:-$(__image_tag maivo-ci/systemd-pid1 latest)}"

_procfs_memory_name="${MAIVO_CI_PROCFS_MEMORY_NAME:-maivo-procfs-memory${_workload_resource_id:+-${_workload_resource_id}}}"
_procfs_memory_base_image="${MAIVO_CI_PROCFS_MEMORY_BASE_IMAGE:-docker.io/library/python:3.12-alpine}"
_procfs_memory_image="${MAIVO_CI_PROCFS_MEMORY_IMAGE:-$(__image_tag maivo-ci/procfs-memory latest)}"
_procfs_memory_memory_bytes="${MAIVO_CI_PROCFS_MEMORY_MEMORY_BYTES:-134217728}"
_procfs_memory_swap_bytes="${MAIVO_CI_PROCFS_MEMORY_SWAP_BYTES:-268435456}"
_procfs_memory_overflow_alloc_bytes="${MAIVO_CI_PROCFS_MEMORY_OVERFLOW_ALLOC_BYTES:-268435456}"
_procfs_memory_swap_exercise_alloc_bytes="${MAIVO_CI_PROCFS_MEMORY_SWAP_EXERCISE_ALLOC_BYTES:-201326592}"

_procfs_cpu_name="${MAIVO_CI_PROCFS_CPU_NAME:-maivo-procfs-cpu${_workload_resource_id:+-${_workload_resource_id}}}"
_procfs_cpu_base_image="${MAIVO_CI_PROCFS_CPU_BASE_IMAGE:-docker.io/library/python:3.12-alpine}"
_procfs_cpu_image="${MAIVO_CI_PROCFS_CPU_IMAGE:-$(__image_tag maivo-ci/procfs-cpu latest)}"
_procfs_cpu_quota_cpus="${MAIVO_CI_PROCFS_CPU_QUOTA_CPUS:-0.1}"

_seccomp_notify_concurrency_name="${MAIVO_CI_SECCOMP_NOTIFY_CONCURRENCY_NAME:-maivo-seccomp-notify-concurrency${_workload_resource_id:+-${_workload_resource_id}}}"
_seccomp_notify_concurrency_base_image="${MAIVO_CI_SECCOMP_NOTIFY_CONCURRENCY_BASE_IMAGE:-docker.io/library/python:3.12-alpine}"
_seccomp_notify_concurrency_image="${MAIVO_CI_SECCOMP_NOTIFY_CONCURRENCY_IMAGE:-$(__image_tag maivo-ci/seccomp-notify-concurrency latest)}"
_seccomp_notify_concurrency_processes="${MAIVO_CI_SECCOMP_NOTIFY_CONCURRENCY_PROCESSES:-24}"
_seccomp_notify_concurrency_sysinfo_iterations="${MAIVO_CI_SECCOMP_NOTIFY_CONCURRENCY_SYSINFO_ITERATIONS:-32}"
_seccomp_notify_concurrency_openat2_iterations="${MAIVO_CI_SECCOMP_NOTIFY_CONCURRENCY_OPENAT2_ITERATIONS:-8}"
_seccomp_notify_concurrency_mount_iterations="${MAIVO_CI_SECCOMP_NOTIFY_CONCURRENCY_MOUNT_ITERATIONS:-8}"

_inner_nginx_base_image="${MAIVO_CI_INNER_NGINX_BASE_IMAGE:-docker.io/nginx:latest}"
_inner_nginx_image="${MAIVO_CI_INNER_NGINX_IMAGE:-$(__image_tag maivo-ci/nginx-workload latest)}"

__require_cmd() {
	local _cmd="$1"
	if ! command -v "$_cmd" >/dev/null 2>&1; then
		echo "missing required command: $_cmd" >&2
		exit 1
	fi
}

__log() {
	printf '\n==> %s\n' "$*" >&2
}

__init_ci_dirs() {
	install -d -m 0755 "$_test_root" "$_image_cache_dir" "$_volume_root" "$_log_root"
}
