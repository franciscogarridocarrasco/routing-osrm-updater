#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  printf 'Usage: %s <country> [release-version]\n' "$(basename "$0")" >&2
  printf 'Uses config/regions/<country>.txt and publishes under data/releases.\n' >&2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ "$#" -ge 1 && "$#" -le 2 ]] || {
  usage
  fail "Expected a country and optional release version"
}

COUNTRY="$1"
[[ "${COUNTRY}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "Invalid country name: ${COUNTRY}"

DATASET_VERSION="${2:-$(date -u +%Y%m%dT%H%M%SZ)-${COUNTRY}}"
[[ "${DATASET_VERSION}" =~ ^[a-zA-Z0-9._-]+$ ]] \
  || fail "Invalid dataset version: ${DATASET_VERSION}"

ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
UPDATER_COMPOSE_FILE="${UPDATER_COMPOSE_FILE:-compose.yaml}"
RELEASES_DIRECTORY="${RELEASES_DIRECTORY:-data/releases}"
REGIONS_FILE="${REGIONS_FILE:-config/regions/${COUNTRY}.txt}"
GCS_BUCKET="${GCS_BUCKET:-gs://adeo-ccdp-delta-routing-engine-prep}"

for variable in ENV_FILE UPDATER_COMPOSE_FILE RELEASES_DIRECTORY REGIONS_FILE; do
  value="${!variable}"
  if [[ "${value}" != /* ]]; then
    printf -v "${variable}" '%s/%s' "${PROJECT_ROOT}" "${value}"
  fi
done

[[ -f "${ENV_FILE}" ]] || fail "Environment file not found: ${ENV_FILE}"
[[ -f "${UPDATER_COMPOSE_FILE}" ]] \
  || fail "Compose file not found: ${UPDATER_COMPOSE_FILE}"
[[ "${GCS_BUCKET}" =~ ^gs://[^/]+/?$ ]] \
  || fail "GCS_BUCKET must be a bucket URI, for example gs://my-bucket"
[[ -s "${PROJECT_ROOT}/config/profiles/car-distance.lua" ]] \
  || fail "OSRM profile is missing or empty: config/profiles/car-distance.lua"
[[ -f "${REGIONS_FILE}" ]] || fail "Country regions file not found: ${REGIONS_FILE}"

case "${REGIONS_FILE}" in
  "${PROJECT_ROOT}"/*)
    regions_file_relative="${REGIONS_FILE#"${PROJECT_ROOT}/"}"
    ;;
  *)
    fail "Country regions file must be inside the project: ${REGIONS_FILE}"
    ;;
esac

region_count=0
while IFS='|' read -r raw_name raw_url || [[ -n "${raw_name:-}" ]]; do
  name="$(trim "${raw_name:-}")"
  url="$(trim "${raw_url:-}")"

  [[ -z "${name}" || "${name}" == \#* ]] && continue
  [[ "${name}" == "${COUNTRY}" ]] \
    || fail "Expected region '${COUNTRY}' in ${REGIONS_FILE}, found '${name}'"
  [[ -n "${url}" ]] || fail "Missing URL for region '${COUNTRY}' in ${REGIONS_FILE}"
  [[ "${url}" == https://* ]] \
    || fail "Expected an HTTPS download URL for region '${COUNTRY}'"
  [[ "${url}" != *'|'* ]] \
    || fail "Expected exactly one name|URL pair per region line"
  region_count=$((region_count + 1))
done < "${REGIONS_FILE}"

[[ "${region_count}" -eq 1 ]] \
  || fail "Expected exactly one '${COUNTRY}' region in ${REGIONS_FILE}"

target_directory="${RELEASES_DIRECTORY}/${DATASET_VERSION}"
[[ ! -e "${target_directory}" ]] \
  || fail "Dataset version already exists: ${DATASET_VERSION}"

work_directory="data/work/countries/${COUNTRY}"
raw_directory="${work_directory}/raw"
merged_directory="${work_directory}/merged"
merged_file="${merged_directory}/region.osm.pbf"

require_command docker
require_command gcloud

cd "${PROJECT_ROOT}"

log_info "Country: ${COUNTRY}"
log_info "Version: ${DATASET_VERSION}"
log_info "Work directory: ${work_directory}"
log_info "Release directory: ${target_directory}"

docker compose \
  -f "${UPDATER_COMPOSE_FILE}" \
  --env-file "${ENV_FILE}" \
  --profile tools \
  run --rm \
  -e ALLOW_STALE_DATASET=false \
  data-tools \
  ./scripts/download.sh "${regions_file_relative}" "${raw_directory}"

country_file="${raw_directory}/${COUNTRY}.osm.pbf"
[[ -f "${country_file}" ]] \
  || fail "Country extract was not downloaded: ${country_file}"

shopt -s nullglob
raw_files=("${raw_directory}"/*.osm.pbf)
shopt -u nullglob
[[ "${#raw_files[@]}" -eq 1 ]] \
  || fail "Expected exactly one country extract in ${raw_directory}"

docker compose \
  -f "${UPDATER_COMPOSE_FILE}" \
  --env-file "${ENV_FILE}" \
  --profile tools \
  run --rm data-tools \
  ./scripts/merge.sh "${raw_directory}" "${merged_file}"

COMPOSE_FILE="${UPDATER_COMPOSE_FILE}" \
ENV_FILE="${ENV_FILE}" \
  "${SCRIPT_DIR}/build-graph.sh" "${merged_file}"

"${SCRIPT_DIR}/publish-dataset.sh" \
  "${merged_directory}" \
  "${DATASET_VERSION}" \
  "${RELEASES_DIRECTORY}"

log_info "Published dataset: ${target_directory}"
log_info "Uploading release to ${GCS_BUCKET}"
gcloud storage cp \
  --recursive \
  "${target_directory}" \
  "${GCS_BUCKET%/}/"

log_info "Country release uploaded successfully"
log_info "GCS destination: ${GCS_BUCKET%/}/${DATASET_VERSION}/"
