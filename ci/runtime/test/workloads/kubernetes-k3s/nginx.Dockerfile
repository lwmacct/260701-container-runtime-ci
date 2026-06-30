ARG BASE_IMAGE=docker.io/nginx:latest
FROM ${BASE_IMAGE}

COPY nginx-index.html /usr/share/nginx/html/index.html
