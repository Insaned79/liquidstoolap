program test_errors;

{$mode objfpc}{$H+}

uses
  SysUtils, fpjson, lserrors;

procedure AssertTrue(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
  begin
    WriteLn(StdErr, 'FAIL: ', MessageText);
    Halt(1);
  end;
end;

procedure TestCategories;
begin
  AssertTrue(ErrorCategory(ERR_INVALID_TOKEN) = 'auth', 'auth category');
  AssertTrue(ErrorCategory(ERR_SQL_ERROR) = 'sql', 'sql category');
  AssertTrue(ErrorCategory(ERR_BACKEND_TIMEOUT) = 'backend', 'backend category');
  AssertTrue(ErrorCategory(ERR_INTERNAL_ERROR) = 'internal', 'internal category');
  AssertTrue(ErrorCategory(ERR_INVALID_REQUEST) = 'request', 'request category');
end;

procedure TestRetryable;
begin
  AssertTrue(ErrorRetryable(ERR_BACKEND_UNAVAILABLE), 'backend unavailable retryable');
  AssertTrue(ErrorRetryable(ERR_BACKEND_TIMEOUT), 'backend timeout retryable');
  AssertTrue(ErrorRetryable(ERR_INTERNAL_ERROR), 'internal retryable');
  AssertTrue(not ErrorRetryable(ERR_INVALID_SQL), 'invalid sql not retryable');
end;

procedure TestErrorJson;
var
  Json: TJSONObject;
  ErrorObject: TJSONObject;
begin
  Json := ErrorResponseJson('req-1', ERR_SQL_ERROR, 'bad SQL');
  try
    AssertTrue(not Json.Booleans['ok'], 'ok false');
    AssertTrue(Json.Strings['request_id'] = 'req-1', 'request id');
    ErrorObject := Json.Objects['error'];
    AssertTrue(ErrorObject.Strings['code'] = ERR_SQL_ERROR, 'error code');
    AssertTrue(ErrorObject.Strings['category'] = 'sql', 'error category');
    AssertTrue(ErrorObject.Strings['message'] = 'bad SQL', 'error message');
    AssertTrue(not ErrorObject.Booleans['retryable'], 'error retryable');
  finally
    Json.Free;
  end;
end;

begin
  TestCategories;
  TestRetryable;
  TestErrorJson;
  WriteLn('test_errors ok');
end.
