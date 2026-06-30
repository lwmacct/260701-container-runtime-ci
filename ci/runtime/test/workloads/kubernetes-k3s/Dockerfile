ARG BASE_IMAGE=docker.io/rancher/k3s:v1.30.6-k3s1
FROM ${BASE_IMAGE}

RUN mkdir -p /opt/maivo-ci /etc/cni/net.d && \
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "-lc" ] || [ "$1" = "-c" ]; then' \
        '  shift' \
        '  exec /bin/sh -c "$*"' \
        'fi' \
        'exec /bin/sh "$@"' >/bin/bash && \
    chmod +x /bin/bash && \
    cat >/etc/cni/net.d/99-loopback.conf <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "maivo-loopback",
  "type": "loopback"
}
EOF
