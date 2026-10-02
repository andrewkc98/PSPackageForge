function New-NativeArgumentRecorder {
    [OutputType([string])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OutputPath,
        [Parameter()] [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')] [string] $FileVersion = '1.0.0.0'
    )

    $fullPath = [IO.Path]::GetFullPath($OutputPath)
    $sourcePath = [IO.Path]::ChangeExtension($fullPath, '.cs')
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
    }
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw 'The .NET Framework C# compiler was not found; the native argument recorder cannot be built.'
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

[assembly: System.Reflection.AssemblyVersion("__FILE_VERSION__")]
[assembly: System.Reflection.AssemblyFileVersion("__FILE_VERSION__")]

internal static class NativeArgumentRecorder
{
    private static string Json(string value)
    {
        if (value == null) return "null";
        var result = new StringBuilder("\"");
        foreach (char c in value)
        {
            switch (c)
            {
                case '\\': result.Append("\\\\"); break;
                case '"': result.Append("\\\""); break;
                case '\r': result.Append("\\r"); break;
                case '\n': result.Append("\\n"); break;
                case '\t': result.Append("\\t"); break;
                default:
                    if (c < 32) result.Append("\\u" + ((int)c).ToString("x4"));
                    else result.Append(c);
                    break;
            }
        }
        return result.Append('"').ToString();
    }

    private static int Main(string[] args)
    {
        string output = Environment.GetEnvironmentVariable("NATIVE_RECORDER_OUTPUT");
        int requestedExitCode = 0;
        Int32.TryParse(Environment.GetEnvironmentVariable("NATIVE_RECORDER_EXIT_CODE"), out requestedExitCode);
        var names = new List<string>();
        var payload = new List<string>();
        bool controlMode = args.Length > 0 && args[0] == "--record";
        if (!controlMode && args.Length > 0)
        {
            payload.AddRange(args);
        }
        else if (controlMode)
        {
            bool inPayload = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (inPayload) { payload.Add(args[i]); continue; }
                if (args[i] == "--") { inPayload = true; continue; }
                if (args[i] == "--record" && i + 1 < args.Length) { output = args[++i]; continue; }
                if (args[i] == "--exit-code" && i + 1 < args.Length) { requestedExitCode = Int32.Parse(args[++i]); continue; }
                if (args[i] == "--env" && i + 1 < args.Length) { names.Add(args[++i]); continue; }
                throw new ArgumentException("Unknown recorder option: " + args[i]);
            }
        }
        string namesText = Environment.GetEnvironmentVariable("NATIVE_RECORDER_ENV_NAMES");
        if (!String.IsNullOrEmpty(namesText)) names.AddRange(namesText.Split(new char[] { ';' }, StringSplitOptions.RemoveEmptyEntries));
        if (String.IsNullOrEmpty(output)) throw new ArgumentException("--record is required.");

        var json = new StringBuilder();
        json.Append("{\"Arguments\":[");
        for (int i = 0; i < payload.Count; i++)
        {
            if (i != 0) json.Append(',');
            json.Append(Json(payload[i]));
        }
        json.Append("],\"Environment\":{");
        for (int i = 0; i < names.Count; i++)
        {
            if (i != 0) json.Append(',');
            json.Append(Json(names[i])).Append(':').Append(Json(Environment.GetEnvironmentVariable(names[i])));
        }
        json.Append("},\"CurrentDirectory\":").Append(Json(Environment.CurrentDirectory));
        json.Append(",\"RequestedExitCode\":").Append(requestedExitCode).Append('}');
        File.WriteAllText(output, json.ToString(), new UTF8Encoding(false));
        if (payload.Count == 2 && payload[0] == "--touch")
        {
            Directory.CreateDirectory(Path.GetDirectoryName(payload[1]));
            File.WriteAllText(payload[1], "installed by the harmless acceptance recorder");
        }
        else if (payload.Count == 2 && payload[0] == "--remove" && File.Exists(payload[1]))
        {
            File.Delete(payload[1]);
        }
        return requestedExitCode;
    }
}
'@
    if ($PSCmdlet.ShouldProcess($fullPath, 'Write source and compile native argument recorder')) {
        $source = $source.Replace('__FILE_VERSION__', $FileVersion)
        Set-Content -LiteralPath $sourcePath -Value $source -Encoding UTF8
        $compileArguments = '/nologo /target:exe /out:"{0}" "{1}"' -f $fullPath, $sourcePath
        $compile = New-Object Diagnostics.ProcessStartInfo
        $compile.FileName = $compiler
        $compile.Arguments = $compileArguments
        $compile.UseShellExecute = $false
        $compile.CreateNoWindow = $true
        $compilerProcess = [Diagnostics.Process]::Start($compile)
        $compilerProcess.WaitForExit()
        if ($compilerProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "The native argument recorder compiler exited with code $($compilerProcess.ExitCode)."
        }
        return $fullPath
    }
}
