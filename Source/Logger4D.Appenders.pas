(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D.Appenders;

(*******************************************************************************
  Logger4D.Appenders

  TLogAppenderBase     - base class: level filter, custom filter, formatter, locking
  TConsoleAppender     - colored console output (stdout, optionally stderr for errors)
  TFileAppender        - UTF-8 file with size based and daily rolling
  TDebugOutputAppender - OutputDebugString (Windows debugger / DebugView)
  TMemoryAppender      - ring buffer of the last N formatted lines
  TEventAppender       - forwards every entry to your own callback

  All appenders are thread-safe. Once an appender has been added to a hub the
  hub owns it (reference counted); do not free it manually.
*******************************************************************************)

interface

uses
  // Windows must come first: in Free Pascal it declares its own TCriticalSection,
  // which would hide the class from SyncObjs if it were listed after it.
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  Logger4D.Types, Logger4D.Utils, Logger4D.Formatters;

type
  { TLogAppenderBase }

  TLogAppenderBase = class(TInterfacedObject, ILogAppender)
  private
    FName: string;
    FMinLevel: TLogLevel;
    FFormatter: ILogFormatter;
    FOnFilter: TLogFilterEvent;
    FLock: TCriticalSection;
    FClosed: Boolean;
    function GetName: string;
    function GetMinLevel: TLogLevel;
    procedure SetMinLevel(const AValue: TLogLevel);
    function GetFormatter: ILogFormatter;
    procedure SetFormatter(const AValue: ILogFormatter);
  protected
    procedure Lock;
    procedure Unlock;
    /// <summary>Called while the appender lock is held.</summary>
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); virtual; abstract;
    procedure DoFlush; virtual;
    procedure DoClose; virtual;
    property IsClosed: Boolean read FClosed;
  public
    constructor Create(const AName: string; const AFormatter: ILogFormatter = nil);
    destructor Destroy; override;
    procedure Append(const AEvent: TLogEvent); virtual;
    procedure Flush; virtual;
    procedure Close; virtual;
    property Name: string read GetName;
    /// <summary>Entries below this level are ignored by this appender.</summary>
    property MinLevel: TLogLevel read GetMinLevel write SetMinLevel;
    /// <summary>Assign the formatter before the appender is used by several threads.</summary>
    property Formatter: ILogFormatter read GetFormatter write SetFormatter;
    property OnFilter: TLogFilterEvent read FOnFilter write FOnFilter;
  end;

  { TConsoleAppender }

  TConsoleAppender = class(TLogAppenderBase)
  private
    FUseColors: Boolean;
    FErrorsToStdErr: Boolean;
    procedure WriteText(AToStdErr: Boolean; const AText: string);
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
  public
    constructor Create(const AFormatter: ILogFormatter = nil);
    property UseColors: Boolean read FUseColors write FUseColors;
    /// <summary>When True, Error and Fatal entries go to stderr instead of stdout.</summary>
    property ErrorsToStdErr: Boolean read FErrorsToStdErr write FErrorsToStdErr;
  end;

  { TFileAppender }

  TFileAppender = class(TLogAppenderBase)
  private
    FFileName: string;
    FStream: TFileStream;
    FMaxFileSize: Int64;
    FMaxBackupFiles: Integer;
    FRollDaily: Boolean;
    FWriteBOM: Boolean;
    FAppendToExisting: Boolean;
    FCurrentDay: Integer;
    function BackupName(AIndex: Integer): string;
    procedure OpenFile(ADefaultDay: Integer);
    procedure CloseFile;
    procedure RollBySize;
    procedure RollByDate(ANewDay: Integer);
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
    procedure DoFlush; override;
    procedure DoClose; override;
  public
    constructor Create(const AFileName: string; const AFormatter: ILogFormatter = nil);
    destructor Destroy; override;
    property FileName: string read FFileName;
    /// <summary>Roll the file when it would grow beyond this many bytes. 0 = unlimited.</summary>
    property MaxFileSize: Int64 read FMaxFileSize write FMaxFileSize;
    /// <summary>Number of numbered backups (app.log.1 ... app.log.N) kept for size rolling.</summary>
    property MaxBackupFiles: Integer read FMaxBackupFiles write FMaxBackupFiles;
    /// <summary>Archive the file as app.yyyymmdd.log when the day changes.</summary>
    property RollDaily: Boolean read FRollDaily write FRollDaily;
    property WriteBOM: Boolean read FWriteBOM write FWriteBOM;
    /// <summary>True (default) appends to an existing file, False truncates it.</summary>
    property AppendToExisting: Boolean read FAppendToExisting write FAppendToExisting;
  end;

  { TDebugOutputAppender }

  TDebugOutputAppender = class(TLogAppenderBase)
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
  public
    constructor Create(const AFormatter: ILogFormatter = nil);
  end;

  { TMemoryAppender }

  TMemoryAppender = class(TLogAppenderBase)
  private
    FLines: TStringList;
    FMaxLines: Integer;
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
  public
    constructor Create(AMaxLines: Integer = 1000; const AFormatter: ILogFormatter = nil);
    destructor Destroy; override;
    function Count: Integer;
    /// <summary>Copies the buffered lines into ADest (ADest is cleared first).</summary>
    procedure CopyTo(ADest: TStrings);
    function AsText: string;
    procedure Clear;
  end;

  { TEventAppender }

  /// <summary>The handler may be called from any thread. Marshal to the UI thread yourself.</summary>
  TLogAppendEvent = procedure(const AEvent: TLogEvent; const AFormatted: string) of object;

  TEventAppender = class(TLogAppenderBase)
  private
    FOnAppend: TLogAppendEvent;
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
  public
    constructor Create(const AHandler: TLogAppendEvent; const AFormatter: ILogFormatter = nil);
    property OnAppend: TLogAppendEvent read FOnAppend write FOnAppend;
  end;

