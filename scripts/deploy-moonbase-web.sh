#!/usr/bin/env bash
set -euo pipefail

# Deploy the latest compiled Moonfin web release from this fork into the
# Moonbase plugin running inside Jellyfin. The release is built by
# .github/workflows/release-web-bundle.yml after Checks succeeds on main.

readonly release_repository="${MOONFIN_RELEASE_REPOSITORY:-fredericsim/Moonfin-Core}"
readonly jellyfin_container="${JELLYFIN_CONTAINER:-jellyfin-app-1}"
readonly public_manifest_url="${MOONFIN_PUBLIC_MANIFEST_URL:-https://movie.sopolak.com/Moonfin/Web/build-manifest.json}"
readonly release_base_url_override="${MOONFIN_RELEASE_BASE_URL:-}"
readonly release_tag_override="${MOONFIN_RELEASE_TAG:-}"
readonly release_api_url="${MOONFIN_RELEASE_API_URL:-https://api.github.com/repos/${release_repository}/releases?per_page=100}"
readonly release_download_root="${MOONFIN_RELEASE_DOWNLOAD_ROOT:-https://github.com/${release_repository}/releases/download}"
readonly temp_parent="${TMPDIR:-/tmp}"

temp_dir=""
release_base_url=""
release_tag=""

cleanup() {
  if [[ -n "${temp_dir}" && "${temp_dir}" == "${temp_parent%/}/moonfin-web-deploy."* ]]; then
    rm -rf -- "${temp_dir}"
  fi
}
trap cleanup EXIT

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

for command_name in curl docker tar awk grep sed head tail tr date sleep mktemp; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "Required command not found: ${command_name}"
done

docker inspect "${jellyfin_container}" >/dev/null 2>&1 \
  || fail "Jellyfin container not found: ${jellyfin_container}"

if [[ "$(docker inspect --format '{{.State.Running}}' "${jellyfin_container}")" != "true" ]]; then
  fail "Jellyfin container is not running: ${jellyfin_container}"
fi

temp_dir="$(mktemp -d "${temp_parent%/}/moonfin-web-deploy.XXXXXX")"
archive_path="${temp_dir}/moonfin-web.tar.gz"
checksum_path="${archive_path}.sha256"
extract_dir="${temp_dir}/bundle"

if [[ -n "${release_base_url_override}" ]]; then
  release_base_url="${release_base_url_override%/}"
elif [[ -n "${release_tag_override}" ]]; then
  [[ "${release_tag_override}" =~ ^moonfin-web-[0-9a-fA-F]{12}$ ]] \
    || fail "MOONFIN_RELEASE_TAG is not a versioned Moonfin web release tag"
  release_tag="${release_tag_override}"
else
  release_index_path="${temp_dir}/releases.json"
  curl --fail --silent --show-error --location \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header 'User-Agent: moonfin-web-deployer' \
    "${release_api_url}" \
    --output "${release_index_path}"

  release_tag="$(
    awk '
      match($0, /"tag_name"[[:space:]]*:[[:space:]]*"moonfin-web-[0-9a-fA-F]+"/) {
        value = substr($0, RSTART, RLENGTH)
        split(value, fields, "\"")
        print fields[4]
        exit
      }
    ' "${release_index_path}"
  )"
  [[ "${release_tag}" =~ ^moonfin-web-[0-9a-fA-F]{12}$ ]] \
    || fail "No published versioned Moonfin web release was found"
fi

if [[ -n "${release_tag}" ]]; then
  release_base_url="${release_download_root%/}/${release_tag}"
  printf 'Downloading Moonfin web release %s from %s...\n' \
    "${release_tag}" "${release_repository}"
else
  printf 'Downloading Moonfin web release from custom URL %s...\n' \
    "${release_base_url}"
fi

curl --fail --silent --show-error --location \
  "${release_base_url}/moonfin-web.tar.gz" \
  --output "${archive_path}"
