program liquidstoolap_server;

{$mode objfpc}{$H+}

uses
  cthreads, cwstring, SysUtils, Classes, BaseUnix, DynLibs, ctypes, termio,
  fphttpclient, fpjson, jsonparser, lsconfig, lshttpserver, lsversion;

var
  ShutdownRequested: Boolean = False;

type
  TReadlineFunc = function(Prompt: PChar): PChar; cdecl;
  TAddHistoryFunc = procedure(Line: PChar); cdecl;
  TReadHistoryFunc = function(FileName: PChar): cint; cdecl;
  TWriteHistoryFunc = function(FileName: PChar): cint; cdecl;

var
  ReadlineHandle: TLibHandle = NilHandle;
  ReadlineFunc: TReadlineFunc = nil;
  AddHistoryFunc: TAddHistoryFunc = nil;
  ReadHistoryFunc: TReadHistoryFunc = nil;
  WriteHistoryFunc: TWriteHistoryFunc = nil;

function IsATTY(Fd: cint): cint; cdecl; external 'c' name 'isatty';
procedure CFree(P: Pointer); cdecl; external 'c' name 'free';

procedure ConfigureTextEncoding;
begin
  DefaultSystemCodePage := CP_UTF8;
  DefaultFileSystemCodePage := CP_UTF8;
  SetMultiByteConversionCodePage(CP_UTF8);
end;

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
  WriteLn('  liquidstoolap connect --url URL (--token TOKEN | --username USER [--password-file PATH])');
  WriteLn('  liquidstoolap connect --url URL --token TOKEN -e SQL [--format table|json]');
end;

function ArgValue(const Name: string; const DefaultValue: string): string;
var
  I: Integer;
begin
  Result := DefaultValue;
  for I := 1 to ParamCount - 1 do
    if (ParamStr(I) = Name) and (I < ParamCount) then
      Exit(ParamStr(I + 1));
end;

function FirstArgValue(const Name1, Name2, DefaultValue: string): string;
begin
  Result := ArgValue(Name1, '');
  if Result = '' then
    Result := ArgValue(Name2, '');
  if Result = '' then
    Result := DefaultValue;
end;

function IsTerminalInput: Boolean;
begin
  Result := IsATTY(0) <> 0;
end;

function HistoryFileName: string;
var
  Home: string;
begin
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Exit('');
  Result := IncludeTrailingPathDelimiter(Home) + '.liquidstoolap_history';
end;

procedure InitReadline;
begin
  if ReadlineHandle <> NilHandle then
    Exit;
  ReadlineHandle := LoadLibrary('libreadline.so.8');
  if ReadlineHandle = NilHandle then
    ReadlineHandle := LoadLibrary('libreadline.so');
  if ReadlineHandle = NilHandle then
    Exit;

  Pointer(ReadlineFunc) := GetProcedureAddress(ReadlineHandle, 'readline');
  Pointer(AddHistoryFunc) := GetProcedureAddress(ReadlineHandle, 'add_history');
  Pointer(ReadHistoryFunc) := GetProcedureAddress(ReadlineHandle, 'read_history');
  Pointer(WriteHistoryFunc) := GetProcedureAddress(ReadlineHandle, 'write_history');
  if not Assigned(ReadlineFunc) then
  begin
    UnloadLibrary(ReadlineHandle);
    ReadlineHandle := NilHandle;
  end;
end;

procedure LoadShellHistory;
var
  FileName: RawByteString;
begin
  if Assigned(ReadHistoryFunc) and (HistoryFileName <> '') then
  begin
    FileName := RawByteString(HistoryFileName);
    ReadHistoryFunc(PChar(FileName));
  end;
end;

procedure SaveShellHistory;
var
  FileName: RawByteString;
begin
  if Assigned(WriteHistoryFunc) and (HistoryFileName <> '') then
  begin
    FileName := RawByteString(HistoryFileName);
    WriteHistoryFunc(PChar(FileName));
  end;
end;

