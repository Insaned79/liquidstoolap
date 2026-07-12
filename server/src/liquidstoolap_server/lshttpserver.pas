unit lshttpserver;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpserver, httpdefs, fpjson, jsonparser, lsconfig,
  lsstoolapadapter, lsstoolapffi, lsauth, lsrequestvalidation;

type
  TLiquidStoolapHttpServer = class
  private
    FConfig: TAppConfig;
    FServer: TFPHTTPServer;
    FActiveRequests: Integer;
    FRequestLock: TRTLCriticalSection;
    FAuthLock: TRTLCriticalSection;
    FStartTime: TDateTime;
    FReady: Boolean;
    FShutdownRequested: Boolean;
    FNotReadyReason: string;
    FAdapter: TStoolapAdapter;
    FAuth: TAuthService;
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure WriteJson(var AResponse: TFPHTTPConnectionResponse; const StatusCode: Integer;
      Json: TJSONObject);
    function StatusText(const StatusCode: Integer): string;
    procedure WriteError(var AResponse: TFPHTTPConnectionResponse; const StatusCode: Integer;
      const RequestId, Code, MessageText: string);
    procedure AddCommonHeaders(var AResponse: TFPHTTPConnectionResponse);
    function ApiPath(const Endpoint: string): string;
    procedure WriteSqlLog(const RequestId, Sql: string; ParamsObject: TJSONObject);
    function TryEnterRequest: Boolean;
    procedure LeaveRequest;
    function IsAuthorized(ARequest: TFPHTTPConnectionRequest): Boolean;
    procedure WriteHealth(var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse; const RequestId: string);
    procedure WriteToken(var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse; const RequestId: string);
    procedure WriteSql(var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse; const RequestId: string);
  public
    constructor Create(const Config: TAppConfig);
    destructor Destroy; override;
    procedure Run;
    procedure RequestShutdown;
  end;

function NewRequestId: string;

implementation

uses
  DateUtils, lsversion, lserrors;

function NewRequestId: string;
var
  Id: TGuid;
begin
  if CreateGUID(Id) = 0 then
    Result := GUIDToString(Id)
  else
    Result := IntToStr(DateTimeToUnix(Now)) + '-' + IntToStr(Random(MaxInt));
end;

