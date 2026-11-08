#!/bin/bash
# Build a release Ghostty from this checkout and install it to /Applications.
#
# The app is signed with a stable Apple Development certificate instead of
# ad-hoc, so macOS privacy permissions (TCC) survive reinstalls. Ad-hoc
# signatures are identified by the binary's hash, which changes every build.
#
# The installed app is swapped while Ghostty keeps running (the running copy
# keeps its open files), so this is safe to run from inside Ghostty. Restart
# Ghostty whenever convenient to pick up the new build, or pass --restart.
#
# Usage: macos/install-local.sh [--no-build] [--restart]
#   --no-build   install the last build without rebuilding
#   --restart    after installing, quit Ghostty and relaunch the new build
#                (runs detached, so it survives Ghostty quitting)
#
# Environment:
#   GHOSTTY_SIGN_IDENTITY  codesigning identity (SHA-1 or name); see
#                          `security find-identity -v -p codesigning`
#   GHOSTTY_INSTALL_PATH   install location (default /Applications/Ghostty.app)

set -euo pipefail

SIGN_IDENTITY="${GHOSTTY_SIGN_IDENTITY:-5CF3D6EC685720BBC7EDEFAFC72E5AB3B223695C}"
INSTALL_PATH="${GHOSTTY_INSTALL_PATH:-/Applications/Ghostty.app}"

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$MACOS_DIR")"
BUILD_APP="$MACOS_DIR/build/ReleaseLocal/Ghostty.app"

build=1
restart=0
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    --restart) restart=1 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# The install path gets renamed and its previous contents deleted, so only
# accept a path that is (or will be) a Ghostty app bundle.
INSTALL_PATH="${INSTALL_PATH%/}"
[[ "$INSTALL_PATH" == /* ]] || die "install path must be absolute: $INSTALL_PATH"
[[ "$INSTALL_PATH" == *.app ]] || die "install path must be an .app bundle: $INSTALL_PATH"
[[ -d "$(dirname "$INSTALL_PATH")" ]] || die "install directory does not exist: $(dirname "$INSTALL_PATH")"
if [[ -L "$INSTALL_PATH" ]]; then
  die "install path is a symlink; refusing to replace it: $INSTALL_PATH"
elif [[ -e "$INSTALL_PATH" ]]; then
  [[ -d "$INSTALL_PATH" ]] || die "install path is not an app bundle: $INSTALL_PATH"
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_id" == com.mitchellh.ghostty ]] ||
    die "install path is not a Ghostty app (bundle id: ${existing_id:-none}): $INSTALL_PATH"
fi

if [[ $build -eq 1 ]]; then
  # The identity's team ID is the parenthesized suffix of its name.
  identity_line="$(security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" | head -1 || true)"
  if [[ -z "$identity_line" ]]; then
    echo "codesigning identity not found: $SIGN_IDENTITY" >&2
    security find-identity -v -p codesigning >&2
    exit 1
  fi
  team_id="$(sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/' <<<"$identity_line")"
  identity_sha="$(awk '{print $2}' <<<"$identity_line")"

  step "Building GhosttyKit (ReleaseFast)"
  (cd "$REPO_DIR" && zig build -Doptimize=ReleaseFast -Demit-macos-app=false)

  step "Building Ghostty.app (ReleaseLocal, signed for team $team_id)"
  # Clean environment, same as build.nu, to avoid Nix/shell interference.
  env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    xcodebuild \
      -project "$MACOS_DIR/Ghostty.xcodeproj" \
      -scheme Ghostty \
      -configuration ReleaseLocal \
      SYMROOT="$MACOS_DIR/build" \
      ENABLE_CODE_COVERAGE=NO \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="$identity_sha" \
      DEVELOPMENT_TEAM="$team_id" \
      PROVISIONING_PROFILE_SPECIFIER= \
      -quiet \
      build
fi

[[ -d "$BUILD_APP" ]] || { echo "no build found at $BUILD_APP" >&2; exit 1; }

step "Verifying signature"
codesign --verify --deep --strict "$BUILD_APP"
requirement="$(codesign -d -r- "$BUILD_APP" 2>&1 | grep '^designated')"
echo "$requirement"
if grep -q cdhash <<<"$requirement"; then
  echo "error: app is ad-hoc signed; permissions would reset on every install" >&2
  exit 1
fi

step "Installing to $INSTALL_PATH"
staging="$(dirname "$INSTALL_PATH")/.Ghostty.app.new.$$"
old="$(dirname "$INSTALL_PATH")/.Ghostty.app.old.$$"
# On any failure or interruption, put the previous app back if the new one
# never made it into place, then drop the staged copy.
cleanup() {
  if [[ -e "$old" && ! -e "$INSTALL_PATH" ]]; then
    if mv "$old" "$INSTALL_PATH"; then
      echo "restored previous app at $INSTALL_PATH" >&2
    else
      echo "error: could not restore previous app; it is at $old" >&2
    fi
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
ditto "$BUILD_APP" "$staging"
if [[ -e "$INSTALL_PATH" ]]; then
  mv "$INSTALL_PATH" "$old"
fi
mv "$staging" "$INSTALL_PATH" || die "could not move new app into place"
rm -rf "$old"
# Let LaunchServices pick up the new bundle (icon, URL handlers, etc).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_PATH" || true
echo "installed build of $(git -C "$REPO_DIR" log -1 --format='%h %s' 2>/dev/null || echo 'unknown commit')"

if [[ $restart -eq 1 ]]; then
  step "Restarting Ghostty (detached)"
  log="${TMPDIR:-/tmp}/ghostty-install-restart.log"
  # setsid detaches from this terminal's session so quitting Ghostty doesn't
  # SIGHUP the helper before it relaunches the app.
  /usr/bin/perl -MPOSIX=setsid -e 'setsid(); exec @ARGV' /bin/bash -c '
    app="$1"
    osascript -e "tell application \"$app\" to quit" || exit 1
    # Wait (up to 10 min, e.g. for a quit confirmation) for it to exit.
    for _ in $(seq 1 1200); do
      pgrep -f "^$app/Contents/MacOS/" >/dev/null || break
      sleep 0.5
    done
    pgrep -f "^$app/Contents/MacOS/" >/dev/null && exit 1
    open "$app"
  ' _ "$INSTALL_PATH" </dev/null >"$log" 2>&1 &
  echo "Ghostty will quit and relaunch (log: $log)"
else
  echo "Restart Ghostty to use the new build."
fi
