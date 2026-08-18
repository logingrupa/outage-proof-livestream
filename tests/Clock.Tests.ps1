# Clock.Tests.ps1
# Unit tests for lib/Clock.psm1 -- the shared monotonic clock D-06's cross-process
# stats staleness design depends on. Get-MonotonicSeconds was promoted here from
# pusher.ps1's private copy (pusher.ps1:160-168) so supervisor.ps1's dashboard can
# read the SAME clock origin pusher.ps1 writes against.

BeforeAll {
    $script:ClockModulePath = Join-Path $PSScriptRoot '../lib/Clock.psm1'
}

Describe 'Clock' -Tag 'Quick' {

    BeforeEach {
        Remove-Module Clock -ErrorAction SilentlyContinue
        Import-Module $script:ClockModulePath -Force
    }

    AfterEach {
        Remove-Module Clock -ErrorAction SilentlyContinue
    }

    It 'returns a [double] greater than 0' {
        $value = Get-MonotonicSeconds

        $value | Should -BeOfType [double]
        $value | Should -BeGreaterThan 0
    }

    It 'never goes backward -- two calls separated by a sleep produce a non-negative, advancing delta' {
        $first = Get-MonotonicSeconds
        Start-Sleep -Milliseconds 50
        $second = Get-MonotonicSeconds

        $delta = $second - $first

        $delta | Should -BeGreaterOrEqual 0
        # Allow timer slack -- assert the clock genuinely advanced, not merely did not
        # regress, without pinning to the full 50ms (scheduler jitter on a loaded box).
        $delta | Should -BeGreaterThan 0.04
    }

    It 'is comparable across processes -- a value written by a CHILD pwsh process compares sanely against the PARENT`s own reading (RESEARCH A3, confirmed by the 05-01 spike)' {
        # Reproduces spike/Confirm-DashboardHost.ps1's Q2 exactly, but calls the real
        # exported Get-MonotonicSeconds through the real module rather than inlining the
        # Stopwatch expression -- this is the actual cross-process contract D-06's
        # staleness design depends on, not a simulation.
        $scratchDirectoryPath = Join-Path $TestDrive ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $scratchDirectoryPath -Force | Out-Null

        $writerResultFilePath = Join-Path $scratchDirectoryPath 'writer-result.txt'
        $writerScriptFilePath = Join-Path $scratchDirectoryPath 'Write-ChildMonotonicSeconds.ps1'

        $writerScriptContent = @'
param(
    [Parameter(Mandatory)] [string] $ClockModulePath,
    [Parameter(Mandatory)] [string] $ResultFilePath
)

$ErrorActionPreference = 'Stop'
Import-Module $ClockModulePath -Force
$writerSeconds = Get-MonotonicSeconds
$writerSeconds.ToString('G17', [System.Globalization.CultureInfo]::InvariantCulture) | Out-File -FilePath $ResultFilePath -Encoding utf8
'@
        Set-Content -LiteralPath $writerScriptFilePath -Value $writerScriptContent -Encoding utf8

        $writerProcess = Start-Process -FilePath 'pwsh' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $writerScriptFilePath,
            '-ClockModulePath', $script:ClockModulePath, '-ResultFilePath', $writerResultFilePath
        ) -PassThru -NoNewWindow
        $writerProcess.WaitForExit()

        # Read the PARENT's own reading immediately after the CHILD process exits -- the
        # smallest practical window between the two independent readings.
        $parentSeconds = Get-MonotonicSeconds

        Test-Path -LiteralPath $writerResultFilePath | Should -BeTrue

        $writerSecondsText = (Get-Content -LiteralPath $writerResultFilePath -Raw).Trim()
        $writerSeconds = [double]::Parse($writerSecondsText, [System.Globalization.CultureInfo]::InvariantCulture)

        $delta = $parentSeconds - $writerSeconds

        # Non-negative and nowhere near the per-process-origin failure mode (which would
        # show up as a huge or negative delta, e.g. on the order of host uptime).
        $delta | Should -BeGreaterOrEqual 0
        $delta | Should -BeLessThan 5
    }
}
