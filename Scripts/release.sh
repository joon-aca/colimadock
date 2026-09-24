#!/bin/bash
# Cuts a signed, notarized ColimaDock release and publishes it to GitHub Releases.
#   Scripts/release.sh 0.1.0      (normally via: make release VERSION=0.1.0)
#
# Refuses to run from anything but a clean, pushed-or-pushable master with a CHANGELOG entry.
# Safe to re-run: if the tag already points at HEAD but the GitHub release is missing, it resumes.
set -euo pipefail

APP_NAME="ColimaDock"
APP_BUNDLE="$APP_NAME.app"
DIST_DIR="dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-aca-notary}"

fail() { echo "✘ $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: make release VERSION=x.y.z (got '${VERSION}')"
TAG="v$VERSION"
ZIP="$DIST_DIR/$APP_NAME-$VERSION.zip"

step "Checking release preconditions"

[ "$(git rev-parse --abbrev-ref HEAD)" = "master" ] || fail "releases are cut from master"
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean; commit or stash first"

git fetch --quiet origin master --tags
git merge-base --is-ancestor origin/master HEAD || fail "master is behind origin/master; pull first"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [ "$(git rev-list -n1 "$TAG")" = "$(git rev-parse HEAD)" ] || fail "$TAG already exists on a different commit"
    gh release view "$TAG" >/dev/null 2>&1 && fail "$TAG is already released"
    echo "$TAG already points at HEAD without a GitHub release; resuming"
fi

NOTES=$(awk -v v="$VERSION" '
    $0 ~ "^## \\[?" v "\\]?( |$)" { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md)
[ -n "$(echo "$NOTES" | tr -d '[:space:]')" ] || fail "CHANGELOG.md has no '## $VERSION' section"

IDENTITIES=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p')
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "$IDENTITIES" | grep -qxF "$SIGN_IDENTITY" || fail "SIGN_IDENTITY '$SIGN_IDENTITY' is not a valid identity in the keychain"
else
    [ -n "$IDENTITIES" ] || fail "no 'Developer ID Application' identity in the keychain"
    [ "$(echo "$IDENTITIES" | wc -l | tr -d ' ')" = "1" ] || fail "several Developer ID identities; pick one with SIGN_IDENTITY=..."
    SIGN_IDENTITY="$IDENTITIES"
fi
echo "Signing as: $SIGN_IDENTITY"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fail "no notarytool credentials saved as '$NOTARY_PROFILE'. One-time setup (stores them in your keychain, not the repo):
    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>
  It prompts for an app-specific password from https://account.apple.com. Then re-run make release."
fi

gh auth status >/dev/null 2>&1 || fail "gh is not logged in; run: gh auth login"

step "Building universal $APP_BUNDLE $VERSION"
UNIVERSAL=1 VERSION="$VERSION" ./build-app.sh
[ "$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")" = "x86_64 arm64" ] || fail "binary is not universal"

step "Signing with hardened runtime"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

step "Notarizing"
rm -rf "$DIST_DIR" && mkdir -p "$DIST_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$DIST_DIR/notarization.log"
grep -q "status: Accepted" "$DIST_DIR/notarization.log" || fail "notarization was not accepted; see $DIST_DIR/notarization.log"

step "Stapling and packaging"
xcrun stapler staple "$APP_BUNDLE"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

step "Tagging and publishing $TAG"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "$APP_NAME $VERSION"
git push --atomic origin master "$TAG"
echo "$NOTES" | gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "$APP_NAME $VERSION" --notes-file -

echo
echo "✔ Released $TAG: $(gh release view "$TAG" --json url -q .url)"
