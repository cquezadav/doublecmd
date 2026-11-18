{
   [my-custom] Linux partitions (ext4, btrfs, xfs...) as drive letters on Windows.

   Shift+right-click a drive button -> "Linux partitions..." runs
   tools\linux\linuxmount.ps1 (next to doublecmd.exe) to list every Linux
   partition (fast: partition table only, no admin, does not start WSL),
   then offers Mount read-only / Mount read-write / Unmount for each one,
   and Share on network (Samba in WSL, smb://<pc>:4450/<name>) for mounted ones.
   Mounting goes through WSL2 (one admin prompt) + rclone/WinFsp; it runs in
   a background thread so the window never freezes, and the drive bar is
   refreshed when it finishes.
}
unit uLinuxMounts;

{$mode objfpc}{$H+}

interface

uses
  Classes;

procedure LinuxPartitionsMenu(X, Y: Integer; OnChanged: TNotifyEvent);
procedure LinuxMountsShutdown;

implementation

uses
  SysUtils, Process, Menus, Forms, Clipbrd, fpjson, jsonparser,
  uShowMsg, uGlobsPaths, uMetrics;

type
  TActionKind = (akMountRO, akMountRW, akUnmount, akShare, akUnshare);

  TLinuxMenu = class(TComponent)
  public
    Menu: TPopupMenu;
    Parts: TJSONArray;
    Data: TJSONData;
    destructor Destroy; override;
    procedure ItemClick(Sender: TObject);
  end;

  TLinuxJob = class(TThread)
  private
    FArgs: array of String;
    FWhat: String;
    FOutput: String;
    FExitCode: Integer;
    procedure Done;
  protected
    procedure Execute; override;
  public
    constructor Create(const Args: array of String; const What: String);
  end;

var
  FOnChanged: TNotifyEvent = nil;
  FMenu: TLinuxMenu = nil;
  FShuttingDown: Boolean = False;

function HelperScript: String;
begin
  Result := gpExePath + 'tools' + PathDelim + 'linux' + PathDelim + 'linuxmount.ps1';
end;

function RunHelper(const Args: array of String; out Output: String): Integer;
var
  Cmd: array of String;
  I: Integer;
begin
  SetLength(Cmd, 5 + Length(Args));
  Cmd[0] := '-NoProfile';
  Cmd[1] := '-NonInteractive';
  Cmd[2] := '-ExecutionPolicy';
  Cmd[3] := 'Bypass';
  Cmd[4] := '-File';
  SetLength(Cmd, Length(Cmd) + 1);
  Cmd[5] := HelperScript;
  for I := 0 to High(Args) do
    Cmd[6 + I] := Args[I];
  Output := '';
  Result := -1;
  RunCommandInDir(gpExePath, 'powershell.exe', Cmd, Output, Result, [poNoConsole]);
end;

{ The script prints one JSON object as its last line. }
function ParseReply(const Output: String): TJSONObject;
var
  L: TStringList;
  I: Integer;
  D: TJSONData;
begin
  Result := nil;
  L := TStringList.Create;
  try
    L.Text := Output;
    for I := L.Count - 1 downto 0 do
      if (Length(Trim(L[I])) > 0) and (Trim(L[I])[1] = '{') then
      begin
        try
          D := GetJSON(Trim(L[I]));
          if D is TJSONObject then Exit(TJSONObject(D));
          D.Free;
        except
        end;
        Break;
      end;
  finally
    L.Free;
  end;
end;

{ ---- background job ---- }

constructor TLinuxJob.Create(const Args: array of String; const What: String);
var
  I: Integer;
begin
  SetLength(FArgs, Length(Args));
  for I := 0 to High(Args) do FArgs[I] := Args[I];
  FWhat := What;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TLinuxJob.Execute;
begin
  FExitCode := RunHelper(FArgs, FOutput);
  if not FShuttingDown then
    Synchronize(@Done);
end;

procedure TLinuxJob.Done;
var
  R: TJSONObject;
  Msg: String;
begin
  if FShuttingDown then Exit;
  R := ParseReply(FOutput);
  try
    if Assigned(R) and R.Get('ok', False) then
    begin
      if R.IndexOfName('url') >= 0 then
      begin
        Clipboard.AsText := R.Get('url', '');
        Msg := R.Get('message', '') + LineEnding + '(address copied to the clipboard)';
        msgToast(Msg, 15000);
        Msg := '';
      end
      else if R.IndexOfName('letter') >= 0 then
        Msg := Format('%s on %s', [FWhat, R.Get('letter', '')]) +
               LineEnding + R.Get('label', '')
      else
        Msg := R.Get('message', FWhat + ' done');
      if Msg <> '' then msgToast(Msg, 4000);
    end
    else if Assigned(R) then
      msgToast(FWhat + ' failed:' + LineEnding + R.Get('error', R.Get('message', '?')), 6000)
    else
      msgToast(FWhat + ' failed (no reply from helper)', 6000);
    MetricsLog('linux_mount', ['what', FWhat, 'ok', Assigned(R) and R.Get('ok', False)]);
  finally
    R.Free;
  end;
  if Assigned(FOnChanged) then FOnChanged(nil);
end;

{ ---- menu ---- }

destructor TLinuxMenu.Destroy;
begin
  Data.Free;
  inherited Destroy;
end;

procedure TLinuxMenu.ItemClick(Sender: TObject);
var
  Item: TMenuItem;
  P: TJSONObject;
  Idx: Integer;
  Kind: TActionKind;
  Disk, Part: String;
begin
  Item := Sender as TMenuItem;
  Idx := Item.Tag div 8;
  Kind := TActionKind(Item.Tag mod 8);
  if (Idx < 0) or (Idx >= Parts.Count) then Exit;
  P := Parts.Objects[Idx];
  Disk := IntToStr(P.Get('disk', -1));
  Part := IntToStr(P.Get('partition', -1));
  case Kind of
    akMountRO:
      begin
        msgToast('Mounting (read-only)...' + LineEnding + 'Approve the Windows admin prompt.', 5000);
        TLinuxJob.Create(['mount', '-Disk', Disk, '-Partition', Part], 'Mounted read-only');
      end;
    akMountRW:
      begin
        msgToast('Mounting (read/write)...' + LineEnding + 'Approve the Windows admin prompt.', 5000);
        TLinuxJob.Create(['mount', '-Disk', Disk, '-Partition', Part, '-ReadWrite'], 'Mounted read/write');
      end;
    akUnmount:
      begin
        msgToast('Releasing ' + P.Get('letter', '') + '...' + LineEnding + 'Approve the Windows admin prompt.', 5000);
        TLinuxJob.Create(['unmount', '-Disk', Disk, '-Partition', Part], 'Unmount');
      end;
    akShare:
      begin
        msgToast('Sharing ' + P.Get('letter', '') + ' on the network...' + LineEnding +
                 'The first time Samba is set up in WSL; approve the admin prompt if one appears.', 6000);
        TLinuxJob.Create(['share', '-Disk', Disk, '-Partition', Part], 'Share');
      end;
    akUnshare:
      TLinuxJob.Create(['unshare', '-Disk', Disk, '-Partition', Part], 'Stop sharing');
  end;
end;

procedure LinuxPartitionsMenu(X, Y: Integer; OnChanged: TNotifyEvent);
var
  Output: String;
  R, Pre, P: TJSONObject;
  Missing: TJSONArray;
  I: Integer;
  Head, Sub: TMenuItem;
  Caption, Letter: String;

  procedure AddSub(const ACaption: String; Kind: TActionKind; AEnabled: Boolean);
  var
    mi: TMenuItem;
  begin
    mi := TMenuItem.Create(Head);
    mi.Caption := ACaption;
    mi.Tag := I * 8 + Ord(Kind);
    mi.Enabled := AEnabled;
    mi.OnClick := @FMenu.ItemClick;
    Head.Add(mi);
  end;

begin
  FOnChanged := OnChanged;
  if not FileExists(HelperScript) then
  begin
    msgToast('Helper not found:' + LineEnding + HelperScript, 5000);
    Exit;
  end;

  msgBusyBegin('  Looking for Linux partitions...  ');
  try
    RunHelper(['list'], Output);
  finally
    msgBusyEnd;
  end;

  R := ParseReply(Output);
  if not Assigned(R) then
  begin
    msgToast('Could not list Linux partitions.', 4000);
    Exit;
  end;
  if not R.Get('ok', False) then
  begin
    msgToast('Could not list Linux partitions:' + LineEnding + R.Get('error', '?'), 5000);
    R.Free;
    Exit;
  end;

  Pre := R.Objects['prereqs'];
  if not Pre.Get('ok', False) then
  begin
    Missing := Pre.Arrays['missing'];
    Caption := '';
    for I := 0 to Missing.Count - 1 do
      Caption := Caption + LineEnding + '- ' + Missing.Strings[I];
    msgToast('To mount Linux partitions, install:' + Caption, 7000);
    R.Free;
    Exit;
  end;

  if R.Arrays['partitions'].Count = 0 then
  begin
    msgToast('No Linux partitions found on the connected disks.', 3000);
    R.Free;
    Exit;
  end;

  FreeAndNil(FMenu);
  FMenu := TLinuxMenu.Create(nil);
  FMenu.Data := R;
  FMenu.Parts := R.Arrays['partitions'];
  FMenu.Menu := TPopupMenu.Create(FMenu);

  for I := 0 to FMenu.Parts.Count - 1 do
  begin
    P := FMenu.Parts.Objects[I];
    Letter := P.Get('letter', '');
    Caption := Format('%s  -  disk %d, partition %d  -  %s GB  -  %s',
      [P.Get('disk_name', '?'), P.Get('disk', 0), P.Get('partition', 0),
       FormatFloat('0.#', P.Get('size_gb', 0.0)), P.Get('type', '')]);
    if Letter <> '' then
      Caption := Caption + '  [on ' + Letter + ' ' + P.Get('label', '') +
                 BoolToStr(P.Get('shared', False), ', shared on network', '') + ']'
    else if not P.Get('mountable', False) then
      Caption := Caption + '  (' + P.Get('reason', 'not mountable') + ')'
    else if P.Get('hides', '') <> '' then
      Caption := Caption + '  (hides ' + P.Get('hides', '') + ' while mounted)';
    Head := TMenuItem.Create(FMenu.Menu);
    Head.Caption := StringReplace(Caption, '&', '&&', [rfReplaceAll]);
    FMenu.Menu.Items.Add(Head);
    if not P.Get('mountable', False) then
    begin
      Head.Enabled := False;
      Continue;
    end;
    AddSub('Mount read-only', akMountRO, Letter = '');
    AddSub('Mount read/write', akMountRW, Letter = '');
    Sub := TMenuItem.Create(Head);
    Sub.Caption := '-';
    Head.Add(Sub);
    AddSub('Unmount (release the disk)', akUnmount, Letter <> '');
    Sub := TMenuItem.Create(Head);
    Sub.Caption := '-';
    Head.Add(Sub);
    AddSub('Share on network (smb, port 4450)', akShare, (Letter <> '') and not P.Get('shared', False));
    AddSub('Stop sharing ' + P.Get('share_name', ''), akUnshare, P.Get('shared', False));
  end;
  FMenu.Menu.PopUp(X, Y);
end;

procedure LinuxMountsShutdown;
begin
  FShuttingDown := True;
  FOnChanged := nil;
  FreeAndNil(FMenu);
end;

end.
