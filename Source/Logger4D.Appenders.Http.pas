(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D.Appenders.Http;

(*******************************************************************************
  Logger4D.Appenders.Http

  THttpAppender collects log entries and POSTs them in batches to an HTTP(S)
  endpoint from its own background thread. The calling thread only pays for a
  buffer insert.

  Body formats:
    AsJsonArray = False (default)  newline separated JSON objects (NDJSON)
    AsJsonArray = True             one JSON array: [{...},{...}]
  The default formatter is TJsonFormatter, so the body is JSON. Use Headers to
  add authentication, e.g. Headers.Values['Authorization'] := 'Bearer ...'.

  A batch is sent when BatchSize entries are buffered, every FlushIntervalMs,
  and on Flush/Close. A failed batch is retried MaxRetries times; if it still
  fails the entries are dropped and OnError is called (from the worker thread).
  When more than MaxBuffered entries are waiting, the oldest are dropped.

  Dependencies:
    Delphi        System.Net.HttpClient (Delphi XE8 or newer)
    Free Pascal   fphttpclient + opensslsockets (3.2+); OpenSSL libraries are
                  needed at run time for https:// URLs
*******************************************************************************)

interface

uses
  SysUtils, Classes, SyncObjs,
  {$IFDEF FPC}fphttpclient, opensslsockets,{$ELSE}System.Net.HttpClient, System.Net.URLClient,{$ENDIF}
  Logger4D.Types, Logger4D.Formatters, Logger4D.Appenders;

{$IFNDEF FPC}
  {$IF CompilerVersion < 29}
    {$MESSAGE FATAL 'THttpAppender requires Delphi XE8 or newer (System.Net.HttpClient).'}
  {$IFEND}
{$ENDIF}

type
  THttpAppender = class;

  THttpWorker = class(TThread)
  private
    FOwner: THttpAppender;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: THttpAppender);
  end;

  THttpAppender = class(TLogAppenderBase)
  private
    FUrl: string;
    FContentType: string;
    FHeaders: TStringList;
    FBuffer: TStringList;
    FWake: TEvent;
    FWorker: THttpWorker;
    FBatchSize: Integer;
    FMaxBuffered: Integer;
    FFlushIntervalMs: Integer;
    FMaxRetries: Integer;
    FRetryDelayMs: Integer;
    FTimeoutMs: Integer;
    FAsJsonArray: Boolean;
    FOnError: TLogErrorEvent;
    FSending: Boolean;
    FStopping: Boolean;
    FDropped: Integer;
    function IsStopping: Boolean;
    function IsIdle: Boolean;
    function TakeBatch(ABatch: TStringList): Boolean;
    procedure BatchDone;
    function BuildBody(ABatch: TStringList): string;
    procedure PostBody(const ABody: string);
    procedure SendBatch(ABatch: TStringList);
    procedure SendAll;
    function GetDroppedCount: Integer;
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
  public
    constructor Create(const AUrl: string; const AFormatter: ILogFormatter = nil);
    destructor Destroy; override;
    procedure Flush; override;
    procedure Close; override;
    /// <summary>Internal: the worker thread main loop.</summary>
    procedure WorkerLoop;
    property Url: string read FUrl write FUrl;
    /// <summary>Extra request headers as Name=Value lines. Set before the first log entry.</summary>
    property Headers: TStringList read FHeaders;
    property ContentType: string read FContentType write FContentType;
    property AsJsonArray: Boolean read FAsJsonArray write FAsJsonArray;
    property BatchSize: Integer read FBatchSize write FBatchSize;
    property MaxBuffered: Integer read FMaxBuffered write FMaxBuffered;
    property FlushIntervalMs: Integer read FFlushIntervalMs write FFlushIntervalMs;
    property MaxRetries: Integer read FMaxRetries write FMaxRetries;
    property RetryDelayMs: Integer read FRetryDelayMs write FRetryDelayMs;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    property DroppedCount: Integer read GetDroppedCount;
    property OnError: TLogErrorEvent read FOnError write FOnError;
  end;

