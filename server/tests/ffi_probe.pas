program ffi_probe;

{$mode objfpc}{$H+}

uses
  SysUtils, lsstoolapffi;

function ArgValue(const Name: string; const DefaultValue: string): string;
var
  I: Integer;
begin
  Result := DefaultValue;
  for I := 1 to ParamCount - 1 do
    if ParamStr(I) = Name then
      Exit(ParamStr(I + 1));
end;

procedure Fail(const MessageText: string);
begin
  WriteLn(StdErr, MessageText);
  Halt(1);
end;

var
  LibraryPath: string;
  Lib: TStoolapLibrary;
  Db: PStoolapDB;
  Rows: PStoolapRows;
  Status: Integer;
  ColumnCount: Integer;
  Value: Int64;

begin
  LibraryPath := ArgValue('--lib', '../.cargo-target/release/libstoolap.so');
  Lib := TStoolapLibrary.Create(LibraryPath);
  Db := nil;
  Rows := nil;
  try
    WriteLn('stoolap_version=', Lib.Version);

    Status := Lib.OpenInMemory(Db);
    if Status <> STOOLAP_OK then
      Fail('stoolap_open_in_memory failed: ' + StrPas(Lib.Errmsg(Db)));

    Status := Lib.Query(Db, 'SELECT 1', Rows);
    if Status <> STOOLAP_OK then
      Fail('stoolap_query failed: ' + StrPas(Lib.Errmsg(Db)));

    ColumnCount := Lib.RowsColumnCount(Rows);
    if ColumnCount <> 1 then
      Fail('expected one column, got ' + IntToStr(ColumnCount));

    Status := Lib.RowsNext(Rows);
    if Status <> STOOLAP_ROW then
      Fail('expected one row, got status ' + IntToStr(Status));

    if Lib.RowsColumnType(Rows, 0) <> STOOLAP_TYPE_INTEGER then
      Fail('expected INTEGER column');

    Value := Lib.RowsColumnInt64(Rows, 0);
    if Value <> 1 then
      Fail('expected SELECT 1 to return 1, got ' + IntToStr(Value));

    WriteLn('select_1=', Value);
  finally
    if Rows <> nil then
      Lib.RowsClose(Rows);
    if Db <> nil then
      Lib.Close(Db);
    Lib.Free;
  end;
end.
