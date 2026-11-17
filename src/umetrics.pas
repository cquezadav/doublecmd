{
   [my-custom] Metrics log for Double Commander.

   Writes one JSON object per line ("JSON Lines") to
     <config dir>/metrics/metrics-YYYY-MM-DD.jsonl
   Every line has: ts (local time), sid (session id), ev (event name),
   plus event-specific fields.

   Off by default. Enabled when the marker file <config dir>/metrics.enabled
   exists (toggled from Configuration > Metrics log).

   Events
     session_start / session_end   version, os, uptime
     startup                       ms from process start to main window shown
     cmd                           command name, source (hotkey/menu/toolbar/
                                   other/nested), shortcut, result, ms
     folder                        folder listing: path, fs, files, list_ms,
                                   build_ms, ui_ms, total_ms, kind, ok
     op                            finished file operation (see uMetricsHooks)
     drives                        drive bar refresh: ms, count
     drive_click                   drive button used: drive, panel
     freeze                        main thread unresponsive >= 500 ms: ms,
                                   activity (what it was doing), last_cmd,
                                   last_folder
     freeze_ongoing                logged once if a freeze passes 5 s

   Thread-safety: MetricsLog may be called from any thread. Command/activity
   tracking and Init/Shutdown/SetEnabled are main-thread only.
}
unit uMetrics;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{en Call once on the main thread after the config dir is known. }
procedure MetricsInit(const AConfigDir: String);
procedure MetricsShutdown;

function MetricsEnabled: Boolean;
procedure MetricsSetEnabled(AValue: Boolean);
function MetricsDir: String;

{en Milliseconds tick counter. }
function MetricsTick: QWord;
{en Tick recorded when this unit was initialized (approx. process start). }
function MetricsProcessStartTick: QWord;

{en Log an event. Fields are key/value pairs:
    MetricsLog('folder', ['path', Path, 'ms', 12]) }
procedure MetricsLog(const Event: String; const Fields: array of const);

{en Main thread: what the UI thread is busy with (shown in freeze events).
    Returns the previous activity so it can be restored. }
function MetricsActivityBegin(const Activity: String): String;
procedure MetricsActivityEnd(const Previous: String);

{en Main thread: tag where the next command comes from. Consumed by the
    next top-level MetricsCommandBegin. }
procedure MetricsSetCmdSource(const Source: String; const Shortcut: String = '');

type
  TMetricsCmdToken = record
    Command, Source, Shortcut, PrevActivity: String;
    Start: QWord;
    TopLevel: Boolean;
  end;

function MetricsCommandBegin(const Command: String): TMetricsCmdToken;
procedure MetricsCommandEnd(const Token: TMetricsCmdToken; const ResultText: String);

{en Remember the last folder listed (used as freeze context). Any thread. }
procedure MetricsSetLastFolder(const Path: String);

implementation

uses
  syncobjs, ExtCtrls;

const
  MARKER_FILE = 'metrics.enabled';
  FREEZE_MS = 500;           // report main-thread stalls at least this long
  FREEZE_ONGOING_MS = 5000;  // also report a long freeze while it is still going
  SUSPEND_MS = 120000;       // longer gaps are treated as sleep/hibernate
  HEARTBEAT_MS = 100;

type
  { Watchdog thread: notices when the main-thread heartbeat stops. }
  TMetricsWatchdog = class(TThread)
  protected
    procedure Execute; override;
  end;

  { Main-thread heartbeat timer owner. }
  THeartbeat = class
    Timer: TTimer;
    procedure OnTimer(Sender: TObject);
  end;

var
  Lock: TCriticalSection = nil;
  FStream: TFileStream = nil;
  FStreamDay: String = '';
  FConfigDir: String = '';
  FEnabled: Boolean = False;
  FInitialized: Boolean = False;
  FSessionId: String = '';
  FStartTick: QWord = 0;
  FSessionStartTick: QWord = 0;
  // shared with the watchdog thread (guarded by Lock)
  FLastBeat: QWord = 0;
  FActivity: String = '';
  FLastCmd: String = '';
  FLastFolder: String = '';
  // main thread only
  FCmdSource: String = '';
  FCmdShortcut: String = '';
  FCmdDepth: Integer = 0;
  FWatchdog: TMetricsWatchdog = nil;
  FHeartbeat: THeartbeat = nil;
  JsonFormat: TFormatSettings;  // '.' decimal separator regardless of locale