implementation

{ THttpWorker }

constructor THttpWorker.Create(AOwner: THttpAppender);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure THttpWorker.Execute;
begin
  FOwner.WorkerLoop;
end;

{ THttpAppender }

constructor THttpAppender.Create(const AUrl: string; const AFormatter: ILogFormatter);
var
  Fmt: ILogFormatter;
begin
  if AFormatter <> nil then
    Fmt := AFormatter
  else
    Fmt := TJsonFormatter.Create(True, True);
  inherited Create('Http', Fmt);
  FUrl := AUrl;
  FContentType := 'application/x-ndjson';
  FHeaders := TStringList.Create;
  FBuffer := TStringList.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FBatchSize := 50;
  FMaxBuffered := 10000;
  FFlushIntervalMs := 2000;
  FMaxRetries := 2;
  FRetryDelayMs := 500;
  FTimeoutMs := 10000;
end;

destructor THttpAppender.Destroy;
begin
  Close;
  FWake.Free;
  FBuffer.Free;
  FHeaders.Free;
  inherited Destroy;
end;

function THttpAppender.IsStopping: Boolean;
begin
  Lock;
  try
    Result := FStopping;
  finally
    Unlock;
  end;
end;

function THttpAppender.IsIdle: Boolean;
begin
  Lock;
  try
    Result := (FBuffer.Count = 0) and (not FSending);
  finally
    Unlock;
  end;
end;

function THttpAppender.GetDroppedCount: Integer;
begin
  Lock;
  try
    Result := FDropped;
  finally
    Unlock;
  end;
end;

procedure THttpAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
begin
  // runs under the appender lock
  if FStopping then
    Exit;
  if FWorker = nil then
    FWorker := THttpWorker.Create(Self);
  FBuffer.Add(AFormatted);
  while (FMaxBuffered > 0) and (FBuffer.Count > FMaxBuffered) do
  begin
    FBuffer.Delete(0);
    Inc(FDropped);
  end;
  if FBuffer.Count >= FBatchSize then
    FWake.SetEvent;
end;

function THttpAppender.TakeBatch(ABatch: TStringList): Boolean;
var
  I, N: Integer;
begin
  ABatch.Clear;
  Lock;
  try
    N := FBuffer.Count;
    if N > FBatchSize then
      N := FBatchSize;
    for I := 0 to N - 1 do
      ABatch.Add(FBuffer[I]);
    for I := 1 to N do
      FBuffer.Delete(0);
    if N > 0 then
      FSending := True;
    Result := N > 0;
  finally
    Unlock;
  end;
end;

procedure THttpAppender.BatchDone;
begin
  Lock;
  try
    FSending := False;
  finally
    Unlock;
  end;
end;

function THttpAppender.BuildBody(ABatch: TStringList): string;
var
  I: Integer;
begin
  Result := '';
  if FAsJsonArray then
  begin
    for I := 0 to ABatch.Count - 1 do
    begin
      if I > 0 then
        Result := Result + ',';
      Result := Result + ABatch[I];
    end;
    Result := '[' + Result + ']';
  end
  else
    for I := 0 to ABatch.Count - 1 do
      Result := Result + ABatch[I] + #10;
end;

{$IFDEF FPC}

procedure THttpAppender.PostBody(const ABody: string);
var
  Client: TFPHTTPClient;
  Request, Response: TMemoryStream;
  Data: UTF8String;
  I: Integer;
