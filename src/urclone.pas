{
   Double Commander (my-custom)
   -------------------------------------------------------------------------
   Copy / move / sync / compare through rclone (https://rclone.org).
   Works the same on Windows, macOS and Linux.

   Why: rclone verifies every copied file with a checksum, resumes after a
   dropped network connection, skips files that are already identical, and
   talks to cloud services directly instead of going through a mounted
   drive's local cache.

   Mounted cloud drives are mapped back to their rclone remote with
   <config dir>/rclone.json, for example:
     "rclone": "",  "mounts":  "X:\\": "gdrive:",  "W:\\": "onedrive:"
   (a JSON object with a "mounts" object inside).
   ("rclone" may hold the full path of rclone if it is not found by itself.)
}
unit uRclone;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Menus;

type
  TRcloneOp = (roCopy, roMove, roSync, roCheck);

const
  RcloneMenuCaption = 'rclone (verified copy / sync)';
  RcloneCaptions: array[TRcloneOp] of String = (
    'Copy to other panel (verified)',
    'Move to other panel (verified)',
    'Sync folder to other panel...',
    'Compare with other panel (checksums)');
  RcloneCommands: array[TRcloneOp] of String = (
    'cm_RcloneCopy', 'cm_RcloneMove', 'cm_RcloneSync', 'cm_RcloneCheck');

function RcloneExe: String;
procedure RcloneRun(Op: TRcloneOp);
procedure RcloneFillMenu(Parent: TMenuItem);

implementation

uses
  Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Graphics, Process, StrUtils,
  fpjson, jsonparser, uGlobsPaths, uShowMsg, uMetrics, uFile, uFileView,
  uFileSystemFileSource, fMain;

const
  MaxLogLines = 3000;

type
  TStepKind = (skRun, skPreview, skCheck);

  TRcloneStep = class
    Kind: TStepKind;
    Args: TStringList;
    constructor Create(AKind: TStepKind; const AArgs: array of String);
    destructor Destroy; override;
  end;

  TfrmRclone = class;

  { TRcloneJob: runs the steps one after another in the background }

  TRcloneJob = class(TThread)
  private
    FForm: TfrmRclone;
    FSteps: TList;
    FCancel: Boolean;
    FStep: TRcloneStep;
    FLog: TStringList;          // lines waiting to be shown
    FLogged: Integer;
    // progress of the current step
    FBytes, FTotalBytes: Int64;
    FSpeed: Double;
    FEta: Integer;
    FFiles, FTotalFiles, FChecks, FTotalChecks: Int64;
    FCurrent: String;
    // totals
    FAllBytes: Int64;
    FErrors: Integer;
    FFailedSteps: Integer;
    // sync preview
    FPrevCopy, FPrevDelete: Integer;
    FPrevBytes: Int64;
    FPrevDeleted: TStringList;
    FConfirmed: Boolean;
    // compare
    FSame, FOnlyA, FOnlyB, FDiffer, FUnreadable: Integer;
    procedure AddLog(const S: String);
    procedure HandleLine(const L: String);
    function RunStep(Step: TRcloneStep): Integer;
    procedure SyncStats;
    procedure SyncFlush;
    procedure SyncAskSync;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TfrmRclone; ASteps: TList);
    destructor Destroy; override;
    procedure Cancel;
  end;

  { TfrmRclone: progress window (one per job, not modal) }

  TfrmRclone = class(TForm)
  private
    FOp: TRcloneOp;
    FJob: TRcloneJob;
    FSteps: TList;
    FStart: QWord;
    FCloseWhenDone: Boolean;
    FPathA, FPathB: String;
    LblWhat, LblInfo, LblFile, LblResult: TLabel;
    Bar: TProgressBar;
    Memo: TMemo;
    BtnStop, BtnClose: TButton;
    procedure BtnStopClick(Sender: TObject);
    procedure BtnCloseClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure JobDone(Sender: TObject);
    procedure AutoClose(Data: PtrInt);
  public
    constructor CreateJob(AOp: TRcloneOp; const What, APathA, APathB: String; ASteps: TList);
    destructor Destroy; override;
  end;

  TRcloneMenuHandler = class
    procedure Click(Sender: TObject);
  end;

var
  FExe: String = '';
  FExeSearched: Boolean = False;
  FMounts: TStringList = nil;     // Name = local prefix, Value = remote
  FCfgAge: LongInt = -2;
  FMenuHandler: TRcloneMenuHandler = nil;

