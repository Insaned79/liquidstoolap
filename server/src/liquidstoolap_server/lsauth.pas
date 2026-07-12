unit lsauth;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, lsconfig;

type
  EAuthError = class(Exception);

  TAuthService = class
  private
    FConfig: TAuthConfig;
    FPassword: string;
    FIssuedTokens: TStringList;
    FStaticTokens: TStringList;
    function ReadPasswordFile(const FileName: string): string;
    procedure LoadStaticTokens(const FileName: string);
    procedure AddIssuedToken(const Token: string);
    function IsIssuedTokenValid(const Token: string): Boolean;
  public
    constructor Create(const Config: TAuthConfig);
    destructor Destroy; override;
    function Enabled: Boolean;
    function IssueToken(const Username, Password: string; out Token: string; out ExpiresIn: Integer): Boolean;
    function ValidateBearer(const AuthorizationHeader: string): Boolean;
  end;

implementation

function NewToken: string;
var
  Id: TGuid;
begin
  if CreateGUID(Id) = 0 then
    Result := 'lst_' + StringReplace(StringReplace(GUIDToString(Id), '{', '', []), '}', '', [])
  else
    Result := 'lst_' + IntToStr(Random(MaxInt)) + IntToStr(Random(MaxInt));
end;

constructor TAuthService.Create(const Config: TAuthConfig);
begin
  inherited Create;
  FConfig := Config;
  FIssuedTokens := TStringList.Create;
  FIssuedTokens.Sorted := True;
  FIssuedTokens.Duplicates := dupIgnore;
  FStaticTokens := TStringList.Create;
  FStaticTokens.Sorted := True;
  FStaticTokens.Duplicates := dupIgnore;
  if FConfig.Enabled and (FConfig.PasswordFile <> '') then
    FPassword := ReadPasswordFile(FConfig.PasswordFile);
  if FConfig.Enabled and FConfig.AllowStaticTokens then
    LoadStaticTokens(FConfig.StaticTokensFile);
end;

destructor TAuthService.Destroy;
begin
  FIssuedTokens.Free;
  FStaticTokens.Free;
  inherited Destroy;
end;

function TAuthService.ReadPasswordFile(const FileName: string): string;
var
  List: TStringList;
begin
  if not FileExists(FileName) then
    raise EAuthError.Create('password file not found: ' + FileName);
  List := TStringList.Create;
  try
    List.LoadFromFile(FileName);
    if List.Count = 0 then
      raise EAuthError.Create('password file is empty: ' + FileName);
    Result := Trim(List[0]);
  finally
    List.Free;
  end;
end;

procedure TAuthService.LoadStaticTokens(const FileName: string);
var
  List: TStringList;
  I: Integer;
  Line: string;
begin
  if not FileExists(FileName) then
    raise EAuthError.Create('static tokens file not found: ' + FileName);

  List := TStringList.Create;
  try
    List.LoadFromFile(FileName);
    for I := 0 to List.Count - 1 do
    begin
      Line := Trim(List[I]);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      if Pos('=', Line) > 0 then
        Line := Trim(Copy(Line, 1, Pos('=', Line) - 1));
      if Line <> '' then
        FStaticTokens.Add(Line);
    end;
  finally
    List.Free;
  end;
end;

procedure TAuthService.AddIssuedToken(const Token: string);
var
  ExpiresAt: TDateTime;
begin
  ExpiresAt := Now + (FConfig.TokenTtlSeconds / 86400);
  FIssuedTokens.Values[Token] := FloatToStr(ExpiresAt);
end;

function TAuthService.IsIssuedTokenValid(const Token: string): Boolean;
var
  Raw: string;
  ExpiresAt: TDateTime;
begin
  Raw := FIssuedTokens.Values[Token];
  if Raw = '' then
    Exit(False);

  try
    ExpiresAt := StrToFloat(Raw);
  except
    Exit(False);
  end;

  if Now > ExpiresAt then
  begin
    FIssuedTokens.Delete(FIssuedTokens.IndexOfName(Token));
    Exit(False);
  end;

  Result := True;
end;

function TAuthService.Enabled: Boolean;
begin
  Result := FConfig.Enabled;
end;

function TAuthService.IssueToken(const Username, Password: string; out Token: string;
  out ExpiresIn: Integer): Boolean;
begin
  Token := '';
  ExpiresIn := FConfig.TokenTtlSeconds;
  if (not FConfig.Enabled) or (not FConfig.IssueTokens) then
    raise EAuthError.Create('token issuing is disabled');

  Result := (Username = FConfig.Username) and (Password = FPassword);
  if Result then
  begin
    Token := NewToken;
    AddIssuedToken(Token);
  end;
end;

function TAuthService.ValidateBearer(const AuthorizationHeader: string): Boolean;
var
  Token: string;
const
  Prefix = 'Bearer ';
begin
  if not FConfig.Enabled then
    Exit(True);
  if Pos(Prefix, AuthorizationHeader) <> 1 then
    Exit(False);
  Token := Copy(AuthorizationHeader, Length(Prefix) + 1, MaxInt);
  Result := (FStaticTokens.IndexOf(Token) >= 0) or IsIssuedTokenValid(Token);
end;

end.
