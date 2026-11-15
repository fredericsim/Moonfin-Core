#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_root="$(cd "${script_dir}/../.." && pwd)"
readonly deployer="${repository_root}/scripts/deploy-moonbase-web.sh"
readonly test_root="$(mktemp -d "${TMPDIR:-/tmp}/moonfin-deployer-test.XXXXXX")"
readonly mock_bin="${test_root}/bin"
readonly container_root="${test_root}/container"
readonly release_root="${test_root}/release"
readonly docker_log="${test_root}/docker.log"
readonly public_manifest="${test_root}/public-build-manifest.json"
readonly invalid_public_manifest="${test_root}/invalid-public-build-manifest.json"
readonly real_curl="$(command -v curl)"
readonly bundle_commit="1111111111111111111111111111111111111111"
readonly frontend_path="/config/plugins/Moonbase_3.1.0.0/frontend"

cleanup() {
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "Expected file: $1"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${message}: expected ${expected}, got ${actual}"
}

mkdir -p "${mock_bin}" "${release_root}/bundle/theme/css" \
  "${release_root}/bundle/theme/js"

printf '<html></html>\n' > "${release_root}/bundle/index.html"
printf 'bootstrap\n' > "${release_root}/bundle/flutter_bootstrap.js"
printf '{"pluginMode":true}\n' > "${release_root}/bundle/config.json"
printf '{"commit":"%s","baseHref":"/Moonfin/Web/","pluginMode":true}\n' \
  "${bundle_commit}" > "${release_root}/bundle/build-manifest.json"
printf '<html></html>\n' > "${release_root}/bundle/theme/index.html"
printf 'css\n' > "${release_root}/bundle/theme/css/styles.css"
printf 'js\n' > "${release_root}/bundle/theme/js/app.js"
cp "${release_root}/bundle/build-manifest.json" "${public_manifest}"
printf '{"commit":"2222222222222222222222222222222222222222"}\n' \
  > "${invalid_public_manifest}"
tar -czf "${release_root}/moonfin-web.tar.gz" -C "${release_root}/bundle" .
sha256sum "${release_root}/moonfin-web.tar.gz" \
  > "${release_root}/moonfin-web.tar.gz.sha256"

cat > "${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
public_request=false
previous=""
for argument in "$@"; do
  if [[ "${previous}" == "--output" ]]; then
    output="${argument}"
  fi
  if [[ "${argument}" == *'?deploy='* ]]; then
    public_request=true
  fi
  previous="${argument}"
done

if [[ "${public_request}" == "true" ]]; then
  cp "${MOCK_PUBLIC_MANIFEST}" "${output}"
  exit 0
fi

exec "${REAL_CURL}" "$@"
EOF

cat > "${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${MOCK_DOCKER_LOG}"
printf '\n' >> "${MOCK_DOCKER_LOG}"

map_path() {
  printf '%s%s' "${MOCK_CONTAINER_ROOT}" "$1"
}

command_name="$1"
shift

case "${command_name}" in
  inspect)
    if [[ "${1:-}" == "--format" ]]; then
      format="$2"
      case "${format}" in
        *State.Running*) printf 'true\n' ;;
        *) printf 'MOONFIN_WEB_ROOT=%s\n' "${MOCK_FRONTEND_PATH}" ;;
      esac
    fi
    ;;
  cp)
    source_path="$1"
    destination_path="${2#*:}"
    mkdir -p "$(map_path "${destination_path}")"
    cp -R "${source_path%/.}/." "$(map_path "${destination_path}")"
    ;;
  restart)
    ;;
  exec)
    shift
    subcommand="$1"
    shift
    case "${subcommand}" in
      test)
        test "$1" "$(map_path "$2")"
        ;;
      mkdir)
        mkdir "$(map_path "$1")"
        ;;
      grep)
        grep "$1" "$2" "$(map_path "$3")"
        ;;
      find)
        parent="$1"
        shift
        find "$(map_path "${parent}")" "$@" \
          | while IFS= read -r result; do
              printf '%s\n' "${result#${MOCK_CONTAINER_ROOT}}"
            done
        ;;
      sh)
        [[ "$1" == "-c" ]] || exit 2
        active_path="$4"
        backup_path="$5"
        staged_path="$6"
        mv "$(map_path "${active_path}")" "$(map_path "${backup_path}")"
        mv "$(map_path "${staged_path}")" "$(map_path "${active_path}")"
        ;;
      rm)
        target="${!#}"
        rm -rf -- "$(map_path "${target}")"
        ;;
      *)
        printf 'Unexpected docker exec command: %s\n' "${subcommand}" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    printf 'Unexpected docker command: %s\n' "${command_name}" >&2
    exit 2
    ;;
esac
EOF

chmod +x "${mock_bin}/curl" "${mock_bin}/docker"

