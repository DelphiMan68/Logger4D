(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D.Utils;

(*******************************************************************************
  Logger4D.Utils
  Small cross-platform helpers (Delphi + Free Pascal).
*******************************************************************************)

interface

uses
  SysUtils, Classes, DateUtils,
  {$IFNDEF FPC}{$IFDEF POSIX}Posix.Unistd,{$ENDIF}{$ENDIF}
  Logger4D.Types;

const
  /// <summary>Locale independent timestamp format used by the default pattern.</summary>
  cTimestampFormat = 'yyyy"-"mm"-"dd hh":"nn":"ss"."zzz';
  /// <summary>ISO 8601 timestamp format used by the JSON formatter.</summary>
  cIsoTimestampFormat = 'yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz';

function LevelToStr(ALevel: TLogLevel): string;
function StrToLevel(const AText: string; ADefault: TLogLevel = llInfo): TLogLevel;

/// <summary>Escapes a string so it can be placed between double quotes in JSON.</summary>
function JsonEscape(const AText: string): string;

/// <summary>Current time, either local or UTC.</summary>
function LogNow(AUtc: Boolean): TDateTime;

/// <summary>The event timestamp converted to UTC (no conversion if it already is UTC).</summary>
function EventToUtc(const AEvent: TLogEvent): TDateTime;

function CurrentThreadIdValue: UInt64;
function CurrentProcessIdValue: Cardinal;
function LocalHostName: string;

implementation

{$IFNDEF FPC}
{$IFDEF MSWINDOWS}
function GetCurrentProcessId: Cardinal; stdcall; external 'kernel32.dll' name 'GetCurrentProcessId';
{$ENDIF}
{$ENDIF}

var
  GProcessId: Cardinal = 0;
  GHostName: string = '';

function LevelToStr(ALevel: TLogLevel): string;
begin
  case ALevel of
    llTrace: Result := 'TRACE';
    llDebug: Result := 'DEBUG';
    llInfo:  Result := 'INFO';
    llWarn:  Result := 'WARN';
    llError: Result := 'ERROR';
    llFatal: Result := 'FATAL';
  else
    Result := 'OFF';
  end;
end;

function StrToLevel(const AText: string; ADefault: TLogLevel): TLogLevel;
var
  U: string;
begin
  U := UpperCase(Trim(AText));
  if U = 'TRACE' then
    Result := llTrace
  else if U = 'DEBUG' then
    Result := llDebug
  else if U = 'INFO' then
    Result := llInfo
  else if (U = 'WARN') or (U = 'WARNING') then
    Result := llWarn
  else if U = 'ERROR' then
    Result := llError
  else if (U = 'FATAL') or (U = 'CRITICAL') then
    Result := llFatal
  else if (U = 'OFF') or (U = 'NONE') then
    Result := llOff
  else
    Result := ADefault;
end;

function JsonEscape(const AText: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    case C of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if Ord(C) < 32 then
        Result := Result + '\u' + IntToHex(Ord(C), 4)
      else
        Result := Result + C;
    end;
  end;
end;

function LogNow(AUtc: Boolean): TDateTime;
begin
  if AUtc then
  begin
    {$IFDEF FPC}
    Result := LocalTimeToUniversal(Now);
    {$ELSE}
    Result := TTimeZone.Local.ToUniversalTime(Now);
    {$ENDIF}
  end
  else
    Result := Now;
end;

function EventToUtc(const AEvent: TLogEvent): TDateTime;
begin
  if AEvent.IsUtc then
    Result := AEvent.Timestamp
  else
  begin
    {$IFDEF FPC}
    Result := LocalTimeToUniversal(AEvent.Timestamp);
    {$ELSE}
    Result := TTimeZone.Local.ToUniversalTime(AEvent.Timestamp);
    {$ENDIF}
  end;
end;

function CurrentThreadIdValue: UInt64;
begin
  {$IFDEF FPC}
  Result := UInt64(GetCurrentThreadId);
  {$ELSE}
  Result := UInt64(TThread.CurrentThread.ThreadID);
  {$ENDIF}
end;

function CurrentProcessIdValue: Cardinal;
begin
  if GProcessId = 0 then
  begin
    {$IFDEF FPC}
    GProcessId := Cardinal(GetProcessID);
    {$ELSE}
      {$IFDEF MSWINDOWS}
      GProcessId := GetCurrentProcessId;
      {$ELSE}
      GProcessId := Cardinal(getpid);
      {$ENDIF}
    {$ENDIF}
  end;
  Result := GProcessId;
end;

function LocalHostName: string;
begin
  if GHostName = '' then
  begin
    {$IFDEF MSWINDOWS}
    GHostName := SysUtils.GetEnvironmentVariable('COMPUTERNAME');
    {$ELSE}
    GHostName := SysUtils.GetEnvironmentVariable('HOSTNAME');
    if GHostName = '' then
      GHostName := SysUtils.GetEnvironmentVariable('HOST');
    {$ENDIF}
    if GHostName = '' then
      GHostName := 'localhost';
  end;
  Result := GHostName;
end;

end.
