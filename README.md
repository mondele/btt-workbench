# BTT Workbench

A technician's toolbox for BTT-Writer projects. It is the successor to
[BTT-Manager](https://github.com/mondele/BTT-Manager), written in Free Pascal.

Each tool is a **module**, and every module runs three ways:

- **Command line:** `btw <module> [options]`, for scripts and remote support
- **Desktop GUI:** `btt-workbench`, built with Lazarus/LCL
- **Android:** a Kotlin UI calling the same code through `libbtw.so`
  (planned; see [android/](android/README.md))

The interface is translatable from the start. All text comes from gettext
`.po` files, and right-to-left languages mirror the whole layout.

## Modules

| Module    | What it does |
|-----------|--------------|
| `ulb2reg` | Converts a target translation from ULB to REG: updates `manifest.json` and renames `*_ulb` to `*_reg`. Refuses if the manifest isn't ULB or the `_reg` folder already exists. Has a `--dry-run` option. |
| `tstudio-import` | Imports a `.tstudio` package into BTT-Writer's `targetTranslations`. The check (`--dry-run`) reports whether each project is new, already up to date, or needs merging, and lists the chunks a merge would leave in conflict. If the project exists, `--on-existing` chooses `stop` (default), `merge` (as BTT-Writer does, with conflicts left for BTT-Writer to resolve) or `overwrite` (the old copy moves to `workbench-backups`). |

```sh
btw list
btw help ulb2reg
btw ulb2reg ~/.config/BTT-Writer/targetTranslations/en_mat_text_ulb --dry-run
btw --lang fr ulb2reg <project>
btw tstudio-import ~/Desktop/en_tit_text_reg.tstudio --dry-run
btw tstudio-import ~/Desktop/en_tit_text_reg.tstudio --on-existing merge
```

In the GUI, a module with a check gets a **Check** button next to **Run**.

### Double-click `.tstudio` files (Linux)

```sh
tools/install-desktop.sh           # register .tstudio -> btt-workbench (per user, no sudo)
tools/install-desktop.sh --remove  # undo
```

Double-clicking a package then opens BTT Workbench on the import module and
runs the check. Nothing changes until you choose what to do and press **Run**.

Exit codes: `0` means success, `1` means the module failed, and `2` means a usage error.

## Building

You need Free Pascal 3.2.2+ and Lazarus 3.6+ (`lazbuild`). The script
assumes an fpcupdeluxe install at `~/fpcupdeluxe`. Set `LAZ_ROOT` or
`LAZBUILD` if yours is somewhere else.

You also need git (2.38 or newer), which BTT-Writer needs anyway.

```sh
./build.sh                  # tests, CLI, libbtw.so, GUI; then runs the tests
LCL_WS=qt6 ./build.sh       # GUI on Qt6 instead of the default GTK2
./build.sh src/cli/btw.lpi  # one project
```

The binaries go in `bin/`.

## Translating

```sh
./build.sh && tools/extract-pot.sh        # refresh locale/btt-workbench.pot
mkdir -p locale/fr
msginit -i locale/btt-workbench.pot -o locale/fr/btt-workbench.po -l fr
```

The GUI lists every language that has a `.po` file. On the command line, use `--lang <code>`.
Both default to the system language.

## Layout

```
src/core/     module contract, reporter, i18n, CLI parsing, JSON (no LCL)
src/modules/  one unit per module; WBAllModules.pas lists them
src/cli/      btw command-line front end
src/gui/      LCL desktop front end
src/lib/      libbtw shared library (C ABI, JSON) for Android
tests/        headless tests (TestCore)
locale/       btt-workbench.pot and <lang>/btt-workbench.po
android/      Kotlin UI (planned)
```

## License

MIT
