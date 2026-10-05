function Write-PackageForgeReceipt {
    <#
        Validates the staged PSADT package and writes its deterministic file receipt.
        All package checks happen before the receipt is created so a failed validation
        cannot leave a new, misleading receipt behind.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $ManifestInput,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PackagePath
    )

    function Get-ManifestValue {
        param(
            [Parameter(Mandatory)] [object] $InputObject,
            [Parameter(Mandatory)] [string] $Name
        )
        if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return Get-DocumentOptionalProperty -InputObject $InputObject -Name $Name
    }

    function Get-RequiredFile {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [Parameter(Mandatory)] [string] $RelativePath,
            [Parameter(Mandatory)] [string] $Description
        )
        $path = Join-Path -Path $Root -ChildPath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw [System.IO.InvalidDataException]::new("Package is missing required $Description '$RelativePath'.")
        }
        $file = Get-Item -LiteralPath $path -Force
        if ($file.Length -le 0) {
            throw [System.IO.InvalidDataException]::new("Package required $Description '$RelativePath' is empty.")
        }
        return $file
    }

    function Get-RelativePackagePath {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [Parameter(Mandatory)] [string] $Path
        )
        $rootWithSeparator = $Root.TrimEnd([char[]] @('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
        $relative = $Path.Substring($rootWithSeparator.Length)
        return $relative.Replace([System.IO.Path]::DirectorySeparatorChar, '/').Replace([System.IO.Path]::AltDirectorySeparatorChar, '/')
    }

    $resolvedPackagePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackagePath)
    if (-not (Test-Path -LiteralPath $resolvedPackagePath -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("Package path was not found: '$resolvedPackagePath'.")
    }
    $resolvedPackagePath = (Resolve-Path -LiteralPath $resolvedPackagePath -ErrorAction Stop).ProviderPath

    $manifestPath = "$(Get-ManifestValue -InputObject $ManifestInput -Name 'ManifestPath')"
    $manifestHash = "$(Get-ManifestValue -InputObject $ManifestInput -Name 'ManifestSHA256')"
    $manifest = Get-ManifestValue -InputObject $ManifestInput -Name 'Manifest'
    $installer = Get-ManifestValue -InputObject $manifest -Name 'Installer'
    $installerFileName = "$(Get-ManifestValue -InputObject $installer -Name 'FileName')"
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or [string]::IsNullOrWhiteSpace($manifestHash)) {
        throw [System.IO.InvalidDataException]::new('Manifest reader output must contain ManifestPath and ManifestSHA256.')
    }
    if ([string]::IsNullOrWhiteSpace($installerFileName) -or
        [System.IO.Path]::IsPathRooted($installerFileName) -or
        $installerFileName.IndexOfAny([char[]] @('\', '/')) -ge 0) {
        throw [System.IO.InvalidDataException]::new('Manifest reader output must contain a direct-child Installer.FileName.')
    }

    $requiredFiles = [ordered] @{
        'root launcher' = 'Invoke-AppDeployToolkit.exe'
        'frontend' = 'Invoke-AppDeployToolkit.ps1'
        'configuration' = 'Config/config.psd1'
        'bundled toolkit manifest' = 'PSAppDeployToolkit/PSAppDeployToolkit.psd1'
        'packaged installer' = "Files/$installerFileName"
    }
    foreach ($description in $requiredFiles.Keys) {
        [void] (Get-RequiredFile -Root $resolvedPackagePath -RelativePath $requiredFiles[$description] -Description $description)
    }

    $toolkitManifestPath = Join-Path -Path $resolvedPackagePath -ChildPath 'PSAppDeployToolkit/PSAppDeployToolkit.psd1'
    try {
        $toolkitManifest = Import-PowerShellDataFile -LiteralPath $toolkitManifestPath -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new("The bundled PSAppDeployToolkit manifest could not be read: $($_.Exception.Message)")
    }
    $toolkitVersion = "$(Get-ManifestValue -InputObject $toolkitManifest -Name 'ModuleVersion')"
    if ($toolkitVersion -ne "$script:RequiredPSADTVersion") {
        throw [System.IO.InvalidDataException]::new(
            "The bundled PSAppDeployToolkit manifest version '$toolkitVersion' does not match the required version '$script:RequiredPSADTVersion'.")
    }

    $receiptRelativePath = 'PSPackageForgeReceipt.json'
    $receiptPath = Join-Path -Path $resolvedPackagePath -ChildPath $receiptRelativePath
    $fileRows = [System.Collections.Generic.List[object]]::new()
    $receiptFiles = @(Get-ChildItem -LiteralPath $resolvedPackagePath -File -Recurse -Force |
        Where-Object { $_.FullName -ne $receiptPath })
    foreach ($file in $receiptFiles) {
        $relativePath = Get-RelativePackagePath -Root $resolvedPackagePath -Path $file.FullName
        $fileRows.Add([ordered] @{
                Path = $relativePath
                Length = [int64] $file.Length
                SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            })
    }
    $fileRows.Sort([System.Comparison[object]] {
            param($left, $right)
            [System.StringComparer]::Ordinal.Compare($left['Path'], $right['Path'])
        })

    $receipt = [ordered] @{
        SchemaVersion = "$script:PackageReceiptSchemaVersion"
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Generator = [ordered] @{
            Name = 'PSPackageForge'
            Version = "$script:GeneratorVersion"
        }
        Renderer = [ordered] @{
            Name = 'PSADT'
            Version = "$script:GeneratorVersion"
        }
        SourceManifest = [ordered] @{
            FileName = [System.IO.Path]::GetFileName($manifestPath)
            SchemaVersion = '2.0'
            SHA256 = $manifestHash
        }
        Toolkit = [ordered] @{
            Name = 'PSAppDeployToolkit'
            Version = $toolkitVersion
            ModuleManifestPath = 'PSAppDeployToolkit/PSAppDeployToolkit.psd1'
        }
        Files = $fileRows.ToArray()
    }

    $json = $receipt | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $receiptPath -Value $json -Encoding UTF8 -ErrorAction Stop
    return $receiptPath
}
