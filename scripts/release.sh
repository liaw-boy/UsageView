#!/usr/bin/env bash
# One-command release: bump version, test, build + sign, verify signature, then (after confirmation)
# commit, tag, push and publish the GitHub Release with zip + .sig + dmg.
# The signing key never leaves this machine.
#
#   UPDATE_SIGNING_KEY=<path to private key> scripts/release.sh <version> <notes.md>
#   DRY_RUN=1 ... runs every local step, then restores bundle.sh and publishes nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

VERSION="${1:-}"
NOTES="${2:-}"
DRY_RUN="${DRY_RUN:-0}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3 (got '${VERSION}')"
[[ -n "$NOTES" && -f "$NOTES" && -s "$NOTES" ]] || die "release notes file is missing or empty: '${NOTES}'"
[[ -n "${UPDATE_SIGNING_KEY:-}" && -f "$UPDATE_SIGNING_KEY" ]] || die "set UPDATE_SIGNING_KEY to the private key file"
TAG="v${VERSION}"

command -v gh >/dev/null || die "gh CLI is required"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "release from the main branch"
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not in sync with origin/main"
! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || die "tag ${TAG} already exists"

CURRENT="$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\([0-9.]*\)<\/string>.*/\1/p' bundle.sh)"
[[ -n "$CURRENT" ]] || die "could not read the current version from bundle.sh"
[[ "$CURRENT" != "$VERSION" ]] || die "bundle.sh is already at ${VERSION}"
echo "==> ${CURRENT} -> ${VERSION}"

restore() { git checkout -- bundle.sh; }
if [[ "$DRY_RUN" == "1" ]]; then trap restore EXIT; fi

# Both places that carry the version (Info.plist string and the final echo).
sed -i '' \
  -e "s/<string>${CURRENT//./\\.}<\/string>/<string>${VERSION}<\/string>/" \
  -e "s/(UsageView v${CURRENT//./\\.})/(UsageView v${VERSION})/" \
  bundle.sh
[[ "$(grep -c "${VERSION//./\\.}" bundle.sh)" -eq 2 ]] || die "expected exactly two version strings in bundle.sh"

echo "==> swift test"
swift test

echo "==> signed build"
RELEASE=1 UPDATE_SIGNING_KEY="$UPDATE_SIGNING_KEY" ./bundle.sh

BUILT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' UsageView.app/Contents/Info.plist)"
[[ "$BUILT" == "$VERSION" ]] || die "built app reports ${BUILT}, expected ${VERSION}"

echo "==> verify signature with the embedded public key"
VERIFIER="$(mktemp -d)/verify_update"
swiftc -parse-as-library -o "$VERIFIER" scripts/verify_update.swift Sources/QuotaBarCore/Services/UpdateSecurity.swift
"$VERIFIER" UsageView.app.zip UsageView.app.zip.sig

if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> dry run finished: nothing committed, tagged or published (bundle.sh restored)"
  exit 0
fi

echo
cat "$NOTES"
echo
read -r -p "Publish ${TAG} with the notes above? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { restore; die "cancelled; bundle.sh restored"; }

git add bundle.sh
git commit -m "chore: release ${TAG}"
git push origin main
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" UsageView.app.zip UsageView.app.zip.sig UsageView.dmg --title "$TAG" --notes-file "$NOTES"
echo "==> published ${TAG}"
