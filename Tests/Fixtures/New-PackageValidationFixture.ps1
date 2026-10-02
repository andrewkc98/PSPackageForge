function Get-PackageValidationMutationMatrix {
    @(
        @{ Name = 'stale manifest commands'; Change = { param($f) $m = Get-Content -LiteralPath (Join-Path $f 'PackageManifest.json') -Raw | ConvertFrom-Json; $m.PackageSpec.InstallCommand.ArgumentList = @('/changed'); $m | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $f 'PackageManifest.json') } }
        @{ Name = 'missing toolkit file'; Change = { param($f) Remove-Item -LiteralPath (Join-Path $f 'Package/PSAppDeployToolkit/PSAppDeployToolkit.psm1') } }
        @{ Name = 'missing launcher'; Change = { param($f) Remove-Item -LiteralPath (Join-Path $f 'Package/Invoke-AppDeployToolkit.exe') } }
        @{ Name = 'placeholder launcher'; Change = { param($f) Set-Content -LiteralPath (Join-Path $f 'Package/Invoke-AppDeployToolkit.exe') -Value 'placeholder' -NoNewline } }
        @{ Name = 'missing frontend'; Change = { param($f) Remove-Item -LiteralPath (Join-Path $f 'Package/Invoke-AppDeployToolkit.ps1') } }
        @{ Name = 'placeholder frontend'; Change = { param($f) Set-Content -LiteralPath (Join-Path $f 'Package/Invoke-AppDeployToolkit.ps1') -Value 'placeholder' -NoNewline } }
        @{ Name = 'extra file'; Change = { param($f) Set-Content -LiteralPath (Join-Path $f 'Package/unexpected.txt') -Value 'extra' -NoNewline } }
        @{ Name = 'changed package bytes'; Change = { param($f) Add-Content -LiteralPath (Join-Path $f 'Package/Files/setup.exe') -Value 'changed' } }
        @{ Name = 'wrong receipt renderer version'; Change = { param($f) $p = Join-Path $f 'Package/PSPackageForgeReceipt.json'; $r = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; $r.Renderer.Version = '0.1.0'; $r | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $p } }
    )
}

function New-PackageValidationFixture {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string] $RootPath,
        [switch] $CreateReceipt
    )

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        $RootPath = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    }
    if (-not $PSCmdlet.ShouldProcess($RootPath, 'Create package validation fixture')) { return }

    $scaffoldRoot = Join-Path $RootPath 'Source'
    $packagePath = Join-Path $RootPath 'Package'
    [void] (New-Item -ItemType Directory -Path $scaffoldRoot -Force)
    [void] (New-Item -ItemType Directory -Path $packagePath -Force)

    $installerPath = Join-Path $scaffoldRoot 'setup.exe'
    Set-Content -LiteralPath $installerPath -Value 'package validation fixture installer' -NoNewline -Encoding UTF8
    $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    $manifest = [ordered] @{
        SchemaVersion = '2.0'
        Generator = [ordered] @{ Name = 'PSPackageForge'; Version = "$script:GeneratorVersion"; RequiredPSADTVersion = "$script:RequiredPSADTVersion" }
        Installer = [ordered] @{ Path = 'setup.exe'; FileName = 'setup.exe'; SHA256 = $installerHash }
        PackageSpec = [ordered] @{
            InstallCommand = [ordered] @{ Executable = 'setup.exe'; ArgumentList = @('/quiet'); ExpectedExitCodes = @(0) }
            UninstallCommand = [ordered] @{ Executable = 'setup.exe'; ArgumentList = @('/uninstall'); ExpectedExitCodes = @(0) }
            ReturnCodeMap = @([ordered] @{ Code = 0; Classification = 'Success'; Meaning = 'Success' })
        }
        Readiness = 'ReviewRequired'
    }
    $manifestPath = Join-Path $scaffoldRoot 'PackageManifest.json'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    foreach ($relative in @('Config', 'PSAppDeployToolkit', 'Files')) {
        [void] (New-Item -ItemType Directory -Path (Join-Path $packagePath $relative) -Force)
    }
    $launcherBytes = [byte[]]::new(128)
    $launcherBytes[0] = 0x4D; $launcherBytes[1] = 0x5A
    [BitConverter]::GetBytes([int] 64).CopyTo($launcherBytes, 0x3C)
    $launcherBytes[64] = 0x50; $launcherBytes[65] = 0x45
    [System.IO.File]::WriteAllBytes((Join-Path $packagePath 'Invoke-AppDeployToolkit.exe'), $launcherBytes)
    $frontend = @'
$adtSession = @{}
function Install-ADTDeployment { }
function Uninstall-ADTDeployment { }
'@
    Set-Content -LiteralPath (Join-Path $packagePath 'Invoke-AppDeployToolkit.ps1') -Value $frontend -NoNewline -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $packagePath 'Config/config.psd1') -Value '@{}' -NoNewline -Encoding UTF8
    $toolkitDir = Join-Path $packagePath 'PSAppDeployToolkit'
    $rootModule = if ($CreateReceipt) { "; RootModule = 'PSAppDeployToolkit.psm1'" } else { '' }
    Set-Content -LiteralPath (Join-Path $toolkitDir 'PSAppDeployToolkit.psd1') -Value "@{ ModuleVersion = '$script:RequiredPSADTVersion'$rootModule }" -NoNewline -Encoding UTF8
    if ($CreateReceipt) { Set-Content -LiteralPath (Join-Path $toolkitDir 'PSAppDeployToolkit.psm1') -Value '# fixture toolkit module' -NoNewline -Encoding UTF8 }
    Copy-Item -LiteralPath $installerPath -Destination (Join-Path $packagePath 'Files/setup.exe')

    $manifestInput = Read-PackageForgeManifest -ManifestPath $manifestPath
    if ($CreateReceipt) { [void] (Write-PackageForgeReceipt -ManifestInput $manifestInput -PackagePath $packagePath) }
    [pscustomobject] @{
        RootPath = $RootPath
        ScaffoldRoot = $scaffoldRoot
        PackagePath = $packagePath
        ManifestPath = $manifestPath
        ManifestInput = $manifestInput
        InstallerPath = $installerPath
    }
}
