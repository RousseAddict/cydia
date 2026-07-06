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

# Landing-page metadata, accumulated per package during the build.
declare -A APP_NAME APP_IOS
ORDER=()

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

  ORDER+=("$package")
  APP_NAME[$package]="$name"

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
    APP_IOS[$package]="${APP_IOS[$package]:-} $n"
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

# Landing page: grouped by app, light styling, so the root isn't a bare 404.
url="${CYDIA_URL:-}"
{
  cat <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{color-scheme:light dark}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       max-width:40rem;margin:3rem auto;padding:0 1.25rem;line-height:1.5}
  h1{margin-bottom:.25rem}
  .sub{color:#888;margin-top:0}
  .src{display:block;background:#f4f4f5;border-radius:.5rem;padding:.75rem 1rem;
       font-family:ui-monospace,SFMono-Regular,Menlo,monospace;overflow-x:auto;margin:1rem 0 2rem}
  ul{list-style:none;padding:0}
  li{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem;
     padding:.75rem 0;border-top:1px solid #e5e5e5}
  .name{font-weight:600}
  code{color:#888;font-size:.85em}
  .badge{font-size:.7rem;font-weight:600;background:#e0edff;color:#1a56db;
         border-radius:1rem;padding:.15rem .55rem}
  @media(prefers-color-scheme:dark){
    .src{background:#1c1c1e} li{border-color:#2c2c2e}
    .badge{background:#1a3a6b;color:#9ec5ff}
  }
</style>
HTML
  echo "<title>${OWNER} Cydia Repo</title></head><body>"
  echo "<h1>${OWNER} Cydia Repo</h1>"
  echo "<p class=\"sub\">Legacy iOS apps by ${OWNER}.</p>"
  [ -n "$url" ] && echo "<p>Add this source in Cydia:</p><code class=\"src\">deb ${url} ./</code>"
  echo "<ul>"
  for pkg in "${ORDER[@]}"; do
    badges=""
    for v in $(printf '%s\n' ${APP_IOS[$pkg]:-} | sort -un); do
      badges="${badges}<span class=\"badge\">iOS ${v}</span>"
    done
    echo "<li><span class=\"name\">${APP_NAME[$pkg]}</span> <code>${pkg}</code> ${badges}</li>"
  done
  echo "</ul></body></html>"
} > index.html

echo "cydia repo built into '$OUT' ($(date -u +%FT%TZ))"
