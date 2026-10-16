unit WBVersion;

{$mode objfpc}{$H+}

{ The version, as BTT-Writer writes its own: <release>+<build>, e.g.
  0.2.0+26. The release is set here by hand; the build number (the git
  commit count) and the commit come from build.sh, which passes them to the
  compiler in BTW_BUILD and BTW_COMMIT. A build made some other way (the
  Lazarus IDE) says +dev. }

interface

const
  WorkbenchRelease = '0.2.0';
  WorkbenchBuild = {$I %BTW_BUILD%};     // '26'; '' outside build.sh
  WorkbenchCommit = {$I %BTW_COMMIT%};   // '050c9d3', '050c9d3-modified'
  { Bump when the libbtw C ABI changes incompatibly. }
  WorkbenchApiVersion = 2;   // 2: btw_choices, password and checklist options

{ 0.2.0+26 }
function WorkbenchVersion: string;
{ 0.2.0+26 (050c9d3) }
function WorkbenchVersionLong: string;

implementation

function WorkbenchVersion: string;
begin
  if WorkbenchBuild <> '' then
    Result := WorkbenchRelease + '+' + WorkbenchBuild
  else
    Result := WorkbenchRelease + '+dev';
end;

function WorkbenchVersionLong: string;
begin
  Result := WorkbenchVersion;
  if WorkbenchCommit <> '' then
    Result := Result + ' (' + WorkbenchCommit + ')';
end;

end.
