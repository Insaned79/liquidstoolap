program test_requestvalidation;

{$mode objfpc}{$H+}

uses
  SysUtils, fpjson, jsonparser, lsrequestvalidation;

procedure AssertTrue(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
  begin
    WriteLn(StdErr, 'FAIL: ', MessageText);
    Halt(1);
  end;
end;

function ParseObject(const Source: string): TJSONObject;
begin
  Result := TJSONObject(GetJSON(Source));
end;

procedure TestMultiStatement;
begin
  AssertTrue(not ContainsMultiStatement('SELECT 1'), 'single select');
  AssertTrue(not ContainsMultiStatement('SELECT 1;'), 'trailing semicolon');
  AssertTrue(not ContainsMultiStatement('SELECT '';'''), 'semicolon inside string');
  AssertTrue(not ContainsMultiStatement('SELECT ''a'''';b'''), 'semicolon inside escaped single-quoted string');
  AssertTrue(not ContainsMultiStatement('SELECT ";";'), 'semicolon inside double-quoted identifier');
  AssertTrue(not ContainsMultiStatement('SELECT 1 -- ; inside comment' + LineEnding), 'semicolon inside line comment');
  AssertTrue(not ContainsMultiStatement('SELECT 1 /* ; inside comment */'), 'semicolon inside block comment');
  AssertTrue(ContainsMultiStatement('SELECT 1; SELECT 2'), 'two statements');
  AssertTrue(ContainsMultiStatement('SELECT 1 /* comment */; SELECT 2'), 'two statements after block comment');
end;

procedure TestAllowedKeys;
var
  Obj: TJSONObject;
  BadKey: string;
begin
  Obj := ParseObject('{"sql":"SELECT 1","params":{}}');
  try
    AssertTrue(HasOnlyKeys(Obj, ['sql', 'params', 'timeout_ms'], BadKey), 'allowed keys');
  finally
    Obj.Free;
  end;

  Obj := ParseObject('{"sql":"SELECT 1","extra":true}');
  try
    AssertTrue(not HasOnlyKeys(Obj, ['sql', 'params', 'timeout_ms'], BadKey), 'unknown key rejected');
    AssertTrue(BadKey = 'extra', 'bad key name');
  finally
    Obj.Free;
  end;
end;

procedure TestTimeoutIntegers;
var
  Obj: TJSONObject;
begin
  Obj := ParseObject('{"a":1,"b":1.5,"c":1e3,"d":"1"}');
  try
    AssertTrue(IsJsonInteger(Obj.Find('a')), 'integer accepted');
    AssertTrue(not IsJsonInteger(Obj.Find('b')), 'float rejected');
    AssertTrue(not IsJsonInteger(Obj.Find('c')), 'exponent rejected');
    AssertTrue(not IsJsonInteger(Obj.Find('d')), 'string rejected');
  finally
    Obj.Free;
  end;
end;

procedure TestJsonDepth;
begin
  AssertTrue(IsJsonDepthAllowed('{"sql":"SELECT ''{not depth}''","params":{"x":"[still string]"}}', 4),
    'brackets inside strings ignored');
  AssertTrue(IsJsonDepthAllowed('{"a":[{"b":1}]}', 3), 'nested document within limit');
  AssertTrue(not IsJsonDepthAllowed('{"a":[{"b":1}]}', 2), 'nested document beyond limit');
  AssertTrue(IsJsonDepthAllowed('{"a":"escaped quote: \" and bracket: {"}', 1), 'escaped quote handled');
end;

procedure TestScalarParams;
var
  Obj: TJSONObject;
  BadKey: string;
begin
  Obj := ParseObject('{"a":null,"b":true,"c":3,"d":"x"}');
  try
    AssertTrue(ValidateScalarParams(Obj, BadKey), 'scalar params accepted');
  finally
    Obj.Free;
  end;

  Obj := ParseObject('{"a":[],"b":{}}');
  try
    AssertTrue(not ValidateScalarParams(Obj, BadKey), 'compound param rejected');
    AssertTrue(BadKey = 'a', 'bad param name');
  finally
    Obj.Free;
  end;
end;

begin
  TestMultiStatement;
  TestAllowedKeys;
  TestTimeoutIntegers;
  TestJsonDepth;
  TestScalarParams;
  WriteLn('test_requestvalidation ok');
end.
