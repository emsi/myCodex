#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=bin/lib/mycodex-image.sh
source "${PROJECT_ROOT}/bin/lib/mycodex-image.sh"

TEST_BUILD_INPUT_DIGEST="$(mycodex_build_input_digest "${PROJECT_ROOT}")"
TEST_SOURCE_REVISION="$(mycodex_source_revision "${PROJECT_ROOT}")"

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

assert_occurrences() {
  local file="$1"
  local text="$2"
  local want="$3"
  local got

  got="$(grep -Fxc -- "${text}" "${file}" || true)"
  [[ "${got}" == "${want}" ]] \
    || fail "${file} contains ${text@Q} ${got} times, want ${want}"
}

assert_semver_order() {
  local want="$1"
  local left="$2"
  local right="$3"

  assert_eq "${want}" "$(mycodex_compare_semver "${left}" "${right}")" \
    "SemVer comparison ${left} versus ${right}"
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
assert_semver_order -1 0.146.0 0.147.0
assert_semver_order 1 0.147.0 0.146.0
assert_semver_order 0 0.147.0+build.1 0.147.0+build.2
assert_semver_order -1 1.0.0-alpha 1.0.0-alpha.1
assert_semver_order -1 1.0.0-alpha.1 1.0.0-alpha.beta
assert_semver_order -1 1.0.0-beta.2 1.0.0-beta.11
assert_semver_order -1 1.0.0-rc.1 1.0.0
assert_eq -1 "$(mycodex_compare_image_releases 0.146.0 12 0.147.0 1)" \
  "older Codex release comparison"
assert_eq 1 "$(mycodex_compare_image_releases 0.147.0 10 0.147.0 2)" \
  "newer image revision comparison"

if mycodex_validate_image_revision 0 >/dev/null 2>&1; then
  fail "revision zero was accepted"
fi
if mycodex_validate_image_revision 01 >/dev/null 2>&1; then
  fail "revision with a leading zero was accepted"
fi
reserved_version_output="$(mycodex_validate_codex_version 0.146.0-r2 2>&1 || true)"
assert_eq \
  $'Codex version includes the reserved image revision suffix: 0.146.0-r2\nPass it separately, for example: --version 0.146.0 --revision 2' \
  "${reserved_version_output}" \
  "revision-qualified Codex version guidance"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mycodex-image-versioning.XXXXXX")"
trap 'rm -rf -- "${tmp_dir}"' EXIT

identity_repo="${tmp_dir}/identity-repo"
mkdir -p "${identity_repo}"
cp \
  "${PROJECT_ROOT}/${MYCODEX_IMAGE_INPUTS_FILE}" \
  "${PROJECT_ROOT}/Dockerfile" \
  "${PROJECT_ROOT}/entrypoint.sh" \
  "${identity_repo}/"
git -C "${identity_repo}" init -q
git -C "${identity_repo}" add .
git -C "${identity_repo}" \
  -c user.name=myCodex-test -c user.email=mycodex-test@example.invalid \
  commit -qm "test image inputs"
baseline_input_digest="$(mycodex_build_input_digest "${identity_repo}")"
mycodex_validate_build_input_digest "${baseline_input_digest}"
mycodex_assert_clean_image_inputs "${identity_repo}"
printf '\n# simulated image change\n' >>"${identity_repo}/entrypoint.sh"
changed_test_digest="$(mycodex_build_input_digest "${identity_repo}")"
if [[ "${changed_test_digest}" == "${baseline_input_digest}" ]]; then
  fail "image-input digest ignored an entrypoint change"
fi
if mycodex_assert_clean_image_inputs "${identity_repo}" >/dev/null 2>&1; then
  fail "dirty image inputs were accepted for publication"
fi
git -C "${identity_repo}" checkout -q -- entrypoint.sh
printf 'documentation only\n' >"${identity_repo}/README.md"
if [[ "$(mycodex_build_input_digest "${identity_repo}")" != "${baseline_input_digest}" ]]; then
  fail "unrelated documentation changed the image-input digest"
fi

export FAKE_DOCKER_LOG="${tmp_dir}/docker.log"
export FAKE_LOCAL_REFS="${tmp_dir}/local-refs"
export FAKE_REMOTE_REFS="${tmp_dir}/remote-refs"
export FAKE_LOCAL_IDENTITIES="${tmp_dir}/local-identities"
export FAKE_REMOTE_IDENTITIES="${tmp_dir}/remote-identities"
touch \
  "${FAKE_DOCKER_LOG}" \
  "${FAKE_LOCAL_REFS}" \
  "${FAKE_REMOTE_REFS}" \
  "${FAKE_LOCAL_IDENTITIES}" \
  "${FAKE_REMOTE_IDENTITIES}"

record_ref() {
  local file="$1"
  local ref="$2"

  grep -Fxq -- "${ref}" "${file}" || printf '%s\n' "${ref}" >>"${file}"
}

set_identity() {
  local file="$1"
  local ref="$2"
  local version="$3"
  local revision="$4"
  local input_digest="$5"
  local source_revision="$6"
  local filtered="${file}.filtered"

  awk -F '|' -v ref="${ref}" '$1 != ref' "${file}" >"${filtered}"
  mv -- "${filtered}" "${file}"
  printf '%s|%s|%s|%s|%s\n' \
    "${ref}" "${version}" "${revision}" "${input_digest}" "${source_revision}" >>"${file}"
}

identity_for() {
  local file="$1"
  local ref="$2"

  awk -F '|' -v ref="${ref}" '$1 == ref { print $2, $3; exit }' "${file}"
}

metadata_for() {
  local file="$1"
  local ref="$2"

  awk -F '|' -v ref="${ref}" '$1 == ref { print $2, $3, $4, $5; exit }' "${file}"
}

input_digest_for() {
  local file="$1"
  local ref="$2"

  awk -F '|' -v ref="${ref}" '$1 == ref { print $4; exit }' "${file}"
}

copy_identity() {
  local source_file="$1"
  local source_ref="$2"
  local target_file="$3"
  local target_ref="$4"
  local metadata version revision input_digest source_revision

  metadata="$(metadata_for "${source_file}" "${source_ref}")"
  [[ -n "${metadata}" ]] || return 0
  read -r version revision input_digest source_revision <<<"${metadata}"
  set_identity \
    "${target_file}" "${target_ref}" \
    "${version}" "${revision}" "${input_digest}" "${source_revision}"
}

docker() {
  printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG}"

  if [[ "$1 $2 $3" == "buildx imagetools inspect" ]]; then
    if [[ "${FAKE_INSPECT_ERROR_REF:-}" == "$4" ]]; then
      printf 'unauthorized: simulated registry failure\n' >&2
      return 1
    fi
    if grep -Fxq -- "$4" "${FAKE_REMOTE_REFS}"; then
      if [[ " $* " == *" --format "* ]]; then
        local metadata version revision input_digest source_revision
        metadata="$(metadata_for "${FAKE_REMOTE_IDENTITIES}" "$4")"
        if [[ -n "${metadata}" ]]; then
          read -r version revision input_digest source_revision <<<"${metadata}"
          printf '%s|%s|%s|%s\n' \
            "${version}" "${revision}" "${input_digest}" "${source_revision}"
        fi
      fi
      return 0
    fi
    printf '%s: not found\n' "$4" >&2
    return 1
  fi

  if [[ "$1 $2" == "image inspect" ]]; then
    local ref="${!#}"
    grep -Fxq -- "${ref}" "${FAKE_LOCAL_REFS}" || return 1
    if [[ " $* " == *" --format "* ]]; then
      local metadata version revision input_digest source_revision
      metadata="$(metadata_for "${FAKE_LOCAL_IDENTITIES}" "${ref}")"
      if [[ -n "${metadata}" ]]; then
        read -r version revision input_digest source_revision <<<"${metadata}"
        printf '%s|%s|%s|%s\n' \
          "${version}" "${revision}" "${input_digest}" "${source_revision}"
      fi
    fi
    return
  fi

  if [[ "$1 $2" == "buildx build" ]]; then
    local previous=""
    local arg tag="" version="" revision="" input_digest="" source_revision=""
    for arg in "$@"; do
      if [[ "${previous}" == "--tag" ]]; then
        tag="${arg}"
        record_ref "${FAKE_LOCAL_REFS}" "${arg}"
      elif [[ "${previous}" == "--build-arg" ]]; then
        case "${arg}" in
          CODEX_VERSION=*) version="${arg#CODEX_VERSION=}" ;;
          MYCODEX_IMAGE_REVISION=*) revision="${arg#MYCODEX_IMAGE_REVISION=}" ;;
          MYCODEX_BUILD_INPUT_DIGEST=*) input_digest="${arg#MYCODEX_BUILD_INPUT_DIGEST=}" ;;
          MYCODEX_SOURCE_REVISION=*) source_revision="${arg#MYCODEX_SOURCE_REVISION=}" ;;
        esac
      fi
      previous="${arg}"
    done
    if [[ -n "${tag}" && -n "${version}" && -n "${revision}" \
      && -n "${input_digest}" && -n "${source_revision}" ]]; then
      set_identity \
        "${FAKE_LOCAL_IDENTITIES}" "${tag}" \
        "${version}" "${revision}" "${input_digest}" "${source_revision}"
      if [[ "${FAKE_CONCURRENT_REF:-}" == "${tag}" ]]; then
        record_ref "${FAKE_REMOTE_REFS}" "${tag}"
        copy_identity \
          "${FAKE_LOCAL_IDENTITIES}" "${tag}" \
          "${FAKE_REMOTE_IDENTITIES}" "${tag}"
      fi
    fi
    return
  fi

  if [[ "$1 $2" == "image tag" ]]; then
    record_ref "${FAKE_LOCAL_REFS}" "$4"
    copy_identity "${FAKE_LOCAL_IDENTITIES}" "$3" "${FAKE_LOCAL_IDENTITIES}" "$4"
    return
  fi

  if [[ "$1 $2" == "image push" ]]; then
    grep -Fxq -- "$3" "${FAKE_LOCAL_REFS}" || return 1
    record_ref "${FAKE_REMOTE_REFS}" "$3"
    copy_identity "${FAKE_LOCAL_IDENTITIES}" "$3" "${FAKE_REMOTE_IDENTITIES}" "$3"
    return
  fi

  if [[ "$1 $2 $3" == "buildx imagetools create" ]]; then
    local previous=""
    local arg source_ref=""
    local -a target_refs=()
    for arg in "$@"; do
      if [[ "${previous}" == "--tag" ]]; then
        record_ref "${FAKE_REMOTE_REFS}" "${arg}"
        target_refs+=("${arg}")
      elif [[ "${arg}" != -* && "${previous}" != "--tag" ]]; then
        source_ref="${arg}"
      fi
      previous="${arg}"
    done
    for arg in "${target_refs[@]}"; do
      if [[ -n "${source_ref}" ]]; then
        copy_identity "${FAKE_REMOTE_IDENTITIES}" "${source_ref}" "${FAKE_REMOTE_IDENTITIES}" "${arg}"
      fi
    done
    return
  fi

  fail "unhandled fake docker invocation: $*"
}
export -f docker record_ref set_identity identity_for metadata_for copy_identity fail

