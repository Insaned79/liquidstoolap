unit lsstoolapffi;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DynLibs, ctypes;

const
  STOOLAP_OK = 0;
  STOOLAP_ERROR = 1;
  STOOLAP_ROW = 100;
  STOOLAP_DONE = 101;

  STOOLAP_TYPE_NULL = 0;
  STOOLAP_TYPE_INTEGER = 1;
  STOOLAP_TYPE_FLOAT = 2;
  STOOLAP_TYPE_TEXT = 3;
  STOOLAP_TYPE_BOOLEAN = 4;
  STOOLAP_TYPE_TIMESTAMP = 5;
  STOOLAP_TYPE_JSON = 6;
  STOOLAP_TYPE_BLOB = 7;

type
  PStoolapDB = Pointer;
  PStoolapRows = Pointer;

  TStoolapTextData = record
    Ptr: PChar;
    Len: Int64;
  end;

  TStoolapBlobData = record
    Ptr: PByte;
    Len: Int64;
  end;

  TStoolapValueData = record
    case Integer of
      0: (IntegerValue: Int64);
      1: (FloatValue: Double);
      2: (BooleanValue: cint);
      3: (TextValue: TStoolapTextData);
      4: (BlobValue: TStoolapBlobData);
      5: (TimestampNanos: Int64);
  end;

  TStoolapValue = record
    ValueType: cint;
    Padding: cint;
    V: TStoolapValueData;
  end;
  PStoolapValue = ^TStoolapValue;

  TStoolapNamedParam = record
    Name: PChar;
    NameLen: cint;
    Padding: cint;
    Value: TStoolapValue;
  end;
  PStoolapNamedParam = ^TStoolapNamedParam;

  TStoolapVersionFunc = function: PChar; cdecl;
  TStoolapOpenFunc = function(Dsn: PChar; var OutDb: PStoolapDB): cint; cdecl;
  TStoolapOpenInMemoryFunc = function(var OutDb: PStoolapDB): cint; cdecl;
  TStoolapCloneFunc = function(Db: PStoolapDB; var OutDb: PStoolapDB): cint; cdecl;
  TStoolapCloseFunc = function(Db: PStoolapDB): cint; cdecl;
  TStoolapErrmsgFunc = function(Db: PStoolapDB): PChar; cdecl;
  TStoolapExecFunc = function(Db: PStoolapDB; Sql: PChar; RowsAffected: PInt64): cint; cdecl;
  TStoolapExecNamedFunc = function(Db: PStoolapDB; Sql: PChar; Params: PStoolapNamedParam;
    ParamsLen: cint; RowsAffected: PInt64): cint; cdecl;
  TStoolapExecNamedTimeoutFunc = function(Db: PStoolapDB; Sql: PChar; Params: PStoolapNamedParam;
    ParamsLen: cint; TimeoutMs: QWord; RowsAffected: PInt64): cint; cdecl;
  TStoolapQueryFunc = function(Db: PStoolapDB; Sql: PChar; var OutRows: PStoolapRows): cint; cdecl;
  TStoolapQueryNamedFunc = function(Db: PStoolapDB; Sql: PChar; Params: PStoolapNamedParam;
    ParamsLen: cint; var OutRows: PStoolapRows): cint; cdecl;
  TStoolapQueryNamedTimeoutFunc = function(Db: PStoolapDB; Sql: PChar; Params: PStoolapNamedParam;
    ParamsLen: cint; TimeoutMs: QWord; var OutRows: PStoolapRows): cint; cdecl;
  TStoolapRowsNextFunc = function(Rows: PStoolapRows): cint; cdecl;
  TStoolapRowsColumnCountFunc = function(Rows: PStoolapRows): cint; cdecl;
  TStoolapRowsColumnNameFunc = function(Rows: PStoolapRows; Index: cint): PChar; cdecl;
  TStoolapRowsColumnTypeFunc = function(Rows: PStoolapRows; Index: cint): cint; cdecl;
  TStoolapRowsColumnIsNullFunc = function(Rows: PStoolapRows; Index: cint): cint; cdecl;
  TStoolapRowsColumnInt64Func = function(Rows: PStoolapRows; Index: cint): Int64; cdecl;
  TStoolapRowsColumnDoubleFunc = function(Rows: PStoolapRows; Index: cint): Double; cdecl;
  TStoolapRowsColumnTextFunc = function(Rows: PStoolapRows; Index: cint; OutLen: PInt64): PChar; cdecl;
  TStoolapRowsColumnBoolFunc = function(Rows: PStoolapRows; Index: cint): cint; cdecl;
  TStoolapRowsColumnBlobFunc = function(Rows: PStoolapRows; Index: cint; OutLen: PInt64): PByte; cdecl;
  TStoolapRowsCloseProc = procedure(Rows: PStoolapRows); cdecl;
  TStoolapRowsErrmsgFunc = function(Rows: PStoolapRows): PChar; cdecl;

  EStoolapLibraryError = class(Exception);

  TStoolapLibrary = class
  private
    FHandle: TLibHandle;
    FVersion: TStoolapVersionFunc;
    FOpen: TStoolapOpenFunc;
    FOpenInMemory: TStoolapOpenInMemoryFunc;
    FClone: TStoolapCloneFunc;
    FClose: TStoolapCloseFunc;
    FErrmsg: TStoolapErrmsgFunc;
    FExec: TStoolapExecFunc;
    FExecNamed: TStoolapExecNamedFunc;
    FExecNamedTimeout: TStoolapExecNamedTimeoutFunc;
    FQuery: TStoolapQueryFunc;
    FQueryNamed: TStoolapQueryNamedFunc;
    FQueryNamedTimeout: TStoolapQueryNamedTimeoutFunc;
    FRowsNext: TStoolapRowsNextFunc;
    FRowsColumnCount: TStoolapRowsColumnCountFunc;
    FRowsColumnName: TStoolapRowsColumnNameFunc;
    FRowsColumnType: TStoolapRowsColumnTypeFunc;
    FRowsColumnIsNull: TStoolapRowsColumnIsNullFunc;
    FRowsColumnInt64: TStoolapRowsColumnInt64Func;
    FRowsColumnDouble: TStoolapRowsColumnDoubleFunc;
    FRowsColumnText: TStoolapRowsColumnTextFunc;
    FRowsColumnBool: TStoolapRowsColumnBoolFunc;
    FRowsColumnBlob: TStoolapRowsColumnBlobFunc;
    FRowsClose: TStoolapRowsCloseProc;
    FRowsErrmsg: TStoolapRowsErrmsgFunc;
    procedure RequireSymbol(const SymbolName: string; var Target: Pointer);
    procedure ResolveSymbols;
  public
    constructor Create(const LibraryPath: string);
    destructor Destroy; override;
    function Version: string;
    property Open: TStoolapOpenFunc read FOpen;
    property OpenInMemory: TStoolapOpenInMemoryFunc read FOpenInMemory;
    property Clone: TStoolapCloneFunc read FClone;
    property Close: TStoolapCloseFunc read FClose;
    property Errmsg: TStoolapErrmsgFunc read FErrmsg;
    property Exec: TStoolapExecFunc read FExec;
    property ExecNamed: TStoolapExecNamedFunc read FExecNamed;
    property ExecNamedTimeout: TStoolapExecNamedTimeoutFunc read FExecNamedTimeout;
    property Query: TStoolapQueryFunc read FQuery;
    property QueryNamed: TStoolapQueryNamedFunc read FQueryNamed;
    property QueryNamedTimeout: TStoolapQueryNamedTimeoutFunc read FQueryNamedTimeout;
    property RowsNext: TStoolapRowsNextFunc read FRowsNext;
    property RowsColumnCount: TStoolapRowsColumnCountFunc read FRowsColumnCount;
    property RowsColumnName: TStoolapRowsColumnNameFunc read FRowsColumnName;
    property RowsColumnType: TStoolapRowsColumnTypeFunc read FRowsColumnType;
    property RowsColumnIsNull: TStoolapRowsColumnIsNullFunc read FRowsColumnIsNull;
    property RowsColumnInt64: TStoolapRowsColumnInt64Func read FRowsColumnInt64;
    property RowsColumnDouble: TStoolapRowsColumnDoubleFunc read FRowsColumnDouble;
    property RowsColumnText: TStoolapRowsColumnTextFunc read FRowsColumnText;
    property RowsColumnBool: TStoolapRowsColumnBoolFunc read FRowsColumnBool;
    property RowsColumnBlob: TStoolapRowsColumnBlobFunc read FRowsColumnBlob;
    property RowsClose: TStoolapRowsCloseProc read FRowsClose;
    property RowsErrmsg: TStoolapRowsErrmsgFunc read FRowsErrmsg;
  end;

