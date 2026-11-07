# macOS Ghostty Application

- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying Ghostty library.
- Use `macos/build.nu` to build the macOS app, do not use `zig build`
  (except to build the underlying library as mentioned above).
  - Build: `macos/build.nu [--scheme Ghostty] [--configuration Debug] [--action build]`
  - Output: `macos/build/<configuration>/Ghostty.app` (e.g. `macos/build/Debug/Ghostty.app`)
- Run unit tests directly with `macos/build.nu --action test`

## AppleScript

- The AppleScript scripting definition is in `macos/Ghostty.sdef`.
- Guard AppleScript entry points and object accessors with the
  `macos-applescript` configuration (use `NSApp.isAppleScriptEnabled`
  and `NSApp.validateScript(command:)` where applicable).
- In `macos/Ghostty.sdef`, keep top-level definitions in this order:
  1. Classes
  2. Records
  3. Enums
  4. Commands
- Test AppleScript support:
  (1) Build with `macos/build.nu`
  (2) Launch and activate the app via osascript using the absolute path
      to the built app bundle:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to activate'`
  (3) Wait a few seconds for the app to fully launch and open a terminal.
  (4) Run test scripts with `osascript`, always targeting the app by
      its absolute path (not by name) to avoid calling the wrong
      application.
  (5) When done, quit via:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to quit'`

## Local Install (fork)

- Install a release build with `macos/install-local.sh`. It builds
  GhosttyKit (ReleaseFast) and the app (ReleaseLocal), signs it with an
  Apple Development certificate, and replaces `/Applications/Ghostty.app`.
  - `--restart` quits and relaunches Ghostty afterwards (runs detached).
  - `--no-build` reinstalls the last build without rebuilding.
  - `GHOSTTY_SIGN_IDENTITY` overrides the signing certificate.
- Do not sign local installs ad-hoc: macOS keys privacy permissions to the
  signature, so ad-hoc builds lose them on every install.
- The install is swapped while Ghostty keeps running, so it is safe to run
  from inside Ghostty. Agents usually run inside the installed Ghostty: never
  run the script, pass `--restart`, or modify `/Applications/Ghostty.app`
  without the user's explicit request.
- The installed app shares the bundle id `com.mitchellh.ghostty` with
  upstream releases. For UI testing, use the Debug build instead.
