# macOS build

Plan for the first macOS build of BTT Workbench. Written on Linux on
2026-10-28; work on the Mac (Apple Silicon, macOS 15, fpcupdeluxe with
FPC 3.2.2 and Lazarus 4.6) began the same day. Update this file as steps
are done, and move what turns out to be permanent into `CLAUDE.md`.

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

## Decisions (2026-10-28)

- HTTPS: native backend (NSURLSession), not bundled OpenSSL.
- Architecture: universal binary (Apple Silicon + Intel).
- Signing: ad hoc for now. The user has a free Apple Developer account,
  which cannot make Developer ID certificates or notarize (see 5).

## Work to do

### 1. HTTPS (`WBHttp`): needed for everything that talks to WACS

On every system but Windows, `WBHttp` uses fphttpclient with OpenSSL
loaded at run time (`opensslsockets`). macOS has no usable OpenSSL: its
`/usr/lib/libssl.dylib` is LibreSSL, and loading it can abort the
program. Two ways out:

- **Native backend (chosen, same choice as Windows):** a `WBMacHttp`
  unit over Apple's NSURLSession (FPC `{$modeswitch objectivec1}` with
  `CocoaAll`, or CFNetwork), shaped like `WBWinHttp.WinHttpRequest`
  (method, URL, user agent, headers, body, timeout → status, body) and
  selected in `WBHttp` the way `{$IFDEF WINDOWS}` selects WinHTTP today.
  TLS, certificates and proxies then come from macOS, nothing extra ships,
  and the Cloudflare `post_handshake_auth` workaround (`TWBSSLHandler`) is
  not needed. `HttpKeepConnections` / `HttpReleaseConnection` can be
  no-ops or keep one session per thread; the library updates
  (`FetchAll`) download in parallel threads.
- *(Not chosen)* **Bundle OpenSSL 3** in `Contents/Frameworks` and point `openssl`'s
  `DLLVersions`/load path at it. Quicker, reuses the Linux code, but the
  libraries must be updated and signed with each release.

Check with: `btw library-languages --dry-run` and `btw library-sources
--dry-run` (anonymous GETs to the catalog/CDN, parallel); `btw
wacs-download --language <code> --list` (BIEL Public Data API, a POST);
`btw wacs-account --username … ` then a download and an upload (token
auth; git gets the token through `GIT_CONFIG_*`, see `WBWacs`).

### 2. "Is BTT-Writer running?" (`WBProcesses`): done (2026-10-29)

macOS has no `/proc`, so the non-Windows branch always answered "not
running" there, and `library-languages` / `library-sources` could have
replaced `index.sqlite` under a running BTT-Writer. A `{$ELSEIF
DEFINED(DARWIN)}` branch lists processes with `proc_listpids` and names
them with `proc_pidpath` (libproc, in libSystem: `external 'c'`). On macOS
BTT-Writer's main process is `…/BTT-Writer.app/Contents/MacOS/BTT-Writer`;
the Electron helpers (`BTT-Writer Helper (Renderer)` etc., in
`Contents/Frameworks`) do not match `IsBttWriterName`, so it counts once.
Checked on arm64 and x86_64 with a stand-in process named `BTT-Writer`
(found) and one named like a helper (not found). Still to check with the
real BTT-Writer open.

### 3. Build script (`build.sh`): done (2026-10-28)

`build.sh` runs under macOS's `/bin/bash` 3.2 and BSD sed:

- `PATH` uses the FPC bin folder for the host, `$LAZ_ROOT/fpc/bin/<cpu>-<os>`
  from `uname` (`x86_64-linux`, `aarch64-darwin`).
- Empty arrays are expanded as `${a[@]+"${a[@]}"}` (bash 3.2 calls them
  unset under `set -u`), and `versioned_lpi` uses separate `sed -e`
  expressions instead of `\|`.
