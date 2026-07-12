program liquidstoolap_server;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, Classes, BaseUnix, fphttpclient, fpjson, jsonparser, lsconfig, lshttpserver, lsversion;

var
  ShutdownRequested: Boolean = False;

procedure HandleShutdownSignal(Sig: cint); cdecl;
begin
  ShutdownRequested := True;
end;

type
  TServerThread = class(TThread)
  private
    FServer: TLiquidStoolapHttpServer;
  protected
    procedure Execute; override;
  public
    constructor Create(Server: TLiquidStoolapHttpServer);
  end;

constructor TServerThread.Create(Server: TLiquidStoolapHttpServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := Server;
end;

procedure TServerThread.Execute;
begin
  FServer.Run;
end;

procedure WakeServer(const Host: string; const Port: Integer; const BasePath: string);
var
  Client: TFPHTTPClient;
  HealthPath: string;
begin
  if BasePath = '/' then
    HealthPath := '/health'
  else
    HealthPath := BasePath + '/health';
  Client := TFPHTTPClient.Create(nil);
  try
    try
      Client.Get('http://' + Host + ':' + IntToStr(Port) + HealthPath);
    except
      on E: Exception do
        ;
    end;
  finally
    Client.Free;
  end;
end;

procedure PrintHelp;
begin
  WriteLn('Liquid Stoolap server');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  liquidstoolap --help');
  WriteLn('  liquidstoolap --version');
  WriteLn('  liquidstoolap serve [--config PATH]');
  WriteLn('  liquidstoolap check-config --config PATH');
  WriteLn('  liquidstoolap health --url URL');
  WriteLn('  liquidstoolap token --url URL --username USER --password-file PATH');
  WriteLn('  liquidstoolap sql --url URL --token TOKEN --sql SQL [--param name=value]');
end;

function ArgValue(const Name: string; const DefaultValue: string): string;
var
  I: Integer;
begin
  Result := DefaultValue;
  for I := 1 to ParamCount - 1 do
    if ParamStr(I) = Name then
      Exit(ParamStr(I + 1));
end;

procedure Serve;
var
  Config: TAppConfig;
  ErrorMessage: string;
  ConfigPath: string;
  Server: TLiquidStoolapHttpServer;
  ServerThread: TServerThread;
  Deadline: TDateTime;
begin
  ConfigPath := ArgValue('--config', '');
  if not LoadConfig(ConfigPath, Config, ErrorMessage) then
  begin
    WriteLn(StdErr, ErrorMessage);
    Halt(2);
  end;

  Server := TLiquidStoolapHttpServer.Create(Config);
  ServerThread := nil;
  try
    ShutdownRequested := False;
    fpSignal(SIGINT, @HandleShutdownSignal);
    fpSignal(SIGTERM, @HandleShutdownSignal);
    ServerThread := TServerThread.Create(Server);
    ServerThread.Start;
    while (not ShutdownRequested) and (not ServerThread.Finished) do
      Sleep(100);

    if ShutdownRequested then
    begin
      Server.RequestShutdown;
      WakeServer(Config.Server.Host, Config.Server.Port, Config.Server.BasePath);
      Deadline := Now + (Config.Timeouts.ShutdownGraceMs / 86400000);
      while (not ServerThread.Finished) and (Now < Deadline) do
        Sleep(50);
    end;

    if not ServerThread.Finished then
    begin
      WriteLn(StdErr, 'server did not stop before shutdown_grace_ms');
      Halt(4);
    end;
    ServerThread.WaitFor;
  finally
    ServerThread.Free;
    Server.Free;
  end;
end;

procedure CheckConfig;
var
  Config: TAppConfig;
  ErrorMessage: string;
  ConfigPath: string;
begin
  ConfigPath := ArgValue('--config', '');
  if ConfigPath = '' then
  begin
    WriteLn(StdErr, '--config is required');
    Halt(2);
  end;

  if not LoadConfig(ConfigPath, Config, ErrorMessage) then
  begin
    WriteLn(StdErr, ErrorMessage);
    Halt(2);
  end;

  WriteLn('config ok');
end;

function ReadFirstLine(const FileName: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    if Lines.Count = 0 then
      Exit('');
    Result := Trim(Lines[0]);
  finally
    Lines.Free;
  end;
end;

function JsonString(const Value: string): string;
var
  I: Integer;
begin
  Result := '"';
  for I := 1 to Length(Value) do
    case Value[I] of
      '\': Result := Result + '\\';
      '"': Result := Result + '\"';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      Result := Result + Value[I];
    end;
  Result := Result + '"';
end;

function LooksLikeJsonNumber(const Value: string): Boolean;
var
  Parsed: TJSONData;
begin
  Result := False;
  if Trim(Value) <> Value then
    Exit;
  try
    Parsed := GetJSON(Value);
  except
    Exit;
  end;
  try
    Result := Parsed.JSONType = jtNumber;
  finally
    Parsed.Free;
  end;
end;

function CliParamValueJson(const Value: string): string;
var
  Lower: string;
begin
  Lower := LowerCase(Value);
  if (Lower = 'null') or (Lower = 'true') or (Lower = 'false') then
    Exit(Lower);
  if LooksLikeJsonNumber(Value) then
    Exit(Value);
  Result := JsonString(Value);
end;

procedure PrintResponseOrFail(Client: TFPHTTPClient; const Body: string);
begin
  WriteLn(Body);
  if Client.ResponseStatusCode >= 500 then
    Halt(4);
  if Client.ResponseStatusCode = 401 then
    Halt(3);
  if Client.ResponseStatusCode = 403 then
    Halt(3);
  if Client.ResponseStatusCode = 422 then
    Halt(5);
  if Client.ResponseStatusCode >= 400 then
    Halt(2);
end;

procedure CliHealth;
var
  Client: TFPHTTPClient;
  Url: string;
  Body: string;
begin
  Url := ArgValue('--url', 'http://127.0.0.1:8321');
  Client := TFPHTTPClient.Create(nil);
  try
    try
      Body := Client.Get(Url + '/health');
      PrintResponseOrFail(Client, Body);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, E.Message);
        Halt(4);
      end;
    end;
  finally
    Client.Free;
  end;
end;

procedure CliToken;
var
  Client: TFPHTTPClient;
  Url: string;
  Username: string;
  PasswordFile: string;
  Password: string;
  Request: TStringStream;
  Body: string;
begin
  Url := ArgValue('--url', 'http://127.0.0.1:8321');
  Username := ArgValue('--username', 'admin');
  PasswordFile := ArgValue('--password-file', '');
  if PasswordFile = '' then
  begin
    WriteLn(StdErr, '--password-file is required');
    Halt(2);
  end;
  Password := ReadFirstLine(PasswordFile);

  Client := TFPHTTPClient.Create(nil);
  Request := TStringStream.Create('{"username":' + JsonString(Username) + ',"password":' + JsonString(Password) + '}');
  try
    Request.Position := 0;
    Client.AddHeader('Content-Type', 'application/json');
    Client.RequestBody := Request;
    try
      Body := Client.Post(Url + '/auth/token');
      PrintResponseOrFail(Client, Body);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, E.Message);
        Halt(4);
      end;
    end;
  finally
    Client.RequestBody := nil;
    Request.Free;
    Client.Free;
  end;
