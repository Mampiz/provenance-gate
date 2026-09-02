#!/usr/bin/env bash
# Records a verifier and renders it to a GIF.
#
# Usage: hack/record.sh <make-target> <asset-name>
#
# The recording is of a real run against the real cluster. Nothing is staged and
# nothing is re-timed: if a check is slow, the GIF is slow, which is the point.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/bin:${PATH}"

TARGET="${1:?usage: record.sh <make-target> <asset-name>}"
NAME="${2:?usage: record.sh <make-target> <asset-name>}"
ASSETS="${ROOT}/docs/assets"
mkdir -p "${ASSETS}"

command -v agg >/dev/null 2>&1 || {
  echo "installing agg" >&2
  curl -sSL -o "${ROOT}/bin/agg" \
    https://github.com/asciinema/agg/releases/latest/download/agg-x86_64-unknown-linux-gnu
  chmod +x "${ROOT}/bin/agg"
}

echo "recording 'make ${TARGET}'" >&2
# --no-print-directory keeps "Entering directory" out of the frame; the grep
# drops the tools preamble, which is the same six lines every time and says
# nothing about the thing being demonstrated.
#
# --line-buffered is not optional. Without it grep holds its output until the
# pipe closes, every line is timestamped at the same instant, and the recording
# plays a thirty second run in four seconds. A demo whose timing is invented is
# worth nothing, and this one invented it silently.
make --no-print-directory -C "${ROOT}" "${TARGET}" 2>&1 \
  | grep --line-buffered -vE 'already installed|^cosign |^crane |^jq-|^shellcheck ver|^chainsaw |tools ready' \
  | while IFS= read -r line; do printf '%s|%s\n' "$(date +%s%3N)" "${line}"; done \
  > "/tmp/${NAME}-timed.txt"

python3 "${ROOT}/hack/build-cast.py" "make ${TARGET}" "${ASSETS}/${NAME}.cast" \
  < "/tmp/${NAME}-timed.txt"

agg --font-size 16 --theme asciinema --idle-time-limit 2 \
  "${ASSETS}/${NAME}.cast" "${ASSETS}/${NAME}.gif" 2>/dev/null

size="$(du -h "${ASSETS}/${NAME}.gif" | cut -f1)"
echo "wrote ${ASSETS}/${NAME}.gif (${size})" >&2

# Always look at the result. A recording nobody opened is how a GIF of a failing
# run, or of output in the wrong language, ends up in a README.
if command -v ffprobe >/dev/null 2>&1; then
  frames="$(ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of csv=p=0 "${ASSETS}/${NAME}.gif")"
  ffmpeg -v error -i "${ASSETS}/${NAME}.gif" \
    -vf "select=eq(n\,$((frames - 1)))" -vsync 0 -frames:v 1 \
    "/tmp/${NAME}-final.png" -y
  echo "final frame: /tmp/${NAME}-final.png (open it before committing)" >&2
fi