{ ---------------------------------------------------------------- config }

function CfgFile: String;
begin
  Result := gpCfgDir + 'rclone.json';
end;

procedure LoadConfig;
var
  Age: LongInt;
  SL: TStringList;
  J: TJSONData;
  M: TJSONObject;
  I: Integer;
begin
  Age := FileAge(CfgFile);
  if (FMounts <> nil) and (Age = FCfgAge) then Exit;
  FCfgAge := Age;
  if FMounts = nil then FMounts := TStringList.Create;
  FMounts.Clear;
  if Age = -1 then Exit;
  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(CfgFile);
      J := GetJSON(SL.Text);
      try
        if J is TJSONObject then
        begin
          if TJSONObject(J).Get('rclone', '') <> '' then
          begin
            FExe := TJSONObject(J).Get('rclone', '');
            FExeSearched := True;
          end;
          M := TJSONObject(J).Get('mounts', TJSONObject(nil));
          if M <> nil then
            for I := 0 to M.Count - 1 do
              FMounts.Values[IncludeTrailingPathDelimiter(M.Names[I])] := M.Items[I].AsString;
        end;
      finally
        J.Free;
      end;
    except
      // a broken config just means "no mounted drives are mapped"
    end;
  finally
    SL.Free;
  end;
end;

function RcloneExe: String;
{$IFDEF MSWINDOWS}
var
  Base: String;
  SR, SR2: TSearchRec;
{$ENDIF}
begin
  LoadConfig;
  if not FExeSearched then
  begin
    FExeSearched := True;
{$IFDEF MSWINDOWS}
    FExe := ExeSearch('rclone.exe', SysUtils.GetEnvironmentVariable('PATH'));
    Base := SysUtils.GetEnvironmentVariable('LOCALAPPDATA') + '\Microsoft\WinGet\';
    if (FExe = '') and FileExists(Base + 'Links\rclone.exe') then
      FExe := Base + 'Links\rclone.exe';
    if (FExe = '') and (FindFirst(Base + 'Packages\Rclone.Rclone*', faDirectory, SR) = 0) then
    try
      if FindFirst(Base + 'Packages\' + SR.Name + '\rclone-*', faDirectory, SR2) = 0 then
      try
        if FileExists(Base + 'Packages\' + SR.Name + '\' + SR2.Name + '\rclone.exe') then
          FExe := Base + 'Packages\' + SR.Name + '\' + SR2.Name + '\rclone.exe';
      finally
        FindClose(SR2);
      end;
    finally
      FindClose(SR);
    end;
    if (FExe = '') and FileExists(SysUtils.GetEnvironmentVariable('ProgramFiles') + '\rclone\rclone.exe') then
      FExe := SysUtils.GetEnvironmentVariable('ProgramFiles') + '\rclone\rclone.exe';
{$ELSE}
    FExe := ExeSearch('rclone', SysUtils.GetEnvironmentVariable('PATH'));
    if (FExe = '') and FileExists('/opt/homebrew/bin/rclone') then FExe := '/opt/homebrew/bin/rclone';
    if (FExe = '') and FileExists('/usr/local/bin/rclone') then FExe := '/usr/local/bin/rclone';
    if (FExe = '') and FileExists('/usr/bin/rclone') then FExe := '/usr/bin/rclone';
{$ENDIF}
  end;
  Result := FExe;
end;

// Local path -> what rclone should use. A path on a mounted cloud drive is
// sent straight to the cloud remote (no local cache in between).
function ToRclone(const Path: String; out Remote: Boolean): String;
var
  I: Integer;
  Prefix, Rest: String;
begin
  LoadConfig;
  Remote := False;
  Result := ExcludeTrailingPathDelimiter(Path);
  if (Length(Result) = 2) and (Result[2] = ':') then
    Result := Result + PathDelim;           // keep "C:\" as a drive root
  for I := 0 to FMounts.Count - 1 do
  begin
    Prefix := FMounts.Names[I];
    if AnsiStartsText(Prefix, IncludeTrailingPathDelimiter(Path)) then
    begin
      Rest := Copy(Path, Length(Prefix) + 1, MaxInt);
      Rest := ExcludeTrailingPathDelimiter(StringReplace(Rest, '\', '/', [rfReplaceAll]));
      Result := FMounts.ValueFromIndex[I] + Rest;
      Remote := True;
      Exit;
    end;
  end;
end;

function R(const Path: String): String;
var
  Dummy: Boolean;
begin
  Result := ToRclone(Path, Dummy);
end;

function Describe(const Path: String): String;
var
  Remote: Boolean;
  S: String;
begin
  S := ToRclone(Path, Remote);
  Result := Path;
  if Remote then
    Result := Result + '   (sent directly to ' + S + ')';
end;

function SizeText(B: Double): String;
begin
  if B >= 1024.0 * 1024 * 1024 then Result := Format('%.2f GB', [B / (1024.0 * 1024 * 1024)])
  else if B >= 1024.0 * 1024 then Result := Format('%.1f MB', [B / (1024.0 * 1024)])
  else if B >= 1024 then Result := Format('%.0f KB', [B / 1024])
  else Result := Format('%.0f bytes', [B]);
end;

function TimeText(Secs: Integer): String;
begin
  if Secs < 0 then Exit('');
  if Secs < 60 then Result := Format('%d s', [Secs])
  else if Secs < 3600 then Result := Format('%d min %d s', [Secs div 60, Secs mod 60])
  else Result := Format('%d h %d min', [Secs div 3600, (Secs mod 3600) div 60]);
end;

{ ---------------------------------------------------------------- steps }

constructor TRcloneStep.Create(AKind: TStepKind; const AArgs: array of String);
var
  S: String;
begin
  Kind := AKind;
  Args := TStringList.Create;
  for S in AArgs do Args.Add(S);
  Args.Add('--use-json-log');
  if AKind <> skPreview then
  begin
    Args.Add('--stats');
    Args.Add('1s');
    Args.Add('--stats-log-level');
    Args.Add('NOTICE');
  end;
  if AKind = skRun then Args.Add('-v');   // one line per copied file
end;

destructor TRcloneStep.Destroy;
begin
  Args.Free;
  inherited Destroy;
end;

{ ---------------------------------------------------------------- job }

constructor TRcloneJob.Create(AForm: TfrmRclone; ASteps: TList);
begin
  FForm := AForm;
  FSteps := ASteps;
  FLog := TStringList.Create;
  FPrevDeleted := TStringList.Create;
  FreeOnTerminate := False;
  inherited Create(True);
end;

destructor TRcloneJob.Destroy;
begin
  FLog.Free;
  FPrevDeleted.Free;
  inherited Destroy;
end;

procedure TRcloneJob.Cancel;
begin
  FCancel := True;
end;

procedure TRcloneJob.AddLog(const S: String);
begin
  if FLogged = MaxLogLines then
    FLog.Add('... (more lines not shown)')
  else if FLogged < MaxLogLines then
    FLog.Add(S);
  Inc(FLogged);
  if FLog.Count >= 200 then Synchronize(@SyncFlush);
end;

procedure TRcloneJob.HandleLine(const L: String);
var
  J: TJSONData;
  O, St: TJSONObject;
  T: TJSONArray;
  Level, Msg, Obj, Skipped: String;
begin
  if L = '' then Exit;
  // "rclone check --combined -" result lines: "= path", "+ path" ...
  if (FStep.Kind = skCheck) and (Length(L) > 2) and (L[2] = ' ') and (L[1] in ['=', '+', '-', '*', '!']) then
  begin
    case L[1] of
      '=': Inc(FSame);
      '+': begin Inc(FOnlyA); AddLog('only in A      ' + Copy(L, 3, MaxInt)); end;
      '-': begin Inc(FOnlyB); AddLog('only in B      ' + Copy(L, 3, MaxInt)); end;
      '*': begin Inc(FDiffer); AddLog('DIFFERENT      ' + Copy(L, 3, MaxInt)); end;
      '!': begin Inc(FUnreadable); AddLog('could not read ' + Copy(L, 3, MaxInt)); end;
    end;
    Exit;
  end;
  if L[1] <> '{' then
  begin
    AddLog(L);
    Exit;
  end;
  try
    J := GetJSON(L);
  except
    AddLog(L);
    Exit;
  end;
  try
    if not (J is TJSONObject) then Exit;
    O := TJSONObject(J);
    St := O.Get('stats', TJSONObject(nil));
    if St <> nil then
    begin
      FBytes := St.Get('bytes', Int64(0));
      FTotalBytes := St.Get('totalBytes', Int64(0));
      FSpeed := St.Get('speed', 0.0);
      if (St.Find('eta') <> nil) and (St.Find('eta').JSONType = jtNumber) then
        FEta := St.Find('eta').AsInteger
      else
        FEta := -1;
      FFiles := St.Get('transfers', Int64(0));
      FTotalFiles := St.Get('totalTransfers', Int64(0));
      FChecks := St.Get('checks', Int64(0));
      FTotalChecks := St.Get('totalChecks', Int64(0));
      FCurrent := '';
      T := St.Get('transferring', TJSONArray(nil));
      if (T <> nil) and (T.Count > 0) and (T.Items[0] is TJSONObject) then
        FCurrent := TJSONObject(T.Items[0]).Get('name', '');
      Synchronize(@SyncStats);
      Exit;
    end;
    Level := O.Get('level', '');
    Msg := O.Get('msg', '');
    Obj := O.Get('object', '');
    if FStep.Kind = skPreview then
    begin
      Skipped := O.Get('skipped', '');
      if Skipped = 'copy' then
      begin
        Inc(FPrevCopy);
        FPrevBytes := FPrevBytes + O.Get('size', Int64(0));
      end
      else if Skipped = 'delete' then
      begin
        Inc(FPrevDelete);
        if FPrevDeleted.Count < 12 then FPrevDeleted.Add(Obj);
      end
      else if Level = 'error' then
        AddLog('ERROR  ' + Obj + ': ' + Msg);
      Exit;
    end;
    // compare: per-file problems already arrive as "+ / - / *" lines
    if (FStep.Kind = skCheck) and (Level = 'error') and (Obj <> '') then Exit;
    if Level = 'error' then
    begin
      Inc(FErrors);
      if Obj <> '' then AddLog('ERROR  ' + Obj + ': ' + Msg) else AddLog('ERROR  ' + Msg);
    end
    else if (FStep.Kind = skCheck) and (Pos('/', Obj) = 0) and (Pos('\', Obj) = 0) and (Pos(' at ', Obj) > 0) then
      AddLog(Msg)                           // summary lines like "3 differences found"
    else if Pos('directory modification time', Msg) > 0 then
      // not interesting for people
    else if (FStep.Kind = skRun) and (Obj <> '') and (Level = 'info') then
      AddLog(Obj + '  -  ' + Msg)           // "Copied (new)", "Moved", "Deleted"...
    else if (Level = 'notice') and (FStep.Kind = skRun) then
      AddLog(Trim(Obj + '  ' + Msg));
  finally
    J.Free;
  end;
end;

function TRcloneJob.RunStep(Step: TRcloneStep): Integer;
var
  P: TProcess;
  Buf, Chunk: String;
  N, I: Integer;
begin
  FStep := Step;
  FBytes := 0; FTotalBytes := 0; FFiles := 0; FTotalFiles := 0;
  FChecks := 0; FTotalChecks := 0; FEta := -1; FSpeed := 0; FCurrent := '';
  P := TProcess.Create(nil);
  try
    P.Executable := RcloneExe;
    P.Parameters.Assign(Step.Args);
    P.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    try
      P.Execute;
    except
      on E: Exception do
      begin
        AddLog('ERROR  could not start rclone: ' + E.Message);
        Inc(FErrors);
        Exit(-1);
      end;
    end;
    Buf := '';
    while True do
    begin
      N := P.Output.NumBytesAvailable;
      if N > 0 then
      begin
        SetLength(Chunk, N);
        N := P.Output.Read(Chunk[1], N);
        Buf := Buf + Copy(Chunk, 1, N);
        I := Pos(#10, Buf);
        while I > 0 do
        begin
          HandleLine(TrimRight(Copy(Buf, 1, I - 1)));
          Delete(Buf, 1, I);
          I := Pos(#10, Buf);
        end;
      end
      else if not P.Running then
        Break
      else
        Sleep(40);
      if FCancel and P.Running then
        P.Terminate(1);
    end;
    HandleLine(TrimRight(Buf));
    Result := P.ExitCode;
    if Step.Kind = skRun then FAllBytes := FAllBytes + FBytes;
  finally
    P.Free;
  end;
end;

procedure TRcloneJob.Execute;
var
  I, Code: Integer;
  Step: TRcloneStep;
begin
  for I := 0 to FSteps.Count - 1 do
  begin
    if FCancel then Break;
    Step := TRcloneStep(FSteps[I]);
    if Step.Kind = skPreview then AddLog('Working out what needs to change ...');
    Code := RunStep(Step);
    if FCancel then Break;
    if Step.Kind = skPreview then
    begin
      if Code <> 0 then
      begin
        Inc(FFailedSteps);
        AddLog('Could not compare the folders, nothing was changed.');
        Break;
      end;
      if (FPrevCopy = 0) and (FPrevDelete = 0) then
      begin
        AddLog('Already identical: nothing to copy or delete.');
        Break;
      end;
      Synchronize(@SyncAskSync);
      if not FConfirmed then
      begin
        FCancel := True;
        Break;
      end;
    end
    else if (Code <> 0) and not ((Step.Kind = skCheck) and (Code = 1)) then
      Inc(FFailedSteps);
  end;
  Synchronize(@SyncFlush);
end;

procedure TRcloneJob.SyncFlush;
begin
  if FLog.Count = 0 then Exit;
  FForm.Memo.Lines.BeginUpdate;
  try
    FForm.Memo.Lines.AddStrings(FLog);
  finally
    FForm.Memo.Lines.EndUpdate;
  end;
  FLog.Clear;
  FForm.Memo.SelStart := Length(FForm.Memo.Text);
end;

procedure TRcloneJob.SyncStats;
var
  S: String;
begin
  SyncFlush;
  if FStep.Kind = skCheck then
  begin
    if FTotalChecks > 0 then
      FForm.Bar.Position := Round(1000 * FChecks / FTotalChecks);
    FForm.LblInfo.Caption := Format('Compared %d of %d files', [FChecks, FTotalChecks]);
    Exit;
  end;
  if FTotalBytes > 0 then
    FForm.Bar.Position := Round(1000 * FBytes / FTotalBytes)
  else if FTotalFiles > 0 then
    FForm.Bar.Position := Round(1000 * FFiles / FTotalFiles);
  S := SizeText(FBytes) + ' of ' + SizeText(FTotalBytes);
  if FSpeed > 0 then S := S + '    ' + SizeText(FSpeed) + '/s';
  if FEta >= 0 then S := S + '    about ' + TimeText(FEta) + ' left';
  S := S + Format('    files %d / %d', [FFiles, FTotalFiles]);
  FForm.LblInfo.Caption := S;
  if FCurrent <> '' then
    FForm.LblFile.Caption := FCurrent
  else if (FTotalChecks > 0) and (FChecks < FTotalChecks) then
    FForm.LblFile.Caption := Format('checking existing files %d / %d', [FChecks, FTotalChecks])
  else
    FForm.LblFile.Caption := '';
end;

procedure TRcloneJob.SyncAskSync;
var
  Msg: String;
  I: Integer;
begin
  SyncFlush;
  Msg := 'Make B an exact copy of A:' + LineEnding + LineEnding +
         'A  ' + FForm.FPathA + LineEnding +
         'B  ' + FForm.FPathB + LineEnding + LineEnding +
         Format('Copy or update %d file(s) in B (%s)', [FPrevCopy, SizeText(FPrevBytes)]) + LineEnding;
  if FPrevDelete > 0 then
  begin
    Msg := Msg + Format('DELETE %d file(s) from B that are not in A:', [FPrevDelete]) + LineEnding;
    for I := 0 to FPrevDeleted.Count - 1 do
      Msg := Msg + '    ' + FPrevDeleted[I] + LineEnding;
    if FPrevDelete > FPrevDeleted.Count then
      Msg := Msg + Format('    ... and %d more', [FPrevDelete - FPrevDeleted.Count]) + LineEnding;
  end;
  Msg := Msg + LineEnding + 'Continue?';
  FConfirmed := msgYesNo(Msg, msmbNo);
  if FConfirmed then
    AddLog(Format('Syncing: %d to copy, %d to delete', [FPrevCopy, FPrevDelete]))
  else
    AddLog('Cancelled, nothing was changed.');
end;

{ ---------------------------------------------------------------- form }

constructor TfrmRclone.CreateJob(AOp: TRcloneOp; const What, APathA, APathB: String; ASteps: TList);
var
  Pnl: TPanel;
begin
  inherited CreateNew(Application);
  FOp := AOp;
  FSteps := ASteps;
  FPathA := APathA;
  FPathB := APathB;
  Caption := 'rclone - ' + RcloneCaptions[AOp];
  Width := 760;
  Height := 440;
  Position := poMainFormCenter;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  OnCloseQuery := @FormCloseQuery;
  OnClose := @FormClose;

  LblWhat := TLabel.Create(Self);
  LblWhat.Parent := Self;
  LblWhat.Align := alTop;
  LblWhat.BorderSpacing.Around := 8;
  LblWhat.WordWrap := True;
  LblWhat.Font.Style := [fsBold];
  LblWhat.Caption := What;

  Bar := TProgressBar.Create(Self);
  Bar.Parent := Self;
  Bar.Align := alTop;
  Bar.Top := 200;
  Bar.Height := 22;
  Bar.Max := 1000;
  Bar.BorderSpacing.Left := 8;
  Bar.BorderSpacing.Right := 8;

  LblInfo := TLabel.Create(Self);
  LblInfo.Parent := Self;
  LblInfo.Align := alTop;
  LblInfo.Top := 300;
  LblInfo.BorderSpacing.Left := 8;
  LblInfo.BorderSpacing.Top := 4;
  LblInfo.Caption := 'Starting ...';

  LblFile := TLabel.Create(Self);
  LblFile.Parent := Self;
  LblFile.Align := alTop;
  LblFile.Top := 400;
  LblFile.BorderSpacing.Left := 8;
  LblFile.Font.Color := clGrayText;
  LblFile.Caption := '';

  Pnl := TPanel.Create(Self);
  Pnl.Parent := Self;
  Pnl.Align := alBottom;
  Pnl.Height := 44;
  Pnl.BevelOuter := bvNone;

  LblResult := TLabel.Create(Self);
  LblResult.Parent := Pnl;
  LblResult.Left := 8;
  LblResult.Top := 12;
  LblResult.Font.Style := [fsBold];
  LblResult.Caption := '';

  BtnClose := TButton.Create(Self);
  BtnClose.Parent := Pnl;
  BtnClose.Caption := 'Close';
  BtnClose.Width := 100;
  BtnClose.Anchors := [akTop, akRight];
  BtnClose.Left := Pnl.ClientWidth - 108;
  BtnClose.Top := 8;
  BtnClose.Enabled := False;
  BtnClose.OnClick := @BtnCloseClick;

  BtnStop := TButton.Create(Self);
  BtnStop.Parent := Pnl;
  BtnStop.Caption := 'Stop';
  BtnStop.Width := 100;
  BtnStop.Anchors := [akTop, akRight];
  BtnStop.Left := Pnl.ClientWidth - 216;
  BtnStop.Top := 8;
  BtnStop.OnClick := @BtnStopClick;

  Memo := TMemo.Create(Self);
  Memo.Parent := Self;
  Memo.Align := alClient;
  Memo.BorderSpacing.Around := 8;
  Memo.ReadOnly := True;
  Memo.ScrollBars := ssAutoBoth;
  Memo.WordWrap := False;

  Show;
  FStart := GetTickCount64;
  FJob := TRcloneJob.Create(Self, FSteps);
  FJob.OnTerminate := @JobDone;
  FJob.Start;
end;

destructor TfrmRclone.Destroy;
var
  I: Integer;
begin
  if Assigned(FJob) then
  begin
    FJob.Cancel;
    FJob.WaitFor;
    FreeAndNil(FJob);
  end;
  if Assigned(FSteps) then
  begin
    for I := 0 to FSteps.Count - 1 do
      TObject(FSteps[I]).Free;
    FSteps.Free;
  end;
  inherited Destroy;
end;

procedure TfrmRclone.BtnStopClick(Sender: TObject);
begin
  if Assigned(FJob) then
  begin
    FJob.Cancel;
    BtnStop.Enabled := False;
    LblInfo.Caption := 'Stopping ...';
  end;
end;

procedure TfrmRclone.BtnCloseClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmRclone.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if Assigned(FJob) and not FJob.Finished then
  begin
    CanClose := False;
    if msgYesNo('Stop this rclone job?' + LineEnding +
                'Files already copied stay where they are; running it again continues where it stopped.', msmbNo) then
    begin
      FCloseWhenDone := True;
      BtnStopClick(nil);
    end;
  end;
end;

procedure TfrmRclone.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
end;

procedure TfrmRclone.AutoClose(Data: PtrInt);
begin
  Close;
end;

procedure TfrmRclone.JobDone(Sender: TObject);
const
  OpNames: array[TRcloneOp] of String = ('copy', 'move', 'sync', 'compare');
var
  Ok: Boolean;
  Summary: String;
  Ms: QWord;
begin
  Ms := GetTickCount64 - FStart;
  BtnStop.Visible := False;
  BtnClose.Enabled := True;
  Bar.Position := Bar.Max;
  Ok := (FJob.FErrors = 0) and (FJob.FFailedSteps = 0) and not FJob.FCancel;
  if FOp = roCheck then
  begin
    Summary := Format('Same: %d    Different: %d    Only in A: %d    Only in B: %d',
                      [FJob.FSame, FJob.FDiffer, FJob.FOnlyA, FJob.FOnlyB]);
    if FJob.FUnreadable > 0 then
      Summary := Summary + Format('    Unreadable: %d', [FJob.FUnreadable]);
    LblInfo.Caption := Summary;
    Ok := Ok and (FJob.FDiffer + FJob.FOnlyA + FJob.FOnlyB + FJob.FUnreadable = 0) and (FJob.FFailedSteps = 0);
    if FJob.FCancel then LblResult.Caption := 'Stopped'
    else if Ok then LblResult.Caption := 'Identical: every file matches'
    else LblResult.Caption := 'The folders are different (see the list)';
  end
  else
  begin
    if FJob.FCancel then
      LblResult.Caption := 'Stopped. Run it again to continue where it stopped.'
    else if Ok then
      LblResult.Caption := 'Done: ' + SizeText(FJob.FAllBytes) + ' transferred, every file verified'
    else
      LblResult.Caption := Format('Finished with %d error(s), see the list', [FJob.FErrors + FJob.FFailedSteps]);
  end;
  if Ok then LblResult.Font.Color := clGreen else LblResult.Font.Color := clRed;
  LblFile.Caption := '';
  Memo.Lines.Add('');
  Memo.Lines.Add(LblResult.Caption + Format('   (%s)', [TimeText(Ms div 1000)]));
  MetricsLog('rclone', ['op', OpNames[FOp], 'bytes', FJob.FAllBytes, 'ms', Int64(Ms),
                        'errors', FJob.FErrors + FJob.FFailedSteps, 'cancelled', FJob.FCancel]);

  if FOp <> roCheck then
  try
    frmMain.FrameLeft.Reload(True);
    frmMain.FrameRight.Reload(True);
  except
  end;

  if FCloseWhenDone then
    Application.QueueAsyncCall(@AutoClose, 0)
  else if Ok and (FOp in [roCopy, roMove]) then
  begin
    msgToast('rclone: ' + LblResult.Caption, 4000);
    Application.QueueAsyncCall(@AutoClose, 0);
  end
  else if not Active then
    msgToast('rclone ' + OpNames[FOp] + ': ' + LblResult.Caption, 5000);
end;

{ ---------------------------------------------------------------- start }

procedure RcloneRun(Op: TRcloneOp);
var
  Src, Dst: TFileView;
  Files: TFiles;
  F: TFile;
  SrcDir, DstDir, A, B, What: String;
  Steps: TList;
  I, Count: Integer;
  IsDir: Boolean;
begin
  if RcloneExe = '' then
  begin
    msgError('rclone was not found.' + LineEnding + LineEnding +
             'Install it from https://rclone.org/downloads/' + LineEnding +
             '  Windows: winget install Rclone.Rclone' + LineEnding +
             '  macOS:   brew install rclone' + LineEnding +
             '  Linux:   your package manager (e.g. sudo apt install rclone)' + LineEnding + LineEnding +
             'or put its full path in ' + CfgFile);
    Exit;
  end;
  Src := frmMain.ActiveFrame;
  Dst := frmMain.NotActiveFrame;
  if not (Src.FileSource.IsClass(TFileSystemFileSource) and Dst.FileSource.IsClass(TFileSystemFileSource)) then
  begin
    msgError('rclone works with normal folders and drives (including mounted cloud drives) in both panels, ' +
             'not inside archives, FTP or plugin views.');
    Exit;
  end;
  SrcDir := IncludeTrailingPathDelimiter(Src.CurrentPath);
  DstDir := IncludeTrailingPathDelimiter(Dst.CurrentPath);

  Files := Src.CloneSelectedOrActiveFiles;
  Steps := TList.Create;
  try
    if Op in [roCopy, roMove] then
    begin
      if SameFileName(SrcDir, DstDir) then
      begin
        msgError('Both panels show the same folder. Open the destination in the other panel first.');
        Exit;
      end;
      Count := 0;
      for I := 0 to Files.Count - 1 do
      begin
        F := Files[I];
        if F.Name = '..' then Continue;
        IsDir := F.IsDirectory or F.IsLinkToDirectory;
        if IsDir and AnsiStartsText(IncludeTrailingPathDelimiter(F.FullPath), DstDir) then
        begin
          msgError('Cannot copy the folder "' + F.Name + '" into itself.');
          Exit;
        end;
        Inc(Count);
        if IsDir then
        begin
          if Op = roCopy then
            Steps.Add(TRcloneStep.Create(skRun, ['copy', R(F.FullPath), R(DstDir + F.Name)]))
          else  // also removes the emptied source folders, including the top one
            Steps.Add(TRcloneStep.Create(skRun, ['move', R(F.FullPath), R(DstDir + F.Name), '--delete-empty-src-dirs']));
        end
        else if Op = roCopy then
          Steps.Add(TRcloneStep.Create(skRun, ['copyto', R(F.FullPath), R(DstDir + F.Name)]))
        else
          Steps.Add(TRcloneStep.Create(skRun, ['moveto', R(F.FullPath), R(DstDir + F.Name)]));
      end;
      if Count = 0 then Exit;
      What := IntToStr(Count) + ' items';
      if Count = 1 then
        for I := 0 to Files.Count - 1 do
          if Files[I].Name <> '..' then What := '"' + Files[I].Name + '"';
      What := IfThen(Op = roCopy, 'Copy ', 'Move ') + What + LineEnding +
              'from  ' + Describe(SrcDir) + LineEnding +
              'to    ' + Describe(DstDir);
      if not msgYesNo(What + LineEnding + LineEnding +
                      'Files that are already identical are skipped; changed ones are replaced. ' +
                      'Every copied file is checked against the original.' + LineEnding + LineEnding + 'Start?') then
        Exit;
      A := SrcDir;
      B := DstDir;
    end
    else
    begin
      if (Files.Count = 1) and (Files[0].Name <> '..') and (Files[0].IsDirectory or Files[0].IsLinkToDirectory) then
      begin
        A := Files[0].FullPath;
        B := DstDir + Files[0].Name;
      end
      else
      begin
        A := ExcludeTrailingPathDelimiter(SrcDir);
        B := ExcludeTrailingPathDelimiter(DstDir);
      end;
      if SameFileName(IncludeTrailingPathDelimiter(A), IncludeTrailingPathDelimiter(B)) then
      begin
        msgError('Both sides are the same folder. Open the other folder in the other panel first.');
        Exit;
      end;
      if Op = roSync then
      begin
        if AnsiStartsText(IncludeTrailingPathDelimiter(A), IncludeTrailingPathDelimiter(B)) or
           AnsiStartsText(IncludeTrailingPathDelimiter(B), IncludeTrailingPathDelimiter(A)) then
        begin
          msgError('One folder is inside the other; sync needs two separate folders.');
          Exit;
        end;
        Steps.Add(TRcloneStep.Create(skPreview, ['sync', R(A), R(B), '--dry-run']));
        Steps.Add(TRcloneStep.Create(skRun, ['sync', R(A), R(B)]));
        What := 'Sync: make B an exact copy of A';
      end
      else
      begin
        Steps.Add(TRcloneStep.Create(skCheck, ['check', R(A), R(B), '--combined', '-']));
        What := 'Compare A and B (file by file, checksums where possible)';
      end;
      What := What + LineEnding + 'A  ' + Describe(A) + LineEnding + 'B  ' + Describe(B);
    end;

    TfrmRclone.CreateJob(Op, What, A, B, Steps);
    Steps := nil;   // owned by the window now
  finally
    Files.Free;
    if Assigned(Steps) then
    begin
      for I := 0 to Steps.Count - 1 do
        TObject(Steps[I]).Free;
      Steps.Free;
    end;
  end;
end;

{ ---------------------------------------------------------------- menus }

procedure TRcloneMenuHandler.Click(Sender: TObject);
begin
  RcloneRun(TRcloneOp((Sender as TMenuItem).Tag));
end;

procedure RcloneFillMenu(Parent: TMenuItem);
var
  Op: TRcloneOp;
  Mi: TMenuItem;
begin
  if FMenuHandler = nil then FMenuHandler := TRcloneMenuHandler.Create;
  for Op := Low(TRcloneOp) to High(TRcloneOp) do
  begin
    Mi := TMenuItem.Create(Parent);
    Mi.Caption := RcloneCaptions[Op];
    Mi.Tag := Ord(Op);
    Mi.OnClick := @FMenuHandler.Click;
    Parent.Add(Mi);
  end;
end;

finalization
  FreeAndNil(FMounts);
  FreeAndNil(FMenuHandler);
end.
