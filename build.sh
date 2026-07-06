#!/usr/bin/env bash
# Build a flat Cydia/APT repo from GitHub-hosted app repos.
#
# Each app repo contains one or more build/*.ipa files. When an app ships
# several iOS-specific builds (e.g. oldpipe_ios6.ipa, oldpipe_ios7.ipa,
# oldpipe_ios8.ipa) they are packaged under the SAME package id, each with a
# `Depends: firmware (>= X), firmware (<< Y)` bound. Cydia/APT then installs
# the single build whose firmware range matches the device, and falls back to
# the next-lower build for iOS versions with no dedicated ipa.
#
# Usage: ./build.sh [output_dir]   (default: public)
set -euo pipefail

OWNER="${CYDIA_OWNER:-RousseAddict}"
OUT="${1:-public}"
DEBS="$OUT/debs"
SRC=".src"

mkdir -p "$OUT" "$DEBS" "$SRC"

# Extract the iOS major version from an ipa filename (default 6 if untagged).
ios_of() {
  local n
  n="$(printf '%s' "$1" | grep -oiE 'ios[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
  printf '%s' "${n:-6}"
}

while IFS='|' read -r repo package name section description; do
  case "${repo:-}" in ''|\#*) continue ;; esac
  repodir="$SRC/$repo"

  if [ -d "$repodir/.git" ]; then
    git -C "$repodir" fetch -q origin </dev/null
    git -C "$repodir" reset --hard -q origin/HEAD </dev/null
  else
    git clone -q "https://github.com/$OWNER/$repo.git" "$repodir" </dev/null
  fi

  # Collect ipas as "iosN:path", sorted ascending by iOS version.
  pairs=()
  for ipa in "$repodir"/build/*.ipa; do
    [ -e "$ipa" ] || continue
    pairs+=("$(ios_of "$ipa"):$ipa")
  done
  if [ "${#pairs[@]}" -eq 0 ]; then
    echo "WARN: no ipa found in $repo/build, skipping" >&2
    continue
  fi
  IFS=$'\n' sorted=($(printf '%s\n' "${pairs[@]}" | sort -t: -k1,1n)); unset IFS

  count="$(git -C "$repodir" rev-list --count HEAD)"
  total="${#sorted[@]}"

  for i in "${!sorted[@]}"; do
    n="${sorted[$i]%%:*}"
    ipa="${sorted[$i]#*:}"

    # Firmware bound: [thisIOS, nextBuildIOS). Highest build has no upper bound.
    if [ "$((i + 1))" -lt "$total" ]; then
      next="${sorted[$((i + 1))]%%:*}"
      depends="firmware (>= ${n}.0), firmware (<< ${next}.0)"
    else
      depends="firmware (>= ${n}.0)"
    fi

    version="1.0+${count}-ios${n}"
    stage="$(mktemp -d)"; payload="$(mktemp -d)"
    mkdir -p "$stage/Applications" "$stage/DEBIAN"

    unzip -qq "$ipa" -d "$payload"
    appdir="$(ls -d "$payload"/Payload/*.app 2>/dev/null | head -n1 || true)"
    if [ -z "$appdir" ]; then
      echo "WARN: no .app inside $ipa, skipping" >&2
      rm -rf "$stage" "$payload"; continue
    fi
    cp -a "$appdir" "$stage/Applications/"

    cat > "$stage/DEBIAN/control" <<EOF
Package: $package
Name: $name
Version: $version
Architecture: iphoneos-arm
Description: $description
Author: $name
Maintainer: $OWNER
Section: ${section:-Applications}
Depends: $depends
EOF

    # gzip: old dpkg/Cydia on iOS 6 cannot read xz/zstd payloads.
    dpkg-deb -Zgzip -b "$stage" "$DEBS/${package}_${version}_iphoneos-arm.deb" >/dev/null
    rm -rf "$stage" "$payload"
  done
done < apps.conf

cd "$OUT"
dpkg-scanpackages -m debs /dev/null > Packages 2>/dev/null
bzip2 -kf9 Packages

cat > Release <<EOF
Origin: ${OWNER} Cydia Repo
Label: ${OWNER}
Suite: stable
Version: 1.0
Codename: stable
Architectures: iphoneos-arm
Components: main
Description: Legacy iOS apps by ${OWNER}
EOF

# Landing page so the repo root isn't a bare 404 in a browser.
{
  echo "<!doctype html><html><head><meta charset=\"utf-8\">"
  echo "<title>${OWNER} Cydia Repo</title></head><body>"
  echo "<h1>${OWNER} Cydia Repo</h1>"
  echo "<p>Legacy iOS apps. Add this URL as a source in Cydia, then install:</p><ul>"
  awk 'BEGIN{RS="";FS="\n"}{p=n=v="";for(i=1;i<=NF;i++){if($i ~ /^Package: /)p=substr($i,10);if($i ~ /^Name: /)n=substr($i,7);if($i ~ /^Version: /)v=substr($i,10)}if(p!="")print "<li><b>"(n?n:p)"</b> <code>"p"</code> "v"</li>"}' Packages
  echo "</ul></body></html>"
} > index.html

echo "cydia repo built into '$OUT' ($(date -u +%FT%TZ))"
