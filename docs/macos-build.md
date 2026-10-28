# macOS build

Plan for the first macOS build of BTT Workbench. Written on Linux on
2026-10-28; nothing here has been tried on a Mac yet. Update this file as
steps are done, and move what turns out to be permanent into `CLAUDE.md`.

The build has to be made on a Mac: FPC cannot link macOS programs from
Linux without Apple's SDK.

## What already works on macOS (in the code)

- BTT-Writer's data folder: `WBDataPaths` uses
  `~/Library/Application Support/BTT-Writer` under `{$IFDEF DARWIN}`.
- BTT-Writer installs: `/Applications/BTT-Writer.app` and
  `~/Applications/BTT-Writer.app`, including the bundled sources inside
  `Contents/Resources/app/src/…` (`FindBttWriterInstalls`).
- SQLite: `WBSqliteDb` loads `libsqlite3.dylib` (macOS ships it).
- Settings: `WBSettings` has a Darwin path.
- WACS client id: `WBGitea` reports `macos`.
- One window per user: `WBSingleWindow` falls back to the temp folder
  when `$XDG_RUNTIME_DIR` is not set (it never is on macOS).
- git: the Xcode Command Line Tools git (`/usr/bin/git`, Apple Git 2.39
  or later) meets the 2.38 minimum. A GUI app started from Finder gets a
  short PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so Homebrew's git is not
  seen there; `/usr/bin/git` is.

## Work to do

### 1. HTTPS (`WBHttp`): needed for everything that talks to WACS

On every system but Windows, `WBHttp` uses fphttpclient with OpenSSL
loaded at run time (`opensslsockets`). macOS has no usable OpenSSL: its
`/usr/lib/libssl.dylib` is LibreSSL, and loading it can abort the
program. Two ways out:

- **Native backend (preferred, same choice as Windows):** a `WBMacHttp`
  unit over Apple's NSURLSession (FPC `{$modeswitch objectivec1}` with
  `CocoaAll`, or CFNetwork), shaped like `WBWinHttp.WinHttpRequest`
  (method, URL, user agent, headers, body, timeout → status, body) and
  selected in `WBHttp` the way `{$IFDEF WINDOWS}` selects WinHTTP today.
  TLS, certificates and proxies then come from macOS, nothing extra ships,
  and the Cloudflare `post_handshake_auth` workaround (`TWBSSLHandler`) is
  not needed. `HttpKeepConnections` / `HttpReleaseConnection` can be
  no-ops or keep one session per thread; the library updates
  (`FetchAll`) download in parallel threads.
- **Bundle OpenSSL 3** in `Contents/Frameworks` and point `openssl`'s
  `DLLVersions`/load path at it. Quicker, reuses the Linux code, but the
  libraries must be updated and signed with each release.

Check with: `btw library-languages --dry-run` and `btw library-sources
--dry-run` (anonymous GETs to the catalog/CDN, parallel); `btw
wacs-download --language <code> --list` (BIEL Public Data API, a POST);
`btw wacs-account --username … ` then a download and an upload (token
auth; git gets the token through `GIT_CONFIG_*`, see `WBWacs`).

### 2. "Is BTT-Writer running?" (`WBProcesses`)

`BttWriterRunning` reads `/proc` in its non-Windows branch. macOS has no
`/proc`, so it would always answer "not running", and `library-languages`
/ `library-sources` could replace `index.sqlite` while BTT-Writer holds
it in memory (BTT-Writer would later write the old one back). Add a
`{$IFDEF DARWIN}` branch: `proc_listpids` + `proc_pidpath` from libproc
(`/usr/lib/libproc.dylib`, part of libSystem), matching `IsBttWriterName`
on the path. On macOS BTT-Writer's process is
`…/BTT-Writer.app/Contents/MacOS/BTT-Writer` (check the real name, and
that Electron helper processes are not counted twice or missed).
Keep `BttWriterRunningOverride` working; the tests use it.

### 3. Build script (`build.sh`)

Written for Linux and GNU tools; on macOS:

- `PATH` is set to `$LAZ_ROOT/fpc/bin/x86_64-linux:/usr/bin:/bin`: pick
  the FPC bin folder by `uname -s`/`uname -m` (on macOS, wherever the
  installed FPC puts `fpc`, e.g. `$LAZ_ROOT/fpc/bin/aarch64-darwin` with
  fpcupdeluxe, or `/usr/local/bin` with the official installer).
  `LAZ_ROOT` defaults to `~/fpcupdeluxe`.
- `versioned_lpi` uses `sed` with `\|` alternation, which BSD sed does
  not support: use `-E` with `|`, or separate `-e` expressions.