begin
  Client := TFPHTTPClient.Create(nil);
  Request := TMemoryStream.Create;
  Response := TMemoryStream.Create;
  try
    Data := UTF8Encode(ABody);
    Request.WriteBuffer(Pointer(Data)^, Length(Data));
    Request.Position := 0;
    Client.RequestBody := Request;
    Client.IOTimeout := FTimeoutMs;
    Client.AddHeader('Content-Type', FContentType);
    for I := 0 to FHeaders.Count - 1 do
      Client.AddHeader(FHeaders.Names[I], FHeaders.ValueFromIndex[I]);
    Client.HTTPMethod('POST', FUrl, Response, []);
    if (Client.ResponseStatusCode < 200) or (Client.ResponseStatusCode >= 300) then
      raise Exception.CreateFmt('HTTP %d %s', [Client.ResponseStatusCode, Client.ResponseStatusText]);
  finally
    Response.Free;
    Request.Free;
    Client.Free;
  end;
end;

{$ELSE}

procedure THttpAppender.PostBody(const ABody: string);
var
  Client: THTTPClient;
  Body: TStringStream;
  Response: IHTTPResponse;
  I: Integer;
begin
  Client := THTTPClient.Create;
  try
    {$IF CompilerVersion >= 33}
    Client.ConnectionTimeout := FTimeoutMs;
    Client.ResponseTimeout := FTimeoutMs;
    {$IFEND}
    Client.ContentType := FContentType;
    for I := 0 to FHeaders.Count - 1 do
      Client.CustomHeaders[FHeaders.Names[I]] := FHeaders.ValueFromIndex[I];
    Body := TStringStream.Create(ABody, TEncoding.UTF8);
    try
      Response := Client.Post(FUrl, Body);
      if (Response.StatusCode < 200) or (Response.StatusCode >= 300) then
        raise Exception.CreateFmt('HTTP %d %s', [Response.StatusCode, Response.StatusText]);
    finally
      Body.Free;
    end;
  finally
    Client.Free;
  end;
end;

{$ENDIF}

procedure THttpAppender.SendBatch(ABatch: TStringList);
var
  Body, Err: string;
  Attempt: Integer;
  Ok: Boolean;
begin
  Body := BuildBody(ABatch);
  Ok := False;
  Err := '';
  for Attempt := 0 to FMaxRetries do
  begin
    try
      PostBody(Body);
      Ok := True;
      Break;
    except
      on E: Exception do
        Err := E.ClassName + ': ' + E.Message;
    end;
    if IsStopping then
      Break;   // do not delay shutdown with retries
    if Attempt < FMaxRetries then
      Sleep(FRetryDelayMs * (Attempt + 1));
  end;
  if (not Ok) and Assigned(FOnError) then
  try
    FOnError(Name, Format('%d entries dropped: %s', [ABatch.Count, Err]));
  except
    // the error handler must never kill the worker thread
  end;
end;

procedure THttpAppender.SendAll;
var
  Batch: TStringList;
begin
  Batch := TStringList.Create;
  try
    while TakeBatch(Batch) do
    begin
      try
        SendBatch(Batch);
      finally
        BatchDone;
      end;
    end;
  finally
    Batch.Free;
  end;
end;

procedure THttpAppender.WorkerLoop;
var
  Stopping: Boolean;
begin
  while True do
  begin
    FWake.WaitFor(FFlushIntervalMs);
    // Read the flag BEFORE sending: once set, no new entry can be buffered,
    // so this pass is guaranteed to be the last one.
    Stopping := IsStopping;
    SendAll;
    if Stopping then
      Break;
  end;
end;

procedure THttpAppender.Flush;
var
  I: Integer;
begin
  if FWorker <> nil then
    for I := 1 to 6000 do   // wait up to ~30 seconds
    begin
      if IsIdle then
        Break;
      FWake.SetEvent;
      Sleep(5);
    end;
end;

procedure THttpAppender.Close;
var
  Worker: THttpWorker;
begin
  Lock;
  try
    FStopping := True;
    Worker := FWorker;
    FWorker := nil;
  finally
    Unlock;
  end;
  if Worker <> nil then
  begin
    FWake.SetEvent;
    Worker.WaitFor;
    Worker.Free;
  end;
  inherited Close;
end;

end.
