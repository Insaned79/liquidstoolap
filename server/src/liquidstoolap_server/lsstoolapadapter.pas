unit lsstoolapadapter;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils, fpjson, base64, lsconfig, lsstoolapffi;

type
  EStoolapAdapterError = class(Exception);
  EStoolapTimeoutError = class(EStoolapAdapterError);
  EStoolapPoolTimeoutError = class(EStoolapTimeoutError);

  TStoolapAdapter = class
  private
    FLibrary: TStoolapLibrary;
    FDb: PStoolapDB;
    FPool: array of PStoolapDB;
    FPoolBusy: array of Boolean;
    FPoolSize: Integer;
    FPoolLock: TRTLCriticalSection;
    FOpenLock: TRTLCriticalSection;
    FConfig: TStoolapConfig;
    function Dsn: string;
    function EffectivePoolSize: Integer;
    function LastDbError(Db: PStoolapDB): string;
    function IsQuerySql(const Sql: string): Boolean;
    function IsReadOnlySql(const Sql: string): Boolean;
    function RowsToJson(Rows: PStoolapRows): TJSONObject;
    function AcquireDb(const TimeoutMs: Int64; out PoolIndex: Integer): PStoolapDB;
    procedure ReleaseDb(const PoolIndex: Integer);
    procedure OpenUnlocked;
  public
    constructor Create(const Config: TStoolapConfig);
    destructor Destroy; override;
    procedure Open;
    procedure Close;
    procedure StartupCheck;
    function ExecuteJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
    function QueryJson(Db: PStoolapDB; const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
    function CommandJson(Db: PStoolapDB; const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
    function Version: string;
  end;

implementation

type
  TStoolapValueArray = array of TStoolapValue;
  TRawByteStringArray = array of RawByteString;

function Utf8Bytes(const Value: string): RawByteString;
begin
  Result := RawByteString(Value);
  SetCodePage(Result, CP_UTF8, False);
end;

function Utf8StringFromPtr(TextPtr: PChar; TextLen: Int64): string;
var
  Raw: RawByteString;
begin
  if TextPtr = nil then
    Exit('');
  SetString(Raw, TextPtr, TextLen);
  SetCodePage(Raw, CP_UTF8, False);
  Result := string(Raw);
end;

function Utf8StringFromNullTerminated(TextPtr: PChar): string;
begin
  if TextPtr = nil then
    Exit('');
  Result := Utf8StringFromPtr(TextPtr, StrLen(TextPtr));
end;

function TimestampNsToIsoUtc(const TimestampNs: Int64): string;
const
  NanosPerSecond = Int64(1000000000);
var
  Seconds: Int64;
  Nanos: Int64;
begin
  Seconds := TimestampNs div NanosPerSecond;
  Nanos := TimestampNs mod NanosPerSecond;
  if Nanos < 0 then
  begin
    Dec(Seconds);
    Inc(Nanos, NanosPerSecond);
  end;
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss', UnixToDateTime(Seconds, True)) +
    Format('.%.9dZ', [Nanos]);
end;

constructor TStoolapAdapter.Create(const Config: TStoolapConfig);
begin
  inherited Create;
  FConfig := Config;
  FDb := nil;
  FPoolSize := 0;
  InitCriticalSection(FPoolLock);
  InitCriticalSection(FOpenLock);
end;

destructor TStoolapAdapter.Destroy;
begin
  Close;
  FLibrary.Free;
  DoneCriticalSection(FOpenLock);
  DoneCriticalSection(FPoolLock);
  inherited Destroy;
end;

function TStoolapAdapter.Dsn: string;
begin
  if (FConfig.DatabasePath = '') or (FConfig.DatabasePath = ':memory:') or
    (FConfig.DatabasePath = 'memory://') then
    Exit('memory://');

  if Pos('file://', FConfig.DatabasePath) = 1 then
    Exit(FConfig.DatabasePath);

  Result := 'file://' + ExpandFileName(FConfig.DatabasePath);
end;

function TStoolapAdapter.EffectivePoolSize: Integer;
begin
  Result := FConfig.SqlWorkerCount;
  if Result <= 0 then
    Result := 1;
end;

function TStoolapAdapter.LastDbError(Db: PStoolapDB): string;
var
  MessagePtr: PChar;
begin
  Result := '';
  if Assigned(FLibrary) and Assigned(FLibrary.Errmsg) then
  begin
    MessagePtr := FLibrary.Errmsg(Db);
    if MessagePtr <> nil then
      Result := Utf8StringFromNullTerminated(MessagePtr);
  end;
end;

function TStoolapAdapter.IsQuerySql(const Sql: string): Boolean;
var
  S: string;
begin
  S := UpperCase(Trim(Sql));
  Result := (Pos('SELECT', S) = 1) or (Pos('WITH', S) = 1) or
    (Pos('SHOW', S) = 1) or (Pos('EXPLAIN', S) = 1);
end;

function TStoolapAdapter.IsReadOnlySql(const Sql: string): Boolean;
var
  S: string;
begin
  S := UpperCase(Trim(Sql));
  Result := (Pos('SELECT', S) = 1) or (Pos('SHOW', S) = 1) or
    ((Pos('EXPLAIN', S) = 1) and (Pos('EXPLAIN ANALYZE', S) <> 1));
end;

function IsParameterizedInsertSelect(const Sql: string): Boolean;
var
  S: string;
begin
  S := UpperCase(Trim(Sql));
  Result := (Pos('INSERT', S) = 1) and (Pos(' SELECT ', S) > 0);
end;

procedure TStoolapAdapter.OpenUnlocked;
var
  Status: Integer;
  I: Integer;
  DsnBytes: RawByteString;
begin
  if FLibrary = nil then
    FLibrary := TStoolapLibrary.Create(FConfig.LibraryPath);

  if FDb <> nil then
    Exit;

  if Dsn = 'memory://' then
    Status := FLibrary.OpenInMemory(FDb)
  else
  begin
    DsnBytes := Utf8Bytes(Dsn);
    Status := FLibrary.Open(PChar(DsnBytes), FDb);
  end;

  if Status <> STOOLAP_OK then
    raise EStoolapAdapterError.Create('failed to open Stoolap database: ' + LastDbError(FDb));

  FPoolSize := EffectivePoolSize;
  SetLength(FPool, FPoolSize);
  SetLength(FPoolBusy, FPoolSize);
  FPool[0] := FDb;
  FPoolBusy[0] := False;
  for I := 1 to FPoolSize - 1 do
  begin
    FPool[I] := nil;
    Status := FLibrary.Clone(FDb, FPool[I]);
    if Status <> STOOLAP_OK then
      raise EStoolapAdapterError.Create('failed to clone Stoolap database handle: ' + LastDbError(FDb));
    FPoolBusy[I] := False;
  end;
end;

procedure TStoolapAdapter.Open;
begin
  if FDb <> nil then
    Exit;
  EnterCriticalSection(FOpenLock);
  try
    OpenUnlocked;
  finally
    LeaveCriticalSection(FOpenLock);
  end;
end;

procedure TStoolapAdapter.Close;
var
  I: Integer;
begin
  EnterCriticalSection(FOpenLock);
  try
    if FLibrary <> nil then
    begin
      for I := High(FPool) downto 0 do
        if FPool[I] <> nil then
        begin
          FLibrary.Close(FPool[I]);
          FPool[I] := nil;
        end;
    end;
    SetLength(FPool, 0);
    SetLength(FPoolBusy, 0);
    FPoolSize := 0;
    FDb := nil;
  finally
    LeaveCriticalSection(FOpenLock);
  end;
end;

function TStoolapAdapter.AcquireDb(const TimeoutMs: Int64; out PoolIndex: Integer): PStoolapDB;
var
  StartedAt: TDateTime;
  I: Integer;
begin
  Open;
  StartedAt := Now;
  PoolIndex := -1;
  Result := nil;

  while True do
  begin
    EnterCriticalSection(FPoolLock);
    try
      for I := 0 to FPoolSize - 1 do
        if (FPool[I] <> nil) and (not FPoolBusy[I]) then
        begin
          FPoolBusy[I] := True;
          PoolIndex := I;
          Result := FPool[I];
          Exit;
        end;
    finally
      LeaveCriticalSection(FPoolLock);
    end;

    if MilliSecondsBetween(Now, StartedAt) >= TimeoutMs then
      raise EStoolapPoolTimeoutError.Create('SQL worker pool wait exceeded timeout_ms');
    Sleep(1);
  end;
end;

procedure TStoolapAdapter.ReleaseDb(const PoolIndex: Integer);
begin
  if PoolIndex < 0 then
    Exit;
  EnterCriticalSection(FPoolLock);
  try
    if PoolIndex <= High(FPoolBusy) then
      FPoolBusy[PoolIndex] := False;
  finally
    LeaveCriticalSection(FPoolLock);
  end;
end;

procedure TStoolapAdapter.StartupCheck;
var
  Rows: PStoolapRows;
  Status: Integer;
begin
  Open;
  Rows := nil;
  Status := FLibrary.Query(FDb, 'SELECT 1', Rows);
  if Status <> STOOLAP_OK then
    raise EStoolapAdapterError.Create('Stoolap startup query failed: ' + LastDbError(FDb));
  try
    Status := FLibrary.RowsNext(Rows);
    if Status <> STOOLAP_ROW then
      raise EStoolapAdapterError.Create('Stoolap startup query returned no rows');
  finally
    if Rows <> nil then
      FLibrary.RowsClose(Rows);
  end;
end;

function TypeName(const TypeCode: Integer): string;
begin
  case TypeCode of
    STOOLAP_TYPE_NULL: Result := 'NULL';
    STOOLAP_TYPE_INTEGER: Result := 'INTEGER';
    STOOLAP_TYPE_FLOAT: Result := 'FLOAT';
    STOOLAP_TYPE_TEXT: Result := 'TEXT';
    STOOLAP_TYPE_BOOLEAN: Result := 'BOOLEAN';
    STOOLAP_TYPE_TIMESTAMP: Result := 'TIMESTAMP';
    STOOLAP_TYPE_JSON: Result := 'JSON';
    STOOLAP_TYPE_BLOB: Result := 'BLOB';
  else
    Result := 'UNKNOWN';
  end;
end;

procedure AssignJsonValue(Value: TJSONData; out Target: TStoolapValue; var TextValue: RawByteString;
  const ParamName: string);
var
  RawNumber: string;
begin
  Target.Padding := 0;
  case Value.JSONType of
    jtNull:
      Target.ValueType := STOOLAP_TYPE_NULL;
    jtBoolean:
      begin
        Target.ValueType := STOOLAP_TYPE_BOOLEAN;
        if Value.AsBoolean then
          Target.V.BooleanValue := 1
        else
          Target.V.BooleanValue := 0;
      end;
    jtNumber:
      begin
        RawNumber := LowerCase(Value.AsJSON);
        if (Pos('.', RawNumber) > 0) or (Pos('e', RawNumber) > 0) then
        begin
          Target.ValueType := STOOLAP_TYPE_FLOAT;
          Target.V.FloatValue := Value.AsFloat;
        end
        else
        begin
          Target.ValueType := STOOLAP_TYPE_INTEGER;
          Target.V.IntegerValue := Value.AsInt64;
        end;
      end;
    jtString:
      begin
        TextValue := Utf8Bytes(Value.AsString);
        Target.ValueType := STOOLAP_TYPE_TEXT;
        Target.V.TextValue.Ptr := PChar(TextValue);
        Target.V.TextValue.Len := Length(TextValue);
      end;
  else
    raise EStoolapAdapterError.Create('unsupported SQL parameter type for ' + ParamName);
  end;
end;

procedure BuildNamedParams(ParamsObject: TJSONObject; out Params: array of TStoolapNamedParam;
  out Names: array of RawByteString; out TextValues: array of RawByteString);
var
  I: Integer;
  Item: TJSONEnum;
begin
  if ParamsObject = nil then
    Exit;

  I := 0;
  for Item in ParamsObject do
  begin
    Names[I] := Utf8Bytes(Item.Key);
    Params[I].Name := PChar(Names[I]);
    Params[I].NameLen := Length(Names[I]);
    Params[I].Padding := 0;
    AssignJsonValue(Item.Value, Params[I].Value, TextValues[I], Item.Key);
    Inc(I);
  end;
end;

function IsIdentifierStart(const Ch: Char): Boolean;
begin
  Result := (Ch = '_') or (Ch in ['A'..'Z']) or (Ch in ['a'..'z']);
end;

function IsIdentifierChar(const Ch: Char): Boolean;
begin
  Result := IsIdentifierStart(Ch) or (Ch in ['0'..'9']);
end;

procedure BuildPositionalCommandParams(const Sql: string; Params: TJSONObject; out RewrittenSql: string;
  out Values: TStoolapValueArray; out TextValues: TRawByteStringArray);
var
  I: Integer;
  Start: Integer;
  ParamName: string;
  Value: TJSONData;
  InSingleQuote: Boolean;
  InDoubleQuote: Boolean;
  ParamIndex: Integer;
begin
  RewrittenSql := '';
  SetLength(Values, 0);
  SetLength(TextValues, 0);
  ParamIndex := 0;
  I := 1;
  InSingleQuote := False;
  InDoubleQuote := False;

  while I <= Length(Sql) do
  begin
    if InSingleQuote then
    begin
      RewrittenSql := RewrittenSql + Sql[I];
      if Sql[I] = '''' then
      begin
        if (I < Length(Sql)) and (Sql[I + 1] = '''') then
        begin
          Inc(I);
          RewrittenSql := RewrittenSql + Sql[I];
        end
        else
          InSingleQuote := False;
      end;
      Inc(I);
      Continue;
    end;

    if InDoubleQuote then
    begin
      RewrittenSql := RewrittenSql + Sql[I];
      if Sql[I] = '"' then
      begin
        if (I < Length(Sql)) and (Sql[I + 1] = '"') then
        begin
          Inc(I);
          RewrittenSql := RewrittenSql + Sql[I];
        end
        else
          InDoubleQuote := False;
      end;
      Inc(I);
      Continue;
    end;

    if Sql[I] = '''' then
    begin
      InSingleQuote := True;
      RewrittenSql := RewrittenSql + Sql[I];
      Inc(I);
      Continue;
    end;

    if Sql[I] = '"' then
    begin
      InDoubleQuote := True;
      RewrittenSql := RewrittenSql + Sql[I];
      Inc(I);
      Continue;
    end;

    if (Sql[I] = ':') and ((I = 1) or (Sql[I - 1] <> ':')) and
      (I < Length(Sql)) and IsIdentifierStart(Sql[I + 1]) then
    begin
      Start := I + 1;
      I := Start;
      while (I <= Length(Sql)) and IsIdentifierChar(Sql[I]) do
        Inc(I);
      ParamName := Copy(Sql, Start, I - Start);
      Value := Params.Find(ParamName);
      if Value = nil then
        raise EStoolapAdapterError.Create('missing SQL parameter: ' + ParamName);
      Inc(ParamIndex);
      SetLength(Values, ParamIndex);
      SetLength(TextValues, ParamIndex);
      AssignJsonValue(Value, Values[ParamIndex - 1], TextValues[ParamIndex - 1], ParamName);
      RewrittenSql := RewrittenSql + '$' + IntToStr(ParamIndex);
      Continue;
    end;

    RewrittenSql := RewrittenSql + Sql[I];
    Inc(I);
  end;
end;

function TStoolapAdapter.RowsToJson(Rows: PStoolapRows): TJSONObject;
var
  Status: Integer;
  ColumnCount: Integer;
  I: Integer;
  Columns: TJSONArray;
  Types: TJSONArray;
  RowObjects: TJSONArray;
  RowObject: TJSONObject;
  Values: TJSONArray;
  TypeCode: Integer;
  TextLen: Int64;
  TextPtr: PChar;
  BlobLen: Int64;
  BlobPtr: PByte;
  BlobString: RawByteString;
begin
  Result := TJSONObject.Create;
  Columns := TJSONArray.Create;
  Types := TJSONArray.Create;
  RowObjects := TJSONArray.Create;
  Result.Add('kind', 'result_set');
  Result.Add('columns', Columns);
  Result.Add('types', Types);
  Result.Add('rows', RowObjects);

  ColumnCount := FLibrary.RowsColumnCount(Rows);
  for I := 0 to ColumnCount - 1 do
    Columns.Add(Utf8StringFromNullTerminated(FLibrary.RowsColumnName(Rows, I)));

  Status := FLibrary.RowsNext(Rows);
  while Status = STOOLAP_ROW do
  begin
    RowObject := TJSONObject.Create;
    Values := TJSONArray.Create;
    RowObject.Add('values', Values);

    for I := 0 to ColumnCount - 1 do
    begin
      TypeCode := FLibrary.RowsColumnType(Rows, I);
      if Types.Count < ColumnCount then
        Types.Add(TypeName(TypeCode));

      if FLibrary.RowsColumnIsNull(Rows, I) <> 0 then
        Values.Add(TJSONNull.Create)
      else
        case TypeCode of
          STOOLAP_TYPE_INTEGER:
            Values.Add(FLibrary.RowsColumnInt64(Rows, I));
          STOOLAP_TYPE_TIMESTAMP:
            Values.Add(TimestampNsToIsoUtc(FLibrary.RowsColumnInt64(Rows, I)));
          STOOLAP_TYPE_FLOAT:
            Values.Add(FLibrary.RowsColumnDouble(Rows, I));
          STOOLAP_TYPE_BOOLEAN:
            Values.Add(FLibrary.RowsColumnBool(Rows, I) <> 0);
          STOOLAP_TYPE_TEXT, STOOLAP_TYPE_JSON:
            begin
              TextLen := 0;
              TextPtr := FLibrary.RowsColumnText(Rows, I, @TextLen);
              if TextPtr = nil then
                Values.Add(TJSONNull.Create)
              else
                  Values.Add(Utf8StringFromPtr(TextPtr, TextLen));
            end;
          STOOLAP_TYPE_BLOB:
            begin
              BlobLen := 0;
              BlobPtr := FLibrary.RowsColumnBlob(Rows, I, @BlobLen);
              if (BlobPtr = nil) or (BlobLen <= 0) then
                Values.Add('')
              else
              begin
                SetLength(BlobString, BlobLen);
                Move(BlobPtr^, BlobString[1], BlobLen);
                Values.Add(EncodeStringBase64(BlobString));
              end;
            end;
        else
          Values.Add('[unsupported]');
        end;
    end;

    RowObjects.Add(RowObject);
    Status := FLibrary.RowsNext(Rows);
  end;

  if Status <> STOOLAP_DONE then
    raise EStoolapAdapterError.Create('Stoolap rows iteration failed: ' + Utf8StringFromNullTerminated(FLibrary.RowsErrmsg(Rows)));

  Result.Add('row_count', RowObjects.Count);
end;

procedure RaiseBackendError(const Prefix, MessageText: string);
begin
  if Pos('timeout', LowerCase(MessageText)) > 0 then
    raise EStoolapTimeoutError.Create(Prefix + MessageText);
  raise EStoolapAdapterError.Create(Prefix + MessageText);
end;

function TStoolapAdapter.QueryJson(Db: PStoolapDB; const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
var
  Rows: PStoolapRows;
  Status: Integer;
  NamedParams: array of TStoolapNamedParam;
  Names: array of RawByteString;
  TextValues: array of RawByteString;
  SqlBytes: RawByteString;
begin
  SqlBytes := Utf8Bytes(Sql);
  Rows := nil;
  SetLength(NamedParams, 0);
  SetLength(Names, 0);
  SetLength(TextValues, 0);
  if (Params <> nil) and (Params.Count > 0) then
  begin
    SetLength(NamedParams, Params.Count);
    SetLength(Names, Params.Count);
    SetLength(TextValues, Params.Count);
    BuildNamedParams(Params, NamedParams, Names, TextValues);
    Status := FLibrary.QueryNamedTimeout(Db, PChar(SqlBytes), @NamedParams[0], Length(NamedParams), TimeoutMs, Rows);
  end
  else
    Status := FLibrary.QueryNamedTimeout(Db, PChar(SqlBytes), nil, 0, TimeoutMs, Rows);

  if Status <> STOOLAP_OK then
    RaiseBackendError('Stoolap query failed: ', LastDbError(Db));

  try
    Result := RowsToJson(Rows);
  finally
    if Rows <> nil then
      FLibrary.RowsClose(Rows);
  end;
end;

function TStoolapAdapter.CommandJson(Db: PStoolapDB; const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
var
  Status: Integer;
  RowsAffected: Int64;
  SqlBytes: RawByteString;
  RewrittenSql: string;
  PositionalParams: TStoolapValueArray;
  TextValues: TRawByteStringArray;
begin
  RowsAffected := 0;
  if (Params <> nil) and (Params.Count > 0) then
  begin
    if IsParameterizedInsertSelect(Sql) then
      raise EStoolapAdapterError.Create(
        'parameterized INSERT ... SELECT is not supported by the Stoolap native parameter binding');
    BuildPositionalCommandParams(Sql, Params, RewrittenSql, PositionalParams, TextValues);
    SqlBytes := Utf8Bytes(RewrittenSql);
    if Length(PositionalParams) > 0 then
      Status := FLibrary.ExecParams(Db, PChar(SqlBytes), @PositionalParams[0], Length(PositionalParams), @RowsAffected)
    else
      Status := FLibrary.ExecParams(Db, PChar(SqlBytes), nil, 0, @RowsAffected);
  end
  else
  begin
    SqlBytes := Utf8Bytes(Sql);
    Status := FLibrary.ExecNamedTimeout(Db, PChar(SqlBytes), nil, 0, TimeoutMs, @RowsAffected);
  end;

  if Status <> STOOLAP_OK then
    RaiseBackendError('Stoolap exec failed: ', LastDbError(Db));

  Result := TJSONObject.Create;
  Result.Add('kind', 'command');
  Result.Add('affected_rows', RowsAffected);
  Result.Add('last_insert_id', TJSONNull.Create);
end;

function TStoolapAdapter.ExecuteJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
var
  Db: PStoolapDB;
  PoolIndex: Integer;
  StartedAt: TDateTime;
  RemainingTimeoutMs: Int64;
begin
  StartedAt := Now;
  Db := AcquireDb(TimeoutMs, PoolIndex);
  try
    RemainingTimeoutMs := TimeoutMs - MilliSecondsBetween(Now, StartedAt);
    if RemainingTimeoutMs < 1 then
      raise EStoolapPoolTimeoutError.Create('SQL worker pool wait exceeded timeout_ms');
    if FConfig.ReadOnly and (not IsReadOnlySql(Sql)) then
      raise EStoolapAdapterError.Create('Stoolap database is configured read-only; SQL commands are not allowed');
    if IsQuerySql(Sql) then
      Result := QueryJson(Db, Sql, Params, RemainingTimeoutMs)
    else
      Result := CommandJson(Db, Sql, Params, RemainingTimeoutMs);
  finally
    ReleaseDb(PoolIndex);
  end;
end;

function TStoolapAdapter.Version: string;
begin
  if FLibrary = nil then
    FLibrary := TStoolapLibrary.Create(FConfig.LibraryPath);
  Result := FLibrary.Version;
end;

end.