function ReadShellLine(const Prompt: string; out Line: string): Boolean;
var
  PromptBytes: RawByteString;
  LinePtr: PChar;
begin
  if IsTerminalInput and Assigned(ReadlineFunc) then
  begin
    PromptBytes := RawByteString(Prompt);
    LinePtr := ReadlineFunc(PChar(PromptBytes));
    if LinePtr = nil then
      Exit(False);
    try
      Line := string(LinePtr);
    finally
      CFree(LinePtr);
    end;
    if (Trim(Line) <> '') and Assigned(AddHistoryFunc) then
      AddHistoryFunc(PChar(RawByteString(Line)));
    Exit(True);
  end;

  Write(Prompt);
  if EOF(Input) then
    Exit(False);
  ReadLn(Line);
  Result := True;
end;

function ReadPasswordFromTerminal(const Prompt: string): string;
var
  OldTerm: Termios;
  NewTerm: Termios;
  HasTerm: Boolean;
begin
  Write(Prompt);
  HasTerm := IsTerminalInput and (TCGetAttr(0, OldTerm) = 0);
  if HasTerm then
  begin
    NewTerm := OldTerm;
    NewTerm.c_lflag := NewTerm.c_lflag and not ECHO;
    TCSetAttr(0, TCSANOW, NewTerm);
  end;
  try
    ReadLn(Result);
  finally
    if HasTerm then
    begin
      TCSetAttr(0, TCSANOW, OldTerm);
      WriteLn;
    end;
  end;
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

function HttpPostJson(const Url, Payload, Token: string; out StatusCode: Integer): string;
var
  Client: TFPHTTPClient;
  Request: TStringStream;
begin
  Client := TFPHTTPClient.Create(nil);
  Request := TStringStream.Create(Payload);
  try
    Client.AddHeader('Content-Type', 'application/json');
    if Token <> '' then
      Client.AddHeader('Authorization', 'Bearer ' + Token);
    Client.RequestBody := Request;
    try
      Result := Client.Post(Url);
    except
      on E: EHTTPClient do
        Result := E.Message;
      on E: Exception do
        raise;
    end;
    StatusCode := Client.ResponseStatusCode;
  finally
    Client.RequestBody := nil;
    Request.Free;
    Client.Free;
  end;
end;

function IssueToken(const Url, Username, PasswordFile: string): string;
var
  StatusCode: Integer;
  Body: string;
  Data: TJSONData;
  Password: string;
begin
  if PasswordFile <> '' then
    Password := ReadFirstLine(PasswordFile)
  else
    Password := ReadPasswordFromTerminal('Password: ');

  Body := HttpPostJson(
    Url + '/auth/token',
    '{"username":' + JsonString(Username) + ',"password":' + JsonString(Password) + '}',
    '',
    StatusCode
  );
  if StatusCode >= 400 then
    raise Exception.Create('auth failed: ' + Body);

  Data := GetJSON(Body);
  try
    Result := TJSONObject(Data).Objects['token'].Get('access_token', '');
  finally
    Data.Free;
  end;
  if Result = '' then
    raise Exception.Create('auth response did not include access_token');
end;

function CliAuthToken(const Url: string): string;
var
  Username: string;
begin
  Result := ArgValue('--token', '');
  if Result <> '' then
    Exit;
  Username := ArgValue('--username', 'admin');
  Result := IssueToken(Url, Username, ArgValue('--password-file', ''));
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

function BuildParamsJson: string; forward;

function SqlPayload(const Sql: string): string;
begin
  Result := '{"sql":' + JsonString(Sql) + BuildParamsJson + '}';
end;

function TrimTrailingSemicolon(const Sql: string): string;
begin
  Result := Trim(Sql);
  if (Result <> '') and (Result[Length(Result)] = ';') then
    Delete(Result, Length(Result), 1);
  Result := Trim(Result);
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
  Payload := SqlPayload(Sql);

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

