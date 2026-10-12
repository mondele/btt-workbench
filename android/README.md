# Android UI (planned)

A small Kotlin app over `libbtw.so`. This is the same split as btt-writer-two:
the Pascal core does the work, and the Android UI is written natively in Kotlin.
Nothing is here yet.

## The core side (done)

`src/lib/btw.lpr` builds `libbtw.so` with a flat C ABI. Strings are UTF-8,
data is JSON, and every returned string is freed with `btw_free_string`:

| Function | Returns |
|---|---|
| `btw_api_version()` | int, bumped on breaking ABI changes |
| `btw_set_language(lang, locale_dir)` | `{"language", "loaded", "rtl"}` |
| `btw_list_modules()` | modules with their option definitions (translated captions) |
| `btw_run_module(id, options_json)` | `{"exit_code", "messages": [{"level", "text"}]}` |

`btw_list_modules` returns enough to generate each module's form, the way
the desktop GUI does. A new module then needs no Kotlin changes.

## To do

1. **Cross-compile** for `aarch64-android` (and `arm-android` and
   `x86_64-android` for the emulator) using fpcupdeluxe's Android
   cross-compiler and the NDK.
2. **JNI bridge.** Kotlin can't call plain C functions directly. Either add
   a few lines of C/JNI shim in the app that forward to the `btw_*`
   functions, or add `Java_..._Native_*` exports on the Pascal side using
   FPC's `jni` unit. Decide once the package name is fixed.
3. **Locale files.** Ship `locale/*/btt-workbench.po` as assets, copy them
   to `filesDir` on first run, and pass that directory to
   `btw_set_language`.
4. **Storage access.** BTT-Writer Android keeps projects in app-private
   storage. Find out what a technician can actually reach (SAF, `adb`,
   export/import) before building module forms around file paths.
5. **Threading.** Run `btw_run_module` on one background thread; the core
   isn't reentrant.
