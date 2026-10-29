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

## Installing

From a release (dist/ when building):

- **Linux (Debian, Ubuntu, Mint):** `sudo apt install ./btt-workbench_<version>_amd64.deb`.
  The programs go in `/opt/btt-workbench`, with `btt-workbench` and `btw`
  on the PATH, a menu entry, and `.tstudio` files opening on the import
  check. `sudo apt remove btt-workbench` takes it all away again.
- **Windows (10 and 11, 64-bit):** run `btt-workbench-<version>-win64-setup.exe`.
  It installs for all users in `Program Files\BTT Workbench` (needs an
  administrator) or just for you in `%LOCALAPPDATA%\Programs\BTT Workbench`
  (no administrator; the only choice when you aren't one). It adds a Start
  menu entry, a desktop shortcut and the `.tstudio` file type if you
  choose them, and an uninstaller in Apps & features. `btw.exe` is in the
  same folder; tick "Add btw to the PATH" to use it from any command
  prompt. Unattended: `setup.exe /S /AllUsers` or `/S /CurrentUser`.
- Without installing: unpack the `.tar.gz` or `.zip` and run the programs
  from that folder.

Either way, BTT Workbench needs git 2.38 or newer (on Windows, Git for
Windows, which the BTT-Writer installer sets up). The Windows installer
warns when it can't find it.

## Modules

| Module    | What it does |
|-----------|--------------|
| `ulb2reg` | Converts a target translation from ULB to REG: updates `manifest.json` and renames `*_ulb` to `*_reg`. Refuses if the manifest isn't ULB or the `_reg` folder already exists. Has a `--dry-run` option. |
| `tstudio-import` | Imports one or more `.tstudio` packages into BTT-Writer's `targetTranslations`. The check (`--dry-run`) reports whether each project is new, already up to date, or needs merging, and lists the chunks a merge would leave in conflict. Several packages (say, copies of one book from different tablets) are taken in the order given, and the check runs each one as if the earlier ones had been imported. If the project exists, `--on-existing` chooses `stop` (default), `merge` (as BTT-Writer does, with conflicts left for BTT-Writer to resolve) or `overwrite` (the old copy moves to `workbench-backups`). |
| `projects` | Lists the projects in `targetTranslations` with any problems: language names or text directions that lag BTT-Writer's language database (`index.sqlite`; also unknown codes and temporary codes since approved), unreadable manifests or fields of the wrong type, missing or damaged git history, misnamed folders, unresolved conflicts (and conflict markers BTT-Writer can't read), finished chunks with no file, and chunking and verse markers compared with each source the manifest lists and, always, en_ulb: one line per source saying which chunks are extra, which are missing (apart from those whose verses are in other chunks here) and which verse markers are outside its chunks, or that there are none, then which source the project matches. Differences from a listed source are problems; differences from en_ulb only when no source matches. Also codes that are not well-formed BCP 47 (which Scripture Burrito needs), and, at the end, a language's projects under several names or several codes. Filter with `--language` (a code, or a first part such as `mxc`), `--book` and `--type` (comma-separated codes); `--problems-only` hides clean projects; `--deep-git` also runs `git fsck` on each project (slower); `--language-db` compares with another `index.sqlite`. A project whose manifest can't be read is filtered by its folder name. Chunk files that no compared source has are listed with the commit that added each and how it begins; `--remove-extra-chunks` deletes them on Run (with their finished marks, in one commit after any loose work is committed), keeping any that hold verses no other chunk has. It makes these repairs, and `--dry-run` (Check) only reports them: a project on git branch `main` is moved to `master`, the only branch BTT-Writer uses (it refuses if both branches exist, and only reports other branches or a detached HEAD); and a `.git` folder that has lost `HEAD`, `config` or its index while its history is intact, as a copy can leave it, is rebuilt (`HEAD` on master, git's default config, the index from the last commit; the files are not touched, and nothing is kept unless `git fsck` then finds the history whole). |
| `library-languages` | Does what BTT-Writer's **Update Languages** does to its `index.sqlite` (target languages, temporary languages and their approved codes, the new-language questions), downloading the four catalogs at once: about 1.5 s. The rows are the ones BTT-Writer writes, row ids included. Reports what changed: languages added, removed and changed, and projects here whose language code the update removes. Replaces BTT-Writer's `index.sqlite` (or `--library-db`) only while BTT-Writer is not running, keeping the old one beside it as `index.sqlite.before-<date-time>`; `--output` writes elsewhere instead, `--dry-run` (Check) only reports. |
| `library-sources` | Does what BTT-Writer's **Update Sources** does (the source list: projects, source languages, resources, translationAcademy), downloading several catalogs at once (`--connections`, default 8): about 30 s where BTT-Writer 1.6.0 takes 3.5-5.5 minutes. Reports the source languages and resources (language/project/resource) added, removed and changed. Same options as `library-languages`, plus `--server`. The source texts themselves are not downloaded. |
| `language-change` | Gives the checked projects another language code, name or text direction, so that a language's projects agree (BTT-Writer copies these into each project when it is made and never updates them). Find by `--language` (a code or a first part), check the projects (`--project <folder>`... or `--all`), and give `--code` (empty: keep), `--name` and `--direction ltr\|rtl` (both default to the language database's entry for the code, else the project's own). Each project's manifest is changed and committed, uncommitted work first, and its folder renamed to match a new code; a project whose new folder exists is left alone. `--dry-run` reports what would change. WACS is not changed: a project with a new code uploads to a repo of its new name. |
| `settings` | Shows where BTT Workbench finds BTT-Writer's data folder and the source texts bundled with BTT-Writer (used to check chunking), and where each comes from. `--btt-writer <folder>` and `--data-dir <folder>` save locations for computers where they aren't found automatically; `--clear` forgets them. Installs are found in the usual folders, through the `btt-writer` command and (Linux) BTT-Writer's desktop entries. |
| `wacs-account` | Logs in to WACS (`--username`; the password is asked for and never saved) and keeps only a login token, named for this computer, in the settings file (owner-only). `--logout` forgets it (with `--password`, also deletes it on WACS). With no options, shows who is logged in and checks the token still works. |
| `wacs-download` | Finds BTT-Writer projects on WACS by `--language`, `--book`, `--type` (and `--owner`), shows each repo's state from the BIEL Public Data API (Primary, Active, Inactive; information only), whether the project is already here, and notes (consolidated, private, empty). Check the repos wanted (GUI: Find, then tick; CLI: `--list` to see them, then `--repo owner/name`... or `--all`). Downloads go through the same placing and merging as `tstudio-import`: `--on-existing stop\|merge\|overwrite`, and `--on-conflict skip\|commit` (skip leaves a project alone if a merge would conflict). `--dry-run` checks the whole list in order. Private repos need `wacs-account`. |
| `wacs-upload` | Uploads the checked local projects to WACS one after another, as BTT-Writer's Upload does: commits loose work, moves `main` to `master`, creates `<owner>/<project>` if missing, pushes `master`. The owner is you unless `--owner` names an organisation. When WACS has newer work, `--when-ahead skip` (default) leaves the project for later and `merge` brings the server's work in first (`--on-conflict skip\|commit` as for downloads). The server copy is compared in a scratch clone; `--dry-run` reports what each project needs. Needs `wacs-account`. |
| `text-check` | The translation text checks of usfm-tools' `verifyUSFM.py` (Larry Versaw; ported from Bible-Translation-Tools/usfm-tools of October 2026), run straight on the chunk files of text projects as one book: punctuation, quotes and brackets; numbers; capitals and sentence ends; footnote-like text; empty, short, all-ASCII and probably untranslated verses (compared with the project's source text); mixed-case words; possible section titles; marker problems; plus BTT-Writer verse checks (missing, repeated, out of order). Each finding gives verifyUSFM's check number in brackets. Filters as in `projects`; `--skip structure,markers,punctuation,quotes,numbers,ascii,caps,source,words,headings,footnotes,brackets` leaves groups out. Changes nothing. |
| `cross-check` | Finds text copied from one book into another within a language: chunks pasted over, blocks of verses, and the end of another book's chunk stuck onto a chunk (also when it runs onto the last word without a space). Every earlier version of each chunk in the projects' git history is compared too, so it says which book had the text first, even when that chunk has since changed, and which commit brought it in (author, date, and how many other files that commit changed, since reverting a whole commit can lose real work). Phrases that come back in a language and real parallels (Kings and Chronicles, the gospels, greetings) are left out: short shared phrases only count at the end of a chunk that had already ended there, and parallels are recognised by comparing the English ULB. A language's projects are compared together even under different codes that share their first part (`mxc-MZ-x-manika` and `mxc-MZ-chimanika`; private-use `qaa`-`qtz` and `x-` codes excepted), with a warning naming the codes. `--language` (a code, or a first part such as `mxc`) and `--book` limit what is reported, but all books of the language are compared; `--no-history` compares current text only (faster, but cannot tell which came first). Also reports book titles another book has (or had first) and chapter titles with another chapter's number. On request it compares with other languages too: `--other-languages` (the other languages' projects in the projects folder), `--sources` (BTT-Writer's source texts of the same books, every language) and `--compare-dir <folder>` (projects elsewhere, such as a neighbouring language's repos downloaded with `wacs-download --target-dir`). It reports verses the same as another language's (97% or more alike), verses an edit reworded to read like another language's (80% or more alike, 15 points more than before), and chunks mostly made of another language's chunk. Between two projects, git history decides which had the text first: only the later one is reported, with the commit that brought it in; with no history to tell (or `--no-history`) both are, marked as such. A source text always counts as the original. Related languages share much, so a verse merely close to one is not reported. Changes nothing. |
| `cross-repair` | Repairs what `cross-check` finds, one chunk file at a time. Find lists the damaged chunks (where the text came from, the commit that brought it in, and what repair would do); check the ones to repair (`--chunk project/chapter/chunk`, or `--all` for every chunk the filters show). A book title that another book has, brought in by a commit that also brought copied text, gets its title from before that back. A chunk that existed before gets its version from before the damaging commit back (from before the first, when several sessions damaged it); a chunk the damage added is deleted and taken out of `finished_chunks`. Everything else those commits changed stays. Left alone: chunks edited since by anyone else, chunks with uncommitted changes, and (unless `--include-mixed`) chunks whose damaging commit also changed their own words. Uncommitted work is committed first; each project gets one commit listing what was done, then everything is checked again. `--dry-run` reports without changing anything. Upload afterwards with `wacs-upload`; the devices that sent the damage must delete the project and import it again. |

```sh
btw list
btw help ulb2reg
btw ulb2reg ~/.config/BTT-Writer/targetTranslations/en_mat_text_ulb --dry-run
btw --lang fr ulb2reg <project>
btw tstudio-import ~/Desktop/en_tit_text_reg.tstudio --dry-run
btw tstudio-import ~/Desktop/en_tit_text_reg.tstudio --on-existing merge
btw tstudio-import tablet1.tstudio tablet2.tstudio --dry-run
btw projects --problems-only
btw projects --language sah,udm --book jon --type text_reg
btw cross-check --language mxc-MZ-x-manika
btw cross-repair --language mxc-MZ-x-manika --book 2co --all --dry-run
```

Source chunking comes from BTT-Writer's library
(`library/resource_containers`), or, for sources BTT-Writer hasn't
unpacked yet, from the `.tsrc` files bundled with BTT-Writer. Set
`BTW_BUNDLED_SOURCES` if the bundled folder isn't found.

In the GUI, the language, book and type filters (and the WACS owner) are pickers: editable drop-downs that complete what you type from what is likely (each part of a comma-separated list on its own; Backspace does not complete), list the matches, and still take anything typed. The projects modules suggest what the projects folder holds; Download from WACS suggests every language in BTT-Writer's language database, every book and the usual types, and after **Find** what WACS has (books, types, owners). A module with a check gets a **Check** button next to **Run**. **Save report…** writes what the module reported to a text file you choose, headed by the module, date and options used (passwords left out). On the command line, redirect the output instead: `btw projects > report.txt`.

### macOS

The disk image (`btt-workbench-<version>-macos.dmg`) holds BTT Workbench.app
for Apple Silicon and Intel Macs (macOS 11 or later): drag it onto
Applications. The app is not notarized by Apple yet, so the first time
macOS refuses to open it: open it once, then click **Open Anyway** in
System Settings → Privacy & Security (or run `xattr -dr
com.apple.quarantine "/Applications/BTT Workbench.app"`). Double-clicking
a `.tstudio` file then opens it in the import, which checks it first.

The command-line program is inside the app; to put it on PATH:
`sudo ln -sf "/Applications/BTT Workbench.app/Contents/MacOS/btw"
/usr/local/bin/btw`.

### Double-click `.tstudio` files (Linux and Windows)

The `.deb` and the Windows installer (if you tick it) make `.tstudio`
files open with BTT Workbench. Double-clicking a package then opens BTT Workbench on the import module and
runs the check. Nothing changes until you choose what to do and press **Run**.
Opening several packages at once, or double-clicking another while the
window is open, adds them to the same list and checks them all again.

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

The version is written as BTT-Writer writes its own, `<release>+<build>`
(for example `0.2.0+26`): the release is set by hand in
`src/core/WBVersion.pas`, the build number is the git commit count, and
the short commit goes with it (`btw --version`, the window title, saved
reports, the Windows file properties). A build from uncommitted changes
says `-modified`; one made outside `build.sh` says `+dev`.

```sh
tools/release.sh            # dist/: .tar.gz, .zip, .deb and -win64-setup.exe
                            # (on a Mac: dist/btt-workbench-<version>-macos.dmg)
```

It refuses uncommitted changes, builds and tests everything, strips the
programs and packs them with the README, licence and translations, then
makes the installers (`tools/package-deb.sh`, `tools/package-win.sh`).
They need `dpkg-deb`, `rsvg-convert` (librsvg2-bin) and `makensis`
(nsis); `makensis` runs on Linux, so the Windows installer is built
there too.

The library updates write SQLite through the system's library, loaded when needed: `libsqlite3.so.0` on Linux, `winsqlite3.dll` (part of Windows 10 and 11) on Windows.

On a Mac, `./build.sh` also makes `bin/BTT Workbench.app`, and `./build.sh
--universal` builds for Apple Silicon and Intel together (it needs FPC's
x86_64 cross-compiler; see [docs/macos-build.md](docs/macos-build.md)).
Web access goes through macOS's own NSURLSession, so no OpenSSL is needed.

For Windows, cross-build from Linux once FPC has its win64 units:
`./build.sh --win64` (the CLI and the GUI). The `.exe` files use only DLLs that come with
Windows: web access goes through Windows' own WinHTTP, so no OpenSSL is
needed. They do need git for Windows (2.38 or newer), which the
BTT-Writer installer sets up.

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
