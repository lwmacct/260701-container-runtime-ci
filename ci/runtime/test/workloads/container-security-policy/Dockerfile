ARG BASE_IMAGE=docker.io/library/python:3.12-alpine
FROM ${BASE_IMAGE}

COPY probe.sh /usr/local/bin/maivo-ci-container-security-policy-probe
RUN apk add --no-cache strace && chmod +x /usr/local/bin/maivo-ci-container-security-policy-probe

CMD ["/bin/sleep", "3600"]
