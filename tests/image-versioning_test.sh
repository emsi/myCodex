#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=bin/lib/mycodex-image.sh
source "${PROJECT_ROOT}/bin/lib/mycodex-image.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local want="$1"
  local got="$2"
  local message="$3"

  [[ "${got}" == "${want}" ]] || fail "${message}: got ${got@Q}, want ${want@Q}"
}

assert_contains() {
  local file="$1"
  local text="$2"

  grep -Fq -- "${text}" "${file}" || fail "${file} does not contain: ${text}"
}

assert_not_contains() {
  local file="$1"
  local text="$2"

  if grep -Fq -- "${text}" "${file}"; then
    fail "${file} unexpectedly contains: ${text}"
  fi
}

assert_ref_exists() {
  local ref="$1"

  grep -Fxq -- "${ref}" "${FAKE_REMOTE_REFS}" || fail "remote ref does not exist: ${ref}"
}

assert_ref_missing() {
  local ref="$1"

  if grep -Fxq -- "${ref}" "${FAKE_REMOTE_REFS}"; then
    fail "remote ref unexpectedly exists: ${ref}"
  fi
}

latest="$({
  printf '%s\n' \
    latest \
    0.145.0 \
    0.146.0 \
    0.146.0-r1 \
    0.146.0-r2 \
    0.147.0-r1-amd64
} | mycodex_latest_semver_from_tags)"
assert_eq "0.146.0-r2" "${latest}" "latest immutable image release"
assert_eq "0.146.0-r12" "$(mycodex_image_release_tag 0.146.0 12)" "release tag"
assert_eq "0.146.0" "$(printf '%s\n' 0.145.0 0.146.0 | mycodex_latest_semver_from_tags)" \
  "legacy unqualified release fallback"
assert_eq "0.147.0" \
  "$(printf '%s\n' 0.146.0-r2 0.147.0 | mycodex_latest_semver_from_tags)" \
  "newer legacy release during migration"

if mycodex_validate_image_revision 0 >/dev/null 2>&1; then
  fail "revision zero was accepted"
fi
if mycodex_validate_image_revision 01 >/dev/null 2>&1; then
  fail "revision with a leading zero was accepted"
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mycodex-image-versioning.XXXXXX")"
trap 'rm -rf -- "${tmp_dir}"' EXIT
export FAKE_DOCKER_LOG="${tmp_dir}/docker.log"
export FAKE_LOCAL_REFS="${tmp_dir}/local-refs"
export FAKE_REMOTE_REFS="${tmp_dir}/remote-refs"
touch "${FAKE_DOCKER_LOG}" "${FAKE_LOCAL_REFS}" "${FAKE_REMOTE_REFS}"

record_ref() {
  local file="$1"
  local ref="$2"

  grep -Fxq -- "${ref}" "${file}" || printf '%s\n' "${ref}" >>"${file}"
}

docker() {
  printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG}"

  if [[ "$1 $2 $3" == "buildx imagetools inspect" ]]; then
    if [[ "${FAKE_INSPECT_ERROR_REF:-}" == "$4" ]]; then
      printf 'unauthorized: simulated registry failure\n' >&2
      return 1
    fi
    if grep -Fxq -- "$4" "${FAKE_REMOTE_REFS}"; then
      return 0
    fi
    printf '%s: not found\n' "$4" >&2
    return 1
  fi

  if [[ "$1 $2" == "image inspect" ]]; then
    grep -Fxq -- "$3" "${FAKE_LOCAL_REFS}"
    return
  fi

  if [[ "$1 $2" == "buildx build" ]]; then
    local previous=""
    local arg
    for arg in "$@"; do
      if [[ "${previous}" == "--tag" ]]; then
        record_ref "${FAKE_LOCAL_REFS}" "${arg}"
      fi
      previous="${arg}"
    done
    return
  fi

  if [[ "$1 $2" == "image tag" ]]; then
    record_ref "${FAKE_LOCAL_REFS}" "$4"
    return
  fi

  if [[ "$1 $2" == "image push" ]]; then
    grep -Fxq -- "$3" "${FAKE_LOCAL_REFS}" || return 1
    record_ref "${FAKE_REMOTE_REFS}" "$3"
    return
  fi

  if [[ "$1 $2 $3" == "buildx imagetools create" ]]; then
    local previous=""
    local arg
    for arg in "$@"; do
      if [[ "${previous}" == "--tag" ]]; then
        record_ref "${FAKE_REMOTE_REFS}" "${arg}"
      fi
      previous="${arg}"
    done
    return
  fi

  fail "unhandled fake docker invocation: $*"
}
export -f docker record_ref fail

