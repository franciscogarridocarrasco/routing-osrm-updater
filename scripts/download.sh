#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ALLOW_STALE_DATASET="${ALLOW_STALE_DATASET:-true}"

case "${ALLOW_STALE_DATASET}" in
  true|false)
    ;;
  *)
    fail "ALLOW_STALE_DATASET must be true or false"
    ;;
esac

REGIONS_FILE="${1:-config/regions/local.txt}"
RAW_DIRECTORY="${2:-data/work/raw}"

if [[ "${REGIONS_FILE}" != /* ]]; then
  REGIONS_FILE="${PROJECT_ROOT}/${REGIONS_FILE}"
fi

if [[ "${RAW_DIRECTORY}" != /* ]]; then
  RAW_DIRECTORY="${PROJECT_ROOT}/${RAW_DIRECTORY}"
fi

require_command curl
require_command osmium

[[ -f "${REGIONS_FILE}" ]] \
  || fail "Regions file not found: ${REGIONS_FILE}"

ensure_directory "${RAW_DIRECTORY}"

downloaded_count=0

while IFS='|' read -r raw_name raw_url || [[ -n "${raw_name:-}" ]]; do
  name="$(trim "${raw_name:-}")"
  url="$(trim "${raw_url:-}")"

  [[ -z "${name}" ]] && continue
  [[ "${name}" == \#* ]] && continue

  if ! [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    fail "Invalid region name: ${name}"
  fi

  [[ -n "${url}" ]] \
    || fail "Missing URL for region: ${name}"

  target_file="${RAW_DIRECTORY}/${name}.osm.pbf"
  temporary_file="${RAW_DIRECTORY}/${name}.part.osm.pbf"

  log_info "Downloading region '${name}'"
  log_info "Source: ${url}"

  rm -f "${temporary_file}"

  if ! curl \
    --fail \
    --location \
    --show-error \
    --silent \
    --retry 5 \
    --retry-delay 3 \
    --retry-all-errors \
    --connect-timeout 20 \
    --output "${temporary_file}" \
    "${url}"; then

    rm -f "${temporary_file}"

    if [[ "${ALLOW_STALE_DATASET}" == "true" ]] \
      && [[ -f "${target_file}" ]] \
      && osmium fileinfo "${target_file}" >/dev/null 2>&1; then
      log_warn "Unable to refresh region '${name}'. Using existing valid file: ${target_file}"
      downloaded_count=$((downloaded_count + 1))
      continue
    fi

    if [[ "${ALLOW_STALE_DATASET}" == "false" ]]; then
      fail "Unable to download region '${name}' and stale data is not allowed"
    fi

    fail "Unable to download region '${name}' and no valid local file is available"
  fi

  log_info "Validating ${temporary_file}"

  if ! osmium fileinfo "${temporary_file}" >/dev/null 2>&1; then
    rm -f "${temporary_file}"
    fail "Invalid OSM PBF file downloaded for region: ${name}"
  fi

  mv "${temporary_file}" "${target_file}"

  file_size="$(du -h "${target_file}" | cut -f1)"
  log_info "Region '${name}' downloaded successfully: ${file_size}"

  downloaded_count=$((downloaded_count + 1))
done < "${REGIONS_FILE}"

[[ "${downloaded_count}" -gt 0 ]] \
  || fail "No regions were found in ${REGIONS_FILE}"

log_info "Download completed. Regions downloaded: ${downloaded_count}"
