#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  echo ::group::INFO
  podman exec pulp bash -c "pip3 list && pip3 install pipdeptree && pipdeptree"
  podman logs pulp
  echo ::endgroup::
  podman stop pulp
}
trap cleanup EXIT

start_container_and_wait() {
  podman run --detach \
             --publish 8080:$port \
             --name pulp \
             --volume "$(pwd)/settings":/etc/pulp:Z \
             --volume "$(pwd)/pulp_storage":/var/lib/pulp:Z \
             --volume "$(pwd)/pgsql":/var/lib/pgsql:Z \
             --volume "$(pwd)/containers":/var/lib/containers:Z \
             --device /dev/fuse \
             -e PULP_DEFAULT_ADMIN_PASSWORD=password \
             -e PULP_HTTPS=${pulp_https} \
             "$1"
  sleep 10
  for _ in $(seq 30)
  do
    sleep 3
    if curl --insecure --fail $scheme://localhost:8080/pulp/api/v3/status/ > /dev/null 2>&1
    then
      # We test it a 2nd time because otherwise there could be an error like:
      # curl: (35) OpenSSL SSL_connect: Connection reset by peer in connection to localhost:8080
      if curl --insecure --fail $scheme://localhost:8080/pulp/api/v3/status/ > /dev/null 2>&1
      then
        break
      fi
    fi
  done
  set -x
  curl --insecure --fail $scheme://localhost:8080/pulp/api/v3/status/ | jq
}


image=${1:-pulp/pulp:latest}
scheme=${2:-http}
old_image=${3:-""}
if [[ "$scheme" == "http" ]]; then
  port=80
  pulp_https=false
else
  port=443
  pulp_https=true
fi

mkdir -p settings pulp_storage pgsql containers
echo "CONTENT_ORIGIN='$scheme://localhost:8080'" >> settings/settings.py
echo "ALLOWED_EXPORT_PATHS = ['/tmp']" >> settings/settings.py
echo "ORPHAN_PROTECTION_TIME = 0" >> settings/settings.py
# pulp_rpm < 3.25 requires sha1 in allowed checksums
echo "ALLOWED_CONTENT_CHECKSUMS = ['sha1', 'sha256', 'sha512']" >> settings/settings.py

if [ "$old_image" != "" ]; then
  start_container_and_wait $old_image
  podman rm -f pulp
fi
start_container_and_wait $image

if [[ ${image} != *"galaxy"* ]];then
  curl --insecure --fail $scheme://localhost:8080/assets/rest_framework/js/default.js
  grep "127.0.0.1   pulp" /etc/hosts || echo "127.0.0.1   pulp" | sudo tee -a /etc/hosts

  echo "Installing Pulp-CLI"
  pip install pulp-cli

  # Retreive installed pulp-cli version
  PULP_CLI_VERSION=$(python3 -c \
    'import importlib.metadata; \
     from packaging.version import Version; \
     print(Version(importlib.metadata.version("pulp-cli")))')

  # Checkout git repo for pulp-cli at correct version to fetch tests
  if [ -d pulp-cli ]; then
    cd pulp-cli
    git fetch --tags origin
    git reset --hard $PULP_CLI_VERSION
  else
    git clone --depth=1 https://github.com/pulp/pulp-cli.git -b "${PULP_CLI_VERSION}"
    cd pulp-cli
  fi

  pip install -r test_requirements.txt || pip install --no-build-isolation -r test_requirements.txt

  if [ -e tests/cli.toml ]; then
    mv tests/cli.toml "tests/cli.toml.bak.$(date -R)"
  fi
  pulp config create --base-url $scheme://pulp:8080 --username "admin" --password "password" --no-verify-ssl --location tests/cli.toml
  if [[ "$scheme" == "https" ]];then
    podman cp pulp:/etc/pulp/certs/pulp_webserver.crt /tmp/pulp_webserver.crt
    sudo cp /tmp/pulp_webserver.crt /usr/local/share/ca-certificates/pulp_webserver.crt
    # Hack: adding pulp CA to certifi.where()
    CERTIFI=$(python -c 'import certifi; print(certifi.where())')
    cat /usr/local/share/ca-certificates/pulp_webserver.crt | sudo tee -a "$CERTIFI" > /dev/null
  fi
  echo "Setup the signing services"
  # Setup key on the Pulp container
  curl -L https://github.com/pulp/pulp-fixtures/raw/master/common/GPG-KEY-fixture-signing |podman exec -i pulp su pulp -c "cat > /tmp/GPG-KEY-fixture-signing"
  curl -L https://github.com/pulp/pulp-fixtures/raw/master/common/GPG-PRIVATE-KEY-fixture-signing |podman exec -i pulp su pulp -c "gpg --import"
  echo "0C1A894EBB86AFAE218424CADDEF3019C2D4A8CF:6:" |podman exec -i pulp gpg --import-ownertrust
  # Setup key on the test machine
  curl -L https://github.com/pulp/pulp-fixtures/raw/master/common/GPG-KEY-fixture-signing | cat > /tmp/GPG-KEY-pulp-qe
  curl -L https://github.com/pulp/pulp-fixtures/raw/master/common/GPG-PRIVATE-KEY-fixture-signing | gpg --import
  echo "0C1A894EBB86AFAE218424CADDEF3019C2D4A8CF:6:" | gpg --import-ownertrust
  echo "Setup ansible signing service"
  podman exec -u pulp -i pulp bash -c "cat > /var/lib/pulp/scripts/sign_detached.sh" < "${PWD}/tests/assets/sign_detached.sh"
  podman exec -u pulp pulp chmod a+rx /var/lib/pulp/scripts/sign_detached.sh
  podman exec -u pulp pulp bash -c "pulpcore-manager add-signing-service --class core:AsciiArmoredDetachedSigningService sign_ansible /var/lib/pulp/scripts/sign_detached.sh 'pulp-fixture-signing-key'"
  echo "Setup deb release signing service"
  podman exec -u pulp -i pulp bash -c "cat > /var/lib/pulp/scripts/sign_deb_release.sh" < "${PWD}/tests/assets/sign_deb_release.sh"
  podman exec -u pulp pulp chmod a+rx /var/lib/pulp/scripts/sign_deb_release.sh
  podman exec -u pulp pulp bash -c "pulpcore-manager add-signing-service --class deb:AptReleaseSigningService sign_deb_release /var/lib/pulp/scripts/sign_deb_release.sh 'pulp-fixture-signing-key'"
  make test
else
  curl --insecure --fail $scheme://localhost:8080/static/galaxy_ng/index.html
fi