function JsonEscape(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

constructor TLiquidStoolapHttpServer.Create(const Config: TAppConfig);
begin
  inherited Create;
  FConfig := Config;
  FActiveRequests := 0;
  InitCriticalSection(FRequestLock);
  InitCriticalSection(FAuthLock);
  FStartTime := Now;
  FReady := True;
  FShutdownRequested := False;
  FNotReadyReason := '';
  try
    FAuth := TAuthService.Create(FConfig.Auth);
    if FConfig.Stoolap.SqlWorkerCount = 0 then
      FConfig.Stoolap.SqlWorkerCount := FConfig.Server.MaxConcurrentRequests;
    FAdapter := TStoolapAdapter.Create(FConfig.Stoolap);
    if FConfig.Stoolap.StartupCheck then
      FAdapter.StartupCheck;
  except
    on E: Exception do
    begin
      FReady := False;
      FNotReadyReason := E.Message;
    end;
  end;
  FServer := TFPHTTPServer.Create(nil);
  FServer.ServerBanner := 'Liquid Stoolap';
  FServer.Threaded := FConfig.Server.MaxConcurrentRequests > 1;
  FServer.HostName := FConfig.Server.Host;
  FServer.Port := FConfig.Server.Port;
  FServer.OnRequest := @HandleRequest;
end;

destructor TLiquidStoolapHttpServer.Destroy;
begin
  FAuth.Free;
  FAdapter.Free;
  FServer.Free;
  DoneCriticalSection(FAuthLock);
  DoneCriticalSection(FRequestLock);
  inherited Destroy;
end;

procedure TLiquidStoolapHttpServer.Run;
begin
  WriteLn('Liquid Stoolap listening on http://', FConfig.Server.Host, ':', FConfig.Server.Port);
  FServer.Active := True;
end;

procedure TLiquidStoolapHttpServer.RequestShutdown;
begin
  FShutdownRequested := True;
  FReady := False;
  FNotReadyReason := 'shutting down';
  if FServer <> nil then
    FServer.Active := False;
end;

function TLiquidStoolapHttpServer.StatusText(const StatusCode: Integer): string;
begin
  case StatusCode of
    200: Result := 'OK';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    422: Result := 'Unprocessable Content';
    500: Result := 'Internal Server Error';
    503: Result := 'Service Unavailable';
    504: Result := 'Gateway Timeout';
  else
    Result := 'OK';
  end;
end;

procedure TLiquidStoolapHttpServer.WriteJson(var AResponse: TFPHTTPConnectionResponse;
  const StatusCode: Integer; Json: TJSONObject);
begin
  try
    AddCommonHeaders(AResponse);
    AResponse.Code := StatusCode;
    AResponse.CodeText := StatusText(StatusCode);
    AResponse.ContentType := 'application/json; charset=utf-8';
    AResponse.Content := Json.AsJSON;
  finally
    Json.Free;
  end;
end;

procedure TLiquidStoolapHttpServer.AddCommonHeaders(var AResponse: TFPHTTPConnectionResponse);
begin
  if FConfig.Server.CorsEnabled then
    AResponse.SetCustomHeader('Access-Control-Allow-Origin', FConfig.Server.CorsAllowOrigin);
end;

function TLiquidStoolapHttpServer.ApiPath(const Endpoint: string): string;
begin
  if FConfig.Server.BasePath = '/' then
    Result := Endpoint
  else
    Result := FConfig.Server.BasePath + Endpoint;
end;

procedure TLiquidStoolapHttpServer.WriteSqlLog(const RequestId, Sql: string; ParamsObject: TJSONObject);
var
  ParamsJson: string;
begin
  if not FConfig.Logging.SqlLog then
    Exit;

  if ParamsObject = nil then
    ParamsJson := '{}'
  else if FConfig.Logging.RedactSqlParams then
    ParamsJson := '"[redacted]"'
  else
    ParamsJson := ParamsObject.AsJSON;

  WriteLn(
    '{"level":"INFO","message":"sql","request_id":"' + JsonEscape(RequestId) +
    '","sql":"' + JsonEscape(Sql) +
    '","params":' + ParamsJson + '}'
  );
end;

function TLiquidStoolapHttpServer.TryEnterRequest: Boolean;
begin
  EnterCriticalSection(FRequestLock);
  try
    Result := FActiveRequests < FConfig.Server.MaxConcurrentRequests;
    if Result then
      Inc(FActiveRequests);
  finally
    LeaveCriticalSection(FRequestLock);
  end;
end;

procedure TLiquidStoolapHttpServer.LeaveRequest;
begin
  EnterCriticalSection(FRequestLock);
  try
    if FActiveRequests > 0 then
      Dec(FActiveRequests);
  finally
    LeaveCriticalSection(FRequestLock);
  end;
end;

function TLiquidStoolapHttpServer.IsAuthorized(ARequest: TFPHTTPConnectionRequest): Boolean;
begin
  EnterCriticalSection(FAuthLock);
  try
    Result := (FAuth = nil) or (not FAuth.Enabled) or FAuth.ValidateBearer(ARequest.Authorization);
  finally
    LeaveCriticalSection(FAuthLock);
  end;
end;

procedure TLiquidStoolapHttpServer.WriteError(var AResponse: TFPHTTPConnectionResponse;
  const StatusCode: Integer; const RequestId, Code, MessageText: string);
begin
  WriteJson(AResponse, StatusCode, ErrorResponseJson(RequestId, Code, MessageText));
end;

procedure TLiquidStoolapHttpServer.WriteHealth(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse; const RequestId: string);
var
  Json: TJSONObject;
  StatusCode: Integer;
begin
  if FConfig.Server.HealthRequiresAuth and (not IsAuthorized(ARequest)) then
  begin
    AResponse.SetCustomHeader('WWW-Authenticate', 'Bearer error="invalid_token"');
    WriteError(AResponse, 401, RequestId, ERR_INVALID_TOKEN, 'missing or invalid bearer token');
    Exit;
  end;

  Json := TJSONObject.Create;
  Json.Add('ok', FReady);
  if FReady then
    Json.Add('status', 'ok')
  else
    Json.Add('status', 'degraded');
  Json.Add('request_id', RequestId);
  Json.Add('version', LIQUID_STOOLAP_VERSION);
  Json.Add('uptime_s', SecondsBetween(Now, FStartTime));
  Json.Add('ready', FReady);
  Json.Add('auth_enabled', FConfig.Auth.Enabled);
  if not FReady then
    Json.Add('reason', FNotReadyReason);

  if FReady then
    StatusCode := 200
  else
    StatusCode := 503;
  WriteJson(AResponse, StatusCode, Json);
end;

procedure TLiquidStoolapHttpServer.WriteToken(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse; const RequestId: string);
var
  Body: TJSONData;
  BodyObject: TJSONObject;
  Username: string;
  Password: string;
  Token: string;
  ExpiresIn: Integer;
  ResponseObject: TJSONObject;
  TokenObject: TJSONObject;
  BadKey: string;
  UsernameData: TJSONData;
  PasswordData: TJSONData;
begin
  if FAuth = nil then
  begin
    WriteError(AResponse, 503, RequestId, ERR_BACKEND_UNAVAILABLE, FNotReadyReason);
    Exit;
  end;

  if ARequest.Content = '' then
  begin
    WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'request body is required');
    Exit;
  end;

  if Length(ARequest.Content) > FConfig.Server.RequestBodyLimitBytes then
  begin
    WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'request body exceeds configured limit');
    Exit;
  end;

  try
    Body := GetJSON(ARequest.Content);
  except
    WriteError(AResponse, 400, RequestId, ERR_INVALID_JSON, 'invalid JSON body');
    Exit;
  end;

  try
    if Body.JSONType <> jtObject then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'request body must be an object');
      Exit;
    end;
    BodyObject := TJSONObject(Body);
    if not HasOnlyKeys(BodyObject, ['username', 'password'], BadKey) then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'unknown field: ' + BadKey);
      Exit;
    end;

    UsernameData := BodyObject.Find('username');
    PasswordData := BodyObject.Find('password');
    if (UsernameData = nil) or (PasswordData = nil) then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'username and password are required');
      Exit;
    end;
    if (UsernameData.JSONType <> jtString) or (PasswordData.JSONType <> jtString) then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'username and password must be strings');
      Exit;
    end;
    Username := UsernameData.AsString;
    Password := PasswordData.AsString;
    if (Username = '') or (Password = '') then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'username and password must not be empty');
      Exit;
    end;

    try
      EnterCriticalSection(FAuthLock);
      try
        if not FAuth.IssueToken(Username, Password, Token, ExpiresIn) then
        begin
          AResponse.SetCustomHeader('WWW-Authenticate', 'Bearer error="invalid_token"');
          WriteError(AResponse, 401, RequestId, ERR_INVALID_TOKEN, 'invalid credentials');
          Exit;
        end;
      finally
        LeaveCriticalSection(FAuthLock);
      end;
    except
      on E: EAuthError do
      begin
        WriteError(AResponse, 403, RequestId, ERR_AUTH_DISABLED, E.Message);
        Exit;
      end;
    end;

    TokenObject := TJSONObject.Create;
    TokenObject.Add('access_token', Token);
    TokenObject.Add('token_type', 'Bearer');
    TokenObject.Add('expires_in', ExpiresIn);

    ResponseObject := TJSONObject.Create;
    ResponseObject.Add('ok', True);
    ResponseObject.Add('request_id', RequestId);
    ResponseObject.Add('token', TokenObject);
    WriteJson(AResponse, 200, ResponseObject);
  finally
    Body.Free;
  end;
