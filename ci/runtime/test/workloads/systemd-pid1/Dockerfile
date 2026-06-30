ARG BASE_IMAGE=docker.io/library/ubuntu:24.04
FROM ${BASE_IMAGE}

ENV container=docker
ENV DEBIAN_FRONTEND=noninteractive
STOPSIGNAL SIGRTMIN+3

RUN set -eux; \
	apt-get update; \
	apt-get install --no-install-recommends -y \
		ca-certificates \
		cron \
		curl \
		dbus \
		dbus-user-session \
		iproute2 \
		kmod \
		less \
		locales \
		openssh-server \
		procps \
		rsyslog \
		systemd \
		systemd-sysv \
		sudo \
		udev \
		vim-tiny; \
	apt-get clean; \
	rm -rf /var/lib/apt/lists/*; \
	test -L /bin; \
	test -L /sbin; \
	test -L /lib; \
	if [ -e /lib64 ]; then test -L /lib64; fi; \
	install -d -m 0755 /opt/maivo-ci /work /run/sshd; \
	printf 'root:root\n' | chpasswd; \
	systemctl set-default multi-user.target; \
	systemctl mask \
		dev-hugepages.mount \
		sys-fs-fuse-connections.mount \
		systemd-firstboot.service \
		systemd-hwdb-update.service \
		systemd-journal-flush.service \
		systemd-machine-id-commit.service \
		systemd-modules-load.service \
		systemd-remount-fs.service \
		systemd-sysusers.service \
		systemd-tmpfiles-setup-dev.service \
		systemd-udev-trigger.service \
		systemd-udevd.service; \
	systemctl disable ssh.socket; \
	systemctl enable ssh.service cron.service rsyslog.service

COPY probe.sh /usr/local/bin/maivo-ci-systemd-pid1-probe

RUN set -eux; \
	chmod +x /usr/local/bin/maivo-ci-systemd-pid1-probe; \
	cat >/etc/systemd/system/maivo-ci-probe.service <<'EOF'
[Unit]
Description=Maivo CI systemd probe
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/maivo-ci-systemd-pid1-probe

[Install]
WantedBy=multi-user.target
EOF

VOLUME ["/sys/fs/cgroup"]
CMD ["/usr/bin/systemd"]