function MetricsTick: QWord;
begin
  Result := GetTickCount64;
end;

function MetricsProcessStartTick: QWord;
begin
  Result := FStartTick;
end;

function MetricsEnabled: Boolean;
begin
  Result := FEnabled;
end;

function MetricsDir: String;
begin
  Result := IncludeTrailingPathDelimiter(FConfigDir) + 'metrics';
end;

{ ---- JSON helpers ---- }

function JsonEscape(const S: String): String;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8:  Result := Result + '\b';
      #9:  Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      #0..#7, #11, #14..#31:
        Result := Result + '\u' + IntToHex(Ord(C), 4);
    else
      Result := Result + C;  // UTF-8 bytes pass through unchanged
    end;
  end;
end;

function JsonValue(const V: TVarRec): String;
begin
  case V.VType of
    vtInteger:       Result := IntToStr(V.VInteger);
    vtInt64:         Result := IntToStr(V.VInt64^);
    vtQWord:         Result := IntToStr(V.VQWord^);
    vtBoolean:       if V.VBoolean then Result := 'true' else Result := 'false';
    vtExtended:      Result := FormatFloat('0.###', V.VExtended^, JsonFormat);
    vtCurrency:      Result := FormatFloat('0.###', V.VCurrency^, JsonFormat);
    vtChar:          Result := '"' + JsonEscape(V.VChar) + '"';
    vtWideChar:      Result := '"' + JsonEscape(UTF8Encode(WideString(V.VWideChar))) + '"';
    vtString:        Result := '"' + JsonEscape(V.VString^) + '"';
    vtAnsiString:    Result := '"' + JsonEscape(AnsiString(V.VAnsiString)) + '"';
    vtPChar:         Result := '"' + JsonEscape(StrPas(V.VPChar)) + '"';
    vtUnicodeString: Result := '"' + JsonEscape(UTF8Encode(UnicodeString(V.VUnicodeString))) + '"';
    vtWideString:    Result := '"' + JsonEscape(UTF8Encode(WideString(V.VWideString))) + '"';
  else
    Result := 'null';
  end;
end;

function VarRecToStr(const V: TVarRec): String;
begin
  case V.VType of
    vtString:        Result := V.VString^;
    vtAnsiString:    Result := AnsiString(V.VAnsiString);
    vtUnicodeString: Result := UTF8Encode(UnicodeString(V.VUnicodeString));
    vtChar:          Result := V.VChar;
    vtPChar:         Result := StrPas(V.VPChar);
  else
    Result := '?';
  end;
end;

{ ---- file writing (caller holds Lock) ---- }

procedure CloseStream;
begin
  FreeAndNil(FStream);
  FStreamDay := '';
end;

function EnsureStream: Boolean;
var
  Day, FileName: String;
begin
  Day := FormatDateTime('yyyy-mm-dd', Now);
  if Assigned(FStream) and (Day = FStreamDay) then
    Exit(True);
  CloseStream;
  try
    ForceDirectories(MetricsDir);
    FileName := MetricsDir + PathDelim + 'metrics-' + Day + '.jsonl';
    if FileExists(FileName) then
    begin
      FStream := TFileStream.Create(FileName, fmOpenWrite or fmShareDenyNone);
      FStream.Seek(0, soEnd);
    end
    else
      FStream := TFileStream.Create(FileName, fmCreate or fmShareDenyNone);
    FStreamDay := Day;
    Result := True;
  except
    CloseStream;
    Result := False;
  end;
end;

procedure WriteLine(const Line: String);
var
  S: String;
begin
  if not EnsureStream then Exit;
  S := Line + LineEnding;
  try
    FStream.WriteBuffer(S[1], Length(S));
  except
    CloseStream;  // e.g. disk full: stop trying until the next event
  end;
end;

procedure MetricsLog(const Event: String; const Fields: array of const);
var
  Line: String;
  I: Integer;
begin
  if not (FEnabled and FInitialized) then Exit;
  Line := '{"ts":"' + FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now) +
          '","sid":"' + FSessionId + '","ev":"' + JsonEscape(Event) + '"';
  I := 0;
  while I + 1 <= High(Fields) do
  begin
    Line := Line + ',"' + JsonEscape(VarRecToStr(Fields[I])) + '":' + JsonValue(Fields[I + 1]);
    Inc(I, 2);
  end;
  Line := Line + '}';
  Lock.Acquire;
  try
    WriteLine(Line);
  finally
    Lock.Release;
  end;
