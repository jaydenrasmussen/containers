#!/bin/sh
envsubst '${LISTEN_PORT} ${UPSTREAM_HOST} ${UPSTREAM_PORT} ${RESOLVER_ADDRESS}' < /nginx.conf.template > /etc/nginx/nginx.conf
exec "$@"