uname() {
  case "$1" in
    -m) printf '%s\n' "${FAKE_UNAME_MACHINE}" ;;
    -s) printf '%s\n' Linux ;;
    *) return 1 ;;
  esac
}
export -f uname

curl() {
  printf '{"version":"%s"}\n' "${FAKE_NPM_LATEST_VERSION:-0.999.0}"
}
export -f curl

probe_output="${tmp_dir}/probe-error.out"
export FAKE_INSPECT_ERROR_REF="example.test/workstation:probe-error"
set +e
mycodex_registry_ref_exists "${FAKE_INSPECT_ERROR_REF}" >"${probe_output}" 2>&1
probe_status=$?
set -e
unset FAKE_INSPECT_ERROR_REF
assert_eq "2" "${probe_status}" "indeterminate registry probe status"
assert_contains "${probe_output}" "cannot determine whether registry tag exists"

set +e
mycodex_registry_ref_exists "example.test/workstation:missing" >/dev/null 2>&1
probe_status=$?
set -e
assert_eq "1" "${probe_status}" "missing registry probe status"

missing_docker_output="${tmp_dir}/missing-docker.out"
set +e
(
  unset -f docker
  # shellcheck disable=SC2123 # Deliberately hide host executables for this probe.
  PATH="${tmp_dir}/empty-path"
  mycodex_registry_ref_exists "example.test/workstation:unknown"
) >"${missing_docker_output}" 2>&1
probe_status=$?
set -e
assert_eq "2" "${probe_status}" "missing Docker registry probe status"
assert_contains "${missing_docker_output}" "without the Docker CLI"

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

