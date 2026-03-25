#!/bin/sh
set -e

# When the pulp-operator (or another orchestrator) mounts its own nginx.conf
# via a read-only ConfigMap, skip all config generation and just start nginx.
# The operator's config uses static upstream blocks that match Kubernetes
# service names, so plugin snippets work without rewriting.
if [ -f /etc/nginx/nginx.conf ] && ! touch /etc/nginx/nginx.conf 2>/dev/null; then
  echo "Detected externally-managed nginx.conf (read-only), skipping config generation"
  exec nginx -g "daemon off;"
fi

PULP_API_HOST="${PULP_API_HOST:-pulp_api}"
PULP_CONTENT_HOST="${PULP_CONTENT_HOST:-pulp_content}"
PULP_CONTENT_PATH="${PULP_CONTENT_PATH:-/pulp/content/}"
PULP_API_ROOT="${PULP_API_ROOT:-/pulp/}"
PULP_HTTPS="${PULP_HTTPS:-false}"
PULP_UI="${PULP_UI:-false}"
PULP_DOMAIN_ENABLED="${PULP_DOMAIN_ENABLED:-false}"
PULP_STATIC_ROOT="${PULP_STATIC_ROOT:-/var/lib/operator/static/}"

export PULP_API_HOST PULP_CONTENT_HOST PULP_CONTENT_PATH PULP_API_ROOT

# Resolve nameserver for DNS-based service discovery
# https://serverfault.com/a/821625/189494
if [ "${container}" = "podman" ]; then
  NAMESERVER=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
else
  NAMESERVER=$(awk '/^nameserver/{print $2}' /etc/resolv.conf | tr '\n' ' ')
fi
export NAMESERVER
echo "Nameserver is: ${NAMESERVER}"

TEMPLATES=/etc/nginx/pulp-web/templates
SERVER_D=/etc/nginx/pulp-web/server.d
LOCATION_D=/etc/nginx/pulp-web/location.d
HTTP_D=/etc/nginx/pulp-web/http.d

# Clean any previously-generated snippets
rm -f "${SERVER_D}"/*.conf "${LOCATION_D}"/*.conf "${HTTP_D}"/*.conf

# --- Listen / SSL ---
if [ "${PULP_HTTPS}" = "true" ]; then
  echo "Enabling HTTPS"
  cp "${TEMPLATES}/listen-https.conf" "${SERVER_D}/listen.conf"
  cp "${TEMPLATES}/http-redirect.conf" "${HTTP_D}/redirect.conf"
  cp "${TEMPLATES}/acme.conf"          "${LOCATION_D}/acme.conf"
else
  cp "${TEMPLATES}/listen-http.conf" "${SERVER_D}/listen.conf"
fi

# --- Domain-enabled routes ---
if [ "${PULP_DOMAIN_ENABLED}" = "true" ]; then
  echo "Enabling domain routes"
  envsubst '${PULP_API_ROOT}' \
    < "${TEMPLATES}/domains.conf.template" \
    > "${LOCATION_D}/domains.conf"
fi

# --- UI ---
if [ "${PULP_UI}" != "false" ] && [ -n "${PULP_UI}" ]; then
  PULP_UI_STATIC="${PULP_STATIC_ROOT}pulp_ui/"
  # Strip trailing "static/pulp_ui/" to get the root for nginx's root directive
  PULP_UI_ROOT=$(echo "${PULP_UI_STATIC}" | sed 's|static/pulp_ui/$||')
  export PULP_UI_STATIC PULP_UI_ROOT
  if [ -d "${PULP_UI_STATIC}" ] && [ "$(ls -A "${PULP_UI_STATIC}" 2>/dev/null)" ]; then
    echo "Enabling UI (serving from ${PULP_UI_STATIC})"
    envsubst '${PULP_UI_STATIC} ${PULP_UI_ROOT}' \
      < "${TEMPLATES}/ui.conf.template" \
      > "${LOCATION_D}/ui.conf"
  else
    echo "Warning: PULP_UI is set but no files found at ${PULP_UI_STATIC}, skipping UI"
  fi
fi

# --- Main config ---
echo "Generating nginx.conf"
envsubst '${NAMESERVER} ${PULP_API_HOST} ${PULP_CONTENT_HOST} ${PULP_CONTENT_PATH} ${PULP_API_ROOT}' \
  < "${TEMPLATES}/nginx.conf.template" \
  > /etc/nginx/nginx.conf

# --- Plugin snippets ---
# Rewrite upstream references so nginx uses the resolver-backed variables
# instead of static upstream names.
for file in /etc/nginx/pulp/*.conf; do
  [ -f "${file}" ] || continue
  echo "Rewriting upstream references in ${file}"
  sed -i 's|proxy_pass http://pulp-api|proxy_pass http://$pulp_api:24817|g' "${file}"
  sed -i 's|proxy_pass http://pulp-content|proxy_pass http://$pulp_content:24816|g' "${file}"
done

echo "Starting nginx"
exec nginx -g "daemon off;"