end;

function BuildParamsJson: string;
var
  I: Integer;
  Raw: string;
  Name: string;
  Value: string;
  P: Integer;
  First: Boolean;
begin
  Result := '';
  First := True;
  for I := 1 to ParamCount - 1 do
  begin
    if ParamStr(I) = '--param' then
    begin
      Raw := ParamStr(I + 1);
      P := Pos('=', Raw);
      if P <= 1 then
        Continue;
      Name := Copy(Raw, 1, P - 1);
      Value := Copy(Raw, P + 1, MaxInt);
      if not First then
        Result := Result + ',';
      Result := Result + JsonString(Name) + ':' + CliParamValueJson(Value);
      First := False;
    end;
  end;
  if Result <> '' then
    Result := ',"params":{' + Result + '}';
end;

procedure CliSql;
var
  Client: TFPHTTPClient;
  Url: string;
  Token: string;
  Sql: string;
  Payload: string;
  Request: TStringStream;
  Body: string;
begin
  Url := ArgValue('--url', 'http://127.0.0.1:8321');
  Token := ArgValue('--token', '');
  Sql := ArgValue('--sql', '');
  if (Token = '') or (Sql = '') then
  begin
    WriteLn(StdErr, '--token and --sql are required');
    Halt(2);
  end;
  Payload := '{"sql":' + JsonString(Sql) + BuildParamsJson + '}';

  Client := TFPHTTPClient.Create(nil);
  Request := TStringStream.Create(Payload);
  try
    Client.AddHeader('Content-Type', 'application/json');
    Client.AddHeader('Authorization', 'Bearer ' + Token);
    Client.RequestBody := Request;
    try
      Body := Client.Post(Url + '/sql');
      PrintResponseOrFail(Client, Body);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, E.Message);
        Halt(4);
      end;
    end;
  finally
    Client.RequestBody := nil;
    Request.Free;
    Client.Free;
  end;
end;

begin
  Randomize;

  if (ParamCount = 0) or (ParamStr(1) = '--help') or (ParamStr(1) = 'help') then
  begin
    PrintHelp;
    Halt(0);
  end;

  if (ParamStr(1) = '--version') or (ParamStr(1) = 'version') then
  begin
    WriteLn(LIQUID_STOOLAP_VERSION);
    Halt(0);
  end;

  if ParamStr(1) = 'serve' then
    Serve
  else if ParamStr(1) = 'check-config' then
    CheckConfig
  else if ParamStr(1) = 'health' then
    CliHealth
  else if ParamStr(1) = 'token' then
    CliToken
  else if ParamStr(1) = 'sql' then
    CliSql
  else
  begin
    WriteLn(StdErr, 'unknown command: ', ParamStr(1));
    PrintHelp;
    Halt(2);
  end;
end.
