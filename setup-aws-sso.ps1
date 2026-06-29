param(
    [string] $ProfileName = "",
    [string[]] $ProfileNames = @(
        "AINDDevelopersAccess",
        "AINDDataAnalystAccess",
        "AINDScientistsAccess"
    ),
    [string] $ConfigSource = (Join-Path $PSScriptRoot "config"),
    [switch] $SkipInstall,
    [switch] $SkipSsoLogin,
    [switch] $DryRun
)

$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($ProfileName) {
    $ProfileNames = @($ProfileName)
}

$ProfileNames = @($ProfileNames | Where-Object { $_ } | Select-Object -Unique)
if (-not $ProfileNames -or $ProfileNames.Count -eq 0) {
    throw "At least one profile name is required."
}

function Write-Step {
    param([string] $Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Detail {
    param([string] $Message)
    Write-Host "    $Message"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-AwsCli {
    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    $command = Get-Command aws.exe -ErrorAction SilentlyContinue
    if ($command) {
        $candidatePaths.Add($command.Source)
    }

    $knownRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LocalAppData
    )

    foreach ($knownRoot in $knownRoots) {
        if (-not $knownRoot) {
            continue
        }

        $candidatePath = Join-Path $knownRoot "Amazon\AWSCLIV2\aws.exe"
        if (Test-Path -LiteralPath $candidatePath) {
            $candidatePaths.Add($candidatePath)
        }
    }

    $uniqueCandidatePaths = $candidatePaths | Select-Object -Unique

    foreach ($candidatePath in $uniqueCandidatePaths) {
        $candidateVersion = Get-AwsCliVersion -AwsPath $candidatePath
        if ($candidateVersion -match "^aws-cli/2\.") {
            Add-CurrentProcessPath -DirectoryPath (Split-Path -Parent $candidatePath)
            return $candidatePath
        }
    }

    foreach ($candidatePath in $uniqueCandidatePaths) {
        Add-CurrentProcessPath -DirectoryPath (Split-Path -Parent $candidatePath)
        return $candidatePath
    }

    return $null
}

function Add-CurrentProcessPath {
    param([string] $DirectoryPath)

    if (-not $DirectoryPath) {
        return
    }

    if (-not (($env:Path -split ";") -contains $DirectoryPath)) {
        $env:Path = "$DirectoryPath;$env:Path"
    }
}

function Get-AwsCliVersion {
    param([string] $AwsPath)

    if (-not $AwsPath) {
        return $null
    }

    try {
        return (& $AwsPath --version 2>&1) -join "`n"
    }
    catch {
        return $null
    }
}

function Invoke-AwsCliCapture {
    param(
        [string] $AwsPath,
        [string[]] $Arguments
    )

    $stdoutPath = [IO.Path]::GetTempFileName()
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        $process = Start-Process `
            -FilePath $AwsPath `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $exitCode = $process.ExitCode
        $stdout = Get-Content -Raw -LiteralPath $stdoutPath -ErrorAction SilentlyContinue
        $stderr = Get-Content -Raw -LiteralPath $stderrPath -ErrorAction SilentlyContinue
        $output = @($stdout, $stderr) | Where-Object { $_ } | Out-String
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (($output | Out-String).Trim())
    }
}

function Get-AwsProfileConfigValue {
    param(
        [string] $AwsPath,
        [string] $ProfileName,
        [string] $Name
    )

    $result = Invoke-AwsCliCapture -AwsPath $AwsPath -Arguments @("configure", "get", $Name, "--profile", $ProfileName)
    if ($result.ExitCode -eq 0) {
        return $result.Output.Trim()
    }

    return ""
}

function Set-AwsProfileConfigValue {
    param(
        [string] $AwsPath,
        [string] $ProfileName,
        [string] $Name,
        [string] $Value
    )

    $result = Invoke-AwsCliCapture -AwsPath $AwsPath -Arguments @(
        "configure",
        "set",
        $Name,
        $Value,
        "--profile",
        $ProfileName
    )

    if ($result.ExitCode -ne 0) {
        throw "Failed to set AWS config value '$Name' for profile '$ProfileName'. Output: $($result.Output)"
    }
}

function Convert-RoleInputToName {
    param([string] $RoleInput)

    $trimmedRoleInput = $RoleInput.Trim()
    $roleMatch = [regex]::Match($trimmedRoleInput, "(?:[?&]|[#&])role_name=([^&]+)")
    if ($roleMatch.Success) {
        return [Uri]::UnescapeDataString($roleMatch.Groups[1].Value)
    }

    return $trimmedRoleInput
}

function Add-AwsSsoRoleProfile {
    param(
        [string] $AwsPath,
        [string] $ProfileName,
        [string] $RoleName,
        [string] $TemplateProfileName
    )

    $ssoSession = Get-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $TemplateProfileName -Name "sso_session"
    $accountId = Get-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $TemplateProfileName -Name "sso_account_id"
    $region = Get-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $TemplateProfileName -Name "region"

    if (-not $ssoSession) {
        $ssoSession = "aind_sso"
    }

    if (-not $accountId) {
        $accountId = "467914378000"
    }

    if (-not $region) {
        $region = "us-west-2"
    }

    Write-Step "Adding AWS profile for entered role"
    Write-Detail "Profile: $ProfileName"
    Write-Detail "Account: $accountId"
    Write-Detail "Role:    $RoleName"

    if ($DryRun) {
        Write-Detail "Dry run: would write this profile to ~/.aws/config."
        return
    }

    Set-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $ProfileName -Name "sso_session" -Value $ssoSession
    Set-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $ProfileName -Name "sso_account_id" -Value $accountId
    Set-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $ProfileName -Name "sso_role_name" -Value $RoleName
    Set-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $ProfileName -Name "region" -Value $region
}

function Install-AwsCli {
    if ($DryRun) {
        Write-Detail "Dry run: would download and silently install AWS CLI v2 MSI."
        return
    }

    $installerUrl = "https://awscli.amazonaws.com/AWSCLIV2.msi"
    $installerPath = Join-Path $env:TEMP "AWSCLIV2.msi"

    Write-Step "Downloading AWS CLI v2"
    Write-Detail $installerUrl
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

    Write-Step "Installing AWS CLI v2 silently"
    $arguments = @("/i", "`"$installerPath`"", "/qn", "/norestart")
    if (Test-IsAdministrator) {
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
    }
    else {
        Write-Detail "Requesting Windows UAC elevation for the installer only."
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    }

    if ($process.ExitCode -eq 3010) {
        Write-Detail "Installer completed and requested a restart, but setup will continue."
    }
    elseif ($process.ExitCode -ne 0) {
        throw "AWS CLI installer failed with exit code $($process.ExitCode)."
    }
}

function Copy-AwsConfig {
    if (-not (Test-Path -LiteralPath $ConfigSource)) {
        throw "Config source not found: $ConfigSource"
    }

    $awsDirectory = Join-Path $HOME ".aws"
    $configDestination = Join-Path $awsDirectory "config"

    Write-Step "Copying AWS config"
    Write-Detail "$ConfigSource -> $configDestination"

    if ($DryRun) {
        Write-Detail "Dry run: would create $awsDirectory and copy config."
        return
    }

    New-Item -ItemType Directory -Path $awsDirectory -Force | Out-Null

    if (Test-Path -LiteralPath $configDestination) {
        $sourceHash = Get-FileHash -LiteralPath $ConfigSource -Algorithm SHA256
        $destinationHash = Get-FileHash -LiteralPath $configDestination -Algorithm SHA256

        if ($sourceHash.Hash -ne $destinationHash.Hash) {
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $backupPath = "$configDestination.backup-$timestamp"
            Copy-Item -LiteralPath $configDestination -Destination $backupPath -Force
            Write-Detail "Backed up existing config to $backupPath"
        }
    }

    Copy-Item -LiteralPath $ConfigSource -Destination $configDestination -Force
}

function Set-AwsProfile {
    param([string] $ProfileName)

    Write-Step "Setting AWS_PROFILE"
    Write-Detail "Current process and future user shells: $ProfileName"
    Write-Detail "Local launcher profile file: $(Join-Path $PSScriptRoot ".aws-profile")"

    if ($DryRun) {
        Write-Detail "Dry run: would persist AWS_PROFILE as a user environment variable and local launcher profile."
        return
    }

    $env:AWS_PROFILE = $ProfileName
    [Environment]::SetEnvironmentVariable("AWS_PROFILE", $ProfileName, "User")
    Set-Content -LiteralPath (Join-Path $PSScriptRoot ".aws-profile") -Value $ProfileName -NoNewline
}

function Invoke-AwsSsoLogin {
    param(
        [string] $AwsPath,
        [string] $ProfileName
    )

    if ($SkipSsoLogin) {
        Write-Step "Skipping AWS SSO login"
        return
    }

    Write-Step "Starting AWS SSO login"
    Write-Detail "A browser/device authorization prompt is the one interactive step AWS requires."

    if ($DryRun) {
        Write-Detail "Dry run: would run aws sso login --profile $ProfileName."
        return
    }

    & $AwsPath sso login --profile $ProfileName
    if ($LASTEXITCODE -ne 0) {
        throw "aws sso login failed with exit code $LASTEXITCODE."
    }
}

function Test-AwsRoleAccess {
    param(
        [string] $AwsPath,
        [string] $ProfileName
    )

    Write-Step "Checking AWS role credentials for $ProfileName"

    if ($DryRun) {
        Write-Detail "Dry run: would run aws sts get-caller-identity --profile $ProfileName."
        return [pscustomobject]@{
            Success = $true
            ProfileName = $ProfileName
            AccountId = ""
            RoleName = ""
            Error = ""
        }
    }

    $result = Invoke-AwsCliCapture -AwsPath $AwsPath -Arguments @(
        "sts",
        "get-caller-identity",
        "--profile",
        $ProfileName,
        "--output",
        "json"
    )

    if ($result.ExitCode -eq 0) {
        try {
            $identity = $result.Output | ConvertFrom-Json
            Write-Detail "Authenticated as account $($identity.Account)."
        }
        catch {
            Write-Detail "Authenticated."
        }

        return [pscustomobject]@{
            Success = $true
            ProfileName = $ProfileName
            AccountId = ""
            RoleName = ""
            Error = ""
        }
    }

    $accountId = Get-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $ProfileName -Name "sso_account_id"
    $roleName = Get-AwsProfileConfigValue -AwsPath $AwsPath -ProfileName $ProfileName -Name "sso_role_name"

    if ($result.Output -match "ForbiddenException" -and $result.Output -match "GetRoleCredentials") {
        Write-Detail "No access for account $accountId role $roleName."
    }
    else {
        Write-Detail "Failed: $($result.Output)"
    }

    return [pscustomobject]@{
        Success = $false
        ProfileName = $ProfileName
        AccountId = $accountId
        RoleName = $roleName
        Error = $result.Output
    }
}

function Select-AwsProfileWithRoleAccess {
    param(
        [string] $AwsPath,
        [string[]] $ProfileNames
    )

    $attempts = @()
    $templateProfileName = $ProfileNames[0]
    $triedProfileNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($candidateProfileName in $ProfileNames) {
        [void] $triedProfileNames.Add($candidateProfileName)
        $attempt = Test-AwsRoleAccess -AwsPath $AwsPath -ProfileName $candidateProfileName
        if ($attempt.Success) {
            Write-Step "Selected AWS profile"
            Write-Detail $candidateProfileName
            return $candidateProfileName
        }

        $attempts += $attempt
    }

    while (-not $DryRun) {
        Write-Step "No configured role worked"
        $roleInput = Read-Host "Enter another AWS SSO role name to try, or press Enter to stop"
        $roleName = Convert-RoleInputToName -RoleInput $roleInput

        if (-not $roleName) {
            break
        }

        $candidateProfileName = $roleName
        if ($triedProfileNames.Contains($candidateProfileName)) {
            Write-Detail "Already tried $candidateProfileName."
            continue
        }

        [void] $triedProfileNames.Add($candidateProfileName)
        Add-AwsSsoRoleProfile `
            -AwsPath $AwsPath `
            -ProfileName $candidateProfileName `
            -RoleName $roleName `
            -TemplateProfileName $templateProfileName

        $attempt = Test-AwsRoleAccess -AwsPath $AwsPath -ProfileName $candidateProfileName
        if ($attempt.Success) {
            Write-Step "Selected AWS profile"
            Write-Detail $candidateProfileName
            return $candidateProfileName
        }

        $attempts += $attempt
    }

    $attemptSummary = ($attempts | ForEach-Object {
        $errorLine = (($_.Error -split "\r?\n") | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $errorLine) {
            $errorLine = "Unknown error"
        }

        "- $($_.ProfileName) / account $($_.AccountId) / role $($_.RoleName): $errorLine"
    }) -join "`n"

    throw @"
AWS SSO login succeeded, but none of the configured profiles could get IAM Identity Center role credentials.

Tried profiles in this order:
$attemptSummary

Ask an AWS/IAM Identity Center admin to grant one of these account/role assignments, or update ./config with a profile assigned to you.
"@
}

function Test-S3Access {
    param(
        [string] $AwsPath,
        [string] $ProfileName
    )

    Write-Step "Checking S3 access"

    if ($DryRun) {
        Write-Detail "Dry run: would run aws s3 ls --profile $ProfileName."
        return
    }

    $result = Invoke-AwsCliCapture -AwsPath $AwsPath -Arguments @("s3", "ls", "--profile", $ProfileName)
    if ($result.Output) {
        Write-Host $result.Output
    }

    if ($result.ExitCode -ne 0) {
        throw @"
AWS role credentials worked, but S3 bucket listing failed.
This usually means the role lacks permission for s3:ListAllMyBuckets, or S3 access is otherwise restricted.

Original AWS CLI error:
$($result.Output)
"@
    }
}

Write-Step "Preparing AWS SSO setup for profiles"
Write-Detail ($ProfileNames -join ", ")

$awsPath = Resolve-AwsCli
$awsVersion = Get-AwsCliVersion -AwsPath $awsPath

if ($awsVersion -match "^aws-cli/2\.") {
    Write-Detail "Found AWS CLI v2: $awsVersion"
}
elseif ($SkipInstall) {
    if (-not $awsPath) {
        throw "AWS CLI was not found and -SkipInstall was supplied."
    }

    throw "AWS CLI v2 is required, but the discovered aws command does not look like v2: $awsVersion"
}
else {
    if ($awsVersion) {
        Write-Detail "Existing aws command is not v2: $awsVersion"
    }
    else {
        Write-Detail "AWS CLI v2 was not found."
    }

    Install-AwsCli
    if ($DryRun) {
        $awsPath = "aws.exe"
        $awsVersion = "aws-cli/2.x dry-run"
        Write-Detail "Dry run: assuming AWS CLI v2 installation would complete."
    }
    else {
        $awsPath = Resolve-AwsCli
        $awsVersion = Get-AwsCliVersion -AwsPath $awsPath
    }

    if (-not ($awsVersion -match "^aws-cli/2\.")) {
        throw "AWS CLI v2 installation completed, but aws --version did not report v2. Version output: $awsVersion"
    }

    Write-Detail "Installed AWS CLI v2: $awsVersion"
}

Copy-AwsConfig
Invoke-AwsSsoLogin -AwsPath $awsPath -ProfileName $ProfileNames[0]
$ProfileName = Select-AwsProfileWithRoleAccess -AwsPath $awsPath -ProfileNames $ProfileNames
Set-AwsProfile -ProfileName $ProfileName
Test-S3Access -AwsPath $awsPath -ProfileName $ProfileName

Write-Step "AWS SSO setup complete"
