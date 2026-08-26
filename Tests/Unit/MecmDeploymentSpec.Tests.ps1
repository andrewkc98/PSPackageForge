<#
    ConvertTo-MecmDeploymentSpec / New-MecmDeploymentSpec -- the README roadmap's
    "MECM and Intune deployment specifications" renderer. Pure rendering over an already
    -parsed PackageManifest.json, exactly like ConvertTo-PackageDocumentContent, so these
    tests exercise it the same way Rendering.Tests.ps1 exercises the document renderer: real
    committed manifest first, then small hand-built manifest shapes for the branches a real
    example does not exercise.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {

    BeforeAll {
        $script:ModuleRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:SevenZipManifestPath = Join-Path $script:ModuleRoot 'Examples\SevenZip\PackageManifest.json'
        $script:SevenZipManifest   = Get-Content -LiteralPath $script:SevenZipManifestPath -Raw | ConvertFrom-Json

        # A minimal, hand-built manifest shape for a per-user application -- the "Obsidian
        # shape" this project's README names as the per-user-context regression case
        # (SelectedContext User, RequiresLogonWhenUserContext true). Built as a JSON
        # round-trip so property access behaves exactly like a real parsed manifest under
        # Set-StrictMode -Version Latest, not like a hashtable.
        $obsidianJson = @'
{
    "SchemaVersion": "1.0",
    "GeneratedAtUtc": "2026-08-21T00:00:00.0000000Z",
    "Installer": {
        "ProductName": "Obsidian",
        "Manufacturer": "Dynalist Inc.",
        "ProductVersionRaw": "1.5.3.0",
        "SHA256": "1111111111111111111111111111111111111111111111111111111111111111"
    },
    "PackageSpec": {
        "InstallCommand": { "Executable": "Obsidian.Setup.exe", "ArgumentList": ["--silent"], "ExpectedExitCodes": [0] },
        "UninstallCommand": { "Executable": "%LOCALAPPDATA%\\Obsidian\\Uninstall Obsidian.exe", "ArgumentList": ["/S"], "ExpectedExitCodes": [0] },
        "SelectedContext": "User",
        "RequiresLogonWhenUserContext": true,
        "RunDetectionAs32Bit": false,
        "DetectionSpec": [
            { "Kind": "File", "Path": "%LOCALAPPDATA%\\Programs\\Obsidian", "FileName": "Obsidian.exe", "Operator": "Exists", "Confidence": "Medium" }
        ],
        "ReturnCodeMap": [
            { "Code": 0, "Meaning": "Success", "Classification": "Success" }
        ]
    },
    "Readiness": "ReviewRequired"
}
'@
        $script:ObsidianManifest = $obsidianJson | ConvertFrom-Json

        # A minimal EXE-installer manifest with no ProductCode at all and a File-kind,
        # Medium-confidence detection -- the "KiCad shape" this project's README names for
        # NSIS/versioned-path installers, to prove no MSI-specific assumption leaks into the
        # MECM rendering just because most fixtures happen to be MSI.
        $kicadJson = @'
{
    "SchemaVersion": "1.0",
    "GeneratedAtUtc": "2026-08-21T00:00:00.0000000Z",
    "Installer": {
        "ProductName": "KiCad 8.0.0",
        "Manufacturer": "KiCad Developers",
        "ProductVersionRaw": "8.0.0",
        "SHA256": "2222222222222222222222222222222222222222222222222222222222222222"
    },
    "PackageSpec": {
        "InstallCommand": { "Executable": "kicad-8.0.0-x86_64.exe", "ArgumentList": ["/S"], "ExpectedExitCodes": [0] },
        "UninstallCommand": { "Executable": "C:\\Program Files\\KiCad\\8.0\\uninstall.exe", "ArgumentList": ["/S"], "ExpectedExitCodes": [0] },
        "SelectedContext": "System",
        "RequiresLogonWhenUserContext": false,
        "RunDetectionAs32Bit": false,
        "DetectionSpec": [
            { "Kind": "File", "Path": "C:\\Program Files\\KiCad\\8.0\\bin", "FileName": "kicad.exe", "Operator": "GreaterOrEqual", "Value": "8.0.0.0", "Confidence": "Medium" }
        ],
        "ReturnCodeMap": [
            { "Code": 0, "Meaning": "Success", "Classification": "Success" }
        ]
    },
    "Readiness": "ReviewRequired"
}
'@
        $script:KiCadManifest = $kicadJson | ConvertFrom-Json

        # No DetectionSpec entries at all -- the unresolved-detection branch.
        $unresolvedJson = @'
{
    "SchemaVersion": "1.0",
    "GeneratedAtUtc": "2026-08-21T00:00:00.0000000Z",
    "Installer": {
        "ProductName": "Widget",
        "Manufacturer": "Contoso",
        "ProductVersionRaw": "1.0.0",
        "SHA256": "3333333333333333333333333333333333333333333333333333333333333333"
    },
    "PackageSpec": {
        "InstallCommand": { "Executable": "setup.exe", "ArgumentList": ["/S"], "ExpectedExitCodes": [0] },
        "UninstallCommand": { "Executable": "setup.exe", "ArgumentList": ["/S", "/uninstall"], "ExpectedExitCodes": [0] },
        "SelectedContext": "System",
        "RequiresLogonWhenUserContext": false,
        "RunDetectionAs32Bit": false,
        "DetectionSpec": [],
        "ReturnCodeMap": [
            { "Code": 0, "Meaning": "Success", "Classification": "Success" }
        ]
    },
    "Readiness": "NeedsInput"
}
'@
        $script:UnresolvedDetectionManifest = $unresolvedJson | ConvertFrom-Json
    }

    Describe 'ConvertTo-MecmDeploymentSpec' {

        Context 'rendering the committed SevenZip example manifest' {

            BeforeAll {
                $script:Spec = ConvertTo-MecmDeploymentSpec -Manifest $script:SevenZipManifest
            }

            It 'maps installer identity onto Application' {
                $script:Spec.Application.LocalizedDisplayName | Should -Be '7-Zip 26.02 (x64 edition)'
                $script:Spec.Application.Publisher             | Should -Be 'Igor Pavlov'
                $script:Spec.Application.SoftwareVersion        | Should -Be '26.02.00.0'
            }

            It 'emits exactly one Script deployment type' {
                $script:Spec.DeploymentType.Count           | Should -Be 1
                $script:Spec.DeploymentType[0].Technology     | Should -Be 'Script'
                $script:Spec.DeploymentType[0].Name           | Should -Be '7-Zip 26.02 (x64 edition) - Script Installer'
            }

            It 'invokes the canonical PSADT wrapper while payload commands remain in the manifest' {
                $script:Spec.DeploymentType[0].InstallCommand |
                    Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent -AllowRebootPassThru'
                $script:Spec.DeploymentType[0].UninstallCommand |
                    Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent -AllowRebootPassThru'

                $script:SevenZipManifest.PackageSpec.InstallCommand.Executable | Should -Be 'msiexec.exe'
                $script:SevenZipManifest.PackageSpec.UninstallCommand.Executable | Should -Be 'msiexec.exe'
            }

            It 'renders the shared detection script as the Script detection method' {
                $detection = $script:Spec.DeploymentType[0].Detection
                $detection.Method         | Should -Be 'Script'
                $detection.ScriptFile     | Should -Be 'Detect-Application.ps1'
                $detection.ScriptLanguage | Should -Be 'PowerShell'
                $detection.RunAs32Bit     | Should -Be $script:SevenZipManifest.PackageSpec.RunDetectionAs32Bit
            }

            It 'maps every return code to the correct MECM CodeType' {
                $codes = $script:Spec.DeploymentType[0].ReturnCodes
                ($codes | Where-Object { $_.Code -eq 0 }).CodeType    | Should -Be 'Success'
                ($codes | Where-Object { $_.Code -eq 3010 }).CodeType | Should -Be 'SoftReboot'
                ($codes | Where-Object { $_.Code -eq 1641 }).CodeType | Should -Be 'HardReboot'
                ($codes | Where-Object { $_.Code -eq 1618 }).CodeType | Should -Be 'FastRetry'
            }

            It 'passes the manifest Readiness through unchanged' {
                $script:Spec.Readiness | Should -Be $script:SevenZipManifest.Readiness
            }

            It 'ties the spec back to its source manifest without re-hashing a file' {
                # Compared against the literal text committed in Examples/SevenZip/PackageManifest.json,
                # not the parsed $script:SevenZipManifest property -- PowerShell 7's ConvertFrom-Json
                # parses that ISO-8601-shaped string into a [DateTime], and round-tripping a DateTime
                # back through Should -Be's own formatting would make this assertion depend on which
                # PowerShell edition is running it rather than on what ConvertTo-MecmDeploymentSpec did.
                $script:Spec.SourceManifest.SchemaVersion   | Should -Be '1.0'
                $script:Spec.SourceManifest.GeneratedAtUtc  | Should -Be '2026-08-20T13:07:01.3761677Z'
                $script:Spec.SourceManifest.InstallerSHA256 | Should -Be $script:SevenZipManifest.Installer.SHA256
            }
        }

        Context 'ContentSourcePath operator input' {

            It 'emits null and MECM_CONTENT_SOURCE_UNSET when no content source is supplied' {
                $spec = ConvertTo-MecmDeploymentSpec -Manifest $script:SevenZipManifest

                $spec.DeploymentType[0].ContentSourcePath | Should -BeNullOrEmpty
                ($spec.Findings | Where-Object { $_.Code -eq 'MECM_CONTENT_SOURCE_UNSET' }).Severity |
                    Should -Be 'Warning'
            }

            It 'carries an operator-supplied content source through with no finding' {
                $spec = ConvertTo-MecmDeploymentSpec -Manifest $script:SevenZipManifest -ContentSourcePath '\\contoso\ContentSource\7-Zip'

                $spec.DeploymentType[0].ContentSourcePath | Should -Be '\\contoso\ContentSource\7-Zip'
                @($spec.Findings | Where-Object { $_.Code -eq 'MECM_CONTENT_SOURCE_UNSET' }).Count | Should -Be 0
            }
        }

        Context 'runtime operator inputs' {

            It 'defaults MaxRuntimeMinutes to 120 with MECM_MAX_RUNTIME_DEFAULTED' {
                $spec = ConvertTo-MecmDeploymentSpec -Manifest $script:SevenZipManifest

                $spec.DeploymentType[0].MaxRuntimeMinutes       | Should -Be 120
                $spec.DeploymentType[0].EstimatedRuntimeMinutes | Should -BeNullOrEmpty
                ($spec.Findings | Where-Object { $_.Code -eq 'MECM_MAX_RUNTIME_DEFAULTED' }).Severity |
                    Should -Be 'Info'
            }

            It 'carries operator-supplied runtimes through with no default finding' {
                $spec = ConvertTo-MecmDeploymentSpec -Manifest $script:SevenZipManifest `
                    -MaxRuntimeMinutes 45 -EstimatedRuntimeMinutes 15

                $spec.DeploymentType[0].MaxRuntimeMinutes       | Should -Be 45
                $spec.DeploymentType[0].EstimatedRuntimeMinutes | Should -Be 15
                @($spec.Findings | Where-Object { $_.Code -eq 'MECM_MAX_RUNTIME_DEFAULTED' }).Count | Should -Be 0
            }
        }

        Context 'Obsidian-shape per-user manifest regression' {

            It 'maps SelectedContext User and RequiresLogonWhenUserContext to InstallForUser / OnlyWhenUserLoggedOn' {
                $spec = ConvertTo-MecmDeploymentSpec -Manifest $script:ObsidianManifest

                $spec.DeploymentType[0].UserExperience.InstallBehavior  | Should -Be 'InstallForUser'
                $spec.DeploymentType[0].UserExperience.LogonRequirement | Should -Be 'OnlyWhenUserLoggedOn'
            }
        }

        Context 'KiCad-shape EXE installer with no ProductCode' {

            BeforeAll {
                $script:KiCadSpec = ConvertTo-MecmDeploymentSpec -Manifest $script:KiCadManifest
            }

            It 'renders File-kind Medium-confidence detection as the generic Script method' {
                $detection = $script:KiCadSpec.DeploymentType[0].Detection
                $detection.Method     | Should -Be 'Script'
                $detection.ScriptFile | Should -Be 'Detect-Application.ps1'
            }

            It 'uses the same PSADT wrapper entry point with no MSI assumptions' {
                $script:KiCadSpec.DeploymentType[0].InstallCommand |
                    Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent -AllowRebootPassThru'
                $script:KiCadSpec.DeploymentType[0].UninstallCommand |
                    Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent -AllowRebootPassThru'
            }

            It 'maps System context to InstallForSystem' {
                $script:KiCadSpec.DeploymentType[0].UserExperience.InstallBehavior | Should -Be 'InstallForSystem'
            }
        }

        Context 'unresolved detection' {

            It 'emits a null Detection block and MECM_DETECTION_UNRESOLVED when no detection spec resolved' {
                $spec = ConvertTo-MecmDeploymentSpec -Manifest $script:UnresolvedDetectionManifest

                $spec.DeploymentType[0].Detection | Should -BeNullOrEmpty
                ($spec.Findings | Where-Object { $_.Code -eq 'MECM_DETECTION_UNRESOLVED' }).Severity |
                    Should -Be 'Warning'
            }

            It 'treats a manifest with no DetectionSpec key at all as unresolved, not as one null rule' {
                # A hand-built manifest may omit the key entirely; Get-DocumentOptionalProperty
                # then returns $null, and @($null) has Count 1 -- which must not sneak past the
                # exactly-one-rule gate as if it were a resolved detection method.
                $noKeyManifest = $script:UnresolvedDetectionManifest |
                    ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $noKeyManifest.PackageSpec.PSObject.Properties.Remove('DetectionSpec')

                $spec = ConvertTo-MecmDeploymentSpec -Manifest $noKeyManifest

                $spec.DeploymentType[0].Detection | Should -BeNullOrEmpty
                ($spec.Findings | Where-Object { $_.Code -eq 'MECM_DETECTION_UNRESOLVED' }).Severity |
                    Should -Be 'Warning'
            }
        }
    }

    Describe 'New-MecmDeploymentSpec' {

        BeforeAll {
            $script:TempManifestPath = Join-Path $TestDrive 'PackageManifest.json'
            Copy-Item -LiteralPath $script:SevenZipManifestPath -Destination $script:TempManifestPath
        }

        It 'writes a valid, round-trippable MecmDeploymentSpec.json next to the manifest' {
            $result = New-MecmDeploymentSpec -ManifestPath $script:TempManifestPath -ContentSourcePath '\\contoso\ContentSource\7-Zip'

            $expectedPath = Join-Path (Split-Path -Path $script:TempManifestPath -Parent) 'MecmDeploymentSpec.json'
            $result.SpecPath | Should -Be (Resolve-Path -LiteralPath $expectedPath).ProviderPath
            $expectedPath | Should -Exist

            $raw = Get-Content -LiteralPath $expectedPath -Raw
            $raw | Should -Not -Match '\{\{'

            { $raw | ConvertFrom-Json } | Should -Not -Throw
            $parsed = $raw | ConvertFrom-Json
            $parsed.Application.LocalizedDisplayName | Should -Be '7-Zip 26.02 (x64 edition)'
        }

        It 'writes nothing under -WhatIf' {
            $outputPath = Join-Path $TestDrive 'whatif\MecmDeploymentSpec.json'
            New-MecmDeploymentSpec -ManifestPath $script:TempManifestPath -OutputPath $outputPath -WhatIf

            $outputPath | Should -Not -Exist
        }
    }
}
