(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

program AdvancedExample;

{$MODE DELPHIUNICODE}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  Logger4D.Types,
  Logger4D.Utils,
  Logger4D.Formatters,
  Logger4D.Appenders,
  Logger4D.Async,
  Logger4D;

type
  TDemoHandlers = class
  public
    function HideHeartbeats(const AEvent: TLogEvent): Boolean;
    procedure InternalError(const ASource, AMessage: string);
  end;

  TWorkerThread = class(TThread)
  private
    FLog: ILogger;
  protected
    procedure Execute; override;
  public
    constructor Create(AIndex: Integer);
  end;

{ TDemoHandlers }

function TDemoHandlers.HideHeartbeats(const AEvent: TLogEvent): Boolean;
begin
  Result := Pos('heartbeat', LowerCase(AEvent.MessageText)) = 0;
end;

procedure TDemoHandlers.InternalError(const ASource, AMessage: string);
begin
  Writeln('Logger4D internal error in ', ASource, ': ', AMessage);
end;

{ TWorkerThread }

constructor TWorkerThread.Create(AIndex: Integer);
begin
  inherited Create(True);
  FLog := GetLogger('Advanced.Worker').ForContext('worker', AIndex);
end;

procedure TWorkerThread.Execute;
var
  I: Integer;
begin
  for I := 1 to 5 do
  begin
    FLog.Info('Processing item %d', [I]);
    Sleep(10);
  end;
end;

procedure ImportCustomers(const ALog: ILogger);
var
  Scope: IInterface;
begin
  // The elapsed time is logged automatically when Scope goes out of scope.
  Scope := ALog.Timed('Import customers', llInfo);
  Sleep(120);
end;

var
  Hub: ILogHub;
  Handlers: TDemoHandlers;
  Console: TConsoleAppender;
  TextFile, JsonFile: TFileAppender;
  Memory: TMemoryAppender;
  Log, DbLog: ILogger;
  Workers: array[0..2] of TWorkerThread;
  I: Integer;

begin
  Handlers := TDemoHandlers.Create;
  try
    Hub := DefaultHub;
    Hub.Level := llDebug;
    Hub.OnInternalError := Handlers.InternalError;

    // Properties added to every single entry.
    Hub.SetGlobalProperty('app', 'Logger4D.Demo');
    Hub.SetGlobalProperty('env', 'dev');

    // Console with a custom pattern and a filter.
    Console := TConsoleAppender.Create(TPatternFormatter.Create(
      '{ts:hh:nn:ss.zzz} {level:5} {logger} | {msg}{props: [%s]}{exc: !! %s}'));
    Console.OnFilter := Handlers.HideHeartbeats;
    Hub.AddAppender(Console);

    // Text file: rolls at 1 MB, keeps 3 backups, archives daily. Written by a
    // background thread so the calling code never waits for the disk.
    TextFile := TFileAppender.Create('logs' + PathDelim + 'advanced.log');
    TextFile.MaxFileSize := 1024 * 1024;
    TextFile.MaxBackupFiles := 3;
    TextFile.RollDaily := True;
    Hub.AddAppender(TAsyncAppender.Create(TextFile, 4096, aoBlock));

    // JSON lines file for log aggregation tools (only warnings and above).
    JsonFile := TFileAppender.Create('logs' + PathDelim + 'advanced.jsonl',
      TJsonFormatter.Create(True, True));
    JsonFile.MinLevel := llWarn;
    Hub.AddAppender(JsonFile);

    // Keeps the last 100 lines in memory (handy for a log viewer in your UI).
    Memory := TMemoryAppender.Create(100);
    Hub.AddAppender(Memory);

    // Per-logger levels: "Advanced.Db" and every logger below it only show warnings.
    Hub.SetLoggerLevel('Advanced.Db', llWarn);

    Log := GetLogger('Advanced');
    DbLog := GetLogger('Advanced.Db.Query');

    Log.Info('Application started');
    Log.Info('Sending heartbeat');            // hidden on the console by the filter
    DbLog.Debug('SELECT 1');                  // suppressed by the logger level
    DbLog.Warn('Slow query: %d ms', [2300]);  // shown

    ImportCustomers(Log);

    // Logging from several threads at once.
    for I := 0 to High(Workers) do
    begin
      Workers[I] := TWorkerThread.Create(I + 1);
      Workers[I].Start;
    end;
    for I := 0 to High(Workers) do
    begin
      Workers[I].WaitFor;
      Workers[I].Free;
    end;

    try
      raise EInvalidOperation.Create('Payment gateway not reachable');
    except
      on E: Exception do
        Log.Error('Checkout failed', E);
    end;

    Log.Info('Memory appender holds %d lines', [Memory.Count]);

    Hub.Flush;
    ShutdownLogging;

    Readln;
  finally
    Handlers.Free;
  end;
end.
