$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ManifestPath = Join-Path $ModuleRoot 'PSPackageForge.psd1'
$AcceptanceEnabled = $env:PSPACKAGEFORGE_RUN_WINDOWS_ACCEPTANCE -eq '1'
$WindowsHost = $env:OS -eq 'Windows_NT'
$SuiteSkip = -not ($AcceptanceEnabled -and $WindowsHost)
$StandardUserSkip = [string]::IsNullOrWhiteSpace($env:PSPACKAGEFORGE_ACCEPTANCE_USER)

Describe 'Windows child-process and package-runtime acceptance' -Skip:$SuiteSkip {
    BeforeAll {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $manifestPath = Join-Path $moduleRoot 'PSPackageForge.psd1'
        . (Join-Path $PSScriptRoot 'New-NativeArgumentRecorder.ps1')
        if ([string]::IsNullOrWhiteSpace($env:PSPACKAGEFORGE_PSADT_MODULE_PATH)) {
            throw 'PSPACKAGEFORGE_PSADT_MODULE_PATH must name the exact PSAppDeployToolkit 4.0.6 module manifest.'
        }
        $script:PSADTPath = [IO.Path]::GetFullPath($env:PSPACKAGEFORGE_PSADT_MODULE_PATH)
        if (-not (Test-Path -LiteralPath $script:PSADTPath -PathType Leaf)) {
            throw "The pinned PSADT module manifest was not found: $script:PSADTPath"
        }
        $psadtData = Import-PowerShellDataFile -LiteralPath $script:PSADTPath
        if ([Version] $psadtData.ModuleVersion -ne [Version] '4.0.6') {
            throw "Windows acceptance requires exactly PSADT 4.0.6; found '$($psadtData.ModuleVersion)'."
        }
        Import-Module -Name $manifestPath -Force -ErrorAction Stop
        Import-Module -Name $script:PSADTPath -Force -ErrorAction Stop

        $script:Recorder = New-NativeArgumentRecorder -OutputPath (Join-Path $TestDrive 'native recorder.exe')
        $script:Module = Get-Module PSPackageForge
        $script:FixtureScript = Join-Path $PSScriptRoot '..\Fixtures\New-PackageValidationFixture.ps1'
        if (-not (Test-Path -LiteralPath $script:FixtureScript -PathType Leaf)) {
            throw "The package-validation fixture helper was not found: $script:FixtureScript"
        }

        function New-TestFixture {
            [CmdletBinding(SupportsShouldProcess)]
            param([string] $RootPath, [switch] $CreateReceipt)
            if (-not $PSCmdlet.ShouldProcess($RootPath, 'Create disposable package fixture')) { return }
            return & $script:Module {
                param($fixturePath, $root, $withReceipt)
                . $fixturePath
                $result = @(New-PackageValidationFixture -RootPath $root -CreateReceipt:$withReceipt)
                return $result[-1]
            } $script:FixtureScript $RootPath ([bool] $CreateReceipt)
        }

        function ConvertTo-TestArgumentString {
            param([AllowEmptyString()] [string[]] $ArgumentList)
            return & $script:Module {
                param($items)
                ConvertTo-WindowsArgumentString -ArgumentList $items
            } $ArgumentList
        }

        function Invoke-AcceptanceProcess {
            param(
                [Parameter(Mandatory)] [string] $FilePath,
                [Parameter()] [AllowEmptyString()] [string[]] $ArgumentList = @(),
                [Parameter()] [string] $WorkingDirectory
            )
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = $FilePath
            $start.Arguments = ConvertTo-TestArgumentString -ArgumentList $ArgumentList
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
            $process = [System.Diagnostics.Process]::Start($start)
            $process.WaitForExit()
            return $process.ExitCode
        }

        function Invoke-AcceptanceCapture {
            param(
                [Parameter(Mandatory)] [string] $FilePath,
                [Parameter()] [AllowEmptyString()] [string[]] $ArgumentList = @(),
                [Parameter()] [string] $WorkingDirectory
            )
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = $FilePath
            $start.Arguments = ConvertTo-TestArgumentString -ArgumentList $ArgumentList
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
            $process = [System.Diagnostics.Process]::Start($start)
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            return [pscustomobject] @{ ExitCode = $process.ExitCode; StandardOutput = $stdout; StandardError = $stderr }
        }

        function New-AcceptancePackage {
            [CmdletBinding(SupportsShouldProcess)]
            param(
                [Parameter(Mandatory)] [string] $Name,
                [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $InstallArguments,
                [Parameter()] [AllowEmptyString()] [string[]] $UninstallArguments = @('uninstall'),
                [Parameter()] [string] $InstallWorkingDirectory,
                [Parameter()] [string] $UninstallWorkingDirectory,
                [Parameter()] [int[]] $ExpectedExitCodes = @(0, 3010)
            )
            $root = Join-Path $TestDrive ('p-' + [Guid]::NewGuid().ToString('N'))
            if (-not $PSCmdlet.ShouldProcess($root, "Create disposable acceptance package '$Name'")) { return }
            $fixture = New-TestFixture -RootPath $root
            $manifest = Get-Content -LiteralPath $fixture.ManifestPath -Raw | ConvertFrom-Json
            $manifest.PackageSpec | Add-Member -MemberType NoteProperty -Name SelectedContext -Value 'User' -Force
            $manifest.Installer | Add-Member -MemberType NoteProperty -Name ProductName -Value 'PSPackageForge Acceptance Recorder' -Force
            $manifest.Installer | Add-Member -MemberType NoteProperty -Name Manufacturer -Value 'PSPackageForge' -Force
            $manifest.Installer | Add-Member -MemberType NoteProperty -Name ProductVersionRaw -Value '1.0.0' -Force
            $manifest.PackageSpec.InstallCommand = [ordered] @{
                Executable = $script:Recorder
                ArgumentList = [string[]] $InstallArguments
                WorkingDirectory = $InstallWorkingDirectory
                ExpectedExitCodes = [int[]] $ExpectedExitCodes
            }
            $manifest.PackageSpec.UninstallCommand = [ordered] @{
                Executable = $script:Recorder
                ArgumentList = [string[]] $UninstallArguments
                WorkingDirectory = $UninstallWorkingDirectory
                ExpectedExitCodes = @(0)
            }
            $manifest.PackageSpec.ReturnCodeMap = @(
                [ordered] @{ Code = 0; Meaning = 'Success'; Classification = 'Success' },
                [ordered] @{ Code = 3010; Meaning = 'Restart required'; Classification = 'SuccessRebootRequired' }
            )
            $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixture.ManifestPath -Encoding UTF8
            $output = Join-Path $root 'Generated Package'
            $generated = New-PSADTPackage -ManifestPath $fixture.ManifestPath -OutputPath $output `
                -PSADTModulePath $script:PSADTPath -ErrorAction Stop
            $manifestInput = & $script:Module { param($path) Read-PackageForgeManifest -ManifestPath $path -RequireRunnable } $fixture.ManifestPath
            $validated = & $script:Module { param($manifestInput, $path) Test-PackageForgePackage -ManifestInput $manifestInput -PackagePath $path } $manifestInput $output
            return [pscustomobject] @{
                Root = $root
                Fixture = $fixture
                Manifest = $manifest
                Generated = $generated
                Validated = $validated
            }
        }

        function Invoke-PackageDeployment {
            param([string] $FrontendPath, [ValidateSet('Install', 'Uninstall')] [string] $DeploymentType)
            $powershell = Join-Path $PSHOME 'powershell.exe'
            return Invoke-AcceptanceProcess -FilePath $powershell -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $FrontendPath, '-DeploymentType', $DeploymentType, '-DeployMode', 'Silent',
                '-AllowRebootPassThru'
            ) -WorkingDirectory (Split-Path -Parent $FrontendPath)
        }

        function Read-RecorderResult {
            param([string] $Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "The native child did not write its argument record '$Path'."
            }
            return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        }
    }

    It 'records Intune source and output path arguments received by a real child' {
        $root = Join-Path $TestDrive 'Intune source and output with spaces'
        $source = Join-Path $root 'Package source'
        $output = Join-Path $root 'Intune output'
        [void](New-Item -ItemType Directory -Path $source -Force)
        [void](New-Item -ItemType Directory -Path $output -Force)
        $record = Join-Path $root 'intune argv.json'
        $env:NATIVE_RECORDER_OUTPUT = $record
        $env:NATIVE_RECORDER_ENV_NAMES = 'PSPACKAGEFORGE_CHILD_PROBE'
        $env:PSPACKAGEFORGE_CHILD_PROBE = 'child environment value'
        try {
            $exitCode = & $script:Module {
                param($recorder, $package, $destination)
                Invoke-IntuneWinAppUtil -IntuneWinAppUtilPath $recorder -PackagePath $package -OutputPath $destination
            } $script:Recorder $source $output
            $exitCode | Should -Be 0
            $child = Read-RecorderResult -Path $record
            $child.Arguments | Should -Be @('-c', $source, '-s', 'Invoke-AppDeployToolkit.exe', '-o', $output, '-q')
            $child.Environment.PSPACKAGEFORGE_CHILD_PROBE | Should -Be 'child environment value'
            [IO.Path]::GetFullPath($child.CurrentDirectory) | Should -Be ([IO.Path]::GetFullPath((Split-Path -Parent $source)))
        }
        finally {
            Remove-Item Env:NATIVE_RECORDER_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item Env:NATIVE_RECORDER_ENV_NAMES -ErrorAction SilentlyContinue
            Remove-Item Env:PSPACKAGEFORGE_CHILD_PROBE -ErrorAction SilentlyContinue
        }
    }

    It 'generates and validates official System and User templates and runs PSADT with exact payload argv' {
        $explicitWorking = Join-Path $TestDrive 'explicit working directory with spaces'
        [void](New-Item -ItemType Directory -Path $explicitWorking -Force)
        $payload = @(
            'two words', '', 'say"hello', 'C:\ordinary\', 'C:\quoted directory\',
            '%USERPROFILE%', '%LOCALAPPDATA%', '%ProgramFiles%'
        )
        $userPackage = New-AcceptancePackage -Name 'payload-runtime' -InstallArguments $payload `
            -UninstallArguments @('uninstall', 'C:\ordinary\') -InstallWorkingDirectory $explicitWorking

        $systemRoot = Join-Path $TestDrive ('system-template-' + [Guid]::NewGuid().ToString('N'))
        $systemFixture = New-TestFixture -RootPath $systemRoot
        $systemManifest = Get-Content -LiteralPath $systemFixture.ManifestPath -Raw | ConvertFrom-Json
        $systemManifest.PackageSpec | Add-Member -MemberType NoteProperty -Name SelectedContext -Value 'System' -Force
        $systemManifest.Installer | Add-Member -MemberType NoteProperty -Name ProductName -Value 'PSPackageForge Acceptance Recorder' -Force
        $systemManifest.Installer | Add-Member -MemberType NoteProperty -Name Manufacturer -Value 'PSPackageForge' -Force
        $systemManifest.Installer | Add-Member -MemberType NoteProperty -Name ProductVersionRaw -Value '1.0.0' -Force
        $systemManifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $systemFixture.ManifestPath -Encoding UTF8
        $systemOutput = Join-Path $systemRoot 'System Package'
        $systemGenerated = New-PSADTPackage -ManifestPath $systemFixture.ManifestPath -OutputPath $systemOutput `
            -PSADTModulePath $script:PSADTPath -ErrorAction Stop
        $systemReader = & $script:Module { param($path) Read-PackageForgeManifest -ManifestPath $path -RequireRunnable } $systemFixture.ManifestPath
        $systemValidated = & $script:Module { param($manifestInput, $packagePath) Test-PackageForgePackage -ManifestInput $manifestInput -PackagePath $packagePath } $systemReader $systemOutput
        $systemValidated.ReceiptPath | Should -Exist

        foreach ($item in @(
            @{ Path = $systemGenerated.DeploymentScriptPath; Context = 'System'; ExpectedAdmin = $true; ManifestPath = $systemFixture.ManifestPath },
            @{ Path = $userPackage.Generated.DeploymentScriptPath; Context = 'User'; ExpectedAdmin = $false; ManifestPath = $userPackage.Fixture.ManifestPath }
        )) {
            $tokens = $null; $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile($item.Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
            @($parseErrors).Count | Should -Be 0
            $configPath = Join-Path (Split-Path -Parent $item.Path) 'Config/config.psd1'
            $config = Import-PowerShellDataFile -LiteralPath $configPath
            $config.Toolkit.RequireAdmin | Should -Be $item.ExpectedAdmin
            if ($item.Context -eq 'User') {
                $config.Toolkit.LogPathNoAdminRights | Should -Be '$envLocalAppData\Logs\Software'
                $config.MSI.LogPathNoAdminRights | Should -Be '$envLocalAppData\Logs\Software'
            }
            $reader = & $script:Module { param($path) Read-PackageForgeManifest -ManifestPath $path -RequireRunnable } $item.ManifestPath
            $result = & $script:Module { param($manifestInput, $packagePath) Test-PackageForgePackage -ManifestInput $manifestInput -PackagePath $packagePath } $reader (Split-Path -Parent $item.Path)
            $result.FrontendPath | Should -Be $item.Path
        }

        $recordPath = Join-Path $userPackage.Root 'payload child.json'
        $env:NATIVE_RECORDER_OUTPUT = $recordPath
        $env:NATIVE_RECORDER_ENV_NAMES = ''
        $env:NATIVE_RECORDER_EXIT_CODE = '0'
        try {
            $processCode = Invoke-PackageDeployment -FrontendPath $userPackage.Generated.DeploymentScriptPath -DeploymentType Install
            $processCode | Should -Be 0
            $child = Read-RecorderResult -Path $recordPath
            $expected = @(
                'two words', '', 'say"hello', 'C:\ordinary\', 'C:\quoted directory\',
                $env:USERPROFILE, $env:LOCALAPPDATA, $env:ProgramFiles
            )
            $child.Arguments | Should -Be $expected
            [IO.Path]::GetFullPath($child.CurrentDirectory) | Should -Be ([IO.Path]::GetFullPath($explicitWorking))

            $processCode = Invoke-PackageDeployment -FrontendPath $userPackage.Generated.DeploymentScriptPath -DeploymentType Uninstall
            $processCode | Should -Be 0
            $uninstallRecord = Read-RecorderResult -Path $recordPath
            $uninstallRecord.Arguments | Should -Be @('uninstall', 'C:\ordinary\')
            [IO.Path]::GetFullPath($uninstallRecord.CurrentDirectory) | Should -Be ([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $userPackage.Generated.DeploymentScriptPath) 'Files')))
        }
        finally {
            Remove-Item Env:NATIVE_RECORDER_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item Env:NATIVE_RECORDER_ENV_NAMES -ErrorAction SilentlyContinue
            Remove-Item Env:NATIVE_RECORDER_EXIT_CODE -ErrorAction SilentlyContinue
        }
    }

    It 'runs an argumentless install with zero native child arguments' {
        $package = New-AcceptancePackage -Name 'argumentless-runtime' -InstallArguments ([string[]] @())
        $recordPath = Join-Path $package.Root 'argumentless child.json'
        $env:NATIVE_RECORDER_OUTPUT = $recordPath
        $env:NATIVE_RECORDER_EXIT_CODE = '0'
        try {
            $processCode = Invoke-PackageDeployment -FrontendPath $package.Generated.DeploymentScriptPath -DeploymentType Install
            $processCode | Should -Be 0
            $child = Read-RecorderResult -Path $recordPath
            @($child.Arguments).Count | Should -Be 0
        }
        finally {
            Remove-Item Env:NATIVE_RECORDER_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item Env:NATIVE_RECORDER_EXIT_CODE -ErrorAction SilentlyContinue
        }
    }

    It 'maps declared 3010 and rejects an unexpected 3010 from the real PSADT child process' {
        $expectedPackage = New-AcceptancePackage -Name 'expected-3010' -InstallArguments @('expected reboot') `
            -ExpectedExitCodes @(0, 3010)
        $unexpectedPackage = New-AcceptancePackage -Name 'unexpected-3010' -InstallArguments @('unexpected reboot') `
            -ExpectedExitCodes @(0)
        $recordPath = Join-Path $TestDrive '3010 child.json'
        $env:NATIVE_RECORDER_OUTPUT = $recordPath
        $env:NATIVE_RECORDER_EXIT_CODE = '3010'
        try {
            $declaredResult = Invoke-PackageDeployment -FrontendPath $expectedPackage.Generated.DeploymentScriptPath -DeploymentType Install
            $declaredChild = Read-RecorderResult -Path $recordPath
            $declaredChild.RequestedExitCode | Should -Be 3010
            $declaredResult | Should -Be 3010

            $unexpectedResult = Invoke-PackageDeployment -FrontendPath $unexpectedPackage.Generated.DeploymentScriptPath -DeploymentType Install
            $unexpectedChild = Read-RecorderResult -Path $recordPath
            $unexpectedChild.RequestedExitCode | Should -Be 3010
            $unexpectedResult | Should -Not -BeIn @(0, 1641, 1707, 3010)
        }
        finally {
            Remove-Item Env:NATIVE_RECORDER_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item Env:NATIVE_RECORDER_EXIT_CODE -ErrorAction SilentlyContinue
        }
    }

    It 'accepts only an exact receipt-backed package and rejects a changed file before reuse' {
        $fixture = New-TestFixture -RootPath (Join-Path $TestDrive 'receipt validation') -CreateReceipt
        $valid = & $script:Module { param($manifestInput, $path) Test-PackageForgePackage -ManifestInput $manifestInput -PackagePath $path } $fixture.ManifestInput $fixture.PackagePath
        $valid.ReceiptPath | Should -Exist
        Add-Content -LiteralPath $valid.ConfigPath -Value '# changed after receipt'
        {
            & $script:Module { param($manifestInput, $path) Test-PackageForgePackage -ManifestInput $manifestInput -PackagePath $path } $fixture.ManifestInput $fixture.PackagePath
        } | Should -Throw '*mismatch*'
    }

    It 'uses any matching file for wildcard detection and returns failure when inspection is denied' {
        $base = Join-Path $TestDrive 'wildcard detection'
        $appDirectory = Join-Path $base 'Application files'
        [void](New-Item -ItemType Directory -Path $appDirectory -Force)
        New-NativeArgumentRecorder -OutputPath (Join-Path $appDirectory 'a-old.exe') -FileVersion '1.0.0.0' | Out-Null
        New-NativeArgumentRecorder -OutputPath (Join-Path $appDirectory 'z-new.exe') -FileVersion '2.0.0.0' | Out-Null
        $spec = & $script:Module {
            param($directory)
            $d = [DetectionSpec]::new()
            $d.Kind = [DetectionKind]::File
            $d.Path = $directory
            $d.FileName = '*.exe'
            $d.UsesWildcardPath = $true
            $d.Operator = [DetectionOperator]::GreaterOrEqual
            $d.Value = '2.0.0.0'
            $d.Confidence = [ConfidenceLevel]::High
            $d.Rationale = 'Acceptance any-match rule.'
            return $d
        } $appDirectory
        $scriptPath = Join-Path $base 'Detect-Application.ps1'
        New-DetectionMethod -DetectionSpec $spec -OutputPath $scriptPath | Out-Null
        $powershell = Join-Path $PSHOME 'powershell.exe'
        $detected = Invoke-AcceptanceCapture -FilePath $powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
        $detected.ExitCode | Should -Be 0
        $detected.StandardOutput | Should -Match 'Detected:'

        $target = Join-Path $base 'inaccessible'
        [void](New-Item -ItemType Directory -Path $target -Force)
        $targetFile = Join-Path $target 'anything.exe'
        [void](New-Item -ItemType File -Path $targetFile -Force)
        $originalAcl = Get-Acl -LiteralPath $target
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetSecurityDescriptorSddlForm($originalAcl.Sddl)
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $deny = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity, [System.Security.AccessControl.FileSystemRights]::ListDirectory,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($deny)
        $failureSpec = & $script:Module {
            param($directory)
            $d = [DetectionSpec]::new()
            $d.Kind = [DetectionKind]::File
            $d.Path = $directory
            $d.FileName = '*.exe'
            $d.UsesWildcardPath = $true
            $d.Operator = [DetectionOperator]::Exists
            $d.Confidence = [ConfidenceLevel]::High
            return $d
        } $target
        $failureScript = Join-Path $base 'Detect-Inaccessible.ps1'
        New-DetectionMethod -DetectionSpec $failureSpec -OutputPath $failureScript | Out-Null
        if (-not ('PSPackageForge.Acceptance.SeBackupPrivilegeScope' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace PSPackageForge.Acceptance {
    public sealed class SeBackupPrivilegeScope : IDisposable {
        private const UInt32 TOKEN_ADJUST_PRIVILEGES = 0x20;
        private const UInt32 TOKEN_QUERY = 0x8;
        private const UInt32 SE_PRIVILEGE_DISABLED = 0x0;
        private const Int32 ERROR_NOT_ALL_ASSIGNED = 1300;
        private IntPtr token;
        private TOKEN_PRIVILEGES previous;
        private bool hasPrevious;

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID {
            public UInt32 LowPart;
            public Int32 HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID_AND_ATTRIBUTES {
            public LUID Luid;
            public UInt32 Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES {
            public UInt32 PrivilegeCount;
            public LUID_AND_ATTRIBUTES Privileges;
        }

        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool OpenProcessToken(IntPtr process, UInt32 access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool LookupPrivilegeValue(string systemName, string name, out LUID luid);
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
            ref TOKEN_PRIVILEGES newState, UInt32 bufferLength,
            out TOKEN_PRIVILEGES previousState, out UInt32 returnLength);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool CloseHandle(IntPtr handle);

        private SeBackupPrivilegeScope() {}

        public static SeBackupPrivilegeScope Disable() {
            SeBackupPrivilegeScope scope = new SeBackupPrivilegeScope();
            try {
                if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out scope.token))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed.");
                LUID luid;
                if (!LookupPrivilegeValue(null, "SeBackupPrivilege", out luid))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue(SeBackupPrivilege) failed.");
                TOKEN_PRIVILEGES requested = new TOKEN_PRIVILEGES();
                requested.PrivilegeCount = 1;
                requested.Privileges.Luid = luid;
                requested.Privileges.Attributes = SE_PRIVILEGE_DISABLED;
                UInt32 returnLength;
                bool adjusted = AdjustTokenPrivileges(scope.token, false, ref requested,
                    (UInt32)Marshal.SizeOf(typeof(TOKEN_PRIVILEGES)), out scope.previous, out returnLength);
                Int32 error = Marshal.GetLastWin32Error();
                if (!adjusted) throw new Win32Exception(error, "AdjustTokenPrivileges(disable) failed.");
                scope.hasPrevious = scope.previous.PrivilegeCount != 0;
                if (error == ERROR_NOT_ALL_ASSIGNED && scope.previous.PrivilegeCount == 0)
                    return scope;
                if (error == ERROR_NOT_ALL_ASSIGNED)
                    throw new Win32Exception(error, "AdjustTokenPrivileges(disable) did not adjust every requested privilege.");
                return scope;
            }
            catch {
                scope.Dispose();
                throw;
            }
        }

        public void Dispose() {
            try {
                if (token != IntPtr.Zero && hasPrevious) {
                    TOKEN_PRIVILEGES ignored;
                    UInt32 returnLength;
                    if (!AdjustTokenPrivileges(token, false, ref previous,
                        (UInt32)Marshal.SizeOf(typeof(TOKEN_PRIVILEGES)), out ignored, out returnLength))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "AdjustTokenPrivileges(restore) failed.");
                    Int32 error = Marshal.GetLastWin32Error();
                    if (error == ERROR_NOT_ALL_ASSIGNED)
                        throw new Win32Exception(error, "Restoring SeBackupPrivilege was not fully assigned.");
                    hasPrevious = false;
                }
            }
            finally {
                if (token != IntPtr.Zero) {
                    IntPtr handle = token;
                    token = IntPtr.Zero;
                    if (!CloseHandle(handle))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "CloseHandle(token) failed.");
                }
            }
        }
    }
}
'@
        }
        $privilegeScope = $null
        try {
            $privilegeScope = [PSPackageForge.Acceptance.SeBackupPrivilegeScope]::Disable()
            Set-Acl -LiteralPath $target -AclObject $acl
            $enumerationError = $null
            try {
                Get-ChildItem -LiteralPath $target -ErrorAction Stop | Out-Null
            }
            catch {
                $enumerationError = $_.Exception
            }
            $enumerationError | Should -BeOfType ([System.UnauthorizedAccessException])
            $failure = Invoke-AcceptanceCapture -FilePath $powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $failureScript)
            $failure.ExitCode | Should -Be 2
            $failure.StandardOutput | Should -BeNullOrEmpty
            $failure.StandardError | Should -Match '(?i)Detection failed:.*(access.*denied|unauthorizedaccess)'
        }
        finally {
            try {
                Set-Acl -LiteralPath $target -AclObject $originalAcl
            }
            finally {
                if ($null -ne $privilegeScope) { $privilegeScope.Dispose() }
            }
        }
    }

    It 'records native MSI installer identity and runs install-detect-uninstall when supplied' {
        $path = $env:PSPACKAGEFORGE_NATIVE_MSI_PATH
        if ([string]::IsNullOrWhiteSpace($path)) {
            Set-ItResult -Skipped -Because 'No representative native MSI was supplied.'
            return
        }
        $path = [IO.Path]::GetFullPath($path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Representative MSI was not found: $path" }
        $file = Get-Item -LiteralPath $path
        $info = Get-InstallerInfo -Path $path
        $version = if ([string]::IsNullOrWhiteSpace($info.ProductVersionRaw)) { '<unavailable>' } else { $info.ProductVersionRaw }
        Write-Information ("Native MSI {0}; product version {1}; SHA-256 {2}" -f $file.Name, $version, (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) -InformationAction Continue
        if ($info.MsiKind.ToString() -ne 'Native' -or -not $info.SupportsMsiUninstall -or -not $info.ProductCodePresent) {
            throw 'The supplied MSI is not a native package with a verified product-code uninstall path.'
        }
        $stagedRoot = Join-Path $TestDrive ('native-msi-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $stagedRoot -Force)
        Copy-Item -LiteralPath $path -Destination (Join-Path $stagedRoot $info.FileName)
        $install = @('/i', (Join-Path $stagedRoot $info.FileName), '/qn', 'REBOOT=ReallySuppress')
        $installCode = Invoke-AcceptanceProcess -FilePath (Join-Path $env:WINDIR 'System32/msiexec.exe') -ArgumentList $install
        if ($installCode -notin @(0, 1641, 1707, 3010)) { throw "Native MSI install failed with exit code $installCode." }
        $comparisonProductName = ([string] $info.ProductName).Trim()
        if ([string]::IsNullOrWhiteSpace($comparisonProductName)) {
            throw 'The native MSI has no usable product name for uninstall registration matching.'
        }
        $comparisonProductVersion = ([string] $info.ProductVersionRaw).Trim()
        $displayNamePattern = [System.Management.Automation.WildcardPattern]::Escape($comparisonProductName) + '*'
        $expectedDisplayNames = @($comparisonProductName)
        if (-not [string]::IsNullOrWhiteSpace($comparisonProductVersion)) {
            $expectedDisplayNames += ('{0} {1}' -f $comparisonProductName, $comparisonProductVersion)
        }
        $discovery = Get-InstalledAppInfo -DisplayNameLike $displayNamePattern
        $productMatches = @($discovery.Matches | Where-Object { ([string] $_.DisplayName).Trim() -in $expectedDisplayNames })
        $productCodeMatches = @($productMatches | Where-Object {
            $_.Evidence | Where-Object { $_.Field -eq 'ProductCode' -and $_.Value -eq $info.ProductCode }
        })
        if ($productCodeMatches.Count -ne 1) {
            throw "Native MSI detection expected one registration with the verified product code, found $($productCodeMatches.Count)."
        }
        if ($productMatches.Count -ne 1) {
            throw 'Native MSI detection did not find its registered product code after installation.'
        }
        $removeCode = Invoke-AcceptanceProcess -FilePath (Join-Path $env:WINDIR 'System32/msiexec.exe') `
            -ArgumentList @('/x', $info.ProductCode, '/qn', 'REBOOT=ReallySuppress')
        if ($removeCode -notin @(0, 1641, 1707, 3010)) { throw "Native MSI uninstall failed with exit code $removeCode." }
        $discovery = Get-InstalledAppInfo -DisplayNameLike $displayNamePattern
        $remaining = @($discovery.Matches |
            Where-Object { ([string] $_.DisplayName).Trim() -in $expectedDisplayNames } |
            Where-Object { $_.Evidence | Where-Object { $_.Field -eq 'ProductCode' -and $_.Value -eq $info.ProductCode } })
        @($remaining).Count | Should -Be 0
    }

    It 'records representative EXE identity and runs install-detect-uninstall when supplied' {
        $path = $env:PSPACKAGEFORGE_EXE_INSTALLER_PATH
        if ([string]::IsNullOrWhiteSpace($path)) {
            Set-ItResult -Skipped -Because 'No representative EXE installer was supplied.'
            return
        }
        $path = [IO.Path]::GetFullPath($path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Representative EXE was not found: $path" }
        $file = Get-Item -LiteralPath $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $info = Get-InstallerInfo -Path $path
        $version = if ([string]::IsNullOrWhiteSpace($info.ProductVersionRaw)) { '<unavailable>' } else { $info.ProductVersionRaw }
        Write-Information ("Native EXE {0}; product version {1}; SHA-256 {2}" -f $file.Name, $version, $hash) -InformationAction Continue
        $installEvidence = $info.GetResolvedEvidence('InstallCommand')
        if ($null -eq $installEvidence -or $installEvidence.Value.GetType().Name -ne 'CommandSpec') {
            throw 'The supplied EXE has no structured safe install command; the native EXE smoke cannot proceed.'
        }
        $stage = Join-Path $TestDrive ('native-exe-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $stage -Force)
        $staged = Join-Path $stage $info.FileName
        Copy-Item -LiteralPath $path -Destination $staged
        $installCommand = $installEvidence.Value
        $installExe = if ($installCommand.Executable -eq $info.FileName) { $staged } else { [Environment]::ExpandEnvironmentVariables($installCommand.Executable) }
        $installCode = Invoke-AcceptanceProcess -FilePath $installExe -ArgumentList $installCommand.ArgumentList -WorkingDirectory $stage
        if ($installCode -notin @(0, 1641, 1707, 3010)) { throw "Native EXE install failed with exit code $installCode." }
        $comparisonProductName = ([string] $info.ProductName).Trim()
        if ([string]::IsNullOrWhiteSpace($comparisonProductName)) {
            throw 'The native EXE has no usable product name for uninstall registration matching.'
        }
        $comparisonProductVersion = ([string] $info.ProductVersionRaw).Trim()
        $displayNamePattern = [System.Management.Automation.WildcardPattern]::Escape($comparisonProductName) + '*'
        $expectedDisplayNames = @($comparisonProductName)
        if (-not [string]::IsNullOrWhiteSpace($comparisonProductVersion)) {
            $expectedDisplayNames += ('{0} {1}' -f $comparisonProductName, $comparisonProductVersion)
        }
        $discovery = Get-InstalledAppInfo -DisplayNameLike $displayNamePattern
        $installed = @($discovery.Matches | Where-Object { ([string] $_.DisplayName).Trim() -in $expectedDisplayNames })
        $match = $installed
        if ($match.Count -ne 1) { throw "Native EXE detection expected one matching uninstall registration, found $($match.Count)." }
        $selectedMatch = $match[0]
        $selectedVersion = @($selectedMatch.Evidence | Where-Object Field -eq 'ProductVersionRaw' | Select-Object -First 1)
        $selectedVersionValue = if ($selectedVersion.Count -eq 1) { [string] $selectedVersion[0].Value } else { $null }
        $uninstallEvidence = @($match[0].Evidence | Where-Object Field -eq 'UninstallCommand' | Select-Object -First 1)
        if ($uninstallEvidence.Count -ne 1 -or
            $null -eq $uninstallEvidence[0].Value -or
            [string]::IsNullOrWhiteSpace([string] $uninstallEvidence[0].Value.Executable)) {
            throw 'The installed EXE did not expose one structured uninstall command; the native EXE smoke cannot continue.'
        }
        if ($uninstallEvidence[0].Confidence.ToString() -ne 'High') {
            throw 'The installed EXE exposes no high-confidence quiet uninstall command; the native EXE smoke will not guess silent switches.'
        }
        $uninstall = $uninstallEvidence[0].Value
        $uninstallExe = [Environment]::ExpandEnvironmentVariables($uninstall.Executable)
        $uninstallCode = Invoke-AcceptanceProcess -FilePath $uninstallExe -ArgumentList $uninstall.ArgumentList
        if ($uninstallCode -notin @(0, 1641, 1707, 3010)) { throw "Native EXE uninstall failed with exit code $uninstallCode." }
        $discovery = Get-InstalledAppInfo -DisplayNameLike $displayNamePattern
        $remainingSelectedRegistration = @($discovery.Matches | Where-Object {
            $candidateVersions = @($_.Evidence | Where-Object Field -eq 'ProductVersionRaw' | Select-Object -First 1)
            $candidateVersionValue = if ($candidateVersions.Count -eq 1) { [string] $candidateVersions[0].Value } else { $null }
            $_.MatchId -eq $selectedMatch.MatchId -and
            $_.DisplayName -eq $selectedMatch.DisplayName -and
            $candidateVersionValue -eq $selectedVersionValue
        })
        $remainingSelectedRegistration | Should -BeNullOrEmpty
    }

    Context 'real standard-user package profile' -Tag StandardUser -Skip:$StandardUserSkip {
        It 'installs, detects, logs, and uninstalls through the standard account profile' {
            if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
                [string]::IsNullOrWhiteSpace($env:PSPACKAGEFORGE_ACCEPTANCE_USER) -or
                $env:USERNAME -ne $env:PSPACKAGEFORGE_ACCEPTANCE_USER) {
                throw 'The standard-user test must run under the unique real local account provisioned by Invoke-WindowsAcceptance.ps1.'
            }
            $marker = Join-Path $env:LOCALAPPDATA 'PSPackageForge Acceptance/installed.txt'
            $record = Join-Path $env:LOCALAPPDATA 'PSPackageForge Acceptance/child.json'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force)
            $package = New-AcceptancePackage -Name 'standard-user-package' `
                -InstallArguments @('--touch', $marker) -UninstallArguments @('--remove', $marker)
            $detectionSpec = & $script:Module {
                param($markerPath)
                $d = [DetectionSpec]::new()
                $d.Kind = [DetectionKind]::File
                $d.Path = Split-Path -Parent $markerPath
                $d.FileName = Split-Path -Leaf $markerPath
                $d.Operator = [DetectionOperator]::Exists
                $d.Confidence = [ConfidenceLevel]::High
                $d.Rationale = 'The harmless acceptance package writes this profile marker.'
                return $d
            } $marker
            $detectionScript = Join-Path $package.Root 'Detect-Application.ps1'
            New-DetectionMethod -DetectionSpec $detectionSpec -OutputPath $detectionScript | Out-Null
            $env:NATIVE_RECORDER_OUTPUT = $record
            try {
                $installCode = Invoke-PackageDeployment -FrontendPath $package.Generated.DeploymentScriptPath -DeploymentType Install
                $installCode | Should -Be 0
                Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
                $detectAfterInstall = Invoke-AcceptanceCapture -FilePath (Join-Path $PSHOME 'powershell.exe') `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $detectionScript)
                $detectAfterInstall.ExitCode | Should -Be 0
                $detectAfterInstall.StandardOutput | Should -Match 'Detected:'
                $logDirectory = Join-Path $env:LOCALAPPDATA 'Logs/Software'
                Test-Path -LiteralPath $logDirectory -PathType Container | Should -BeTrue
                @(Get-ChildItem -LiteralPath $logDirectory -File -ErrorAction Stop).Count | Should -BeGreaterThan 0
                $child = Read-RecorderResult -Path $record
                $child.Arguments | Should -Be @('--touch', $marker)

                $uninstallCode = Invoke-PackageDeployment -FrontendPath $package.Generated.DeploymentScriptPath -DeploymentType Uninstall
                $uninstallCode | Should -Be 0
                Test-Path -LiteralPath $marker | Should -BeFalse
                $detectAfterUninstall = Invoke-AcceptanceCapture -FilePath (Join-Path $PSHOME 'powershell.exe') `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $detectionScript)
                $detectAfterUninstall.ExitCode | Should -Be 0
                $detectAfterUninstall.StandardOutput | Should -BeNullOrEmpty
                @(Get-ChildItem -LiteralPath $logDirectory -File -ErrorAction Stop).Count | Should -BeGreaterThan 0
            }
            finally {
                Remove-Item Env:NATIVE_RECORDER_OUTPUT -ErrorAction SilentlyContinue
            }
        }
    }
}
