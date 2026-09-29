#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

PROJECT_ROOT="$(
  cd "${SCRIPT_DIR}"
  pwd
)"

PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-${PROJECT_ROOT}}"

# shellcheck source=scripts/lib/common.sh
source "${PROJECT_ROOT}/scripts/lib/common.sh"

NEW_VERSION="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
RELEASES_DIRECTORY="${RELEASES_DIRECTORY:-${PROJECT_ROOT}/data/releases}"
UPDATER_COMPOSE_FILE="${UPDATER_COMPOSE_FILE:-${PROJECT_ROOT}/compose.yaml}"
RUNTIME_COMPOSE_FILE="${RUNTIME_COMPOSE_FILE:-}"
REGIONS_FILE="${REGIONS_FILE:-config/regions/local.txt}"

require_command docker

[[ -f "${ENV_FILE}" ]] \
  || fail "Environment file not found: ${ENV_FILE}"

[[ "${NEW_VERSION}" =~ ^[a-zA-Z0-9._-]+$ ]] \
  || fail "Invalid dataset version: ${NEW_VERSION}"

previous_version="$(
  grep '^OSRM_DATASET_VERSION=' "${ENV_FILE}" \
    | tail -n 1 \
    | cut -d '=' -f 2-
)"

previous_version="$(trim "${previous_version}")"

[[ -n "${previous_version}" ]] \
  || fail "Unable to determine the currently active dataset version"

[[ -d "${RELEASES_DIRECTORY}/${previous_version}" ]] \
  || fail "Current dataset directory does not exist: ${previous_version}"

[[ ! -e "${RELEASES_DIRECTORY}/${NEW_VERSION}" ]] \
  || fail "Dataset version already exists: ${NEW_VERSION}"

log_info "Starting updater microservice workflow"
log_info "Current version: ${previous_version}"
log_info "New version: ${NEW_VERSION}"

log_info "Downloading fresh OpenStreetMap data"
docker compose \
  -f "${UPDATER_COMPOSE_FILE}" \
  --env-file "${ENV_FILE}" \
  --profile tools \
  run --rm \
  -e ALLOW_STALE_DATASET=false \
  data-tools \
  ./scripts/download.sh "${REGIONS_FILE}"

log_info "Merging OpenStreetMap extracts"
docker compose \
  -f "${UPDATER_COMPOSE_FILE}" \
  --env-file "${ENV_FILE}" \
  --profile tools \
  run --rm \
  data-tools \
  ./scripts/merge.sh data/work/raw data/work/merged/region.osm.pbf

log_info "Building OSRM graph"
(
  cd "${PROJECT_ROOT}"
  COMPOSE_FILE="${UPDATER_COMPOSE_FILE#${PROJECT_ROOT}/}" \
    ./scripts/build-graph.sh data/work/merged/region.osm.pbf
)

log_info "Publishing dataset version ${NEW_VERSION}"
"${PROJECT_ROOT}/scripts/publish-dataset.sh" \
  data/work/merged \
  "${NEW_VERSION}" \
  data/releases

if [[ -z "${RUNTIME_COMPOSE_FILE}" ]]; then
  log_info "Dataset build and publish completed successfully"
  log_info "Activation step skipped (RUNTIME_COMPOSE_FILE not configured)"
  exit 0
fi

log_info "Activating dataset version ${NEW_VERSION} in runtime microservice"

osrm_host_port="$({
  grep '^OSRM_HOST_PORT=' "${ENV_FILE}" \
    | tail -n 1 \
    | cut -d '=' -f 2-
} || true)"

osrm_host_port="$(trim "${osrm_host_port}")"
osrm_host_port="${osrm_host_port:-5001}"

if "${PROJECT_ROOT}/scripts/activate-dataset.sh" "${NEW_VERSION}" "${ENV_FILE}" \
  && docker compose -f "${RUNTIME_COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d --force-recreate osrm \
  && OSRM_BASE_URL="http://localhost:${osrm_host_port}" "${PROJECT_ROOT}/scripts/smoke-test.sh"; then
  log_info "Dataset update completed successfully"
  log_info "Active version: ${NEW_VERSION}"
  exit 0
fi

log_error "Dataset ${NEW_VERSION} failed after activation"
log_warn "Rolling back to ${previous_version}"

if "${PROJECT_ROOT}/scripts/activate-dataset.sh" "${previous_version}" "${ENV_FILE}" \
  && docker compose -f "${RUNTIME_COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d --force-recreate osrm \
  && OSRM_BASE_URL="http://localhost:${osrm_host_port}" "${PROJECT_ROOT}/scripts/smoke-test.sh"; then
  log_warn "Rollback completed successfully"
  log_warn "Active version restored: ${previous_version}"
  exit 1
fi

log_error "CRITICAL: automatic rollback failed"
log_error "Expected previous version: ${previous_version}"

exit 2
