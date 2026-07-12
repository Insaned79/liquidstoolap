unit lsrequestvalidation;

{$mode objfpc}{$H+}

interface

uses
  fpjson;

function ContainsMultiStatement(const Sql: string): Boolean;
function HasOnlyKeys(Obj: TJSONObject; const Allowed: array of string; out BadKey: string): Boolean;
function IsJsonInteger(Value: TJSONData): Boolean;
function IsScalarJsonValue(Value: TJSONData): Boolean;
function ValidateScalarParams(ParamsObject: TJSONObject; out BadKey: string): Boolean;

implementation

uses
  SysUtils;

function ContainsMultiStatement(const Sql: string): Boolean;
var
  I: Integer;
  InSingleQuote: Boolean;
begin
  Result := False;
  InSingleQuote := False;
  for I := 1 to Length(Sql) do
  begin
    if Sql[I] = '''' then
      InSingleQuote := not InSingleQuote
    else if (Sql[I] = ';') and not InSingleQuote and (Trim(Copy(Sql, I + 1, MaxInt)) <> '') then
      Exit(True);
  end;
end;

function HasOnlyKeys(Obj: TJSONObject; const Allowed: array of string; out BadKey: string): Boolean;
var
  Item: TJSONEnum;
  I: Integer;
  Found: Boolean;
begin
  Result := True;
  BadKey := '';
  for Item in Obj do
  begin
    Found := False;
    for I := Low(Allowed) to High(Allowed) do
      if Item.Key = Allowed[I] then
      begin
        Found := True;
        Break;
      end;
    if not Found then
    begin
      BadKey := Item.Key;
      Exit(False);
    end;
  end;
end;

function IsJsonInteger(Value: TJSONData): Boolean;
var
  Raw: string;
begin
  Result := False;
  if (Value = nil) or (Value.JSONType <> jtNumber) then
    Exit;
  Raw := LowerCase(Value.AsJSON);
  Result := (Pos('.', Raw) = 0) and (Pos('e', Raw) = 0);
end;

function IsScalarJsonValue(Value: TJSONData): Boolean;
begin
  Result := (Value <> nil) and (Value.JSONType in [jtNull, jtBoolean, jtNumber, jtString]);
end;

function ValidateScalarParams(ParamsObject: TJSONObject; out BadKey: string): Boolean;
var
  Item: TJSONEnum;
begin
  Result := True;
  BadKey := '';
  if ParamsObject = nil then
    Exit;
  for Item in ParamsObject do
    if not IsScalarJsonValue(Item.Value) then
    begin
      BadKey := Item.Key;
      Exit(False);
    end;
end;

end.
