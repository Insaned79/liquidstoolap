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
      Result := StrPas(MessagePtr);
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

procedure TStoolapAdapter.Open;
var
  Status: Integer;
begin
  if FLibrary = nil then
    FLibrary := TStoolapLibrary.Create(FConfig.LibraryPath);

  if FDb <> nil then
    Exit;

  if Dsn = 'memory://' then
    Status := FLibrary.OpenInMemory(FDb)
  else
    Status := FLibrary.Open(PChar(Dsn), FDb);

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
    Names[I] := RawByteString(Item.Key);
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
          TextValues[I] := RawByteString(Value.AsString);
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
    Columns.Add(StrPas(FLibrary.RowsColumnName(Rows, I)));

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
                  Values.Add(Copy(StrPas(TextPtr), 1, TextLen));
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
    raise EStoolapAdapterError.Create('Stoolap rows iteration failed: ' + StrPas(FLibrary.RowsErrmsg(Rows)));

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
begin
  Open;
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
    Status := FLibrary.QueryNamedTimeout(FDb, PChar(Sql), @NamedParams[0], Length(NamedParams), TimeoutMs, Rows);
  end
  else
    Status := FLibrary.QueryNamedTimeout(FDb, PChar(Sql), nil, 0, TimeoutMs, Rows);

  if Status <> STOOLAP_OK then
    RaiseBackendError('Stoolap query failed: ', LastDbError);

  try
    Result := RowsToJson(Rows);
  finally
    if Rows <> nil then
      FLibrary.RowsClose(Rows);
  end;
end;

function TStoolapAdapter.CommandJson(const Sql: string; Params: TJSONObject; TimeoutMs: Int64): TJSONObject;
var
  Status: Integer;
  RowsAffected: Int64;
  NamedParams: array of TStoolapNamedParam;
  Names: array of RawByteString;
  TextValues: array of RawByteString;
begin
  Open;
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
    Status := FLibrary.ExecNamedTimeout(FDb, PChar(Sql), @NamedParams[0], Length(NamedParams), TimeoutMs, @RowsAffected);
  end
  else
    Status := FLibrary.ExecNamedTimeout(FDb, PChar(Sql), nil, 0, TimeoutMs, @RowsAffected);

  if Status <> STOOLAP_OK then
    RaiseBackendError('Stoolap exec failed: ', LastDbError);

  Result := TJSONObject.Create;
  Result.Add('kind', 'command');
  Result.Add('affected_rows', RowsAffected);
  Result.Add('last_insert_id', TJSONNull.Create);
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