- On macOS the default projects are TestCore, the CLI and the GUI (no
  `src/lib`), with the Cocoa widgetset (Lazarus's default).
- `./build.sh --universal [<x.lpi>...]` builds each project with
  `--cpu=aarch64` and `--cpu=x86_64`, keeps the slices in
  `lib/<cpu>-darwin/`, joins them with `lipo` into `bin/`, and runs
  TestCore under `arch -arm64` and `arch -x86_64` (Rosetta).
- `MACOSX_DEPLOYMENT_TARGET` defaults to 11.0. fpcupdeluxe's `fpc.cfg`
  gives native (arm64) builds `-WM10.15`, which beats the variable, so the
  arm64 slice says 10.15 and the x86_64 slice 11.0. That is harmless:
  Apple Silicon Macs all run 11 or later. Do not force `-WM11.0` on arm64:
  Apple's ld 1167.5 (Command Line Tools, 2025) crashes with a segfault
  linking the GUI with it (the CLI links). `-ld_classic` avoids the crash
  but Apple is removing it.

Still to do here: make the app bundle (step 4), probably as
`--universal`'s last stage or a separate `--bundle`.

### 4. App bundle, icon and version

- `BTT Workbench.app/Contents/{MacOS/btt-workbench, Info.plist,
  Resources/btt-workbench.icns}`. Lazarus's IDE makes bundles; with
  lazbuild, write the bundle by script. `Info.plist`: `CFBundleExecutable`,
  `CFBundleIdentifier` (e.g. `org.wycliffeassociates.btt-workbench`),
  `CFBundleName`, `CFBundleIconFile`, `CFBundleShortVersionString`
  (`<release>`, e.g. 0.2.0) and `CFBundleVersion` (`<release>+<build>`,
  from `lib/version.stamp`), `NSHighResolutionCapable`,
  `LSMinimumSystemVersion`.
- Icon: `.icns` from `btt-wb-icon.svg` (repo root; the Windows `.ico`s
  were rendered from it). On the Mac: render PNGs from the SVG
  (`rsvg-convert` from Homebrew librsvg, or `qlmanage -t -s 1024 -o .`
  then `sips -z`), make `btt-workbench.iconset/` (`icon_16x16.png`,
  `icon_16x16@2x.png`, … `icon_512x512@2x.png`) and run `iconutil -c
  icns`. Commit the `.icns` (or a script that makes it) so later builds
  need no converter.
- `btw` (the CLI) ships beside the app in the archive, or inside
  `Contents/MacOS/` with a note on how to put it on PATH.
- `tools/release.sh`: add a macOS stage →
  `dist/btt-workbench-<version>-macos-<arch>.zip` (or `.dmg`), with
  README, CHANGELOG, LICENSE and `locale/`. `sha256sum` does not exist on
  macOS: use `shasum -a 256`.

### 5. Architecture and signing

- Universal: build twice, `lazbuild --cpu=aarch64` and `--cpu=x86_64`
  (`--os=darwin`), into separate output folders, then `lipo -create -output
  <exe> <arm64 exe> <x86_64 exe>` for `btt-workbench` and `btw`. Check with
  `lipo -info` and run the tests natively plus under Rosetta (`arch -x86_64
  ./bin/TestCore`, needs `softwareupdate --install-rosetta`). The official
  FPC 3.2.2 macOS installer (`fpc-3.2.2.intelarm64-macosx.dmg`) has both
  compilers; with fpcupdeluxe, add the other CPU as a cross-compiler. The
  LCL and packages get compiled once per CPU. `LSMinimumSystemVersion`:
  11.0 covers every Apple Silicon Mac; pass the same `-WM` (deployment
  target) to both builds.
- On Apple Silicon every program must be signed to run; Apple's linker
  signs ad hoc, which is enough on the build machine. After changing a
  bundle, re-sign: `codesign --force --deep -s - "BTT Workbench.app"`.
- For other people's Macs, a download that is not notarized is blocked
  by Gatekeeper. On macOS 15 (Sequoia) and later, right-click → Open no
  longer gets past it: testers open the app once, then System Settings →
  Privacy & Security → "Open Anyway". Or, in Terminal:
  `xattr -dr com.apple.quarantine "/Applications/BTT Workbench.app"`.
  Put these steps in the archive's README.
- A free Apple Developer account does not help here: its "Apple
  Development" certificate (via Xcode) is for running on the developer's
  own registered devices, and Developer ID certificates and notarization
  need the paid Apple Developer Program (US$99/year, could be a WA
  organization account). With that: sign with the Developer ID
  Application certificate and hardened runtime (`codesign --options
  runtime --timestamp`), `xcrun notarytool submit … --wait`, then `xcrun
  stapler staple`. Leave room for this in the release script; ad hoc
  until then.

### 6. Tests and checks on the Mac

First run (2026-10-28, arm64): 62 checks passed, then TestCore stopped.
Three causes, all fixed on 2026-10-29; now 463/463 pass on arm64 and
under Rosetta (`./build.sh --universal`):
- FPC 3.2.2's TUnZipper chmods files of entries made on OS X (which its
  TZipper writes on macOS) to 000: `TPackageUnZipper` in
  ModTStudioImport. Also hit Linux and Windows with such packages.
- FPC 3.2.2's regexpr reads `{m,n}` counts from the wrong offset on
  aarch64 (writes with `AlignToInt`, reads with `AlignToPtr`), so `a{3}`
  matched like `a{0,...}`: fixed in WBRegExpr, and the import tests moved
  from FPC's RegExpr to WBRegExpr. Also affected the Android library.
