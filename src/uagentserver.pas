{
   [my-custom] Agent control server.

   A tiny JSON-RPC-over-HTTP endpoint that lets a local AI agent (through the
   MCP bridge in tools/mcp/doublecmd_mcp.py) drive Double Commander the way a
   user would: read panel state, navigate, select files, run commands and
   start copy/move/delete operations through the normal operations queue.

   Security:
     * listens on 127.0.0.1 only;
     * every request must carry "Authorization: Bearer <token>"; the random
       token is written, together with the port, to <cfg>\agent\endpoint.json
       which only the current user can read;
     * disabled unless <cfg>\agent.enabled exists (Configuration menu toggle);
     * permanent deletes always show Double Commander's own confirmation.

   All handlers run on the main (GUI) thread via TThread.Synchronize.

   Request:  POST /rpc   with a JSON body: method = "get_state", params = object
   Response: JSON with ok = true and result, or ok = false and error
}
unit uAgentServer;

{$mode objfpc}{$H+}

interface

procedure AgentServerInit(const CfgDir: String);
procedure AgentServerShutdown;
function  AgentServerEnabled: Boolean;
procedure AgentServerSetEnabled(Value: Boolean);
function  AgentServerRunning: Boolean;
function  AgentServerPort: Integer;
function  AgentEndpointFile: String;

implementation

uses
  Classes, SysUtils, fpjson, jsonparser, fphttpserver, httpdefs,
  Forms, DateUtils, LazUTF8,
  uMetrics, uFileView, uFile, uFileSource, uFileSourceOperation,
  uFileSourceOperationTypes, uOperationsManager, uFileViewNotebook,
  uFileSourceUtil, uDisplayFile, uFormCommands, uFilePanelSelect,
  uFileSourceSetFilePropertyOperation, uFileProperty, fMain;

const
  DefaultPort = 47811;
  PortTries = 10;

type
  { Gives access to protected TFileView.IsLoadingFileList }
  TFileViewAccess = class(TFileView);
  { Gives access to protected TFPHttpServer.Address }
  THttpServerAccess = class(TFPHttpServer);

  TAgentServerThread = class(TThread)
  private
    FServer: TFPHttpServer;
    FPort: Integer;
    procedure DoIdle(Sender: TObject);
    procedure DoRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
                        var AResponse: TFPHTTPConnectionResponse);
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Integer);
    property Port: Integer read FPort;
  end;

  { One RPC call, executed on the main thread }
  TAgentCall = class
  public
    Method: String;
    Params: TJSONObject;
    Result: TJSONData;
    Error: String;
    procedure Run;
  end;

var
  FCfgDir: String = '';
  FEnabled: Boolean = False;
  FToken: String = '';
  FThread: TAgentServerThread = nil;
  FBoundPort: Integer = 0;
  FStartError: String = '';

{ ---------- helpers ---------- }

function MarkerFile: String;
begin
  Result := FCfgDir + 'agent.enabled';
end;

function AgentEndpointFile: String;
begin
  Result := FCfgDir + 'agent' + PathDelim + 'endpoint.json';
end;

function NewToken: String;
var
  G1, G2: TGUID;
begin
  CreateGUID(G1);
  CreateGUID(G2);
  Result := LowerCase(StringReplace(GUIDToString(G1) + GUIDToString(G2), '-', '', [rfReplaceAll]));
  Result := StringReplace(StringReplace(Result, '{', '', [rfReplaceAll]), '}', '', [rfReplaceAll]);
end;

function PStr(P: TJSONObject; const Name: String; const Def: String = ''): String;
begin
  if Assigned(P) and (P.IndexOfName(Name) >= 0) and not P.Nulls[Name] then
    Result := P.Get(Name, Def)
  else
    Result := Def;
end;

function PInt(P: TJSONObject; const Name: String; Def: Integer): Integer;
begin
  if Assigned(P) and (P.IndexOfName(Name) >= 0) and not P.Nulls[Name] then
    Result := P.Get(Name, Def)
  else
    Result := Def;
end;

