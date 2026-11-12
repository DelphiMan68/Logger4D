(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D.Types;

(*******************************************************************************
  Logger4D.Types
  Core types and interfaces shared by every part of the library.
*******************************************************************************)

interface

uses
  SysUtils, Classes;

type
  /// <summary>Severity of a log entry, from the most verbose to the most severe.</summary>
  TLogLevel = (llTrace, llDebug, llInfo, llWarn, llError, llFatal, llOff);

  /// <summary>A structured key/value pair attached to a log entry.</summary>
  TLogProperty = record
    Key: string;
    Value: string;
  end;

  TLogProperties = array of TLogProperty;

  /// <summary>
  ///   A single log record. Created by a logger, handed to every appender and
  ///   freed by the hub afterwards. Appenders that need to keep an event
  ///   (for example for asynchronous processing) must call Clone.
  /// </summary>
  TLogEvent = class
  public
    Timestamp: TDateTime;
    IsUtc: Boolean;
    Level: TLogLevel;
    LoggerName: string;
    MessageText: string;
    ThreadId: UInt64;
    ProcessId: Cardinal;
    HostName: string;
    Properties: TLogProperties;
    ExceptionClass: string;
    ExceptionMessage: string;
    function HasException: Boolean;
    function ExceptionText: string;
    function PropertiesAsText(const ASeparator: string = ', '): string;
    function Clone: TLogEvent;
  end;

  /// <summary>Return False to drop an event before it is written by an appender.</summary>
  TLogFilterEvent = function(const AEvent: TLogEvent): Boolean of object;

  /// <summary>Raised internally when an appender fails. Logging never raises to the caller.</summary>
  TLogErrorEvent = procedure(const ASource, AMessage: string) of object;

  /// <summary>Converts an event into text.</summary>
  ILogFormatter = interface
    ['{6F1D3B52-8C0E-4A57-9E2B-5B1E2C7A4D10}']
    function FormatEvent(const AEvent: TLogEvent): string;
  end;

  /// <summary>A destination for log events (console, file, memory, ...).</summary>
  ILogAppender = interface
    ['{A2C4E8F0-3B71-4D9A-8F66-0C5D7E1B9A23}']
    function GetName: string;
    function GetMinLevel: TLogLevel;
    procedure SetMinLevel(const AValue: TLogLevel);
    function GetFormatter: ILogFormatter;
    procedure SetFormatter(const AValue: ILogFormatter);
    /// <summary>Thread-safe. Writes the event if it passes level and filter checks.</summary>
    procedure Append(const AEvent: TLogEvent);
    procedure Flush;
    procedure Close;
    property Name: string read GetName;
    property MinLevel: TLogLevel read GetMinLevel write SetMinLevel;
    property Formatter: ILogFormatter read GetFormatter write SetFormatter;
  end;

  /// <summary>The object application code logs through.</summary>
  ILogger = interface
    ['{D0B7A1C9-52E4-4F38-B6A1-7E9C3D5F8B42}']
    function GetName: string;
    function GetLevel: TLogLevel;
    procedure SetLevel(const AValue: TLogLevel);

    /// <summary>True if an entry of the given level would currently be written.</summary>
    function IsEnabled(ALevel: TLogLevel): Boolean;
    /// <summary>Removes a level set directly on this logger; the hub configuration applies again.</summary>
    procedure ResetLevel;

    procedure Log(ALevel: TLogLevel; const AMsg: string); overload;
    procedure Log(ALevel: TLogLevel; const AFmt: string; const AArgs: array of const); overload;
    procedure Log(ALevel: TLogLevel; const AMsg: string; const AException: Exception); overload;

    procedure Trace(const AMsg: string); overload;
    procedure Trace(const AFmt: string; const AArgs: array of const); overload;
    procedure Debug(const AMsg: string); overload;
    procedure Debug(const AFmt: string; const AArgs: array of const); overload;
    procedure Info(const AMsg: string); overload;
    procedure Info(const AFmt: string; const AArgs: array of const); overload;
    procedure Warn(const AMsg: string); overload;
    procedure Warn(const AFmt: string; const AArgs: array of const); overload;
    procedure Warn(const AMsg: string; const AException: Exception); overload;
    procedure Error(const AMsg: string); overload;
    procedure Error(const AFmt: string; const AArgs: array of const); overload;
    procedure Error(const AMsg: string; const AException: Exception); overload;
    procedure Fatal(const AMsg: string); overload;
    procedure Fatal(const AFmt: string; const AArgs: array of const); overload;
    procedure Fatal(const AMsg: string; const AException: Exception); overload;

    /// <summary>Returns a new logger that adds a structured property to every entry.</summary>
    function ForContext(const AKey, AValue: string): ILogger; overload;
    function ForContext(const AKey: string; AValue: Int64): ILogger; overload;

    /// <summary>
    ///   Starts a timer. When the returned reference is released, the elapsed
    ///   time is logged. Keep it in an IInterface variable for the scope you
    ///   want to measure.
    /// </summary>
    function Timed(const AOperation: string; ALevel: TLogLevel = llDebug): IInterface;

    property Name: string read GetName;
    property Level: TLogLevel read GetLevel write SetLevel;
  end;

  /// <summary>
  ///   Owns the appenders and the level configuration, and hands out loggers.
  ///   A process-wide default hub is available through Logger4D.DefaultHub.
  /// </summary>
  ILogHub = interface
    ['{4E8A9C13-7D25-4B6F-A0E1-3F2B8D6C5A97}']
    function GetLevel: TLogLevel;
    procedure SetLevel(const AValue: TLogLevel);
    function GetUseUtc: Boolean;
    procedure SetUseUtc(const AValue: Boolean);
    function GetOnInternalError: TLogErrorEvent;
    procedure SetOnInternalError(const AValue: TLogErrorEvent);

    function GetLogger(const AName: string = ''): ILogger;

    procedure AddAppender(const AAppender: ILogAppender);
    procedure RemoveAppender(const AAppender: ILogAppender);
    procedure ClearAppenders;
    function AppenderCount: Integer;
    function FindAppender(const AName: string): ILogAppender;

    /// <summary>Sets the level of a named logger and of all its dotted children ("App.Db" covers "App.Db.Query").</summary>
    procedure SetLoggerLevel(const AName: string; ALevel: TLogLevel);
    procedure ClearLoggerLevels;
    function ResolveLevel(const AName: string): TLogLevel;
    function ConfigVersion: Integer;

    /// <summary>Adds a property (application name, version, environment, ...) to every entry.</summary>
    procedure SetGlobalProperty(const AKey, AValue: string);
    function GlobalProperties: TLogProperties;

    procedure Dispatch(const AEvent: TLogEvent);
    procedure Flush;
    procedure Shutdown;

    property Level: TLogLevel read GetLevel write SetLevel;
    property UseUtc: Boolean read GetUseUtc write SetUseUtc;
    property OnInternalError: TLogErrorEvent read GetOnInternalError write SetOnInternalError;
  end;

implementation

{ TLogEvent }

function TLogEvent.HasException: Boolean;
begin
  Result := (ExceptionClass <> '') or (ExceptionMessage <> '');
end;

function TLogEvent.ExceptionText: string;
begin
  if not HasException then
    Result := ''
  else if ExceptionMessage = '' then
    Result := ExceptionClass
  else
    Result := ExceptionClass + ': ' + ExceptionMessage;
end;

function TLogEvent.PropertiesAsText(const ASeparator: string): string;
var
  I: Integer;
  V: string;
begin
  Result := '';
  for I := 0 to High(Properties) do
  begin
    V := Properties[I].Value;
    if (V = '') or (Pos(' ', V) > 0) then
      V := '"' + V + '"';
    if I > 0 then
      Result := Result + ASeparator;
    Result := Result + Properties[I].Key + '=' + V;
  end;
end;

function TLogEvent.Clone: TLogEvent;
begin
  Result := TLogEvent.Create;
  Result.Timestamp := Timestamp;
  Result.IsUtc := IsUtc;
  Result.Level := Level;
  Result.LoggerName := LoggerName;
  Result.MessageText := MessageText;
  Result.ThreadId := ThreadId;
  Result.ProcessId := ProcessId;
  Result.HostName := HostName;
  Result.Properties := Copy(Properties, 0, Length(Properties));
  Result.ExceptionClass := ExceptionClass;
  Result.ExceptionMessage := ExceptionMessage;
end;

end.
