; Buni Windows Installer
; Requires Inno Setup 6  (pre-installed on GitHub Actions windows-latest)
;
; Build:
;   iscc /DAppVersion=1.3.10 /DExeSource=dist\Buni-Windows.exe windows\installer.iss

#define AppName      "Buni"
#define AppPublisher "EloyYang"
#define AppURL       "https://github.com/EloyYang/buni"

[Setup]
AppId={{B2E45A7C-D891-4F23-A6B0-C3D456789012}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; 관리자 권한 불필요 — 사용자 폴더에 설치
PrivilegesRequired=lowest
OutputDir=.
OutputBaseFilename=Buni-Windows-Setup-{#AppVersion}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
SetupIconFile=buni_icon.ico
UninstallDisplayIcon={app}\buni_icon.ico
UninstallDisplayName={#AppName}

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "바탕화면에 바로 가기 만들기"; Flags: unchecked
Name: "startup";     Description: "Windows 시작 시 자동 실행";   Flags: unchecked

[Files]
Source: "{#ExeSource}"; DestDir: "{app}"; DestName: "Buni-Windows.exe"; Flags: ignoreversion
; 바로가기 아이콘을 exe 리소스에만 맡기지 않고 아이콘 파일도 함께 설치한다 (아이콘 캐시가 낡아도 부니 아이콘으로 보이게)
Source: "buni_icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\{#AppName}"; Filename: "{app}\Buni-Windows.exe"; IconFilename: "{app}\buni_icon.ico"; Comment: "Claude Code 동반자 앱"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\Buni-Windows.exe"; IconFilename: "{app}\buni_icon.ico"; Tasks: desktopicon

[Registry]
; 자동 시작 (선택 시)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "Buni"; \
  ValueData: """{app}\Buni-Windows.exe"""; \
  Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Buni-Windows.exe"; \
  Description: "{#AppName} 시작하기"; \
  Flags: nowait postinstall skipifsilent
; 앱 안에서 업데이트할 때(조용한 설치)는 설치가 끝나면 알아서 다시 시작한다
Filename: "{app}\Buni-Windows.exe"; Flags: nowait runasoriginaluser; Check: WizardSilent

[UninstallRun]
; 제거 전 실행 중인 Buni 종료
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM Buni-Windows.exe"; \
  Flags: runhidden; RunOnceId: "KillBuni"

[Code]
procedure InitializeWizard();
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM Buni-Windows.exe',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
