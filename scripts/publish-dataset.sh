#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ALLOW_REPLACE_EXISTING="${ALLOW_REPLACE_EXISTING:-false}"

case "${ALLOW_REPLACE_EXISTING}" in
  true|false)
    ;;
  *)
    fail "ALLOW_REPLACE_EXISTING must be true or false"
    ;;
esac

SOURCE_DIRECTORY="${1:-data/work/merged}"
DATASET_VERSION="${2:-local}"
RELEASES_DIRECTORY="${3:-data/releases}"

if [[ "${SOURCE_DIRECTORY}" != /* ]]; then
  SOURCE_DIRECTORY="${PROJECT_ROOT}/${SOURCE_DIRECTORY}"
fi

if [[ "${RELEASES_DIRECTORY}" != /* ]]; then
  RELEASES_DIRECTORY="${PROJECT_ROOT}/${RELEASES_DIRECTORY}"
fi

[[ -d "${SOURCE_DIRECTORY}" ]] \
  || fail "Source directory not found: ${SOURCE_DIRECTORY}"

[[ "${DATASET_VERSION}" =~ ^[a-zA-Z0-9._-]+$ ]] \
  || fail "Invalid dataset version: ${DATASET_VERSION}"

shopt -s nullglob
graph_files=("${SOURCE_DIRECTORY}"/region.osrm*)
shopt -u nullglob

[[ "${#graph_files[@]}" -gt 0 ]] \
  || fail "No region.osrm files found in ${SOURCE_DIRECTORY}"

# Determine algorithm based on generated files
if [[ -f "${SOURCE_DIRECTORY}/region.osrm.hsgr" ]]; then
  ALGORITHM="ch"
  log_info "Detected CH algorithm (region.osrm.hsgr present)"
elif [[ -f "${SOURCE_DIRECTORY}/region.osrm.partition" ]]; then
  ALGORITHM="mld"
  log_info "Detected MLD algorithm (region.osrm.partition present)"
else
  fail "Unable to determine algorithm: neither .hsgr (CH) nor .partition (MLD) found"
fi

# Validate required files per algorithm
if [[ "${ALGORITHM}" == "ch" ]]; then
  [[ -f "${SOURCE_DIRECTORY}/region.osrm.hsgr" ]] \
    || fail "Missing required file for CH: region.osrm.hsgr"
else
  [[ -f "${SOURCE_DIRECTORY}/region.osrm.partition" ]] \
    || fail "Missing required file for MLD: region.osrm.partition"
  [[ -f "${SOURCE_DIRECTORY}/region.osrm.cells" ]] \
    || fail "Missing required file for MLD: region.osrm.cells"
fi

ensure_directory "${RELEASES_DIRECTORY}"

target_directory="${RELEASES_DIRECTORY}/${DATASET_VERSION}"
temporary_directory="${RELEASES_DIRECTORY}/.${DATASET_VERSION}.tmp"
backup_directory="${RELEASES_DIRECTORY}/.${DATASET_VERSION}.previous"

if [[ -d "${target_directory}" ]] \
  && [[ "${ALLOW_REPLACE_EXISTING}" == "false" ]]; then
  fail "Dataset version already exists and replacement is disabled: ${DATASET_VERSION}"
fi

log_info "Publishing OSRM dataset"
log_info "Version: ${DATASET_VERSION}"
log_info "Files: ${#graph_files[@]}"

rm -rf "${temporary_directory}"
mkdir -p "${temporary_directory}"

for graph_file in "${graph_files[@]}"; do
  cp "${graph_file}" "${temporary_directory}/"
done

published_files_count="$(
  find "${temporary_directory}" \
    -maxdepth 1 \
    -type f \
    -name 'region.osrm*' \
    | wc -l \
    | tr -d ' '
)"

[[ "${published_files_count}" -eq "${#graph_files[@]}" ]] \
  || fail "Not all graph files were copied"

rm -rf "${backup_directory}"

if [[ -d "${target_directory}" ]]; then
  mv "${target_directory}" "${backup_directory}"
fi

if ! mv "${temporary_directory}" "${target_directory}"; then
  log_error "Unable to activate dataset version: ${DATASET_VERSION}"

  if [[ -d "${backup_directory}" ]]; then
    mv "${backup_directory}" "${target_directory}"
  fi

  exit 1
fi

rm -rf "${backup_directory}"

log_info "Dataset published successfully"
log_info "Target: ${target_directory}"
log_info "Files published: ${published_files_count}"