uname() {
  case "$1" in
    -m) printf '%s\n' "${FAKE_UNAME_MACHINE}" ;;
    -s) printf '%s\n' Linux ;;
    *) return 1 ;;
  esac
}
export -f uname

run_build() {
  local machine="$1"
  local archs="$2"
  local output="$3"
  shift 3

  FAKE_UNAME_MACHINE="${machine}" \
  ARCHS="${archs}" \
  RELEASE_ARCHS="amd64 arm64" \
  MYCODEX_IMAGE_NAME="example.test/workstation" \
    bash "${PROJECT_ROOT}/bin/build-codex-image.sh" "$@" >"${output}" 2>&1
}

amd64_output="${tmp_dir}/amd64.out"
run_build x86_64 amd64 "${amd64_output}" --version 0.146.0 --revision 2 --push
assert_ref_exists "example.test/workstation:0.146.0-r2-amd64"
assert_ref_missing "example.test/workstation:0.146.0-r2"
assert_ref_missing "example.test/workstation:0.146.0"
assert_contains "${amd64_output}" "pending architecture tags: arm64"
assert_contains "${FAKE_DOCKER_LOG}" "--build-arg MYCODEX_IMAGE_REVISION=2"

: >"${FAKE_DOCKER_LOG}"
arm64_output="${tmp_dir}/arm64.out"
run_build aarch64 arm64 "${arm64_output}" --version 0.146.0 --revision 2 --push
assert_ref_exists "example.test/workstation:0.146.0-r2-arm64"
assert_ref_exists "example.test/workstation:0.146.0-r2"
assert_ref_exists "example.test/workstation:0.146.0"
assert_ref_exists "example.test/workstation:latest"
assert_contains "${FAKE_DOCKER_LOG}" "buildx imagetools create --tag example.test/workstation:0.146.0-r2 example.test/workstation:0.146.0-r2-amd64 example.test/workstation:0.146.0-r2-arm64"
assert_contains "${FAKE_DOCKER_LOG}" "buildx imagetools create --tag example.test/workstation:0.146.0 --tag example.test/workstation:latest example.test/workstation:0.146.0-r2"

: >"${FAKE_DOCKER_LOG}"
retry_output="${tmp_dir}/retry.out"
run_build x86_64 amd64 "${retry_output}" --version 0.146.0 --revision 2 --refresh-tags --push
assert_contains "${retry_output}" "immutable registry tag already exists"
assert_not_contains "${FAKE_DOCKER_LOG}" "buildx build"
assert_not_contains "${FAKE_DOCKER_LOG}" "image push"
assert_not_contains "${FAKE_DOCKER_LOG}" "imagetools create --tag example.test/workstation:0.146.0-r2 example.test"

: >"${FAKE_DOCKER_LOG}"
: >"${FAKE_LOCAL_REFS}"
: >"${FAKE_REMOTE_REFS}"
arm64_first_output="${tmp_dir}/arm64-first.out"
run_build aarch64 arm64 "${arm64_first_output}" --version 0.147.0 --revision 1 --push
assert_ref_exists "example.test/workstation:0.147.0-r1-arm64"
assert_ref_missing "example.test/workstation:0.147.0-r1"
assert_contains "${arm64_first_output}" "pending architecture tags: amd64"

amd64_second_output="${tmp_dir}/amd64-second.out"
run_build x86_64 amd64 "${amd64_second_output}" --version 0.147.0 --revision 1 --push
assert_ref_exists "example.test/workstation:0.147.0-r1-amd64"
assert_ref_exists "example.test/workstation:0.147.0-r1"
assert_ref_exists "example.test/workstation:0.147.0"

missing_output="${tmp_dir}/missing.out"
if run_build x86_64 amd64 "${missing_output}" --version 0.200.0 --revision 1 --manifest; then
  fail "manifest finalization accepted a missing architecture set"
fi
assert_contains "${missing_output}" "missing architecture tags: amd64 arm64"

invalid_output="${tmp_dir}/invalid.out"
if run_build x86_64 amd64 "${invalid_output}" --version 0.146.0 --revision 01; then
  fail "build accepted a non-canonical image revision"
fi
assert_contains "${invalid_output}" "positive integer without leading zeros"

registry_error_output="${tmp_dir}/registry-error.out"
export FAKE_INSPECT_ERROR_REF="example.test/workstation:0.300.0-r1-amd64"
if run_build x86_64 amd64 "${registry_error_output}" --version 0.300.0 --revision 1 --push; then
  fail "build treated a registry inspection error as a missing immutable tag"
fi
unset FAKE_INSPECT_ERROR_REF
assert_contains "${registry_error_output}" "cannot determine whether registry tag exists"
assert_not_contains "${registry_error_output}" "Building example.test/workstation:0.300.0-r1-amd64"

printf 'PASS: image release versioning and split-builder publication\n'
