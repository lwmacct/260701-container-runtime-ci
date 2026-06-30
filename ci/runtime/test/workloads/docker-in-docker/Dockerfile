ARG BASE_IMAGE=ghcr.io/lwmacct/250210-cr-docker:29.4.0-dind-260408
FROM ${BASE_IMAGE}

COPY smoke.sh /usr/local/bin/maivo-ci-docker-in-docker-smoke
RUN chmod +x /usr/local/bin/maivo-ci-docker-in-docker-smoke
