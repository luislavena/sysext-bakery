#!/usr/bin/env bash
# vim: et ts=2 syn=bash
#
# Build the uncloud sysext (x86-64 and arm64) and publish it to a Cloudflare
# R2 bucket served as a plain sysupdate directory:
#
#   extensions/uncloud.conf
#   extensions/uncloud/SHA256SUMS
#   extensions/uncloud/uncloud-<version>-<arch>.raw
#
# Usage: tools/publish-r2.sh <version|latest>
#
# Needs: docker, mise, a 'wrangler login' session, and in .env:
#   bakery_hub=<public hostname of the bucket>
#   R2_BUCKET=<bucket> (optional)

set -euo pipefail

cd "$(dirname "$0")/.."
[[ -s .env ]] && source .env

: "${bakery_hub:?set bakery_hub=<your hostname> in .env}"
if [[ ${bakery_hub} == extensions.flatcar.org ]]; then
  echo "ERROR: bakery_hub points at the upstream hub, set your own in .env" >&2
  exit 1
fi
R2_BUCKET="${R2_BUCKET:-hl-flatcar-07b9ab5a}"
version="${1:?usage: $0 <version|latest>}"
ext="uncloud"
base_url="https://${bakery_hub}/extensions"
wrangler=(mise exec -- pnpx wrangler@4.155.0)

out="$(mktemp -d)"
trap 'rm -rf "${out}"' EXIT

echo "Building ${ext} ${version} into ${out}"
docker run --rm \
  -v "${PWD}:/bakery:ro" -v "${out}:/out" -w /out \
  -e GH_TOKEN="${GH_TOKEN:-}" \
  -e ext="${ext}" -e version="${version}" \
  ubuntu:24.04 bash -euo pipefail -c '
    apt-get update -qq >/dev/null
    apt-get install -yqq curl jq squashfs-tools xz-utils erofs-utils >/dev/null
    if [[ ${version} == latest ]]; then
      version="$(/bakery/bakery.sh list "${ext}" --latest true | head -n1)"
    fi
    echo "${version}" > VERSION
    for arch in x86-64 arm64; do
      /bakery/bakery.sh create "${ext}" "${version}" --arch "${arch}" \
        --sysupdate true --output-file "${ext}-${version}-${arch}"
      cat "SHA256SUMS.${ext}" >> SHA256SUMS.new
    done
  '

version="$(<"${out}/VERSION")"
[[ -n ${version} ]] || { echo "ERROR: could not resolve version" >&2; exit 1; }
# lib/libbakery.sh only reads bakery_hub from .env, never from the environment.
grep -qx "Path=${base_url}/${ext}/" "${out}/${ext}.conf" \
  || { echo "ERROR: ${ext}.conf does not use ${bakery_hub}, set it in .env" >&2; exit 1; }

# Keep every version already published; -k2 dedupes on file name so a re-run
# replaces the old checksum instead of adding a second line.
{ curl -fsSL "${base_url}/${ext}/SHA256SUMS" || true; } > "${out}/SHA256SUMS.old"
sort -s -u -k2,2 "${out}/SHA256SUMS.new" "${out}/SHA256SUMS.old" > "${out}/SHA256SUMS"

function put() {
  local key="$1" file="$2"
  shift 2
  "${wrangler[@]}" r2 object put "${R2_BUCKET}/${key}" --file "${file}" --remote "${@}"
}

# shortcut: wrangler r2 object put caps objects at 315 MB, switch to
# rclone/S3 multipart if a .raw grows past that.
# Images first, SHA256SUMS last: a host must never see a checksum line
# before its file exists.
for arch in x86-64 arm64; do
  f="${ext}-${version}-${arch}.raw"
  put "extensions/${ext}/${f}" "${out}/${f}" --content-type application/octet-stream
done
put "extensions/${ext}.conf" "${out}/${ext}.conf" \
  --content-type text/plain --cache-control no-cache
put "extensions/${ext}/SHA256SUMS" "${out}/SHA256SUMS" \
  --content-type text/plain --cache-control no-cache

echo "Checking ${base_url}/${ext}/SHA256SUMS"
published="$(curl -fsSL "${base_url}/${ext}/SHA256SUMS")"
for arch in x86-64 arm64; do
  grep -q " ${ext}-${version}-${arch}.raw$" <<<"${published}" \
    || { echo "ERROR: ${ext}-${version}-${arch}.raw missing from SHA256SUMS" >&2; exit 1; }
done
echo "Published ${ext} ${version} to ${base_url}/${ext}/"