function PBool(P: TJSONObject; const Name: String; Def: Boolean): Boolean;
begin
  if Assigned(P) and (P.IndexOfName(Name) >= 0) and not P.Nulls[Name] then
    Result := P.Get(Name, Def)
  else
    Result := Def;
end;

function PArr(P: TJSONObject; const Name: String): TJSONArray;
begin
  Result := nil;
  if Assigned(P) and (P.IndexOfName(Name) >= 0) and (P.Items[P.IndexOfName(Name)] is TJSONArray) then
    Result := P.Arrays[Name];
end;

{ Resolves "left" / "right" / "active" / "inactive" (default: active) }
function GetPanel(P: TJSONObject; out Side: String): TFileView;
var
  S: String;
begin
  S := LowerCase(PStr(P, 'panel', 'active'));
  if S = 'active' then
  begin
    if frmMain.ActiveFrame = frmMain.FrameLeft then S := 'left' else S := 'right';
  end
  else if S = 'inactive' then
  begin
    if frmMain.ActiveFrame = frmMain.FrameLeft then S := 'right' else S := 'left';
  end;
  if S = 'left' then
    Result := frmMain.FrameLeft
  else if S = 'right' then
    Result := frmMain.FrameRight
  else
    raise Exception.Create('panel must be left, right, active or inactive');
  Side := S;
end;

function NotebookOf(const Side: String): TFileViewNotebook;
begin
  if Side = 'left' then
    Result := frmMain.LeftTabs
  else
    Result := frmMain.RightTabs;
end;

function FullPathOf(View: TFileView): String;
begin
  Result := View.CurrentAddress + View.CurrentPath;
end;

