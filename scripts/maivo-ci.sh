#!/usr/bin/env bash
# shellcheck disable=all

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/.." && pwd)"

_maivo_dir="${MAIVO_DIR:-${_repo_root}/maivo}"
_test_root="${MAIVO_CI_TEST_ROOT:-/tmp/maivo}"
_image_cache_dir="${MAIVO_CI_IMAGE_CACHE_DIR:-${_test_root}/images}"
_build_tags="${BUILDTAGS:-seccomp idmapped_mnt}"
_gate_mode="${MAIVO_GATE_MODE:-ci}"
_host_goarch="${MAIVO_CI_GOARCH:-$(go env GOARCH 2>/dev/null || uname -m)}"
_bin_dir="${BIN_DIR:-bin-${_host_goarch}}"
_release_root="${MAIVO_RELEASE_ROOT:-/opt/maivo/releases}"
_current_link="${MAIVO_CURRENT_LINK:-/opt/maivo/current}"
_run_id="${MAIVO_WORKLOAD_RUN_ID:-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
_resource_id="$(printf '%s' "$_run_id" | tr -c '[:alnum:]_.-' '-')"
_resource_id="${_resource_id:0:32}"

_procfs_cpu_name="maivo-procfs-cpu-${_resource_id}"
_procfs_cpu_image="maivo-ci/procfs-cpu:${_resource_id}"
_procfs_cpu_base_image="${MAIVO_CI_PROCFS_CPU_BASE_IMAGE:-1181.s.kuaicdn.cn:11818/docker.io/library/python:3.12-alpine}"
_procfs_cpu_quota_cpus="${MAIVO_CI_PROCFS_CPU_QUOTA_CPUS:-0.1}"

__log() {
  printf '\n==> %s\n' "$*" >&2
}

__require_cmd() {
  local _cmd="$1"
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "missing required command: $_cmd" >&2
    exit 1
  fi
}

__install_dependencies() {
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    jq \
    libseccomp-dev \
    pkg-config \
    util-linux
}

__show_host_capabilities() {
  set -x
  uname -a
  cat /sys/kernel/security/lsm || true
  findmnt /sys/fs/bpf || true
  docker version
  docker info
  go version
  task --version
}

__setup_runtime_host() {
  __require_cmd task
  __require_cmd sudo
  __require_cmd go
  __require_cmd gcc
  __require_cmd docker
  __require_cmd systemctl
  __require_cmd jq

  __init_ci_dirs
  __build_maivo_binaries
  __install_maivo_binaries
  __install_maivo_systemd_unit
  __configure_docker_runtime
  __restart_maivo_services
  echo "ci-setup-ok"
}

__init_ci_dirs() {
  sudo install -d -m 0755 "$_test_root" "$_image_cache_dir"
}

__build_maivo_binaries() {
  __log "building maivo binaries for linux/${_host_goarch}"
  cd "$_maivo_dir"
  GOOS=linux GOARCH="$_host_goarch" CGO_ENABLED=1 BUILDTAGS="$_build_tags" BIN_DIR="$_bin_dir" task build
}

__install_maivo_binaries() {
  local _rev _release
  _rev="$(git -C "$_maivo_dir" rev-parse --short=12 HEAD)"
  _release="${_release_root}/$(date +%Y%m%d%H%M%S)-${_rev}-${_host_goarch}-ci"

  __log "removing previous validation containers before installing binaries"
  docker ps -a --format '{{.Names}}' |
    awk '/^maivo-(docker-in-docker|kubernetes-k3s|systemd-pid1|procfs-memory|procfs-cpu|seccomp-notify-concurrency|container-security-policy)/ { print }' |
    xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network ls --format '{{.Name}}' |
    awk '/^maivo-docker-in-docker/ { print }' |
    xargs -r docker network rm >/dev/null 2>&1 || true

  __log "installing maivo binaries to ${_release}"
  sudo install -d -m 0755 "${_release}/bin"
  sudo install -m 0755 "${_maivo_dir}/${_bin_dir}/maivo-runtime" "${_release}/bin/maivo-runtime"
  sudo install -m 0755 "${_maivo_dir}/${_bin_dir}/maivo-daemon" "${_release}/bin/maivo-daemon"
  sudo ln -sfn "$_release" "$_current_link"
  sudo ln -sfn "${_current_link}/bin/maivo-runtime" /usr/bin/maivo-runtime
  sudo ln -sfn "${_current_link}/bin/maivo-daemon" /usr/bin/maivo-daemon
  sudo rm -f /usr/bin/maivo-runc /usr/bin/maivod /usr/bin/maivo-policy
}

