#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

INPUT_FILE="${1:-data/work/merged/region.osm.pbf}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"

if [[ "${INPUT_FILE}" != /* ]]; then
  INPUT_FILE="${PROJECT_ROOT}/${INPUT_FILE}"
fi

[[ -f "${INPUT_FILE}" ]] \
  || fail "Merged OSM file not found: ${INPUT_FILE}"

require_command docker

OSRM_ALGORITHM="$(grep '^OSRM_ALGORITHM=' "${ENV_FILE}" | tail -n 1 | cut -d '=' -f 2- || echo 'mld')"
OSRM_ALGORITHM="$(printf '%s' "${OSRM_ALGORITHM}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

ALGORITHM_FLAG=""
if [[ "${OSRM_ALGORITHM}" == "ch" ]]; then
  ALGORITHM_FLAG="--ch"
fi

log_info "Building with algorithm: ${OSRM_ALGORITHM}"

INPUT_RELATIVE="${INPUT_FILE#"${PROJECT_ROOT}/data/"}"

[[ "${INPUT_RELATIVE}" != "${INPUT_FILE}" ]] \
  || fail "Input file must be located inside ${PROJECT_ROOT}/data"

INPUT_DIRECTORY="$(dirname "${INPUT_FILE}")"
INPUT_FILENAME="$(basename "${INPUT_FILE}")"

OUTPUT_BASENAME="${INPUT_FILENAME%.osm.pbf}.osrm"
OUTPUT_BASE="${INPUT_DIRECTORY}/${OUTPUT_BASENAME}"
OUTPUT_RELATIVE="${INPUT_RELATIVE%.osm.pbf}.osrm"

log_info "Removing previous graph files"

find "${INPUT_DIRECTORY}" \
  -maxdepth 1 \
  -type f \
  -name "${OUTPUT_BASENAME}*" \
  -delete

log_info "Running osrm-extract"

docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --profile tools run --rm osrm-builder \
  osrm-extract \
  -p /opt/car.lua \
  "/data/${INPUT_RELATIVE}"

if [[ "${OSRM_ALGORITHM}" == "ch" ]]; then
  log_info "Running osrm-contract (CH algorithm)"

  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --profile tools run --rm osrm-builder \
    osrm-contract \
    "/data/${OUTPUT_RELATIVE}"

  log_info "Skipping osrm-customize for CH (optional for CH, required only with turn penalties)"
else
  log_info "Running osrm-partition (MLD algorithm)"

  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --profile tools run --rm osrm-builder \
    osrm-partition \
    "/data/${OUTPUT_RELATIVE}"

  log_info "Running osrm-customize (MLD algorithm)"

  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --profile tools run --rm osrm-builder \
    osrm-customize \
    "/data/${OUTPUT_RELATIVE}"
fi

generated_files_count="$(
  find "${INPUT_DIRECTORY}" \
    -maxdepth 1 \
    -type f \
    -name "${OUTPUT_BASENAME}*" \
    | wc -l \
    | tr -d ' '
)"

[[ "${generated_files_count}" -gt 0 ]] \
  || fail "No OSRM graph files were generated"

if [[ "${OSRM_ALGORITHM}" == "ch" ]]; then
  [[ -f "${OUTPUT_BASE}.hsgr" ]] \
    || fail "OSRM hsgr file was not generated (CH algorithm)"
else
  [[ -f "${OUTPUT_BASE}.partition" ]] \
    || fail "OSRM partition file was not generated (MLD algorithm)"
  [[ -f "${OUTPUT_BASE}.cells" ]] \
    || fail "OSRM cells file was not generated (MLD algorithm)"
fi

log_info "OSRM graph generated successfully (${OSRM_ALGORITHM})"
log_info "Generated files: ${generated_files_count}"
log_info "Output base: ${OUTPUT_BASE}"
