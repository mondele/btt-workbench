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
- Checklist options (`ChecklistOptionDef`, kind `okChecklist`) are lists
  the module finds itself: override `TWBModule.Choices` (the other options
  are the filters). The GUI shows a check-box list with Find / Select all /
  None, the CLI prints `btw <module> --list [filters]` and takes `--all`
  (stored as `AllChoices`, `*`), libbtw has `btw_choices`. Read the values
  with `ChecklistValues`, which expands `*`. Nothing is pre-checked.
- Password options (`PasswordOptionDef`, `okPassword`) are masked in the
  GUI, never forwarded to another window, and asked for without echo by
  the CLI when their `PromptWith` option is given.
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
- `index.sqlite` is read with `WBSqlite`, a small pure-Pascal read-only
  reader (whole tables, rowid order), so nothing needs a sqlite3 library
  on Windows or Android. It was checked table-for-table against the
  `sqlite3` tool on real BTT-Writer databases; `tests/fixtures/langs.sqlite`
  covers interior pages, overflow, rowid aliases and added columns.
  `WBLanguages` loads the language tables from it. Desktop copies the
  database into `<data>/library/` once and updates it from the catalog,
  but never refreshes a project's `target_language` name or direction.
- Sources are downloaded from WACS, not Door43.
- Network: `WBHttp` (fphttpclient + opensslsockets, own User-Agent,
  readable errors), `WBGitea` (WACS REST, `/api/v1`, search paged at 50),
  `WBBielCatalog` (BIEL Public Data API, Hasura GraphQL, Primary/Active
  state; ILIKE patterns passed as variables so `_` is escaped once),
  `WBWacs` (saved login in `[wacs]`; git gets the token through
  `GIT_CONFIG_*` env via `RunGitAs`, never argv or `.git/config`).
  Tests use `tests/FakeWacs.pas`, a local fphttpserver fake with
  `file://` clone URLs; never test against the real WACS with writes.
- FPC 3.2.2's `openssl` unit only looks for OpenSSL up to 1.1 on Unix;
  `WBHttp`'s initialization adds `.3` to `DLLVersions` so HTTPS works on
  current Linux.
- On Windows `WBHttp` sends requests through WinHTTP (`WBWinHttp`, own
  declarations: FPC 3.2.2's `winhttp` unit misnames WinHttpSetTimeouts), so
  Windows builds need no OpenSSL DLLs; TLS, certificates and proxies come
  from Windows. Tests run on Linux and never reach that code: check it on
  Windows after changing it.
- Windows cross build on the laptop: `lazbuild --os=win64 --cpu=x86_64
  --ws=win32 <project>.lpi` (win64 units installed in fpcupdeluxe).
- `WBImport` is shared by tstudio-import and wacs-download:
  `TImportContext.FromServer` switches the wording, `OnConflict = 'skip'`
  leaves a project alone when a merge would conflict. Initialise contexts
  with `Default(TImportContext)`.
- BTT-Writer only uses git branch `master` (`gitnative.js`: `git init -b
  master`, pull and push `master` by name). `projects` moves `main` to
  `master` while scanning.
- `WBUsfmChecks` ports usfm-tools' `verifyUSFM.py` (WA code, open licence;
  credit Larry Versaw) from upstream Bible-Translation-Tools/usfm-tools
  (not the stale mondele fork). Keep verifyUSFM's check numbers, regexes
  and order of decisions; it tokenises like `usfmReader.py` and runs the
  whole-book, block and token passes in verifyUSFM's order. Helpers:
  `WBSentences` (sentences.py), `WBSectionTitles` (section_titles.py),
  `WBPyText` (Python str semantics, `isCaseless`), `WBUnicodeNames`
  (generated from Python's unicodedata), `WBVersification` (generated
  from usfm_verses.py), `wbusfmchecks_enulb.inc` (footnotes.py list).
- Regexes use `WBRegExpr`, an altered copy of FPC's regexpr (marked as
  such, as its licence requires) whose `\w` excludes combining marks and
  whose `\s`/`\d` are Unicode, like Python's; do not switch back to
  `uregexpr`. Units with curly quotes in patterns need `{$codepage utf8}`.
  Real constants compared for equality must be Doubles (FPC evaluates
  untyped ones in extended precision; see `D()` in WBSectionTitles).
  `TRegExpr.ExecPos` searches the last `InputString`: set it first.
