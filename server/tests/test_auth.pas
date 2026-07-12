program test_auth;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, lsconfig, lsauth;

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

procedure TestDisabledAuthAllowsRequests;
var
  Config: TAppConfig;
  Auth: TAuthService;
begin
  SetDefaultConfig(Config);
  Config.Auth.Enabled := False;
  Auth := TAuthService.Create(Config.Auth);
  try
    AssertTrue(Auth.Enabled = False, 'disabled auth flag');
    AssertTrue(Auth.ValidateBearer(''), 'disabled auth validates empty header');
  finally
    Auth.Free;
  end;
end;

procedure TestIssuedToken;
var
  Config: TAppConfig;
  Auth: TAuthService;
  PasswordFile: string;
  Token: string;
  ExpiresIn: Integer;
begin
  SetDefaultConfig(Config);
  PasswordFile := GetTempDir(False) + DirectorySeparator + 'liquidstoolap-auth-password.txt';
  WriteTextFile(PasswordFile, 'secret' + LineEnding);
  Config.Auth.PasswordFile := PasswordFile;
  Config.Auth.TokenTtlSeconds := 60;

  Auth := TAuthService.Create(Config.Auth);
  try
    AssertTrue(not Auth.IssueToken('admin', 'wrong', Token, ExpiresIn), 'wrong password rejected');
    AssertTrue(Auth.IssueToken('admin', 'secret', Token, ExpiresIn), 'correct password accepted');
    AssertTrue(Pos('lst_', Token) = 1, 'token prefix');
    AssertTrue(ExpiresIn = 60, 'expires in');
    AssertTrue(Auth.ValidateBearer('Bearer ' + Token), 'issued token validates');
    AssertTrue(not Auth.ValidateBearer(Token), 'missing bearer prefix rejected');
    AssertTrue(not Auth.ValidateBearer('Bearer nope'), 'unknown token rejected');
  finally
    Auth.Free;
    DeleteFile(PasswordFile);
  end;
end;

procedure TestStaticTokens;
var
  Config: TAppConfig;
  Auth: TAuthService;
  TokenFile: string;
begin
  SetDefaultConfig(Config);
  TokenFile := GetTempDir(False) + DirectorySeparator + 'liquidstoolap-static-tokens.txt';
  WriteTextFile(TokenFile,
    '# comment' + LineEnding +
    'lst_plain' + LineEnding +
    'lst_named = ignored label' + LineEnding);
  Config.Auth.IssueTokens := False;
  Config.Auth.PasswordFile := '';
  Config.Auth.AllowStaticTokens := True;
  Config.Auth.StaticTokensFile := TokenFile;

  Auth := TAuthService.Create(Config.Auth);
  try
    AssertTrue(Auth.ValidateBearer('Bearer lst_plain'), 'plain static token validates');
    AssertTrue(Auth.ValidateBearer('Bearer lst_named'), 'named static token validates');
    AssertTrue(not Auth.ValidateBearer('Bearer ignored label'), 'static token label ignored');
  finally
    Auth.Free;
    DeleteFile(TokenFile);
  end;
end;

begin
  TestDisabledAuthAllowsRequests;
  TestIssuedToken;
  TestStaticTokens;
  WriteLn('test_auth ok');
end.
