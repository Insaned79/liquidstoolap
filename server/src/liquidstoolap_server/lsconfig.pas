unit lsconfig;

{$mode objfpc}{$H+}

interface

type
  TServerConfig = record
    Host: string;
    Port: Integer;
    BasePath: string;
    RequestBodyLimitBytes: Integer;
    MaxConcurrentRequests: Integer;
    CorsEnabled: Boolean;
    CorsAllowOrigin: string;
    HealthRequiresAuth: Boolean;
  end;

  TAuthConfig = record
    Enabled: Boolean;
    IssueTokens: Boolean;
    Username: string;
    PasswordFile: string;
    TokenTtlSeconds: Integer;
    AllowStaticTokens: Boolean;
    StaticTokensFile: string;
    TokenRevokeOnRestart: Boolean;
  end;

  TStoolapConfig = record
    LibraryPath: string;
    DatabasePath: string;
    ReadOnly: Boolean;
    BusyTimeoutMs: Integer;
    StartupCheck: Boolean;
  end;

  TTimeoutsConfig = record
    RequestTimeoutMs: Integer;
    MaxSqlTimeoutMs: Integer;
    ShutdownGraceMs: Integer;
  end;

  TLoggingConfig = record
    Level: string;
    Format: string;
    AccessLog: Boolean;
    SqlLog: Boolean;
    RedactSqlParams: Boolean;
    IncludeRequestId: Boolean;
  end;

  TObservabilityConfig = record
    EnableMetrics: Boolean;
    MetricsBindHost: string;
    MetricsPort: Integer;
  end;

  TCliConfig = record
    DefaultOutput: string;
  end;

  TAppConfig = record
    Server: TServerConfig;
    Auth: TAuthConfig;
    Stoolap: TStoolapConfig;
    Timeouts: TTimeoutsConfig;
    Logging: TLoggingConfig;
    Observability: TObservabilityConfig;
    Cli: TCliConfig;
  end;

procedure SetDefaultConfig(out Config: TAppConfig);
function LoadConfig(const FileName: string; out Config: TAppConfig; out ErrorMessage: string): Boolean;
function NormalizeBasePath(const Value: string): string;

implementation

uses
  SysUtils, IniFiles;

function ReadBoolText(Ini: TIniFile; const Section, Key: string; const DefaultValue: Boolean): Boolean;
var
  Raw: string;
begin
  if DefaultValue then
    Raw := 'true'
  else
    Raw := 'false';
  Raw := LowerCase(Trim(Ini.ReadString(Section, Key, Raw)));

  if (Raw = 'true') or (Raw = 'yes') or (Raw = '1') or (Raw = 'on') then
    Exit(True);
  if (Raw = 'false') or (Raw = 'no') or (Raw = '0') or (Raw = 'off') then
    Exit(False);

  raise EConvertError.Create('invalid boolean value for ' + Section + '.' + Key + ': ' + Raw);
end;

procedure SetDefaultConfig(out Config: TAppConfig);
begin
  Config.Server.Host := '127.0.0.1';
  Config.Server.Port := 8321;
  Config.Server.BasePath := '/';
  Config.Server.RequestBodyLimitBytes := 1048576;
  Config.Server.MaxConcurrentRequests := 32;
  Config.Server.CorsEnabled := False;
  Config.Server.CorsAllowOrigin := '*';
  Config.Server.HealthRequiresAuth := False;
  Config.Auth.Enabled := True;
  Config.Auth.IssueTokens := True;
  Config.Auth.Username := 'admin';
  Config.Auth.PasswordFile := '';
  Config.Auth.TokenTtlSeconds := 3600;
  Config.Auth.AllowStaticTokens := False;
  Config.Auth.StaticTokensFile := '';
  Config.Auth.TokenRevokeOnRestart := True;
  Config.Stoolap.LibraryPath := './.cargo-target/release/libstoolap.so';
  Config.Stoolap.DatabasePath := './data/stoolap.db';
  Config.Stoolap.ReadOnly := False;
  Config.Stoolap.BusyTimeoutMs := 5000;
  Config.Stoolap.StartupCheck := True;
  Config.Timeouts.RequestTimeoutMs := 30000;
  Config.Timeouts.MaxSqlTimeoutMs := 60000;
  Config.Timeouts.ShutdownGraceMs := 15000;
  Config.Logging.Level := 'INFO';
  Config.Logging.Format := 'json';
  Config.Logging.AccessLog := True;
  Config.Logging.SqlLog := False;
  Config.Logging.RedactSqlParams := True;
  Config.Logging.IncludeRequestId := True;
  Config.Observability.EnableMetrics := False;
  Config.Observability.MetricsBindHost := '127.0.0.1';
  Config.Observability.MetricsPort := 9095;
  Config.Cli.DefaultOutput := 'json';
