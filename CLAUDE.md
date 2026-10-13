# CLAUDE.md

Guidance for Claude Code in this repository.

## Project

BTT Workbench is a technician's toolbox for BTT-Writer projects. It
replaces BTT-Manager (`../BTT-Manager`, a single Python script). It is Free
Pascal / Lazarus, and follows the UI strategy of `../btt-writer-two`:
- an LCL desktop GUI
- a small separate Kotlin Android UI over a shared FPC-built `.so` with a
  flat C ABI (UTF-8 + JSON)

Don't re-litigate that choice.

Three requirements shape everything:
1. **Modular.** Each tool is a `TWBModule` (`src/core/WBModule.pas`).
2. **Every module runs headless and in a GUI.** Modules never touch the
   console or widgets. They declare `OptionDefs`, take name=value options,
   and report through `TWBReporter`. The CLI, GUI and libbtw are thin
   front ends over the same registry.
3. **i18n from day one.** Every user-visible string is a
   `resourcestring`, and translations are gettext `.po` files loaded by
   `WBI18n`. The GUI has no `.lfm`: controls are built in code, so there
   are no form-stream captions to extract. RTL languages flip the layout.

## Build and test

```bash
./build.sh                       # all four projects, then bin/TestCore
./build.sh tests/TestCore.lpi && ./bin/TestCore
BTW_KEEP_TEST=1 ./bin/TestCore   # keep the temp fixtures to inspect
tools/extract-pot.sh             # after adding/changing resourcestrings
```

`build.sh` defaults to `LAZ_ROOT=~/fpcupdeluxe`, which is the laptop
(Lazarus 3.6, FPC 3.2.2). On the desktop, Lazarus lives under
`~/Applications/Development/FPCUPdeluxe-2.4`, so set
`LAZ_ROOT=~/Applications/Development/FPCUPdeluxe-2.4`. The script resets
PATH because a linuxbrew `ld` breaks FPC links. The `crtbeginS.o not found`
linker warnings are harmless.

## Adding a module

1. `src/modules/Mod<Name>.pas`: subclass `TWBModule`, keep all strings in
   `resourcestring`, and call `RegisterModule(T<Name>Module.Create)` in
   `initialization`.
2. Add the unit to `src/modules/WBAllModules.pas`. That is the only
   registration point; the CLI, GUI, lib and tests all use it.
3. Add tests to `tests/TestCore.lpr`, using temp-dir fixtures. Never touch
   the real `~/.config/BTT-Writer` data.
4. Run `./build.sh && tools/extract-pot.sh` and commit the updated `.pot`.

## Rules

- `src/core` and `src/modules` must not use LCL units. They are compiled
  into the CLI and the `.so`.
- Module `Id` and option `Name` are stable API: CLI verbs, `--options` and
  JSON keys. Never translate or rename them casually.
- Exit codes: 0 means OK, 1 means the module failed, 2 means usage error.
- Modules that change BTT-Writer data must check before acting, refuse
  rather than guess, and support a `dry-run` flag. The GUI turns `dry-run`
  into a **Check** button, and runs it automatically when the GUI is started
  with `btt-workbench <module> [options]` (this is how double-clicked
  `.tstudio` files land on the import check).
- Choice options (`ChoiceOptionDef`) show as dropdowns. Their values are
  stable API, like option names.
- List options (`ListOptionDef`, `Multiple`) carry their values in one
  name=value entry, separated by line feeds. Read them with `OptionValues`
  and add with `AddOptionValue`. On the CLI they repeat, or take every
  remaining positional argument. In JSON they are arrays. In the GUI they are a
  memo, one value per line.
- The GUI keeps one window per user (`src/gui/WBSingleWindow.pas`,
  SimpleIPC pipe in `$XDG_RUNTIME_DIR`). A second `btt-workbench <module>
  ...` hands its options to the open window and exits.
- Default to BTT-Writer's data via `WBDataPaths`. `BTT_WRITER_DATA`
  overrides it, then the saved `settings --data-dir`. Modules that write
  should also take a `--target-dir` so tests never touch real data.
- Saved settings live in `WBSettings` (an ini file; `BTW_SETTINGS` names
  another). TestCore sets `SettingsFileOverride` first thing so tests never
  read or change the user's settings.
- Bundled sources: `BTW_BUNDLED_SOURCES`, then the saved `settings
  --btt-writer`, then `FindBttWriterInstalls` (usual folders, `btt-writer`
  on PATH, Linux desktop entries; symlinks resolved so `/lib` and
  `/usr/lib` count once).
- Compatibility target: **BTT-Writer Desktop 1.6.0**, installed at
  `/usr/lib/btt-writer/resources/app/src/`. That is newer than the
  `../BTT-Writer-Desktop` checkout and the `bttw-deb` package. Check
  behaviour there. Project manifests are `package_version` 8. Conflicts
  must be *committed* with `<<<<<<< HEAD` / `>>>>>>> <40-hex sha>` markers;
  `render.js` rejects anything else. To check that against the real
  parser, run it with `ELECTRON_RUN_AS_NODE=1 /usr/lib/btt-writer/BTT-Writer
  script.js`.
- Project helpers (`StrField`, `ProjectFolderName`, chunk ids) live in
  `WBProject`. Source chunking (chunks and their verses, from the library
  or bundled `.tsrc`) lives in `WBSources`. That unit follows Desktop's
  `getContainerData`: toc.yml order, only chunks that have a file, and a
  `<verse number="5-6">` tag counts as both verses. Tests set
  `WBDataPaths.BundledSourcesOverride` so they never depend on an installed
  BTT-Writer.
- Run git through `WBGit.RunGit`: no shell, `LC_ALL=C`, both pipes
  drained.
- Write `manifest.json` with `WBJson.WriteBttJSONFile`. It keeps
  BTT-Writer's tab-indented layout so the project's git diff shows only
  real changes.
- Lazarus only loads `.po` entries that have a `#:` reference line.
  rstconv output always has them; hand-written test `.po` files need them.
- Don't name things `IsRightToLeft`: it clashes with `TControl.IsRightToLeft`.
- `for S in ['a', 'bbb']` with string literals makes fixed-length
  shortstrings sized to the first literal and truncates the rest. Use a
  typed `array of string` const.
- `TProcess.ExitStatus` is the raw wait status (exit 1 reads as 256). Use
  `ExitCode`.
- `Out` is a reserved word; it can't be a parameter or variable name.
- `TIntegerArray` in the RTL is a fixed-size array type, so `Concat` and
  `nil` don't work on it. Declare a dynamic `array of Integer` type (as
  `WBSources.TVerseList` does).
- Prefix new unit names with `WB`. FPC's fcl-base has `singleinstance`,
  which `CustApp` (and so `Forms`) uses, and a project unit with the same
  name shadows it and breaks the build.

## Conventions (from btt-writer-two / chunkCounter)

- `{$mode objfpc}{$H+}`, PascalCase unit files, `T` class prefix
- Manual memory management with `FreeAndNil`; `Generics.Collections`
- Platform conditionals: `{$IFDEF WINDOWS}` / `{$IFDEF DARWIN}` / `{$IFDEF LINUX}`
- Avoid `{ }` inside brace comments (FPC nests them). Use `(* *)` when a
  comment needs to show JSON.

## Related code

- `../BTT-Manager/ulb2reg.py`: the original of `ModUlb2Reg`
- `../btt-writer-two/`: data model, LocaleManager pattern, UI strategy
- `../chunkCounter/`: resource container loading (TBook/TChapter/TChunk)
