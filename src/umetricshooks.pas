{
   [my-custom] Metrics hooks that need the file-operation units.
   Kept separate from uMetrics so low-level units can use uMetrics
   without unit cycles.

   'op' event fields: op (fsoCopy, fsoMove, fsoDelete, ...), class, result
   (fsorFinished/fsorAborted), ms, desc, and when available: files_done,
   files_total, bytes_done, bytes_total, mb_s, src_fs, dst_fs.
}
unit uMetricsHooks;

{$mode objfpc}{$H+}

interface

procedure MetricsHooksInstall;
procedure MetricsHooksRemove;

implementation

uses
  SysUtils, DateUtils, TypInfo, uMetrics, uOperationsManager,
  uFileSourceOperation, uFileSourceOperationTypes,
  uFileSourceCopyOperation, uFileSourceMoveOperation,
  uFileSourceDeleteOperation;

type
  TOpListener = class
    procedure OnEvent(Item: TOperationsManagerItem; Event: TOperationManagerEvent);
  end;

var
  Listener: TOpListener = nil;

function MBps(Bytes: Int64; Ms: Int64): Double;
begin
  if Ms <= 0 then
    Result := 0
  else
    Result := (Bytes / 1048576) / (Ms / 1000);
end;

procedure TOpListener.OnEvent(Item: TOperationsManagerItem; Event: TOperationManagerEvent);
var
  Op: TFileSourceOperation;
  Ms: Int64;
  OpName, ResName, Desc: String;
  CopyStats: TFileSourceCopyOperationStatistics;
  DelStats: TFileSourceDeleteOperationStatistics;
begin
  if not MetricsEnabled or (Event <> omevOperationRemoved) then Exit;
  Op := Item.Operation;
  if not Assigned(Op) then Exit;
  try
    if Op.StartTime > 0 then
      Ms := MilliSecondsBetween(Now, Op.StartTime)
    else
      Ms := 0;
    OpName := GetEnumName(TypeInfo(TFileSourceOperationType), Ord(Op.ID));
    ResName := GetEnumName(TypeInfo(TFileSourceOperationResult), Ord(Op.Result));
    Desc := Op.GetDescription(fsoddJobAndTarget);

    if Op is TFileSourceCopyOperation then
    begin
      CopyStats := TFileSourceCopyOperation(Op).RetrieveStatistics;
      MetricsLog('op', ['op', OpName, 'class', Op.ClassName, 'result', ResName,
        'ms', Ms, 'files_done', CopyStats.DoneFiles, 'files_total', CopyStats.TotalFiles,
        'bytes_done', CopyStats.DoneBytes, 'bytes_total', CopyStats.TotalBytes,
        'mb_s', MBps(CopyStats.DoneBytes, Ms),
        'src_fs', TFileSourceCopyOperation(Op).SourceFileSource.ClassName,
        'dst_fs', TFileSourceCopyOperation(Op).TargetFileSource.ClassName,
        'desc', Desc]);
    end
    else if Op is TFileSourceMoveOperation then
    begin
      CopyStats := TFileSourceMoveOperation(Op).RetrieveStatistics;
      MetricsLog('op', ['op', OpName, 'class', Op.ClassName, 'result', ResName,
        'ms', Ms, 'files_done', CopyStats.DoneFiles, 'files_total', CopyStats.TotalFiles,
        'bytes_done', CopyStats.DoneBytes, 'bytes_total', CopyStats.TotalBytes,
        'mb_s', MBps(CopyStats.DoneBytes, Ms), 'desc', Desc]);
    end
    else if Op is TFileSourceDeleteOperation then
    begin
      DelStats := TFileSourceDeleteOperation(Op).RetrieveStatistics;
      MetricsLog('op', ['op', OpName, 'class', Op.ClassName, 'result', ResName,
        'ms', Ms, 'files_done', DelStats.DoneFiles, 'files_total', DelStats.TotalFiles,
        'bytes_total', DelStats.TotalBytes, 'desc', Desc]);
    end
    else
      MetricsLog('op', ['op', OpName, 'class', Op.ClassName, 'result', ResName,
        'ms', Ms, 'desc', Desc]);
  except
    on E: Exception do
      MetricsLog('metrics_error', ['where', 'op', 'msg', E.Message]);
  end;
end;

procedure MetricsHooksInstall;
begin
  if Assigned(Listener) then Exit;
  Listener := TOpListener.Create;
  OperationsManager.AddEventsListener([omevOperationRemoved], @Listener.OnEvent);
end;

procedure MetricsHooksRemove;
begin
  if not Assigned(Listener) then Exit;
  if Assigned(OperationsManager) then
    OperationsManager.RemoveEventsListener([omevOperationRemoved], @Listener.OnEvent);
  FreeAndNil(Listener);
end;

end.
