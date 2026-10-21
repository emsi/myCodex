#!/usr/bin/env bash
# Host-side release management. Metadata is always parsed as data. Staging and
# previous releases are retained intentionally; this module never deletes files.
# Each command initializes its own installation record inside its subshell.
# shellcheck disable=SC2030,SC2031

mc_release_error() { printf 'myCodex: %s\n' "$*" >&2; return 1; }

mc_release_usage() {
  cat <<'EOF'
Usage:
  myCodex install [--name NAME] [--bin-dir DIR] [--manifest-dir DIR]
  myCodex update [--check] [--version YYYY.M.N[-rc.N]] [--allow-downgrade]
  myCodex update --rollback

Install defaults to ~/.local/bin/myCodex and preserves every existing file or
symlink. Use --name myCodex-release alongside a development installation.
Keep release.manifest and release.manifest.sig beside the verified download,
or supply --manifest-dir. Verify the initial download before executing it.

Update changes only a registered, unmodified release executable. Git checkouts
are managed through Git; update --check only reports a signed release.
Rollback restores the previous verified launcher. No container is changed.
Set MYCODEX_RELEASE_CHECK=0 to disable background launcher release checks.
EOF
}

mc_release_require() {
  local program
  for program in "$@"; do
    command -v "${program}" >/dev/null 2>&1 || {
      mc_release_error "${program} is required for this operation"; return 1;
    }
  done
}