- `/var/folders` is a link to `/private/var/folders`; settings tests
  compared a resolved path with an unresolved one: TestCore now resolves
  its temp root (`ResolveLinks` is public in WBDataPaths).

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
   macOS or the official installers. With fpcupdeluxe, install into
   `~/fpcupdeluxe` (`build.sh`'s default `LAZ_ROOT`): the app suggests a
   folder beside itself, e.g. on the Desktop. Use `fpc/bin/aarch64-darwin/
   fpc.sh`, not `fpc`, when calling the compiler by hand: only `fpc.sh`
   passes fpcupdeluxe's `fpc.cfg`.
3. The x86_64 cross-compiler (for `--universal`), see below. Rosetta to
   run the x86_64 tests: `softwareupdate --install-rosetta
   --agree-to-license`.
4. Clone over SSH, the same way the Mac reaches `mondele/claude-config`
   (same host alias from `~/.ssh/config`), e.g. `git clone
   git@github-WA:mondele/btt-workbench.git`. If it was cloned over HTTPS,
   `git remote set-url origin` to the SSH form before pushing.
5. Build, test, then work through the list above.

### The x86_64 cross-compiler on Apple Silicon

fpcupdeluxe's Cross tab (x86_64 / darwin) fails with FPC 3.2.2 on an
Apple Silicon host. Built by hand from `~/fpcupdeluxe/fpcsrc` it works,
with three fixes. Redo them if fpcupdeluxe rebuilds FPC.

1. The cross-compiler must emulate x86's 80-bit `Extended` (an arm64 host
   has none), or it stops with `genmath.inc(919,7) Fatal: Internal error
   2014051001`: build it with `-dFPC_SOFT_FPUX80`.
2. That needs the unit `sfpux80` for the host, which the darwin RTL
   Makefile in 3.2.2 does not build (the Linux one does). Compile it into
   both host RTL folders:

   ```sh
   cd ~/fpcupdeluxe/fpcsrc
   PP=~/fpcupdeluxe/fpc/bin/aarch64-darwin/ppca64
   CFG=~/fpcupdeluxe/fpc/bin/aarch64-darwin/fpc.cfg
   for d in rtl/units/aarch64-darwin ~/fpcupdeluxe/fpc/units/aarch64-darwin/rtl; do
     $PP -n @$CFG -Fu$d -FU$d rtl/inc/sfpux80.pp
   done
   ```
3. Apple's assembler rejects the x86_64 `RawThunk` in
   `packages/rtl-objpas/src/inc/rtti.pp` (`non-private labels cannot
   appear between .cfi_startproc / .cfi_endproc pairs`, for the global
   `RawThunkEnd` label). Leave raw thunks out on x86_64-darwin: change
   the `{$elseif defined(cpux86_64)}` before the x86_64 `RawThunk` to
   `{$elseif defined(cpux86_64) and not defined(darwin)}`.
   `AllocateRawThunk` then returns nil, as on platforms without thunks;
   btt-workbench and the LCL do not use the `Rtti` unit. (The original
   is kept as `rtti.pp.orig`.)

Then build, and move the results to fpcupdeluxe's layout (`make
crossinstall` uses FPC's standard `lib/fpc/3.2.2/` one):

```sh
cd ~/fpcupdeluxe/fpcsrc
export PATH=~/fpcupdeluxe/fpc/bin/aarch64-darwin:/usr/bin:/bin:/usr/sbin:/sbin
make crossall crossinstall CPU_TARGET=x86_64 OS_TARGET=darwin \
  PP=~/fpcupdeluxe/fpc/bin/aarch64-darwin/ppca64 \
  INSTALL_PREFIX=~/fpcupdeluxe/fpc \
  OPT="-dFPC_SOFT_FPUX80 -XR/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -Fu$HOME/fpcupdeluxe/fpc/units/aarch64-darwin/rtl"
cd ~/fpcupdeluxe/fpc
cp lib/fpc/3.2.2/ppcrossx64 bin/aarch64-darwin/ppcx64
mv lib/fpc/3.2.2/units/x86_64-darwin units/
```

Check: `fpc.sh -Px86_64 -iTPTO` prints `x86_64 darwin`, and a program
built with `fpc.sh -Px86_64` runs under `arch -x86_64`. Lazarus compiles
the LCL for x86_64 the first time `build.sh --universal` runs. Note that
`SizeOf(Extended)` is 10 in the x86_64 slice and 8 in the arm64 one.

## Rules that still apply

`CLAUDE.md` holds for macOS work too. In particular: `src/core` and
`src/modules` use no LCL; every user-visible string is a
`resourcestring` (run `tools/extract-pot.sh` and commit the `.pot`);
Linux and Windows behaviour must not change (they are built and tested
on the Linux machines, so say what needs a Linux run); keep `CHANGELOG.md`
"Unreleased" current.