__install_maivo_systemd_unit() {
  case "$_gate_mode" in
  strict | ci) ;;
  *)
    echo "unsupported MAIVO_GATE_MODE: $_gate_mode" >&2
    exit 2
    ;;
  esac

  __log "installing maivo-daemon systemd unit"
  sudo systemctl disable maivod.service >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/maivod.service
  sudo tee /etc/systemd/system/maivo-daemon.service >/dev/null <<EOF
[Unit]
Description=maivo-daemon (Maivo unified daemon)
Before=docker.service containerd.service

[Service]
Type=notify
Environment=MAIVO_GATE_MODE=${_gate_mode}
ExecStart=/usr/bin/maivo-daemon --log /var/log/maivo-daemon.log --metrics-listen 127.0.0.1:9618
TimeoutStartSec=45
TimeoutStopSec=90
StartLimitInterval=0
NotifyAccess=main
OOMScoreAdjust=-500
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable maivo-daemon.service >/dev/null
}

__configure_docker_runtime() {
  local _daemon_config="/etc/docker/daemon.json"
  local _tmp_config

  __log "configuring docker maivo-runtime"
  sudo install -d -m 0755 /etc/docker
  _tmp_config="$(mktemp)"
  if sudo test -s "$_daemon_config"; then
    sudo jq '
			if type != "object" then
				error("docker daemon config must be a JSON object")
			else
				.runtimes = ((.runtimes // {})
					| del(."mosbox-runc", ."mosbox-runtime")
					| .["maivo-runtime"] = {
						"path": "/usr/bin/maivo-runtime",
						"runtimeArgs": []
					})
			end
		' "$_daemon_config" >"$_tmp_config"
  else
    jq -n '{
			"runtimes": {
				"maivo-runtime": {
					"path": "/usr/bin/maivo-runtime",
					"runtimeArgs": []
				}
			}
		}' >"$_tmp_config"
  fi
  sudo install -m 0644 "$_tmp_config" "$_daemon_config"
  rm -f "$_tmp_config"
}

__restart_maivo_services() {
  __log "restarting maivo-daemon and docker"
  docker rm -f \
    "${_procfs_cpu_name}" \
    "${_procfs_cpu_name}-nolimit" \
    "${_procfs_cpu_name}-idle-isolation" \
    "${_procfs_cpu_name}-pressure" >/dev/null 2>&1 || true
  sudo truncate -s 0 /var/log/maivo-daemon.log 2>/dev/null || sudo install -m 0600 /dev/null /var/log/maivo-daemon.log
  sudo systemctl reset-failed docker.service maivo-daemon.service maivod.service || true
  sudo systemctl stop maivo-daemon.service maivod.service || true
  while read -r _mp; do
    [[ -n "$_mp" ]] || continue
    sudo umount -l "$_mp" || true
  done < <(awk '$0 ~ / - fuse maivofs / && $5 ~ /^\/var\/lib\/maivofs\// {print $5}' /proc/self/mountinfo)
  sudo rm -f /run/maivo/daemon.sock /run/maivo/maivod.sock /run/maivo/seccomp-notify.sock /run/maivo/daemon.pid /run/maivo/maivod.pid
  sudo rm -rf /run/maivo/sessions
  if sudo test -d /var/lib/maivofs; then
    sudo find /var/lib/maivofs -mindepth 1 -maxdepth 1 -xdev -exec rm -rf -- {} + 2>/dev/null || true
  fi
  sudo systemctl restart maivo-daemon.service
  sudo systemctl is-active --quiet maivo-daemon.service
  sudo systemctl restart docker
  __assert_maivo_ready
}

