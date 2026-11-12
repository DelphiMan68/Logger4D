(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D.Appenders.Syslog;

(*******************************************************************************
  Logger4D.Appenders.Syslog

  TSyslogAppender sends RFC 5424 messages over UDP to a syslog server
  (rsyslog, syslog-ng, Graylog, Papertrail, ...).

  Properties of the entry become RFC 5424 structured data:
    <134>1 2026-11-12T10:15:30.123Z host MyApp 4242 - [logger4d@32473 user="bob"] Logger: text

  Dependencies (nothing to install):
    Delphi        Indy (IdUDPClient), shipped with Delphi
    Free Pascal   unit "sockets" (RTL). Host names are resolved with "winsock2"
                  on Windows and "netdb" on other systems. If your installation
                  cannot find one of them, define LOGGER4D_NO_DNS in the project
                  options: the host must then be an IP address (or "localhost").

  Add this unit to your uses clause only if you need it.
*******************************************************************************)

interface

uses
  SysUtils, Classes,
  {$IFDEF FPC}
    {$IFNDEF LOGGER4D_NO_DNS}
      {$IFDEF MSWINDOWS}winsock2,{$ELSE}netdb,{$ENDIF}
    {$ENDIF}
    sockets,
  {$ELSE}
    IdGlobal, IdUDPClient,
  {$ENDIF}
  Logger4D.Types, Logger4D.Utils, Logger4D.Formatters, Logger4D.Appenders;

type
  TSyslogFacility = (
    sfKernel = 0, sfUser = 1, sfMail = 2, sfDaemon = 3, sfAuth = 4, sfSyslog = 5,
    sfLpr = 6, sfNews = 7, sfUucp = 8, sfCron = 9, sfAuthPriv = 10, sfFtp = 11,
    sfLocal0 = 16, sfLocal1 = 17, sfLocal2 = 18, sfLocal3 = 19,
    sfLocal4 = 20, sfLocal5 = 21, sfLocal6 = 22, sfLocal7 = 23);

  TSyslogAppender = class(TLogAppenderBase)
  private
    FHost: string;
    FPort: Word;
    FAppName: string;
    FHostName: string;
    FSdId: string;
    FFacility: TSyslogFacility;
    FMaxMessageSize: Integer;
    {$IFDEF FPC}
    FSocket: TSocket;
    FOpen: Boolean;
    FAddr: TInetSockAddr;
    procedure OpenSocket;
    {$ELSE}
    FClient: TIdUDPClient;
    {$ENDIF}
    function BuildPacket(const AEvent: TLogEvent; const AFormatted: string): UTF8String;
    procedure SendPacket(const AData: UTF8String);
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
    procedure DoClose; override;
  public
    constructor Create(const AHost: string; APort: Word = 514;
      const AAppName: string = 'app'; AFacility: TSyslogFacility = sfUser;
      const AFormatter: ILogFormatter = nil);
    destructor Destroy; override;
    /// <summary>Host name placed in the packet header (default: this computer).</summary>
    property HostName: string read FHostName write FHostName;
    property AppName: string read FAppName write FAppName;
    property Facility: TSyslogFacility read FFacility write FFacility;
    /// <summary>Structured data id, must look like name@enterpriseNumber.</summary>
    property StructuredDataId: string read FSdId write FSdId;
    /// <summary>Packets are truncated to this many bytes (default 1024).</summary>
    property MaxMessageSize: Integer read FMaxMessageSize write FMaxMessageSize;
  end;

implementation

function SyslogSeverity(ALevel: TLogLevel): Integer;
begin
  case ALevel of
    llTrace, llDebug: Result := 7;
    llInfo:           Result := 6;
    llWarn:           Result := 4;
    llError:          Result := 3;
    llFatal:          Result := 2;
  else
    Result := 6;
  end;
end;

/// <summary>Header fields may not contain spaces or control characters.</summary>
function HeaderField(const AValue: string): string;
var
  I: Integer;
begin
  Result := AValue;
  for I := 1 to Length(Result) do
    if (Ord(Result[I]) <= 32) or (Ord(Result[I]) > 126) then
      Result[I] := '_';
  if Result = '' then
    Result := '-';
end;

function SdName(const AValue: string): string;
var
  I: Integer;
begin
  Result := AValue;
  for I := 1 to Length(Result) do
    if (Ord(Result[I]) <= 32) or (Ord(Result[I]) > 126) or
       (Result[I] = '=') or (Result[I] = ']') or (Result[I] = '"') then
      Result[I] := '_';
  if Result = '' then
    Result := '_';
end;

function SdValue(const AValue: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    if (AValue[I] = '\') or (AValue[I] = '"') or (AValue[I] = ']') then
      Result := Result + '\';
    Result := Result + AValue[I];
  end;
end;

{ TSyslogAppender }

constructor TSyslogAppender.Create(const AHost: string; APort: Word;
  const AAppName: string; AFacility: TSyslogFacility; const AFormatter: ILogFormatter);
var
  Fmt: ILogFormatter;
begin
  if AFormatter <> nil then
    Fmt := AFormatter
  else
    Fmt := TPatternFormatter.Create('{logger}: {msg}{exc: | %s}');
  inherited Create('Syslog', Fmt);
  FHost := AHost;
  FPort := APort;
  FAppName := AAppName;
  FFacility := AFacility;
  FHostName := LocalHostName;
  FSdId := 'logger4d@32473';
  FMaxMessageSize := 1024;
end;

destructor TSyslogAppender.Destroy;
begin
  inherited Destroy;   // Close -> DoClose releases the socket
  {$IFNDEF FPC}
  FClient.Free;
  {$ENDIF}
end;

function TSyslogAppender.BuildPacket(const AEvent: TLogEvent; const AFormatted: string): UTF8String;
var
  Pri, I, Cut: Integer;
  Stamp, SD, Text: string;
begin
  Pri := Ord(FFacility) * 8 + SyslogSeverity(AEvent.Level);
  Stamp := FormatDateTime(cIsoTimestampFormat, EventToUtc(AEvent)) + 'Z';

  if Length(AEvent.Properties) = 0 then
    SD := '-'
  else
  begin
    SD := '[' + SdName(FSdId);
    for I := 0 to High(AEvent.Properties) do
      SD := SD + ' ' + SdName(AEvent.Properties[I].Key) + '="' +
        SdValue(AEvent.Properties[I].Value) + '"';
    SD := SD + ']';
  end;

  Text := '<' + IntToStr(Pri) + '>1 ' + Stamp + ' ' + HeaderField(FHostName) + ' ' +
    HeaderField(FAppName) + ' ' + IntToStr(AEvent.ProcessId) + ' - ' + SD + ' ' + AFormatted;
  Result := UTF8Encode(Text);

  // Truncate to the maximum size without cutting a multi-byte character in half.
  if (FMaxMessageSize > 0) and (Length(Result) > FMaxMessageSize) then
  begin
    Cut := FMaxMessageSize;
    while (Cut > 0) and ((Ord(Result[Cut + 1]) and $C0) = $80) do
      Dec(Cut);
    SetLength(Result, Cut);
  end;
end;

{$IFDEF FPC}

function ResolveHost(const AHost: string; out AAddr: in_addr): Boolean;
var
  Parsed: in_addr;
  {$IFNDEF LOGGER4D_NO_DNS}
  {$IFDEF MSWINDOWS}
  WsaInfo: winsock2.TWSAData;
  HostInfo: winsock2.PHostEnt;
  {$ELSE}
  Entry: THostEntry;
  {$ENDIF}
  {$ENDIF}
begin
  Result := True;
  if SameText(AHost, 'localhost') then
  begin
    AAddr := StrToNetAddr('127.0.0.1');
    Exit;
  end;
  Parsed := StrToNetAddr(AnsiString(AHost));
  if (Parsed.s_addr <> 0) or (AHost = '0.0.0.0') then
  begin
    AAddr := Parsed;
    Exit;
  end;
  {$IFDEF LOGGER4D_NO_DNS}
  Result := False;
  {$ELSE}
    {$IFDEF MSWINDOWS}
  winsock2.WSAStartup($0202, WsaInfo);   // reference counted, safe to call repeatedly
  HostInfo := winsock2.gethostbyname(PAnsiChar(AnsiString(AHost)));
  if (HostInfo = nil) or (HostInfo^.h_addr_list = nil) or (HostInfo^.h_addr_list^ = nil) then
    Result := False
  else
    Move(HostInfo^.h_addr_list^^, AAddr, SizeOf(AAddr));
    {$ELSE}
  if ResolveHostByName(AnsiString(AHost), Entry) then
    AAddr := HostToNet(Entry.Addr)
  else
    Result := False;
    {$ENDIF}
  {$ENDIF}
end;

procedure TSyslogAppender.OpenSocket;
var
  Addr: in_addr;
begin
  FillChar(FAddr, SizeOf(FAddr), 0);
  if not ResolveHost(FHost, Addr) then
    raise Exception.CreateFmt('Cannot resolve syslog host "%s"', [FHost]);
  FAddr.sin_family := AF_INET;
  FAddr.sin_port := htons(FPort);
  FAddr.sin_addr := Addr;
  FSocket := fpSocket(AF_INET, SOCK_DGRAM, 0);
  if FSocket = (not TSocket(0)) then
    raise Exception.Create('Cannot create the syslog UDP socket');
  FOpen := True;
end;

procedure TSyslogAppender.SendPacket(const AData: UTF8String);
begin
  if not FOpen then
    OpenSocket;
  if fpSendTo(FSocket, Pointer(AData), Length(AData), 0, psockaddr(@FAddr), SizeOf(FAddr)) < 0 then
    raise Exception.Create('Sending the syslog packet failed');
end;

procedure TSyslogAppender.DoClose;
begin
  if FOpen then
  begin
    CloseSocket(FSocket);
    FOpen := False;
  end;
end;

{$ELSE}

procedure TSyslogAppender.SendPacket(const AData: UTF8String);
var
  Buf: TIdBytes;
begin
  if FClient = nil then
    FClient := TIdUDPClient.Create(nil);
  SetLength(Buf, Length(AData));
  if Length(AData) > 0 then
    Move(Pointer(AData)^, Buf[0], Length(AData));
  FClient.SendBuffer(FHost, FPort, Buf);
end;

procedure TSyslogAppender.DoClose;
begin
  // the client is released in the destructor
end;

{$ENDIF}

procedure TSyslogAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
begin
  SendPacket(BuildPacket(AEvent, AFormatted));
end;

end.
