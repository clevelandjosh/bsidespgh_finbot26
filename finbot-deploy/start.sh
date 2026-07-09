#!/usr/bin/env bash
set -euo pipefail

# start.sh for proxy image
# Requires BACKEND_HOSTNAME env var to be set (in App Settings)
: "${BACKEND_HOSTNAME:?Need to set BACKEND_HOSTNAME environment variable}"

# Substitute BACKEND_HOSTNAME into nginx.conf from template
envsubst '${BACKEND_HOSTNAME}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Start nginx in foreground
nginx -g 'daemon off;'