setup_container() {
  rm -rf -- "${container_root}"
  mkdir -p "${container_root}${frontend_path}" \
    "${container_root}${frontend_path}.backup-20260101T000000Z-1" \
    "${container_root}${frontend_path}.backup-20260201T000000Z-2"
  printf 'old frontend\n' > "${container_root}${frontend_path}/index.html"
  printf 'old bootstrap\n' > "${container_root}${frontend_path}/flutter_bootstrap.js"
  : > "${docker_log}"
}

run_deployer() {
  local retention="$1"
  local manifest="${2:-${public_manifest}}"
  PATH="${mock_bin}:${PATH}" \
    REAL_CURL="${real_curl}" \
    MOCK_CONTAINER_ROOT="${container_root}" \
    MOCK_DOCKER_LOG="${docker_log}" \
    MOCK_FRONTEND_PATH="${frontend_path}" \
    MOCK_PUBLIC_MANIFEST="${manifest}" \
    MOONFIN_RELEASE_BASE_URL="file://${release_root}" \
    MOONFIN_PUBLIC_MANIFEST_URL="https://media.example.test/Moonfin/Web/build-manifest.json" \
    MOONFIN_BACKUP_RETENTION="${retention}" \
    "${deployer}"
}

setup_container
run_deployer 1 > "${test_root}/retention-1.log"
backup_count="$(
  find "${container_root}/config/plugins/Moonbase_3.1.0.0" \
    -maxdepth 1 -type d -name 'frontend.backup-*' | wc -l | tr -d ' '
)"
assert_equals 1 "${backup_count}" "Retention 1 backup count"
assert_file "${container_root}${frontend_path}/build-manifest.json"
grep -q "${bundle_commit}" "${container_root}${frontend_path}/build-manifest.json" \
  || fail "Deployed frontend manifest does not contain the expected commit"

setup_container
mkdir "${container_root}${frontend_path}.backup-99991231T235959Z-9"
run_deployer 1 > "${test_root}/current-backup-first.log"
[[ ! -d "${container_root}${frontend_path}.backup-99991231T235959Z-9" ]] \
  || fail "Retention did not prioritize the current deployment backup"
backup_count="$(
  find "${container_root}/config/plugins/Moonbase_3.1.0.0" \
    -maxdepth 1 -type d -name 'frontend.backup-*' | wc -l | tr -d ' '
)"
assert_equals 1 "${backup_count}" "Current deployment backup count"

setup_container
run_deployer 2 > "${test_root}/retention-2.log"
backup_count="$(
  find "${container_root}/config/plugins/Moonbase_3.1.0.0" \
    -maxdepth 1 -type d -name 'frontend.backup-*' | wc -l | tr -d ' '
)"
assert_equals 2 "${backup_count}" "Retention 2 backup count"
[[ -d "${container_root}${frontend_path}.backup-20260201T000000Z-2" ]] \
  || fail "Retention 2 did not keep the newest pre-existing backup"

setup_container
run_deployer 0 > "${test_root}/retention-0.log"
backup_count="$(
  find "${container_root}/config/plugins/Moonbase_3.1.0.0" \
    -maxdepth 1 -type d -name 'frontend.backup-*' | wc -l | tr -d ' '
)"
assert_equals 0 "${backup_count}" "Retention 0 backup count"

setup_container
if run_deployer 1 "${invalid_public_manifest}" \
    > "${test_root}/failed-verification.log" 2>&1; then
  fail "Deployment with the wrong public manifest unexpectedly succeeded"
fi
backup_count="$(
  find "${container_root}/config/plugins/Moonbase_3.1.0.0" \
    -maxdepth 1 -type d -name 'frontend.backup-*' | wc -l | tr -d ' '
)"
assert_equals 3 "${backup_count}" "Failed verification must not prune backups"

: > "${docker_log}"
if PATH="${mock_bin}:${PATH}" \
  REAL_CURL="${real_curl}" \
  MOCK_CONTAINER_ROOT="${container_root}" \
  MOCK_DOCKER_LOG="${docker_log}" \
  MOCK_FRONTEND_PATH="${frontend_path}" \
  MOCK_PUBLIC_MANIFEST="${public_manifest}" \
  MOONFIN_BACKUP_RETENTION=01 \
  "${deployer}" > "${test_root}/invalid-retention.log" 2>&1; then
  fail "Invalid backup retention unexpectedly succeeded"
fi
[[ ! -s "${docker_log}" ]] \
  || fail "Invalid backup retention touched Docker before failing"
grep -q 'MOONFIN_BACKUP_RETENTION must be a non-negative integer' \
  "${test_root}/invalid-retention.log" \
  || fail "Invalid backup retention did not report the expected error"

printf 'deploy-moonbase-web tests passed\n'
