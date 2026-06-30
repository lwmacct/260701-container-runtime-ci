ARG BASE_IMAGE=1181.s.kuaicdn.cn:11818/docker.io/nginx:latest
FROM ${BASE_IMAGE}

COPY nginx-index.html /usr/share/nginx/html/index.html
