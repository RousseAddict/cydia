#!/usr/bin/env bash
# Build an OTA (itms-services) install page from GitHub-hosted app repos.
#
# Reads the same apps.conf as build.sh. For every build/*.ipa in each app repo
# it emits a manifest.plist and lists it on an install page, one button per
# iOS-specific build. No firmware detection: every variant gets its own button
# in the same list and the user picks the one matching their device.
#
# The ipa itself is never copied -- manifests point at raw.githubusercontent.com
# pinned to the repo's current commit sha (immutable, no CDN cache staleness).
#
# CAVEATS
#  - iOS requires the manifest URL to be HTTPS with a *trusted* cert. GitHub
#    Pages and raw.githubusercontent.com both use Let's Encrypt, whose root is
#    absent from the iOS 6/7 trust store -- those devices need ISRG Root X1
#    installed as a configuration profile first.
#  - The ipas are ad-hoc signed with no provisioning profile, so installd only
#    accepts them on jailbroken devices (AppSync Unified).
#
# Usage: ./build-ota.sh [output_dir]   (default: public/OTA)
set -euo pipefail

OWNER="${CYDIA_OWNER:-RousseAddict}"
OUT="${1:-public/OTA}"
SRC=".src"

# Absolute HTTPS base the manifests are reachable at. itms-services needs an
# absolute URL, so this cannot be relative.
OTA_URL="${OTA_URL:-https://cydia.rousseaddict.online/OTA}"
OTA_URL="${OTA_URL%/}"

mkdir -p "$OUT" "$SRC"

xesc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# Extract the iOS major version from an ipa filename (default 6 if untagged).
ios_of() {
  local n
  n="$(printf '%s' "$1" | grep -oiE 'ios[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
  printf '%s' "${n:-6}"
}

ROWS=()

while IFS='|' read -r repo package name section description; do
  case "${repo:-}" in ''|\#*) continue ;; esac
  repodir="$SRC/$repo"

  if [ -d "$repodir/.git" ]; then
    git -C "$repodir" fetch -q origin </dev/null
    git -C "$repodir" reset --hard -q origin/HEAD </dev/null
  else
    git clone -q "https://github.com/$OWNER/$repo.git" "$repodir" </dev/null
  fi

  sha="$(git -C "$repodir" rev-parse HEAD)"
  short_sha="${sha:0:7}"

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

  buttons=""
  for entry in "${sorted[@]}"; do
    n="${entry%%:*}"
    ipa="${entry#*:}"
    ipa_file="$(basename "$ipa")"
    ipa_url="https://raw.githubusercontent.com/$OWNER/$repo/$sha/build/$ipa_file"

    # Read the real bundle id / version out of the app's Info.plist. plistlib
    # handles the binary plist format that Xcode emits.
    payload="$(mktemp -d)"
    unzip -qq "$ipa" -d "$payload"
    appdir="$(ls -d "$payload"/Payload/*.app 2>/dev/null | head -n1 || true)"
    if [ -z "$appdir" ]; then
      echo "WARN: no .app inside $ipa, skipping" >&2
      rm -rf "$payload"; continue
    fi
    meta="$(python3 - "$appdir/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as fh:
    p = plistlib.load(fh)
print(p.get('CFBundleIdentifier', ''))
print(p.get('CFBundleShortVersionString') or p.get('CFBundleVersion') or '1.0')
PY
)"
    bundle_id="$(printf '%s' "$meta" | sed -n 1p)"
    bundle_ver="$(printf '%s' "$meta" | sed -n 2p)"
    rm -rf "$payload"

    if [ -z "$bundle_id" ]; then
      echo "WARN: no CFBundleIdentifier in $ipa, skipping" >&2
      continue
    fi

    plist_name="${package}-ios${n}.plist"
    cat > "$OUT/$plist_name" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key><string>software-package</string>
          <key>url</key><string>$(xesc "$ipa_url")</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key><string>$(xesc "$bundle_id")</string>
        <key>bundle-version</key><string>$(xesc "$bundle_ver")</string>
        <key>kind</key><string>software</string>
        <key>title</key><string>$(xesc "$name")</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
EOF

    install_url="itms-services://?action=download-manifest&url=$OTA_URL/$plist_name"
    buttons="${buttons}<a class=\"btn\" href=\"$(xesc "$install_url")\">iOS ${n}+</a>"
  done

  [ -n "$buttons" ] || continue

  repo_url="https://github.com/$OWNER/$repo"
  ROWS+=("<li><div class=\"info\"><span class=\"name\"><a href=\"$repo_url\">$(xesc "$name")</a></span><span class=\"desc\">$(xesc "$description")</span><code><a href=\"$repo_url/commit/$sha\">$short_sha</a></code></div><div class=\"btns\">$buttons</div></li>")
done < apps.conf

{
  cat <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="../ginger.png">
<style>
  :root{color-scheme:light dark}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       max-width:40rem;margin:2rem auto;padding:0 1.25rem;line-height:1.5}
  h1{margin-bottom:.25rem}
  .sub{color:#888;margin-top:0}
  .note{background:#fff8e1;border-radius:.5rem;padding:.75rem 1rem;font-size:.85rem;margin:1.5rem 0}
  ul{list-style:none;padding:0}
  li{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;
     gap:.75rem;padding:1rem 0;border-top:1px solid #e5e5e5}
  .info{display:flex;flex-direction:column;min-width:12rem}
  .name{font-weight:600}
  .name a{color:inherit;text-decoration:none}
  .desc{font-size:.8rem;color:#888}
  code{color:#888;font-size:.75em}
  code a{color:inherit;text-decoration:none;border-bottom:1px dotted #aaa}
  .btns{display:flex;gap:.4rem;flex-wrap:wrap}
  .btn{display:inline-block;background:#1a56db;color:#fff;text-decoration:none;
       font-size:.8rem;font-weight:600;border-radius:1rem;padding:.4rem .9rem}
  .btn:active{opacity:.7}
  @media(prefers-color-scheme:dark){
    li{border-color:#2c2c2e} .note{background:#2c2515}
  }
</style>
HTML
  echo "<title>${OWNER} OTA Install</title></head><body>"
  echo "<h1>${OWNER} OTA Install</h1>"
  echo "<p class=\"sub\">Tap the button matching your iOS version. Open this page in Safari on the device.</p>"
  echo "<div class=\"note\">Requires a jailbroken device with AppSync Unified (the apps are ad-hoc signed). On iOS 6/7 you must also install the <strong>ISRG Root X1</strong> CA profile first, otherwise iOS cannot validate this site's certificate and the install will fail to start.</div>"
  echo "<ul>"
  for row in "${ROWS[@]}"; do echo "$row"; done
  echo "</ul>"
  echo "<p class=\"sub\"><a href=\"../\">&larr; Cydia repo</a></p>"
  echo "</body></html>"
} > "$OUT/index.html"

echo "OTA page built into '$OUT' ($(date -u +%FT%TZ))"