- Hot paths replace some regexes with direct scans or cheap pre-checks
  that give the same matches (they are commented); the fixtures prove it.
  Fixtures are regenerated from the upstream Python: `verifyusfm-*.tsv`,
  `section-titles.jsonl`, `usfm-tools-units.jsonl` (every input of the
  upstream tokenizer, Token, parseLine and verifyUSFM helper tests). When usfm-tools changes, regenerate and re-port.
- `cross-check` (`ModCrossCheck`, engine `WBCrossCheck`) compares the text
  projects of a language as runs of 4 words (`TokenizeWords`: markers out,
  case folded), over every committed version of every chunk
  (`WBChunkHistory`: one `git log --all -p -U1000000` per project, parsed
  by `ParseChunkLog`). The first time each run appears per book decides
  which book it came from. Reported: blocks (25+ words, or 8+ covering
  half the chunk), tails (6+ words ending both chunks, on a chunk that
  ended there 6+ hours earlier) and text glued onto the last word. Real
  parallels are dropped by comparing the English ULB (articles left out),
  unless the chunk's verse numbers don't fit its chapter. Thresholds were
  tuned on the Chimanika damage of October 2026 (all found) and the
  udm/sah backup (nothing reported); check both again when changing them.
- `cross-check` and `cross-repair` gather projects and history through
  `WBCrossScan` (`ListTextProjects`, `ScanLanguage`). `WBCrossRepair`
  plans per damaged chunk: the version that brought the copied text into
  that file (`HasCopiedText` with the finding's `Hash`/`Fragment`) gives
  the damaging commit; restore = the file at `<commit>^`, remove = the
  file did not exist there. Later commits to the file are fine only if
  they also brought copied text into the project; uncommitted changes
  hold it. Mixed = words added since the old version that no chunk of
  another book sharing 2+ word runs has (slack 2). On the Chimanika copy
  (2026-10-16) all 103 damaged chunks planned clean and repaired with
  cross-check then finding nothing; rehearse on a copy (`--target-dir`).
- A standalone FPC program using these units needs `cwstring` (lazbuild
  programs here do without), or string conversion is very slow or fails.
- Sources are downloaded from WACS, not Door43.
- Network: `WBHttp` (fphttpclient + opensslsockets, own User-Agent,
  readable errors), `WBGitea` (WACS REST, `/api/v1`, search paged at 50),
  `WBBielCatalog` (BIEL Public Data API, Hasura GraphQL, Primary/Active
  state; ILIKE patterns passed as variables so `_` is escaped once),
  `WBWacs` (saved login in `[wacs]`; git gets the token through
  `GIT_CONFIG_*` env via `RunGitAs`, never argv or `.git/config`).
  Tests use `tests/FakeWacs.pas`, a local fphttpserver fake with
  `file://` clone URLs; never test against the real WACS with writes.
- FPC 3.2.2's `openssl` unit only looks for OpenSSL up to 1.1 on Unix;
  `WBHttp`'s initialization adds `.3` to `DLLVersions` so HTTPS works on
  current Linux.
- `WBImport` is shared by tstudio-import and wacs-download:
  `TImportContext.FromServer` switches the wording, `OnConflict = 'skip'`
  leaves a project alone when a merge would conflict. Initialise contexts
  with `Default(TImportContext)`.
- BTT-Writer only uses git branch `master` (`gitnative.js`: `git init -b
  master`, pull and push `master` by name). `projects` moves `main` to
  `master` while scanning.
- `WBUsfmChecks` ports usfm-tools' `verifyUSFM.py` checks (WA code, open
  licence; credit Larry Versaw). Keep verifyUSFM's check numbers and
  regexes. It uses `uregexpr` on UnicodeString with `{$codepage utf8}`
  (without it the curly quotes in the patterns become bytes), and maps
  Unicode spaces to ' ' first, because uregexpr's `\s` does not match
  them. `tests/fixtures/verifyusfm-samples.tsv` holds texts with what
  verifyUSFM itself reports; regenerate the expected column from the
  Python when adding samples. `WBVersification` is generated from
  `usfm_verses.py`. `WBSectionTitles` ports `section_titles.py`;
  `tests/fixtures/section-titles.jsonl` holds the Python's answers for
  every input of usfm-tools' `test_section_titles.py`. `WBPyText` has the
  Python string semantics (islower/isupper/istitle/split) they rely on.
  TRegExpr's `ExecPos` searches the last `InputString`: set it first.
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