end;

function NormalizeBasePath(const Value: string): string;
begin
  Result := Trim(Value);
  if Result = '' then
    Result := '/';
  if Result[1] <> '/' then
    Result := '/' + Result;
  while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

function LoadConfig(const FileName: string; out Config: TAppConfig; out ErrorMessage: string): Boolean;
var
  Ini: TIniFile;
begin
  SetDefaultConfig(Config);
  ErrorMessage := '';
  Result := True;

  if FileName = '' then
    Exit;

  if not FileExists(FileName) then
  begin
    ErrorMessage := 'config file not found: ' + FileName;
    Exit(False);
  end;

  Ini := TIniFile.Create(FileName);
  try
    try
      Config.Server.Host := Ini.ReadString('server', 'host', Config.Server.Host);
      Config.Server.Port := Ini.ReadInteger('server', 'port', Config.Server.Port);
      Config.Server.BasePath := NormalizeBasePath(Ini.ReadString('server', 'base_path', Config.Server.BasePath));
      Config.Server.RequestBodyLimitBytes := Ini.ReadInteger('server', 'request_body_limit_bytes', Config.Server.RequestBodyLimitBytes);
      Config.Server.MaxConcurrentRequests := Ini.ReadInteger('server', 'max_concurrent_requests', Config.Server.MaxConcurrentRequests);
      Config.Server.CorsEnabled := ReadBoolText(Ini, 'server', 'cors_enabled', Config.Server.CorsEnabled);
      Config.Server.CorsAllowOrigin := Ini.ReadString('server', 'cors_allow_origin', Config.Server.CorsAllowOrigin);
      Config.Server.HealthRequiresAuth := ReadBoolText(Ini, 'server', 'health_requires_auth', Config.Server.HealthRequiresAuth);
      Config.Auth.Enabled := ReadBoolText(Ini, 'auth', 'enabled', Config.Auth.Enabled);
      Config.Auth.IssueTokens := ReadBoolText(Ini, 'auth', 'issue_tokens', Config.Auth.IssueTokens);
      Config.Auth.Username := Ini.ReadString('auth', 'username', Config.Auth.Username);
      Config.Auth.PasswordFile := Ini.ReadString('auth', 'password_file', Config.Auth.PasswordFile);
      Config.Auth.TokenTtlSeconds := Ini.ReadInteger('auth', 'token_ttl_seconds', Config.Auth.TokenTtlSeconds);
      Config.Auth.AllowStaticTokens := ReadBoolText(Ini, 'auth', 'allow_static_tokens', Config.Auth.AllowStaticTokens);
      Config.Auth.StaticTokensFile := Ini.ReadString('auth', 'static_tokens_file', Config.Auth.StaticTokensFile);
      Config.Auth.TokenRevokeOnRestart := ReadBoolText(Ini, 'auth', 'token_revoke_on_restart', Config.Auth.TokenRevokeOnRestart);
      Config.Stoolap.LibraryPath := Ini.ReadString('stoolap', 'library_path', Config.Stoolap.LibraryPath);
      Config.Stoolap.DatabasePath := Ini.ReadString('stoolap', 'database_path', Config.Stoolap.DatabasePath);
      Config.Stoolap.ReadOnly := ReadBoolText(Ini, 'stoolap', 'read_only', Config.Stoolap.ReadOnly);
      Config.Stoolap.BusyTimeoutMs := Ini.ReadInteger('stoolap', 'busy_timeout_ms', Config.Stoolap.BusyTimeoutMs);
      Config.Stoolap.StartupCheck := ReadBoolText(Ini, 'stoolap', 'startup_check', Config.Stoolap.StartupCheck);
      Config.Timeouts.RequestTimeoutMs := Ini.ReadInteger('timeouts', 'request_timeout_ms', Config.Timeouts.RequestTimeoutMs);
      Config.Timeouts.MaxSqlTimeoutMs := Ini.ReadInteger('timeouts', 'max_sql_timeout_ms', Config.Timeouts.MaxSqlTimeoutMs);
      Config.Timeouts.ShutdownGraceMs := Ini.ReadInteger('timeouts', 'shutdown_grace_ms', Config.Timeouts.ShutdownGraceMs);
      Config.Logging.Level := Ini.ReadString('logging', 'level', Config.Logging.Level);
      Config.Logging.Format := Ini.ReadString('logging', 'format', Config.Logging.Format);
      Config.Logging.AccessLog := ReadBoolText(Ini, 'logging', 'access_log', Config.Logging.AccessLog);
      Config.Logging.SqlLog := ReadBoolText(Ini, 'logging', 'sql_log', Config.Logging.SqlLog);
      Config.Logging.RedactSqlParams := ReadBoolText(Ini, 'logging', 'redact_sql_params', Config.Logging.RedactSqlParams);
      Config.Logging.IncludeRequestId := ReadBoolText(Ini, 'logging', 'include_request_id', Config.Logging.IncludeRequestId);
      Config.Observability.EnableMetrics := ReadBoolText(Ini, 'observability', 'enable_metrics', Config.Observability.EnableMetrics);
      Config.Observability.MetricsBindHost := Ini.ReadString('observability', 'metrics_bind_host', Config.Observability.MetricsBindHost);
      Config.Observability.MetricsPort := Ini.ReadInteger('observability', 'metrics_port', Config.Observability.MetricsPort);
      Config.Cli.DefaultOutput := Ini.ReadString('cli', 'default_output', Config.Cli.DefaultOutput);
    except
      on E: Exception do
      begin
        ErrorMessage := E.Message;
        Exit(False);
      end;
    end;
  finally
    Ini.Free;
  end;

  if Config.Server.Port <= 0 then
  begin
    ErrorMessage := 'server.port must be positive';
    Exit(False);
  end;

  if Config.Server.RequestBodyLimitBytes <= 0 then
  begin
    ErrorMessage := 'server.request_body_limit_bytes must be positive';
    Exit(False);
  end;

  if Config.Server.MaxConcurrentRequests <= 0 then
  begin
    ErrorMessage := 'server.max_concurrent_requests must be positive';
    Exit(False);
  end;

  if Pos('?', Config.Server.BasePath) > 0 then
  begin
    ErrorMessage := 'server.base_path must be a path, not a URL or query string';
    Exit(False);
  end;

  if Pos('#', Config.Server.BasePath) > 0 then
  begin
    ErrorMessage := 'server.base_path must be a path, not a URL fragment';
    Exit(False);
  end;

  if Config.Timeouts.MaxSqlTimeoutMs <= 0 then
  begin
    ErrorMessage := 'timeouts.max_sql_timeout_ms must be positive';
    Exit(False);
  end;

  if Config.Stoolap.BusyTimeoutMs <= 0 then
  begin
    ErrorMessage := 'stoolap.busy_timeout_ms must be positive';
    Exit(False);
  end;

  if Config.Timeouts.RequestTimeoutMs <= 0 then
  begin
    ErrorMessage := 'timeouts.request_timeout_ms must be positive';
    Exit(False);
  end;

  if Config.Auth.TokenTtlSeconds <= 0 then
  begin
    ErrorMessage := 'auth.token_ttl_seconds must be positive';
    Exit(False);
  end;

  if Config.Observability.EnableMetrics then
  begin
    ErrorMessage := 'observability.enable_metrics is reserved for post-1.0 and must be false';
    Exit(False);
  end;

  if Config.Auth.Enabled and (Config.Auth.PasswordFile = '') and
    (not (Config.Auth.AllowStaticTokens and (Config.Auth.StaticTokensFile <> ''))) then
  begin
    ErrorMessage := 'auth.password_file or auth.static_tokens_file is required when auth.enabled = true';
    Exit(False);
  end;

  if Config.Auth.AllowStaticTokens and (Config.Auth.StaticTokensFile = '') then
  begin
    ErrorMessage := 'auth.static_tokens_file is required when auth.allow_static_tokens = true';
    Exit(False);
  end;
end;

end.
