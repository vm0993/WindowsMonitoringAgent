; Inno Setup 6 script: builds OfficeMonitoringAgent-Setup-<version>.exe from the self-contained publish folder.
;   iscc /DAppVersion=2.1.0 /DPublishDir=..\publish installer\OfficeMonitoringAgent.iss
; (/DFileVersion=x.y.z[.n] is needed when AppVersion is not numeric, e.g. 0.0.0-ci.5)
; Silent install (all values optional on upgrade):
;   OfficeMonitoringAgent-Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /ROLE=fs-utama /APIURL=https://100.x.y.z
;     /AGENTID=fs-utama /SITE=office /TOKEN=<token> [/SYNCTHINGKEY=<key>] [/DATAROOT=D:\] [/CERT=C:\monitor.crt]
;     [/TASKS="startservice,trustcert"]
; The monitoring server is reached ONLY over its Tailscale IP (100.64.0.0/10, fd7a:115c:a1e0::/48); host names, LAN and
; public IPs are refused. Bake the default in at build time with /DDefaultApiUrl=https://100.x.y.z (installer/build.sh and
; the release workflow pass MONITOR_API_URL). certs\monitoring.crt = the server's self-signed certificate for that IP
; (made with installer/make-cert.sh); it is imported into Trusted Root by the "trustcert" task.

#ifndef AppVersion
  #define AppVersion "2.0.0"
#endif
#ifndef FileVersion
  #define FileVersion AppVersion
#endif
#ifndef PublishDir
  #define PublishDir "..\publish"
#endif
#ifndef DefaultApiUrl
  #define DefaultApiUrl ""
#endif
#define ServiceName "OfficeMonitoringAgent"
; Put the monitoring server certificate here to ship it with the installer (public certificate only, never the key).
#ifexist "certs\monitoring.crt"
  #define EmbeddedCert
#endif

