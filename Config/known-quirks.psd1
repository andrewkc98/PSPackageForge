<#
    Known-quirk registry (build order step 9).

    A "quirk" fills a gap the MSI provider deliberately refuses to answer -- most often a
    wrapper MSI (plan §8.1 / MsiKind.Wrapper), where the Directory table describes where the
    payload is *extracted*, not where the product is *installed*. Get-MsiEvidence declines to
    guess in that case (see Private\Providers\Get-MsiEvidence.ps1, MSI_PAYLOAD_NOT_INTROSPECTABLE)
    rather than emit a confident wrong answer. A quirk entry is how a reviewed, honestly
    attributed answer gets supplied instead.

    Provenance, not authority: quirk evidence is emitted with EvidenceSource.KnownQuirk, which
    ranks BELOW MsiDatabase in the merge precedence (see the EvidenceSource enum in
    PSPackageForge.psm1). A quirk can only fill a field the MSI provider left empty; it can
    never outvote a value the MSI actually observed. It also ranks below AdditionalEvidence
    sources such as DiscoveryJson and UserOverride, so a reviewed override always wins over a
    canned quirk. This file is reviewed, checked-in data -- not a live discovery -- and its
    precedence position reflects that.

    ---------------------------------------------------------------------------------------
    SCHEMA (version 1.0)
    ---------------------------------------------------------------------------------------

    @{
        SchemaVersion = '1.0'        # Required. Must be '1.0'; anything else is rejected as
                                      # invalid config (KNOWN_QUIRK_CONFIG_INVALID) rather than
                                      # silently reinterpreted.

        Quirks = @(                  # Optional; an empty or absent array means no quirks are
                                      # configured, which is normal and raises nothing.
            @{
                Id = 'some-id'       # Required. Short, stable, kebab-case identifier. Named in
                                      # KNOWN_QUIRK_APPLIED / KNOWN_QUIRK_CONFIG_INVALID findings
                                      # so an operator can trace a resolved value back to the
                                      # entry that produced it.

                Match = @{
                    # ALL keys present in this table must hold (AND) for the quirk to apply.
                    # A quirk with NEITHER UpgradeCode NOR ProductCode among its Match keys has
                    # no strong identifier and is rejected as invalid config -- matching on
                    # ProductName/Manufacturer text alone is not considered reliable enough to
                    # inject evidence into a package.
                    #
                    #   UpgradeCode / ProductCode
                    #       Exact match against the corresponding identity value read off the
                    #       provider evidence gathered so far (see NOTE below). Compared with
                    #       ConvertTo-ForgeComparableValue, so brace/case differences in the
                    #       GUID text do not matter.
                    #
                    #   <Field>Pattern   (e.g. ManufacturerPattern, ProductNamePattern)
                    #       Regular expression (-match, case-insensitive) tested against the
                    #       identity value for <Field> (Manufacturer, ProductName, ...).
                    #
                    # UpgradeCode is preferred over ProductCode where the installer has both:
                    # a ProductCode changes on every release (a new MSI per version), so pinning
                    # to it means the quirk silently stops matching the next time the vendor
                    # ships an update. UpgradeCode identifies the product family and is stable
                    # across versions -- exactly what a wrapper-MSI quirk needs, since the
                    # wrapper shape itself does not change version to version.
                    UpgradeCode         = '{...}'
                    ManufacturerPattern = '^Some Vendor$'
                    ProductNamePattern  = 'Some Product'
                }

                # Each entry becomes one EvidenceRecord with Source = KnownQuirk, merged in
                # alongside every other provider's evidence and subject to the same precedence
                # and conflict rules as anything else (Private\Resolution\Merge-InstallerEvidence.ps1).
                Evidence = @(
                    @{
                        Field      = 'InstallLocation'   # Any InstallerInfo evidence field name.
                        Value      = 'C:\...'             # Scalar for most fields. For
                                                           # *Command fields (InstallCommand /
                                                           # UninstallCommand) this is instead a
                                                           # hashtable shaped like CommandSpec
                                                           # (Executable / ArgumentList /
                                                           # ExpectedExitCodes / WorkingDirectory)
                                                           # -- Resolve-PackageSpec converts it
                                                           # via ConvertTo-ForgeCommandSpecFromDictionary,
                                                           # this provider never does. Passed
                                                           # through untouched either way.
                        Confidence = 'Medium'              # 'Low' | 'Medium' | 'High'. An
                                                           # unrecognised name is rejected for
                                                           # that one entry (falls back to Low
                                                           # plus KNOWN_QUIRK_CONFIG_INVALID)
                                                           # rather than invalidating the whole
                                                           # quirk.
                        Notes      = 'Why this value is trustworthy.'   # Optional.
                    }
                )

                Notes = 'Human-readable summary of why this quirk exists.'   # Optional.
            }
        )
    }

    NOTE on matching: identity values (ProductName, Manufacturer, UpgradeCode, ProductCode) are
    read from the raw provider evidence gathered so far in Get-InstallerInfo -- i.e. what the
    installer itself claims to be -- not from the post-merge resolved winners. Quirks run before
    the merge (see the hook in Public\Get-InstallerInfo.ps1), and matching on pre-merge provider
    observations is deliberate: a quirk answers "does this file look like the installer I know
    about", which is a question about what the MSI says, independent of whatever AdditionalEvidence
    a caller happened to also supply for this run.

    ---------------------------------------------------------------------------------------
    ENTRIES
    ---------------------------------------------------------------------------------------

    firefox-esr-msi-wrapper
        Real values below were read directly off Installers\Firefox Setup 140.13.0esr.msi via
        Get-InstallerInfo (build order step 9 verification run):

            ProductName   = 'Mozilla Firefox 140.13.0esr x64 en-US'
            Manufacturer  = 'Mozilla'
            UpgradeCode   = '{3118AB4C-B433-4FBB-B9FA-8F9CA4B5C103}'
            ProductCode   = '{1294A4C5-9977-480F-9497-C0EA1E630130}'
            MsiKind       = Wrapper (no File-table payload; runs the bundled NSIS EXE via
                            custom actions RunInstallNoDir / RunInstallDirPath /
                            RunInstallDirName / RunExtractOnly)

        UpgradeCode is used as the match key (both codes are present on this installer, but
        ProductCode is re-minted by Mozilla on every ESR release while UpgradeCode identifies
        the Firefox ESR product family and is stable release over release -- see the preference
        note in the schema comment above). ManufacturerPattern and ProductNamePattern are
        included as corroborating, not load-bearing, signals.

        InstallLocation / DetectionTarget reflect the standard 64-bit ESR install layout under
        %ProgramFiles%\Mozilla Firefox. UninstallCommand points at the NSIS-generated
        uninstall\helper.exe that ships inside that install directory, which supports a silent
        /S switch; msiexec /x does not remove this product (SupportsMsiUninstall is $false --
        see MSI_WRAPPER_DETECTED).