function FileToJson(AFile: TFile; Selected: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', AFile.Name);
  Result.Add('dir', AFile.IsDirectory or AFile.IsLinkToDirectory);
  if (fpSize in AFile.SupportedProperties) and not AFile.IsDirectory then
    Result.Add('size', AFile.Size);
  if fpModificationTime in AFile.SupportedProperties then
    try
      Result.Add('modified', FormatDateTime('yyyy-mm-dd hh:nn:ss', AFile.ModificationTime));
    except
    end;
  if Selected then
    Result.Add('selected', True);
end;

function PanelJson(View: TFileView; const Side: String; WithTabs: Boolean): TJSONObject;
var
  I, Sel: Integer;
  Names: TJSONArray;
  Tabs: TJSONArray;
  Tab: TJSONObject;
  NB: TFileViewNotebook;
  ActiveFile: TFile;
begin
  Result := TJSONObject.Create;
  Result.Add('panel', Side);
  Result.Add('path', FullPathOf(View));
  Result.Add('file_source', View.FileSource.ClassName);
  Result.Add('loading', TFileViewAccess(View).IsLoadingFileList);
  Result.Add('count', View.DisplayFiles.Count);
  ActiveFile := View.CloneActiveFile;
  try
    if Assigned(ActiveFile) then
      Result.Add('cursor', ActiveFile.Name);
  finally
    ActiveFile.Free;
  end;
  Names := TJSONArray.Create;
  Sel := 0;
  for I := 0 to View.DisplayFiles.Count - 1 do
    if View.DisplayFiles[I].Selected then
    begin
      Inc(Sel);
      if Names.Count < 200 then
        Names.Add(View.DisplayFiles[I].FSFile.Name);
    end;
  Result.Add('selected_count', Sel);
  Result.Add('selected', Names);
  if WithTabs then
  begin
    NB := NotebookOf(Side);
    Tabs := TJSONArray.Create;
    for I := 0 to NB.PageCount - 1 do
    begin
      Tab := TJSONObject.Create;
      Tab.Add('index', I);
      Tab.Add('path', FullPathOf(NB.View[I]));
      Tab.Add('locked', NB.Page[I].LockState <> tlsNormal);
      Tab.Add('active', I = NB.PageIndex);
      Tabs.Add(Tab);
    end;
    Result.Add('tabs', Tabs);
  end;
end;

function OperationsJson: TJSONArray;
var
  Q, I: Integer;
  Queue: TOperationsManagerQueue;
  Item: TOperationsManagerItem;
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  for Q := 0 to OperationsManager.QueuesCount - 1 do
  begin
    Queue := OperationsManager.QueueByIndex[Q];
    for I := 0 to Queue.Count - 1 do
    begin
      Item := Queue.Items[I];
      O := TJSONObject.Create;
      O.Add('handle', Int64(Item.Handle));
      O.Add('description', Item.Operation.GetDescription(fsoddJobAndTarget));
      O.Add('state', Ord(Item.Operation.State));
      O.Add('progress_pct', Round(Item.Operation.Progress * 100));
      Result.Add(O);
    end;
  end;
end;

{ Selects exactly the given names (case-sensitive match, then case-insensitive). }
function SelectNames(View: TFileView; Names: TJSONArray; Mode: String): Integer;
var
  I, J: Integer;
  F: TDisplayFile;
  Want: TStringList;
begin
  Result := 0;
  Mode := LowerCase(Mode);
  if Mode = 'all' then
  begin
    View.MarkFiles(True);
    Exit(View.DisplayFiles.Count);
  end;
  if (Mode = 'none') or (Mode = 'set') then
    View.MarkFiles(False);
  if (Mode = 'none') or not Assigned(Names) then Exit;
  Want := TStringList.Create;
  try
    Want.CaseSensitive := False;
    Want.Sorted := True;
    Want.Duplicates := dupIgnore;
    for J := 0 to Names.Count - 1 do
      Want.Add(Names.Strings[J]);
    for I := 0 to View.DisplayFiles.Count - 1 do
    begin
      F := View.DisplayFiles[I];
      if F.FSFile.Name = '..' then Continue;
      if Want.IndexOf(F.FSFile.Name) >= 0 then
      begin
        View.MarkFile(F, Mode <> 'remove', False);
        Inc(Result);
      end;
    end;
    View.Invalidate;
  finally
    Want.Free;
  end;
end;

procedure MakeActive(View: TFileView);
begin
  if frmMain.ActiveFrame <> View then
  begin
    if View = frmMain.FrameLeft then
      frmMain.SelectedPanel := fpLeft
    else
      frmMain.SelectedPanel := fpRight;
    View.SetFocus;
  end;
end;

{ ---------- RPC methods ---------- }

procedure TAgentCall.Run;
var
  View: TFileView;
  Side, S: String;
  O: TJSONObject;
  A: TJSONArray;
  I, Offset, Limit, N: Integer;
  F: TDisplayFile;
  Files: TFiles;
  Op: TFileSourceOperation;
  CmdParams: array of String;
  Res: TCommandFuncResult;
  List: TStringList;
  Started: Boolean;
begin
  Result := nil;
  Error := '';
  try
    if Method = 'ping' then
    begin
      O := TJSONObject.Create;
      O.Add('app', 'Double Commander');
      O.Add('pid', Int64(GetProcessID));
      Result := O;
    end

    else if Method = 'get_state' then
    begin
      O := TJSONObject.Create;
      if frmMain.ActiveFrame = frmMain.FrameLeft then S := 'left' else S := 'right';
      O.Add('active_panel', S);
      O.Add('left', PanelJson(frmMain.FrameLeft, 'left', True));
      O.Add('right', PanelJson(frmMain.FrameRight, 'right', True));
      O.Add('operations', OperationsJson);
      Result := O;
    end

    else if Method = 'list_panel' then
    begin
      View := GetPanel(Params, Side);
      Offset := PInt(Params, 'offset', 0);
      Limit := PInt(Params, 'limit', 500);
      O := PanelJson(View, Side, False);
      A := TJSONArray.Create;
      N := 0;
      for I := Offset to View.DisplayFiles.Count - 1 do
      begin
        if N >= Limit then Break;
        F := View.DisplayFiles[I];
        A.Add(FileToJson(F.FSFile, F.Selected));
        Inc(N);
      end;
      O.Add('offset', Offset);
      O.Add('files', A);
      Result := O;
    end

    else if Method = 'navigate' then
    begin
      View := GetPanel(Params, Side);
      S := PStr(Params, 'path');
      if S = '' then raise Exception.Create('path is required');
      if not ChooseFileSource(View, S) then
        if not DirectoryExists(S) then
          raise Exception.Create('Cannot open: ' + S);
      if PBool(Params, 'activate', False) then MakeActive(View);
      Result := PanelJson(View, Side, False);
    end

    else if Method = 'set_active_panel' then
    begin
      View := GetPanel(Params, Side);
      MakeActive(View);
      Result := TJSONString.Create(Side);
    end

    else if Method = 'new_tab' then
    begin
      View := GetPanel(Params, Side);
      View := NotebookOf(Side).NewPage(View).FileView;
      NotebookOf(Side).PageIndex := NotebookOf(Side).PageCount - 1;
      S := PStr(Params, 'path');
      if S <> '' then ChooseFileSource(View, S);
      Result := PanelJson(View, Side, False);
    end

    else if Method = 'select' then
    begin
      View := GetPanel(Params, Side);
      N := SelectNames(View, PArr(Params, 'names'), PStr(Params, 'mode', 'set'));
      S := PStr(Params, 'cursor');
      if S <> '' then View.SetActiveFile(S);
      O := PanelJson(View, Side, False);
      O.Add('matched', N);
      Result := O;
    end

    else if (Method = 'copy') or (Method = 'move') then
    begin
      View := GetPanel(Params, Side);
      if Assigned(PArr(Params, 'names')) then
        SelectNames(View, PArr(Params, 'names'), 'set');
      Files := View.CloneSelectedOrActiveFiles;
      try
        if (Files = nil) or (Files.Count = 0) then
          raise Exception.Create('Nothing selected');
        S := PStr(Params, 'dest');
        if S = '' then
        begin
          if View = frmMain.FrameLeft then
            S := frmMain.FrameRight.CurrentPath
          else
            S := frmMain.FrameLeft.CurrentPath;
        end;
        N := Files.Count;
      finally
        Files.Free;
      end;
      MakeActive(View);
      if Method = 'copy' then
        Started := frmMain.CopyFiles(S, PBool(Params, 'confirm', False))
      else
        Started := frmMain.MoveFiles(S, PBool(Params, 'confirm', False));
      O := TJSONObject.Create;
      O.Add('started', Started);
      O.Add('files', N);
      O.Add('dest', S);
      Result := O;
    end

    else if Method = 'delete' then
    begin
      View := GetPanel(Params, Side);
      if Assigned(PArr(Params, 'names')) then
        SelectNames(View, PArr(Params, 'names'), 'set');
      MakeActive(View);
      if PBool(Params, 'permanent', False) then
        // Permanent delete: always let the user confirm in Double Commander.
        Res := frmMain.Commands.Commands.ExecuteCommand('cm_Delete', ['trashcan=false', 'confirmation=1'])
      else
        Res := frmMain.Commands.Commands.ExecuteCommand('cm_Delete', ['trashcan=true', 'confirmation=0']);
      Result := TJSONBoolean.Create(Res = cfrSuccess);
    end

    else if Method = 'mkdir' then
    begin
      View := GetPanel(Params, Side);
      S := PStr(Params, 'name');
      if S = '' then raise Exception.Create('name is required');
      Op := View.FileSource.CreateCreateDirectoryOperation(View.CurrentPath, S);
      if not Assigned(Op) then raise Exception.Create('Not supported here');
      try
        Op.Execute;
        Result := TJSONBoolean.Create(Op.Result = fsorFinished);
      finally
        Op.Free;
      end;
      View.Reload(True);
    end

    else if Method = 'rename' then
    begin
      View := GetPanel(Params, Side);
      S := PStr(Params, 'from');
      F := nil;
      for I := 0 to View.DisplayFiles.Count - 1 do
        if View.DisplayFiles[I].FSFile.Name = S then
        begin
          F := View.DisplayFiles[I];
          Break;
        end;
      if F = nil then raise Exception.Create('Not found: ' + S);
      if PStr(Params, 'to') = '' then raise Exception.Create('to is required');
      Result := TJSONBoolean.Create(
        RenameFile(View.FileSource, F.FSFile, PStr(Params, 'to'), True, False) = sfprSuccess);
      View.Reload(True);
    end

    else if Method = 'run_command' then
    begin
      S := PStr(Params, 'command');
      if S = '' then raise Exception.Create('command is required');
      A := PArr(Params, 'params');
      SetLength(CmdParams, 0);
      if Assigned(A) then
      begin
        SetLength(CmdParams, A.Count);
        for I := 0 to A.Count - 1 do
          CmdParams[I] := A.Strings[I];
      end;
      Res := frmMain.Commands.Commands.ExecuteCommand(S, CmdParams);
      case Res of
        cfrSuccess:  Result := TJSONString.Create('ok');
        cfrDisabled: Result := TJSONString.Create('disabled');
        cfrNotFound: raise Exception.Create('Unknown command: ' + S);
      end;
    end

    else if Method = 'list_commands' then
    begin
      S := LowerCase(PStr(Params, 'filter'));
      List := TStringList.Create;
      try
        frmMain.Commands.Commands.GetCommandsList(List);
        A := TJSONArray.Create;
        for I := 0 to List.Count - 1 do
          if (S = '') or (Pos(S, LowerCase(List[I])) > 0) or
             (Pos(S, LowerCase(frmMain.Commands.Commands.GetCommandCaption(List[I], cctShort))) > 0) then
          begin
            O := TJSONObject.Create;
            O.Add('command', List[I]);
            O.Add('caption', StringReplace(frmMain.Commands.Commands.GetCommandCaption(List[I], cctShort), '&', '', [rfReplaceAll]));
            A.Add(O);
          end;
        Result := A;
      finally
        List.Free;
      end;
    end

    else if Method = 'operations' then
      Result := OperationsJson

    else
      raise Exception.Create('Unknown method: ' + Method);
  except
    on E: Exception do
    begin
      FreeAndNil(Result);
      Error := E.Message;
    end;
  end;
end;

{ ---------- server thread ---------- }

constructor TAgentServerThread.Create(APort: Integer);
begin
  FPort := APort;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TAgentServerThread.DoIdle(Sender: TObject);
begin
  if Terminated then
    FServer.Active := False;
end;

procedure TAgentServerThread.DoRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
var
  Call: TAgentCall;
  Body: TJSONData;
  Reply: TJSONObject;
  T0: QWord;
begin
  AResponse.ContentType := 'application/json';
  Reply := TJSONObject.Create;
  Call := TAgentCall.Create;
  Body := nil;
  try
    if ARequest.Authorization <> 'Bearer ' + FToken then
    begin
      AResponse.Code := 401;
      Reply.Add('ok', False);
      Reply.Add('error', 'unauthorized');
      Exit;
    end;
    if (ARequest.Method <> 'POST') or (ARequest.PathInfo <> '/rpc') then
    begin
      AResponse.Code := 404;
      Reply.Add('ok', False);
      Reply.Add('error', 'POST /rpc only');
      Exit;
    end;
    try
      Body := GetJSON(ARequest.Content);
    except
      on E: Exception do
      begin
        AResponse.Code := 400;
        Reply.Add('ok', False);
        Reply.Add('error', 'bad json: ' + E.Message);
        Exit;
      end;
    end;
    if not (Body is TJSONObject) then
    begin
      AResponse.Code := 400;
      Reply.Add('ok', False);
      Reply.Add('error', 'body must be an object');
      Exit;
    end;
    Call.Method := TJSONObject(Body).Get('method', '');
    if TJSONObject(Body).IndexOfName('params') >= 0 then
      if TJSONObject(Body).Items[TJSONObject(Body).IndexOfName('params')] is TJSONObject then
        Call.Params := TJSONObject(Body).Objects['params'];
    T0 := GetTickCount64;
    Synchronize(@Call.Run);
    MetricsLog('agent', ['method', Call.Method, 'ms', Int64(GetTickCount64 - T0),
                         'ok', Call.Error = '']);
    if Call.Error = '' then
    begin
      Reply.Add('ok', True);
      if Assigned(Call.Result) then
      begin
        Reply.Add('result', Call.Result);
        Call.Result := nil; // owned by Reply now
      end
      else
        Reply.Add('result', TJSONNull.Create);
    end
    else
    begin
      Reply.Add('ok', False);
      Reply.Add('error', Call.Error);
    end;
  finally
    AResponse.Content := Reply.AsJSON;
    Reply.Free;
    Call.Result.Free;
    Call.Free;
    Body.Free;
  end;
end;

procedure TAgentServerThread.Execute;
begin
  FServer := TFPHttpServer.Create(nil);
  try
    try
      THttpServerAccess(FServer).Address := '127.0.0.1';
      FServer.Port := FPort;
      FServer.Threaded := False;
      FServer.AcceptIdleTimeout := 300;
      FServer.OnAcceptIdle := @DoIdle;
      FServer.OnRequest := @DoRequest;
      FServer.Active := True;   // blocks until DoIdle sets Active := False
    except
      on E: Exception do
        FStartError := E.Message;
    end;
  finally
    FreeAndNil(FServer);
  end;
end;

{ ---------- public API ---------- }

procedure WriteEndpoint(Port: Integer);
var
  O: TJSONObject;
  SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(AgentEndpointFile));
  O := TJSONObject.Create;
  SL := TStringList.Create;
  try
    O.Add('url', Format('http://127.0.0.1:%d/rpc', [Port]));
    O.Add('port', Port);
    O.Add('token', FToken);
    O.Add('pid', Int64(GetProcessID));
    SL.Text := O.FormatJSON;
    SL.SaveToFile(AgentEndpointFile);
  finally
    SL.Free;
    O.Free;
  end;