function JsonValueToText(Value: TJSONData): string;
begin
  if Value = nil then
    Exit('NULL');
  case Value.JSONType of
    jtNull: Result := 'NULL';
    jtBoolean:
      if Value.AsBoolean then
        Result := 'true'
      else
        Result := 'false';
    jtNumber: Result := Value.AsJSON;
    jtString: Result := Value.AsString;
  else
    Result := Value.AsJSON;
  end;
end;

function RepeatChar(const Ch: Char; Count: Integer): string;
begin
  if Count <= 0 then
    Exit('');
  SetLength(Result, Count);
  FillChar(Result[1], Count, Ord(Ch));
end;

procedure PrintTableSeparator(const Widths: array of Integer);
var
  I: Integer;
begin
  Write('+');
  for I := 0 to High(Widths) do
    Write(RepeatChar('-', Widths[I] + 2), '+');
  WriteLn;
end;

procedure PrintTableRow(const Values: array of string; const Widths: array of Integer);
var
  I: Integer;
begin
  Write('|');
  for I := 0 to High(Widths) do
    Write(' ', Values[I], RepeatChar(' ', Widths[I] - Length(Values[I]) + 1), '|');
  WriteLn;
end;

procedure PrintSqlTable(const Body: string);
var
  Data: TJSONData;
  ResultObj: TJSONObject;
  Kind: string;
  Columns: TJSONArray;
  Rows: TJSONArray;
  RowValues: TJSONArray;
  Widths: array of Integer;
  Header: array of string;
  RowText: array of string;
  I: Integer;
  R: Integer;
  AffectedRows: Int64;
begin
  Data := GetJSON(Body);
  try
    if not TJSONObject(Data).Get('ok', False) then
    begin
      WriteLn(Body);
      Exit;
    end;

    ResultObj := TJSONObject(Data).Objects['result'];
    Kind := ResultObj.Get('kind', '');
    if Kind = 'command' then
    begin
      AffectedRows := ResultObj.Get('affected_rows', Int64(0));
      WriteLn('Query OK, ', AffectedRows, ' row(s) affected');
      Exit;
    end;

    if Kind <> 'result_set' then
    begin
      WriteLn(Body);
      Exit;
    end;

    Columns := ResultObj.Arrays['columns'];
    Rows := ResultObj.Arrays['rows'];
    SetLength(Widths, Columns.Count);
    SetLength(Header, Columns.Count);
    SetLength(RowText, Columns.Count);

    for I := 0 to Columns.Count - 1 do
    begin
      Header[I] := Columns.Strings[I];
      Widths[I] := Length(Header[I]);
    end;

    for R := 0 to Rows.Count - 1 do
    begin
      RowValues := Rows.Objects[R].Arrays['values'];
      for I := 0 to Columns.Count - 1 do
      begin
        RowText[I] := JsonValueToText(RowValues.Items[I]);
        if Length(RowText[I]) > Widths[I] then
          Widths[I] := Length(RowText[I]);
      end;
    end;

    PrintTableSeparator(Widths);
    PrintTableRow(Header, Widths);
    PrintTableSeparator(Widths);
    for R := 0 to Rows.Count - 1 do
    begin
      RowValues := Rows.Objects[R].Arrays['values'];
      for I := 0 to Columns.Count - 1 do
        RowText[I] := JsonValueToText(RowValues.Items[I]);
      PrintTableRow(RowText, Widths);
    end;
    PrintTableSeparator(Widths);
    WriteLn(Rows.Count, ' row(s)');
  finally
    Data.Free;
  end;
end;

procedure PrintSqlResponse(const Body, OutputFormat: string);
var
  TrimmedBody: string;
begin
  TrimmedBody := Trim(Body);
  if TrimmedBody = '' then
    Exit;
  if TrimmedBody[1] <> '{' then
  begin
    WriteLn(Body);
    Exit;
  end;
  if OutputFormat = 'json' then
    WriteLn(Body)
  else
    PrintSqlTable(Body);
end;

function ExecuteSqlForCli(const Url, Token, Sql, OutputFormat: string): Integer;
var
  StatusCode: Integer;
  Body: string;
