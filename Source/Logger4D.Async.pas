(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D.Async;

(*******************************************************************************
  Logger4D.Async

  TAsyncAppender wraps any other appender and moves the slow part (formatting
  and I/O of the wrapped appender) to a dedicated worker thread, so that the
  calling thread only pays for a queue insert.

  Overflow policies when the queue is full:
    aoBlock       the caller waits for free space (no entries are lost)
    aoDropNewest  the new entry is discarded
    aoDropOldest  the oldest queued entry is discarded
*******************************************************************************)

interface

uses
  SysUtils, Classes, SyncObjs,
  Logger4D.Types, Logger4D.Appenders;

type
  TAsyncOverflowPolicy = (aoBlock, aoDropNewest, aoDropOldest);

  TAsyncAppender = class;

  TAsyncWorker = class(TThread)
  private
    FOwner: TAsyncAppender;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAsyncAppender);
  end;

  TAsyncAppender = class(TLogAppenderBase)
  private
    FTarget: ILogAppender;
    FQueue: TList;
    FQueueLock: TCriticalSection;
    FDataEvent: TEvent;
    FSpaceEvent: TEvent;
    FWorker: TAsyncWorker;
    FMaxQueue: Integer;
    FPolicy: TAsyncOverflowPolicy;
    FInFlight: Boolean;
    FStopping: Boolean;
    FDropped: Integer;
    function TryDequeue(out AEvent: TLogEvent): Boolean;
    procedure Processed;
    procedure Enqueue(AEvent: TLogEvent);
    function IsIdle: Boolean;
    function IsStopping: Boolean;
    function GetDroppedCount: Integer;
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
  public
    constructor Create(const ATarget: ILogAppender; AQueueSize: Integer = 8192;
      APolicy: TAsyncOverflowPolicy = aoBlock);
    destructor Destroy; override;
    procedure Append(const AEvent: TLogEvent); override;
    /// <summary>Waits until every queued entry has been written, then flushes the target.</summary>
    procedure Flush; override;
    /// <summary>Drains the queue, stops the worker thread and closes the target.</summary>
    procedure Close; override;
    /// <summary>Internal: the worker thread main loop.</summary>
    procedure WorkerLoop;
    property DroppedCount: Integer read GetDroppedCount;
  end;

implementation

{ TAsyncWorker }

constructor TAsyncWorker.Create(AOwner: TAsyncAppender);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TAsyncWorker.Execute;
begin
  FOwner.WorkerLoop;
end;

{ TAsyncAppender }

constructor TAsyncAppender.Create(const ATarget: ILogAppender; AQueueSize: Integer;
  APolicy: TAsyncOverflowPolicy);
begin
  inherited Create('Async(' + ATarget.Name + ')');
  FTarget := ATarget;
  FMaxQueue := AQueueSize;
  if FMaxQueue < 1 then
    FMaxQueue := 1;
  FPolicy := APolicy;
  FQueue := TList.Create;
  FQueueLock := TCriticalSection.Create;
  FDataEvent := TEvent.Create(nil, False, False, '');
  FSpaceEvent := TEvent.Create(nil, True, True, '');
  FWorker := TAsyncWorker.Create(Self);
end;

destructor TAsyncAppender.Destroy;
var
  I: Integer;
begin
  Close;
  for I := 0 to FQueue.Count - 1 do
    TLogEvent(FQueue[I]).Free;
  FQueue.Free;
  FSpaceEvent.Free;
  FDataEvent.Free;
  FQueueLock.Free;
  FTarget := nil;
  inherited Destroy;
end;

function TAsyncAppender.IsStopping: Boolean;
begin
  FQueueLock.Enter;
  try
    Result := FStopping;
  finally
    FQueueLock.Leave;
  end;
end;

function TAsyncAppender.IsIdle: Boolean;
begin
  FQueueLock.Enter;
  try
    Result := (FQueue.Count = 0) and (not FInFlight);
  finally
    FQueueLock.Leave;
  end;
end;

function TAsyncAppender.GetDroppedCount: Integer;
begin
  FQueueLock.Enter;
  try
    Result := FDropped;
  finally
    FQueueLock.Leave;
  end;
end;

function TAsyncAppender.TryDequeue(out AEvent: TLogEvent): Boolean;
begin
  AEvent := nil;
  FQueueLock.Enter;
  try
    Result := FQueue.Count > 0;
    if Result then
    begin
      AEvent := TLogEvent(FQueue[0]);
      FQueue.Delete(0);
      FInFlight := True;
      FSpaceEvent.SetEvent;
    end;
  finally
    FQueueLock.Leave;
  end;
end;

procedure TAsyncAppender.Processed;
begin
  FQueueLock.Enter;
  try
    FInFlight := False;
  finally
    FQueueLock.Leave;
  end;
end;

procedure TAsyncAppender.Enqueue(AEvent: TLogEvent);
var
  Done: Boolean;
begin
  Done := False;
  repeat
    FQueueLock.Enter;
    try
      if FStopping then
      begin
        AEvent.Free;
        Exit;
      end;
      if FQueue.Count < FMaxQueue then
      begin
        FQueue.Add(AEvent);
        Done := True;
      end
      else
      begin
        case FPolicy of
          aoDropNewest:
            begin
              AEvent.Free;
              Inc(FDropped);
              Exit;
            end;
          aoDropOldest:
            begin
              TLogEvent(FQueue[0]).Free;
              FQueue.Delete(0);
              FQueue.Add(AEvent);
              Inc(FDropped);
              Done := True;
            end;
        else
          FSpaceEvent.ResetEvent;   // aoBlock: wait outside the lock
        end;
      end;
    finally
      FQueueLock.Leave;
    end;
    if Done then
      FDataEvent.SetEvent
    else
      FSpaceEvent.WaitFor(50);
  until Done;
end;

procedure TAsyncAppender.WorkerLoop;
var
  E: TLogEvent;
  Stopping: Boolean;
begin
  while True do
  begin
    FDataEvent.WaitFor(250);
    // Read the flag BEFORE draining: once it is set no new entry can be queued,
    // so the drain below is guaranteed to be the last one.
    Stopping := IsStopping;
    while TryDequeue(E) do
    begin
      try
        try
          FTarget.Append(E);
        except
          // a failing target must never kill the worker thread
        end;
      finally
        E.Free;
        Processed;
      end;
    end;
    if Stopping then
      Break;
  end;
end;

procedure TAsyncAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
begin
  // not used: Append is overridden
end;

procedure TAsyncAppender.Append(const AEvent: TLogEvent);
begin
  if IsClosed or (AEvent.Level < MinLevel) then
    Exit;
  if Assigned(OnFilter) and (not OnFilter(AEvent)) then
    Exit;
  Enqueue(AEvent.Clone);
end;

procedure TAsyncAppender.Flush;
begin
  if FWorker <> nil then
  begin
    while not IsIdle do
    begin
      FDataEvent.SetEvent;
      Sleep(1);
    end;
  end;
  FTarget.Flush;
end;

procedure TAsyncAppender.Close;
begin
  if FWorker <> nil then
  begin
    FQueueLock.Enter;
    try
      FStopping := True;
      FSpaceEvent.SetEvent;
    finally
      FQueueLock.Leave;
    end;
    FDataEvent.SetEvent;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
    FTarget.Close;
  end;
  inherited Close;
end;

end.