end;

procedure StartServer;
var
  I: Integer;
begin
  if Assigned(FThread) then Exit;
  FToken := NewToken;
  for I := 0 to PortTries - 1 do
  begin
    FStartError := '';
    FThread := TAgentServerThread.Create(DefaultPort + I);
    // Give the listener a moment to bind (or fail).
    Sleep(150);
    if FStartError = '' then
    begin
      FBoundPort := DefaultPort + I;
      WriteEndpoint(FBoundPort);
      MetricsLog('agent_server', ['state', 'started', 'port', FBoundPort]);
      Exit;
    end;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  MetricsLog('agent_server', ['state', 'failed', 'error', FStartError]);
end;

procedure StopServer;
begin
  if not Assigned(FThread) then Exit;
  FThread.Terminate;
  // DoIdle notices Terminated within AcceptIdleTimeout. Keep serving
  // Synchronize calls meanwhile so a request in flight cannot deadlock us.
  while not FThread.Finished do
    CheckSynchronize(20);
  FThread.WaitFor;
  FreeAndNil(FThread);
  FBoundPort := 0;
  DeleteFile(AgentEndpointFile);
end;

procedure AgentServerInit(const CfgDir: String);
begin
  FCfgDir := IncludeTrailingPathDelimiter(CfgDir);
  FEnabled := FileExists(MarkerFile);
  if FEnabled then StartServer;
end;

procedure AgentServerShutdown;
begin
  StopServer;
end;

function AgentServerEnabled: Boolean;
begin
  Result := FEnabled;
end;

procedure AgentServerSetEnabled(Value: Boolean);
var
  SL: TStringList;
begin
  if Value = FEnabled then Exit;
  FEnabled := Value;
  if Value then
  begin
    SL := TStringList.Create;
    try
      SL.Text := 'Delete this file to turn off the agent control server.';
      SL.SaveToFile(MarkerFile);
    finally
      SL.Free;
    end;
    StartServer;
  end
  else
  begin
    DeleteFile(MarkerFile);
    StopServer;
  end;
end;

function AgentServerRunning: Boolean;
begin
  Result := Assigned(FThread) and (FBoundPort <> 0);
end;

function AgentServerPort: Integer;
begin
  Result := FBoundPort;
end;

end.
