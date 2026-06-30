#!/usr/bin/env bash

__assert_maivo_ready() {
	__log "checking maivo services"
	systemctl is-active --quiet maivo-daemon.service
	grep -q "Ready ..." /var/log/maivo-daemon.log
	! grep -q "ID-mapped mounts are required" /var/log/maivo-daemon.log
	! grep -q "overlayfs on ID-mapped mounts is required" /var/log/maivo-daemon.log
	docker info --format '{{json .Runtimes}}' | jq -e 'has("maivo-runtime")' >/dev/null
}