end;

procedure TLiquidStoolapHttpServer.WriteSql(var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse; const RequestId: string);
var
  Body: TJSONData;
  BodyObject: TJSONObject;
  Sql: string;
  ParamsData: TJSONData;
  ParamsObject: TJSONObject;
  TimeoutData: TJSONData;
  TimeoutMs: Int64;
  ResultObject: TJSONObject;
  ResponseObject: TJSONObject;
  StartedAt: TDateTime;
  DurationMs: Int64;
  BadKey: string;
  SqlData: TJSONData;
begin
  if not FReady then
  begin
    WriteError(AResponse, 503, RequestId, ERR_BACKEND_UNAVAILABLE, FNotReadyReason);
    Exit;
  end;

  if not IsAuthorized(ARequest) then
  begin
    AResponse.SetCustomHeader('WWW-Authenticate', 'Bearer error="invalid_token"');
    WriteError(AResponse, 401, RequestId, ERR_INVALID_TOKEN, 'missing or invalid bearer token');
    Exit;
  end;

  if ARequest.Content = '' then
  begin
    WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'request body is required');
    Exit;
  end;

  if Length(ARequest.Content) > FConfig.Server.RequestBodyLimitBytes then
  begin
    WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'request body exceeds configured limit');
    Exit;
  end;

  try
    Body := GetJSON(ARequest.Content);
  except
    on E: Exception do
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_JSON, 'invalid JSON body');
      Exit;
    end;
  end;

  try
    if not (Body.JSONType = jtObject) then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'request body must be an object');
      Exit;
    end;

    BodyObject := TJSONObject(Body);
    if not HasOnlyKeys(BodyObject, ['sql', 'params', 'timeout_ms'], BadKey) then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'unknown field: ' + BadKey);
      Exit;
    end;

    SqlData := BodyObject.Find('sql');
    if SqlData = nil then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'sql is required');
      Exit;
    end;
    if SqlData.JSONType <> jtString then
    begin
      WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'sql must be a string');
      Exit;
    end;
    Sql := Trim(SqlData.AsString);
    if Sql = '' then
    begin
      WriteError(AResponse, 422, RequestId, ERR_INVALID_SQL, 'sql must not be empty');
      Exit;
    end;

    if ContainsMultiStatement(Sql) then
    begin
      WriteError(AResponse, 422, RequestId, ERR_MULTI_STATEMENT_NOT_ALLOWED, 'multi-statement SQL is not allowed');
      Exit;
    end;

    ParamsObject := nil;
    ParamsData := BodyObject.Find('params');
    if ParamsData <> nil then
    begin
      if ParamsData.JSONType <> jtObject then
      begin
        WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'params must be an object');
        Exit;
      end;
      ParamsObject := TJSONObject(ParamsData);
      if not ValidateScalarParams(ParamsObject, BadKey) then
      begin
        WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'params.' + BadKey + ' must be a scalar value');
        Exit;
      end;
    end;

    TimeoutData := BodyObject.Find('timeout_ms');
    if FConfig.Stoolap.BusyTimeoutMs > 0 then
      TimeoutMs := FConfig.Stoolap.BusyTimeoutMs
    else
      TimeoutMs := FConfig.Timeouts.RequestTimeoutMs;
    if TimeoutData <> nil then
    begin
      if not IsJsonInteger(TimeoutData) then
      begin
        WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'timeout_ms must be an integer');
        Exit;
      end;
      TimeoutMs := TimeoutData.AsInt64;
      if TimeoutMs < 1 then
      begin
        WriteError(AResponse, 400, RequestId, ERR_INVALID_REQUEST, 'timeout_ms must be >= 1');
        Exit;
      end;
      if TimeoutMs > FConfig.Timeouts.MaxSqlTimeoutMs then
        TimeoutMs := FConfig.Timeouts.MaxSqlTimeoutMs;
    end;

    WriteSqlLog(RequestId, Sql, ParamsObject);

    StartedAt := Now;
    try
      ResultObject := FAdapter.ExecuteJson(Sql, ParamsObject, TimeoutMs);
    except
      on E: EStoolapLibraryError do
      begin
        WriteError(AResponse, 503, RequestId, ERR_BACKEND_UNAVAILABLE, E.Message);
        Exit;
      end;
      on E: EStoolapTimeoutError do
      begin
        WriteError(AResponse, 504, RequestId, ERR_BACKEND_TIMEOUT, E.Message);
        Exit;
      end;
      on E: EStoolapAdapterError do
      begin
        WriteError(AResponse, 422, RequestId, ERR_SQL_ERROR, E.Message);
        Exit;
      end;
      on E: Exception do
      begin
        WriteError(AResponse, 500, RequestId, ERR_INTERNAL_ERROR, E.Message);
        Exit;
      end;
    end;
    DurationMs := MilliSecondsBetween(Now, StartedAt);
    if DurationMs > TimeoutMs then
    begin
      ResultObject.Free;
      WriteError(AResponse, 504, RequestId, ERR_BACKEND_TIMEOUT, 'SQL execution exceeded timeout_ms');
      Exit;
    end;

    ResponseObject := TJSONObject.Create;
    ResponseObject.Add('ok', True);
    ResponseObject.Add('request_id', RequestId);
    ResponseObject.Add('duration_ms', DurationMs);
    ResponseObject.Add('result', ResultObject);
    WriteJson(AResponse, 200, ResponseObject);
  finally
    Body.Free;
  end;
