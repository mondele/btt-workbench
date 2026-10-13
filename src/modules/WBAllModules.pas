unit WBAllModules;

{$mode objfpc}{$H+}

{ The one place modules are listed. The CLI, GUI, library and tests all
  use this unit, so a new module only needs adding here (and to the
  <Units> of the .lpi files if you want it visible in the IDE). }

interface

uses
  ModUlb2Reg,
  ModTStudioImport,
  ModProjects,
  ModSettings,
  ModWacsAccount,
  ModWacsDownload;

implementation

end.
