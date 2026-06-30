ARG BASE_IMAGE=docker.io/library/python:3.12-alpine
FROM ${BASE_IMAGE}

RUN apk add --no-cache build-base

COPY probe.py /usr/local/bin/maivo-ci-procfs-memory-probe
RUN chmod +x /usr/local/bin/maivo-ci-procfs-memory-probe

CMD ["/usr/local/bin/maivo-ci-procfs-memory-probe"]
