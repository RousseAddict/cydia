# RousseAddict Cydia Repo

A flat Cydia/APT repository for legacy iOS (6+), built by GitHub Actions and
served on GitHub Pages: <https://rousseaddict.github.io/cydia/>

## Add an app

Edit `apps.conf` — one line per app, pipe-separated:

```
repo|package|name|section|description
```

- `repo` — GitHub repo name under `RousseAddict` containing `build/*.ipa`
- `package` — reverse-DNS id (e.g. `rousseaddict.oldpipe`)
- `name` — display name in Cydia
- `section` — Cydia category
- `description` — short description

Push to `main`; the workflow rebuilds and redeploys. Apps with multiple
per-iOS builds (e.g. `oldpipe_ios6.ipa`, `oldpipe_ios8.ipa`) are packaged
under one id with `firmware` version bounds so each device installs the
matching build.

## Build

- **CI:** `.github/workflows/build-pages.yml` runs on push, manual dispatch,
  and hourly (to pick up new ipas). Output is deployed to Pages.
- **Local:** `./build.sh public` produces the repo tree in `public/`
  (needs `dpkg-dev`, `bzip2`, `unzip`, `git`).

Version per package is `1.0+<commit-count>-ios<N>`, so a new commit to a
source app repo makes Cydia offer an upgrade.

## Add the repo in Cydia

> Note: GitHub Pages is HTTPS-only with a modern cert, which iOS 6 cannot
> validate. Use an HTTP relay/mirror in front of this Pages URL for on-device
> use; the Pages deployment is the build origin.

Sources → Edit → Add:

```
deb https://rousseaddict.github.io/cydia/ ./
```
