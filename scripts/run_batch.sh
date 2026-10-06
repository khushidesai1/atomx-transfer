#!/usr/bin/env bash
#
# run_batch.sh
# Runs get_tma.sh (raw) or get_tma_addfiles.sh (additional files) for every sample listed in a
# batch file, one at a time, and stops at the first failure. Optionally posts STARTED / SUCCESS /
# FAILURE updates to a Slack incoming webhook.
#
# This replaces the per-batch runner scripts (tma_raw_runner.sh, tma_addfiles_runner.sh, ...),
# which differed only in their hardcoded sample lists.
#
# Usage:
#   ./run_batch.sh raw        <batch.tsv>
#   ./run_batch.sh additional <batch.tsv>
#
# Batch file: one sample per line, tab- or space-separated, '#' comments allowed:
#   <export_root>  <remote_sample>  [gcs_sample]
# gcs_sample defaults to remote_sample (use it when the AtoMx name differs from the bucket name).
# See examples/batch.example.tsv.
#
# Environment (see examples/env.example):
#   ATOMX_PASSWORD_FILE  file containing the SFTP password (default: ~/.tma_sftp_password)
#   SLACK_WEBHOOK_FILE   optional file containing a Slack webhook URL (default: ~/.slack_tma_webhook)
#   plus everything get_tma.sh / get_tma_addfiles.sh need (ATOMX_SFTP_USER, GCS_*_DEST_BASE)
#
set -uo pipefail

KIND="${1:-}"
BATCH_FILE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSWORD_FILE="${ATOMX_PASSWORD_FILE:-${HOME}/.tma_sftp_password}"
WEBHOOK_FILE="${SLACK_WEBHOOK_FILE:-${HOME}/.slack_tma_webhook}"

case "$KIND" in
  raw) SCRIPT="${SCRIPT_DIR}/get_tma.sh" ;;
  additional) SCRIPT="${SCRIPT_DIR}/get_tma_addfiles.sh" ;;
  *)
    echo "Usage: $0 raw|additional <batch.tsv>" >&2
    exit 1
    ;;
esac

RUN_LOG="${PWD}/run_batch_${KIND}_$(date +%Y%m%d_%H%M%S).log"

post_slack() {
  local status="$1"
  local sample="$2"
  local message="$3"
  [[ -r "$WEBHOOK_FILE" ]] || return 0
  local webhook
  local payload
  webhook="$(cat "$WEBHOOK_FILE")"
  payload="$(
    python3 - "$status" "$sample" "$message" <<'PY'
import json
import sys

print(json.dumps({
    "status": sys.argv[1],
    "sample": sys.argv[2],
    "message": sys.argv[3],
}))
PY
  )"

  curl -fsS -X POST \
    -H 'Content-type: application/json' \
    --data "$payload" \
    "$webhook" >/dev/null || true
}

run_one() {
  local root_dir="$1"
  local remote_sample="$2"
  local gcs_sample="${3:-$remote_sample}"
  local output_file
  output_file="$(mktemp)"

  echo "=== ${gcs_sample} ${KIND} started at $(date) ===" | tee -a "$RUN_LOG"
  post_slack "STARTED" "$gcs_sample" "Started ${KIND} transfer from ${root_dir}; SFTP sample=${remote_sample}"

  export SFTP_PASSWORD
  SFTP_PASSWORD="$(cat "$PASSWORD_FILE")"

  if [[ "$KIND" == "raw" ]]; then
    # get_tma.sh uploads the local folder by name, so the local folder name is the bucket name.
    "$SCRIPT" "$root_dir" "$remote_sample" "$gcs_sample" 2>&1 | tee "$output_file" | tee -a "$RUN_LOG"
  else
    "$SCRIPT" "$root_dir" "$remote_sample" "${gcs_sample}_additional" "$gcs_sample" 2>&1 \
      | tee "$output_file" | tee -a "$RUN_LOG"
  fi
  local exit_code="${PIPESTATUS[0]}"

  if [[ "$exit_code" -eq 0 ]] && grep -qx 'SUCCESS' "$output_file"; then
    echo "=== ${gcs_sample} ${KIND} SUCCESS at $(date) ===" | tee -a "$RUN_LOG"
    post_slack "SUCCESS" "$gcs_sample" "${KIND} transfer completed and uploaded to GCS"
    rm -f "$output_file"
    return 0
  fi

  local missing_success="yes"
  if grep -qx 'SUCCESS' "$output_file"; then
    missing_success="no"
  fi
  echo "=== ${gcs_sample} ${KIND} FAILURE at $(date); exit=${exit_code}; missing_success=${missing_success} ===" | tee -a "$RUN_LOG"
  post_slack "FAILURE" "$gcs_sample" "Stopping remaining ${KIND} transfers. exit=${exit_code}; missing_success=${missing_success}; log=${RUN_LOG}"
  rm -f "$output_file"
  return 1
}

main() {
  if [[ ! -r "$BATCH_FILE" || ! -r "$PASSWORD_FILE" || ! -x "$SCRIPT" ]]; then
    echo "Missing batch file, password file (${PASSWORD_FILE}), or executable ${SCRIPT}." >&2
    exit 1
  fi

  post_slack "STARTED" "${KIND} batch" "${KIND} batch from $(basename "$BATCH_FILE") started on $(hostname). Log: ${RUN_LOG}"

  local root_dir remote_sample gcs_sample
  while read -r root_dir remote_sample gcs_sample _; do
    [[ -z "${root_dir:-}" || "$root_dir" == \#* ]] && continue
    run_one "$root_dir" "$remote_sample" "${gcs_sample:-}" || exit 1
  done < "$BATCH_FILE"

  post_slack "SUCCESS" "${KIND} batch" "All ${KIND} transfers in $(basename "$BATCH_FILE") completed."
  echo "ALL SUCCESS" | tee -a "$RUN_LOG"
}

main "$@"
