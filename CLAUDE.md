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
  rather than guess, and support `--dry-run`.
- Write `manifest.json` with `WBJson.WriteBttJSONFile`. It keeps
  BTT-Writer's tab-indented layout so the project's git diff shows only
  real changes.
- Lazarus only loads `.po` entries that have a `#:` reference line.
  rstconv output always has them; hand-written test `.po` files need them.
- Don't name things `IsRightToLeft`: it clashes with `TControl.IsRightToLeft`.

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