implementation

constructor TStoolapLibrary.Create(const LibraryPath: string);
begin
  inherited Create;
  FHandle := LoadLibrary(LibraryPath);
  if FHandle = NilHandle then
    raise EStoolapLibraryError.Create('failed to load Stoolap library: ' + LibraryPath);
  ResolveSymbols;
end;

destructor TStoolapLibrary.Destroy;
begin
  if FHandle <> NilHandle then
    UnloadLibrary(FHandle);
  inherited Destroy;
end;

procedure TStoolapLibrary.RequireSymbol(const SymbolName: string; var Target: Pointer);
begin
  Target := GetProcedureAddress(FHandle, SymbolName);
  if Target = nil then
    raise EStoolapLibraryError.Create('missing Stoolap symbol: ' + SymbolName);
end;

procedure TStoolapLibrary.ResolveSymbols;
begin
  RequireSymbol('stoolap_version', Pointer(FVersion));
  RequireSymbol('stoolap_open', Pointer(FOpen));
  RequireSymbol('stoolap_open_in_memory', Pointer(FOpenInMemory));
  RequireSymbol('stoolap_clone', Pointer(FClone));
  RequireSymbol('stoolap_close', Pointer(FClose));
  RequireSymbol('stoolap_errmsg', Pointer(FErrmsg));
  RequireSymbol('stoolap_exec', Pointer(FExec));
  RequireSymbol('stoolap_exec_named', Pointer(FExecNamed));
  RequireSymbol('stoolap_exec_named_timeout', Pointer(FExecNamedTimeout));
  RequireSymbol('stoolap_query', Pointer(FQuery));
  RequireSymbol('stoolap_query_named', Pointer(FQueryNamed));
  RequireSymbol('stoolap_query_named_timeout', Pointer(FQueryNamedTimeout));
  RequireSymbol('stoolap_rows_next', Pointer(FRowsNext));
  RequireSymbol('stoolap_rows_column_count', Pointer(FRowsColumnCount));
  RequireSymbol('stoolap_rows_column_name', Pointer(FRowsColumnName));
  RequireSymbol('stoolap_rows_column_type', Pointer(FRowsColumnType));
  RequireSymbol('stoolap_rows_column_is_null', Pointer(FRowsColumnIsNull));
  RequireSymbol('stoolap_rows_column_int64', Pointer(FRowsColumnInt64));
  RequireSymbol('stoolap_rows_column_double', Pointer(FRowsColumnDouble));
  RequireSymbol('stoolap_rows_column_text', Pointer(FRowsColumnText));
  RequireSymbol('stoolap_rows_column_bool', Pointer(FRowsColumnBool));
  RequireSymbol('stoolap_rows_column_blob', Pointer(FRowsColumnBlob));
  RequireSymbol('stoolap_rows_close', Pointer(FRowsClose));
  RequireSymbol('stoolap_rows_errmsg', Pointer(FRowsErrmsg));
end;

function TStoolapLibrary.Version: string;
begin
  if Assigned(FVersion) then
    Result := StrPas(FVersion())
  else
    Result := '';
end;

end.