[Setup]
AppId={{6F1D2B7C-3E4A-4C59-9B1E-0D7A5C2F8E31}
AppName=Office Monitoring Agent
AppVersion={#AppVersion}
AppVerName=Office Monitoring Agent {#AppVersion}
AppPublisher=Dapenma
VersionInfoVersion={#FileVersion}
DefaultDirName={code:GetDefaultDir}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=OfficeMonitoringAgent-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Office Monitoring Agent
UninstallDisplayIcon={app}\WindowsMonitoringAgent.exe
CloseApplications=no

[Tasks]
Name: "startservice"; Description: "Jalankan service setelah instalasi"
#ifdef EmbeddedCert
Name: "trustcert"; Description: "Percayai sertifikat server monitoring yang disertakan (Trusted Root)"
#endif

[Files]
Source: "{#PublishDir}\*"; Excludes: "appsettings.json,*.pdb,\deploy\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
; The live appsettings.json is created by configure.ps1 from one of these and is never overwritten on upgrade.
Source: "{#PublishDir}\appsettings.json"; DestDir: "{app}\examples"; DestName: "appsettings.default.json"; Flags: ignoreversion
Source: "..\deploy\examples\*.json"; DestDir: "{app}\examples"; Flags: ignoreversion
Source: "configure.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
Source: "..\deploy\check-prerequisites.ps1"; DestDir: "{app}\tools"; Flags: ignoreversion
#ifdef EmbeddedCert
Source: "certs\monitoring.crt"; DestDir: "{app}\certs"; Flags: ignoreversion
#endif

[Run]
Filename: "{sys}\notepad.exe"; Parameters: """{app}\appsettings.json"""; Description: "Buka appsettings.json untuk memeriksa folder dan rute"; Flags: postinstall nowait skipifsilent unchecked

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""$s=Get-Service {#ServiceName} -ErrorAction SilentlyContinue; if($s){{ if($s.Status -ne 'Stopped'){{ Stop-Service {#ServiceName} -Force; $s.WaitForStatus('Stopped','00:01:00') }; sc.exe delete {#ServiceName} }"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveService"

[UninstallDelete]
Type: files; Name: "{app}\install.log"

[Code]
const
  ServiceKey = 'SYSTEM\CurrentControlSet\Services\{#ServiceName}';
  TokenVar = 'MONITOR_AGENT_API_KEY';
  SyncthingVar = 'SYNCTHING_API_KEY';

var
  RolePage: TInputOptionWizardPage;
  ConnPage: TInputQueryWizardPage;
  DataPage: TInputDirWizardPage;
#ifndef EmbeddedCert
  CertPage: TInputFileWizardPage;
#endif
  ExistingDir: String;
  HasExistingConfig: Boolean;

function PowerShell: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function Param(const Name, Default: String): String;
begin
  Result := Trim(ExpandConstant('{param:' + Name + '}'));
  if Result = '' then
    Result := Default;
end;

function RoleCode(Index: Integer): String;
begin
  case Index of
    0: Result := 'fs-utama';
    1: Result := 'fs-mirror';
    2: Result := 'fs-dc';
  else
    Result := 'default';
  end;
end;

function RoleSite(Index: Integer): String;
begin
  if Index = 2 then
    Result := 'datacenter'
  else
    Result := 'office';
end;

function RoleIndex(const Code: String): Integer;
begin
  Result := 3;
  if CompareText(Code, 'fs-utama') = 0 then Result := 0;
  if CompareText(Code, 'fs-mirror') = 0 then Result := 1;
  if CompareText(Code, 'fs-dc') = 0 then Result := 2;
end;

{ The install folder of an existing service, also when it was installed with deploy\install.ps1. }
function ExistingServiceDir: String;
var
  ImagePath: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM, ServiceKey, 'ImagePath', ImagePath) then
  begin
    StringChangeEx(ImagePath, '"', '', True);
    Result := ExtractFileDir(ImagePath);
  end;
end;

function GetDefaultDir(Value: String): String;
begin
  if ExistingDir <> '' then
    Result := ExistingDir
  else
    Result := ExpandConstant('{autopf}\{#ServiceName}');
end;

{ Service environment: REG_MULTI_SZ "NAME=value" entries separated by #0. }
function ServiceEnvironment: String;
begin
  if not RegQueryMultiStringValue(HKLM, ServiceKey, 'Environment', Result) then
    Result := '';
end;

function EnvironmentHas(const Env, Name: String): Boolean;
begin
  Result := (Pos(Uppercase(Name) + '=', Uppercase(Env)) = 1) or (Pos(#0 + Uppercase(Name) + '=', Uppercase(Env)) > 0);
end;

function EnvironmentSet(Env: String; const Name, Value: String): String;
var
  Item: String;
  At: Integer;
begin
  Result := '';
  while Env <> '' do
  begin
    At := Pos(#0, Env);
    if At = 0 then
    begin
      Item := Env;
      Env := '';
    end else
    begin
      Item := Copy(Env, 1, At - 1);
      Delete(Env, 1, At);
    end;
    if (Item <> '') and (Pos(Uppercase(Name) + '=', Uppercase(Item)) <> 1) then
    begin
      if Result <> '' then Result := Result + #0;
      Result := Result + Item;
    end;
  end;
  if Result <> '' then Result := Result + #0;
  Result := Result + Name + '=' + Value;
end;

{ Host part of an https:// URL, lowercase, without port or IPv6 brackets. }
function UrlHost(Url: String): String;
var
  At: Integer;
begin
  Url := Lowercase(Trim(Url));
  At := Pos('://', Url);
  if At > 0 then Delete(Url, 1, At + 2);
  At := Pos('/', Url);
  if At > 0 then Url := Copy(Url, 1, At - 1);
  At := Pos('@', Url);
  if At > 0 then Delete(Url, 1, At);
  if (Url <> '') and (Url[1] = '[') then
  begin
    At := Pos(']', Url);
    if At > 0 then Url := Copy(Url, 2, At - 2);
  end else
  begin
    At := Pos(':', Url);
    if At > 0 then Url := Copy(Url, 1, At - 1);
  end;
  Result := Url;
end;

{ True for 100.64.0.0/10 (Tailscale CGNAT range). }
function IsTailscaleIPv4(Host: String): Boolean;
var
  I, At, Part: Integer;
  Parts: array[0..3] of Integer;
begin
  Result := False;
  for I := 0 to 3 do
  begin
    At := Pos('.', Host);
    if I = 3 then
    begin
      if At > 0 then Exit;
      At := Length(Host) + 1;
    end else if At = 0 then
      Exit;
    Part := StrToIntDef(Copy(Host, 1, At - 1), -1);
    if (Part < 0) or (Part > 255) or (At = 1) then Exit;
    Parts[I] := Part;
    Delete(Host, 1, At);
  end;
  Result := (Parts[0] = 100) and (Parts[1] >= 64) and (Parts[1] <= 127);
end;

{ Only Tailscale IPs are accepted: 100.64.0.0/10 or fd7a:115c:a1e0::/48. }
function IsTailscaleUrl(const Url: String): Boolean;
var
  Host: String;
begin
  Host := UrlHost(Url);
  Result := (Host <> '') and (
    IsTailscaleIPv4(Host) or
    (Pos('fd7a:115c:a1e0:', Host) = 1));
end;

function HasToken: Boolean;
begin
  Result := EnvironmentHas(ServiceEnvironment, TokenVar) or (GetEnv(TokenVar) <> '');
end;

{ Reads ApiBaseUrl, AgentId and Site from an existing appsettings.json so an upgrade keeps them. }
function ReadExistingConfig(var Url, AgentId, Site: String): Boolean;
var
  OutFile: String;
  Lines: TArrayOfString;
  Code: Integer;
begin
  Result := False;
  ExtractTemporaryFile('configure.ps1');
  OutFile := ExpandConstant('{tmp}\existing.txt');
  if Exec(PowerShell, '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\configure.ps1') +
      '" -InstallDir "' + ExistingDir + '" -ReadConfig "' + ExistingDir + '\appsettings.json" -OutFile "' + OutFile + '"',
      '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) and LoadStringsFromFile(OutFile, Lines) and (GetArrayLength(Lines) >= 3) then
  begin
    Url := Lines[0];
    AgentId := Lines[1];
    Site := Lines[2];
    Result := True;
  end;
end;

function InitializeSetup: Boolean;
begin
  ExistingDir := ExistingServiceDir;
  HasExistingConfig := (ExistingDir <> '') and FileExists(ExistingDir + '\appsettings.json');
  Result := True;
end;

procedure InitializeWizard;
var
  Url, AgentId, Site: String;
  Role: Integer;
begin
  RolePage := CreateInputOptionPage(wpSelectDir, 'Peran server',
    'Pilih peran server ini dalam alur replikasi.',
    'Konfigurasi awal (folder, DFSR, Syncthing, Tailscale) diambil dari contoh sesuai peran. Detailnya dapat diubah nanti di appsettings.json.',
    True, False);
  RolePage.Add('FS-UTAMA: server sumber, memantau DFSR ke FS-MIRROR');
  RolePage.Add('FS-MIRROR: anggota DFSR, mengirim Syncthing ke FS-DC');
  RolePage.Add('FS-DC: data center, menerima Syncthing dari FS-MIRROR');
  RolePage.Add('Lainnya: konfigurasi umum');
  Role := RoleIndex(Param('ROLE', 'fs-utama'));
  RolePage.SelectedValueIndex := Role;

  ConnPage := CreateInputQueryPage(RolePage.ID, 'Koneksi ke server monitoring',
    'Isi sesuai pendaftaran agent di server monitoring.',
    'Agent ID dan Site harus sama persis dengan perintah "php artisan monitor:register-agent <agent_id> <site>". Token ditampilkan sekali oleh perintah tersebut.');
  ConnPage.Add('URL server monitoring via IP Tailscale (https://100.x.y.z):', False);
  ConnPage.Add('Agent ID:', False);
  ConnPage.Add('Site:', False);
  ConnPage.Add('Token agent (kosongkan untuk memakai token yang sudah terpasang):', True);
  ConnPage.Add('API key Syncthing (hanya FS-MIRROR dan FS-DC, boleh kosong):', True);

  Url := '{#DefaultApiUrl}';
  AgentId := RoleCode(Role);
  Site := RoleSite(Role);
  if Role = 3 then AgentId := '';
  if HasExistingConfig then
  begin
    ReadExistingConfig(Url, AgentId, Site);
    { Older installs point at the datacenter LAN IP: switch them to the Tailscale address on upgrade. }
    if not IsTailscaleUrl(Url) then
      Url := '{#DefaultApiUrl}';
  end;
  ConnPage.Values[0] := Param('APIURL', Url);
  ConnPage.Values[1] := Param('AGENTID', AgentId);
  ConnPage.Values[2] := Param('SITE', Site);
  ConnPage.Values[3] := Param('TOKEN', '');
  ConnPage.Values[4] := Param('SYNCTHINGKEY', '');

  DataPage := CreateInputDirPage(ConnPage.ID, 'Lokasi folder data',
    'Folder induk tempat folder share berada.',
    'Folder Keuangan, Umum, dan Sekretariat dicari di dalam folder ini (contoh: D:\ untuk D:\Keuangan). Path setiap folder dapat diubah nanti di appsettings.json.',
    False, '');
  DataPage.Add('Folder induk:');
  DataPage.Values[0] := Param('DATAROOT', 'D:\');

#ifndef EmbeddedCert
  CertPage := CreateInputFilePage(DataPage.ID, 'Sertifikat server monitoring',
    'Opsional: sertifikat server monitoring yang perlu dipercaya Windows.',
    'Pilih file .crt/.pem/.cer bila server monitoring memakai sertifikat self-signed. Kosongkan bila sertifikatnya sudah dipercaya.');
  CertPage.Add('File sertifikat:', 'Sertifikat|*.crt;*.pem;*.cer|Semua file|*.*', '.crt');
  CertPage.Values[0] := Param('CERT', '');
#endif
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := HasExistingConfig and ((PageID = RolePage.ID) or (PageID = DataPage.ID));
end;

function IsRoleDefault(const Value: String): Boolean;
begin
  Result := (Value = '') or (RoleIndex(Value) < 3) or (Value = 'office') or (Value = 'datacenter');
end;

function ValidateInputs: String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to 4 do
    if Pos('"', ConnPage.Values[I]) > 0 then
      Result := 'Isian tidak boleh mengandung tanda kutip (").';
  if Pos('"', DataPage.Values[0]) > 0 then
    Result := 'Folder induk tidak boleh mengandung tanda kutip (").';
  if Result <> '' then
    Exit;
  if Pos('https://', Lowercase(Trim(ConnPage.Values[0]))) <> 1 then
    Result := 'URL server monitoring wajib diawali https:// (agent menolak koneksi tanpa TLS).'
  else if not IsTailscaleUrl(ConnPage.Values[0]) then
    Result := 'URL server monitoring wajib memakai IP Tailscale (100.64.0.0/10, contoh https://100.101.2.3). ' +
      'IP lokal data center atau IP publik tidak diizinkan.'
  else if Trim(ConnPage.Values[1]) = '' then
    Result := 'Agent ID wajib diisi.'
  else if Trim(ConnPage.Values[2]) = '' then
    Result := 'Site wajib diisi.'
  else if (Trim(ConnPage.Values[3]) = '') and not HasToken then
    Result := 'Token agent wajib diisi pada instalasi pertama.';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Error: String;
begin
  Result := True;
  if CurPageID = RolePage.ID then
  begin
    { Follow the chosen role unless the user already typed their own values. }
    if IsRoleDefault(ConnPage.Values[1]) then
      if RolePage.SelectedValueIndex = 3 then
        ConnPage.Values[1] := ''
      else
        ConnPage.Values[1] := RoleCode(RolePage.SelectedValueIndex);
    if IsRoleDefault(ConnPage.Values[2]) then
      ConnPage.Values[2] := RoleSite(RolePage.SelectedValueIndex);
  end;
  if CurPageID = ConnPage.ID then
  begin
    Error := ValidateInputs;
    if Error <> '' then
    begin
      MsgBox(Error, mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := ValidateInputs;
  if Result <> '' then
    Exit;
  { Release WindowsMonitoringAgent.exe so it can be replaced. }
  Exec(PowerShell, '-NoProfile -Command "$s=Get-Service {#ServiceName} -ErrorAction SilentlyContinue; ' +
    'if($s -and $s.Status -ne ''Stopped''){ Stop-Service {#ServiceName} -Force; $s.WaitForStatus(''Stopped'',''00:01:00'') }"',
    '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function CertificateFile: String;
begin
  Result := '';
#ifdef EmbeddedCert
  if WizardIsTaskSelected('trustcert') then
    Result := ExpandConstant('{app}\certs\monitoring.crt');
#else
  Result := Trim(CertPage.Values[0]);
#endif
end;

procedure Configure;
var
  Args, Env, LogFile: String;
  Code: Integer;
begin
  LogFile := ExpandConstant('{app}\install.log');
  Args := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\tools\configure.ps1') + '"' +
    ' -InstallDir "' + ExpandConstant('{app}') + '"' +
    ' -Role ' + RoleCode(RolePage.SelectedValueIndex) +
    ' -ApiBaseUrl "' + Trim(ConnPage.Values[0]) + '"' +
    ' -AgentId "' + Trim(ConnPage.Values[1]) + '"' +
    ' -Site "' + Trim(ConnPage.Values[2]) + '"' +
    ' -DataRoot "' + RemoveBackslash(Trim(DataPage.Values[0])) + '"' +
    ' -LogFile "' + LogFile + '"';
  if CertificateFile <> '' then
    Args := Args + ' -CertFile "' + CertificateFile + '"';
  if not Exec(PowerShell, Args, '', SW_HIDE, ewWaitUntilTerminated, Code) or ((Code <> 0) and (Code <> 2)) then
  begin
    SuppressibleMsgBox('Konfigurasi agent gagal (kode ' + IntToStr(Code) + '). Lihat ' + LogFile + '.', mbError, MB_OK, IDOK);
    Exit;
  end;
  if Code = 2 then
    SuppressibleMsgBox('Agent terpasang, tetapi server monitoring ' + Trim(ConnPage.Values[0]) + ' belum bisa dihubungi dari server ini ' +
      '(Tailscale belum login/terhubung, atau sertifikat TLS belum dipercaya). Data tetap diantrekan dan dikirim setelah koneksi pulih. Detail: ' + LogFile,
      mbInformation, MB_OK, IDOK);

  { The token lives only in the service's own environment: readable by the service, effective without reboot. }
  Env := ServiceEnvironment;
  if Trim(ConnPage.Values[3]) <> '' then
    Env := EnvironmentSet(Env, TokenVar, Trim(ConnPage.Values[3]));
  if Trim(ConnPage.Values[4]) <> '' then
    Env := EnvironmentSet(Env, SyncthingVar, Trim(ConnPage.Values[4]));
  if (Env <> '') and not RegWriteMultiStringValue(HKLM, ServiceKey, 'Environment', Env) then
    SuppressibleMsgBox('Token agent gagal disimpan ke registry service.', mbError, MB_OK, IDOK);

  if WizardIsTaskSelected('startservice') then
    if not Exec(PowerShell, '-NoProfile -Command "Start-Service {#ServiceName} -ErrorAction Stop"', '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
      SuppressibleMsgBox('Service {#ServiceName} gagal dijalankan. Periksa Event Viewer > Windows Logs > Application (sumber WindowsMonitoringAgent).',
        mbError, MB_OK, IDOK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    Configure;
end;