reset_fake_state() {
  : >"${FAKE_DOCKER_LOG}"
  : >"${FAKE_LOCAL_REFS}"
  : >"${FAKE_REMOTE_REFS}"
  : >"${FAKE_LOCAL_IDENTITIES}"
  : >"${FAKE_REMOTE_IDENTITIES}"
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
assert_contains "${FAKE_DOCKER_LOG}" "--tag example.test/workstation:0.146.0-r2 example.test/workstation:0.146.0-r2-amd64 example.test/workstation:0.146.0-r2-arm64"
assert_contains "${FAKE_DOCKER_LOG}" "--tag example.test/workstation:0.146.0 --tag example.test/workstation:latest example.test/workstation:0.146.0-r2"
assert_occurrences "${FAKE_DOCKER_LOG}" "buildx imagetools inspect example.test/workstation:0.146.0-r2-amd64" 1
assert_occurrences "${FAKE_DOCKER_LOG}" "buildx imagetools inspect example.test/workstation:0.146.0-r2-arm64" 3
assert_occurrences "${FAKE_DOCKER_LOG}" "buildx imagetools inspect example.test/workstation:0.146.0-r2" 1

: >"${FAKE_DOCKER_LOG}"
retry_output="${tmp_dir}/retry.out"
run_build x86_64 amd64 "${retry_output}" --version 0.146.0 --revision 2 --refresh-tags --push
assert_contains "${retry_output}" "immutable registry tag already exists"
assert_not_contains "${FAKE_DOCKER_LOG}" "buildx build"
assert_not_contains "${FAKE_DOCKER_LOG}" "image push"
assert_not_contains "${FAKE_DOCKER_LOG}" "imagetools create"
assert_contains "${retry_output}" "Moving registry aliases were not changed."
assert_contains "${retry_output}" "No local image or local aliases were created."

: >"${FAKE_DOCKER_LOG}"
: >"${FAKE_LOCAL_REFS}"
: >"${FAKE_REMOTE_REFS}"
: >"${FAKE_LOCAL_IDENTITIES}"
: >"${FAKE_REMOTE_IDENTITIES}"
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

record_ref "${FAKE_REMOTE_REFS}" "example.test/workstation:0.146.0-r2-amd64"
record_ref "${FAKE_REMOTE_REFS}" "example.test/workstation:0.146.0-r2-arm64"
record_ref "${FAKE_REMOTE_REFS}" "example.test/workstation:0.146.0-r2"
set_identity \
  "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:0.146.0-r2-amd64" \
  0.146.0 2 "${TEST_BUILD_INPUT_DIGEST}" "${TEST_SOURCE_REVISION}"
set_identity \
  "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:0.146.0-r2-arm64" \
  0.146.0 2 "${TEST_BUILD_INPUT_DIGEST}" "${TEST_SOURCE_REVISION}"
set_identity \
  "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:0.146.0-r2" \
  0.146.0 2 "${TEST_BUILD_INPUT_DIGEST}" "${TEST_SOURCE_REVISION}"
: >"${FAKE_DOCKER_LOG}"
older_retry_output="${tmp_dir}/older-retry.out"
run_build x86_64 amd64 "${older_retry_output}" --version 0.146.0 --revision 2 --push
assert_not_contains "${FAKE_DOCKER_LOG}" "imagetools create"
assert_contains "${older_retry_output}" "Moving registry aliases were not changed."

: >"${FAKE_DOCKER_LOG}"
explicit_promotion_output="${tmp_dir}/explicit-promotion.out"
run_build x86_64 amd64 "${explicit_promotion_output}" --version 0.146.0 --revision 2 --manifest
assert_contains "${explicit_promotion_output}" "Explicit --manifest finalization will evaluate moving aliases for monotonic promotion."
assert_contains "${explicit_promotion_output}" "Protected moving aliases left unchanged:"
assert_contains "${FAKE_DOCKER_LOG}" "--tag example.test/workstation:0.146.0 example.test/workstation:0.146.0-r2"
assert_not_contains "${FAKE_DOCKER_LOG}" "--tag example.test/workstation:latest"

: >"${FAKE_DOCKER_LOG}"
: >"${FAKE_LOCAL_REFS}"
: >"${FAKE_REMOTE_REFS}"
: >"${FAKE_LOCAL_IDENTITIES}"
: >"${FAKE_REMOTE_IDENTITIES}"
run_build x86_64 amd64 "${tmp_dir}/delayed-old-amd64.out" --version 0.148.0 --revision 1 --push
run_build x86_64 amd64 "${tmp_dir}/new-amd64.out" --version 0.149.0 --revision 1 --push
run_build aarch64 arm64 "${tmp_dir}/new-arm64.out" --version 0.149.0 --revision 1 --push
assert_eq "0.149.0 1" \
  "$(identity_for "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:latest")" \
  "latest identity before delayed release completion"

: >"${FAKE_DOCKER_LOG}"
delayed_completion_output="${tmp_dir}/delayed-completion.out"
run_build aarch64 arm64 "${delayed_completion_output}" --version 0.148.0 --revision 1 --push
assert_ref_exists "example.test/workstation:0.148.0-r1"
assert_ref_exists "example.test/workstation:0.148.0"
assert_contains "${delayed_completion_output}" "Keeping newer moving alias example.test/workstation:latest at 0.149.0-r1"
assert_contains "${delayed_completion_output}" "Protected moving aliases left unchanged:"
assert_contains "${FAKE_DOCKER_LOG}" "--tag example.test/workstation:0.148.0 example.test/workstation:0.148.0-r1"
assert_not_contains "${FAKE_DOCKER_LOG}" "--tag example.test/workstation:latest"
assert_eq "0.149.0 1" \
  "$(identity_for "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:latest")" \
  "latest identity after delayed release completion"

: >"${FAKE_DOCKER_LOG}"
: >"${FAKE_LOCAL_REFS}"
: >"${FAKE_REMOTE_REFS}"
: >"${FAKE_LOCAL_IDENTITIES}"
: >"${FAKE_REMOTE_IDENTITIES}"
run_build x86_64 amd64 "${tmp_dir}/delayed-r1-amd64.out" --version 0.150.0 --revision 1 --push
run_build x86_64 amd64 "${tmp_dir}/r2-amd64.out" --version 0.150.0 --revision 2 --push
run_build aarch64 arm64 "${tmp_dir}/r2-arm64.out" --version 0.150.0 --revision 2 --push

: >"${FAKE_DOCKER_LOG}"
delayed_revision_output="${tmp_dir}/delayed-revision.out"
run_build aarch64 arm64 "${delayed_revision_output}" --version 0.150.0 --revision 1 --push
assert_contains "${delayed_revision_output}" "Keeping newer moving alias example.test/workstation:0.150.0 at 0.150.0-r2"
assert_contains "${delayed_revision_output}" "Keeping newer moving alias example.test/workstation:latest at 0.150.0-r2"
assert_not_contains "${FAKE_DOCKER_LOG}" "--tag example.test/workstation:0.150.0 "
assert_not_contains "${FAKE_DOCKER_LOG}" "--tag example.test/workstation:latest"
assert_eq "0.150.0 2" \
  "$(identity_for "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:0.150.0")" \
  "version alias after delayed lower revision completion"
assert_eq "0.150.0 2" \
  "$(identity_for "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:latest")" \
  "latest alias after delayed lower revision completion"

: >"${FAKE_DOCKER_LOG}"
: >"${FAKE_LOCAL_REFS}"
: >"${FAKE_REMOTE_REFS}"
: >"${FAKE_LOCAL_IDENTITIES}"
: >"${FAKE_REMOTE_IDENTITIES}"
record_ref "${FAKE_REMOTE_REFS}" "example.test/workstation:0.151.0"
record_ref "${FAKE_REMOTE_REFS}" "example.test/workstation:latest"
export FAKE_NPM_LATEST_VERSION=0.151.0
run_build x86_64 amd64 "${tmp_dir}/legacy-amd64.out" --version 0.151.0 --revision 1 --push
legacy_migration_output="${tmp_dir}/legacy-migration.out"
run_build aarch64 arm64 "${legacy_migration_output}" --version 0.151.0 --revision 1 --push
unset FAKE_NPM_LATEST_VERSION
assert_contains "${legacy_migration_output}" "Migrating legacy moving alias example.test/workstation:0.151.0"
assert_contains "${legacy_migration_output}" "Migrating legacy latest alias example.test/workstation:latest"
assert_eq "0.151.0 1" \
  "$(identity_for "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:latest")" \
  "legacy latest migration identity"

reset_fake_state
auto_amd64_output="${tmp_dir}/auto-amd64.out"
run_build x86_64 amd64 "${auto_amd64_output}" --version 0.160.0 --push
assert_contains "${auto_amd64_output}" "Selected image revision 1 for new image inputs"
assert_ref_exists "example.test/workstation:0.160.0-r1-amd64"
assert_ref_missing "example.test/workstation:0.160.0-r2-amd64"

: >"${FAKE_DOCKER_LOG}"
auto_partial_retry_output="${tmp_dir}/auto-partial-retry.out"
run_build x86_64 amd64 "${auto_partial_retry_output}" --version 0.160.0 --push
assert_contains "${auto_partial_retry_output}" "Reusing image revision 1 for matching image inputs"
assert_not_contains "${FAKE_DOCKER_LOG}" "buildx build"
assert_not_contains "${FAKE_DOCKER_LOG}" "image push"
assert_not_contains "${FAKE_DOCKER_LOG}" "imagetools create"

auto_arm64_output="${tmp_dir}/auto-arm64.out"
run_build aarch64 arm64 "${auto_arm64_output}" --version 0.160.0 --push
assert_contains "${auto_arm64_output}" "Reusing image revision 1 for matching image inputs"
assert_ref_exists "example.test/workstation:0.160.0-r1"
assert_ref_exists "example.test/workstation:0.160.0"

: >"${FAKE_DOCKER_LOG}"
auto_complete_retry_output="${tmp_dir}/auto-complete-retry.out"
run_build x86_64 amd64 "${auto_complete_retry_output}" --version 0.160.0 --push
assert_contains "${auto_complete_retry_output}" "Reusing image revision 1 for matching image inputs"
assert_contains "${auto_complete_retry_output}" "Moving registry aliases were not changed."
assert_not_contains "${FAKE_DOCKER_LOG}" "buildx build"
assert_not_contains "${FAKE_DOCKER_LOG}" "image push"
assert_not_contains "${FAKE_DOCKER_LOG}" "imagetools create"
assert_ref_missing "example.test/workstation:0.160.0-r2-amd64"

changed_input_digest="sha256:$(printf 'b%.0s' {1..64})"
for changed_ref in \
  example.test/workstation:0.160.0-r1-amd64 \
  example.test/workstation:0.160.0-r1-arm64 \
  example.test/workstation:0.160.0-r1 \
  example.test/workstation:0.160.0; do
  set_identity \
    "${FAKE_REMOTE_IDENTITIES}" "${changed_ref}" \
    0.160.0 1 "${changed_input_digest}" "${TEST_SOURCE_REVISION}"
done
: >"${FAKE_DOCKER_LOG}"
changed_amd64_output="${tmp_dir}/changed-amd64.out"
run_build x86_64 amd64 "${changed_amd64_output}" --version 0.160.0 --push
assert_contains "${changed_amd64_output}" "Selected image revision 2 for new image inputs"
assert_ref_exists "example.test/workstation:0.160.0-r2-amd64"
assert_ref_missing "example.test/workstation:0.160.0-r2"

changed_arm64_output="${tmp_dir}/changed-arm64.out"
run_build aarch64 arm64 "${changed_arm64_output}" --version 0.160.0 --push
assert_contains "${changed_arm64_output}" "Reusing image revision 2 for matching image inputs"
assert_ref_exists "example.test/workstation:0.160.0-r2"
assert_eq "${TEST_BUILD_INPUT_DIGEST}" \
  "$(input_digest_for "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:0.160.0")" \
  "promoted version alias build-input digest"

reset_fake_state
record_ref "${FAKE_REMOTE_REFS}" "example.test/workstation:0.161.0"
set_identity \
  "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:0.161.0" \
  0.161.0 1 "" ""
legacy_auto_output="${tmp_dir}/legacy-auto.out"
run_build x86_64 amd64 "${legacy_auto_output}" --version 0.161.0 --push
assert_contains "${legacy_auto_output}" "Selected image revision 2 for new image inputs"
assert_ref_exists "example.test/workstation:0.161.0-r2-amd64"

reset_fake_state
record_ref "${FAKE_REMOTE_REFS}" "example.test/workstation:0.162.0-r1-amd64"
record_ref "${FAKE_REMOTE_REFS}" "example.test/workstation:0.162.0-r1-arm64"
set_identity \
  "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:0.162.0-r1-amd64" \
  0.162.0 1 "${TEST_BUILD_INPUT_DIGEST}" "${TEST_SOURCE_REVISION}"
set_identity \
  "${FAKE_REMOTE_IDENTITIES}" "example.test/workstation:0.162.0-r1-arm64" \
  0.162.0 1 "${changed_input_digest}" "${TEST_SOURCE_REVISION}"
conflicting_auto_output="${tmp_dir}/conflicting-auto.out"
if run_build x86_64 amd64 "${conflicting_auto_output}" --version 0.162.0 --push; then
  fail "automatic revision selection accepted conflicting architecture identities"
fi
assert_contains "${conflicting_auto_output}" "contains conflicting build-input identities"
assert_not_contains "${FAKE_DOCKER_LOG}" "imagetools create"

conflicting_manifest_output="${tmp_dir}/conflicting-manifest.out"
if run_build x86_64 amd64 "${conflicting_manifest_output}" \
  --version 0.162.0 --revision 1 --manifest; then
  fail "manifest finalization accepted conflicting architecture identities"
fi
assert_contains "${conflicting_manifest_output}" "belongs to different or legacy image inputs"
assert_ref_missing "example.test/workstation:0.162.0-r1"

reset_fake_state
export FAKE_CONCURRENT_REF="example.test/workstation:0.163.0-r1-amd64"
concurrent_output="${tmp_dir}/concurrent.out"
run_build x86_64 amd64 "${concurrent_output}" --version 0.163.0 --push
unset FAKE_CONCURRENT_REF
assert_contains "${concurrent_output}" "published concurrently; kept immutable"
assert_not_contains "${FAKE_DOCKER_LOG}" "image push"
assert_ref_exists "example.test/workstation:0.163.0-r1-amd64"
assert_ref_missing "example.test/workstation:0.163.0-r1"

reset_fake_state
stale_local_ref="example.test/workstation:0.164.0-r1-amd64"
record_ref "${FAKE_LOCAL_REFS}" "${stale_local_ref}"
set_identity \
  "${FAKE_LOCAL_IDENTITIES}" "${stale_local_ref}" \
  0.164.0 1 "${changed_input_digest}" "${TEST_SOURCE_REVISION}"
stale_local_output="${tmp_dir}/stale-local.out"
run_build x86_64 amd64 "${stale_local_output}" --version 0.164.0 --push
assert_contains "${stale_local_output}" "local tag has different or legacy image inputs"
assert_contains "${FAKE_DOCKER_LOG}" "buildx build"
assert_eq "${TEST_BUILD_INPUT_DIGEST}" \
  "$(input_digest_for "${FAKE_REMOTE_IDENTITIES}" "${stale_local_ref}")" \
  "rebuilt local image identity"

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

reserved_version_build_output="${tmp_dir}/reserved-version.out"
if run_build x86_64 amd64 "${reserved_version_build_output}" --version 0.146.0-r2 --revision 3; then
  fail "build accepted an image release tag as a Codex version"
fi
assert_contains "${reserved_version_build_output}" "--version 0.146.0 --revision 2"

registry_error_output="${tmp_dir}/registry-error.out"
export FAKE_INSPECT_ERROR_REF="example.test/workstation:0.300.0-r1-amd64"
if run_build x86_64 amd64 "${registry_error_output}" --version 0.300.0 --revision 1 --push; then
  fail "build treated a registry inspection error as a missing immutable tag"
fi
unset FAKE_INSPECT_ERROR_REF
assert_contains "${registry_error_output}" "cannot determine whether registry tag exists"
assert_not_contains "${registry_error_output}" "Building example.test/workstation:0.300.0-r1-amd64"

printf 'PASS: image release versioning and split-builder publication\n'
