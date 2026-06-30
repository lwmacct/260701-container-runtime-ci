#!/bin/sh
set -eu

__main() {
	install -d -m 0755 /work
	printf 'systemd-pid1-unit-ok\n' >/work/systemd-unit-probe
	stat -c 'systemd-unit-probe %u:%g %n' /work /work/systemd-unit-probe
}

__main "$@"
