#!/usr/bin/env bash
# Installs the verification tooling into bin/, at pinned versions, checking a
# pinned SHA-256 for each download.
#
# The checksums are in this file rather than fetched from the release alongside
# the binary. Downloading a checksum from the same place as the artifact it
# describes proves only that the two arrived together. Pinned here, they are
# reviewed in a pull request and changing one is a visible diff.
#
# The bootstrapping problem is real and worth naming: cosign's own release is
# signed, and the honest way to check it is with cosign, which is the thing
# being installed. That regress ends somewhere, and here it ends at a hash
# committed to this repository by a human.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${ROOT}/bin"
mkdir -p "${BIN}"

COSIGN_VERSION="v3.1.3"
COSIGN_SHA256="4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"

CRANE_VERSION="v0.22.0"
CRANE_SHA256="edb74d53fad9a596860f59d1c5d04a43dfb5f441dc71f57060dd0bf39483c833"

JQ_VERSION="jq-1.8.2"
JQ_SHA256="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"

SHELLCHECK_VERSION="v0.11.0"
SHELLCHECK_SHA256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"

note() { printf '\033[1m%s\033[0m\n' "$1"; }

verify() {
  local file="$1" want="$2"
  local got
  got="$(sha256sum "${file}" | cut -d' ' -f1)"
  if [ "${got}" != "${want}" ]; then
    echo "checksum mismatch for ${file}" >&2
    echo "  want ${want}" >&2
    echo "  got  ${got}" >&2
    rm -f "${file}"
    exit 1
  fi
}

install_cosign() {
  local target="${BIN}/cosign-${COSIGN_VERSION}"
  if [ -x "${target}" ]; then note "cosign ${COSIGN_VERSION} already installed"; return; fi
  note "installing cosign ${COSIGN_VERSION}"
  curl -sSL -o "${target}" \
    "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
  verify "${target}" "${COSIGN_SHA256}"
  chmod +x "${target}"
  ln -sf "cosign-${COSIGN_VERSION}" "${BIN}/cosign"
}

install_crane() {
  local target="${BIN}/crane-${CRANE_VERSION}"
  if [ -x "${target}" ]; then note "crane ${CRANE_VERSION} already installed"; return; fi
  note "installing crane ${CRANE_VERSION}"
  local archive
  archive="$(mktemp)"
  curl -sSL -o "${archive}" \
    "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz"
  verify "${archive}" "${CRANE_SHA256}"
  tar -xzf "${archive}" -C "${BIN}" crane
  mv "${BIN}/crane" "${target}"
  rm -f "${archive}"
  chmod +x "${target}"
  ln -sf "crane-${CRANE_VERSION}" "${BIN}/crane"
}

install_jq() {
  local target="${BIN}/jq-${JQ_VERSION}"
  if [ -x "${target}" ]; then note "jq ${JQ_VERSION} already installed"; return; fi
  note "installing ${JQ_VERSION}"
  curl -sSL -o "${target}" \
    "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64"
  verify "${target}" "${JQ_SHA256}"
  chmod +x "${target}"
  ln -sf "jq-${JQ_VERSION}" "${BIN}/jq"
}

install_shellcheck() {
  local target="${BIN}/shellcheck-${SHELLCHECK_VERSION}"
  if [ -x "${target}" ]; then note "shellcheck ${SHELLCHECK_VERSION} already installed"; return; fi
  note "installing shellcheck ${SHELLCHECK_VERSION}"
  local archive
  archive="$(mktemp)"
  curl -sSL -o "${archive}" \
    "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
  verify "${archive}" "${SHELLCHECK_SHA256}"
  tar -xJf "${archive}" -C "${BIN}" --strip-components=1 \
    "shellcheck-${SHELLCHECK_VERSION}/shellcheck"
  mv "${BIN}/shellcheck" "${target}"
  rm -f "${archive}"
  chmod +x "${target}"
  ln -sf "shellcheck-${SHELLCHECK_VERSION}" "${BIN}/shellcheck"
}

install_cosign
install_crane
install_jq
install_shellcheck

note "tools ready in ${BIN}"
"${BIN}/cosign" version --json 2>/dev/null | "${BIN}/jq" -r '"cosign " + .gitVersion' || true
"${BIN}/crane" version | sed 's/^/crane /'
"${BIN}/jq" --version
"${BIN}/shellcheck" --version | sed -n '2p' | sed 's/^/shellcheck /' 
