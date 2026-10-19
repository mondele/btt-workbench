# Changelog

All notable changes to BTT Workbench. Versions are written as BTT-Writer
writes its own, `<release>+<build>`, where the build number is the git
commit count (see [README](README.md#building)).

Each release's section below is also its release notes on GitHub.

## Unreleased

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
