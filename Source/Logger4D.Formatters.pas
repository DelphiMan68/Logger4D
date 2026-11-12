(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D.Formatters;

(*******************************************************************************
  Logger4D.Formatters

  TPatternFormatter - human readable text driven by a pattern string
  TJsonFormatter    - one JSON object per line (ready for ELK, Loki, Seq, ...)

  Pattern tokens (case-insensitive, written between braces):
    {ts}              timestamp, default format "yyyy-mm-dd hh:nn:ss.zzz"
    {ts:FORMAT}       timestamp with a custom FormatDateTime format
    {level}           TRACE / DEBUG / INFO / WARN / ERROR / FATAL
    {level:N}         level padded with spaces to width N
    {logger}          logger name
    {msg}             message text
    {tid}             thread id
    {pid}             process id
    {host}            computer name
    {props}           structured properties as key=value pairs (empty if none)
    {props:FMT}       same, wrapped with a Format string, e.g. {props: [%s]}
    {exc}             exception class and message (empty if none)
    {exc:FMT}         same, wrapped with a Format string, e.g. {exc: | %s}
    {nl}              line break
    {{                a literal opening brace
*******************************************************************************)

interface

uses
  SysUtils, Classes, Logger4D.Types, Logger4D.Utils;

const
  cDefaultPattern =
    '{ts} {level:5} [{tid}] {logger} - {msg}{props: | %s}{exc: | %s}';

type
  TPatternTokenKind = (ptText, ptTimestamp, ptLevel, ptLogger, ptMessage,
    ptThread, ptProcess, ptHost, ptProps, ptException, ptNewLine);

  TPatternToken = record
    Kind: TPatternTokenKind;
    Text: string;
    Arg: string;
  end;

  TPatternFormatter = class(TInterfacedObject, ILogFormatter)
  private
    FPattern: string;
    FTokens: array of TPatternToken;
    procedure AddToken(AKind: TPatternTokenKind; const AText, AArg: string);
    procedure Compile;
  public
    constructor Create(const APattern: string = cDefaultPattern);
    function FormatEvent(const AEvent: TLogEvent): string;
    property Pattern: string read FPattern;
  end;

  TJsonFormatter = class(TInterfacedObject, ILogFormatter)
  private
    FIncludeHost: Boolean;
    FIncludeProcess: Boolean;
  public
    constructor Create(AIncludeHost: Boolean = False; AIncludeProcess: Boolean = False);
    function FormatEvent(const AEvent: TLogEvent): string;
    property IncludeHost: Boolean read FIncludeHost write FIncludeHost;
    property IncludeProcess: Boolean read FIncludeProcess write FIncludeProcess;
  end;

implementation

function TokenKindFromName(const AName: string; out AKind: TPatternTokenKind): Boolean;
begin
  AKind := ptText;
  Result := True;
  if AName = 'ts' then
    AKind := ptTimestamp
  else if AName = 'level' then
    AKind := ptLevel
  else if AName = 'logger' then
    AKind := ptLogger
  else if AName = 'msg' then
    AKind := ptMessage
  else if AName = 'tid' then
    AKind := ptThread
  else if AName = 'pid' then
    AKind := ptProcess
  else if AName = 'host' then
    AKind := ptHost
  else if AName = 'props' then
    AKind := ptProps
  else if AName = 'exc' then
    AKind := ptException
  else if AName = 'nl' then
    AKind := ptNewLine
  else
    Result := False;
end;

function WrapValue(const AFormat, AValue: string): string;
begin
  if AFormat = '' then
    Result := AValue
  else
    Result := Format(AFormat, [AValue]);
end;

{ TPatternFormatter }

constructor TPatternFormatter.Create(const APattern: string);
begin
  inherited Create;
  FPattern := APattern;
  if FPattern = '' then
    FPattern := cDefaultPattern;
  Compile;
end;

procedure TPatternFormatter.AddToken(AKind: TPatternTokenKind; const AText, AArg: string);
begin
  SetLength(FTokens, Length(FTokens) + 1);
  FTokens[High(FTokens)].Kind := AKind;
  FTokens[High(FTokens)].Text := AText;
  FTokens[High(FTokens)].Arg := AArg;
end;

procedure TPatternFormatter.Compile;
var
  I, J, L, P: Integer;
  Lit, Body, Name, Arg: string;
  Kind: TPatternTokenKind;
begin
  SetLength(FTokens, 0);
  Lit := '';
  L := Length(FPattern);
  I := 1;
  while I <= L do
  begin
    if FPattern[I] = '{' then
    begin
      if (I < L) and (FPattern[I + 1] = '{') then
      begin
        Lit := Lit + '{';
        Inc(I, 2);
        Continue;
      end;
      J := I + 1;
      while (J <= L) and (FPattern[J] <> '}') do
        Inc(J);
      if J > L then
      begin
        // unterminated token: keep the rest as literal text
        Lit := Lit + Copy(FPattern, I, MaxInt);
        Break;
      end;
      Body := Copy(FPattern, I + 1, J - I - 1);
      P := Pos(':', Body);
      if P > 0 then
      begin
        Name := LowerCase(Copy(Body, 1, P - 1));
        Arg := Copy(Body, P + 1, MaxInt);
      end
      else
      begin
        Name := LowerCase(Body);
        Arg := '';
      end;
      if TokenKindFromName(Name, Kind) then
      begin
        if Lit <> '' then
        begin
          AddToken(ptText, Lit, '');
          Lit := '';
        end;
        AddToken(Kind, '', Arg);
      end
      else
        Lit := Lit + '{' + Body + '}';
      I := J + 1;
    end
    else
    begin
      Lit := Lit + FPattern[I];
      Inc(I);
    end;
  end;
  if Lit <> '' then
    AddToken(ptText, Lit, '');
end;

function TPatternFormatter.FormatEvent(const AEvent: TLogEvent): string;
var
  I, W: Integer;
  S, Fmt: string;
begin
  Result := '';
  for I := 0 to High(FTokens) do
  begin
    case FTokens[I].Kind of
      ptText:
        Result := Result + FTokens[I].Text;
      ptTimestamp:
        begin
          Fmt := FTokens[I].Arg;
          if Fmt = '' then
            Fmt := cTimestampFormat;
          Result := Result + FormatDateTime(Fmt, AEvent.Timestamp);
        end;
      ptLevel:
        begin
          S := LevelToStr(AEvent.Level);
          W := StrToIntDef(FTokens[I].Arg, 0);
          if Length(S) < W then
            S := S + StringOfChar(' ', W - Length(S));
          Result := Result + S;
        end;
      ptLogger:
        Result := Result + AEvent.LoggerName;
      ptMessage:
        Result := Result + AEvent.MessageText;
      ptThread:
        Result := Result + IntToStr(Int64(AEvent.ThreadId));
      ptProcess:
        Result := Result + IntToStr(AEvent.ProcessId);
      ptHost:
        Result := Result + AEvent.HostName;
      ptProps:
        begin
          S := AEvent.PropertiesAsText;
          if S <> '' then
            Result := Result + WrapValue(FTokens[I].Arg, S);
        end;
      ptException:
        begin
          S := AEvent.ExceptionText;
          if S <> '' then
            Result := Result + WrapValue(FTokens[I].Arg, S);
        end;
      ptNewLine:
        Result := Result + sLineBreak;
    end;
  end;
end;

{ TJsonFormatter }

constructor TJsonFormatter.Create(AIncludeHost, AIncludeProcess: Boolean);
begin
  inherited Create;
  FIncludeHost := AIncludeHost;
  FIncludeProcess := AIncludeProcess;
end;

function TJsonFormatter.FormatEvent(const AEvent: TLogEvent): string;
var
  I: Integer;
  Stamp: string;
begin
  Stamp := FormatDateTime(cIsoTimestampFormat, AEvent.Timestamp);
  if AEvent.IsUtc then
    Stamp := Stamp + 'Z';

  Result := '{"ts":"' + Stamp + '"' +
    ',"level":"' + LevelToStr(AEvent.Level) + '"' +
    ',"logger":"' + JsonEscape(AEvent.LoggerName) + '"' +
    ',"msg":"' + JsonEscape(AEvent.MessageText) + '"' +
    ',"tid":' + IntToStr(Int64(AEvent.ThreadId));

  if FIncludeProcess then
    Result := Result + ',"pid":' + IntToStr(AEvent.ProcessId);
  if FIncludeHost then
    Result := Result + ',"host":"' + JsonEscape(AEvent.HostName) + '"';

  if Length(AEvent.Properties) > 0 then
  begin
    Result := Result + ',"props":{';
    for I := 0 to High(AEvent.Properties) do
    begin
      if I > 0 then
        Result := Result + ',';
      Result := Result + '"' + JsonEscape(AEvent.Properties[I].Key) + '":"' +
        JsonEscape(AEvent.Properties[I].Value) + '"';
    end;
    Result := Result + '}';
  end;

  if AEvent.HasException then
    Result := Result + ',"exception":{"class":"' + JsonEscape(AEvent.ExceptionClass) +
      '","message":"' + JsonEscape(AEvent.ExceptionMessage) + '"}';

  Result := Result + '}';
end;

end.
