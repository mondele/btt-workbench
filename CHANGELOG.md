# Changelog

All notable changes to BTT Workbench. Versions are written as BTT-Writer
writes its own, `<release>+<build>`, where the build number is the git
commit count (see [README](README.md#building)).

Each release's section below is also its release notes on GitHub.

## Unreleased

- Spanish translation (`locale/es`), machine-made for testing the
  translation support; it needs review by a Spanish speaker before it is
  relied on. `btw --lang es`, or the GUI's language setting.

- tstudio-import: a package whose entries are marked as made on macOS
  (as FPC's zip code writes them there) no longer unpacks with unreadable
  files ("Permission denied" on manifest.json).

- text-check on ARM (the Android app, Apple Silicon Macs): patterns with
  a count such as `{0,11}` used the wrong count, because the regex engine
  read it from the wrong place on CPUs that need aligned memory access.

- The programs have an icon (the hammer in a blue hexagon): on Windows
  for btt-workbench.exe and btw.exe, and as the GUI's window icon.

- text-check: a verse bridge of three or more verses (`\v 23-25`) is no
  longer reported as "Verses out of order".

- text-check: 3 John 1:15 and Revelation 12:18 are no longer reported
  as "Verse numbers past the end of the chapter". Many Bibles number the
  ends of those chapters one verse further than the table usfm-tools
  uses, and verifyUSFM allows them too.

- projects: chunking and verse markers are reported per source, each
  saying what is extra, missing (missing chunks whose verses are in
  other chunks apart) and outside its chunks, or that nothing is, then
  which source the project matches. A project that matches a listed
  source and only chunks differently from en_ulb (Chimanika John follows
  pt-br_jhn_blv) is no longer reported as a problem; the en_ulb line
  says what would be lost if it were opened with en_ulb.

- cross-check, other languages: a verse or chunk two projects share is
  reported only on the project that had it later, by both projects' git
  history, with the commit that brought it in; a rewording only if the
  other text read that way first. Chimanika Mark 01-13 (Chibangwe 3 John
  13-15, pasted in October 2026) is reported on Mark alone. Compared the
  other way, the Bemba repos no longer show 10 verses "reworded to read
  like Bwile" in 2022, before Bwile had that wording. Without history on
  either side both are reported, marked as unknown order.
- projects: chunk files that no compared source has are listed with the
  commit that added each and how it begins. `--remove-extra-chunks`
  ("Remove extra chunks") deletes them on Run, with their finished marks,
  in one commit (loose work is committed first); a chunk holding verses
  no other chunk has is kept and named.

- projects: verse markers are always compared with en_ulb as well, not
  only with the source the project follows (a project following another
  source's chunking was never compared with English); reported on a line
  of its own. Each text project's report names the sources it was
  compared with, so a clean one shows en_ulb was looked at.
- projects: a `.git` folder that has lost `HEAD`, `config` or its index
  while its history is intact (as an incomplete copy leaves it; git then
  does not see a repository at all) is reported, and rebuilt on Run: HEAD
  on master, git's default config, the index from the last commit. The
  files are not touched, and nothing is kept unless `git fsck` finds the
  history whole.
- New modules **library-languages** ("Update target languages") and
  **library-sources** ("Update source list"): BTT-Writer's Update
  Languages and Update Sources, downloading catalogs several at once
  (languages about 1.5 s, sources about 30 s where BTT-Writer takes 3.5 to
  5.5 minutes), writing the rows BTT-Writer would write. They report what
  changed (languages or resources added, removed and changed, and projects
  whose language code goes), and replace BTT-Writer's index.sqlite only
  while BTT-Writer is not running, keeping the old one beside it; or write
  elsewhere (`--output`), or only report (Check).
- WACS and catalog access on Linux get past Cloudflare on
  cdn.bibletranslationtools.org, and JSON with `\u` escapes keeps its
  non-ASCII text.
- GUI: the language, book and type filters, and the WACS owner, are
  pickers: editable drop-downs that complete what is typed, list the
  matches and still take anything (each value of a comma-separated list on
  its own). The projects modules offer what the projects folder holds;
  Download from WACS offers every language in BTT-Writer's language
  database, every book and the usual types, and after Find what WACS has.
- New module **language-change** ("Change project language"): gives the
  checked projects another language code, name or text direction, so a
  language's projects agree (Udmurt projects under two names, Chimanika
  under two codes). It changes and commits each manifest and renames the
  folder for a new code; WACS is not changed.
- projects: warns about language codes that are not well-formed BCP 47
  (Scripture Burrito needs them; mxc-MZ-chimanika and udm-x-norudmurt are
  not), and notes a language's projects under several names or codes.
  `--language` also takes a first part such as `mxc`.
- cross-check: book titles that another book has (or had first) and
  chapter titles with another chapter's number are reported. Titles were
  too short for the copied-text check, and the Chimanika damage had
  changed several (Luke and Mark both "JudaBERU", Acts and John
  "Marako"). Spaces don't count, and a title another book got in the
  same session counts even after that book was put right. cross-repair
  offers every title found: a book title goes back to the last earlier
  title of its own (not another book's, not set in the same session), a
  chapter title to an earlier version with its number or gets its number
  corrected; a title with nothing to go back to is left to fix by hand.
- cross-check can also compare with other languages: `--other-languages`
  (projects of other languages in the projects folder), `--sources`
  (BTT-Writer's source texts of the same books) and `--compare-dir`
  (projects in other folders, such as a neighbouring language's repos).
  It reports verses the same as another language's, verses reworded to
  read like another language's, and chunks taken from another language.
  On the Bwile 1 Peter and 1 John repos compared with Bemba it finds the
  8 verses reworded towards the Bemba Bible in October 2026, and nothing
  else.
- cross-check and cross-repair: a language's projects are compared
  together even when they carry different codes that share their first
  part. Chimanika's Luke (`mxc-MZ-chimanika`) had been compared only with
  itself, so text pasted into it from Mark and Acts (`mxc-MZ-x-manika`)
  went unreported. A warning now names the codes, and `--language` takes
  a first part such as `mxc` and only limits what is reported.
- Tests: the test program exits with 1 on any failure (a failure count of
  256 used to wrap round to exit code 0).

## 0.2.0+26 — 2026-10-16

First release. BTT Workbench is the successor to
[BTT-Manager](https://github.com/mondele/BTT-Manager): a toolbox for
technicians supporting BTT-Writer users. Every tool (module) runs from
the command line (`btw <module>`) and from the desktop program
(`btt-workbench`).

### Downloads

| File | For |
|------|-----|
| `btt-workbench-0.2.0+26-win64.zip` | Windows 10/11, 64-bit: `btt-workbench.exe` (desktop) and `btw.exe` (command line) |
| `btt-workbench-0.2.0+26-linux-x86_64.tar.gz` | Linux, 64-bit: `btt-workbench` and `btw` |

Both need git 2.38 or newer (the BTT-Writer installer sets it up on
Windows). The Windows programs use only DLLs that come with Windows. On
Linux the desktop program needs GTK2, and WACS access needs OpenSSL 3.

### Modules

- **projects**: lists BTT-Writer projects and their problems: unreadable
  or damaged manifests, folder names that don't match, missing or damaged
  git history (`--deep-git` runs `git fsck`), unresolved conflicts,
  finished chunks with no file, chunking that doesn't match the source,
  verse markers in the wrong chunk, and language names, directions and
  codes that lag BTT-Writer's language database. Moves projects on git
  branch `main` to `master`, the only branch BTT-Writer uses.
- **tstudio-import**: imports one or more `.tstudio` packages the way
  BTT-Writer 1.6.0 does. The check reports whether each project is new,
  up to date or needs merging, and which chunks would conflict, taking
  several packages in order. On Linux, `.tstudio` files can open in BTT
  Workbench with a double-click (`tools/install-desktop.sh`).
- **ulb2reg**: converts a project from ULB to REG.
- **settings**: shows and saves where BTT-Writer's data and bundled
  source texts are; finds installs in the usual places.
- **wacs-account**: logs in to WACS and keeps only a login token, never
  the password.
- **wacs-download**: finds projects on WACS by language, book, type and
  owner, shows each repo's BIEL state (Primary, Active, Inactive), and
  downloads the chosen ones, merging into existing projects as BTT-Writer
  does.
- **wacs-upload**: uploads the chosen projects to WACS in one run, as
  BTT-Writer's Upload does, and skips or merges when WACS has newer work.
- **text-check**: the translation checks of usfm-tools' `verifyUSFM`
  (Larry Versaw), run straight on BTT-Writer chunk files: verses,
  markers, punctuation, quotes, numbers, capitals, footnotes, possible
  section titles, and verses that look untranslated compared with the
  source. Gives the same results as the current Python on all of its
  test cases, in less time and memory.
- **cross-check**: finds text copied from one book into another within a
  language, using each project's git history to tell which book had it
  first and which commit brought it in. Real parallels (Kings and
  Chronicles, the gospels) are left out.
- **cross-repair**: repairs what cross-check finds, one chunk at a time:
  a damaged chunk gets its earlier version back, and a chunk the damage
  added is removed. Chunks edited since are left alone. Each project gets
  one commit, made as the WACS user logged in (else "BTT Workbench").
  Upload afterwards with wacs-upload; the devices that sent the damage
  must delete the project and import it again.

### Desktop program

- Find, Check and Run work in the background, so the window stays
  responsive during slow WACS requests.
- **Save report…** writes a module's output to a text file, headed by
  the version, module, date and options (passwords left out).
- The version shows in the window title, in saved reports and in the
  Windows file properties.

### Known limits

- Uploading to the live WACS server has not yet been tried end to end.
- WACS access from the Windows build (through WinHTTP) has not yet been
  tested on Windows; the rest of the Windows build has.
- The interface is translatable (gettext `.po` files), but no
  translations are included yet.