curl --fail --silent --show-error --location \
  "${release_base_url}/moonfin-web.tar.gz.sha256" \
  --output "${checksum_path}"

expected_checksum="$(awk 'NR == 1 { print $1 }' "${checksum_path}" | tr 'A-F' 'a-f')"
[[ "${expected_checksum}" =~ ^[0-9a-fA-F]{64}$ ]] \
  || fail "Release checksum file is invalid"

if command -v sha256sum >/dev/null 2>&1; then
  actual_checksum="$(sha256sum "${archive_path}" | awk '{ print $1 }' | tr 'A-F' 'a-f')"
elif command -v shasum >/dev/null 2>&1; then
  actual_checksum="$(shasum -a 256 "${archive_path}" | awk '{ print $1 }' | tr 'A-F' 'a-f')"
else
  fail "Neither sha256sum nor shasum is available"
fi

[[ "${actual_checksum}" == "${expected_checksum}" ]] \
  || fail "Moonfin bundle checksum mismatch"

archive_listing="${temp_dir}/archive-listing.txt"
tar -tzf "${archive_path}" > "${archive_listing}" \
  || fail "Could not list Moonfin bundle contents"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "${archive_listing}"; then
  fail "Moonfin bundle contains an unsafe path"
fi

mkdir -p "${extract_dir}"
tar -xzf "${archive_path}" -C "${extract_dir}"

for required_file in \
  index.html \
  flutter_bootstrap.js \
  config.json \
  build-manifest.json \
  theme/index.html \
  theme/css/styles.css \
  theme/js/app.js; do
  [[ -f "${extract_dir}/${required_file}" ]] \
    || fail "Moonfin bundle is missing ${required_file}"
done

bundle_manifest="${extract_dir}/build-manifest.json"
bundle_commit="$(sed -n 's/.*"commit"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]\{40\}\)".*/\1/p' "${bundle_manifest}" | head -n 1)"
[[ "${bundle_commit}" =~ ^[0-9a-fA-F]{40}$ ]] \
  || fail "Moonfin build manifest has no valid commit"
grep -Eq '"baseHref"[[:space:]]*:[[:space:]]*"/Moonfin/Web/"' "${bundle_manifest}" \
  || fail "Moonfin bundle has the wrong base href"
grep -Eq '"pluginMode"[[:space:]]*:[[:space:]]*true' "${bundle_manifest}" \
  || fail "Moonfin bundle is not a plugin-mode build"
grep -Eq '"pluginMode"[[:space:]]*:[[:space:]]*true' "${extract_dir}/config.json" \
  || fail "Moonfin runtime config is not in plugin mode"

frontend_path="${MOONFIN_FRONTEND_PATH:-}"
path_source="override"

if [[ -z "${frontend_path}" ]]; then
  frontend_path="$(
    docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${jellyfin_container}" \
      | sed -n 's/^MOONFIN_WEB_ROOT=//p' \
      | tail -n 1
  )"
  path_source="container environment"
fi

if [[ -z "${frontend_path}" ]]; then
  candidates="$(
    docker exec "${jellyfin_container}" sh -c \
      'find /config/plugins -type f -name build-manifest.json -print 2>/dev/null' \
      | grep -E '/(frontend|web)/build-manifest\.json$' \
      || true
  )"
  candidate_count="$(printf '%s\n' "${candidates}" | awk 'NF { count++ } END { print count + 0 }')"

  if [[ "${candidate_count}" == "0" ]]; then
    candidates="$(
      docker exec "${jellyfin_container}" sh -c \
        'find /config/plugins -type f -name flutter_bootstrap.js -print 2>/dev/null' \
        | grep -E '/(frontend|web)/flutter_bootstrap\.js$' \
        || true
    )"
    candidate_count="$(printf '%s\n' "${candidates}" | awk 'NF { count++ } END { print count + 0 }')"
    path_source="legacy automatic discovery"
  else
    path_source="automatic discovery"
  fi

  [[ "${candidate_count}" == "1" ]] \
    || fail "Expected one active Moonbase frontend, found ${candidate_count}. Set MOONFIN_FRONTEND_PATH explicitly."
  frontend_path="${candidates%/*}"
