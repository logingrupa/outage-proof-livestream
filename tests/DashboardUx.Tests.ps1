# DashboardUx.Tests.ps1
# Source/text-assertion regression tests for the DASH-04/05/06/07/08 dashboard UX
# wiring (Task 4). Following STATE.md's established "source/text-assertion
# regression test" convention (05.1-05) for wiring that crosses a boundary a plain
# behavioral mock cannot observe -- here, the plain-HTML/JS/CSS boundary that no
# Pester mock can drive without a real browser DOM. These tests prove the WIRING
# exists (new ids present, frozen ids preserved, load order correct, the pure
# helpers and the /api/config POST are referenced); the actual pixels/interaction
# are confirmed by the plan's checkpoint:human-verify task, not here.

BeforeAll {
    $script:DashboardRoot = Join-Path $PSScriptRoot '../dashboard'
    $script:IndexHtmlPath = Join-Path $script:DashboardRoot 'index.html'
    $script:AppJsPath = Join-Path $script:DashboardRoot 'app.js'
    $script:AppCssPath = Join-Path $script:DashboardRoot 'app.css'

    $script:IndexHtmlText = Get-Content -LiteralPath $script:IndexHtmlPath -Raw
    $script:AppJsText = Get-Content -LiteralPath $script:AppJsPath -Raw
    $script:AppCssText = Get-Content -LiteralPath $script:AppCssPath -Raw
}