implementation

{ TLogAppenderBase }

constructor TLogAppenderBase.Create(const AName: string; const AFormatter: ILogFormatter);
begin
  inherited Create;
  FName := AName;
  FMinLevel := llTrace;
  FLock := TCriticalSection.Create;
  if AFormatter <> nil then
    FFormatter := AFormatter
  else
    FFormatter := TPatternFormatter.Create;
end;

destructor TLogAppenderBase.Destroy;
begin
  Close;
  FFormatter := nil;
  FLock.Free;
  inherited Destroy;
end;

procedure TLogAppenderBase.Lock;
begin
  FLock.Enter;
end;

procedure TLogAppenderBase.Unlock;
begin
  FLock.Leave;
end;

function TLogAppenderBase.GetName: string;
begin
  Result := FName;
end;

function TLogAppenderBase.GetMinLevel: TLogLevel;
begin
  Result := FMinLevel;
end;

procedure TLogAppenderBase.SetMinLevel(const AValue: TLogLevel);
begin
  FMinLevel := AValue;
end;

function TLogAppenderBase.GetFormatter: ILogFormatter;
begin
  Result := FFormatter;
end;

procedure TLogAppenderBase.SetFormatter(const AValue: ILogFormatter);
begin
  if AValue = nil then
    FFormatter := TPatternFormatter.Create
  else
    FFormatter := AValue;
end;

procedure TLogAppenderBase.Append(const AEvent: TLogEvent);
var
  Text: string;
  Fmt: ILogFormatter;
begin
  if FClosed or (AEvent.Level < FMinLevel) then
    Exit;
  if Assigned(FOnFilter) and (not FOnFilter(AEvent)) then
    Exit;
  Fmt := FFormatter;
  Text := Fmt.FormatEvent(AEvent);  // formatting happens outside the lock
  FLock.Enter;
  try
    if not FClosed then
      DoAppend(AEvent, Text);
  finally
    FLock.Leave;
  end;
end;

procedure TLogAppenderBase.Flush;
begin
  FLock.Enter;
  try
    if not FClosed then
      DoFlush;
  finally
    FLock.Leave;
  end;
end;

procedure TLogAppenderBase.Close;
begin
  FLock.Enter;
  try
    if not FClosed then
    begin
      DoFlush;
      FClosed := True;
      DoClose;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TLogAppenderBase.DoFlush;
begin
  // nothing to do by default
end;

procedure TLogAppenderBase.DoClose;
begin
  // nothing to do by default
end;

{ TConsoleAppender }

constructor TConsoleAppender.Create(const AFormatter: ILogFormatter);
begin
  inherited Create('Console', AFormatter);
  FUseColors := True;
end;

