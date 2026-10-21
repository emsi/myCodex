# This template follows the launcher's Bash preflight in a generated executable.
# The builder replaces the metadata and checksum markers, then appends an archive.
# shellcheck shell=bash
set -euo pipefail
umask 077
MC_BUNDLE_VERSION='@VERSION@'
MC_BUNDLE_ARCHIVE_SHA='@ARCHIVE_SHA@'
MC_BUNDLE_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
mc_bundle_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | sed 's/^.*= //'
  else printf 'myCodex: SHA-256 tool required\n' >&2; return 1; fi
}
mc_bundle_verify_tree() {
  local digest path
  while read -r digest path; do
    [[ -f "$1/${path}" && ! -L "$1/${path}" \
      && "$(mc_bundle_sha <"$1/${path}")" == "${digest}" ]] || return 1
  done <<'MYCODEX_PAYLOAD_CHECKSUMS'
@CHECKSUMS@
MYCODEX_PAYLOAD_CHECKSUMS
}
for mc_tool in tar gzip base64 flock; do
  command -v "${mc_tool}" >/dev/null 2>&1 || {
    printf 'myCodex: %s is required by the release bundle\n' "${mc_tool}" >&2
    exit 2
  }
done
mc_data="${XDG_DATA_HOME:-}"
[[ "${mc_data}" == /* ]] || mc_data="${HOME}/.local/share"
mc_data="${mc_data}/myCodex/releases"
mkdir -p -- "${mc_data}"
mc_root="${mc_data}/${MC_BUNDLE_VERSION}-${MC_BUNDLE_ARCHIVE_SHA}"
exec {mc_lock}>"${mc_data}/${MC_BUNDLE_ARCHIVE_SHA}.lock"
flock "${mc_lock}"
if [[ ! -e "${mc_root}" && ! -L "${mc_root}" ]]; then
  mc_stage="$(mktemp -d "${mc_data}/unpack.XXXXXXXX")"
  sed '1,/^__MYCODEX_ARCHIVE__$/d' "${MC_BUNDLE_PATH}" | base64 -d >"${mc_stage}/payload.tar.gz"
  [[ "$(mc_bundle_sha <"${mc_stage}/payload.tar.gz")" == "${MC_BUNDLE_ARCHIVE_SHA}" ]] || {
    printf 'myCodex: embedded archive checksum failed\n' >&2; exit 1;
  }
  mkdir "${mc_stage}/payload"
  tar -xzf "${mc_stage}/payload.tar.gz" -C "${mc_stage}/payload"
  mc_bundle_verify_tree "${mc_stage}/payload" || {
    printf 'myCodex: extracted payload checksum failed\n' >&2; exit 1;
  }
  mv -- "${mc_stage}/payload" "${mc_root}"
fi
if [[ ! -d "${mc_root}" || -L "${mc_root}" || ! -O "${mc_root}" ]] || ! mc_bundle_verify_tree "${mc_root}"; then
  printf 'myCodex: extracted release files changed at %s; refusing to execute them\n' "${mc_root}" >&2
  exit 1
fi
exec {mc_lock}>&-
export _MYCODEX_BUNDLE_PATH="${MC_BUNDLE_PATH}"
exec bash "${mc_root}/bin/myCodex" "$@"
exit 1
