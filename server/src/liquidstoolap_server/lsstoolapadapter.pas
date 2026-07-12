unit lsstoolapadapter;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, base64, lsconfig, lsstoolapffi;

type
  EStoolapAdapterError = class(Exception);
  EStoolapTimeoutError = class(EStoolapAdapterError);

  TStoolapAdapter = class
  private
    FLibrary: TStoolapLibrary;
    FDb: PStoolapDB;
    FConfig: TStoolapConfig;
    function Dsn: string;
    function LastDbError: string;
    function IsQuerySql(const Sql: string): Boolean;
    function RowsToJson(Rows: PStoolapRows): TJSONObject;
    function CommandJsonRaw(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
    function QueryScalarInt64(const Sql: string; TimeoutMs: Int64): Int64;
    function TryRewriteTelemetryInsert(const Sql: string; out RewrittenSql: string): Boolean;
    function IsTelemetryMutation(const Sql: string): Boolean;
    procedure RefreshTelemetryDim(TimeoutMs: Int64);
  public
    constructor Create(const Config: TStoolapConfig);
    destructor Destroy; override;
    procedure Open;
    procedure Close;
    procedure StartupCheck;
    function ExecuteJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
    function QueryJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
    function CommandJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
    function Version: string;
  end;

implementation

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

constructor TStoolapAdapter.Create(const Config: TStoolapConfig);
begin
  inherited Create;
  FConfig := Config;
  FDb := nil;
end;

destructor TStoolapAdapter.Destroy;
begin
  Close;
  FLibrary.Free;
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

function TStoolapAdapter.LastDbError: string;
var
  MessagePtr: PChar;
begin
  Result := '';
  if Assigned(FLibrary) and Assigned(FLibrary.Errmsg) then
  begin
    MessagePtr := FLibrary.Errmsg(FDb);
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

function StripIdentifier(const Value: string): string;
var
  S: string;
begin
  S := Trim(Value);
  if (Length(S) >= 2) and (S[1] = '"') and (S[Length(S)] = '"') then
    S := Copy(S, 2, Length(S) - 2);
  Result := UpperCase(S);
end;

function FindMatchingParen(const S: string; OpenPos: Integer): Integer;
var
  I: Integer;
  Depth: Integer;
  InString: Boolean;
begin
  Result := 0;
  Depth := 0;
  InString := False;
  I := OpenPos;
  while I <= Length(S) do
  begin
    if S[I] = '''' then
    begin
      if InString and (I < Length(S)) and (S[I + 1] = '''') then
        Inc(I)
      else
        InString := not InString;
    end
    else if not InString then
    begin
      if S[I] = '(' then
        Inc(Depth)
      else if S[I] = ')' then
      begin
        Dec(Depth);
        if Depth = 0 then
          Exit(I);
      end;
    end;
    Inc(I);
  end;
end;

function NextWord(const S: string; var PosIndex: Integer): string;
var
  Start: Integer;
begin
  while (PosIndex <= Length(S)) and (S[PosIndex] <= ' ') do
    Inc(PosIndex);
  if PosIndex > Length(S) then
    Exit('');
  if S[PosIndex] = '"' then
  begin
    Start := PosIndex;
    Inc(PosIndex);
    while (PosIndex <= Length(S)) and (S[PosIndex] <> '"') do
      Inc(PosIndex);
    if PosIndex <= Length(S) then
      Inc(PosIndex);
    Exit(Copy(S, Start, PosIndex - Start));
  end;
  Start := PosIndex;
  while (PosIndex <= Length(S)) and not (S[PosIndex] in [' ', #9, #10, #13, '(']) do
    Inc(PosIndex);
  Result := Copy(S, Start, PosIndex - Start);
end;

function TStoolapAdapter.QueryScalarInt64(const Sql: string; TimeoutMs: Int64): Int64;
var
  Json: TJSONObject;
  Rows: TJSONArray;
  Row: TJSONObject;
  Values: TJSONArray;
begin
  Json := QueryJson(Sql, nil, TimeoutMs);
  try
    Rows := Json.Arrays['rows'];
    if Rows.Count = 0 then
      Exit(0);
    Row := Rows.Objects[0];
    Values := Row.Arrays['values'];
    if (Values.Count = 0) or (Values.Items[0].JSONType = jtNull) then
      Exit(0);
    Result := Values.Integers[0];
  finally
    Json.Free;
  end;
end;

function TStoolapAdapter.TryRewriteTelemetryInsert(const Sql: string; out RewrittenSql: string): Boolean;
var
  S: string;
  Upper: string;
  P: Integer;
  InsertWord: string;
  IntoWord: string;
  TableName: string;
  ColumnsStart: Integer;
  ColumnsEnd: Integer;
  ValuesPos: Integer;
  ValuesStart: Integer;
  ValuesEnd: Integer;
  ColumnsText: string;
  NextId: Int64;
  Tail: string;
begin
  Result := False;
  RewrittenSql := Sql;
  S := Trim(Sql);
  if (S <> '') and (S[Length(S)] = ';') then
    Delete(S, Length(S), 1);

  P := 1;
  InsertWord := UpperCase(NextWord(S, P));
  IntoWord := UpperCase(NextWord(S, P));
  if (InsertWord <> 'INSERT') or (IntoWord <> 'INTO') then
    Exit;
  TableName := NextWord(S, P);
  if StripIdentifier(TableName) <> 'TELEMETRY' then
    Exit;

  while (P <= Length(S)) and (S[P] <= ' ') do
    Inc(P);
  if (P > Length(S)) or (S[P] <> '(') then
    Exit;
  ColumnsStart := P;
  ColumnsEnd := FindMatchingParen(S, ColumnsStart);
  if ColumnsEnd = 0 then
    Exit;
  ColumnsText := Copy(S, ColumnsStart + 1, ColumnsEnd - ColumnsStart - 1);
  if Pos('ID', UpperCase(StringReplace(ColumnsText, '"', '', [rfReplaceAll]))) > 0 then
    Exit;

  Upper := UpperCase(S);
  ValuesPos := Pos('VALUES', Copy(Upper, ColumnsEnd + 1, MaxInt));
  if ValuesPos = 0 then
    Exit;
  ValuesPos := ColumnsEnd + ValuesPos;
  ValuesStart := ValuesPos + Length('VALUES');
  while (ValuesStart <= Length(S)) and (S[ValuesStart] <= ' ') do
    Inc(ValuesStart);
  if (ValuesStart > Length(S)) or (S[ValuesStart] <> '(') then
    Exit;
  ValuesEnd := FindMatchingParen(S, ValuesStart);
  if ValuesEnd = 0 then
    Exit;
  Tail := Trim(Copy(S, ValuesEnd + 1, MaxInt));
  if (Tail <> '') and (Tail[1] = ',') then
    raise EStoolapAdapterError.Create('Firebird compatibility auto-ID supports single-row TELEMETRY INSERT only');

  NextId := QueryScalarInt64('SELECT max("ID") FROM "TELEMETRY"', 60000) + 1;
  RewrittenSql :=
    Copy(S, 1, ColumnsStart) + '"ID", ' +
    Copy(S, ColumnsStart + 1, ColumnsEnd - ColumnsStart - 1) +
    Copy(S, ColumnsEnd, ValuesStart - ColumnsEnd + 1) + IntToStr(NextId) + ', ' +
    Copy(S, ValuesStart + 1, MaxInt);
  Result := True;
end;

function TStoolapAdapter.IsTelemetryMutation(const Sql: string): Boolean;
var
  S: string;
  P: Integer;
  First: string;
  Second: string;
  TableName: string;
begin
  Result := False;
  S := Trim(Sql);
  if (S <> '') and (S[Length(S)] = ';') then
    Delete(S, Length(S), 1);
  P := 1;
  First := UpperCase(NextWord(S, P));
  if First = 'INSERT' then
  begin
    Second := UpperCase(NextWord(S, P));
    if Second <> 'INTO' then
      Exit;
    TableName := NextWord(S, P);
  end
  else if First = 'DELETE' then
  begin
    Second := UpperCase(NextWord(S, P));
    if Second <> 'FROM' then
      Exit;
    TableName := NextWord(S, P);
  end
  else if First = 'UPDATE' then
    TableName := NextWord(S, P)
  else
    Exit;
  Result := StripIdentifier(TableName) = 'TELEMETRY';
end;

procedure TStoolapAdapter.RefreshTelemetryDim(TimeoutMs: Int64);
var
  Obj: TJSONObject;
begin
  Obj := CommandJsonRaw('DROP TABLE IF EXISTS "TELEMETRY_DIM"', nil, TimeoutMs);
  Obj.Free;
  Obj := CommandJsonRaw('CREATE TABLE "TELEMETRY_DIM" ("TYPE" TEXT, "NAME" TEXT, "FIRST_DATE_TIME" TIMESTAMP, "LAST_DATE_TIME" TIMESTAMP, "CNT" INTEGER)', nil, TimeoutMs);
  Obj.Free;
  Obj := CommandJsonRaw(
    'INSERT INTO "TELEMETRY_DIM" ("TYPE", "NAME", "FIRST_DATE_TIME", "LAST_DATE_TIME", "CNT") ' +
    'SELECT "TYPE", "NAME", min("DATE_TIME"), max("DATE_TIME"), count(*) FROM "TELEMETRY" ' +
    'WHERE "TYPE" IS NOT NULL AND "NAME" IS NOT NULL GROUP BY "TYPE", "NAME"',
    nil, TimeoutMs);
  Obj.Free;
  Obj := CommandJsonRaw('CREATE UNIQUE INDEX PK_TELEMETRY_DIM ON "TELEMETRY_DIM" ("NAME", "TYPE")', nil, TimeoutMs);
  Obj.Free;
end;

procedure TStoolapAdapter.Open;
var
  Status: Integer;
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
    raise EStoolapAdapterError.Create('failed to open Stoolap database: ' + LastDbError);
end;

procedure TStoolapAdapter.Close;
begin
  if (FLibrary <> nil) and (FDb <> nil) then
  begin
    FLibrary.Close(FDb);
    FDb := nil;
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
    raise EStoolapAdapterError.Create('Stoolap startup query failed: ' + LastDbError);
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

procedure BuildNamedParams(ParamsObject: TJSONObject; out Params: array of TStoolapNamedParam;
  out Names: array of RawByteString; out TextValues: array of RawByteString);
var
  I: Integer;
  Item: TJSONEnum;
  Value: TJSONData;
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
    Value := Item.Value;

    case Value.JSONType of
      jtNull:
        Params[I].Value.ValueType := STOOLAP_TYPE_NULL;
      jtBoolean:
        begin
          Params[I].Value.ValueType := STOOLAP_TYPE_BOOLEAN;
          if Value.AsBoolean then
            Params[I].Value.V.BooleanValue := 1
          else
            Params[I].Value.V.BooleanValue := 0;
        end;
      jtNumber:
        begin
          if Pos('.', Value.AsJSON) > 0 then
          begin
            Params[I].Value.ValueType := STOOLAP_TYPE_FLOAT;
            Params[I].Value.V.FloatValue := Value.AsFloat;
          end
          else
          begin
            Params[I].Value.ValueType := STOOLAP_TYPE_INTEGER;
            Params[I].Value.V.IntegerValue := Value.AsInt64;
          end;
        end;
      jtString:
        begin
          TextValues[I] := Utf8Bytes(Value.AsString);
          Params[I].Value.ValueType := STOOLAP_TYPE_TEXT;
          Params[I].Value.V.TextValue.Ptr := PChar(TextValues[I]);
          Params[I].Value.V.TextValue.Len := Length(TextValues[I]);
        end;
    else
      raise EStoolapAdapterError.Create('unsupported SQL parameter type for ' + Item.Key);
    end;
    Params[I].Value.Padding := 0;
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
          STOOLAP_TYPE_INTEGER, STOOLAP_TYPE_TIMESTAMP:
            Values.Add(FLibrary.RowsColumnInt64(Rows, I));
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

function TStoolapAdapter.QueryJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
var
  Rows: PStoolapRows;
  Status: Integer;
  NamedParams: array of TStoolapNamedParam;
  Names: array of RawByteString;
  TextValues: array of RawByteString;
  SqlBytes: RawByteString;
begin
  Open;
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
    Status := FLibrary.QueryNamedTimeout(FDb, PChar(SqlBytes), @NamedParams[0], Length(NamedParams), TimeoutMs, Rows);
  end
  else
    Status := FLibrary.QueryNamedTimeout(FDb, PChar(SqlBytes), nil, 0, TimeoutMs, Rows);

  if Status <> STOOLAP_OK then
    RaiseBackendError('Stoolap query failed: ', LastDbError);

  try
    Result := RowsToJson(Rows);
  finally
    if Rows <> nil then
      FLibrary.RowsClose(Rows);
  end;
end;

function TStoolapAdapter.CommandJsonRaw(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
var
  Status: Integer;
  RowsAffected: Int64;
  NamedParams: array of TStoolapNamedParam;
  Names: array of RawByteString;
  TextValues: array of RawByteString;
  SqlBytes: RawByteString;
begin
  Open;
  SqlBytes := Utf8Bytes(Sql);
  RowsAffected := 0;
  SetLength(NamedParams, 0);
  SetLength(Names, 0);
  SetLength(TextValues, 0);
  if (Params <> nil) and (Params.Count > 0) then
  begin
    SetLength(NamedParams, Params.Count);
    SetLength(Names, Params.Count);
    SetLength(TextValues, Params.Count);
    BuildNamedParams(Params, NamedParams, Names, TextValues);
    Status := FLibrary.ExecNamedTimeout(FDb, PChar(SqlBytes), @NamedParams[0], Length(NamedParams), TimeoutMs, @RowsAffected);
  end
  else
    Status := FLibrary.ExecNamedTimeout(FDb, PChar(SqlBytes), nil, 0, TimeoutMs, @RowsAffected);

  if Status <> STOOLAP_OK then
    RaiseBackendError('Stoolap exec failed: ', LastDbError);

  Result := TJSONObject.Create;
  Result.Add('kind', 'command');
  Result.Add('affected_rows', RowsAffected);
  Result.Add('last_insert_id', TJSONNull.Create);
end;

function TStoolapAdapter.CommandJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
var
  SqlToExecute: string;
begin
  SqlToExecute := Sql;
  TryRewriteTelemetryInsert(Sql, SqlToExecute);
  Result := CommandJsonRaw(SqlToExecute, Params, TimeoutMs);
  if IsTelemetryMutation(SqlToExecute) then
    RefreshTelemetryDim(TimeoutMs);
end;

function TStoolapAdapter.ExecuteJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
begin
  if IsQuerySql(Sql) then
    Result := QueryJson(Sql, Params, TimeoutMs)
  else if FConfig.ReadOnly then
    raise EStoolapAdapterError.Create('Stoolap database is configured read-only; SQL commands are not allowed')
  else
    Result := CommandJson(Sql, Params, TimeoutMs);
end;

function TStoolapAdapter.Version: string;
begin
  if FLibrary = nil then
    FLibrary := TStoolapLibrary.Create(FConfig.LibraryPath);
  Result := FLibrary.Version;
end;

end.