procedure TConsoleAppender.WriteText(AToStdErr: Boolean; const AText: string);
begin
  if AToStdErr then
  begin
    WriteLn(ErrOutput, AText);
    System.Flush(ErrOutput);
  end
  else
  begin
    WriteLn(Output, AText);
    System.Flush(Output);
  end;
end;

{$IFDEF MSWINDOWS}
function WindowsColor(ALevel: TLogLevel; ADefault: Word): Word;
var
  Back: Word;
begin
  Back := ADefault and $00F0;
  case ALevel of
    llTrace: Result := Back or 8;    // dark gray
    llDebug: Result := Back or 11;   // bright cyan
    llWarn:  Result := Back or 14;   // yellow
    llError: Result := Back or 12;   // bright red
    llFatal: Result := $4F;          // white on red
  else
    Result := ADefault;              // info: console default
  end;
end;
{$ELSE}
function AnsiColor(ALevel: TLogLevel): string;
begin
  case ALevel of
    llTrace: Result := '90';
    llDebug: Result := '36';
    llWarn:  Result := '33';
    llError: Result := '31';
    llFatal: Result := '97;41';
  else
    Result := '';
  end;
end;
{$ENDIF}

procedure TConsoleAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
var
  ToErr: Boolean;
  {$IFDEF MSWINDOWS}
  H: THandle;
  BufInfo: TConsoleScreenBufferInfo;
  Colored: Boolean;
  {$ELSE}
  Code: string;
  {$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if not IsConsole then
    Exit;
  {$ENDIF}
  ToErr := FErrorsToStdErr and (AEvent.Level >= llError);

  {$IFDEF MSWINDOWS}
  Colored := False;
  H := 0;
  if FUseColors then
  begin
    if ToErr then
      H := GetStdHandle(STD_ERROR_HANDLE)
    else
      H := GetStdHandle(STD_OUTPUT_HANDLE);
    if GetConsoleScreenBufferInfo(H, BufInfo) then
    begin
      SetConsoleTextAttribute(H, WindowsColor(AEvent.Level, BufInfo.wAttributes));
      Colored := True;
    end;
  end;
  try
    WriteText(ToErr, AFormatted);
  finally
    if Colored then
      SetConsoleTextAttribute(H, BufInfo.wAttributes);
  end;
  {$ELSE}
  Code := '';
  if FUseColors then
    Code := AnsiColor(AEvent.Level);
  if Code <> '' then
    WriteText(ToErr, #27'[' + Code + 'm' + AFormatted + #27'[0m')
  else
    WriteText(ToErr, AFormatted);
  {$ENDIF}
end;

{ TFileAppender }

constructor TFileAppender.Create(const AFileName: string; const AFormatter: ILogFormatter);
begin
  inherited Create('File', AFormatter);
  FFileName := ExpandFileName(AFileName);
  FMaxBackupFiles := 5;
  FAppendToExisting := True;
  FWriteBOM := False;
end;

destructor TFileAppender.Destroy;
begin
  inherited Destroy;   // Close -> DoClose releases the stream
  FStream.Free;
end;

function TFileAppender.BackupName(AIndex: Integer): string;
begin
  Result := FFileName + '.' + IntToStr(AIndex);
end;

procedure TFileAppender.OpenFile(ADefaultDay: Integer);
var
  Dir: string;
  Fresh: Boolean;
  FileTime: TDateTime;
  Bom: array[0..2] of Byte;
begin
  Dir := ExtractFilePath(FFileName);
  if (Dir <> '') and (not DirectoryExists(Dir)) then
    ForceDirectories(Dir);

  Fresh := not FileExists(FFileName);
  FCurrentDay := ADefaultDay;

  if Fresh or (not FAppendToExisting) then
    FStream := TFileStream.Create(FFileName, fmCreate or fmShareDenyWrite)
  else
  begin
    FStream := TFileStream.Create(FFileName, fmOpenReadWrite or fmShareDenyWrite);
    FStream.Seek(0, soEnd);
    if FileAge(FFileName, FileTime) then
      FCurrentDay := Trunc(FileTime);
  end;

  if FWriteBOM and (FStream.Size = 0) then
  begin
    Bom[0] := $EF;
    Bom[1] := $BB;
    Bom[2] := $BF;
    FStream.WriteBuffer(Bom[0], 3);
  end;
end;

procedure TFileAppender.CloseFile;
begin
  FreeAndNil(FStream);
end;

procedure TFileAppender.RollBySize;
var
  I: Integer;
begin
  CloseFile;
  if FMaxBackupFiles <= 0 then
    SysUtils.DeleteFile(FFileName)
  else
  begin
    SysUtils.DeleteFile(BackupName(FMaxBackupFiles));
    for I := FMaxBackupFiles - 1 downto 1 do
      if FileExists(BackupName(I)) then
        SysUtils.RenameFile(BackupName(I), BackupName(I + 1));
    SysUtils.RenameFile(FFileName, BackupName(1));
  end;
  OpenFile(FCurrentDay);
end;

procedure TFileAppender.RollByDate(ANewDay: Integer);
var
  Base, Ext, Stamp, Target: string;
  N: Integer;
begin
  CloseFile;
  Base := ChangeFileExt(FFileName, '');
  Ext := ExtractFileExt(FFileName);
  Stamp := FormatDateTime('yyyymmdd', FCurrentDay);
  Target := Base + '.' + Stamp + Ext;
  N := 0;
  while FileExists(Target) do
  begin
    Inc(N);
    Target := Base + '.' + Stamp + '.' + IntToStr(N) + Ext;
  end;
  SysUtils.RenameFile(FFileName, Target);
  OpenFile(ANewDay);
end;

procedure TFileAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
var
  Data: UTF8String;
  EventDay: Integer;
begin
  Data := UTF8Encode(AFormatted + sLineBreak);
  EventDay := Trunc(AEvent.Timestamp);

  if FStream = nil then
    OpenFile(EventDay);

  if FRollDaily and (FStream.Size > 0) and (EventDay > FCurrentDay) then
    RollByDate(EventDay);

  if (FMaxFileSize > 0) and (FStream.Size > 0) and
     (FStream.Size + Length(Data) > FMaxFileSize) then
    RollBySize;

  FStream.WriteBuffer(Pointer(Data)^, Length(Data));
end;

procedure TFileAppender.DoFlush;
begin
  {$IFDEF MSWINDOWS}
  if FStream <> nil then
    FlushFileBuffers(FStream.Handle);
  {$ENDIF}
end;

procedure TFileAppender.DoClose;
begin
  CloseFile;
end;

{ TDebugOutputAppender }

constructor TDebugOutputAppender.Create(const AFormatter: ILogFormatter);
begin
  inherited Create('DebugOutput', AFormatter);
end;

procedure TDebugOutputAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
begin
  {$IFDEF MSWINDOWS}
  OutputDebugStringW(PWideChar(AFormatted));
  {$ENDIF}
end;

{ TMemoryAppender }

constructor TMemoryAppender.Create(AMaxLines: Integer; const AFormatter: ILogFormatter);
begin
  inherited Create('Memory', AFormatter);
  FMaxLines := AMaxLines;
  if FMaxLines < 1 then
    FMaxLines := 1;
  FLines := TStringList.Create;
end;

destructor TMemoryAppender.Destroy;
begin
  inherited Destroy;
  FLines.Free;
end;

procedure TMemoryAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
begin
  FLines.Add(AFormatted);
  while FLines.Count > FMaxLines do
    FLines.Delete(0);
end;

function TMemoryAppender.Count: Integer;
begin
  Lock;
  try
    Result := FLines.Count;
  finally
    Unlock;
  end;
end;

procedure TMemoryAppender.CopyTo(ADest: TStrings);
begin
  Lock;
  try
    ADest.Assign(FLines);
  finally
    Unlock;
  end;
end;

function TMemoryAppender.AsText: string;
begin
  Lock;
  try
    Result := FLines.Text;
  finally
    Unlock;
  end;
end;

procedure TMemoryAppender.Clear;
begin
  Lock;
  try
    FLines.Clear;
  finally
    Unlock;
  end;
end;

{ TEventAppender }

constructor TEventAppender.Create(const AHandler: TLogAppendEvent; const AFormatter: ILogFormatter);
begin
  inherited Create('Event', AFormatter);
  FOnAppend := AHandler;
end;

procedure TEventAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
begin
  if Assigned(FOnAppend) then
    FOnAppend(AEvent, AFormatted);
end;

end.
