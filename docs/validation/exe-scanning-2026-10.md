# EXE marker scan comparison — October 2026

The optimized scanner completed the Obsidian full-marker scan in 28,289 ms and the KiCad scan in 83,656 ms on the Windows acceptance VM. `Get-InstallerInfo` completed in 30,684 ms and 99,112 ms, respectively. Both completed under the 120-second per-operation bound. No installer payload was executed.

## Environment and source identity

- Windows: `Microsoft Windows NT 10.0.26100.0`
- Windows PowerShell: `5.1.26100.9457` (`Desktop`)
- .NET Framework runtime: `4.0.30319.42000`
- VM processor label: `virt-9.1`; 10 logical processors
- Reader chunk size: 4096 bytes
- Production patterns: `NullsoftInst`, `Inno Setup Setup Data`, `InstallShield Setup Launcher`, `SquirrelSetup`, `SquirrelAwareVersion`, and `Installer for Squirrel-based applications`, each searched as ASCII and UTF-16LE (12 byte patterns)
- Optimized reader source SHA-256: `9201CC7739EB2452BC5D5BCB862F9C7528C9C7F0EEF2C7FDA055336046625D7E`
- Framework evidence source SHA-256: `2882A8DA42B35C3B9658788FABB8E172764F67CE89EA7CA5C863DC03FD4EBB0C`
- Scaffold source SHA-256: `740686F7F7B9B077B00D25645B0433B633390A4360AA338A626396416C4FF851`
- Benchmark script SHA-256: `B4DA2C3F58A88384F1F003267ED5FB2D3327C2FCD3DA9F249DA3B417FBE09840`
- Module loader SHA-256: `A34F1A918638B55625A26472628ED2BC06CB369648A8F77B6FFB8B4ADCAE5AC0`

After the measured run, the harness received analyzer-only maintenance: the installer loop variable was renamed to avoid PowerShell's automatic `$input` variable, the synthetic PE writer gained `ShouldProcess` protection, and an unused capture was removed. Current harness SHA-256 is `3015F8D9B4966AD78D29729845DDC47709C8FA79C552DE24DA52A7DABAB2C257`; it was not used to produce `results-04` and the benchmark was not rerun. The measured results remain bound to the earlier script SHA above.

The complete per-file source manifest and final measured JSON are retained at `C:\PSPackageForge-Acceptance\bench-task3-20261005-7E575602-8483-45BB-BBC2-2D535AE06E78\results-04\exe-scan-benchmark.json`. The production sources were uploaded to their matching paths under `C:\PSPackageForge-Acceptance\repo` before the run. The benchmark script passed the Windows PowerShell 5.1 parser.

## Baseline and optimized timings

The preserved baseline is `C:\PSPackageForge-Acceptance\bench-20261005-16a57033387842edb898c29b67734465\supplemental-production-markers-20261005.jsonl`, SHA-256 `32B3064962C91FF3011055EB90DAD8E524F025B1B1D88468580B4E586B2A90E5`. The baseline reader source SHA-256 was `DFD9DB28D7FC5EDD0628E62EB807F1F1526398714F044D0ED744A87E5A4CA19A`; its source-manifest SHA-256 was `449131352F792109A472910EFFD2020D1FD4EB322679B708254A479CC2E2935A`. The baseline observations below were supplied from the preserved benchmark record; its Obsidian scan did not return a result.

| Scenario | Preserved baseline | Current run | Comparison |
| --- | ---: | ---: | ---: |
| Markerless 1 MiB, warm | 2,167 ms | 122 ms | 17.8× faster |
| Markerless 8 MiB, warm | 15,895 ms | 899 ms | 17.7× faster |
| Obsidian full-marker scan | 120,015 ms, right-censored with no result | 28,289 ms | More than 4.24× the censored observation |

The markerless scans returned no markers. Cold compile plus the first 1 MiB scan took 370 ms. Warm early ASCII positive scan took 61 ms and returned all six ASCII markers. Warm late UTF-16LE positive scan took 112 ms and returned all six UTF-16LE markers.

The matcher type was absent before the first read in a fresh PowerShell process and present after scanning the read-only NSIS fixture; that first read returned `NullsoftInst`. Legacy PowerShell-loop outputs matched the optimized scanner on seven fixed framework fixtures and three retained synthetic cases. The synthetic cases checked an ASCII marker across a 4096-byte boundary, a UTF-16LE marker across that boundary, duplicate marker input and ordering, and case sensitivity.

## Signed installer measurements

| Input | SHA-256 | Full marker scan | `Get-InstallerInfo` | Hash | Authenticode | PE header/version resource |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Obsidian 1.13.7, 331,012,528 bytes | `F233DC24896B3F2D5F9E4B01111181A561D0760B2105F0A474024C5F3143A9BC` | 28,289 ms | 30,684 ms | 288 ms | 1,509 ms | 58 ms |
| KiCad 10.0.6, 967,765,696 bytes | `9E24DC47119F7C472128C2F293C5E3F35569274A44C905E60A7514D47C16CE48` | 83,656 ms | 99,112 ms | 849 ms | 4,433 ms | 63 ms |

Both full scans found `NullsoftInst` in ASCII and no UTF-16LE markers. `Get-InstallerInfo` independently returned `Framework = Nsis`, the matching file version and product name, and a valid Authenticode status for each input. The generated NSIS profile is `/S`; the run only read metadata and did not invoke that command.

## Retained outputs and limits

All generated synthetic PE files and reports were retained. The complete successful run is in the `results-04` folder above; the earlier `results`, `results-02`, and `results-03` folders were also retained after earlier harness iterations. The report records the exact current source hashes and baseline identity. The baseline timing values were supplied from the preserved record after an attempted full JSONL export was rejected; its file hash was verified on the VM, and its contents were not exported or independently re-read.

Formal Pester verification remains pending the user's deletion approval because the existing suites use cleanup behavior. The prior Obsidian observation is right-censored, so the reported 4.24× comparison is a lower bound and is not an exact old/new full-scan ratio. The KiCad baseline full-file result and end-to-end baseline timings were not supplied, so no speedup is claimed for them.
