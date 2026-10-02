[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DependencyRoot,
    [Parameter()] [string] $NativeMsiPath,
    [Parameter()] [string] $ExeInstallerPath,
    [Parameter()] [switch] $IncludeStandardUser,
    [Parameter(DontShow)] [switch] $StandardUserChild,
    [Parameter(DontShow)] [string] $StandardUserName
)

$ErrorActionPreference = 'Stop'
$DependencyRoot = [IO.Path]::GetFullPath($DependencyRoot)
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pesterManifest = Join-Path $DependencyRoot 'Pester/5.7.1/Pester.psd1'
$analyzerManifest = Join-Path $DependencyRoot 'PSScriptAnalyzer/1.25.0/PSScriptAnalyzer.psd1'
$psadtManifest = Join-Path $DependencyRoot 'PSAppDeployToolkit/4.0.6/PSAppDeployToolkit.psd1'

if ($PSVersionTable.PSVersion -lt [Version] '5.1' -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Invoke-WindowsAcceptance.ps1 must run under Windows PowerShell 5.1.'
}
if (-not (Test-Path -LiteralPath $DependencyRoot -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $DependencyRoot -Force)
}

function Test-SavedModule {
    param([string] $ManifestPath, [string] $Name, [Version] $Version)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
    $data = Import-PowerShellDataFile -LiteralPath $ManifestPath
    $savedName = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $ManifestPath))
    return ($savedName -eq $Name -and [Version] $data.ModuleVersion -eq $Version)
}

function Save-ExactModuleIfMissing {
    param([string] $Name, [Version] $Version, [string] $ManifestPath)
    if (Test-SavedModule -ManifestPath $ManifestPath -Name $Name -Version $Version) { return }
    Save-Module -Name $Name -RequiredVersion $Version -Repository PSGallery -Path $DependencyRoot -Force
    if (-not (Test-SavedModule -ManifestPath $ManifestPath -Name $Name -Version $Version)) {
        throw "Save-Module did not provide $Name $Version at '$ManifestPath'."
    }
}

Save-ExactModuleIfMissing -Name Pester -Version ([Version] '5.7.1') -ManifestPath $pesterManifest
Save-ExactModuleIfMissing -Name PSScriptAnalyzer -Version ([Version] '1.25.0') -ManifestPath $analyzerManifest
Save-ExactModuleIfMissing -Name PSAppDeployToolkit -Version ([Version] '4.0.6') -ManifestPath $psadtManifest

$env:PSModulePath = $DependencyRoot + [IO.Path]::PathSeparator + $env:PSModulePath
$env:PSPACKAGEFORGE_RUN_WINDOWS_ACCEPTANCE = '1'
$env:PSPACKAGEFORGE_PSADT_MODULE_PATH = $psadtManifest
if (-not [string]::IsNullOrWhiteSpace($NativeMsiPath)) {
    $env:PSPACKAGEFORGE_NATIVE_MSI_PATH = [IO.Path]::GetFullPath($NativeMsiPath)
}
if (-not [string]::IsNullOrWhiteSpace($ExeInstallerPath)) {
    $env:PSPACKAGEFORGE_EXE_INSTALLER_PATH = [IO.Path]::GetFullPath($ExeInstallerPath)
}

Import-Module -Name $pesterManifest -Force -ErrorAction Stop
Import-Module -Name $analyzerManifest -Force -ErrorAction Stop
Import-Module -Name $psadtManifest -Force -ErrorAction Stop