fi

while [[ "${frontend_path}" != "/" && "${frontend_path}" == */ ]]; do
  frontend_path="${frontend_path%/}"
done

case "${frontend_path}" in
  ''|'/'|'/config'|'/config/plugins')
    fail "Refusing unsafe Moonbase frontend path: ${frontend_path:-<empty>}"
    ;;
  /*) ;;
  *)
    fail "Moonbase frontend path must be absolute: ${frontend_path}"
    ;;
esac

if [[ ! "${frontend_path}" =~ ^/config/plugins/[^/]+/(frontend|web)$ ]]; then
  fail "Moonbase frontend path must be a frontend or web directory directly inside a plugin: ${frontend_path}"
fi

docker exec "${jellyfin_container}" test -d "${frontend_path}" \
  || fail "Moonbase frontend directory does not exist: ${frontend_path}"
for existing_marker in index.html flutter_bootstrap.js; do
  docker exec "${jellyfin_container}" test -f "${frontend_path}/${existing_marker}" \
    || fail "Refusing to replace a directory without the Moonbase frontend marker ${existing_marker}: ${frontend_path}"
done

deploy_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
staged_path="${frontend_path}.new-${deploy_id}"
backup_path="${frontend_path}.backup-${deploy_id}"

printf 'Deploying commit %s to %s (%s)...\n' \
  "${bundle_commit}" "${frontend_path}" "${path_source}"

docker exec "${jellyfin_container}" mkdir "${staged_path}"
docker cp "${extract_dir}/." "${jellyfin_container}:${staged_path}/" >/dev/null

docker exec "${jellyfin_container}" test -f "${staged_path}/index.html" \
  || fail "Staged frontend is missing index.html"
docker exec "${jellyfin_container}" grep -q "${bundle_commit}" "${staged_path}/build-manifest.json" \
  || fail "Staged frontend commit does not match the release"

if ! docker exec "${jellyfin_container}" sh -c '
  set -eu
  active_path="$1"
  backup_path="$2"
  staged_path="$3"

  mv "$active_path" "$backup_path"
  if ! mv "$staged_path" "$active_path"; then
    mv "$backup_path" "$active_path"
    exit 1
  fi
' sh "${frontend_path}" "${backup_path}" "${staged_path}"; then
  fail "Could not swap the Moonbase frontend; the previous frontend was restored"
fi

if ! docker restart "${jellyfin_container}" >/dev/null; then
  printf 'Jellyfin failed to restart. The previous frontend remains at:\n  %s\n' "${backup_path}" >&2
  exit 1
fi

live_manifest="${temp_dir}/live-build-manifest.json"
verified=false
attempt=1
while [[ "${attempt}" -le 15 ]]; do
  if curl --fail --silent --show-error \
      "${public_manifest_url}?deploy=${deploy_id}" \
      --output "${live_manifest}" 2>/dev/null \
      && grep -q "${bundle_commit}" "${live_manifest}"; then
    verified=true
    break
  fi

  sleep 2
  attempt=$((attempt + 1))
done

if [[ "${verified}" != "true" ]]; then
  printf 'The files were deployed, but the public manifest did not report commit %s.\n' \
    "${bundle_commit}" >&2
  printf 'Previous frontend backup:\n  %s\n' "${backup_path}" >&2
  exit 1
fi

printf '\nMoonfin web deployment complete.\n'
printf '  Commit: %s\n' "${bundle_commit}"
printf '  Frontend: %s\n' "${frontend_path}"
printf '  Backup: %s\n' "${backup_path}"
printf '  Verified: %s\n' "${public_manifest_url}"
