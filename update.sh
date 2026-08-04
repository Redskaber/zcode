#!/usr/bin/env bash
# @path: derivations/zcode/update.sh
# @author: redskaber
# @datetime: 2026-08-04
# @description: Refresh sources.nix with the latest ZCode release for all 4 platforms.
#
# ZCode does not expose a JSON version manifest. Instead, we scrape the public
# downloads page (https://zcode.z.ai/cn#all-downloads), which embeds every
# release URL in the rendered HTML. We:
#   1. Fetch the page.
#   2. Extract all CDN URLs of the form
#      `https://cdn-zcode.z.ai/zcode/electron/releases/<v>/linux-x64/ZCode-<v>-linux-x64.deb`
#      (the new pattern; older 3.1.x–3.4.x used flat .AppImage files and are
#      filtered out automatically).
#   3. Pick the highest semver version.
#   4. Verify all 4 expected URLs exist (HEAD request) for that version.
#   5. Prefetch each artifact with `nix-prefetch-url` to get the nix32 sha256.
#   6. Emit sources.nix.
#
# Usage:
#   nix run .#update-sources
#   DOWNLOADS_PAGE=https://zcode.z.ai/en ./update.sh
#
# Requires: curl, nix-prefetch-url (shipped with Nix).

set -euo pipefail

DOWNLOADS_PAGE="${DOWNLOADS_PAGE:-https://zcode.z.ai/cn?utm_source=codegeex_ext#all-downloads}"
SOURCES_FILE="${SOURCES_FILE:-sources.nix}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Fetching ZCode downloads page: $DOWNLOADS_PAGE ..."
PAGE_HTML="$TMP_DIR/page.html"
curl -fsSL "$DOWNLOADS_PAGE" -o "$PAGE_HTML"

# Extract distinct versions from new-pattern URLs only:
#   .../releases/<VERSION>/linux-x64/ZCode-<VERSION>-linux-x64.deb
VERSIONS=$(grep -oE \
  'https://cdn-zcode\.z\.ai/zcode/electron/releases/[0-9]+\.[0-9]+\.[0-9]+/linux-x64/ZCode-[0-9]+\.[0-9]+\.[0-9]+-linux-x64\.deb' \
  "$PAGE_HTML" |
  sed -E 's#.*/releases/([0-9]+\.[0-9]+\.[0-9]+)/.*#\1#' |
  sort -uV)

if [[ -z "$VERSIONS" ]]; then
  echo "ERROR: no ZCode linux-x64 deb URLs found on the downloads page." >&2
  echo "The CDN URL pattern may have changed; inspect $PAGE_HTML and update this script." >&2
  exit 1
fi

# Pick the highest version (sort -V then tail -1).
VERSION=$(echo "$VERSIONS" | tail -1)
echo "Latest ZCode version detected: $VERSION"

# Sanity-check that ALL 4 platform URLs actually exist before we prefetch.
declare -A PLATFORM_PATH=(
  ["x86_64-linux"]="linux-x64"
  ["aarch64-linux"]="linux-arm64"
  ["x86_64-darwin"]="macos-x64"
  ["aarch64-darwin"]="macos-arm64"
)
declare -A PLATFORM_FILE=(
  ["x86_64-linux"]="linux-x64.deb"
  ["aarch64-linux"]="linux-arm64.deb"
  ["x86_64-darwin"]="mac-x64.dmg"
  ["aarch64-darwin"]="mac-arm64.dmg"
)

declare -A URLS
for system in "${!PLATFORM_PATH[@]}"; do
  arch_path="${PLATFORM_PATH[$system]}"
  arch_file="${PLATFORM_FILE[$system]}"
  url="https://cdn-zcode.z.ai/zcode/electron/releases/${VERSION}/${arch_path}/ZCode-${VERSION}-${arch_file}"
  status=$(curl -fsIL -o /dev/null -w '%{http_code}' "$url" || true)
  if [[ "$status" != "200" ]]; then
    echo "ERROR: HTTP $status for $url" >&2
    echo "  Some platforms may lag behind; check https://zcode.z.ai/cn#all-downloads manually." >&2
    exit 1
  fi
  URLS[$system]="$url"
done

# Generate sources.nix using nix-prefetch-url for the nix32 sha256.
{
  echo "{"
  echo "  version = \"$VERSION\";"
  echo ""
  for system in "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"; do
    url="${URLS[$system]}"
    echo "  $system = {"
    echo "    url = \"$url\";"
    # nix-prefetch-url prints the nix32 sha256 to stdout.
    sha256=$(nix-prefetch-url --type sha256 "$url")
    echo "    sha256 = \"$sha256\";"
    echo "  };"
    echo ""
  done
  echo "}"
} >"$SOURCES_FILE"

echo "Wrote $SOURCES_FILE (4 platforms, version $VERSION)"
echo
echo "Next steps:"
echo "  nix build .#packages.x86_64-linux.default"
echo "  nix build .#packages.aarch64-linux.default"
echo "  nix build .#packages.x86_64-darwin.default   (on a Darwin host)"
echo "  nix build .#packages.aarch64-darwin.default  (on a Darwin host)"
echo "  ./result/bin/zcode"
