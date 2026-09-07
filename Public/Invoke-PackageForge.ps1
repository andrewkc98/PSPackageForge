function Invoke-PackageForge {
    <#
        .SYNOPSIS
            Dispatches PSPackageForge workflow actions behind one flat command contract.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'Discovery JSON writes are owned by Get-InstalledAppInfo, which receives the wrapper WhatIf preference and performs its own ShouldProcess decision.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.PackageForgeResult')]
    param(
        [Parameter(Position = 0, Mandatory)]
        [ValidateSet('discover', 'scaffold', 'pack', IgnoreCase = $true)]
        [string] $Action,

        [Parameter(Position = 1)]
        [Alias('InstallerPath', 'Installer', 'PackagePath', 'DisplayNameLike')]
        [string] $Path,

        [Parameter()]
        [Alias('Output')]
        [string] $OutputPath,

        [Parameter()]
        [Alias('Discovery', 'DiscoveryData')]
        [string] $DiscoveryPath,

        [Parameter()]
        [Alias('Match')]
        [string] $DiscoveryMatchId,

        [Parameter()]
        [string] $DetectionOperator,

        [Parameter()]
        [switch] $FailOnLowConfidence,

        [Parameter()]
        [string] $PSADTModulePath,

        [Parameter()]
        [string] $IntuneWinAppUtilPath
    )

    function Get-PackageForgeResult {
        param(
            [Parameter(Mandatory)] [string] $Action,
            [Parameter(Mandatory)] [string] $Status,
            [string] $OutputPath = $null,
            [string] $DiscoveryPath = $null,
            [string] $ManifestPath = $null,
            [string] $DocumentPath = $null,
            [string] $DetectionPath = $null,
            [string] $PackagePath = $null,
            [string] $IntuneWinPath = $null,
            [object] $Readiness = $null,
            [object] $Findings = $null,
            [object] $ResultMatches = $null,
            [string] $SHA256 = $null,
            [object] $DiscoveryResult = $null,
            [object] $ScaffoldResult = $null,
            [object] $PSADTResult = $null,
            [object] $IntuneWinResult = $null,
            [string] $PSADTDisposition = 'NotApplicable'
        )

        $result = [PSCustomObject] [ordered] @{
            Action           = $Action.ToLowerInvariant()
            Status           = $Status
            OutputPath       = $OutputPath
            DiscoveryPath    = $DiscoveryPath
            ManifestPath     = $ManifestPath
            DocumentPath     = $DocumentPath
            DetectionPath    = $DetectionPath
            PackagePath      = $PackagePath
            IntuneWinPath    = $IntuneWinPath
            Readiness        = $Readiness
            Findings         = $Findings
            Matches          = $ResultMatches
            SHA256           = $SHA256
            DiscoveryResult  = $DiscoveryResult
            ScaffoldResult   = $ScaffoldResult
            PSADTResult      = $PSADTResult
            IntuneWinResult  = $IntuneWinResult
            PSADTDisposition = $PSADTDisposition
        }
        $result.PSTypeNames.Insert(0, 'PSPackageForge.PackageForgeResult')
        return $result
    }

    function ConvertTo-PackageForgeSafeName {
        param([Parameter(Mandatory)] [string] $Value)

        $invalidCharacters = New-Object 'System.Collections.Generic.HashSet[char]'
        foreach ($character in [System.IO.Path]::GetInvalidFileNameChars()) {
            [void] $invalidCharacters.Add($character)
        }
        foreach ($number in 0..31) {
            [void] $invalidCharacters.Add([char] $number)
        }
        foreach ($character in '<>:"/\|*?[]'.ToCharArray()) {
            [void] $invalidCharacters.Add($character)
        }

        $builder = New-Object System.Text.StringBuilder
        foreach ($character in $Value.ToCharArray()) {
            if (-not $invalidCharacters.Contains($character)) {
                [void] $builder.Append($character)
            }
        }

        $safeName = $builder.ToString().TrimEnd('.', ' ')
        if ([string]::IsNullOrWhiteSpace($safeName)) {
            return 'discovery'
        }

        if ($safeName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            return 'discovery'
        }

        return $safeName
    }

    $normalizedAction = $Action.ToLowerInvariant()

    if ($normalizedAction -eq 'discover') {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw 'Invoke-PackageForge discover requires a non-empty display-name wildcard pattern in -Path or -DisplayNameLike.'
        }
        if ($PSBoundParameters.ContainsKey('DiscoveryPath')) {
            throw 'Invoke-PackageForge discover does not use -DiscoveryPath. Use -OutputPath to choose the discovery JSON destination.'
        }
        if ($PSBoundParameters.ContainsKey('DiscoveryMatchId')) {
            throw 'Invoke-PackageForge discover does not select a match. Pass -DiscoveryMatchId to scaffold with a discovery file.'
        }
        if ($PSBoundParameters.ContainsKey('DetectionOperator')) {
            throw 'Invoke-PackageForge discover does not use -DetectionOperator. Pass it to scaffold.'
        }
        if ($PSBoundParameters.ContainsKey('FailOnLowConfidence')) {
            throw 'Invoke-PackageForge discover does not use -FailOnLowConfidence. Pass it to scaffold.'
        }
        if ($PSBoundParameters.ContainsKey('PSADTModulePath')) {
            throw 'Invoke-PackageForge discover does not use -PSADTModulePath. Pass it to pack.'
        }
        if ($PSBoundParameters.ContainsKey('IntuneWinAppUtilPath')) {
            throw 'Invoke-PackageForge discover does not use -IntuneWinAppUtilPath. Pass it to pack.'
        }

        $pattern = $Path
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $safePattern = ConvertTo-PackageForgeSafeName -Value $pattern
            $destination = Join-Path (Join-Path (Get-Location).ProviderPath 'Output') ($safePattern + '.discovery.json')
        }
        else {
            $destination = $OutputPath
        }

        if ($WhatIfPreference) {
            $discoveryResult = Get-InstalledAppInfo -DisplayNameLike $pattern -OutputPath $destination -WhatIf
            $status = 'WhatIf'
        }
        else {
            $discoveryResult = Get-InstalledAppInfo -DisplayNameLike $pattern -OutputPath $destination
            $status = 'Completed'
        }

        return Get-PackageForgeResult `
            -Action $normalizedAction `
            -Status $status `
            -DiscoveryPath $destination `
            -Findings $discoveryResult.Findings `
            -ResultMatches $discoveryResult.Matches `
            -DiscoveryResult $discoveryResult `
            -PSADTDisposition 'NotApplicable'
    }

    if ($normalizedAction -eq 'scaffold') {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw 'Invoke-PackageForge scaffold requires an installer file in -Path or its alias.'
        }
        if ($PSBoundParameters.ContainsKey('PSADTModulePath')) {
            throw 'Invoke-PackageForge scaffold does not use -PSADTModulePath. Pass it to pack.'
        }
        if ($PSBoundParameters.ContainsKey('IntuneWinAppUtilPath')) {
            throw 'Invoke-PackageForge scaffold does not use -IntuneWinAppUtilPath. Pass it to pack.'
        }
        if (-not [string]::IsNullOrWhiteSpace($DiscoveryMatchId) -and [string]::IsNullOrWhiteSpace($DiscoveryPath)) {
            throw 'Invoke-PackageForge scaffold: -DiscoveryMatchId requires -DiscoveryPath.'
        }

        $resolvedPath = $null
        try {
            $resolvedPath = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
            if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) { throw '' }
        }
        catch {
            throw "Invoke-PackageForge scaffold requires an existing installer file. Not found: $Path"
        }
        if (-not [string]::IsNullOrWhiteSpace($DiscoveryPath)) {
            $resolvedDiscovery = $null
            try {
                $resolvedDiscovery = (Get-Item -LiteralPath $DiscoveryPath -ErrorAction Stop).FullName
                if (-not (Test-Path -LiteralPath $resolvedDiscovery -PathType Leaf)) { throw '' }
            }
            catch {
                throw "Invoke-PackageForge scaffold requires an existing discovery file. Not found: $DiscoveryPath"
            }
        }
        else {
            $resolvedDiscovery = $null
        }

        $installerBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $output = Join-Path (Join-Path (Get-Location).ProviderPath 'Output') $installerBaseName
        }
        else {
            $output = $OutputPath
        }
        # [IO.Path]::GetFullPath(string) resolves relative paths against the process
        # working directory, which can differ from PowerShell's current location after
        # Set-Location. Resolve through the PowerShell provider so an explicit relative
        # output keeps the caller's intended meaning.
        $output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($output)

        if (Test-Path -LiteralPath $output) {
            $existingContent = @(Get-ChildItem -LiteralPath $output -Force | Select-Object -First 1)
            if ($existingContent.Count -gt 0) {
                throw "Invoke-PackageForge scaffold: output target exists and is non-empty. Refusing to overwrite: $output"
            }
        }

        if ($WhatIfPreference) {
            return Get-PackageForgeResult `
                -Action $normalizedAction `
                -Status 'WhatIf' `
                -OutputPath $output `
                -PSADTDisposition 'NotApplicable'
        }

        $scaffoldParams = @{
            Path       = $resolvedPath
            OutputPath = $output
        }
        if ($PSBoundParameters.ContainsKey('DiscoveryPath')) { $scaffoldParams['DiscoveryData'] = $DiscoveryPath }
        if ($PSBoundParameters.ContainsKey('DiscoveryMatchId')) { $scaffoldParams['DiscoveryMatchId'] = $DiscoveryMatchId }
        if ($PSBoundParameters.ContainsKey('DetectionOperator')) { $scaffoldParams['DetectionOperator'] = $DetectionOperator }
        if ($PSBoundParameters.ContainsKey('FailOnLowConfidence')) { $scaffoldParams['FailOnLowConfidence'] = [bool] $FailOnLowConfidence }

        $scaffoldResult = New-PackageScaffold @scaffoldParams
        $scaffoldStatus = 'Completed'
        if ([string] $scaffoldResult.Readiness -eq 'NeedsInput') { $scaffoldStatus = 'NeedsInput' }
        $scaffoldCanonicalOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($scaffoldResult.OutputPath)

        return Get-PackageForgeResult `
            -Action $normalizedAction `
            -Status $scaffoldStatus `
            -OutputPath $scaffoldCanonicalOutput `
            -ManifestPath $scaffoldResult.ManifestPath `
            -DocumentPath $scaffoldResult.DocumentPath `
            -DetectionPath $scaffoldResult.DetectionPath `
            -PackagePath (Join-Path $scaffoldCanonicalOutput 'Package') `
            -Readiness $scaffoldResult.Readiness `
            -Findings @($scaffoldResult.InstallerInfo.Findings) `
            -ScaffoldResult $scaffoldResult `
            -PSADTDisposition 'NotApplicable'
    }

    if ($normalizedAction -eq 'pack') {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw 'Invoke-PackageForge pack requires an existing scaffold root directory in -Path or -PackagePath.'
        }
        if ($PSBoundParameters.ContainsKey('DiscoveryPath')) {
            throw 'Invoke-PackageForge pack does not use -DiscoveryPath. It was consumed during scaffold.'
        }
        if ($PSBoundParameters.ContainsKey('DiscoveryMatchId')) {
            throw 'Invoke-PackageForge pack does not use -DiscoveryMatchId. It was consumed during scaffold.'
        }
        if ($PSBoundParameters.ContainsKey('DetectionOperator')) {
            throw 'Invoke-PackageForge pack does not use -DetectionOperator. Pass it to scaffold.'
        }
        if ($PSBoundParameters.ContainsKey('FailOnLowConfidence')) {
            throw 'Invoke-PackageForge pack does not use -FailOnLowConfidence. Pass it to scaffold.'
        }
        if ($PSBoundParameters.ContainsKey('OutputPath')) {
            throw 'Invoke-PackageForge pack does not write outside the scaffold root and does not use -OutputPath or -Output.'
        }

        $canonicalRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        if (-not (Test-Path -LiteralPath $canonicalRoot -PathType Container)) {
            throw "Invoke-PackageForge pack requires an existing scaffold root directory. Not a directory: $Path"
        }

        $manifestPath = Join-Path -Path $canonicalRoot -ChildPath 'PackageManifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Invoke-PackageForge pack requires PackageManifest.json in the scaffold root. Not found: $manifestPath"
        }

        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
        catch {
            throw "Invoke-PackageForge pack: PackageManifest.json is not valid JSON: $($_.Exception.Message)"
        }

        if ("$($manifest.SchemaVersion)" -ne '1.0') {
            throw "Invoke-PackageForge pack: PackageManifest.json schema '$($manifest.SchemaVersion)' is not supported; expected '1.0'."
        }

        if ("$($manifest.Readiness)" -eq 'NeedsInput') {
            throw "Invoke-PackageForge pack: PackageManifest.json readiness is 'NeedsInput'. Resolve the blocking findings, then scaffold again into a new empty root; for an intentional refresh use the advanced New-PSADTPackage primitive."
        }

        $installer = $manifest.Installer
        $manifestInstallerPath = "$($installer.Path)"
        $manifestInstallerFileName = "$($installer.FileName)"
        $manifestExpectedHash = "$($installer.SHA256)"

        $packagePath = Join-Path -Path $canonicalRoot -ChildPath 'Package'
        if ((Test-Path -LiteralPath $packagePath) -and -not (Test-Path -LiteralPath $packagePath -PathType Container)) {
            throw "Invoke-PackageForge pack: Package exists but is not a directory, so it is partial or corrupt. Reuse is refused and the content will not be deleted or replaced: $packagePath"
        }
        if (Test-Path -LiteralPath $packagePath -PathType Container) {
            $packageEntries = @(Get-ChildItem -LiteralPath $packagePath -Force)
        }
        else {
            $packageEntries = @()
        }
        $packageEmpty = ($packageEntries.Count -eq 0)

        # Read-only reuse check: a Package directory (or a non-empty one) is reusable only
        # when it is a complete, valid PSAppDeployToolkit package whose installer and
        # packaged installer both hash to the manifest. This intentionally mirrors the
        # Intune preflight so the dispatcher can decide Created versus Reused.
        function Test-PackageForgeReusablePackage {
            param(
                [Parameter(Mandatory)] [string] $Root,
                [Parameter(Mandatory)] [string] $PackagePath,
                [Parameter(Mandatory)] [string] $InstallerPathText,
                [Parameter(Mandatory)] [string] $InstallerFileName,
                [Parameter(Mandatory)] [string] $ExpectedHash
            )

            $separators = [char[]] @('\', '/')
            if ([string]::IsNullOrWhiteSpace($InstallerPathText) -or
                [string]::IsNullOrWhiteSpace($InstallerFileName) -or
                $InstallerFileName.IndexOfAny($separators) -ge 0 -or
                $InstallerPathText.IndexOfAny($separators) -ge 0 -or
                -not [string]::Equals($InstallerPathText, $InstallerFileName, [StringComparison]::OrdinalIgnoreCase) -or
                [System.IO.Path]::IsPathRooted($InstallerPathText) -or
                [System.IO.Path]::IsPathRooted($InstallerFileName) -or
                [string]::IsNullOrWhiteSpace($ExpectedHash)) {
                throw 'Invoke-PackageForge pack: PackageManifest.json is missing a complete direct-child Installer.Path/Installer.FileName and Installer.SHA256, so the existing Package cannot be validated for reuse. The existing content is refused and will not be deleted or replaced. Scaffold into a new empty root, or use New-PSADTPackage for an intentional refresh.'
            }

            $stagedPath = Join-Path -Path $Root -ChildPath $InstallerPathText
            if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) {
                throw "Invoke-PackageForge pack: the staged installer '$InstallerFileName' was not found beside PackageManifest.json, so the existing Package is not complete and valid. Reuse is refused and the content will not be deleted or replaced. Scaffold into a new empty root, or use New-PSADTPackage for an intentional refresh."
            }
            $stagedHash = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash
            if (-not [string]::Equals($stagedHash, $ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Invoke-PackageForge pack: staged installer hash mismatch. Expected $ExpectedHash, got $stagedHash. The existing Package is not complete and valid; reuse is refused and the content will not be deleted or replaced."
            }

            $setupExe = Join-Path -Path $PackagePath -ChildPath 'Invoke-AppDeployToolkit.exe'
            if (-not (Test-Path -LiteralPath $setupExe -PathType Leaf)) {
                throw "Invoke-PackageForge pack: Package is missing Invoke-AppDeployToolkit.exe, so it is partial or corrupt. Reuse is refused and the content will not be deleted or replaced. Delete the Package directory and scaffold into a new empty root, or use New-PSADTPackage for an intentional refresh."
            }

            $setupScript = Join-Path -Path $PackagePath -ChildPath 'Invoke-AppDeployToolkit.ps1'
            if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
                throw "Invoke-PackageForge pack: Package is missing Invoke-AppDeployToolkit.ps1, so it is partial or corrupt. Reuse is refused and the content will not be deleted or replaced. Delete the Package directory and scaffold into a new empty root, or use New-PSADTPackage for an intentional refresh."
            }

            $packagedPath = Join-Path -Path (Join-Path -Path $PackagePath -ChildPath 'Files') -ChildPath $InstallerFileName
            if (-not (Test-Path -LiteralPath $packagedPath -PathType Leaf)) {
                throw "Invoke-PackageForge pack: Package is missing the packaged installer '$InstallerFileName' under its Files directory, so it is partial or corrupt. Reuse is refused and the content will not be deleted or replaced. Delete the Package directory and scaffold into a new empty root, or use New-PSADTPackage for an intentional refresh."
            }
            $packagedHash = (Get-FileHash -LiteralPath $packagedPath -Algorithm SHA256).Hash
            if (-not [string]::Equals($packagedHash, $ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Invoke-PackageForge pack: packaged installer hash mismatch. Expected $ExpectedHash, got $packagedHash. Reuse is refused and the content will not be deleted or replaced. Delete the Package directory and scaffold into a new empty root, or use New-PSADTPackage for an intentional refresh."
            }
        }

        if ($WhatIfPreference) {
            if ($packageEmpty) {
                $psadtWhatIfParams = @{
                    ManifestPath = $manifestPath
                    WhatIf       = $true
                }
                if ($PSBoundParameters.ContainsKey('PSADTModulePath')) { $psadtWhatIfParams['PSADTModulePath'] = $PSADTModulePath }
                $psadtPreview = New-PSADTPackage @psadtWhatIfParams
                return Get-PackageForgeResult `
                    -Action $normalizedAction `
                    -Status 'WhatIf' `
                    -OutputPath $canonicalRoot `
                    -ManifestPath $manifestPath `
                    -PackagePath $packagePath `
                    -Readiness $manifest.Readiness `
                    -PSADTResult $psadtPreview `
                    -PSADTDisposition 'WouldCreate'
            }

            Test-PackageForgeReusablePackage `
                -Root $canonicalRoot `
                -PackagePath $packagePath `
                -InstallerPathText $manifestInstallerPath `
                -InstallerFileName $manifestInstallerFileName `
                -ExpectedHash $manifestExpectedHash

            $intuneWhatIfParams = @{
                OutputPath = $canonicalRoot
                WhatIf     = $true
            }
            if ($PSBoundParameters.ContainsKey('IntuneWinAppUtilPath')) { $intuneWhatIfParams['IntuneWinAppUtilPath'] = $IntuneWinAppUtilPath }
            $intunePreview = New-IntuneWinPackage @intuneWhatIfParams
            return Get-PackageForgeResult `
                    -Action $normalizedAction `
                    -Status 'WhatIf' `
                    -OutputPath $canonicalRoot `
                    -ManifestPath $manifestPath `
                    -PackagePath $packagePath `
                    -Readiness $manifest.Readiness `
                    -IntuneWinResult $intunePreview `
                    -PSADTDisposition 'WouldReuse'
        }

        $psadtResult = $null
        $psadtDisposition = 'Created'
        if ($packageEmpty) {
            $psadtParams = @{
                ManifestPath = $manifestPath
            }
            if ($PSBoundParameters.ContainsKey('PSADTModulePath')) { $psadtParams['PSADTModulePath'] = $PSADTModulePath }
            $psadtResult = New-PSADTPackage @psadtParams
        }
        else {
            Test-PackageForgeReusablePackage `
                -Root $canonicalRoot `
                -PackagePath $packagePath `
                -InstallerPathText $manifestInstallerPath `
                -InstallerFileName $manifestInstallerFileName `
                -ExpectedHash $manifestExpectedHash
            $psadtDisposition = 'Reused'
        }

        $intuneParams = @{
            OutputPath = $canonicalRoot
        }
        if ($PSBoundParameters.ContainsKey('IntuneWinAppUtilPath')) { $intuneParams['IntuneWinAppUtilPath'] = $IntuneWinAppUtilPath }
        $intuneResult = New-IntuneWinPackage @intuneParams

        $status = 'Completed'
        if ("$($intuneResult.Status)" -eq 'InstructionsOnly') { $status = 'InstructionsOnly' }
        $intuneWinPath = $null
        $artifactHash = $null
        if ("$($intuneResult.Status)" -eq 'Built') {
            $intuneWinPath = "$($intuneResult.IntuneWinPath)"
            $artifactHash = "$($intuneResult.SHA256)"
        }

        return Get-PackageForgeResult `
            -Action $normalizedAction `
            -Status $status `
            -OutputPath $canonicalRoot `
            -ManifestPath $manifestPath `
            -PackagePath $packagePath `
            -Readiness $manifest.Readiness `
            -IntuneWinPath $intuneWinPath `
            -SHA256 $artifactHash `
            -Findings @($intuneResult.Findings) `
            -PSADTResult $psadtResult `
            -IntuneWinResult $intuneResult `
            -PSADTDisposition $psadtDisposition
    }
}
