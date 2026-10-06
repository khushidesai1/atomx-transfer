#!/usr/bin/env bash
#
# sftp_inventory.sh
# Lists DecodedFiles/ and flatFiles/ for each AtoMx export root, so you can see which samples
# an export contains before transferring. Generalizes the hand-written sftp batch files.
#
# Usage:
#   export SFTP_PASSWORD=...   (or set ATOMX_PASSWORD_FILE)
#   ./sftp_inventory.sh /MyExport_17_08_2026_10_31_17_209 [/AnotherExport_... ...]
#   ./sftp_inventory.sh            # no roots: list the top level of the export server
#
# Requires sshpass.
set -uo pipefail

SFTP_HOST="${ATOMX_SFTP_HOST:-na.export.atomx.nanostring.com}"
SFTP_USER="${ATOMX_SFTP_USER:-}"
SFTP_PORT="${ATOMX_SFTP_PORT:-22}"

if [[ -z "$SFTP_USER" ]]; then
  echo "ERROR: ATOMX_SFTP_USER is not set. See examples/env.example." >&2
  exit 1
fi
if [[ -z "${SFTP_PASSWORD:-}" && -r "${ATOMX_PASSWORD_FILE:-}" ]]; then
  SFTP_PASSWORD="$(cat "$ATOMX_PASSWORD_FILE")"
fi
if [[ -z "${SFTP_PASSWORD:-}" ]]; then
  echo "ERROR: set SFTP_PASSWORD or ATOMX_PASSWORD_FILE." >&2
  exit 1
fi
export SSHPASS="$SFTP_PASSWORD"

BATCH="$(mktemp)"
trap 'rm -f "$BATCH"' EXIT
if [[ $# -eq 0 ]]; then
  echo "ls -1 /" >> "$BATCH"
else
  for root in "$@"; do
    echo "ls -1 ${root}/DecodedFiles" >> "$BATCH"
    echo "ls -1 ${root}/flatFiles" >> "$BATCH"
  done
fi
echo "bye" >> "$BATCH"

# Commands go on stdin, like get_tma.sh: `sftp -b` forces BatchMode, which disables password auth.
sshpass -e sftp -o "Port=${SFTP_PORT}" -o "StrictHostKeyChecking=accept-new" \
  "${SFTP_USER}@${SFTP_HOST}" < "$BATCH"