begin
  Body := HttpPostJson(Url + '/sql', SqlPayload(TrimTrailingSemicolon(Sql)), Token, StatusCode);
  PrintSqlResponse(Body, OutputFormat);
  if StatusCode >= 500 then
    Exit(4);
  if (StatusCode = 401) or (StatusCode = 403) then
    Exit(3);
  if StatusCode = 422 then
    Exit(5);
  if StatusCode >= 400 then
    Exit(2);
  Result := 0;
end;

procedure PrintShellHelp;
begin
  WriteLn('Commands:');
  WriteLn('  SQL;             execute SQL when a trailing semicolon is entered');
  WriteLn('  .help            show this help');
  WriteLn('  .format table    print result sets as ASCII tables');
  WriteLn('  .format json     print raw JSON responses');
  WriteLn('  .quit, .exit, \q  exit');
end;

procedure CliConnect;
var
  Url: string;
  Token: string;
  ExecuteSql: string;
  OutputFormat: string;
  Line: string;
  SqlBuffer: string;
  ExitCode: Integer;
begin
  Url := ArgValue('--url', 'http://127.0.0.1:8321');
  OutputFormat := ArgValue('--format', 'table');
  if (OutputFormat <> 'table') and (OutputFormat <> 'json') then
  begin
    WriteLn(StdErr, '--format must be table or json');
    Halt(2);
  end;

  try
    Token := CliAuthToken(Url);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(3);
    end;
  end;

  ExecuteSql := FirstArgValue('--execute', '-e', '');
  if ExecuteSql <> '' then
  begin
    Halt(ExecuteSqlForCli(Url, Token, ExecuteSql, OutputFormat));
  end;

  WriteLn('Connected to ', Url);
  WriteLn('Enter SQL terminated by semicolon. Type .help for help.');
  if IsTerminalInput then
  begin
    InitReadline;
    LoadShellHistory;
  end;
  SqlBuffer := '';
  try
    while True do
    begin
      if SqlBuffer = '' then
      begin
        if not ReadShellLine('liquidstoolap> ', Line) then
          Break;
      end
      else
      begin
        if not ReadShellLine('          ...> ', Line) then
          Break;
      end;

      if (SqlBuffer = '') and (Length(Trim(Line)) > 0) and (Trim(Line)[1] = '.') then
      begin
        Line := Trim(Line);
        if (Line = '.quit') or (Line = '.exit') then
          Break;
        if Line = '.help' then
        begin
          PrintShellHelp;
          Continue;
        end;
        if Pos('.format ', Line) = 1 then
        begin
          OutputFormat := Trim(Copy(Line, Length('.format ') + 1, MaxInt));
          if (OutputFormat <> 'table') and (OutputFormat <> 'json') then
            WriteLn('format must be table or json')
          else
            WriteLn('format set to ', OutputFormat);
          Continue;
        end;
        WriteLn('unknown command: ', Line);
        Continue;
      end;

      if (SqlBuffer = '') and (Trim(Line) = '\q') then
        Break;
      if Trim(Line) = '' then
        Continue;

      if SqlBuffer <> '' then
        SqlBuffer := SqlBuffer + LineEnding;
      SqlBuffer := SqlBuffer + Line;

      if (Trim(SqlBuffer) <> '') and (Trim(SqlBuffer)[Length(Trim(SqlBuffer))] = ';') then
      begin
        ExitCode := ExecuteSqlForCli(Url, Token, SqlBuffer, OutputFormat);
        if ExitCode <> 0 then
          WriteLn(StdErr, 'SQL failed with exit code ', ExitCode);
        SqlBuffer := '';
      end;
    end;
  finally
    if IsTerminalInput then
      SaveShellHistory;
    end;
end;

begin
  ConfigureTextEncoding;
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
  else if ParamStr(1) = 'connect' then
    CliConnect
  else
  begin
    WriteLn(StdErr, 'unknown command: ', ParamStr(1));
    PrintHelp;
    Halt(2);
  end;
end.