Describe 'Dashboard UX wiring (DASH-04/05/06/07/08, Task 4)' -Tag 'Quick' {

    Context 'index.html -- new ids present, frozen ids preserved, script load order' {

        It 'contains every new sticky-header id (DASH-04)' {
            @('sticky-delay', 'sticky-send-bitrate', 'sticky-record-bitrate', 'sticky-percent-sent') | ForEach-Object {
                $script:IndexHtmlText | Should -Match ("id=`"$_`"")
            }
        }

        It 'contains every new catch-up-slider id (DASH-05)' {
            @('catchup-slider', 'catchup-slider-value', 'catchup-effective') | ForEach-Object {
                $script:IndexHtmlText | Should -Match ("id=`"$_`"")
            }
        }

        It 'contains the new catch-up-ratio and last-send metric row ids (DASH-07/DASH-08)' {
            @('metric-catchup-ratio', 'metric-last-send') | ForEach-Object {
                $script:IndexHtmlText | Should -Match ("id=`"$_`"")
            }
        }

        It 'still contains every frozen id that must be preserved (additive-only ids contract)' {
            @('connection-pill', 'metric-catchup-utilization', 'timeline-sent-label', 'timeline-pending-label', 'setting-CATCH_UP_MULTIPLIER') | ForEach-Object {
                $script:IndexHtmlText | Should -Match ("id=`"$_`"")
            }
        }

        It 'does not add a second connection pill -- exactly one element carries id="connection-pill"' {
            ([regex]::Matches($script:IndexHtmlText, 'id="connection-pill"')).Count | Should -Be 1
        }

        It 'references format.js BEFORE app.js so window.DashboardFormat exists at render time' {
            $formatIndex = $script:IndexHtmlText.IndexOf('src="format.js"')
            $appIndex = $script:IndexHtmlText.IndexOf('src="app.js"')
            $formatIndex | Should -BeGreaterThan -1
            $appIndex | Should -BeGreaterThan -1
            $formatIndex | Should -BeLessThan $appIndex
        }
    }

    Context 'app.css -- mobile-first sticky header (DASH-04)' {

        It 'makes .header-bar sticky' {
            $script:AppCssText | Should -Match 'position:\s*sticky'
        }

        It 'header-bar carries a top:0 rule alongside the sticky position' {
            $script:AppCssText | Should -Match 'top:\s*0'
        }
    }

    Context 'app.js -- pure-helper + slider + MB-label + catch-up/last-send wiring' {

        It 'references DashboardFormat.formatMegabytes' {
            $script:AppJsText | Should -Match 'DashboardFormat\.formatMegabytes'
        }

        It 'references DashboardFormat.computeEffectiveCatchUp' {
            $script:AppJsText | Should -Match 'DashboardFormat\.computeEffectiveCatchUp'
        }

        It 'references the new metric-last-send id' {
            $script:AppJsText | Should -Match 'metric-last-send'
        }

        It 'references the new catchup-slider id' {
            $script:AppJsText | Should -Match 'catchup-slider'
        }

        It 'posts CATCH_UP_MULTIPLIER to /api/config' {
            $script:AppJsText | Should -Match '/api/config'
            $script:AppJsText | Should -Match 'CATCH_UP_MULTIPLIER'
        }

        It 'never writes probe/user-controlled or formatted values via innerHTML (existing XSS discipline preserved)' {
            $script:AppJsText | Should -Not -Match '\.innerHTML\s*='
        }
    }
}

Describe 'Dashboard Draining header swap (15-03 Task 2, CHUR-03/D-10)' -Tag 'Quick' {

    Context 'index.html -- new sticky-header label ids present, frozen value ids preserved' {

        It 'contains every new sticky-header label id' {
            @('sticky-delay-label', 'sticky-send-bitrate-label', 'sticky-record-bitrate-label', 'sticky-percent-sent-label') | ForEach-Object {
                $script:IndexHtmlText | Should -Match ("id=`"$_`"")
            }
        }

        It 'still contains every frozen sticky-header value id (DASH-04 additive-only ids contract)' {
            @('sticky-delay', 'sticky-send-bitrate', 'sticky-record-bitrate', 'sticky-percent-sent') | ForEach-Object {
                $script:IndexHtmlText | Should -Match ("id=`"$_`"")
            }
        }
    }

    Context 'app.js -- Draining label literals + formatter wiring for the sticky-header slots' {

        It 'references all four Draining label literals (Left / Drain rate / Remaining / ETA)' {
            @('Left', 'Drain rate', 'Remaining', 'ETA') | ForEach-Object {
                $script:AppJsText | Should -Match ([regex]::Escape("`"$_`""))
            }
        }

        It 'references DashboardFormat.formatMegabytes (Remaining slot) and DashboardFormat.formatHumanDuration (ETA slot)' {
            $script:AppJsText | Should -Match 'DashboardFormat\.formatMegabytes'
            $script:AppJsText | Should -Match 'DashboardFormat\.formatHumanDuration'
        }
    }
}

Describe 'Dashboard Metrics panel regroup (15-03 Task 3, D-11)' -Tag 'Quick' {

    Context 'index.html -- three captioned groups, all ten metric row ids intact' {

        It 'contains exactly three metrics-group-caption elements' {
            ([regex]::Matches($script:IndexHtmlText, 'metrics-group-caption')).Count | Should -Be 3
        }

        It 'the three caption texts appear in the fixed order Flow, Position, Connection' {
            $flowIndex = $script:IndexHtmlText.IndexOf('metrics-group-caption">Flow<')
            $positionIndex = $script:IndexHtmlText.IndexOf('metrics-group-caption">Position<')
            $connectionIndex = $script:IndexHtmlText.IndexOf('metrics-group-caption">Connection<')
            $flowIndex | Should -BeGreaterThan -1
            $positionIndex | Should -BeGreaterThan -1
            $connectionIndex | Should -BeGreaterThan -1
            $flowIndex | Should -BeLessThan $positionIndex
            $positionIndex | Should -BeLessThan $connectionIndex
        }

        It 'still contains every one of the ten frozen metric row ids' {
            @(
                'metric-send-bitrate', 'metric-record-bitrate', 'metric-nic-upload',
                'metric-offset', 'metric-catchup-ratio', 'metric-catchup-utilization',
                'metric-connection-state', 'metric-backoff-streak', 'metric-cumulative-reconnects',
                'metric-last-send', 'metric-uptime'
            ) | ForEach-Object {
                $script:IndexHtmlText | Should -Match ("id=`"$_`"")
            }
        }

        It 'renders exactly three .metrics-grid elements (one per group, scoped not shared)' {
            ([regex]::Matches($script:IndexHtmlText, 'class="metrics-grid"')).Count | Should -Be 3
        }

        It 'still has exactly one metrics-heading (the three captions are not a second heading)' {
            ([regex]::Matches($script:IndexHtmlText, 'id="metrics-heading"')).Count | Should -Be 1
        }
    }

    Context 'app.css -- new structural classes, zero new color' {

        It 'contains the .metrics-group rule' {
            $script:AppCssText | Should -Match '\.metrics-group\s*\{'
        }

        It 'contains the .metrics-group-caption rule' {
            $script:AppCssText | Should -Match '\.metrics-group-caption\s*\{'
        }

        It 'introduces no NEW destructive red (#EF4444 count unchanged from the pre-existing --color-destructive definition)' {
            ([regex]::Matches($script:AppCssText, '#EF4444')).Count | Should -Be 1
        }
    }
}

Describe 'Dashboard VPS health pill (15-06 Task 1, D-12)' -Tag 'Quick' {

    Context 'index.html -- pill/detail ids, five fixed check rows in fixed order' {

        It 'contains id="vps-health-pill" and id="vps-health-detail"' {
            $script:IndexHtmlText | Should -Match 'id="vps-health-pill"'
            $script:IndexHtmlText | Should -Match 'id="vps-health-detail"'
        }

        It 'contains exactly five vps-health-check-row elements' {
            ([regex]::Matches($script:IndexHtmlText, 'vps-health-check-row')).Count | Should -Be 5
        }

        It 'contains exactly five vps-health-check-dot elements' {
            ([regex]::Matches($script:IndexHtmlText, 'vps-health-check-dot')).Count | Should -Be 5
        }

        It 'the five check-row labels appear in the fixed order Ingest, YouTube LV, YouTube RU, Tunnel, Port' {
            $labels = @('Ingest', 'YouTube LV', 'YouTube RU', 'Tunnel', 'Port')
            $indexes = $labels | ForEach-Object {
                $script:IndexHtmlText.IndexOf("vps-health-check-label`">$_<")
            }
            for ($i = 0; $i -lt $indexes.Count; $i += 1) {
                $indexes[$i] | Should -BeGreaterThan -1
            }
            for ($i = 1; $i -lt $indexes.Count; $i += 1) {
                $indexes[$i] | Should -BeGreaterThan $indexes[$i - 1]
            }
        }

        It 'is placed inside .header-status, after #connection-pill and before the Behind live metric' {
            $connectionPillIndex = $script:IndexHtmlText.IndexOf('id="connection-pill"')
            $vpsPillIndex = $script:IndexHtmlText.IndexOf('id="vps-health-pill"')
            $behindLiveIndex = $script:IndexHtmlText.IndexOf('id="header-behind-live"')
            $connectionPillIndex | Should -BeLessThan $vpsPillIndex
            $vpsPillIndex | Should -BeLessThan $behindLiveIndex
        }
    }

    Context 'app.css -- nine new additive classes, zero new custom properties' {

        It 'contains all nine new VPS health pill class rules' {
            @(
                '.vps-health-details', '.vps-health-summary', '.vps-health-detail',
                '.vps-health-check-row', '.vps-health-check-dot', '.vps-health-check-label',
                '.vps-health-check-detail'
            ) | ForEach-Object {
                $script:AppCssText | Should -Match ([regex]::Escape($_) + '\s*\{|' + [regex]::Escape($_) + ',')
            }
        }

        It 'defines no new custom property inside :root (design-token-only reuse)' {
            $rootMatch = [regex]::Match($script:AppCssText, ':root\s*\{([\s\S]*?)\n\}')
            $rootMatch.Success | Should -BeTrue
            $rootBlock = $rootMatch.Groups[1].Value
            $rootDeclarationCount = ([regex]::Matches($rootBlock, '(?m)^\s*--[\w-]+:')).Count
            # Pre-existing :root custom properties (05-UI-SPEC baseline) -- this
            # plan introduces none, so the count must stay exactly as before.
            $rootDeclarationCount | Should -Be 25
        }
    }
}

Describe 'Dashboard VPS health pill render logic (15-06 Task 2, D-12/D-13)' -Tag 'Quick' {

    Context 'app.js -- probe entry lookup, shared display-state helper, fixed label literals' {

        It 'references vps-relay (the probe name this pill looks up)' {
            $script:AppJsText | Should -Match 'vps-relay'
        }

        It 'references resolveProbeDisplayState at least twice (existing probe panel + new pill)' {
            ([regex]::Matches($script:AppJsText, 'resolveProbeDisplayState')).Count | Should -BeGreaterOrEqual 2
        }

        It 'references the vps-health-pill id' {
            $script:AppJsText | Should -Match 'vps-health-pill'
        }

        It 'references all five fixed check-row label literals' {
            @('Ingest', 'YouTube LV', 'YouTube RU', 'Tunnel', 'Port') | ForEach-Object {
                $script:AppJsText | Should -Match ([regex]::Escape("`"$_`""))
            }
        }

        It 'references all three dot state classes' {
            @('state-streaming', 'state-idle', 'state-unknown') | ForEach-Object {
                $script:AppJsText | Should -Match ([regex]::Escape($_))
            }
        }

        It 'VPS_HEALTH_VALUE_TO_DOT_CLASS maps the Port leg''s "in use" state to the healthy (state-streaming) class (260809-oc4: passive ss-derived ESTABLISHED-session state)' {
            $mapMatch = [regex]::Match($script:AppJsText, 'VPS_HEALTH_VALUE_TO_DOT_CLASS\s*=\s*\{[\s\S]*?\n  \};')
            $mapMatch.Success | Should -BeTrue
            $mapMatch.Value | Should -Match '"in use":\s*"state-streaming"'
        }

        It 'renderVpsHealthPill contains no innerHTML assignment (T-15-06-01)' {
            $functionMatch = [regex]::Match($script:AppJsText, 'function renderVpsHealthPill[\s\S]*?\n  \}')
            $functionMatch.Success | Should -BeTrue
            $functionMatch.Value | Should -Not -Match '\.innerHTML\s*='
        }

        It 'setVpsHealthRow contains no innerHTML assignment (T-15-06-01)' {
            $functionMatch = [regex]::Match($script:AppJsText, 'function setVpsHealthRow[\s\S]*?\n  \}')
            $functionMatch.Success | Should -BeTrue
            $functionMatch.Value | Should -Not -Match '\.innerHTML\s*='
        }
    }
}