__verify_gate() {
  sudo systemctl is-active --quiet maivo-daemon.service
  sudo systemctl cat maivo-daemon.service
  sudo maivo-daemon gate status
  sudo maivo-daemon gate status | jq -e '.mode == "ci" and .enforce == false'
}

__assert_maivo_ready() {
  __log "checking maivo services"
  sudo systemctl is-active --quiet maivo-daemon.service
  sudo grep -q "Ready ..." /var/log/maivo-daemon.log
  ! sudo grep -q "ID-mapped mounts are required" /var/log/maivo-daemon.log
  ! sudo grep -q "overlayfs on ID-mapped mounts is required" /var/log/maivo-daemon.log
  docker info --format '{{json .Runtimes}}' | jq -e 'has("maivo-runtime")' >/dev/null
}

__cleanup_procfs_cpu() {
  docker rm -f \
    "${_procfs_cpu_name}" \
    "${_procfs_cpu_name}-nolimit" \
    "${_procfs_cpu_name}-idle-isolation" \
    "${_procfs_cpu_name}-pressure" >/dev/null 2>&1 || true
}

__build_procfs_cpu_image() {
  __log "building ${_procfs_cpu_image}"
  docker build --network host \
    --build-arg "BASE_IMAGE=${_procfs_cpu_base_image}" \
    -t "$_procfs_cpu_image" \
    "${_repo_root}/workloads/procfs-cpu"
}

__run_procfs_cpu() {
  __require_cmd docker
  __require_cmd jq

  __assert_maivo_ready
  __cleanup_procfs_cpu
  trap __cleanup_procfs_cpu EXIT
  __build_procfs_cpu_image

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
    --name "${_procfs_cpu_name}-pressure" \
    --hostname "${_procfs_cpu_name}-pressure" \
    "$_procfs_cpu_image" \
    python3 -c 'while True: pass' >/dev/null

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
    "$_procfs_cpu_image"

  __cleanup_procfs_cpu
  __assert_maivo_ready
  echo "procfs-cpu-validation-ok"
}

__collect_logs() {
  local _log_dir="${_test_root}/runs/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}/logs"
  sudo install -d -m 0755 "$_log_dir"
  {
    uname -a || true
    cat /sys/kernel/security/lsm || true
    findmnt /sys/fs/bpf || true
    docker info || true
    docker ps -a || true
    docker images || true
    for _container in $(docker ps -a --format '{{.Names}}' | awk '/^maivo-procfs-cpu/ { print }'); do
      docker logs "$_container" || true
    done
    sudo systemctl --no-pager --full status docker.service maivo-daemon.service || true
    sudo systemctl cat maivo-daemon.service || true
    sudo maivo-daemon gate status || true
    sudo journalctl --no-pager -u docker.service -u maivo-daemon.service || true
  } 2>&1 | sudo tee "${_log_dir}/host-diagnostics.log" >/dev/null
  if sudo test -f /var/log/maivo-daemon.log; then
    sudo cp /var/log/maivo-daemon.log "${_log_dir}/maivo-daemon.log"
    sudo chmod 0644 "${_log_dir}/maivo-daemon.log"
  fi
}

__warm_go_cache() {
  cd "$_maivo_dir"
  go mod download
  BIN_DIR=bin BUILDTAGS="${_build_tags}" task build
}

__usage() {
  cat <<'EOF'
usage: scripts/maivo-ci.sh <command>

commands:
  install-dependencies
  show-host-capabilities
  setup-runtime-host
  verify-gate
  procfs-cpu
  collect-logs
  warm-go-cache
EOF
}

case "${1:-}" in
install-dependencies)
  __install_dependencies
  ;;
show-host-capabilities)
  __show_host_capabilities
  ;;
setup-runtime-host)
  __setup_runtime_host
  ;;
verify-gate)
  __verify_gate
  ;;
procfs-cpu)
  __run_procfs_cpu
  ;;
collect-logs)
  __collect_logs
  ;;
warm-go-cache)
  __warm_go_cache
  ;;
-h | --help | help)
  __usage
  ;;
*)
  __usage >&2
  exit 2
  ;;
esac
