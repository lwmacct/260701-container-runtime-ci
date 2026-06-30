#!/usr/bin/env bash
# shellcheck disable=all

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/.." && pwd)"
_runtime_test_dir="${_repo_root}/ci/runtime/test"

_maivo_image="${MAIVO_IMAGE:-ghcr.io/lwmacct/260522-maivo:latest}"
_test_root="${MAIVO_CI_TEST_ROOT:-/tmp/maivo}"
_image_cache_dir="${MAIVO_CI_IMAGE_CACHE_DIR:-${_test_root}/images}"
_gate_mode="${MAIVO_GATE_MODE:-ci}"
_target_platform="${MAIVO_IMAGE_PLATFORM:-linux/amd64}"
_release_root="${MAIVO_RELEASE_ROOT:-/opt/maivo/releases}"
_current_link="${MAIVO_CURRENT_LINK:-/opt/maivo/current}"
_run_id="${MAIVO_WORKLOAD_RUN_ID:-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
_resource_id="$(printf '%s' "$_run_id" | tr -c '[:alnum:]_.-' '-')"
_resource_id="${_resource_id:0:32}"

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
    jq \
    libseccomp2 \
    util-linux
}

__show_host_capabilities() {
  set -x
  uname -a
  cat /sys/kernel/security/lsm || true
  findmnt /sys/fs/bpf || true
  docker version
  docker info
  oras version
}

__setup_runtime_host() {
  __require_cmd sudo
  __require_cmd docker
  __require_cmd systemctl
  __require_cmd jq
  __require_cmd oras

  __init_ci_dirs
  __install_maivo_binaries
  __install_maivo_systemd_unit
  __configure_docker_runtime
  __restart_maivo_services
  echo "ci-setup-ok"
}

__init_ci_dirs() {
  sudo install -d -m 0755 "$_test_root" "$_image_cache_dir"
  sudo chown -R "$(id -u):$(id -g)" "$_test_root"
}

__image_repo() {
  local _ref="$1"
  local _repo _last

  _repo="${_ref%%@*}"
  _last="${_repo##*/}"
  if [[ "$_last" == *:* ]]; then
    _repo="${_repo%:*}"
  fi
  printf '%s' "$_repo"
}

__extract_maivo_binaries_from_image() {
  local _dest="$1"
  local _work_dir _manifest _repo _digest _layer _i

  _work_dir="$(mktemp -d "${_test_root}/oras-image.XXXXXX")"
  _manifest="${_work_dir}/manifest.json"
  _repo="$(__image_repo "$_maivo_image")"

  __log "fetching ${_target_platform} manifest from ${_maivo_image}"
  oras manifest fetch --platform "$_target_platform" --output "$_manifest" "$_maivo_image"

  mkdir -p "${_work_dir}/rootfs" "${_work_dir}/layers"
  _i=0
  while IFS= read -r _digest; do
    [[ -n "$_digest" ]] || continue
    _i=$((_i + 1))
    _layer="${_work_dir}/layers/${_i}.tar"
    __log "fetching layer ${_i}: ${_digest}"
    oras blob fetch --output "$_layer" "${_repo}@${_digest}"
    tar -xf "$_layer" -C "${_work_dir}/rootfs"
  done < <(jq -r '.layers[].digest' "$_manifest")

  install -d -m 0755 "$_dest"
  install -m 0755 "${_work_dir}/rootfs/usr/local/bin/maivo-daemon" "${_dest}/maivo-daemon"
  install -m 0755 "${_work_dir}/rootfs/usr/local/bin/maivo-runtime" "${_dest}/maivo-runtime"
  rm -rf "$_work_dir"
}

__install_maivo_binaries() {
  local _release _artifact_bin_dir
  _release="${_release_root}/$(date +%Y%m%d%H%M%S)-ci"
  _artifact_bin_dir="${_test_root}/maivo-bin"

  __log "removing previous validation containers before installing binaries"
  docker ps -a --format '{{.Names}}' |
    awk '/^maivo-(docker-in-docker|kubernetes-k3s|systemd-pid1|procfs-memory|procfs-cpu|seccomp-notify-concurrency|container-security-policy)/ { print }' |
    xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network ls --format '{{.Name}}' |
    awk '/^maivo-docker-in-docker/ { print }' |
    xargs -r docker network rm >/dev/null 2>&1 || true

  rm -rf "$_artifact_bin_dir"
  __extract_maivo_binaries_from_image "$_artifact_bin_dir"
  "${_artifact_bin_dir}/maivo-daemon" version
  "${_artifact_bin_dir}/maivo-runtime" version

  __log "installing maivo binaries to ${_release}"
  sudo install -d -m 0755 "${_release}/bin"
  sudo install -m 0755 "${_artifact_bin_dir}/maivo-runtime" "${_release}/bin/maivo-runtime"
  sudo install -m 0755 "${_artifact_bin_dir}/maivo-daemon" "${_release}/bin/maivo-daemon"
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
  docker ps -a --format '{{.Names}}' |
    awk '/^maivo-(docker-in-docker|kubernetes-k3s|systemd-pid1|procfs-memory|procfs-cpu|seccomp-notify-concurrency|container-security-policy)/ { print }' |
    xargs -r docker rm -f >/dev/null 2>&1 || true
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

__run_workload() {
  __require_cmd docker
  __require_cmd jq
  __require_cmd flock
  local _workload="$1"

  if [[ -z "$_workload" || "$_workload" == "all" ]]; then
    echo "run-workload requires one concrete workload name" >&2
    exit 2
  fi

  __assert_maivo_ready
  export MAIVO_CI_TEST_ROOT="$_test_root"
  export MAIVO_CI_IMAGE_CACHE_DIR="$_image_cache_dir"
  export MAIVO_WORKLOAD_RUN_ID="$_resource_id"

  bash "${_runtime_test_dir}/run.sh" run "$_workload"
}

__run_workloads() {
  local -a _workloads=("$@")

  if (( ${#_workloads[@]} == 0 )); then
    read -r -a _workloads <<<"${MAIVO_CI_WORKLOADS:-procfs-cpu}"
  fi
  if (( ${#_workloads[@]} == 0 )); then
    _workloads=(procfs-cpu)
  fi
  for _workload in "${_workloads[@]}"; do
    __run_workload "$_workload"
  done
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
    for _container in $(docker ps -a --format '{{.Names}}' | awk '/^maivo-/ { print }'); do
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

__usage() {
  cat <<'EOF'
usage: scripts/maivo-ci.sh <command>

commands:
  install-dependencies
  show-host-capabilities
  setup-runtime-host
  verify-gate
  run-workload <workload>
  run-workloads [workload...]
  collect-logs
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
run-workload)
  shift
  __run_workload "${1:-}"
  ;;
run-workloads)
  shift
  __run_workloads "$@"
  ;;
collect-logs)
  __collect_logs
  ;;
-h | --help | help)
  __usage
  ;;
*)
  __usage >&2
  exit 2
  ;;
esac
