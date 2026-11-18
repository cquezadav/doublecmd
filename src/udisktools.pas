{
   [my-custom] Disk Tools window (Windows): see every disk, its partitions and
   free space; check, repair, format, create, resize, delete partitions, change
   letters and labels, set up or erase whole disks.

   The work is done by tools\disk\disktools.ps1 (next to doublecmd.exe), which
   asks for admin rights per action. Actions run in a background thread, so the
   window never freezes. Anything that erases data must be confirmed by typing
   the drive letter / label / disk name.
}
unit uDiskTools;

{$mode objfpc}{$H+}

interface

{ Opens the window. PreselectRoot: e.g. 'O:\' selects that partition. }
procedure ShowDiskTools(const PreselectRoot: String = '');

implementation

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Dialogs,
  Graphics, Process, StrUtils, fpjson, jsonparser, uGlobsPaths, uShowMsg, uMetrics;

type
  TNodeKind = (nkDisk, nkPart, nkFree);

  TfrmDiskTools = class;

  TDiskJob = class(TThread)
  private
    FForm: TfrmDiskTools;
    FArgs: array of String;
    FWhat: String;
    FOutput: String;
    procedure Done;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TfrmDiskTools; const Args: array of String; const What: String);
  end;

  TfrmDiskTools = class(TForm)
  private
    LV: TListView;
    Info: TMemo;
    Log: TMemo;
    Status: TLabel;
    SelLabel: TLabel;
    SafeBox, DangerBox: TGroupBox;
    SafeFlow, DangerFlow: TFlowPanel;
    FRowKind: array of TNodeKind;
    FRowDisk, FRowPart: array of TJSONObject;
    FRowBand: array of Integer;
    btnRefresh, btnCheck, btnRepair, btnFormat, btnCreate, btnResize,
    btnDelete, btnLetter, btnLabel, btnInit, btnWipe: TButton;
    Data: TJSONData;
    Busy: Boolean;
    FPreselect: String;
    function AddButton(AParent: TWinControl; const ACaption, AHint: String; AOnClick: TNotifyEvent): TButton;
    procedure LoadList;
    procedure UpdateButtons;
    procedure LVSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure LVDraw(Sender: TCustomListView; Item: TListItem; State: TCustomDrawState; var DefaultDraw: Boolean);
    function Sel(out Kind: TNodeKind; out Disk, Part: TJSONObject): Boolean;
    function PartName(D, P: TJSONObject): String;
    function Confirm(const What, Token: String): Boolean;
    procedure Run(const Args: array of String; const What: String);
    procedure JobDone(const What, Output: String);
    procedure DoRefresh(Sender: TObject);
    procedure DoCheck(Sender: TObject);
    procedure DoRepair(Sender: TObject);
    procedure DoFormat(Sender: TObject);
    procedure DoCreate(Sender: TObject);
    procedure DoResize(Sender: TObject);
    procedure DoDelete(Sender: TObject);
    procedure DoLetter(Sender: TObject);
    procedure DoLabel(Sender: TObject);
    procedure DoInit(Sender: TObject);
    procedure DoWipe(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor CreateTools(const Preselect: String);
    destructor Destroy; override;
  end;

var
  frmDiskTools: TfrmDiskTools = nil;

function ScriptPath: String;
begin
  Result := gpExePath + 'tools' + PathDelim + 'disk' + PathDelim + 'disktools.ps1';
end;

function RunScript(const Args: array of String; out Output: String): Integer;
var
  Cmd: array of String;
  I: Integer;
begin
  SetLength(Cmd, 6 + Length(Args));
  Cmd[0] := '-NoProfile';
  Cmd[1] := '-NonInteractive';
  Cmd[2] := '-ExecutionPolicy';
  Cmd[3] := 'Bypass';
  Cmd[4] := '-File';
  Cmd[5] := ScriptPath;
  for I := 0 to High(Args) do
    Cmd[6 + I] := Args[I];
  Output := '';
  Result := -1;
  RunCommandInDir(gpExePath, 'powershell.exe', Cmd, Output, Result, [poNoConsole]);
end;

function LastJson(const Output: String): TJSONObject;
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

function SizeText(MB: Int64): String;
begin
  if MB >= 1024 * 1024 then
    Result := FormatFloat('0.0', MB / (1024 * 1024)) + ' TB'
  else if MB >= 1024 then
    Result := FormatFloat('0.0', MB / 1024) + ' GB'
  else
    Result := IntToStr(MB) + ' MB';
end;

{ Small dialog: file system + label (+ size for new partitions). }
function AskFormat(const ACaption: String; WithSize: Boolean; MaxMB: Int64;
  out Fs, ALabel: String; out SizeMB: Int64): Boolean;
var
  F: TForm;
  cbFs: TComboBox;
  edLabel, edSize: TEdit;
  Y: Integer;

  procedure Lbl(const S: String; AY: Integer);
  begin
    with TLabel.Create(F) do
    begin
      Parent := F; Caption := S; Left := 12; Top := AY + 4;
    end;
  end;

begin
  Result := False;
  Fs := ''; ALabel := ''; SizeMB := 0;
  F := TForm.CreateNew(nil);
  try
    F.Caption := ACaption;
    F.BorderStyle := bsDialog;
    F.Position := poMainFormCenter;
    F.ClientWidth := 474;
    Y := 12;
    Lbl('File system:', Y);
    cbFs := TComboBox.Create(F);
    cbFs.Parent := F; cbFs.Left := 130; cbFs.Top := Y; cbFs.Width := 330;
    cbFs.Style := csDropDownList;
    cbFs.Items.Add('exFAT  (big files, Windows + Mac + Linux)');
    cbFs.Items.Add('FAT32  (consoles, Wii, old devices; any size)');
    cbFs.Items.Add('NTFS   (Windows)');
    cbFs.Items.Add('ext4   (Linux, Batocera)');
    cbFs.Items.Add('F2FS   (Linux, made for SD cards / flash)');
    cbFs.Items.Add('btrfs  (Linux, snapshots, checksums)');
    cbFs.Items.Add('xfs    (Linux, very large files)');
    cbFs.Items.Add('HFS+   (Mac, older macOS / iPods)');
    cbFs.Items.Add('UDF    (Windows + Mac + Linux + TVs)');
    cbFs.DropDownCount := 12;
    cbFs.ItemIndex := 0;
    Inc(Y, 34);
    Lbl('Label:', Y);
    edLabel := TEdit.Create(F);
    edLabel.Parent := F; edLabel.Left := 130; edLabel.Top := Y; edLabel.Width := 330;
    edLabel.Text := 'DATA';
    Inc(Y, 34);
    edSize := nil;
    if WithSize then
    begin
      Lbl(Format('Size in MB (max %d):', [MaxMB]), Y);
      edSize := TEdit.Create(F);
      edSize.Parent := F; edSize.Left := 200; edSize.Top := Y; edSize.Width := 260;
      edSize.Text := IntToStr(MaxMB);
      Inc(Y, 34);
    end;
    with TButton.Create(F) do
    begin
      Parent := F; Caption := 'OK'; ModalResult := mrOK; Default := True;
      Left := 290; Top := Y + 6; Width := 80;
    end;
    with TButton.Create(F) do
    begin
      Parent := F; Caption := 'Cancel'; ModalResult := mrCancel; Cancel := True;
      Left := 380; Top := Y + 6; Width := 80;
    end;
    F.ClientHeight := Y + 44;
    if F.ShowModal <> mrOK then Exit;
    case cbFs.ItemIndex of
      0: Fs := 'exfat';
      1: Fs := 'fat32';
      2: Fs := 'ntfs';
      3: Fs := 'ext4';
      4: Fs := 'f2fs';
      5: Fs := 'btrfs';
      6: Fs := 'xfs';
      7: Fs := 'hfsplus';
      8: Fs := 'udf';
    end;
    ALabel := Trim(edLabel.Text);
    if Assigned(edSize) then
    begin
      SizeMB := StrToInt64Def(Trim(edSize.Text), -1);
      if (SizeMB <= 0) or (SizeMB > MaxMB) then
      begin
        msgToast('Size must be between 1 and ' + IntToStr(MaxMB) + ' MB.', 4000);
        Exit;
      end;
      if SizeMB = MaxMB then SizeMB := 0;  // 0 = use all of the free space
    end;
    Result := True;
  finally
    F.Free;
  end;
end;

{ ---- job ---- }

constructor TDiskJob.Create(AForm: TfrmDiskTools; const Args: array of String; const What: String);
var
  I: Integer;
begin
  FForm := AForm;
  SetLength(FArgs, Length(Args));
  for I := 0 to High(Args) do FArgs[I] := Args[I];
  FWhat := What;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TDiskJob.Execute;
begin
  RunScript(FArgs, FOutput);
  Synchronize(@Done);
end;

procedure TDiskJob.Done;
begin
  if frmDiskTools = FForm then
    FForm.JobDone(FWhat, FOutput);
end;

{ ---- form ---- }

const
  // background bands, alternating per disk (BGR)
  clBandA      = $00FFF3E6;  // light blue
  clBandB      = $00EAF7EA;  // light green
  clBandAHead  = $00F5DFC4;  // disk row, darker blue
  clBandBHead  = $00CDEBCD;  // disk row, darker green
  clBandSys    = $00E0E0FF;  // Windows disk: light red
  clBandSysHd  = $00C8C8FF;
  clBandOff    = $00EEEEEE;  // locked / no media: grey
  clTextSys    = $00000090;  // dark red
  clTextOff    = $00808080;
  clTextFree   = $00007000;  // dark green

constructor TfrmDiskTools.CreateTools(const Preselect: String);
var
  PnlR, Groups: TPanel;
  Split: TSplitter;
  Col: TListColumn;

  procedure AddCol(const ACaption: String; AWidth: Integer; Right: Boolean = False);
  begin
    Col := LV.Columns.Add;
    Col.Caption := ACaption;
    Col.Width := AWidth;
    if Right then Col.Alignment := taRightJustify;
  end;

begin
  inherited CreateNew(nil);
  FPreselect := UpperCase(Copy(Preselect, 1, 1));
  Caption := 'Disk Tools';
  Width := 1280;
  Height := 760;
  Position := poMainFormCenter;
  OnClose := @FormClose;

  Status := TLabel.Create(Self);
  Status.Parent := Self;
  Status.Align := alTop;
  Status.BorderSpacing.Around := 8;
  Status.Caption := 'Loading...';

  Log := TMemo.Create(Self);
  Log.Parent := Self;
  Log.Align := alBottom;
  Log.Height := 120;
  Log.ReadOnly := True;
  Log.ScrollBars := ssAutoVertical;
  Log.Font.Name := 'Cascadia Mono';

  PnlR := TPanel.Create(Self);
  PnlR.Parent := Self;
  PnlR.Align := alRight;
  PnlR.Width := 400;
  PnlR.BevelOuter := bvNone;

  Split := TSplitter.Create(Self);
  Split.Parent := Self;
  Split.Align := alRight;

  LV := TListView.Create(Self);
  LV.Parent := Self;
  LV.Align := alClient;
  LV.ViewStyle := vsReport;
  LV.ReadOnly := True;
  LV.RowSelect := True;
  LV.HideSelection := False;
  LV.MultiSelect := False;
  LV.Font.Size := 10;
  AddCol('Disk / partition', 290);
  AddCol('Letter', 55);
  AddCol('Label', 140);
  AddCol('Size', 85, True);
  AddCol('File system', 95);
  AddCol('Free', 85, True);
  AddCol('Notes', 240);
  LV.OnSelectItem := @LVSelect;
  LV.OnCustomDrawItem := @LVDraw;

  // what will be acted on, in big letters
  SelLabel := TLabel.Create(Self);
  SelLabel.Parent := PnlR;
  SelLabel.Align := alTop;
  SelLabel.BorderSpacing.Around := 8;
  SelLabel.WordWrap := True;
  SelLabel.AutoSize := True;
  SelLabel.Font.Size := 12;
  SelLabel.Font.Style := [fsBold];
  SelLabel.Caption := 'Nothing selected';

  Groups := TPanel.Create(Self);
  Groups.Parent := PnlR;
  Groups.Align := alBottom;
  Groups.Height := 250;
  Groups.BevelOuter := bvNone;

  SafeBox := TGroupBox.Create(Self);
  SafeBox.Parent := Groups;
  SafeBox.Align := alTop;
  SafeBox.Height := 112;
  SafeBox.Caption := ' Safe: keeps your files ';
  SafeBox.BorderSpacing.Around := 6;
  SafeFlow := TFlowPanel.Create(Self);
  SafeFlow.Parent := SafeBox;
  SafeFlow.Align := alClient;
  SafeFlow.BevelOuter := bvNone;

  DangerBox := TGroupBox.Create(Self);
  DangerBox.Parent := Groups;
  DangerBox.Align := alClient;
  DangerBox.Caption := ' Erases data: asks you to type a confirmation ';
  DangerBox.Font.Color := clTextSys;
  DangerBox.Font.Style := [fsBold];
  DangerBox.BorderSpacing.Around := 6;
  DangerFlow := TFlowPanel.Create(Self);
  DangerFlow.Parent := DangerBox;
  DangerFlow.Align := alClient;
  DangerFlow.BevelOuter := bvNone;
  DangerFlow.ParentFont := False;

  Info := TMemo.Create(Self);
  Info.Parent := PnlR;
  Info.Align := alClient;
  Info.ReadOnly := True;
  Info.BorderSpacing.Around := 6;
  Info.Font.Name := 'Cascadia Mono';

  btnCheck  := AddButton(SafeFlow, 'Check', 'Read-only scan for errors (changes nothing)', @DoCheck);
  btnRepair := AddButton(SafeFlow, 'Repair', 'Fix file system errors', @DoRepair);
  btnLabel  := AddButton(SafeFlow, 'Label...', 'Rename the volume', @DoLabel);
  btnLetter := AddButton(SafeFlow, 'Drive letter...', 'Change or remove the drive letter', @DoLetter);
  btnResize := AddButton(SafeFlow, 'Resize...', 'Change the size (NTFS only)', @DoResize);
  btnCreate := AddButton(SafeFlow, 'New partition...', 'Create a partition in this free space', @DoCreate);
  btnInit   := AddButton(SafeFlow, 'Set up disk...', 'Create a partition table on a new blank disk', @DoInit);
  btnRefresh := AddButton(SafeFlow, 'Refresh', 'Read the disks again', @DoRefresh);
  btnFormat := AddButton(DangerFlow, 'Format...', 'Erase this partition and create a new file system', @DoFormat);
  btnDelete := AddButton(DangerFlow, 'Delete partition', 'Delete this partition and everything on it', @DoDelete);
  btnWipe   := AddButton(DangerFlow, 'Erase whole disk...', 'Delete ALL partitions on this disk', @DoWipe);
end;

destructor TfrmDiskTools.Destroy;
begin
  Data.Free;
  if frmDiskTools = Self then frmDiskTools := nil;
  inherited Destroy;
end;

procedure TfrmDiskTools.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
  if frmDiskTools = Self then frmDiskTools := nil;
end;

function TfrmDiskTools.AddButton(AParent: TWinControl; const ACaption, AHint: String; AOnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Hint := AHint;
  Result.ShowHint := True;
  Result.AutoSize := True;
  Result.Constraints.MinWidth := 118;
  Result.BorderSpacing.Around := 3;
  Result.ParentFont := False;
  Result.Font.Style := [];
  Result.Font.Color := clDefault;
  Result.OnClick := AOnClick;
end;

function DiskKindText(D: TJSONObject): String;
begin
  if D.Get('removable', False) then
    Result := 'SD card / USB stick'
  else
    Result := D.Get('bus', '');
end;

procedure TfrmDiskTools.LoadList;
var
  Output, S: String;
  R: TJSONObject;
  Disks, Parts: TJSONArray;
  D, P: TJSONObject;
  I, J, N: Integer;
  It, ToSelect: TListItem;

  procedure AddRow(AKind: TNodeKind; ADisk, APart: TJSONObject; ABand: Integer);
  begin
    N := Length(FRowKind);
    SetLength(FRowKind, N + 1);  FRowKind[N] := AKind;
    SetLength(FRowDisk, N + 1);  FRowDisk[N] := ADisk;
    SetLength(FRowPart, N + 1);  FRowPart[N] := APart;
    SetLength(FRowBand, N + 1);  FRowBand[N] := ABand;
    It := LV.Items.Add;
    It.Data := Pointer(PtrInt(N));
  end;

begin
  Status.Caption := 'Reading disks...';
  Application.ProcessMessages;
  RunScript(['list'], Output);
  R := LastJson(Output);
  if not Assigned(R) or not R.Get('ok', False) then
  begin
    if Assigned(R) then S := R.Get('error', '?') else S := Output;
    Status.Caption := 'Could not read the disks: ' + S;
    R.Free;
    Exit;
  end;
  ToSelect := nil;
  LV.Items.BeginUpdate;
  try
    LV.Items.Clear;
    SetLength(FRowKind, 0); SetLength(FRowDisk, 0); SetLength(FRowPart, 0); SetLength(FRowBand, 0);
    FreeAndNil(Data);
    Data := R;
    Disks := R.Arrays['disks'];
    for I := 0 to Disks.Count - 1 do
    begin
      D := Disks.Objects[I];
      AddRow(nkDisk, D, nil, I mod 2);
      It.Caption := Format('Disk %d   %s', [D.Get('disk', 0), D.Get('name', '')]);
      It.SubItems.Add('');
      It.SubItems.Add(DiskKindText(D));
      It.SubItems.Add(SizeText(D.Get('size_mb', Int64(0))));
      It.SubItems.Add(D.Get('style', ''));
      It.SubItems.Add('');
      It.SubItems.Add(D.Get('locked', ''));
      Parts := D.Arrays['parts'];
      for J := 0 to Parts.Count - 1 do
      begin
        P := Parts.Objects[J];
        if P.Get('kind', '') = 'free' then
        begin
          AddRow(nkFree, D, P, I mod 2);
          It.Caption := '      free space (unused)';
          It.SubItems.Add('');
          It.SubItems.Add('');
          It.SubItems.Add(SizeText(P.Get('size_mb', Int64(0))));
          It.SubItems.Add('');
          It.SubItems.Add('');
          It.SubItems.Add('can hold a new partition');
        end
        else
        begin
          AddRow(nkPart, D, P, I mod 2);
          It.Caption := Format('      partition %d', [P.Get('number', 0)]);
          if P.Get('letter', '') <> '' then It.SubItems.Add(P.Get('letter', '') + ':') else It.SubItems.Add('');
          It.SubItems.Add(P.Get('label', ''));
          It.SubItems.Add(SizeText(P.Get('size_mb', Int64(0))));
          It.SubItems.Add(P.Get('fs', ''));
          if (P.IndexOfName('free_mb') >= 0) and not P.Nulls['free_mb'] then
            It.SubItems.Add(SizeText(P.Get('free_mb', Int64(0))))
          else
            It.SubItems.Add('');
          S := P.Get('type', '');
          if P.Get('system', False) then S := S + ' - Windows needs it';
          It.SubItems.Add(S);
          if (FPreselect <> '') and (UpperCase(P.Get('letter', '')) = FPreselect) then
            ToSelect := It;
        end;
      end;
    end;
  finally
    LV.Items.EndUpdate;
  end;
  if Assigned(ToSelect) then
  begin
    LV.Selected := ToSelect;
    ToSelect.MakeVisible(False);
  end;
  FPreselect := '';
  Status.Caption := 'Pick a disk, partition or free space. Each disk has its own colour band; ' +
                    'red = the Windows disk. Changes ask for admin rights.';
  UpdateButtons;
end;

function TfrmDiskTools.Sel(out Kind: TNodeKind; out Disk, Part: TJSONObject): Boolean;
var
  I: Integer;
begin
  Result := False;
  Disk := nil; Part := nil; Kind := nkDisk;
  if LV.Selected = nil then Exit;
  I := PtrInt(LV.Selected.Data);
  if (I < 0) or (I > High(FRowKind)) then Exit;
  Kind := FRowKind[I];
  Disk := FRowDisk[I];
  Part := FRowPart[I];
  Result := True;
end;

procedure TfrmDiskTools.LVDraw(Sender: TCustomListView; Item: TListItem;
  State: TCustomDrawState; var DefaultDraw: Boolean);
var
  I: Integer;
  D: TJSONObject;
  Sys, Off: Boolean;
begin
  DefaultDraw := True;
  I := PtrInt(Item.Data);
  if (I < 0) or (I > High(FRowKind)) then Exit;
  D := FRowDisk[I];
  Sys := Pos('Windows runs', D.Get('locked', '')) > 0;
  Off := (D.Get('locked', '') <> '') and not Sys;
  with Sender.Canvas do
  begin
    Font.Style := [];
    Font.Color := clWindowText;
    if Sys then
    begin
      if FRowKind[I] = nkDisk then Brush.Color := clBandSysHd else Brush.Color := clBandSys;
      Font.Color := clTextSys;
    end
    else if Off then
    begin
      Brush.Color := clBandOff;
      Font.Color := clTextOff;
    end
    else if FRowBand[I] = 0 then
    begin
      if FRowKind[I] = nkDisk then Brush.Color := clBandAHead else Brush.Color := clBandA;
    end
    else
    begin
      if FRowKind[I] = nkDisk then Brush.Color := clBandBHead else Brush.Color := clBandB;
    end;
    if FRowKind[I] = nkDisk then Font.Style := [fsBold];
    if FRowKind[I] = nkFree then
    begin
      Font.Style := [fsItalic];
      if not (Sys or Off) then Font.Color := clTextFree;
    end;
  end;
end;

function TfrmDiskTools.PartName(D, P: TJSONObject): String;
begin
  if P.Get('letter', '') <> '' then
    Result := P.Get('letter', '') + ':'
  else if P.Get('label', '') <> '' then
    Result := P.Get('label', '')
  else
    Result := Format('DISK%dP%d', [D.Get('disk', 0), P.Get('number', 0)]);
end;

procedure TfrmDiskTools.UpdateButtons;
var
  Kind: TNodeKind;
  D, P: TJSONObject;
  Have, Locked, Sys, IsPart, Special: Boolean;
  Fs, T, DiskText: String;
begin
  Have := Sel(Kind, D, P) and not Busy;
  Locked := Have and (D.Get('locked', '') <> '');
  IsPart := Have and (Kind = nkPart);
  Sys := IsPart and P.Get('system', False);
  if IsPart then Fs := P.Get('fs', '') else Fs := '';
  if IsPart then T := P.Get('type', '') else T := '';
  Special := (T = 'EFI system') or (T = 'Microsoft reserved') or (T = 'Windows recovery');

  btnRefresh.Enabled := not Busy;
  btnCheck.Enabled  := IsPart and ((P.Get('letter', '') <> '') or (Fs = 'Linux')) and not Special;
  btnRepair.Enabled := btnCheck.Enabled and not Locked and not Sys;
  btnFormat.Enabled := IsPart and not Locked and not Sys and not Special;
  btnCreate.Enabled := Have and (Kind = nkFree) and not Locked;
  btnResize.Enabled := IsPart and not Locked and not Sys and (Fs = 'NTFS');
  btnDelete.Enabled := IsPart and not Locked and not Sys;
  btnLetter.Enabled := IsPart and not Locked and not Sys and (Fs <> 'Linux') and not Special;
  btnLabel.Enabled  := IsPart and not Locked and not Sys and (P.Get('letter', '') <> '');
  btnInit.Enabled   := Have and (Kind = nkDisk) and not Locked and (D.Get('style', '') = 'RAW') and (D.Get('size_mb', Int64(0)) > 0);
  btnWipe.Enabled   := Have and (Kind = nkDisk) and not Locked and (D.Get('style', '') <> 'RAW');

  Info.Clear;
  if not Sel(Kind, D, P) then
  begin
    SelLabel.Caption := 'Nothing selected';
    SelLabel.Font.Color := clWindowText;
    Exit;
  end;
  DiskText := Format('Disk %d  %s  (%s, %s)', [D.Get('disk', 0), D.Get('name', ''),
                DiskKindText(D), SizeText(D.Get('size_mb', Int64(0)))]);
  case Kind of
    nkDisk: SelLabel.Caption := 'Selected: whole ' + DiskText;
    nkFree: SelLabel.Caption := 'Selected: ' + SizeText(P.Get('size_mb', Int64(0))) +
                                ' of free space on ' + DiskText;
    nkPart: SelLabel.Caption := 'Selected: ' + Trim(P.Get('letter', '') +
              IfThen(P.Get('letter', '') <> '', ':  ', '') + P.Get('label', '') + '  ' +
              SizeText(P.Get('size_mb', Int64(0))) + '  ' + Fs) + LineEnding + 'on ' + DiskText;
  end;
  if Locked and (Pos('Windows runs', D.Get('locked', '')) > 0) then
    SelLabel.Font.Color := clTextSys
  else
    SelLabel.Font.Color := clWindowText;

  Info.Lines.Add(Format('Disk %d: %s', [D.Get('disk', 0), D.Get('name', '')]));
  Info.Lines.Add(Format('  %s, %s, %s', [SizeText(D.Get('size_mb', Int64(0))), DiskKindText(D), D.Get('style', '')]));
  if Locked then Info.Lines.Add('  ' + D.Get('locked', ''));
  if Kind = nkPart then
  begin
    Info.Lines.Add('');
    Info.Lines.Add(Format('Partition %d', [P.Get('number', 0)]));
    Info.Lines.Add('  Letter:      ' + P.Get('letter', '-'));
    Info.Lines.Add('  Label:       ' + P.Get('label', ''));
    Info.Lines.Add('  File system: ' + Fs);
    Info.Lines.Add('  Type:        ' + T);
    Info.Lines.Add('  Size:        ' + SizeText(P.Get('size_mb', Int64(0))));
    if (P.IndexOfName('free_mb') >= 0) and not P.Nulls['free_mb'] then
      Info.Lines.Add('  Free:        ' + SizeText(P.Get('free_mb', Int64(0))));
    if P.Get('health', '') <> '' then
      Info.Lines.Add('  Health:      ' + P.Get('health', ''));
    if Sys then Info.Lines.Add('  Windows needs this partition: it cannot be changed.');
    if Special then Info.Lines.Add('  Special Windows partition.');
  end
  else if Kind = nkFree then
  begin
    Info.Lines.Add('');
    Info.Lines.Add('Unused space: ' + SizeText(P.Get('size_mb', Int64(0))));
    Info.Lines.Add('Use "New partition..." to make it usable.');
  end;
end;

procedure TfrmDiskTools.LVSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  UpdateButtons;
end;

type
  { Compact type-to-confirm box: OK only works once the token is typed. }
  TConfirmBox = class(TForm)
  public
    Ed: TEdit;
    BtnOk: TButton;
    Token: String;
    procedure EdChange(Sender: TObject);
  end;

procedure TConfirmBox.EdChange(Sender: TObject);
begin
  BtnOk.Enabled := SameText(Trim(Ed.Text), Token);
end;

function TfrmDiskTools.Confirm(const What, Token: String): Boolean;
var
  F: TConfirmBox;
  L1, L2, L3: TLabel;
begin
  F := TConfirmBox.CreateNew(Self);
  try
    F.Caption := 'Confirm';
    F.BorderStyle := bsDialog;
    F.Position := poOwnerFormCenter;
    F.Token := Token;
    F.ClientWidth := 460;
    F.ChildSizing.LeftRightSpacing := 14;
    F.ChildSizing.TopBottomSpacing := 12;

    L1 := TLabel.Create(F);
    L1.Parent := F; L1.Left := 14; L1.Top := 12; L1.Width := 432;
    L1.AutoSize := True; L1.WordWrap := True;
    L1.Caption := What;

    L2 := TLabel.Create(F);
    L2.Parent := F; L2.Left := 14; L2.Top := 52;
    L2.Caption := 'Everything on it will be lost.';
    L2.Font.Color := $00000090;
    L2.Font.Style := [fsBold];

    L3 := TLabel.Create(F);
    L3.Parent := F; L3.Left := 14; L3.Top := 80;
    L3.Caption := 'To continue, type:   ' + Token;
    L3.Font.Size := 11;
    L3.Font.Style := [fsBold];

    F.Ed := TEdit.Create(F);
    F.Ed.Parent := F; F.Ed.Left := 14; F.Ed.Top := 110; F.Ed.Width := 200;
    F.Ed.Font.Size := 11;
    F.Ed.OnChange := @F.EdChange;

    F.BtnOk := TButton.Create(F);
    F.BtnOk.Parent := F; F.BtnOk.Caption := 'Erase'; F.BtnOk.ModalResult := mrOK;
    F.BtnOk.Left := 270; F.BtnOk.Top := 108; F.BtnOk.Width := 84; F.BtnOk.Enabled := False;
    F.BtnOk.Default := True;

    with TButton.Create(F) do
    begin
      Parent := F; Caption := 'Cancel'; ModalResult := mrCancel; Cancel := True;
      Left := 362; Top := 108; Width := 84;
    end;
    F.ClientHeight := 152;
    F.ActiveControl := F.Ed;
    Result := (F.ShowModal = mrOK) and SameText(Trim(F.Ed.Text), Token);
  finally
    F.Free;
  end;
  if not Result then
    Log.Lines.Add('Cancelled: ' + What);
end;

procedure TfrmDiskTools.Run(const Args: array of String; const What: String);
begin
  Busy := True;
  UpdateButtons;
  Status.Caption := What + '...  (approve the Windows admin prompt)';
  Log.Lines.Add('> ' + What);
  Screen.BeginWaitCursor;
  TDiskJob.Create(Self, Args, What);
end;

procedure TfrmDiskTools.JobDone(const What, Output: String);
var
  R: TJSONObject;
  Ok: Boolean;
  Msg: String;
begin
  Screen.EndWaitCursor;
  Busy := False;
  R := LastJson(Output);
  try
    Ok := Assigned(R) and R.Get('ok', False);
    if Assigned(R) then
    begin
      if R.IndexOfName('message') >= 0 then Msg := R.Get('message', '') else Msg := R.Get('error', '');
    end
    else
      Msg := Trim(Output);
    if Trim(Msg) = '' then
      Msg := 'No details. Raw output: ' + Copy(Trim(Output), 1, 600);
    if Trim(Msg) = 'No details. Raw output:' then
      Msg := 'No details (was the admin prompt cancelled?)';
    if Ok then
      Log.Lines.Add('  OK: ' + StringReplace(Msg, #10, LineEnding + '      ', [rfReplaceAll]))
    else
      Log.Lines.Add('  FAILED: ' + StringReplace(Msg, #10, LineEnding + '      ', [rfReplaceAll]));
    MetricsLog('disk_tools', ['what', What, 'ok', Ok]);
    if Ok then msgToast(What + ': done', 2500) else msgToast(What + ': failed', 3000);
  finally
    R.Free;
  end;
  LoadList;
end;

procedure TfrmDiskTools.DoRefresh(Sender: TObject);
begin
  LoadList;
end;

procedure TfrmDiskTools.DoCheck(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject;
begin
  if not Sel(K, D, P) or (K <> nkPart) then Exit;
  Run(['check', '-Disk', IntToStr(D.Get('disk', 0)), '-Partition', IntToStr(P.Get('number', 0))],
      'Check ' + PartName(D, P));
end;

procedure TfrmDiskTools.DoRepair(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject;
begin
  if not Sel(K, D, P) or (K <> nkPart) then Exit;
  if MessageDlg('Repair ' + PartName(D, P) + '?' + LineEnding +
       'Files on it can''t be used while it is repaired.', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  Run(['repair', '-Disk', IntToStr(D.Get('disk', 0)), '-Partition', IntToStr(P.Get('number', 0))],
      'Repair ' + PartName(D, P));
end;

procedure TfrmDiskTools.DoFormat(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject; Fs, L: String; Sz: Int64;
begin
  if not Sel(K, D, P) or (K <> nkPart) then Exit;
  if not AskFormat('Format ' + PartName(D, P), False, 0, Fs, L, Sz) then Exit;
  if not Confirm('Format ' + PartName(D, P) + ' (' + SizeText(P.Get('size_mb', Int64(0))) + ') as ' + UpperCase(Fs) + '.',
                 PartName(D, P)) then Exit;
  Run(['format', '-Disk', IntToStr(D.Get('disk', 0)), '-Partition', IntToStr(P.Get('number', 0)),
       '-FileSystem', Fs, '-Label', L], 'Format ' + PartName(D, P) + ' as ' + UpperCase(Fs));
end;

procedure TfrmDiskTools.DoCreate(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject; Fs, L: String; Sz: Int64;
begin
  if not Sel(K, D, P) or (K <> nkFree) then Exit;
  if not AskFormat('New partition on disk ' + IntToStr(D.Get('disk', 0)), True,
                   P.Get('size_mb', Int64(0)), Fs, L, Sz) then Exit;
  Run(['create', '-Disk', IntToStr(D.Get('disk', 0)), '-SizeMB', IntToStr(Sz),
       '-OffsetMB', IntToStr(P.Get('offset_mb', Int64(0))), '-FileSystem', Fs, '-Label', L],
      'New ' + UpperCase(Fs) + ' partition on disk ' + IntToStr(D.Get('disk', 0)));
end;

procedure TfrmDiskTools.DoResize(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject; S: String;
begin
  if not Sel(K, D, P) or (K <> nkPart) then Exit;
  S := IntToStr(P.Get('size_mb', Int64(0)));
  if not InputQuery('Resize ' + PartName(D, P), 'New size in MB:', S) then Exit;
  Run(['resize', '-Disk', IntToStr(D.Get('disk', 0)), '-Partition', IntToStr(P.Get('number', 0)),
       '-SizeMB', Trim(S)], 'Resize ' + PartName(D, P));
end;

procedure TfrmDiskTools.DoDelete(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject;
begin
  if not Sel(K, D, P) or (K <> nkPart) then Exit;
  if not Confirm('Delete partition ' + PartName(D, P) + ' (' + SizeText(P.Get('size_mb', Int64(0))) + ').',
                 PartName(D, P)) then Exit;
  Run(['delete', '-Disk', IntToStr(D.Get('disk', 0)), '-Partition', IntToStr(P.Get('number', 0))],
      'Delete ' + PartName(D, P));
end;

procedure TfrmDiskTools.DoLetter(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject; S: String;
begin
  if not Sel(K, D, P) or (K <> nkPart) then Exit;
  S := P.Get('letter', '');
  if not InputQuery('Drive letter', 'New drive letter (leave empty to remove it):', S) then Exit;
  S := UpperCase(Trim(StringReplace(S, ':', '', [])));
  if S = '' then S := 'none'
  else if (Length(S) <> 1) or not (S[1] in ['A'..'Z']) then
  begin
    msgToast('Use a single letter, e.g. T', 3000);
    Exit;
  end;
  Run(['setletter', '-Disk', IntToStr(D.Get('disk', 0)), '-Partition', IntToStr(P.Get('number', 0)),
       '-Letter', S], 'Drive letter of ' + PartName(D, P));
end;

procedure TfrmDiskTools.DoLabel(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject; S: String;
begin
  if not Sel(K, D, P) or (K <> nkPart) then Exit;
  S := P.Get('label', '');
  if not InputQuery('Label', 'New label for ' + PartName(D, P) + ':', S) then Exit;
  Run(['setlabel', '-Disk', IntToStr(D.Get('disk', 0)), '-Partition', IntToStr(P.Get('number', 0)),
       '-Label', Trim(S)], 'Label of ' + PartName(D, P));
end;

function AskStyle(out Style: String): Boolean;
begin
  case QuestionDlg('Partition table',
         'GPT: modern, any size (recommended).' + LineEnding +
         'MBR: old devices; disks up to 2 TB.',
         mtConfirmation, [mrYes, 'GPT', mrNo, 'MBR', mrCancel, 'Cancel'], 0) of
    mrYes: Style := 'gpt';
    mrNo:  Style := 'mbr';
  else
    Exit(False);
  end;
  Result := True;
end;

procedure TfrmDiskTools.DoInit(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject; St: String;
begin
  if not Sel(K, D, P) or (K <> nkDisk) then Exit;
  if not AskStyle(St) then Exit;
  Run(['initialize', '-Disk', IntToStr(D.Get('disk', 0)), '-Style', St],
      'Set up disk ' + IntToStr(D.Get('disk', 0)) + ' (' + UpperCase(St) + ')');
end;

procedure TfrmDiskTools.DoWipe(Sender: TObject);
var K: TNodeKind; D, P: TJSONObject; St, Tok: String;
begin
  if not Sel(K, D, P) or (K <> nkDisk) then Exit;
  Tok := 'DISK' + IntToStr(D.Get('disk', 0));
  if not Confirm('Erase ALL partitions on disk ' + IntToStr(D.Get('disk', 0)) + ' - ' + D.Get('name', '') +
                 ' (' + SizeText(D.Get('size_mb', Int64(0))) + ').', Tok) then Exit;
  if not AskStyle(St) then Exit;
  Run(['wipe', '-Disk', IntToStr(D.Get('disk', 0)), '-Style', St], 'Erase disk ' + IntToStr(D.Get('disk', 0)));
end;

procedure ShowDiskTools(const PreselectRoot: String);
begin
  if not FileExists(ScriptPath) then
  begin
    msgToast('Disk tools script not found:' + LineEnding + ScriptPath, 5000);
    Exit;
  end;
  if not Assigned(frmDiskTools) then
    frmDiskTools := TfrmDiskTools.CreateTools(PreselectRoot)
  else
    frmDiskTools.FPreselect := UpperCase(Copy(PreselectRoot, 1, 1));
  frmDiskTools.Show;
  frmDiskTools.BringToFront;
  Application.ProcessMessages;
  frmDiskTools.LoadList;
end;

end.
