#!/usr/bin/env bash
set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/../../.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"

__main() {
	local _pressure_name="${_procfs_cpu_name}-pressure"

	if [[ "${1:-}" == "cleanup" ]]; then
		__require_cmd docker
		docker rm -f "$_procfs_cpu_name" "${_procfs_cpu_name}-nolimit" "${_procfs_cpu_name}-idle-isolation" "$_pressure_name" >/dev/null 2>&1 || true
		return
	fi

	__require_cmd docker
	__assert_maivo_ready
	__init_ci_dirs

	docker rm -f "$_procfs_cpu_name" "${_procfs_cpu_name}-nolimit" "${_procfs_cpu_name}-idle-isolation" "$_pressure_name" >/dev/null 2>&1 || true
	__build_ci_image "$_procfs_cpu_image" "${_workload_dir}/workloads/procfs-cpu" --build-arg "BASE_IMAGE=${_procfs_cpu_base_image}"

	__log "running host-equivalent CPU presentation validation without CPU limits"
	docker run --rm \
		--name "${_procfs_cpu_name}-nolimit" \
		--hostname "${_procfs_cpu_name}-nolimit" \
		--runtime maivo-runtime \
		--cgroupns=private \
		--label io.backend.security.profile=default \
		-e "CI_PROCFS_CPU_EXPECT_VISIBLE_FROM_AFFINITY=1" \
		-e "CI_PROCFS_CPU_EXPECT_AFFINITY_MATCH=1" \
		"$_procfs_cpu_image"

	__log "running automatic CPU quota presentation validation"
	docker run --rm \
		--name "$_procfs_cpu_name" \
		--hostname "$_procfs_cpu_name" \
		--runtime maivo-runtime \
		--cgroupns=private \
		--cpus "$_procfs_cpu_quota_cpus" \
		--label io.backend.security.profile=default \
		-e "CI_PROCFS_CPU_EXPECT_VISIBLE=1" \
		-e "CI_PROCFS_CPU_EXPECT_AFFINITY_MATCH=1" \
		-e "CI_PROCFS_CPU_CHECK_USAGE=1" \
		"$_procfs_cpu_image"

	__log "running CPU idle isolation validation under host-side load"
	docker run -d \
		--name "$_pressure_name" \
		--hostname "$_pressure_name" \
		"$_procfs_cpu_image" \
		python3 -c 'while True: pass' >/dev/null
	local _idle_status=0
	docker run --rm \
		--name "${_procfs_cpu_name}-idle-isolation" \
		--hostname "${_procfs_cpu_name}-idle-isolation" \
		--runtime maivo-runtime \
		--cgroupns=private \
		--cpus "$_procfs_cpu_quota_cpus" \
		--label io.backend.security.profile=default \
		-e "CI_PROCFS_CPU_EXPECT_VISIBLE=1" \
		-e "CI_PROCFS_CPU_EXPECT_AFFINITY_MATCH=1" \
		-e "CI_PROCFS_CPU_CHECK_IDLE=1" \
		"$_procfs_cpu_image" || _idle_status=$?
	docker rm -f "$_pressure_name" >/dev/null 2>&1 || true
	if [[ "$_idle_status" -ne 0 ]]; then
		return "$_idle_status"
	fi

	__assert_maivo_ready
	echo "procfs-cpu-validation-ok"
}

__main "$@"
