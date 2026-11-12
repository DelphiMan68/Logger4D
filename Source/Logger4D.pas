(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D;

(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Quick start:

    uses Logger4D, Logger4D.Types, Logger4D.Appenders;

    DefaultHub.AddAppender(TConsoleAppender.Create);
    GetLogger('App').Info('Hello %s', ['world']);

  Units:
    Logger4D.Types       types and interfaces (ILogger, ILogHub, ILogAppender, ...)
    Logger4D.Formatters  TPatternFormatter, TJsonFormatter
    Logger4D.Appenders   console, file, debug output, memory, event appenders
    Logger4D.Async       TAsyncAppender (background thread decorator)
    Logger4D             hub, logger implementation and the global helpers below
*******************************************************************************)

interface

uses
  SysUtils, Classes, SyncObjs,
  Logger4D.Types, Logger4D.Utils;

type
  TLogAppenderArray = array of ILogAppender;

  { TLogHub }

  TLogHub = class(TInterfacedObject, ILogHub)
  private
    FLock: TCriticalSection;
    FAppenders: TLogAppenderArray;
    FLevel: TLogLevel;
    FUseUtc: Boolean;
    FOnInternalError: TLogErrorEvent;
    FGlobalProps: TLogProperties;
    FLevels: TStringList;
    FVersion: Integer;
    FShutDown: Boolean;
    procedure ReportInternalError(const ASource, AMessage: string);
    procedure Touch;
    function GetLevel: TLogLevel;
    procedure SetLevel(const AValue: TLogLevel);
    function GetUseUtc: Boolean;
    procedure SetUseUtc(const AValue: Boolean);
    function GetOnInternalError: TLogErrorEvent;
    procedure SetOnInternalError(const AValue: TLogErrorEvent);
  public
    constructor Create;
    destructor Destroy; override;

    function GetLogger(const AName: string = ''): ILogger;

    procedure AddAppender(const AAppender: ILogAppender);
    procedure RemoveAppender(const AAppender: ILogAppender);
    procedure ClearAppenders;
    function AppenderCount: Integer;
    function FindAppender(const AName: string): ILogAppender;

    procedure SetLoggerLevel(const AName: string; ALevel: TLogLevel);
    procedure ClearLoggerLevels;
    function ResolveLevel(const AName: string): TLogLevel;
    function ConfigVersion: Integer;

    procedure SetGlobalProperty(const AKey, AValue: string);
    function GlobalProperties: TLogProperties;

    procedure Dispatch(const AEvent: TLogEvent);
    procedure Flush;
    procedure Shutdown;

    property Level: TLogLevel read GetLevel write SetLevel;
    property UseUtc: Boolean read GetUseUtc write SetUseUtc;
    property OnInternalError: TLogErrorEvent read GetOnInternalError write SetOnInternalError;
  end;

/// <summary>The process-wide hub. Created at startup, shut down automatically at exit.</summary>
function DefaultHub: ILogHub;

/// <summary>Shortcut for DefaultHub.GetLogger(AName).</summary>
function GetLogger(const AName: string = ''): ILogger;

/// <summary>Creates an independent hub (for libraries or tests that must not touch the default one).</summary>
function CreateHub: ILogHub;

/// <summary>Flushes and closes every appender of the default hub.</summary>
procedure ShutdownLogging;

implementation

type
  { TLogger }

  TLogger = class(TInterfacedObject, ILogger)
  private
    FName: string;
    FHub: ILogHub;
    FProps: TLogProperties;
    FHasLocalLevel: Boolean;
    FLocalLevel: TLogLevel;
    FEffective: TLogLevel;
    FSeenVersion: Integer;
    function GetName: string;
    function GetLevel: TLogLevel;
    procedure SetLevel(const AValue: TLogLevel);
    procedure Write(ALevel: TLogLevel; const AMsg: string; const AException: Exception);
    function MergeProps: TLogProperties;
    function Derive(const AKey, AValue: string): ILogger;
  public
    constructor Create(const AName: string; const AHub: ILogHub; const AProps: TLogProperties;
      AHasLocalLevel: Boolean; ALocalLevel: TLogLevel);

    function IsEnabled(ALevel: TLogLevel): Boolean;
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

    function ForContext(const AKey, AValue: string): ILogger; overload;
    function ForContext(const AKey: string; AValue: Int64): ILogger; overload;
    function Timed(const AOperation: string; ALevel: TLogLevel = llDebug): IInterface;
  end;

  { TLogTimer }

  TLogTimer = class(TInterfacedObject)
  private
    FLogger: ILogger;
    FOperation: string;
    FLevel: TLogLevel;
    FStart: TDateTime;
  public
    constructor Create(const ALogger: ILogger; const AOperation: string; ALevel: TLogLevel);
    destructor Destroy; override;
  end;

var
  GDefaultHub: ILogHub = nil;

{ helpers }

procedure SetProperty(var AProps: TLogProperties; const AKey, AValue: string);
var
  I: Integer;
begin
  for I := 0 to High(AProps) do
    if SameText(AProps[I].Key, AKey) then
    begin
      AProps[I].Value := AValue;
      Exit;
    end;
  SetLength(AProps, Length(AProps) + 1);
  AProps[High(AProps)].Key := AKey;
  AProps[High(AProps)].Value := AValue;
end;

{ TLogHub }

constructor TLogHub.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLevels := TStringList.Create;
  FLevel := llInfo;
end;

destructor TLogHub.Destroy;
begin
  Shutdown;
  FLevels.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLogHub.Touch;
begin
  Inc(FVersion);
end;

procedure TLogHub.ReportInternalError(const ASource, AMessage: string);
var
  Handler: TLogErrorEvent;
begin
  FLock.Enter;
  try
    Handler := FOnInternalError;
  finally
    FLock.Leave;
  end;
  if Assigned(Handler) then
  try
    Handler(ASource, AMessage);
  except
    // the error handler itself must never break logging
  end;
end;

function TLogHub.GetLevel: TLogLevel;
begin
  Result := FLevel;
end;

procedure TLogHub.SetLevel(const AValue: TLogLevel);
begin
  FLock.Enter;
  try
    FLevel := AValue;
    Touch;
  finally
    FLock.Leave;
  end;
end;

function TLogHub.GetUseUtc: Boolean;
begin
  Result := FUseUtc;
end;

procedure TLogHub.SetUseUtc(const AValue: Boolean);
begin
  FUseUtc := AValue;
end;

function TLogHub.GetOnInternalError: TLogErrorEvent;
begin
  Result := FOnInternalError;
end;

procedure TLogHub.SetOnInternalError(const AValue: TLogErrorEvent);
begin
  FLock.Enter;
  try
    FOnInternalError := AValue;
  finally
    FLock.Leave;
  end;
end;

function TLogHub.GetLogger(const AName: string): ILogger;
var
  NoProps: TLogProperties;
begin
  SetLength(NoProps, 0);
  Result := TLogger.Create(AName, Self, NoProps, False, llInfo);
end;

procedure TLogHub.AddAppender(const AAppender: ILogAppender);
var
  I: Integer;
begin
  if AAppender = nil then
    Exit;
  FLock.Enter;
  try
    for I := 0 to High(FAppenders) do
      if FAppenders[I] = AAppender then
        Exit;
    SetLength(FAppenders, Length(FAppenders) + 1);
    FAppenders[High(FAppenders)] := AAppender;
  finally
    FLock.Leave;
  end;
end;

procedure TLogHub.RemoveAppender(const AAppender: ILogAppender);
var
  I, J: Integer;
  NewList: TLogAppenderArray;
  Removed: ILogAppender;
begin
  Removed := nil;
  FLock.Enter;
  try
    SetLength(NewList, 0);
    for I := 0 to High(FAppenders) do
    begin
      if FAppenders[I] = AAppender then
        Removed := FAppenders[I]
      else
      begin
        J := Length(NewList);
        SetLength(NewList, J + 1);
        NewList[J] := FAppenders[I];
      end;
    end;
    FAppenders := NewList;
  finally
    FLock.Leave;
  end;
  if Removed <> nil then
  try
    Removed.Close;
  except
    // ignore errors while closing
  end;
end;

procedure TLogHub.ClearAppenders;
var
  Old: TLogAppenderArray;
  I: Integer;
begin
  FLock.Enter;
  try
    Old := FAppenders;
    SetLength(FAppenders, 0);
  finally
    FLock.Leave;
  end;
  for I := 0 to High(Old) do
  try
    Old[I].Close;
  except
    // ignore errors while closing
  end;
end;

function TLogHub.AppenderCount: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FAppenders);
  finally
    FLock.Leave;
  end;