end;

{ ---- activity / command tracking ---- }

function MetricsActivityBegin(const Activity: String): String;
begin
  Lock.Acquire;
  try
    Result := FActivity;
    FActivity := Activity;
  finally
    Lock.Release;
  end;
end;

procedure MetricsActivityEnd(const Previous: String);
begin
  Lock.Acquire;
  try
    FActivity := Previous;
  finally
    Lock.Release;
  end;
end;

procedure MetricsSetCmdSource(const Source: String; const Shortcut: String);
begin
  FCmdSource := Source;
  FCmdShortcut := Shortcut;
end;

function MetricsCommandBegin(const Command: String): TMetricsCmdToken;
begin
  Result.Command := Command;
  Result.Start := MetricsTick;
  Result.TopLevel := FCmdDepth = 0;
  if Result.TopLevel then
  begin
    if FCmdSource <> '' then Result.Source := FCmdSource else Result.Source := 'other';
    Result.Shortcut := FCmdShortcut;
  end
  else begin
    Result.Source := 'nested';
    Result.Shortcut := '';
  end;
  FCmdSource := '';
  FCmdShortcut := '';
  Inc(FCmdDepth);
  Result.PrevActivity := MetricsActivityBegin('cmd:' + Command);
  Lock.Acquire;
  try
    if Result.TopLevel then FLastCmd := Command;
  finally
    Lock.Release;
  end;
end;

procedure MetricsCommandEnd(const Token: TMetricsCmdToken; const ResultText: String);
begin
  Dec(FCmdDepth);
  if FCmdDepth < 0 then FCmdDepth := 0;
  MetricsActivityEnd(Token.PrevActivity);
  if Token.Shortcut <> '' then
    MetricsLog('cmd', ['cmd', Token.Command, 'source', Token.Source,
      'shortcut', Token.Shortcut, 'result', ResultText,
      'ms', Int64(MetricsTick - Token.Start)])
  else
    MetricsLog('cmd', ['cmd', Token.Command, 'source', Token.Source,
      'result', ResultText, 'ms', Int64(MetricsTick - Token.Start)]);
end;

procedure MetricsSetLastFolder(const Path: String);
begin
  if Lock = nil then Exit;
  Lock.Acquire;
  try
    FLastFolder := Path;
  finally
    Lock.Release;
  end;
end;

{ ---- freeze detection ---- }

procedure THeartbeat.OnTimer(Sender: TObject);
begin
  Lock.Acquire;
  try
    FLastBeat := MetricsTick;
  finally
    Lock.Release;
  end;
end;

procedure TMetricsWatchdog.Execute;
var
  Beat, PrevBeat, Gap, FreezeStart: QWord;
  InFreeze, ReportedLong: Boolean;
  Activity, LastCmd, LastFolder: String;
  FrzActivity, FrzLastCmd, FrzLastFolder: String;
begin
  InFreeze := False;
  ReportedLong := False;
  FreezeStart := 0;
  PrevBeat := 0;
  while not Terminated do
  begin
    Sleep(50);
    Lock.Acquire;
    try
      Beat := FLastBeat;
      Activity := FActivity;
      LastCmd := FLastCmd;
      LastFolder := FLastFolder;
    finally
      Lock.Release;
    end;
    if Beat = 0 then Continue;  // heartbeat not started yet
    Gap := MetricsTick - Beat;

    if not InFreeze then
    begin
      if Gap >= FREEZE_MS + HEARTBEAT_MS then
      begin
        InFreeze := True;
        ReportedLong := False;
        FreezeStart := Beat;
        PrevBeat := Beat;
        FrzActivity := Activity;
        FrzLastCmd := LastCmd;
        FrzLastFolder := LastFolder;
        // capture what the main thread is doing *now*, while it is stuck
        MetricsLog('freeze_begin', ['activity', Activity, 'last_cmd', LastCmd,
          'last_folder', LastFolder]);
      end;
    end
    else if Beat <> PrevBeat then
    begin
      // heartbeat resumed: the stall lasted from the last beat before it
      // until this beat (minus one normal timer interval)
      InFreeze := False;
      if Beat - FreezeStart >= SUSPEND_MS then
        MetricsLog('suspend_gap', ['ms', Int64(Beat - FreezeStart)])
      else
        MetricsLog('freeze', ['ms', Int64(Beat - FreezeStart - HEARTBEAT_MS),
          'activity', FrzActivity, 'last_cmd', FrzLastCmd, 'last_folder', FrzLastFolder]);
    end
    else if (not ReportedLong) and (Gap >= FREEZE_ONGOING_MS) and (Gap < SUSPEND_MS) then
    begin
      ReportedLong := True;
      MetricsLog('freeze_ongoing', ['ms', Int64(Gap), 'activity', Activity,
        'last_cmd', LastCmd, 'last_folder', LastFolder]);
    end;
  end;
