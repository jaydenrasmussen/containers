#!/bin/sh
envsubst '${LISTEN_PORT} ${OLD_API_HOST} ${OLD_API_PORT} ${OLD_API_WEIGHT} ${NEW_API_HOST} ${NEW_API_PORT} ${NEW_API_WEIGHT} ${RESOLVER_ADDRESS}' < /nginx.conf.template > /etc/nginx/nginx.conf
exec "$@"
