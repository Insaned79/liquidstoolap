program test_config;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, lsconfig;

procedure AssertTrue(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
  begin
    WriteLn(StdErr, 'FAIL: ', MessageText);
    Halt(1);
  end;
end;

procedure WriteTextFile(const FileName, Content: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := Content;
    Lines.SaveToFile(FileName);
  finally
    Lines.Free;
  end;
end;

procedure TestDefaults;
var
  Config: TAppConfig;
begin
  SetDefaultConfig(Config);
  AssertTrue(Config.Server.Host = '127.0.0.1', 'default host');
  AssertTrue(Config.Server.Port = 8321, 'default port');
  AssertTrue(Config.Server.BasePath = '/', 'default base path');
  AssertTrue(Config.Auth.Enabled, 'auth enabled by default');
  AssertTrue(Config.Auth.MaxIssuedTokens = 4096, 'default max issued tokens');
  AssertTrue(Config.Server.MaxResultRows = 10000, 'default max result rows');
  AssertTrue(Config.Stoolap.SqlWorkerCount = 0, 'default sql worker count is auto');
  AssertTrue(Config.Stoolap.StartupCheck, 'startup check enabled by default');
end;

procedure TestBasePathNormalization;
begin
  AssertTrue(NormalizeBasePath('') = '/', 'empty base path');
  AssertTrue(NormalizeBasePath('/') = '/', 'root base path');
  AssertTrue(NormalizeBasePath('api/v1') = '/api/v1', 'missing leading slash');
  AssertTrue(NormalizeBasePath('/api/v1/') = '/api/v1', 'trailing slash');
end;

procedure TestLoadConfigValidation;
var
  Config: TAppConfig;
  ErrorMessage: string;
  FileName: string;
begin
  AssertTrue(not LoadConfig('/tmp/liquidstoolap-missing-config.ini', Config, ErrorMessage), 'missing config fails');
  AssertTrue(Pos('config file not found', ErrorMessage) > 0, 'missing config error message');

  FileName := GetTempDir(False) + DirectorySeparator + 'liquidstoolap-config-test.ini';
  WriteTextFile(FileName,
    '[server]' + LineEnding +
    'port = 9001' + LineEnding +
    'base_path = api/v1/' + LineEnding +
    LineEnding +
    '[auth]' + LineEnding +
    'enabled = false' + LineEnding);

  AssertTrue(LoadConfig(FileName, Config, ErrorMessage), 'valid config loads');
  AssertTrue(Config.Server.Port = 9001, 'loaded port');
  AssertTrue(Config.Server.BasePath = '/api/v1', 'loaded base path normalized');
  AssertTrue(Config.Stoolap.SqlWorkerCount = Config.Server.MaxConcurrentRequests, 'auto sql worker count resolves to max concurrent requests');
  AssertTrue(not Config.Auth.Enabled, 'loaded auth disabled');

  WriteTextFile(FileName,
    '[server]' + LineEnding +
    'base_path = /api?x=1' + LineEnding +
    LineEnding +
    '[auth]' + LineEnding +
    'enabled = false' + LineEnding);

  AssertTrue(not LoadConfig(FileName, Config, ErrorMessage), 'query string base path fails');
  AssertTrue(Pos('server.base_path', ErrorMessage) > 0, 'base path error message');

  WriteTextFile(FileName,
    '[server]' + LineEnding +
    'max_concurrent_requests = 0' + LineEnding +
    LineEnding +
    '[auth]' + LineEnding +
    'enabled = false' + LineEnding);

  AssertTrue(not LoadConfig(FileName, Config, ErrorMessage), 'invalid max concurrent fails');
  AssertTrue(Pos('server.max_concurrent_requests', ErrorMessage) > 0, 'max concurrent error message');

  WriteTextFile(FileName,
    '[server]' + LineEnding +
    'max_result_rows = 0' + LineEnding +
    LineEnding +
    '[auth]' + LineEnding +
    'enabled = false' + LineEnding);

  AssertTrue(not LoadConfig(FileName, Config, ErrorMessage), 'invalid max result rows fails');
  AssertTrue(Pos('server.max_result_rows', ErrorMessage) > 0, 'max result rows error message');

  WriteTextFile(FileName,
    '[stoolap]' + LineEnding +
    'busy_timeout_ms = 0' + LineEnding +
    LineEnding +
    '[auth]' + LineEnding +
    'enabled = false' + LineEnding);

  AssertTrue(not LoadConfig(FileName, Config, ErrorMessage), 'invalid busy timeout fails');
  AssertTrue(Pos('stoolap.busy_timeout_ms', ErrorMessage) > 0, 'busy timeout error message');

  WriteTextFile(FileName,
    '[stoolap]' + LineEnding +
    'sql_worker_count = -1' + LineEnding +
    LineEnding +
    '[auth]' + LineEnding +
    'enabled = false' + LineEnding);

  AssertTrue(not LoadConfig(FileName, Config, ErrorMessage), 'invalid sql worker count fails');
  AssertTrue(Pos('stoolap.sql_worker_count', ErrorMessage) > 0, 'sql worker count error message');

  WriteTextFile(FileName,
    '[observability]' + LineEnding +
    'enable_metrics = true' + LineEnding +
    LineEnding +
    '[auth]' + LineEnding +
    'enabled = false' + LineEnding);

  AssertTrue(not LoadConfig(FileName, Config, ErrorMessage), 'metrics enabled fails in v1');
  AssertTrue(Pos('observability.enable_metrics', ErrorMessage) > 0, 'metrics error message');

  WriteTextFile(FileName,
    '[auth]' + LineEnding +
    'max_issued_tokens = 0' + LineEnding);

  AssertTrue(not LoadConfig(FileName, Config, ErrorMessage), 'invalid max issued tokens fails');
  AssertTrue(Pos('auth.max_issued_tokens', ErrorMessage) > 0, 'max issued tokens error message');
  DeleteFile(FileName);
end;

begin
  TestDefaults;
  TestBasePathNormalization;
  TestLoadConfigValidation;
  WriteLn('test_config ok');
end.
