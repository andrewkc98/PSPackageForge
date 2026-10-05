$script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ToolkitModulePath = $env:PSPACKAGEFORGE_PSADT_MODULE_PATH
$script:ToolkitConfigured = -not [string]::IsNullOrWhiteSpace($script:ToolkitModulePath)
$script:ToolkitAvailable = $false
if ($script:ToolkitConfigured -and
    (Test-Path -LiteralPath $script:ToolkitModulePath -PathType Leaf)) {
    try {
        $toolkitManifest = Import-PowerShellDataFile -LiteralPath $script:ToolkitModulePath -ErrorAction Stop
        $script:ToolkitAvailable = ([string] $toolkitManifest.ModuleVersion -eq '4.0.6')
    }
    catch { $script:ToolkitAvailable = $false }
}

Describe 'Shipped module distribution' {
    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        # Pester runs BeforeAll/It in a later phase than the file-level discovery
        # statements above. Recreate these values here for the runtime assertion;
        # the discovery-time $script:ToolkitConfigured remains the source for -Skip.
        $script:ToolkitModulePath = $env:PSPACKAGEFORGE_PSADT_MODULE_PATH
        $script:ToolkitConfigured = -not [string]::IsNullOrWhiteSpace($script:ToolkitModulePath)
        $script:ToolkitAvailable = $false
        if ($script:ToolkitConfigured -and
            (Test-Path -LiteralPath $script:ToolkitModulePath -PathType Leaf)) {
            try {
                $toolkitManifest = Import-PowerShellDataFile -LiteralPath $script:ToolkitModulePath -ErrorAction Stop
                $script:ToolkitAvailable = ([string] $toolkitManifest.ModuleVersion -eq '4.0.6')
            }
            catch { $script:ToolkitAvailable = $false }
        }
    }

    BeforeEach {
        $script:DistributionRoot = Join-Path $TestDrive ('distribution-' + [Guid]::NewGuid().ToString('N'))
        $script:ModuleCopy = Join-Path $script:DistributionRoot 'PSPackageForge'
        [void] (New-Item -ItemType Directory -Path $script:ModuleCopy -Force)

        foreach ($asset in @('PSPackageForge.psd1', 'PSPackageForge.psm1')) {
            Copy-Item -LiteralPath (Join-Path $script:ModuleRoot $asset) -Destination $script:ModuleCopy
        }
        foreach ($directory in @('Private', 'Public', 'Config', 'Templates')) {
            Copy-Item -LiteralPath (Join-Path $script:ModuleRoot $directory) -Destination $script:ModuleCopy -Recurse
        }

        $script:ChildScript = Join-Path $script:DistributionRoot 'distribution-child.ps1'
        Set-Content -LiteralPath $script:ChildScript -Encoding UTF8 -Value @'
param(
    [Parameter(Mandatory)] [ValidateSet('WhatIf', 'Package')] [string] $Scenario,
    [Parameter(Mandatory)] [string] $ModuleManifest,
    [Parameter(Mandatory)] [string] $InstallerPath,
    [Parameter(Mandatory)] [string] $ScaffoldRoot,
    [Parameter(Mandatory)] [string] $PackagePath,
    [Parameter()] [string] $ToolkitPath
)
$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $ModuleManifest
Set-Location -LiteralPath (Split-Path -Parent $InstallerPath)
if ((Test-Path -LiteralPath (Join-Path $moduleRoot 'Tests')) -or
    (Test-Path -LiteralPath (Join-Path $moduleRoot '.agent')) -or
    (Test-Path -LiteralPath (Join-Path $moduleRoot 'Examples'))) {
    throw 'The isolated module copy contains excluded repository content.'
}
Import-Module -Name $ModuleManifest -Force -ErrorAction Stop
$module = Get-Module PSPackageForge | Where-Object {
    [IO.Path]::GetFullPath($_.ModuleBase) -eq [IO.Path]::GetFullPath($moduleRoot)
}
if ($null -eq $module) { throw 'PSPackageForge did not load from the isolated module manifest.' }

if ($Scenario -eq 'WhatIf') {
    $result = psforge scaffold -Path $InstallerPath -OutputPath $ScaffoldRoot -WhatIf -Confirm:$false
    if ($result.Status -ne 'WhatIf') { throw "Expected WhatIf status; received '$($result.Status)'." }
    if (Test-Path -LiteralPath $ScaffoldRoot) { throw 'The WhatIf smoke path wrote scaffold output.' }
    'DISTRIBUTION_WHATIF_OK'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ToolkitPath) -or -not (Test-Path -LiteralPath $ToolkitPath -PathType Leaf)) {
    throw 'The explicit PSPACKAGEFORGE_PSADT_MODULE_PATH toolkit manifest is unavailable.'
}
$env:PSPACKAGEFORGE_PSADT_MODULE_PATH = $ToolkitPath
[void] (New-Item -ItemType Directory -Path $ScaffoldRoot -Force)
$stagedInstallerPath = Join-Path $ScaffoldRoot ([IO.Path]::GetFileName($InstallerPath))
Copy-Item -LiteralPath $InstallerPath -Destination $stagedInstallerPath -ErrorAction Stop
$hash = (Get-FileHash -LiteralPath $stagedInstallerPath -Algorithm SHA256).Hash
$manifest = [ordered] @{
    SchemaVersion = '2.0'
    Generator = [ordered] @{ Name = 'PSPackageForge'; Version = '0.2.0'; RequiredPSADTVersion = '4.0.6' }
    Installer = [ordered] @{
        Path = [IO.Path]::GetFileName($InstallerPath)
        FileName = [IO.Path]::GetFileName($InstallerPath)
        SHA256 = $hash
        ProductName = 'Distribution Fixture'
        Manufacturer = 'PSPackageForge'
        ProductVersionRaw = '1.0.0'
        ApplicationArchitecture = 'Unknown'
    }
    PackageSpec = [ordered] @{
        SelectedContext = 'System'
        InstallCommand = [ordered] @{ Executable = 'setup.exe'; ArgumentList = @('/quiet'); ExpectedExitCodes = @(0) }
        UninstallCommand = [ordered] @{ Executable = 'setup.exe'; ArgumentList = @('/uninstall'); ExpectedExitCodes = @(0) }
        ReturnCodeMap = @([ordered] @{ Code = 0; Classification = 'Success'; Meaning = 'Success' })
    }
    Readiness = 'ReviewRequired'
}
$manifestPath = Join-Path $ScaffoldRoot 'PackageManifest.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$generated = New-PSADTPackage -ManifestPath $manifestPath -OutputPath $PackagePath `
    -PSADTModulePath $ToolkitPath -ErrorAction Stop