end;

function TLogHub.FindAppender(const AName: string): ILogAppender;
var
  I: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    for I := 0 to High(FAppenders) do
      if SameText(FAppenders[I].Name, AName) then
      begin
        Result := FAppenders[I];
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TLogHub.SetLoggerLevel(const AName: string; ALevel: TLogLevel);
var
  Idx: Integer;
begin
  FLock.Enter;
  try
    Idx := FLevels.IndexOf(AName);
    if Idx < 0 then
      Idx := FLevels.Add(AName);
    FLevels.Objects[Idx] := TObject(NativeInt(Ord(ALevel)));
    Touch;
  finally
    FLock.Leave;
  end;
end;

procedure TLogHub.ClearLoggerLevels;
begin
  FLock.Enter;
  try
    FLevels.Clear;
    Touch;
  finally
    FLock.Leave;
  end;
end;

function TLogHub.ResolveLevel(const AName: string): TLogLevel;
var
  Key: string;
  P, Idx: Integer;
begin
  FLock.Enter;
  try
    Result := FLevel;
    Key := AName;
    while Key <> '' do
    begin
      Idx := FLevels.IndexOf(Key);
      if Idx >= 0 then
      begin
        Result := TLogLevel(NativeInt(FLevels.Objects[Idx]));
        Exit;
      end;
      P := LastDelimiter('.', Key);
      if P = 0 then
        Break;
      Key := Copy(Key, 1, P - 1);
    end;
  finally
    FLock.Leave;
  end;
