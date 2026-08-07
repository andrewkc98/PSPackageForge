@{
    # Warnings are treated as errors by build.ps1. A style rule nobody enforces is a style
    # rule nobody follows, so the rule set here is the one we actually intend to obey.
    Severity     = @('Error', 'Warning', 'Information')

    IncludeRules = @('*')

    ExcludeRules = @(
        # --- Deliberate scope decisions -------------------------------------------------
        # The module is Windows-only by design: MSI COM interop, registry views, and
        # Authenticode have no cross-platform equivalent worth faking.
        'PSUseCompatibleCommands'
        'PSUseCompatibleTypes'

        # Write-Host is never used to emit data -- data always goes to the pipeline. It is
        # used only by build.ps1 for human-facing build progress, which is exactly what it
        # is for.
        'PSAvoidUsingWriteHost'

        # --- Formatting rules that contradict each other ---------------------------------
        # These are opt-in formatting rules, not correctness rules. Column-aligned
        # assignments are used throughout this codebase because they make the type contract
        # readable at a glance:
        #
        #     $this.Field      = $field
        #     $this.Confidence = $confidence
        #
        # PSAlignAssignmentStatement asks for exactly that, and PSUseConsistentWhitespace
        # then objects to the padding it requires. They cannot both be satisfied. The
        # aligned style wins because it serves the reader; the rules that fight it are off.
        'PSUseConsistentWhitespace'
        'PSAlignAssignmentStatement'

        # Rejects the hanging-indent style used for multi-line pipelines and calculated
        # properties, both of which are idiomatic PowerShell.
        'PSUseConsistentIndentation'
        'PSPlaceOpenBrace'
        'PSPlaceCloseBrace'
    )

    Rules        = @{
        # Kept, and load-bearing: it caught real breakage. Windows PowerShell 5.1 reads a
        # UTF-8 file with no BOM as ANSI, which corrupts every non-ASCII character in the
        # file. All module source is UTF-8 with BOM for this reason.
        PSUseBOMForUnicodeEncodedFile = @{
            Enable = $true
        }

        # 5.1 is non-negotiable, so syntax that only parses on 7 is an error, not a nit.
        PSUseCompatibleSyntax         = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
