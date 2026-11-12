(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

{$I Logger4D.inc}
unit Logger4D.Appenders.SQLite;

(*******************************************************************************
  Logger4D.Appenders.SQLite

  TSQLiteAppender stores every entry as a row in a SQLite database, so logs can
  be queried with SQL. Rows are written in transactions of BatchSize entries
  (and on Flush/Close) for speed, and the table can be capped with MaxRows.

  Table layout (created automatically):
    id, ts, level (0..5), level_name, logger, message,
    thread_id, process_id, host, props, exception

  Dependencies:
    Delphi        FireDAC with the SQLite driver. Make sure SQLite is available
                  (add FireDAC.Phys.SQLiteWrapper.Stat for static linking, or
                  ship sqlite3.dll).
    Free Pascal   SQLDB (sqldb + sqlite3conn) and the sqlite3 library
                  (sqlite3.dll on Windows, libsqlite3 on Linux/macOS).

  The connection is created on the first entry and used under the appender
  lock. Wrap this appender in TAsyncAppender so that all database work happens
  on a single background thread.
*******************************************************************************)

interface

uses
  SysUtils, Classes,
  {$IFDEF FPC}
  db, sqldb, sqlite3conn,
  {$ELSE}
  Data.DB, FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Error, FireDAC.UI.Intf,
  FireDAC.Phys.Intf, FireDAC.Stan.Def, FireDAC.Stan.Pool, FireDAC.Stan.Async,
  FireDAC.Phys, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef, FireDAC.Stan.ExprFuncs,
  FireDAC.DApt, FireDAC.Stan.Param, FireDAC.Comp.Client,
  {$ENDIF}
  Logger4D.Types, Logger4D.Utils, Logger4D.Formatters, Logger4D.Appenders;

type
  TSQLiteAppender = class(TLogAppenderBase)
  private
    FFileName: string;
    FTable: string;
    FBatchSize: Integer;
    FMaxRows: Integer;
    FPruneEvery: Integer;
    FPending: Integer;
    FSincePrune: Integer;
    FConnected: Boolean;
    {$IFDEF FPC}
    FConn: TSQLite3Connection;
    FTrans: TSQLTransaction;
    FQuery: TSQLQuery;
    {$ELSE}
    FConn: TFDConnection;
    FQuery: TFDQuery;
    {$ENDIF}
    procedure Connect;
    procedure Disconnect;
    procedure ExecSql(const ASql: string);
    procedure BeginBatch;
    procedure CommitBatch;
    procedure SetText(const AName, AValue: string);
    procedure SetNumber(const AName: string; AValue: Int64);
    procedure Prune;
  protected
    procedure DoAppend(const AEvent: TLogEvent; const AFormatted: string); override;
    procedure DoFlush; override;
    procedure DoClose; override;
  public
    constructor Create(const AFileName: string; const ATableName: string = 'logs');
    destructor Destroy; override;
    property FileName: string read FFileName;
    property TableName: string read FTable;
    /// <summary>Rows per transaction (default 50).</summary>
    property BatchSize: Integer read FBatchSize write FBatchSize;
    /// <summary>Keep at most this many rows; 0 = unlimited (default).</summary>
    property MaxRows: Integer read FMaxRows write FMaxRows;
  end;

implementation

function SafeIdentifier(const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AName) do
    if CharInSet(AName[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Result := Result + AName[I];
  if Result = '' then
    Result := 'logs';
end;

{ TSQLiteAppender }

constructor TSQLiteAppender.Create(const AFileName: string; const ATableName: string);
begin
  // the formatter is not used for storage; the columns come from the event itself
  inherited Create('SQLite');
  FFileName := ExpandFileName(AFileName);
  FTable := SafeIdentifier(ATableName);
  FBatchSize := 50;
  FPruneEvery := 500;
end;

destructor TSQLiteAppender.Destroy;
begin
  inherited Destroy;   // Close -> DoClose commits and disconnects
end;

procedure TSQLiteAppender.ExecSql(const ASql: string);
begin
  {$IFDEF FPC}
  FConn.ExecuteDirect(ASql);
  {$ELSE}
  FConn.ExecSQL(ASql);
  {$ENDIF}
end;

procedure TSQLiteAppender.BeginBatch;
begin
  {$IFDEF FPC}
  if not FTrans.Active then
    FTrans.StartTransaction;
  {$ELSE}
  if not FConn.InTransaction then
    FConn.StartTransaction;
  {$ENDIF}
end;

procedure TSQLiteAppender.CommitBatch;
begin
  if not FConnected then
    Exit;
  {$IFDEF FPC}
  if FTrans.Active then
    FTrans.Commit;
  if FQuery.Prepared then
    FQuery.UnPrepare;
  {$ELSE}
  if FConn.InTransaction then
    FConn.Commit;
  {$ENDIF}
  FPending := 0;
end;

procedure TSQLiteAppender.Connect;
var
  Dir: string;
  InsertSql: string;
begin
  Dir := ExtractFilePath(FFileName);
  if (Dir <> '') and (not DirectoryExists(Dir)) then
    ForceDirectories(Dir);

  InsertSql := 'INSERT INTO ' + FTable +
    ' (ts, level, level_name, logger, message, thread_id, process_id, host, props, exception)' +
    ' VALUES (:p_ts, :p_level, :p_level_name, :p_logger, :p_message, :p_thread_id,' +
    ' :p_process_id, :p_host, :p_props, :p_exception)';

  {$IFDEF FPC}
  FConn := TSQLite3Connection.Create(nil);
  FTrans := TSQLTransaction.Create(nil);
  FConn.DatabaseName := FFileName;
  FConn.Transaction := FTrans;
  FTrans.DataBase := FConn;
  FConn.Open;
  FQuery := TSQLQuery.Create(nil);
  FQuery.DataBase := FConn;
  FQuery.Transaction := FTrans;
  FQuery.SQL.Text := InsertSql;
  {$ELSE}
  FConn := TFDConnection.Create(nil);
  FConn.DriverName := 'SQLite';
  FConn.Params.Values['Database'] := FFileName;
  FConn.Params.Values['JournalMode'] := 'WAL';
  FConn.LoginPrompt := False;
  FConn.ResourceOptions.SilentMode := True;
  FConn.Connected := True;
  FQuery := TFDQuery.Create(nil);
  FQuery.Connection := FConn;
  FQuery.SQL.Text := InsertSql;
  {$ENDIF}
  FConnected := True;

  BeginBatch;
  ExecSql('CREATE TABLE IF NOT EXISTS ' + FTable + ' (' +
    'id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, level INTEGER NOT NULL, ' +
    'level_name TEXT NOT NULL, logger TEXT, message TEXT, thread_id INTEGER, ' +
    'process_id INTEGER, host TEXT, props TEXT, exception TEXT)');
  ExecSql('CREATE INDEX IF NOT EXISTS idx_' + FTable + '_ts ON ' + FTable + ' (ts)');
  ExecSql('CREATE INDEX IF NOT EXISTS idx_' + FTable + '_level ON ' + FTable + ' (level)');
  CommitBatch;
end;

procedure TSQLiteAppender.Disconnect;
begin
  if not FConnected then
    Exit;
  FConnected := False;
  FQuery.Free;
  FQuery := nil;
  {$IFDEF FPC}
  FConn.Close;
  FTrans.Free;
  FTrans := nil;
  FConn.Free;
  FConn := nil;
  {$ELSE}
  FConn.Connected := False;
  FConn.Free;
  FConn := nil;
  {$ENDIF}
end;

procedure TSQLiteAppender.SetText(const AName, AValue: string);
begin
  {$IFDEF FPC}
  FQuery.Params.ParamByName(AName).AsString := UTF8Encode(AValue);
  {$ELSE}
  FQuery.ParamByName(AName).AsString := AValue;
  {$ENDIF}
end;

procedure TSQLiteAppender.SetNumber(const AName: string; AValue: Int64);
begin
  {$IFDEF FPC}
  FQuery.Params.ParamByName(AName).AsLargeInt := AValue;
  {$ELSE}
  FQuery.ParamByName(AName).AsLargeInt := AValue;
  {$ENDIF}
end;

procedure TSQLiteAppender.Prune;
begin
  if FMaxRows <= 0 then
    Exit;
  ExecSql('DELETE FROM ' + FTable + ' WHERE id <= (SELECT MAX(id) FROM ' + FTable +
    ') - ' + IntToStr(FMaxRows));
end;

procedure TSQLiteAppender.DoAppend(const AEvent: TLogEvent; const AFormatted: string);
var
  Stamp: string;
begin
  if not FConnected then
    Connect;
  BeginBatch;

  Stamp := FormatDateTime(cIsoTimestampFormat, AEvent.Timestamp);
  if AEvent.IsUtc then
    Stamp := Stamp + 'Z';

  SetText('p_ts', Stamp);
  SetNumber('p_level', Ord(AEvent.Level));
  SetText('p_level_name', LevelToStr(AEvent.Level));
  SetText('p_logger', AEvent.LoggerName);
  SetText('p_message', AEvent.MessageText);
  SetNumber('p_thread_id', Int64(AEvent.ThreadId));
  SetNumber('p_process_id', AEvent.ProcessId);
  SetText('p_host', AEvent.HostName);
  SetText('p_props', AEvent.PropertiesAsText);
  SetText('p_exception', AEvent.ExceptionText);
  FQuery.ExecSQL;

  Inc(FPending);
  Inc(FSincePrune);
  if (FMaxRows > 0) and (FSincePrune >= FPruneEvery) then
  begin
    FSincePrune := 0;
    Prune;
  end;
  if FPending >= FBatchSize then
    CommitBatch;
end;

procedure TSQLiteAppender.DoFlush;
begin
  CommitBatch;
end;

procedure TSQLiteAppender.DoClose;
begin
  try
    CommitBatch;
  finally
    Disconnect;
  end;
end;

end.