end;

function TLogHub.ConfigVersion: Integer;
begin
  Result := FVersion;
end;

procedure TLogHub.SetGlobalProperty(const AKey, AValue: string);
begin
  FLock.Enter;
  try
    SetProperty(FGlobalProps, AKey, AValue);
  finally
    FLock.Leave;
  end;
end;

function TLogHub.GlobalProperties: TLogProperties;
begin
  FLock.Enter;
  try
    Result := Copy(FGlobalProps, 0, Length(FGlobalProps));
  finally
    FLock.Leave;
  end;
end;

procedure TLogHub.Dispatch(const AEvent: TLogEvent);
var
  Snapshot: TLogAppenderArray;
  I: Integer;
begin
  FLock.Enter;
  try
    Snapshot := FAppenders;
  finally
    FLock.Leave;
  end;
  for I := 0 to High(Snapshot) do
  begin
    try
      Snapshot[I].Append(AEvent);
    except
      on E: Exception do
        ReportInternalError(Snapshot[I].Name, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure TLogHub.Flush;
var
  Snapshot: TLogAppenderArray;
  I: Integer;
begin
  FLock.Enter;
  try
    Snapshot := FAppenders;
  finally
    FLock.Leave;
  end;
  for I := 0 to High(Snapshot) do
  begin
    try
      Snapshot[I].Flush;
    except
      on E: Exception do
        ReportInternalError(Snapshot[I].Name, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure TLogHub.Shutdown;
begin
  if FShutDown then
    Exit;
  FShutDown := True;
  Flush;
  ClearAppenders;
end;

{ TLogger }

constructor TLogger.Create(const AName: string; const AHub: ILogHub; const AProps: TLogProperties;
  AHasLocalLevel: Boolean; ALocalLevel: TLogLevel);
begin
  inherited Create;
  FName := AName;
  FHub := AHub;
  FProps := AProps;
  FHasLocalLevel := AHasLocalLevel;
  FLocalLevel := ALocalLevel;
  FSeenVersion := -1;
end;

function TLogger.GetName: string;
begin
  Result := FName;
end;

function TLogger.GetLevel: TLogLevel;
var
  V: Integer;
begin
  if FHasLocalLevel then
    Result := FLocalLevel
  else
  begin
    V := FHub.ConfigVersion;
    if V <> FSeenVersion then
    begin
      FEffective := FHub.ResolveLevel(FName);
      FSeenVersion := V;
    end;
    Result := FEffective;
  end;
end;

procedure TLogger.SetLevel(const AValue: TLogLevel);
begin
  FLocalLevel := AValue;
  FHasLocalLevel := True;
end;

procedure TLogger.ResetLevel;
begin
  FHasLocalLevel := False;
  FSeenVersion := -1;
end;

function TLogger.IsEnabled(ALevel: TLogLevel): Boolean;
begin
  Result := (ALevel <> llOff) and (ALevel >= GetLevel);
end;

function TLogger.MergeProps: TLogProperties;
var
  I: Integer;
begin
  Result := FHub.GlobalProperties;
  for I := 0 to High(FProps) do
    SetProperty(Result, FProps[I].Key, FProps[I].Value);
end;

procedure TLogger.Write(ALevel: TLogLevel; const AMsg: string; const AException: Exception);
var
  E: TLogEvent;
begin
  E := TLogEvent.Create;
  try
    E.Timestamp := LogNow(FHub.UseUtc);
    E.IsUtc := FHub.UseUtc;
    E.Level := ALevel;
    E.LoggerName := FName;
    E.MessageText := AMsg;
    E.ThreadId := CurrentThreadIdValue;
    E.ProcessId := CurrentProcessIdValue;
    E.HostName := LocalHostName;
    E.Properties := MergeProps;
    if AException <> nil then
    begin
      E.ExceptionClass := AException.ClassName;
      E.ExceptionMessage := AException.Message;
    end;
    FHub.Dispatch(E);
  finally
    E.Free;
  end;
end;

function TLogger.Derive(const AKey, AValue: string): ILogger;
var
  NewProps: TLogProperties;
begin
  NewProps := Copy(FProps, 0, Length(FProps));
  SetProperty(NewProps, AKey, AValue);
  Result := TLogger.Create(FName, FHub, NewProps, FHasLocalLevel, FLocalLevel);
end;

procedure TLogger.Log(ALevel: TLogLevel; const AMsg: string);
begin
  if IsEnabled(ALevel) then
    Write(ALevel, AMsg, nil);
end;

procedure TLogger.Log(ALevel: TLogLevel; const AFmt: string; const AArgs: array of const);
begin
  if IsEnabled(ALevel) then
    Write(ALevel, Format(AFmt, AArgs), nil);
end;

procedure TLogger.Log(ALevel: TLogLevel; const AMsg: string; const AException: Exception);
begin
  if IsEnabled(ALevel) then
    Write(ALevel, AMsg, AException);
end;

procedure TLogger.Trace(const AMsg: string);
begin
  Log(llTrace, AMsg);
end;

procedure TLogger.Trace(const AFmt: string; const AArgs: array of const);
begin
  Log(llTrace, AFmt, AArgs);
end;

procedure TLogger.Debug(const AMsg: string);
begin
  Log(llDebug, AMsg);
end;

procedure TLogger.Debug(const AFmt: string; const AArgs: array of const);
begin
  Log(llDebug, AFmt, AArgs);
end;

procedure TLogger.Info(const AMsg: string);
begin
  Log(llInfo, AMsg);
end;

procedure TLogger.Info(const AFmt: string; const AArgs: array of const);
begin
  Log(llInfo, AFmt, AArgs);
end;

procedure TLogger.Warn(const AMsg: string);
begin
  Log(llWarn, AMsg);
end;

procedure TLogger.Warn(const AFmt: string; const AArgs: array of const);
begin
  Log(llWarn, AFmt, AArgs);
end;

procedure TLogger.Warn(const AMsg: string; const AException: Exception);
begin
  Log(llWarn, AMsg, AException);
end;

procedure TLogger.Error(const AMsg: string);
begin
  Log(llError, AMsg);
end;

procedure TLogger.Error(const AFmt: string; const AArgs: array of const);
begin
  Log(llError, AFmt, AArgs);
end;

procedure TLogger.Error(const AMsg: string; const AException: Exception);
begin
  Log(llError, AMsg, AException);
end;

procedure TLogger.Fatal(const AMsg: string);
begin
  Log(llFatal, AMsg);
end;

procedure TLogger.Fatal(const AFmt: string; const AArgs: array of const);
begin
  Log(llFatal, AFmt, AArgs);
end;

procedure TLogger.Fatal(const AMsg: string; const AException: Exception);
begin
  Log(llFatal, AMsg, AException);
end;

function TLogger.ForContext(const AKey, AValue: string): ILogger;
begin
  Result := Derive(AKey, AValue);
end;

function TLogger.ForContext(const AKey: string; AValue: Int64): ILogger;
begin
  Result := Derive(AKey, IntToStr(AValue));
end;

function TLogger.Timed(const AOperation: string; ALevel: TLogLevel): IInterface;
begin
  Result := TLogTimer.Create(Self, AOperation, ALevel);
end;

{ TLogTimer }

constructor TLogTimer.Create(const ALogger: ILogger; const AOperation: string; ALevel: TLogLevel);
begin
  inherited Create;
  FLogger := ALogger;
  FOperation := AOperation;
  FLevel := ALevel;
  FStart := Now;
end;

destructor TLogTimer.Destroy;
var
  Ms: Int64;
begin
  try
    if FLogger.IsEnabled(FLevel) then
    begin
      Ms := Round((Now - FStart) * 86400000.0);
      FLogger.ForContext('elapsed_ms', Ms).Log(FLevel, '%s completed in %d ms', [FOperation, Ms]);
    end;
  except
    // never raise from a destructor
  end;
  FLogger := nil;
  inherited Destroy;
end;

{ global helpers }

function DefaultHub: ILogHub;
begin
  Result := GDefaultHub;
end;

function GetLogger(const AName: string): ILogger;
begin
  Result := GDefaultHub.GetLogger(AName);
end;

function CreateHub: ILogHub;
begin
  Result := TLogHub.Create;
end;

procedure ShutdownLogging;
begin
  if GDefaultHub <> nil then
    GDefaultHub.Shutdown;
end;

initialization
  GDefaultHub := TLogHub.Create;

finalization
  if GDefaultHub <> nil then
    GDefaultHub.Shutdown;
  GDefaultHub := nil;

end.
