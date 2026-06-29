@echo off
setlocal

set "AWSCLI=%ProgramFiles%\Amazon\AWSCLIV2\aws.exe"

if not defined AWS_PROFILE (
    if exist "%~dp0.aws-profile" (
        set /p AWS_PROFILE=<"%~dp0.aws-profile"
    )
)

if exist "%AWSCLI%" (
    "%AWSCLI%" %*
    exit /b %ERRORLEVEL%
)

echo AWS CLI v2 was not found at "%AWSCLI%". Run setup-aws-sso.cmd first. 1>&2
exit /b 1
