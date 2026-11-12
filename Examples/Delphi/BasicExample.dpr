(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

program BasicExample;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Logger4D.Types      in '..\..\Source\Logger4D.Types.pas',
  Logger4D.Utils      in '..\..\Source\Logger4D.Utils.pas',
  Logger4D.Formatters in '..\..\Source\Logger4D.Formatters.pas',
  Logger4D.Appenders  in '..\..\Source\Logger4D.Appenders.pas',
  Logger4D            in '..\..\Source\Logger4D.pas';

var
  Log: ILogger;

begin
  try
    // 1. Configure the default hub once, at application start-up.
    DefaultHub.Level := llTrace;
    DefaultHub.AddAppender(TConsoleAppender.Create);

    // 2. Ask for a named logger (usually one per unit or class).
    Log := GetLogger('Basic');

    // 3. Log at every level.
    Log.Trace('Entering the main routine');
    Log.Debug('Configuration loaded from %s', ['settings.ini']);
    Log.Info('User %s logged in from %s', ['alice', '10.0.0.5']);
    Log.Warn('Disk usage is at %d%%', [91]);

    // 4. Log exceptions together with a message.
    try
      raise Exception.Create('Disk is full');
    except
      on E: Exception do
        Log.Error('Could not save the document', E);
    end;

    Log.Fatal('Unrecoverable state, shutting down');

    // 5. Attach structured properties with ForContext.
    Log.ForContext('user', 'alice').ForContext('order', 4711).Info('Order submitted');

    // 6. Skip expensive work when a level is disabled.
    if Log.IsEnabled(llTrace) then
      Log.Trace('Expensive dump: %s', ['...']);

    // 7. Flush and close all appenders (also done automatically at exit).
    ShutdownLogging;

    Readln;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
  Writeln;
  Write('Press Enter to exit...');
  Readln;
end.