#>
@{
    SchemaVersion = '1.0'

    Quirks = @(
        @{
            Id = 'firefox-esr-msi-wrapper'

            Match = @{
                UpgradeCode         = '{3118AB4C-B433-4FBB-B9FA-8F9CA4B5C103}'
                ManufacturerPattern = '^Mozilla$'
                ProductNamePattern  = 'Firefox'
            }

            Evidence = @(
                @{
                    Field      = 'InstallLocation'
                    Value      = '%ProgramFiles%\Mozilla Firefox'
                    Confidence = 'Medium'
                    Notes      = 'Standard 64-bit Firefox ESR install directory. The MSI is a wrapper (no File-table payload), so Get-MsiEvidence cannot resolve this itself.'
                }
                @{
                    Field      = 'DetectionTarget'
                    Value      = '%ProgramFiles%\Mozilla Firefox\firefox.exe'
                    Confidence = 'Medium'
                    Notes      = 'Primary Firefox executable at the standard 64-bit ESR install location.'
                }
                @{
                    Field      = 'SelectedContext'
                    Value      = 'System'
                    Confidence = 'Medium'
                    Notes      = 'Per-machine install, corroborating the MSI ALLUSERS=1 property signal already read by the MSI provider.'
                }
                @{
                    Field = 'UninstallCommand'
                    Value = @{
                        Executable        = '%ProgramFiles%\Mozilla Firefox\uninstall\helper.exe'
                        ArgumentList      = @('/S')
                        ExpectedExitCodes = @(0)
                    }
                    Confidence = 'Medium'
                    Notes      = 'NSIS-generated vendor uninstaller shipped inside the install directory; the wrapper MSI registers no msiexec-removable product (SupportsMsiUninstall = $false).'
                }
            )

            Notes = 'Wrapper MSI around the vendor NSIS setup executable for Firefox ESR x64; the MSI provider deliberately reports no install location or detection target for it (MSI_PAYLOAD_NOT_INTROSPECTABLE).'
        }
    )
}