end;

procedure TLiquidStoolapHttpServer.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest; var AResponse: TFPHTTPConnectionResponse);
var
  RequestId: string;
  StartedAt: TDateTime;
  DurationMs: Int64;
  RequestEntered: Boolean;
begin
  RequestEntered := False;
  StartedAt := Now;
  RequestId := ARequest.GetCustomHeader('X-Request-Id');
  if RequestId = '' then
    RequestId := NewRequestId;

  try
    RequestEntered := TryEnterRequest;
    if not RequestEntered then
    begin
      WriteError(AResponse, 503, RequestId, ERR_BACKEND_UNAVAILABLE, 'server concurrency limit reached');
      Exit;
    end;

    if (ARequest.Method = 'GET') and (ARequest.URI = ApiPath('/health')) then
    begin
      WriteHealth(ARequest, AResponse, RequestId);
      Exit;
    end;

    if ARequest.Method = 'OPTIONS' then
    begin
      AddCommonHeaders(AResponse);
      AResponse.SetCustomHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, X-Request-Id');
      AResponse.SetCustomHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      AResponse.Code := 200;
      AResponse.CodeText := 'OK';
      Exit;
    end;

    if (ARequest.Method = 'POST') and (ARequest.URI = ApiPath('/auth/token')) then
    begin
      WriteToken(ARequest, AResponse, RequestId);
      Exit;
    end;

    if (ARequest.Method = 'POST') and (ARequest.URI = ApiPath('/sql')) then
    begin
      WriteSql(ARequest, AResponse, RequestId);
      Exit;
    end;

    WriteError(AResponse, 404, RequestId, ERR_INVALID_REQUEST, 'endpoint not found');
  finally
    if FConfig.Logging.AccessLog then
    begin
      DurationMs := MilliSecondsBetween(Now, StartedAt);
      WriteLn(
        '{"level":"INFO","message":"access","request_id":"' + JsonEscape(RequestId) +
        '","method":"' + JsonEscape(ARequest.Method) +
        '","path":"' + JsonEscape(ARequest.URI) +
        '","status_code":' + IntToStr(AResponse.Code) +
        ',"duration_ms":' + IntToStr(DurationMs) + '}'
      );
    end;
    if FShutdownRequested and (FServer <> nil) then
      FServer.Active := False;
    if RequestEntered then
      LeaveRequest;
  end;
end;

end.
