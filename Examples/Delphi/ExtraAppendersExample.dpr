(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

program ExtraAppendersExample;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Logger4D.Types            in '..\..\Source\Logger4D.Types.pas',
  Logger4D.Utils            in '..\..\Source\Logger4D.Utils.pas',
  Logger4D.Formatters       in '..\..\Source\Logger4D.Formatters.pas',
  Logger4D.Appenders        in '..\..\Source\Logger4D.Appenders.pas',
  Logger4D.Async            in '..\..\Source\Logger4D.Async.pas',
  Logger4D.Appenders.Syslog in '..\..\Source\Logger4D.Appenders.Syslog.pas',
  Logger4D.Appenders.Http   in '..\..\Source\Logger4D.Appenders.Http.pas',
  Logger4D.Appenders.SQLite in '..\..\Source\Logger4D.Appenders.SQLite.pas',
  Logger4D                  in '..\..\Source\Logger4D.pas';

type
  TErrorHandlers = class
  public
    procedure OnHttpError(const ASource, AMessage: string);
  end;

procedure TErrorHandlers.OnHttpError(const ASource, AMessage: string);
begin
  Writeln('[', ASource, '] delivery problem: ', AMessage);
end;

var
  Hub: ILogHub;
  Handlers: TErrorHandlers;
  Syslog: TSyslogAppender;
  Http: THttpAppender;
  Db: TSQLiteAppender;
  Log: ILogger;
  I: Integer;

begin
  Handlers := TErrorHandlers.Create;
  try
    Hub := DefaultHub;
    Hub.Level := llInfo;
    Hub.AddAppender(TConsoleAppender.Create);

    // Syslog over UDP (RFC 5424): warnings and above go to the local syslog daemon.
    Syslog := TSyslogAppender.Create('127.0.0.1', 514, 'Logger4DDemo', sfLocal0);
    Syslog.MinLevel := llWarn;
    Hub.AddAppender(Syslog);

    // HTTP: batches of JSON entries are POSTed from a background thread.
    // Replace the URL (and the token) with your own log collector.
    Http := THttpAppender.Create('http://localhost:8080/logs');
    Http.Headers.Values['Authorization'] := 'Bearer YOUR-TOKEN';
    Http.BatchSize := 20;
    Http.FlushIntervalMs := 1000;
    Http.OnError := Handlers.OnHttpError;
    Hub.AddAppender(Http);

    // SQLite: every entry becomes a row. Wrapped in TAsyncAppender so the
    // database is only touched by one background thread.
    Db := TSQLiteAppender.Create('logs' + PathDelim + 'logs.db');
    Db.BatchSize := 100;
    Db.MaxRows := 100000;
    Hub.AddAppender(TAsyncAppender.Create(Db));

    Log := GetLogger('Extra');
    for I := 1 to 5 do
      Log.ForContext('item', I).Info('Processed item %d', [I]);
    Log.Warn('Queue length is %d', [250]);
    Log.Error('Remote service returned %d', [503]);

    Hub.Flush;
    ShutdownLogging;

    Readln;
  finally
    Handlers.Free;
  end;
  Writeln;
  Write('Press Enter to exit...');
  Readln;
end.
