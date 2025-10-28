#!/bin/bash

set -x

trap 'echo Received SIGTERM; exit 0' TERM

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/utils.sh"

HOME="${HOME:-/root}"
export CONFIG_PATH="/system.json"
LAST_CONFIG_PATH="/system_next.json"

INSTALL_MENU="$(jq -r '.install_menu' "${CONFIG_PATH}")"
if [[ "${INSTALL_MENU}" = "true" ]]; then
  "${SCRIPT_DIR}/dialog-maintenance.sh" --install
fi

"${SCRIPT_DIR}/dialog-reports.sh" &

action_on_failure() {
  sleep 60
  if [[ -f "/data/run-update" || "${UPDATE}" = "1" ]]; then
    report_alert "cuos:update:rollback" "Failed to start application. Update aborted. Rolling back changes and rebooting system"
    "${SCRIPT_DIR}/do-rollback.sh" "Failed to start application. Update aborted. Rolling back changes and rebooting system"
  else
    report_crit "cuos:startup:failed" "Failed to start application. Startup failed. Trying update"
    "${SCRIPT_DIR}/api.sh" update
    sleep 30
    # no update needed, so reboot
    report_crit "cuos:startup:failed_reboot" "Failed to start application. Startup failed. Trying reboot"
    sync
    /sbin/reboot
  fi
  exit 1
}

START_TIME=$(date +%s)
check_rollback() {
  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [[ $ELAPSED -ge 3600 ]]; then
    report_err "cuos:startup:timedout" "System start or update took too long"
    action_on_failure
  fi
  return 0
}

# Ensure that the image with the desired digest is available (try an infinite number of times)
download_image() {
  IMAGE_PATH="$1"
  IMAGE_DIGEST="$2"

  OLD_IMAGE_PATH="$(docker inspect --format='{{.Image}}' "${CONTAINER_NAME}")"
  OLD_IMAGE_PATH="${OLD_IMAGE_PATH:-"${IMAGE_PATH}"}"

  OLD_IMAGE_DIGEST=$(docker image inspect --format '{{index .RepoDigests 0}}' "${OLD_IMAGE_PATH}" 2>/dev/null | cut -d'@' -f2)
  if [[ -n "${OLD_IMAGE_DIGEST}" && "${OLD_IMAGE_DIGEST}" = "${IMAGE_DIGEST}" ]]; then
    # Image already exists with the correct digest
    return 2
  fi

  while true; do
    check_rollback
    echo "Pulling $IMAGE_PATH ... (Digest should be ${IMAGE_DIGEST})"
    if docker pull "${INITIAL_IMAGE}"; then
      CURRENT_IMAGE_DIGEST=$(docker image inspect --format '{{index .RepoDigests 0}}' "${IMAGE_PATH}" 2>/dev/null | cut -d'@' -f2)
      if [[ -n "${CURRENT_IMAGE_DIGEST}" && "${CURRENT_IMAGE_DIGEST}" = "${IMAGE_DIGEST}" ]]; then
        return 0
      fi
      if [[ -n "${CURRENT_IMAGE_DIGEST}" && "${IMAGE_DIGEST}" = "" ]]; then
        if [[ "${CURRENT_IMAGE_DIGEST}" = "${OLD_IMAGE_DIGEST}" ]]; then
          # Image already exists with the correct digest
          return 2
        else
          return 0
        fi
      fi
      report_err "cuos:application:digest_check_failed" "Security: Digest check failed for initial image ${INITIAL_IMAGE}. Please consult your system provider. Trying to pull the image again in 60 seconds."
    else
      report_err "cuos:application:upstart_failed" "Failed to pull initial image ${INITIAL_IMAGE}. Check your network configuration, firewall settings or proxy certificates. Trying to pull the image again in 60 seconds."
    fi
    # Remove image, with incorrect digest:
    docker image rm -f "${INITIAL_IMAGE}" 2>/dev/null
    sleep 60
  done
}

CONTAINER_NAME="cuos-app"
if ! INITIAL_IMAGE="$(image_url "init" || image_url "initial")"; then
  report_err "cuos:application:image_not_defined" "Application image not defined"
  action_on_failure
fi
INITIAL_IMAGE_VERSION="$(image_version "${INITIAL_IMAGE}")"

LAST_INITIAL_IMAGE_VERSION="$(jq -r '.initial_image_version // empty' "${LAST_CONFIG_PATH}" 2>/dev/null)"
INITIAL_DIGEST="$(jq -r '.initial_image_digest // empty' "${CONFIG_PATH}")"


echo "Waiting for Docker to be ready..."
until docker info >/dev/null 2>&1; do
  check_rollback
  sleep 1
done

while ! "${SCRIPT_DIR}/utils-docker-login.sh"; do
  check_rollback
  echo "Retrying docker login in 5 seconds ..."
  sleep 5
done

IMAGE_RUNNING=$(docker image inspect --format '{{index .RepoDigests 0}}' "${INITIAL_IMAGE}" 2>/dev/null | cut -d'@' -f2)

UPDATE=0
if [[ -f "/data/run-update" || -z "${IMAGE_RUNNING}" ]]; then
  if download_image "${INITIAL_IMAGE}" "${INITIAL_DIGEST}"; then
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  fi
  UPDATE=1

  rm -f "/data/run-update"
fi
export UPDATE



# Check whether the container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
  # Check whether the container exists (but is stopped)
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    docker start "${CONTAINER_NAME}"
  else

    DOCKER_ARGS="$(docker inspect --format '{{ index .Config.Labels "dev.cuos.app_command" }}' "${INITIAL_IMAGE}")"
    if [[ -z "${DOCKER_ARGS}" ]]; then
      DOCKER_ARGS="\
        --device /dev/tty7 \
        --network=host \
        --volume /var/run/docker.sock:/var/run/docker.sock  \
        --volume /root/.docker/config.json:/root/.docker/config.json:ro  \
        --volume /system.json:/system.json:ro  \
        --volume /etc/partition_mode:/etc/partition_mode:ro  \
        --volume /var/run/cuos.sock:/var/run/cuos.sock  \
        --volume /usr/local/share/ca-certificates/custom:/usr/local/share/ca-certificates/custom:ro"
    fi

    touch "${HOME}/.docker/config.json"
    # shellcheck disable=SC2086
    if ! docker run \
      --detach \
      --pull=never \
      --restart always \
      --log-driver=journald \
      ${DOCKER_ARGS} \
      --env SYSTEM_TYPE="cuos" \
      --env SYSTEM_CONFIG_PATH="/system.json" \
      --env VIRT_TYPE="$(systemd-detect-virt)" \
      --name "${CONTAINER_NAME}" \
      "${INITIAL_IMAGE}" \
      "${INITIAL_IMAGE_VERSION}" "${LAST_INITIAL_IMAGE_VERSION}"; then
        report_err "cuos:application:failed" "Failed to run initial container with image ${INITIAL_IMAGE}"
        action_on_failure
    fi
  fi
fi

if [[ "${UPDATE}" -eq 1 ]]; then
  docker exec "${CONTAINER_NAME}" /api/update 2>/dev/null || true

  state '.state' 'running'
  state jq '.start_date = (now | todate)'

  report_notice "cuos:update:done" "System successfully updated."
fi

report_info "cuos:startup:done" "OS layer successfully started."

sleep infinity & wait