$manifestInput = & $module { param($path) Read-PackageForgeManifest -ManifestPath $path -RequireRunnable } $manifestPath
$validated = & $module { param($readerResult, $path) Test-PackageForgePackage -ManifestInput $readerResult -PackagePath $path } `
    $manifestInput $generated.PackagePath
if ([IO.Path]::GetFullPath($validated.PackagePath) -ne [IO.Path]::GetFullPath($PackagePath)) {
    throw 'Package validation returned an unexpected package path.'
}
'DISTRIBUTION_PACKAGE_VALIDATED'
'@

        $script:PowerShellPath = if ($env:OS -eq 'Windows_NT') {
            Join-Path $PSHOME 'pwsh.exe'
        }
        else { Join-Path $PSHOME 'pwsh' }
        if (-not (Test-Path -LiteralPath $script:PowerShellPath -PathType Leaf)) {
            $script:PowerShellPath = (Get-Command powershell -ErrorAction Stop).Source
        }

        $script:InstallerPath = Join-Path $script:DistributionRoot 'setup.exe'
        Set-Content -LiteralPath $script:InstallerPath -Value 'synthetic distribution installer' -NoNewline -Encoding UTF8
    }

    It 'imports only shipped assets in a fresh process and supports the psforge WhatIf path' {
        foreach ($required in @('Private', 'Public', 'Config', 'Templates', 'PSPackageForge.psd1', 'PSPackageForge.psm1')) {
            Test-Path -LiteralPath (Join-Path $script:ModuleCopy $required) | Should -BeTrue
        }
        foreach ($excluded in @('Tests', '.agent', 'Examples', '.openhands')) {
            Test-Path -LiteralPath (Join-Path $script:ModuleCopy $excluded) | Should -BeFalse
        }
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ModuleCopy 'PSPackageForge.psd1')
        $modulePrefix = $script:ModuleCopy.TrimEnd([char[]] @('/', '\')) + [IO.Path]::DirectorySeparatorChar
        $actualFiles = @(Get-ChildItem -LiteralPath $script:ModuleCopy -File -Recurse | ForEach-Object {
            $_.FullName.Substring($modulePrefix.Length).Replace('\', '/')
        } | Sort-Object)
        $listedFiles = @($manifest.FileList | Sort-Object)
        @(Compare-Object -ReferenceObject $actualFiles -DifferenceObject $listedFiles) | Should -BeNullOrEmpty

        $scaffoldRoot = Join-Path $script:DistributionRoot 'whatif-output'
        $output = @(& $script:PowerShellPath -NoLogo -NoProfile -NonInteractive -File $script:ChildScript `
            -Scenario WhatIf -ModuleManifest (Join-Path $script:ModuleCopy 'PSPackageForge.psd1') `
            -InstallerPath $script:InstallerPath -ScaffoldRoot $scaffoldRoot -PackagePath (Join-Path $script:DistributionRoot 'Package') 2>&1)
        $exitCode = $LASTEXITCODE
        ($output | Out-String) | Should -Match 'DISTRIBUTION_WHATIF_OK'
        $exitCode | Should -Be 0
        Test-Path -LiteralPath $scaffoldRoot | Should -BeFalse
    }

    It 'generates and validates a package from the isolated copy with the explicit pinned toolkit' -Skip:(-not $script:ToolkitConfigured) {
        $script:ToolkitAvailable | Should -BeTrue -Because 'a configured toolkit path must point to a readable PSADT 4.0.6 module manifest'
        $scaffoldRoot = Join-Path $script:DistributionRoot 'package-source'
        $packagePath = Join-Path $script:DistributionRoot 'generated-package'
        $output = @(& $script:PowerShellPath -NoLogo -NoProfile -NonInteractive -File $script:ChildScript `
            -Scenario Package -ModuleManifest (Join-Path $script:ModuleCopy 'PSPackageForge.psd1') `
            -InstallerPath $script:InstallerPath -ScaffoldRoot $scaffoldRoot -PackagePath $packagePath `
            -ToolkitPath $script:ToolkitModulePath 2>&1)
        $exitCode = $LASTEXITCODE
        ($output | Out-String) | Should -Match 'DISTRIBUTION_PACKAGE_VALIDATED'
        $exitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $packagePath 'PSPackageForgeReceipt.json') | Should -BeTrue
    }
}
