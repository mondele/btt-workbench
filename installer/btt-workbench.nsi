; Windows installer for BTT Workbench (NSIS 3, built on Linux by
; tools/package-win.sh; makensis also runs on Windows).
;
;   makensis -DVERSION=0.2.0+51 -DVERSION4=0.2.0.51 -DSRC=<staged files>
;            -DOUTFILE=<setup.exe> installer/btt-workbench.nsi
;
; Installs for all users into Program Files\BTT Workbench: the GUI, btw,
; README, CHANGELOG, LICENSE and the translations. Adds a Start menu
; entry, optionally a desktop shortcut, and the .tstudio file type
; (double-click opens the import check). Warns when Git for Windows is
; missing: Workbench runs git for everything that touches a project.

Unicode true
SetCompressor /SOLID lzma
ManifestDPIAware true

!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

!define APP "BTT Workbench"
!define EXE "btt-workbench.exe"
!define PUBLISHER "Wycliffe Associates"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP}"
!define PROGID "BttWorkbench.tstudio"
!define GIT_URL "https://git-scm.com/download/win"

Name "${APP} ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\${APP}"
InstallDirRegKey HKLM "${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel admin

VIProductVersion "${VERSION4}"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "${APP} setup"
VIAddVersionKey "LegalCopyright" "MIT licence"

!define MUI_ICON "..\src\gui\BttWorkbench.ico"
!define MUI_UNICON "..\src\gui\BttWorkbench.ico"
!define MUI_ABORTWARNING
!define MUI_LANGDLL_ALLLANGUAGES
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${SRC}\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Spanish"
!insertmacro MUI_RESERVEFILE_LANGDLL

LangString SecMain ${LANG_ENGLISH} "${APP} (required)"
LangString SecMain ${LANG_SPANISH} "${APP} (necesario)"
LangString SecDesktop ${LANG_ENGLISH} "Desktop shortcut"
LangString SecDesktop ${LANG_SPANISH} "Acceso directo en el escritorio"
LangString SecTStudio ${LANG_ENGLISH} "Open .tstudio files with ${APP}"
LangString SecTStudio ${LANG_SPANISH} "Abrir archivos .tstudio con ${APP}"
LangString TStudioType ${LANG_ENGLISH} "BTT-Writer project package"
LangString TStudioType ${LANG_SPANISH} "Paquete de proyecto de BTT-Writer"
LangString No64 ${LANG_ENGLISH} "${APP} needs 64-bit Windows."
LangString No64 ${LANG_SPANISH} "${APP} necesita Windows de 64 bits."
LangString NoGit ${LANG_ENGLISH} "Git for Windows was not found (the BTT-Writer installer sets it up). ${APP} needs it to read, repair, download and upload projects.$\r$\n$\r$\nOpen the Git for Windows download page now?"
LangString NoGit ${LANG_SPANISH} "No se encontró Git for Windows (el instalador de BTT-Writer lo instala). ${APP} lo necesita para leer, reparar, descargar y subir proyectos.$\r$\n$\r$\n¿Abrir ahora la página de descarga de Git for Windows?"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "$(No64)"
    Abort
  ${EndIf}
  SetRegView 64
  !insertmacro MUI_LANGDLL_DISPLAY
FunctionEnd

Function un.onInit
  SetRegView 64
  !insertmacro MUI_UNGETLANGUAGE
FunctionEnd

Section "$(SecMain)" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "${SRC}\${EXE}"
  File "${SRC}\btw.exe"
  File "${SRC}\README.md"
  File "${SRC}\CHANGELOG.md"
  File "${SRC}\LICENSE"
  ; A newer version may have dropped a translation: start the folder over.
  RMDir /r "$INSTDIR\locale"
  File /nonfatal /r "${SRC}\locale"

  SetShellVarContext all
  CreateShortcut "$SMPROGRAMS\${APP}.lnk" "$INSTDIR\${EXE}"

  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${EXE}"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "URLInfoAbout" "https://github.com/mondele/btt-workbench"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "$(SecDesktop)" SEC_DESKTOP
  SetShellVarContext all
  CreateShortcut "$DESKTOP\${APP}.lnk" "$INSTDIR\${EXE}"
SectionEnd

; BTT-Writer registers no .tstudio type, so this takes nothing from it.
; The default is only set when no other program has one.
Section "$(SecTStudio)" SEC_TSTUDIO
  WriteRegStr HKLM "Software\Classes\${PROGID}" "" "$(TStudioType)"
  WriteRegStr HKLM "Software\Classes\${PROGID}\DefaultIcon" "" "$INSTDIR\${EXE},0"
  WriteRegStr HKLM "Software\Classes\${PROGID}\shell\open\command" "" '"$INSTDIR\${EXE}" tstudio-import "%1"'
  WriteRegStr HKLM "Software\Classes\.tstudio\OpenWithProgids" "${PROGID}" ""
  ReadRegStr $0 HKLM "Software\Classes\.tstudio" ""
  ${If} $0 == ""
    WriteRegStr HKLM "Software\Classes\.tstudio" "" "${PROGID}"
  ${EndIf}
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd

Section "-git check"
  ReadRegStr $0 HKLM "Software\GitForWindows" "InstallPath"
  ${If} $0 == ""
    SearchPath $0 "git.exe"
  ${EndIf}
  ${If} $0 == ""
  ${AndIfNot} ${Silent}
    MessageBox MB_YESNO|MB_ICONEXCLAMATION "$(NoGit)" IDNO +2
    ExecShell "open" "${GIT_URL}"
  ${EndIf}
SectionEnd

Section "-size"
  SectionGetSize ${SEC_MAIN} $0
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" $0
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\${EXE}"
  Delete "$INSTDIR\btw.exe"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\CHANGELOG.md"
  Delete "$INSTDIR\LICENSE"
  RMDir /r "$INSTDIR\locale"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  SetShellVarContext all
  Delete "$SMPROGRAMS\${APP}.lnk"
  Delete "$DESKTOP\${APP}.lnk"

  DeleteRegValue HKLM "Software\Classes\.tstudio\OpenWithProgids" "${PROGID}"
  ReadRegStr $0 HKLM "Software\Classes\.tstudio" ""
  ${If} $0 == "${PROGID}"
    DeleteRegValue HKLM "Software\Classes\.tstudio" ""
  ${EndIf}
  DeleteRegKey /ifempty HKLM "Software\Classes\.tstudio\OpenWithProgids"
  DeleteRegKey /ifempty HKLM "Software\Classes\.tstudio"
  DeleteRegKey HKLM "Software\Classes\${PROGID}"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'

  DeleteRegKey HKLM "${UNINST_KEY}"
SectionEnd
