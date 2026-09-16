function Read-PackageForgeManifest {
    <#
        Reads and validates the authoritative schema-2 manifest without changing it or
        touching any package output.  All consumers use this boundary so path, hash, and
        command validation has one implementation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ManifestPath,

        [Parameter()]
        [switch] $RequireRunnable
    )

    function Get-RequiredProperty {
        param([object] $InputObject, [string] $Name, [string] $Description)
        $value = Get-DocumentOptionalProperty -InputObject $InputObject -Name $Name
        if ($null -eq $value) {
            throw [System.IO.InvalidDataException]::new("PackageManifest.json is missing $Description.")
        }
        return $value
    }

    function ConvertTo-CanonicalFullPath {
        param([string] $Path)
        return [System.IO.Path]::GetFullPath(
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    }

    function Test-ReservedExitCode {
        param([int] $Code)
        if ($Code -eq [int]::MinValue) {
            throw [System.IO.InvalidDataException]::new(
                'PackageManifest.json uses reserved exit code -2147483648.')
        }
    }

    function ConvertTo-StrictExitCode {
        param([object] $Value, [string] $Description)
        if ($Value -is [bool] -or $Value -is [string] -or $null -eq $Value) {
            throw [System.IO.InvalidDataException]::new("$Description must be an integer.")
        }
        try {
            $decimalValue = [decimal] $Value
            if ([decimal]::Truncate($decimalValue) -ne $decimalValue -or
                $decimalValue -lt [int]::MinValue -or $decimalValue -gt [int]::MaxValue) {
                throw 'out of range or fractional'
            }
            return [int] $decimalValue
        }
        catch {
            throw [System.IO.InvalidDataException]::new("$Description must be a 32-bit integer.")
        }
    }

    function Get-CommandExitCode {
        param([object] $Command, [string] $Operation, [object[]] $ReturnCodeMap, [bool] $AllowUnresolved)

        if ($null -eq $Command) {
            if ($AllowUnresolved) { return }
            throw [System.IO.InvalidDataException]::new("PackageManifest.json does not contain a resolved $Operation command.")
        }
        if ($Command -isnot [pscustomobject] -and $Command -isnot [hashtable]) {
            throw [System.IO.InvalidDataException]::new("The manifest $Operation command must be a structured object.")
        }
        $executable = Get-DocumentOptionalProperty -InputObject $Command -Name 'Executable'
        if ($executable -isnot [string] -or [string]::IsNullOrWhiteSpace($executable)) {
            throw [System.IO.InvalidDataException]::new("The manifest $Operation command must contain a nonempty string Executable.")
        }
        $argumentProperty = @($Command.PSObject.Properties.Match('ArgumentList'))
        if ($argumentProperty.Count -ne 1 -or $argumentProperty[0].Value -isnot [array]) {
            throw [System.IO.InvalidDataException]::new("The manifest $Operation command ArgumentList must be an array of strings.")
        }
        $rawArguments = $argumentProperty[0].Value
        foreach ($argument in @($rawArguments)) {
            if ($argument -isnot [string]) {
                throw [System.IO.InvalidDataException]::new("The manifest $Operation command ArgumentList must contain only strings.")
            }
        }
        $workingDirectory = Get-DocumentOptionalProperty -InputObject $Command -Name 'WorkingDirectory'
        if ($null -ne $workingDirectory -and $workingDirectory -isnot [string]) {
            throw [System.IO.InvalidDataException]::new("The manifest $Operation command WorkingDirectory must be a string or null.")
        }

        $codeProperty = @($Command.PSObject.Properties.Match('ExpectedExitCodes'))
        $rawCodes = $null
        if ($codeProperty.Count -eq 1) { $rawCodes = $codeProperty[0].Value }
        $codes = @($rawCodes)
        if ($codeProperty.Count -ne 1 -or $rawCodes -isnot [array] -or $codes.Count -eq 0) {
            throw [System.IO.InvalidDataException]::new(
                "The manifest $Operation command must contain a nonempty ExpectedExitCodes set.")
        }
        $normalised = [System.Collections.Generic.List[int]]::new()
        foreach ($rawCode in $codes) {
            $code = ConvertTo-StrictExitCode -Value $rawCode -Description "The manifest $Operation command expected exit code '$rawCode'"
            Test-ReservedExitCode -Code $code
            if ($normalised.Contains($code)) {
                throw [System.IO.InvalidDataException]::new("The manifest $Operation command repeats expected exit code $code.")
            }
            $normalised.Add($code)
        }

        foreach ($code in $normalised) {
            $matchingRows = @($ReturnCodeMap | Where-Object {
                    $mapCode = Get-DocumentOptionalProperty -InputObject $_ -Name 'Code'
                    $null -ne $mapCode -and (ConvertTo-StrictExitCode -Value $mapCode -Description 'ReturnCodeMap.Code') -eq $code
                })
            if ($matchingRows.Count -ne 1) {
                throw [System.IO.InvalidDataException]::new(
                    "Expected exit code $code for the $Operation command must have exactly one ReturnCodeMap entry.")
            }
            $classification = Get-DocumentOptionalProperty -InputObject $matchingRows[0] -Name 'Classification'
            if ($classification -notin @('Success', 'SuccessRebootRequired', 'SuccessRebootInitiated')) {
                throw [System.IO.InvalidDataException]::new(
                    "Expected exit code $code for the $Operation command is classified as '$classification', not as success or reboot success.")
            }
        }
        return [int[]] @($normalised)
    }

    $canonicalManifestPath = ConvertTo-CanonicalFullPath -Path $ManifestPath
    if (-not (Test-Path -LiteralPath $canonicalManifestPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("PackageManifest.json was not found: '$canonicalManifestPath'.")
    }
    $scaffoldRoot = ConvertTo-CanonicalFullPath -Path ([System.IO.Directory]::GetParent($canonicalManifestPath).FullName)

    try {
        $manifest = Get-Content -LiteralPath $canonicalManifestPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new("PackageManifest.json is malformed JSON: $($_.Exception.Message)")
    }

    if ("$(Get-RequiredProperty -InputObject $manifest -Name 'SchemaVersion' -Description 'SchemaVersion')" -ne '2.0') {
        throw [System.IO.InvalidDataException]::new("PackageManifest.json schema '$($manifest.SchemaVersion)' is not supported; expected '2.0'.")
    }
    $generator = Get-RequiredProperty -InputObject $manifest -Name 'Generator' -Description 'Generator metadata'
    if ("$(Get-RequiredProperty -InputObject $generator -Name 'Name' -Description 'Generator.Name')" -ne 'PSPackageForge') {
        throw [System.IO.InvalidDataException]::new('PackageManifest.json Generator.Name must be PSPackageForge.')
    }
    if ("$(Get-RequiredProperty -InputObject $generator -Name 'Version' -Description 'Generator.Version')" -ne "$script:GeneratorVersion") {
        throw [System.IO.InvalidDataException]::new("PackageManifest.json Generator.Version must be exactly $script:GeneratorVersion.")
    }
    $requiredVersionText = "$(Get-RequiredProperty -InputObject $generator -Name 'RequiredPSADTVersion' -Description 'Generator.RequiredPSADTVersion')"
    if ($requiredVersionText -ne "$script:RequiredPSADTVersion") {
        throw [System.IO.InvalidDataException]::new("PackageManifest.json requires PSADT '$requiredVersionText'; exactly '$script:RequiredPSADTVersion' is supported.")
    }

    $readiness = "$(Get-RequiredProperty -InputObject $manifest -Name 'Readiness' -Description 'Readiness')"
    if ($readiness -notin @('NeedsInput', 'ReviewRequired')) {
        throw [System.IO.InvalidDataException]::new("PackageManifest.json readiness '$readiness' is not supported.")
    }
    if ($RequireRunnable -and $readiness -ne 'ReviewRequired') {
        throw [System.InvalidOperationException]::new(
            "PackageManifest.json readiness is '$readiness'; a runnable consumer requires 'ReviewRequired'.")
    }

    $installer = Get-RequiredProperty -InputObject $manifest -Name 'Installer' -Description 'Installer metadata'
    $pathText = "$(Get-RequiredProperty -InputObject $installer -Name 'Path' -Description 'Installer.Path')"
    $fileName = "$(Get-RequiredProperty -InputObject $installer -Name 'FileName' -Description 'Installer.FileName')"
    $separators = [char[]] @('\', '/')
    if ([string]::IsNullOrWhiteSpace($pathText) -or [string]::IsNullOrWhiteSpace($fileName) -or
        $pathText -cne $fileName -or $pathText.IndexOfAny($separators) -ge 0 -or
        $fileName.IndexOfAny($separators) -ge 0 -or [System.IO.Path]::IsPathRooted($pathText) -or
        $fileName -in @('.', '..')) {
        throw [System.IO.InvalidDataException]::new(
            'PackageManifest.json Installer.Path and Installer.FileName must exactly match one direct child filename.')
    }

    $expectedHash = "$(Get-RequiredProperty -InputObject $installer -Name 'SHA256' -Description 'Installer.SHA256')"
    if ($expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
        throw [System.IO.InvalidDataException]::new('PackageManifest.json Installer.SHA256 must be exactly 64 hexadecimal characters.')
    }
    $installerPath = ConvertTo-CanonicalFullPath -Path (Join-Path -Path $scaffoldRoot -ChildPath $fileName)
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("The staged installer was not found: '$installerPath'.")
    }
    $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($actualHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [System.IO.InvalidDataException]::new("Staged installer hash mismatch. Expected $expectedHash, got $actualHash.")
    }

    $packageSpec = Get-RequiredProperty -InputObject $manifest -Name 'PackageSpec' -Description 'PackageSpec'
    $returnCodeMap = @(Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'ReturnCodeMap')
    if ($returnCodeMap.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('PackageManifest.json PackageSpec.ReturnCodeMap must be nonempty.')
    }
    $seenMapCodes = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($row in $returnCodeMap) {
        $rawCode = Get-DocumentOptionalProperty -InputObject $row -Name 'Code'
        if ($null -eq $rawCode) { throw [System.IO.InvalidDataException]::new('PackageManifest.json ReturnCodeMap contains an entry without Code.') }
        $mapCode = ConvertTo-StrictExitCode -Value $rawCode -Description "PackageManifest.json ReturnCodeMap.Code '$rawCode'"
        Test-ReservedExitCode -Code $mapCode
        if (-not $seenMapCodes.Add($mapCode)) {
            throw [System.IO.InvalidDataException]::new("PackageManifest.json ReturnCodeMap repeats Code $mapCode.")
        }
        $classification = Get-DocumentOptionalProperty -InputObject $row -Name 'Classification'
        if ($classification -notin @('Failure', 'Success', 'SuccessRebootRequired', 'SuccessRebootInitiated', 'Retry')) {
            throw [System.IO.InvalidDataException]::new("PackageManifest.json ReturnCodeMap has unsupported Classification '$classification'.")
        }
    }
    $allowUnresolved = (-not $RequireRunnable -and $readiness -eq 'NeedsInput')
    [void] (Get-CommandExitCode -Command (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'InstallCommand') -Operation 'Install' -ReturnCodeMap $returnCodeMap -AllowUnresolved $allowUnresolved)
    [void] (Get-CommandExitCode -Command (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'UninstallCommand') -Operation 'Uninstall' -ReturnCodeMap $returnCodeMap -AllowUnresolved $allowUnresolved)

    [PSCustomObject] ([ordered] @{
        ManifestPath          = $canonicalManifestPath
        ScaffoldRoot          = $scaffoldRoot
        Manifest              = $manifest
        ManifestSHA256        = (Get-FileHash -LiteralPath $canonicalManifestPath -Algorithm SHA256).Hash
        InstallerPath          = $installerPath
        RequiredPSADTVersion  = ([Version] $requiredVersionText).ToString()
    })
}