end;

procedure StartMonitoring;
begin
  if Assigned(FWatchdog) then Exit;
  Lock.Acquire;
  try
    FLastBeat := MetricsTick;
  finally
    Lock.Release;
  end;
  FHeartbeat := THeartbeat.Create;
  FHeartbeat.Timer := TTimer.Create(nil);
  FHeartbeat.Timer.Interval := HEARTBEAT_MS;
  FHeartbeat.Timer.OnTimer := @FHeartbeat.OnTimer;
  FHeartbeat.Timer.Enabled := True;
  FWatchdog := TMetricsWatchdog.Create(False);
end;

procedure StopMonitoring;
begin
  if Assigned(FWatchdog) then
  begin
    FWatchdog.Terminate;
    FWatchdog.WaitFor;
    FreeAndNil(FWatchdog);
  end;
  if Assigned(FHeartbeat) then
  begin
    FHeartbeat.Timer.Free;
    FreeAndNil(FHeartbeat);
  end;
end;

{ ---- lifecycle ---- }

procedure LogSessionStart;
begin
  MetricsLog('session_start', ['exe', ParamStr(0),
    'os', {$I %FPCTARGETOS%}, 'cpu', {$I %FPCTARGETCPU%},
    'build', {$I %DATE%} + ' ' + {$I %TIME%}, 'pid', Int64(GetProcessID)]);
end;

procedure MetricsInit(const AConfigDir: String);
begin
  if FInitialized then Exit;
  FConfigDir := AConfigDir;
  FSessionId := IntToHex(Random($FFFFFF), 6) + IntToHex(GetProcessID and $FFFF, 4);
  FSessionStartTick := MetricsTick;
  FEnabled := FileExists(IncludeTrailingPathDelimiter(FConfigDir) + MARKER_FILE);
  FInitialized := True;
  if FEnabled then
  begin
    LogSessionStart;
    StartMonitoring;
  end;
end;

procedure MetricsShutdown;
begin
  if not FInitialized then Exit;
  StopMonitoring;
  if FEnabled then
    MetricsLog('session_end', ['uptime_s', Int64((MetricsTick - FStartTick) div 1000)]);
  Lock.Acquire;
  try
    CloseStream;
  finally
    Lock.Release;
  end;
  FInitialized := False;
end;

procedure MetricsSetEnabled(AValue: Boolean);
var
  Marker: String;
  F: THandle;
begin
  if not FInitialized or (AValue = FEnabled) then Exit;
  Marker := IncludeTrailingPathDelimiter(FConfigDir) + MARKER_FILE;
  if AValue then
  begin
    F := FileCreate(Marker);
    if F <> THandle(-1) then FileClose(F);
    FEnabled := True;
    LogSessionStart;
    MetricsLog('metrics_on', []);
    StartMonitoring;
  end
  else begin
    MetricsLog('metrics_off', []);
    StopMonitoring;
    FEnabled := False;
    DeleteFile(Marker);
    Lock.Acquire;
    try
      CloseStream;
    finally
      Lock.Release;
    end;
  end;
end;

initialization
  FStartTick := GetTickCount64;
  JsonFormat := DefaultFormatSettings;
  JsonFormat.DecimalSeparator := '.';
  JsonFormat.ThousandSeparator := #0;
  Lock := TCriticalSection.Create;
  Randomize;

finalization
  // MetricsShutdown must be called before the LCL is torn down (doublecmd.lpr).
  // If it was not, only stop the thread; the TTimer can't be freed safely here.
  if Assigned(FWatchdog) then
  begin
    FWatchdog.Terminate;
    FWatchdog.WaitFor;
    FreeAndNil(FWatchdog);
  end;
  if FInitialized then
  begin
    FInitialized := False;
    FEnabled := False;
    FreeAndNil(FStream);
  end;
  FreeAndNil(Lock);

end.