if ($StandardUserChild) {
    if ([string]::IsNullOrWhiteSpace($StandardUserName)) { throw 'The standard-user child run requires its unique account name.' }
    $env:PSPACKAGEFORGE_ACCEPTANCE_USER = $StandardUserName
    $testResult = Invoke-Pester -Path (Join-Path $PSScriptRoot 'WindowsPackageRuntime.Tests.ps1') `
        -Tag StandardUser -Output Detailed -PassThru
    if ($null -eq $testResult -or $testResult.FailedCount -gt 0 -or $testResult.PassedCount -eq 0) {
        throw 'The standard-user Windows acceptance suite failed or executed no tests.'
    }
    exit 0
}

$buildScript = Join-Path $repositoryRoot 'build.ps1'
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $buildScript -Task All -Output Detailed
if ($LASTEXITCODE -ne 0) { throw "The full build failed with exit code $LASTEXITCODE." }

$testResult = Invoke-Pester -Path (Join-Path $PSScriptRoot 'WindowsPackageRuntime.Tests.ps1') `
    -ExcludeTag StandardUser -Output Detailed -PassThru
if ($null -eq $testResult -or $testResult.FailedCount -gt 0 -or $testResult.PassedCount -eq 0) {
    throw 'The Windows package-runtime acceptance suite failed or executed no tests.'
}

if ($IncludeStandardUser) {
    if (-not (Get-Command New-LocalUser -ErrorAction SilentlyContinue)) {
        throw 'The Windows LocalAccounts cmdlets are unavailable; the standard-user acceptance scenario cannot be provisioned safely.'
    }

    $accountName = 'PSPFStd' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $passwordCharacters = ([Guid]::NewGuid().ToString('N') + '!aA9').ToCharArray()
    $accountPassword = [Security.SecureString]::new()
    foreach ($passwordCharacter in $passwordCharacters) { $accountPassword.AppendChar($passwordCharacter) }
    $accountPassword.MakeReadOnly()
    $account = $null
    try {
        $account = New-LocalUser -Name $accountName -Password $accountPassword -AccountNeverExpires `
            -PasswordNeverExpires -Description 'Temporary PSPackageForge acceptance account'
        $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545' -ErrorAction Stop
        $administratorsGroup = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
        Add-LocalGroupMember -Group $usersGroup.Name -Member $account -ErrorAction Stop
        $adminSids = @(Get-LocalGroupMember -Group $administratorsGroup.Name -ErrorAction Stop |
            ForEach-Object { $_.SID.Value })
        if ($adminSids -contains $account.SID.Value) { throw 'The temporary acceptance account unexpectedly belongs to Administrators.' }

        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
            '-DependencyRoot', $DependencyRoot, '-StandardUserChild', '-StandardUserName', $accountName)
        if (-not [string]::IsNullOrWhiteSpace($NativeMsiPath)) { $arguments += @('-NativeMsiPath', [IO.Path]::GetFullPath($NativeMsiPath)) }
        if (-not [string]::IsNullOrWhiteSpace($ExeInstallerPath)) { $arguments += @('-ExeInstallerPath', [IO.Path]::GetFullPath($ExeInstallerPath)) }
        $quotedArguments = @($arguments | ForEach-Object {
            '"' + ([string] $_).Replace('"', '\"') + '"'
        }) -join ' '
        $acceptanceLogRoot = Split-Path -Parent $DependencyRoot
        $logId = [Guid]::NewGuid().ToString('N')
        $standardUserStdoutPath = Join-Path $acceptanceLogRoot "standard-user-$logId.stdout.log"
        $standardUserStderrPath = Join-Path $acceptanceLogRoot "standard-user-$logId.stderr.log"
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Credential `
            ([Management.Automation.PSCredential]::new($accountName, $accountPassword)) -LoadUserProfile `
            -ArgumentList $quotedArguments -RedirectStandardOutput $standardUserStdoutPath `
            -RedirectStandardError $standardUserStderrPath -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Output "Standard-user acceptance stdout log: $standardUserStdoutPath"
            if (Test-Path -LiteralPath $standardUserStdoutPath -PathType Leaf) {
                $standardUserStdout = Get-Content -LiteralPath $standardUserStdoutPath -Raw
                if (-not [string]::IsNullOrEmpty($standardUserStdout)) {
                    Write-Output '--- standard-user acceptance stdout ---'
                    Write-Output $standardUserStdout
                }
            }
            Write-Output "Standard-user acceptance stderr log: $standardUserStderrPath"
            if (Test-Path -LiteralPath $standardUserStderrPath -PathType Leaf) {
                $standardUserStderr = Get-Content -LiteralPath $standardUserStderrPath -Raw
                if (-not [string]::IsNullOrEmpty($standardUserStderr)) {
                    Write-Output '--- standard-user acceptance stderr ---'
                    Write-Output $standardUserStderr
                }
            }
            throw "The standard-user acceptance process failed with exit code $($process.ExitCode)."
        }
        Write-Output "Standard-user acceptance stdout log: $standardUserStdoutPath"
        Write-Output "Standard-user acceptance stderr log: $standardUserStderrPath"
    }
    finally {
        if ($null -ne $account) {
            $createdUserProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$($account.SID.Value)'" -ErrorAction SilentlyContinue
            Remove-LocalUser -SID $account.SID -ErrorAction SilentlyContinue
            if ($null -ne $createdUserProfile) { Remove-CimInstance -InputObject $createdUserProfile -ErrorAction SilentlyContinue }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($NativeMsiPath)) {
    Write-Output 'SKIPPED: native MSI smoke unavailable; no -NativeMsiPath was supplied.'
}
if ([string]::IsNullOrWhiteSpace($ExeInstallerPath)) {
    Write-Output 'SKIPPED: native EXE smoke unavailable; no -ExeInstallerPath was supplied.'
}