mc_release_xdg() {
  local value="${!1:-}"
  if [[ "${value}" != /* ]]; then value="${HOME:?HOME is required}/$2"; fi
  printf '%s/myCodex\n' "${value}"
}

mc_release_sha() { mycodex_sha256_stream <"$1"; }

mc_release_version_valid() {
  [[ "$1" =~ ^2[0-9]{3}\.([1-9]|1[0-2])\.[1-9][0-9]{0,5}(-rc\.[1-9][0-9]{0,5})?$ ]]
}

# Compare CalVer numerically, including release candidates. No sort -V or eval.
mc_release_compare() {
  local a="$1" b="$2" i
  local -a left right
  mc_release_version_valid "${a}" && mc_release_version_valid "${b}" || return 1
  IFS=. read -r -a left <<<"${a%%-rc.*}"
  IFS=. read -r -a right <<<"${b%%-rc.*}"
  for i in 0 1 2; do
    if (( left[i] < right[i] )); then printf '%s\n' -1; return; fi
    if (( left[i] > right[i] )); then printf '%s\n' 1; return; fi
  done
  if [[ "${a}" == "${b}" ]]; then printf '0\n'
  elif [[ "${a}" != *-rc.* ]]; then printf '1\n'
  elif [[ "${b}" != *-rc.* ]]; then printf '%s\n' -1
  elif (( ${a##*-rc.} < ${b##*-rc.} )); then printf '%s\n' -1
  else printf '1\n'; fi
}

mc_release_git_root() {
  # Never inspect the user's current project when classifying this executable.
  # Filesystem discovery also works without Git and ignores exported GIT_DIR.
  local directory
  directory="$(dirname -- "$1")"
  while :; do
    if [[ -e "${directory}/.git" || -L "${directory}/.git" ]]; then
      printf '%s\n' "${directory}"; return 0
    fi
    [[ "${directory}" != / ]] || return 1
    directory="$(dirname -- "${directory}")"
  done
}

mc_release_init() {
  MC_RELEASE_KIND=source
  MC_RELEASE_VERSION=dev
  MC_RELEASE_COMMIT=unknown
  MC_RELEASE_EXECUTABLE="${SCRIPT_PATH}"
  MC_RELEASE_SIGNERS="${PROJECT_ROOT}/release/allowed_signers"
  MC_RELEASE_STATE="$(mc_release_xdg XDG_STATE_HOME .local/state)"
  MC_RELEASE_CACHE="$(mc_release_xdg XDG_CACHE_HOME .cache)"
  local key value
  if [[ -f "${PROJECT_ROOT}/release/build-info" && -n "${_MYCODEX_BUNDLE_PATH:-}" ]]; then
    MC_RELEASE_EXECUTABLE="$(realpath -- "${_MYCODEX_BUNDLE_PATH}")"
    while IFS='=' read -r key value; do
      case "${key}" in
        version) MC_RELEASE_VERSION="${value}" ;;
        commit) MC_RELEASE_COMMIT="${value}" ;;
        *) mc_release_error 'invalid packaged build metadata'; return 1 ;;
      esac
    done <"${PROJECT_ROOT}/release/build-info"
    mc_release_version_valid "${MC_RELEASE_VERSION}" || return 1
    [[ "${MC_RELEASE_COMMIT}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
    MC_RELEASE_KIND=release
  fi
  # A packaged artifact inside a worktree is still developer-managed.
  MC_RELEASE_GIT_ROOT="$(mc_release_git_root "${MC_RELEASE_EXECUTABLE}" || true)"
  if [[ -n "${MC_RELEASE_GIT_ROOT}" ]]; then
    MC_RELEASE_KIND=source
    MC_RELEASE_COMMIT="$(
      unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
      git -C "${MC_RELEASE_GIT_ROOT}" rev-parse HEAD 2>/dev/null || printf 'unknown\n'
    )"
  fi
}

mc_release_print_version() {
  if [[ "${MC_RELEASE_KIND}" == source ]]; then
    printf 'myCodex development (%s)\n' "${MC_RELEASE_COMMIT}"
    printf 'Source: %s\n' "${MC_RELEASE_GIT_ROOT:-${PROJECT_ROOT}}"
  else
    printf 'myCodex %s (%s)\n' "${MC_RELEASE_VERSION}" "${MC_RELEASE_COMMIT}"
  fi
}

mc_release_read_manifest() {
  local directory="$1" key value count=0
  local -A fields=()
  [[ -f "${directory}/release.manifest" && $(wc -c <"${directory}/release.manifest") -lt 8192 ]] || {
    mc_release_error 'missing or oversized release manifest'; return 1;
  }
  while IFS='=' read -r key value; do
    case "${key}" in
      schema|repository|version|channel|commit|asset|size|sha256) ;;
      *) mc_release_error 'unknown release manifest field'; return 1 ;;
    esac
    [[ ! -v "fields[${key}]" ]] || { mc_release_error 'duplicate manifest field'; return 1; }
    fields["${key}"]="${value}"
    count=$((count + 1))
  done <"${directory}/release.manifest"
  [[ "${count}" == 8 && "${fields[schema]:-}" == 1 \
    && "${fields[repository]:-}" == emsi/myCodex && "${fields[asset]:-}" == myCodex ]] || {
    mc_release_error 'invalid manifest schema, repository, or asset'; return 1;
  }
  mc_release_version_valid "${fields[version]:-}" || { mc_release_error 'invalid release version'; return 1; }
  [[ "${fields[commit]:-}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ \
    && "${fields[sha256]:-}" =~ ^[0-9a-f]{64}$ \
    && "${fields[size]:-}" =~ ^[1-9][0-9]{0,7}$ ]] || {
    mc_release_error 'invalid release digest, size, or commit'; return 1;
  }
  [[ ( "${fields[version]}" == *-rc.* && "${fields[channel]:-}" == prerelease ) \
    || ( "${fields[version]}" != *-rc.* && "${fields[channel]:-}" == stable ) ]] || {
    mc_release_error 'release channel does not match version'; return 1;
  }
  MC_REMOTE_VERSION="${fields[version]}"
  MC_REMOTE_SHA="${fields[sha256]}"
  MC_REMOTE_SIZE="${fields[size]}"
}

mc_release_verify_manifest() {
  local directory="$1"
  mc_release_require ssh-keygen || return
  [[ -f "${directory}/release.manifest.sig" && -f "${MC_RELEASE_SIGNERS}" ]] || {
    mc_release_error 'release signature or trusted signing key is missing'; return 1;
  }
  ssh-keygen -Y verify -f "${MC_RELEASE_SIGNERS}" -I emsi -n mycodex-release \
    -s "${directory}/release.manifest.sig" <"${directory}/release.manifest" >/dev/null 2>&1 || {
    mc_release_error 'release signature verification failed'; return 1;
  }
  mc_release_read_manifest "${directory}"
}

mc_release_verify_asset() {
  local directory="$1" asset="${2:-$1/myCodex}"
  mc_release_verify_manifest "${directory}" || return
  [[ -f "${asset}" && ! -L "${asset}" && "$(wc -c <"${asset}" | tr -d '[:space:]')" == "${MC_REMOTE_SIZE}" \
    && "$(mc_release_sha "${asset}")" == "${MC_REMOTE_SHA}" ]] || {
    mc_release_error 'release executable does not match the signed manifest'; return 1;
  }
}

mc_release_http() {
  curl --proto '=https' --proto-redir '=https' --connect-timeout 3 --max-time 15 \
    --fail --silent --show-error --location "$@"
}

mc_release_download_metadata() {
  local requested="${1:-}" effective base directory
  mc_release_require curl ssh-keygen || return
  if [[ -z "${requested}" ]]; then
    effective="$(mc_release_http -o /dev/null -w '%{url_effective}' \
      https://github.com/emsi/myCodex/releases/latest)" || {
      mc_release_error 'could not check GitHub releases (offline, rate limited, or no stable release yet)'; return 1;
    }
    [[ "${effective}" == https://github.com/emsi/myCodex/releases/tag/v* ]] || {
      mc_release_error 'unexpected latest-release redirect'; return 1;
    }
    requested="${effective#https://github.com/emsi/myCodex/releases/tag/v}"
    [[ "${requested}" != *-rc.* ]] || { mc_release_error 'latest release is not stable'; return 1; }
  fi
  mc_release_version_valid "${requested}" || { mc_release_error 'invalid requested release version'; return 1; }
  mkdir -p -- "${MC_RELEASE_CACHE}/downloads" || return
  directory="$(mktemp -d "${MC_RELEASE_CACHE}/downloads/release.XXXXXXXX")" || return
  base="https://github.com/emsi/myCodex/releases/download/v${requested}"
  mc_release_http --max-filesize 8192 -o "${directory}/release.manifest" "${base}/release.manifest" || return
  mc_release_http --max-filesize 16384 -o "${directory}/release.manifest.sig" "${base}/release.manifest.sig" || return
  mc_release_verify_manifest "${directory}" || return
  [[ "${MC_REMOTE_VERSION}" == "${requested}" ]] || { mc_release_error 'release tag and signed version differ'; return 1; }
  MC_RELEASE_DOWNLOAD="${directory}"
  MC_RELEASE_DOWNLOAD_BASE="${base}"
}

mc_release_install_id() { printf '%s' "$1" | mycodex_sha256_stream; }

mc_release_install_record() {
  local target="$1" id digest
  [[ -f "${target}" && ! -L "${target}" && "$(realpath -- "${target}")" == "${target}" ]] || {
    mc_release_error 'installation path is missing or has become a symlink'; return 1;
  }
  [[ -z "$(mc_release_git_root "${target}" || true)" ]] || {
    mc_release_error 'this executable belongs to a Git worktree'; return 1;
  }
  id="$(mc_release_install_id "${target}")" || return
  MC_INSTALL_DIR="${MC_RELEASE_STATE}/installations/${id}"
  [[ -f "${MC_INSTALL_DIR}/target" && "$(cat "${MC_INSTALL_DIR}/target")" == "${target}" ]] || {
    mc_release_error 'unregistered executable; use install to create a managed installation'; return 1;
  }
  digest="$(mc_release_sha "${target}")" || return
  MC_INSTALL_OBJECT="${MC_INSTALL_DIR}/versions/${digest}"
  mc_release_verify_asset "${MC_INSTALL_OBJECT}" "${target}" || {
    mc_release_error 'installation was modified or has no verified receipt; it will not be overwritten'; return 1;
  }
  MC_INSTALL_SHA="${digest}"
}

# Receipts are keyed by executable digest and prepared before activation. Thus a
# crash before/after the rename leaves either the old or new receipt usable.
mc_release_activate() {
  local target="$1" directory="$2" expected="$3" previous="$4"
  local digest version object staged receipt high temporary
  mc_release_verify_asset "${directory}" || return
  digest="${MC_REMOTE_SHA}"; version="${MC_REMOTE_VERSION}"
  object="${MC_INSTALL_DIR}/versions/${digest}"
  if [[ ! -d "${object}" ]]; then
    receipt="$(mktemp -d "${MC_INSTALL_DIR}/receipt.XXXXXXXX")" || return
    cp -- "${directory}/myCodex" "${directory}/release.manifest" "${directory}/release.manifest.sig" "${receipt}/" || return
    printf '%s\n' "${previous}" >"${receipt}/previous"
    mkdir -p -- "${MC_INSTALL_DIR}/versions" || return
    mv -- "${receipt}" "${object}" || return
  else
    mc_release_verify_asset "${object}" || return
  fi
  staged="$(mktemp "$(dirname -- "${target}")/.myCodex-stage.XXXXXXXX")" || return
  cp -- "${object}/myCodex" "${staged}" || return
  chmod 755 "${staged}" || return
  mc_release_verify_asset "${object}" "${staged}" || return
  high="$(cat "${MC_INSTALL_DIR}/highest" 2>/dev/null || true)"
  if [[ -n "${high}" ]]; then
    mc_release_version_valid "${high}" || { mc_release_error 'invalid installation version history'; return 1; }
  fi
  if [[ -z "${high}" || "$(mc_release_compare "${version}" "${high}")" == 1 ]]; then
    temporary="$(mktemp "${MC_INSTALL_DIR}/highest.XXXXXXXX")" || return
    printf '%s\n' "${version}" >"${temporary}"
    mv -- "${temporary}" "${MC_INSTALL_DIR}/highest" || return
  fi
  # Preserve the predecessor separately even when rolling back to an old object.
  temporary="$(mktemp "${MC_INSTALL_DIR}/previous.XXXXXXXX")" || return
  printf '%s\n' "${previous}" >"${temporary}"
  mv -- "${temporary}" "${MC_INSTALL_DIR}/previous-${digest}" || return
  [[ ! -L "${target}" && "$(realpath -m -- "${target}")" == "${target}" \
    && -z "$(mc_release_git_root "${target}" || true)" ]] || {
    mc_release_error 'installation path changed; refusing replacement'; return 1;
  }
  if [[ "${expected}" == absent ]]; then
    [[ ! -e "${target}" ]] || { mc_release_error 'installation path is now occupied'; return 1; }
  else
    [[ -f "${target}" && "$(mc_release_sha "${target}")" == "${expected}" ]] || {
      mc_release_error 'executable changed during update; refusing replacement'; return 1;
    }
  fi
  mv -f -- "${staged}" "${target}" || return
  printf 'myCodex: installed %s at %s\n' "${version}" "${target}"
}

mc_release_install() (
  umask 077
  local name=myCodex bin_dir="${HOME}/.local/bin" manifest_dir="" target id lockfd
  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then mc_release_usage; exit 0; fi
  [[ "${MC_RELEASE_KIND}" == release ]] || {
    mc_release_error 'install requires a packaged release; source checkouts are managed through Git'; exit 1;
  }
  while (( $# )); do
    case "$1" in
      --name|--bin-dir|--manifest-dir)
        [[ $# -ge 2 && -n "$2" ]] || { mc_release_error "$1 requires a value"; exit 2; }
        case "$1" in --name) name="$2" ;; --bin-dir) bin_dir="$2" ;; --manifest-dir) manifest_dir="$2" ;; esac
        shift 2 ;;
      *) mc_release_error "unknown install option: $1"; exit 2 ;;
    esac
  done
  [[ "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ && "${bin_dir}" != *$'\n'* ]] || {
    mc_release_error 'invalid installation name or directory'; exit 2;
  }
  mc_release_require flock || exit
  [[ -n "${manifest_dir}" ]] || manifest_dir="$(dirname -- "${MC_RELEASE_EXECUTABLE}")"
  mc_release_verify_asset "${manifest_dir}" "${MC_RELEASE_EXECUTABLE}" || exit
  mkdir -p -- "${bin_dir}" || exit
  bin_dir="$(realpath -- "${bin_dir}")"
  target="${bin_dir}/${name}"
  [[ ! -e "${target}" && ! -L "${target}" ]] || {
    mc_release_error "${target} is occupied; leaving it untouched. Choose --name myCodex-release or --bin-dir."; exit 1;
  }
  [[ -z "$(mc_release_git_root "${target}" || true)" ]] || {
    mc_release_error 'refusing installation inside a Git worktree'; exit 1;
  }
  id="$(mc_release_install_id "${target}")"
  MC_INSTALL_DIR="${MC_RELEASE_STATE}/installations/${id}"
  mkdir -p -- "${MC_INSTALL_DIR}" || exit
  exec {lockfd}>"${MC_INSTALL_DIR}/lock"
  flock -n "${lockfd}" || { mc_release_error 'another installation or update is running'; exit 1; }
  [[ ! -e "${target}" && ! -L "${target}" ]] || { mc_release_error 'installation path became occupied'; exit 1; }
  printf '%s\n' "${target}" >"${MC_INSTALL_DIR}/target"
  local directory
  directory="$(mktemp -d "${MC_INSTALL_DIR}/initial.XXXXXXXX")" || exit
  cp -- "${MC_RELEASE_EXECUTABLE}" "${directory}/myCodex" || exit
  cp -- "${manifest_dir}/release.manifest" "${manifest_dir}/release.manifest.sig" "${directory}/" || exit
  mc_release_activate "${target}" "${directory}" absent ''
)

mc_release_update() (
  umask 077
  local check=0 requested="" rollback=0 downgrade=0 lockfd target high previous expected
  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then mc_release_usage; exit 0; fi
  while (( $# )); do
    case "$1" in
      --check) check=1; shift ;;
      --rollback) rollback=1; shift ;;
      --allow-downgrade) downgrade=1; shift ;;
      --version)
        [[ $# -ge 2 ]] || { mc_release_error '--version requires a value'; exit 2; }
        requested="${2#v}"; shift 2 ;;
      *) mc_release_error "unknown update option: $1"; exit 2 ;;
    esac
  done
  if (( rollback && (check || downgrade) )) || [[ "${rollback}" == 1 && -n "${requested}" ]]; then
    mc_release_error '--rollback cannot be combined with other update options'; exit 2
  fi
  if [[ "${MC_RELEASE_KIND}" == source ]]; then
    mc_release_print_version
    if [[ "${check}" != 1 ]]; then
      printf 'This installation is managed through Git. Use update --check to check signed releases.\n'
      exit 0
    fi
  fi
  if [[ "${check}" == 1 ]]; then
    mc_release_download_metadata "${requested}" || exit
    printf 'Latest selected signed release: %s\n' "${MC_REMOTE_VERSION}"
    if [[ "${MC_RELEASE_KIND}" == release ]]; then
      printf 'Installed launcher: %s\n' "${MC_RELEASE_VERSION}"
      case "$(mc_release_compare "${MC_REMOTE_VERSION}" "${MC_RELEASE_VERSION}")" in
        1) printf 'A launcher update is available.\n' ;;
        0) printf 'The launcher is up to date.\n' ;;
        -1) printf 'The selected release is older than the installed launcher.\n' ;;
      esac
    fi
    exit 0
  fi
  mc_release_require flock || exit
  target="${MC_RELEASE_EXECUTABLE}"
  mc_release_install_record "${target}" || exit
  exec {lockfd}>"${MC_INSTALL_DIR}/lock"
  flock -n "${lockfd}" || { mc_release_error 'another installation or update is running'; exit 1; }
  mc_release_install_record "${target}" || exit
  expected="${MC_INSTALL_SHA}"
  if [[ "${rollback}" == 1 ]]; then
    previous="$(cat "${MC_INSTALL_DIR}/previous-${expected}" 2>/dev/null || true)"
    [[ "${previous}" =~ ^[0-9a-f]{64}$ && "${previous}" != "${expected}" ]] || {
      mc_release_error 'no previous verified launcher is available'; exit 1;
    }
    mc_release_activate "${target}" "${MC_INSTALL_DIR}/versions/${previous}" "${expected}" "${expected}"
    exit $?
  fi
  mc_release_download_metadata "${requested}" || exit
  high="$(cat "${MC_INSTALL_DIR}/highest")" || exit
  mc_release_version_valid "${high}" || { mc_release_error 'invalid installation version history'; exit 1; }
  if [[ "$(mc_release_compare "${MC_REMOTE_VERSION}" "${high}")" == -1 && "${downgrade}" != 1 ]]; then
    mc_release_error "release ${MC_REMOTE_VERSION} is older than previously installed ${high}; use --version with --allow-downgrade deliberately"
    exit 1
  fi
  if [[ "${downgrade}" == 1 && -z "${requested}" ]]; then
    mc_release_error '--allow-downgrade requires --version'; exit 2
  fi
  if [[ "${MC_REMOTE_SHA}" == "${expected}" ]]; then printf 'myCodex: already up to date\n'; exit 0; fi
  if [[ "${MC_REMOTE_VERSION}" == "${MC_RELEASE_VERSION}" ]]; then
    mc_release_error 'release content changed without a new version'; exit 1
  fi
  mc_release_http --max-filesize "${MC_REMOTE_SIZE}" -o "${MC_RELEASE_DOWNLOAD}/myCodex" \
    "${MC_RELEASE_DOWNLOAD_BASE}/myCodex" || exit
  mc_release_verify_asset "${MC_RELEASE_DOWNLOAD}" || exit
  mc_release_activate "${target}" "${MC_RELEASE_DOWNLOAD}" "${expected}" "${expected}"
)

mc_release_check_background() (
  umask 077
  local lockfd now last temporary
  mc_release_require flock curl ssh-keygen >/dev/null 2>&1 || exit 0
  mkdir -p -- "${MC_RELEASE_CACHE}" || exit 0
  exec {lockfd}>"${MC_RELEASE_CACHE}/check.lock"
  flock -n "${lockfd}" || exit 0
  now="$(date +%s)"
  last="$(cat "${MC_RELEASE_CACHE}/checked-at" 2>/dev/null || true)"
  [[ "${last}" =~ ^[0-9]{1,12}$ ]] || last=0
  (( now < last || now - last >= 86400 )) || exit 0
  temporary="$(mktemp "${MC_RELEASE_CACHE}/checked-at.XXXXXXXX")" || exit 0
  printf '%s\n' "${now}" >"${temporary}"
  mv -- "${temporary}" "${MC_RELEASE_CACHE}/checked-at" || exit 0
  mc_release_download_metadata || exit 0
  temporary="$(mktemp "${MC_RELEASE_CACHE}/latest.XXXXXXXX")" || exit 0
  printf '%s\n' "${MC_RELEASE_DOWNLOAD}" >"${temporary}"
  mv -- "${temporary}" "${MC_RELEASE_CACHE}/latest"
)

mc_release_notice() {
  local enabled="${MYCODEX_RELEASE_CHECK:-}" directory id shown temporary
  [[ -n "${enabled}" ]] || { if [[ "${MC_RELEASE_KIND}" == release ]]; then enabled=1; else enabled=0; fi; }
  [[ "${enabled}" == 1 ]] || return 0
  # All streams are detached: attach never waits for a network request or gets
  # background output mixed into its terminal. A fresh result appears next time.
  (mc_release_check_background </dev/null >/dev/null 2>&1 &) 2>/dev/null
  directory="$(cat "${MC_RELEASE_CACHE}/latest" 2>/dev/null || true)"
  [[ "${directory}" == "${MC_RELEASE_CACHE}/downloads/"* ]] || return 0
  mc_release_verify_manifest "${directory}" >/dev/null 2>&1 || return 0
  if [[ "${MC_RELEASE_KIND}" == release ]]; then
    [[ "$(mc_release_compare "${MC_RELEASE_VERSION}" "${MC_REMOTE_VERSION}")" == -1 ]] || return 0
  fi
  id="$(mc_release_install_id "${MC_RELEASE_EXECUTABLE}")" || return 0
  shown="${MC_RELEASE_STATE}/notices/${id}"
  [[ "$(cat "${shown}" 2>/dev/null || true)" != "${MC_REMOTE_VERSION}" ]] || return 0
  (umask 077; mkdir -p -- "${MC_RELEASE_STATE}/notices") || return 0
  temporary="$(mktemp "${MC_RELEASE_STATE}/notices/seen.XXXXXXXX")" || return 0
  printf '%s\n' "${MC_REMOTE_VERSION}" >"${temporary}"
  mv -- "${temporary}" "${shown}" || return 0
  if [[ "${MC_RELEASE_KIND}" == source ]]; then
    printf 'myCodex: launcher release %s is available; this development checkout is managed through Git.\n' "${MC_REMOTE_VERSION}"
  else
    printf 'myCodex: launcher %s is available (installed: %s). Run %q update.\n' \
      "${MC_REMOTE_VERSION}" "${MC_RELEASE_VERSION}" "${MC_RELEASE_EXECUTABLE}"
  fi
}
