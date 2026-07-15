#!/usr/bin/env bash
# Build a flat Cydia/APT repo from GitHub-hosted app repos.
#
# Each app repo contains one or more build/*.ipa files. When an app ships
# several iOS-specific builds (e.g. oldpipe_ios6.ipa, oldpipe_ios7.ipa,
# oldpipe_ios8.ipa) they are packaged under the SAME package id, each with a
# `Depends: firmware (>= X)` lower bound and an iOS-ascending version string.
# Cydia/APT installs the highest-versioned build whose firmware bound the
# device satisfies, falling back to the next-lower build for iOS versions with
# no dedicated ipa. (No `<< Y` upper bound: legacy iOS 6/7 Cydia cannot parse
# a two-clause firmware dependency and aborts the whole index.)
#
# Usage: ./build.sh [output_dir]   (default: public)
set -euo pipefail

OWNER="${CYDIA_OWNER:-RousseAddict}"
OUT="${1:-public}"
DEBS="$OUT/debs"
SRC=".src"

mkdir -p "$OUT" "$DEBS" "$SRC"

# Repo/site icon: ginger.png -> site favicon + Cydia repo icon (CydiaIcon.png).
if [ -f ginger.png ]; then
  cp ginger.png "$OUT/ginger.png"
  cp ginger.png "$OUT/CydiaIcon.png"
fi

# GitHub Pages custom-domain marker (must be in the deployed artifact root).
[ -f CNAME ] && cp CNAME "$OUT/CNAME"

# Landing-page metadata, accumulated per package during the build.
declare -A APP_NAME APP_IOS APP_SHA APP_REPO
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
  APP_REPO[$package]="$repo"
  APP_SHA[$package]="$(git -C "$repodir" rev-parse --short HEAD)"

  count="$(git -C "$repodir" rev-list --count HEAD)"

  for i in "${!sorted[@]}"; do
    n="${sorted[$i]%%:*}"
    ipa="${sorted[$i]#*:}"

    # Lower bound only. Legacy Cydia/APT on iOS 6/7 cannot parse a second
    # firmware clause / the `<<` upper bound and aborts the whole index
    # ("dependencies can't be parsed"). APT already installs the highest
    # eligible candidate, and our version string sorts by iOS ascending, so a
    # device gets the highest build its firmware allows, falling back to the
    # next-lower build automatically -- no upper bound required.
    depends="firmware (>= ${n}.0)"

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
<link rel="icon" href="ginger.png">
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
  .name a{color:inherit;text-decoration:none}
  .name a:hover{text-decoration:underline}
  code{color:#888;font-size:.85em}
  code a{color:inherit;text-decoration:none;border-bottom:1px dotted #aaa}
  code a:hover{border-bottom-style:solid}
  .gh{display:inline-flex;align-items:center;opacity:.55}
  .gh:hover{opacity:1}
  .gh svg{width:1rem;height:1rem;fill:currentColor;vertical-align:-2px}
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
  if [ -n "$url" ]; then
    echo "<p>Add a source in Cydia / Sileo:</p>"
    case "$url" in
      http://*)
        echo "<p class=\"sub\">Modern iOS (HTTPS):</p><code class=\"src\">deb https://${url#http://} ./</code>"
        echo "<p class=\"sub\">iOS 6/7 without modern TLS (HTTP):</p><code class=\"src\">deb ${url} ./</code>"
        ;;
      *)
        echo "<code class=\"src\">deb ${url} ./</code>"
        ;;
    esac
  fi
  echo "<ul>"
  for pkg in "${ORDER[@]}"; do
    badges=""
    for v in $(printf '%s\n' ${APP_IOS[$pkg]:-} | sort -un); do
      badges="${badges}<span class=\"badge\">iOS ${v}</span>"
    done
    repo="${APP_REPO[$pkg]:-}"
    repo_url="https://github.com/${OWNER}/${repo}"
    sha="${APP_SHA[$pkg]:-}"
    sha_html="<code>${sha}</code>"
    [ -n "$sha" ] && sha_html="<code><a href=\"${repo_url}/commit/${sha}\" title=\"View commit on GitHub\">${sha}</a></code>"
    gh_link="<a class=\"gh\" href=\"${repo_url}\" title=\"View ${repo} on GitHub\" aria-label=\"View ${repo} on GitHub\"><svg viewBox=\"0 0 16 16\"><path d=\"M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z\"/></svg></a>"
    echo "<li><span class=\"name\"><a href=\"${repo_url}\">${APP_NAME[$pkg]}</a></span> <code>${pkg}</code> ${sha_html} ${badges} ${gh_link}</li>"
  done
  echo "</ul></body></html>"
} > index.html

echo "cydia repo built into '$OUT' ($(date -u +%FT%TZ))"
