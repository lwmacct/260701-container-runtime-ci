#!/bin/sh
set -eu

__main() {
	docker info --format '{{.ServerVersion}} {{.Architecture}} {{.Driver}}'
}

__main "$@"
