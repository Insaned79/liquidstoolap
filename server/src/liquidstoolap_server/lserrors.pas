unit lserrors;

{$mode objfpc}{$H+}

interface

uses
  fpjson;

const
  ERR_INVALID_JSON = 'invalid_json';
  ERR_INVALID_REQUEST = 'invalid_request';
  ERR_INVALID_SQL = 'invalid_sql';
  ERR_MULTI_STATEMENT_NOT_ALLOWED = 'multi_statement_not_allowed';
  ERR_INVALID_TOKEN = 'invalid_token';
  ERR_INSUFFICIENT_SCOPE = 'insufficient_scope';
  ERR_AUTH_DISABLED = 'auth_disabled';
  ERR_SQL_ERROR = 'sql_error';
  ERR_BACKEND_UNAVAILABLE = 'backend_unavailable';
  ERR_BACKEND_TIMEOUT = 'backend_timeout';
  ERR_INTERNAL_ERROR = 'internal_error';

function ErrorCategory(const Code: string): string;
function ErrorRetryable(const Code: string): Boolean;
function ErrorResponseJson(const RequestId, Code, MessageText: string): TJSONObject;

implementation

function ErrorCategory(const Code: string): string;
begin
  if (Code = ERR_INVALID_TOKEN) or (Code = ERR_INSUFFICIENT_SCOPE) or (Code = ERR_AUTH_DISABLED) then
    Exit('auth');
  if (Code = ERR_SQL_ERROR) then
    Exit('sql');
  if (Code = ERR_BACKEND_UNAVAILABLE) or (Code = ERR_BACKEND_TIMEOUT) then
    Exit('backend');
  if Code = ERR_INTERNAL_ERROR then
    Exit('internal');
  Result := 'request';
end;

function ErrorRetryable(const Code: string): Boolean;
begin
  Result := (Code = ERR_BACKEND_UNAVAILABLE) or (Code = ERR_BACKEND_TIMEOUT) or (Code = ERR_INTERNAL_ERROR);
end;

function ErrorResponseJson(const RequestId, Code, MessageText: string): TJSONObject;
var
  ErrorObject: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('ok', False);
  Result.Add('request_id', RequestId);

  ErrorObject := TJSONObject.Create;
  ErrorObject.Add('code', Code);
  ErrorObject.Add('category', ErrorCategory(Code));
  ErrorObject.Add('message', MessageText);
  ErrorObject.Add('retryable', ErrorRetryable(Code));

  Result.Add('error', ErrorObject);
end;

end.