- macOS's `/bin/bash` is 3.2: `"${TEMP_LPIS[@]}"` on an empty array
  fails under `set -u`; avoid bash 4 features (`mapfile`, `${x,,}`).
- Widgetset: Cocoa is Lazarus's default on macOS (`LCL_WS` can stay unset).
- `src/lib/btw.lpi` (the `.so` for Android) is not needed on macOS; skip
  it there.
- Add `--macos` (or detect Darwin) to also make the app bundle (below).

### 4. App bundle, icon and version

- `BTT Workbench.app/Contents/{MacOS/btt-workbench, Info.plist,
  Resources/btt-workbench.icns}`. Lazarus's IDE makes bundles; with
  lazbuild, write the bundle by script. `Info.plist`: `CFBundleExecutable`,
  `CFBundleIdentifier` (e.g. `org.wycliffeassociates.btt-workbench`),
  `CFBundleName`, `CFBundleIconFile`, `CFBundleShortVersionString`
  (`<release>`, e.g. 0.2.0) and `CFBundleVersion` (`<release>+<build>`,
  from `lib/version.stamp`), `NSHighResolutionCapable`,
  `LSMinimumSystemVersion`.
- Icon: `.icns` from `btt-wb-icon.svg` (in the repo root on the desktop
  machine; the Windows `.ico` in `src/gui/BttWorkbench.ico` holds the same
  image at 16–256 px). On the Mac: make `btt-workbench.iconset/`
  (`icon_16x16.png`, `icon_16x16@2x.png`, … `icon_512x512@2x.png`) and
  run `iconutil -c icns`. A 1024 px PNG can be rendered from the SVG
  with `rsvg-convert` (Homebrew librsvg) or extracted from the `.ico`'s
  256 px image if nothing better is at hand.
- `btw` (the CLI) ships beside the app in the archive, or inside
  `Contents/MacOS/` with a note on how to put it on PATH.
- `tools/release.sh`: add a macOS stage →
  `dist/btt-workbench-<version>-macos-<arch>.zip` (or `.dmg`), with
  README, CHANGELOG, LICENSE and `locale/`. `sha256sum` does not exist on
  macOS: use `shasum -a 256`.

### 5. Architecture and signing

- Apple Silicon (`aarch64-darwin`) and/or Intel (`x86_64-darwin`); a
  universal binary is `lipo -create` of both.
- On Apple Silicon every program must be signed to run; Apple's linker
  signs ad hoc, which is enough on the build machine. After changing a
  bundle, re-sign: `codesign --force --deep -s - "BTT Workbench.app"`.
- For other people's Macs, an unsigned download is blocked by
  Gatekeeper: testers right-click → Open, or run
  `xattr -dr com.apple.quarantine "BTT Workbench.app"`. Opening normally
  needs a Developer ID certificate and notarization (paid Apple
  Developer account): undecided.

### 6. Tests and checks on the Mac

- `./build.sh` then `./bin/TestCore`; all checks must pass (459 on
  Linux at commit 3a9fa37). Tests use temp folders and `FakeWacs` (a
  local fphttpserver with `file://` clone URLs), never real WACS or real
  BTT-Writer data. Some may assume Linux (paths, `/proc`); fix the
  assumption, not the check.
- The GUI on Cocoa is untested: controls are built in code (no `.lfm`);
  watch layout and fonts, the pickers (`WBPicker` uses `QueueAsyncCall`
  because GTK put text and caret back; Cocoa may differ), RTL flipping,
  the background-thread Run/Check, and Save report.
- Open a `.tstudio` file with the app (the GUI starts on
  `tstudio-import` with a Check); on macOS that needs a document type in
  `Info.plist` and handling the open-file event (`Application.OnDropFiles`
  / `TApplicationProperties.OnDropFiles`), not argv.
- If BTT-Writer is installed on the Mac, try `btw projects` on its data,
  and BTT-Writer-running detection while it is open.

## Setting up the Mac

1. `xcode-select --install` (Apple's linker for FPC, and git).
2. FPC 3.2.2 and Lazarus: Lazarus 4.x is recommended on macOS (much
   better Cocoa support than the 3.6 used on Linux); fpcupdeluxe for
   macOS or the official installers.
3. `git clone https://github.com/mondele/btt-workbench.git`. To push,
   the Mac needs an SSH key on the mondele GitHub account; otherwise
   send patches (`git format-patch`).
4. Build, test, then work through the list above.

## Rules that still apply

`CLAUDE.md` holds for macOS work too. In particular: `src/core` and
`src/modules` use no LCL; every user-visible string is a
`resourcestring` (run `tools/extract-pot.sh` and commit the `.pot`);
Linux and Windows behaviour must not change (they are built and tested
on the Linux machines, so say what needs a Linux run); keep `CHANGELOG.md`
"Unreleased" current.
