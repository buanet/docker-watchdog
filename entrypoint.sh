#!/bin/sh

set -e
set -o pipefail

DOCKER_SOCK=${DOCKER_SOCK:-/var/run/docker.sock}
CURL_TIMEOUT=${CURL_TIMEOUT:-30}

# SIGTERM-handler
term_handler() {
  exit 143; # 128 + 15 -- SIGTERM
}

docker_curl() {
  curl --max-time "${CURL_TIMEOUT}" --no-buffer -s --unix-socket "${DOCKER_SOCK}" "$@" || return 1
  return 0
}

trap 'kill ${!}; term_handler' SIGTERM

if [ "$1" = 'healthcheck' ]; then
  docker_curl --fail http://localhost/_ping
  exit $?
fi

if [ "$1" = 'watchdog' ] && [ -e ${DOCKER_SOCK} ]; then

  # https://docs.docker.com/engine/api/v1.25/

  # Set container selector
  if [ "$WATCHDOG_CONTAINER_LABEL" == "all" ]; then
    labelFilter=""
  else
    labelFilter=",\"label\":\[\"${WATCHDOG_CONTAINER_LABEL:=watchdog}=true\"\]"
  fi

  WATCHDOG_START_PERIOD=${WATCHDOG_START_PERIOD:=0}
  echo "Monitoring containers for unhealthy status $([ "${WATCHDOG_START_PERIOD}" != 0 ] && echo "in ${WATCHDOG_START_PERIOD} second(s)")"
  sleep ${WATCHDOG_START_PERIOD}

  while true; do
    sleep ${WATCHDOG_INTERVAL:=5}

    apiUrl="http://localhost/containers/json?filters=\{\"health\":\[\"unhealthy\"\]${labelFilter}\}"
    stopTimeout=".Labels[\"watchdog.stop.timeout\"] // ${WATCHDOG_DEFAULT_STOP_TIMEOUT:-10}"
    docker_curl "$apiUrl" | \
    jq -r "foreach .[] as \$CONTAINER([];[]; \$CONTAINER | .Id, .Names[0], $stopTimeout )" | \
    while read -r CONTAINER_ID && read -r CONTAINER_NAME && read -r TIMEOUT; do
        CONTAINER_SHORT_ID=${CONTAINER_ID:0:12}
        DATE=$(date +%d-%m-%Y" "%H:%M:%S)
        if [ "null" = "$CONTAINER_NAME" ]; then
          echo "$DATE Container name of ($CONTAINER_SHORT_ID) is null, which implies container does not exist - don't restart"
        else
          echo "$DATE Container ${CONTAINER_NAME} ($CONTAINER_SHORT_ID) found to be unhealthy - Restarting container now with ${TIMEOUT}s timeout"
          docker_curl -f -XPOST "http://localhost/containers/${CONTAINER_ID}/restart?t=${TIMEOUT}" \
            || echo "$DATE Restarting container $CONTAINER_SHORT_ID failed"
        fi
    done
  done

else
  exec "$@"
fi
