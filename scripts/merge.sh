#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")"
  pwd
)"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

RAW_DIRECTORY="${1:-data/work/raw}"
OUTPUT_FILE="${2:-data/work/merged/region.osm.pbf}"

if [[ "${RAW_DIRECTORY}" != /* ]]; then
  RAW_DIRECTORY="${PROJECT_ROOT}/${RAW_DIRECTORY}"
fi

if [[ "${OUTPUT_FILE}" != /* ]]; then
  OUTPUT_FILE="${PROJECT_ROOT}/${OUTPUT_FILE}"
fi

require_command osmium

[[ -d "${RAW_DIRECTORY}" ]] \
  || fail "Raw data directory not found: ${RAW_DIRECTORY}"

ensure_directory "$(dirname "${OUTPUT_FILE}")"

shopt -s nullglob
input_files=("${RAW_DIRECTORY}"/*.osm.pbf)
shopt -u nullglob

input_count="${#input_files[@]}"

[[ "${input_count}" -gt 0 ]] \
  || fail "No .osm.pbf files found in ${RAW_DIRECTORY}"

temporary_file="$(dirname "${OUTPUT_FILE}")/region.tmp.osm.pbf"

rm -f "${temporary_file}"

log_info "Preparing merged OSM dataset"
log_info "Input files: ${input_count}"

for input_file in "${input_files[@]}"; do
  log_info "Input: $(basename "${input_file}")"
done

if [[ "${input_count}" -eq 1 ]]; then
  log_info "Only one region found. Merge is not required."
  cp "${input_files[0]}" "${temporary_file}"
else
  log_info "Merging ${input_count} regions with Osmium"

  osmium merge \
    "${input_files[@]}" \
    --overwrite \
    --output "${temporary_file}"
fi

log_info "Validating merged dataset"

osmium fileinfo "${temporary_file}" >/dev/null \
  || fail "Generated merged dataset is invalid"

mv "${temporary_file}" "${OUTPUT_FILE}"

file_size="$(du -h "${OUTPUT_FILE}" | cut -f1)"

log_info "Merged dataset generated successfully"
log_info "Output: ${OUTPUT_FILE}"
log_info "Size: ${file_size}"
