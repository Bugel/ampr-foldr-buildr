#Requires -Version 5.1
<#
.SYNOPSIS
  Ampr Foldr Buildr — stage ampr_emu libSceAmpr.sprx into ShadowMount backport folders.

.DESCRIPTION
  By default, downloads the game list from the APR compatibility tracker and
  creates one backport folder per PPSA ID in ShadowMount layout:

    <OutputRoot>/data/homebrew/backports/PPSAxxxxx/fakelib/libSceAmpr.sprx

  Deploy to the PS5 (copy the data folder):

    <OutputRoot>/data/  ->  /data/

  Which lands at:

    /data/homebrew/backports/PPSAxxxxx/fakelib/libSceAmpr.sprx

  Pass -GamesRoot to scan local dump folders instead (reads sce_sys/param.json).

.PARAMETER AprSource
  Path to ampr_emu folder or libSceAmpr.sprx file.

.PARAMETER GamesRoot
  Optional. Scan local dump folder(s) instead of the APR tracker.

.PARAMETER TrackerUrl
  CSV URL for the tracker game list (default: apr-tracker games.csv).

.PARAMETER Status
  Filter tracker rows: All, Working, Issues, or Crash.

.PARAMETER LinkMode
  Copy | HardLink | SymbolicLink. Default Copy (safest for FTP).

.EXAMPLE
  .\ampr-foldr-buildr.ps1 -AprSource "C:\Users\Bret\Downloads\ampr_emu_0.2b"

.EXAMPLE
  .\ampr-foldr-buildr.cmd -AprSource "...\ampr_emu_0.2b" -Status Working -LinkMode HardLink
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AprSource,

    [string]$GamesRoot,

    [string]$TrackerUrl = 'https://apr-tracker.netlify.app/games.csv',

    [ValidateSet('All', 'Working', 'Issues', 'Crash')]
    [string]$Status = 'All',

    [string]$OutputRoot = (Join-Path (Get-Location) 'export'),

    [ValidateSet('Copy', 'HardLink', 'SymbolicLink')]
    [string]$LinkMode = 'Copy',

    [switch]$UseDebugBuild,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AprSprxPath {
    param([string]$Source, [switch]$UseDebug)

    $src = $Source.TrimEnd('\', '/')
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        return (Resolve-Path -LiteralPath $src).Path
    }
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        throw "APR source not found: $Source"
    }

    $candidates = @()
    if ($UseDebug) { $candidates += Join-Path $src 'debug\libSceAmpr.sprx' }
    $candidates += Join-Path $src 'libSceAmpr.sprx'
    if (-not $UseDebug) { $candidates += Join-Path $src 'debug\libSceAmpr.sprx' }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    throw "No libSceAmpr.sprx under: $Source"
}

function Normalize-TitleId {
    param([string]$Value)

    if (-not $Value) { return $null }
    $v = $Value.Trim()
    if ($v -eq '' -or $v -eq '-' -or $v -eq ([string][char]0x2013)) { return $null }
    if ($v -match '^(PPSA\d{5}|CUSA\d{5})') { return $Matches[1] }
    return $null
}

function Get-TrackerTitleEntries {
    param(
        [string]$Url,
        [string]$StatusFilter
    )

    Write-Host "Fetching tracker: $Url"
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
    } catch {
        throw "Failed to download tracker CSV: $($_.Exception.Message)"
    }

    $rows = @($response.Content | ConvertFrom-Csv)
    $byId = @{}
    $skipped = @()

    foreach ($row in $rows) {
        if ($StatusFilter -ne 'All' -and $row.Status -ne $StatusFilter) { continue }

        $ppsaField = $row.PSObject.Properties['PPSA ID'].Value
        $titleId = Normalize-TitleId -Value ([string]$ppsaField)
        if (-not $titleId) {
            $skipped += [pscustomobject]@{
                Game   = [string]$row.Game
                Status = [string]$row.Status
                Reason = 'no PPSA ID in tracker'
            }
            continue
        }

        if (-not $byId.ContainsKey($titleId)) {
            $byId[$titleId] = [pscustomobject]@{
                TitleId = $titleId
                Game    = [string]$row.Game
                Status  = [string]$row.Status
                Source  = 'apr-tracker'
            }
        }
    }

    return @{
        Entries = @($byId.Values)
        Skipped = @($skipped)
    }
}

function Find-ParamJson {
    param([string]$Root)

    $direct = Join-Path $Root 'sce_sys\param.json'
    if (Test-Path -LiteralPath $direct) { return $direct }

    $nested = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'sce_sys\param.json' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if ($nested) { return $nested }

    $deep = Get-ChildItem -LiteralPath $Root -Recurse -Filter 'param.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'sce_sys' } |
        Select-Object -First 1
    if ($deep) { return $deep.FullName }
    return $null
}

function Get-TitleIdFromParam {
    param([string]$ParamPath)

    $raw = Get-Content -LiteralPath $ParamPath -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json
    $titleId = Normalize-TitleId -Value $json.titleId
    if (-not $titleId) { throw "Unrecognized titleId in $ParamPath" }
    return $titleId
}

function Test-GameDumpRoot {
    param([string]$Root)
    if (Test-Path -LiteralPath (Join-Path $Root 'eboot.bin')) { return $true }
    if (Find-ParamJson -Root $Root) { return $true }
    return $false
}

function Get-LocalTitleEntries {
    param([string]$Root)

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $candidates = if (Test-GameDumpRoot -Root $rootPath) {
        @($rootPath)
    } else {
        Get-ChildItem -LiteralPath $rootPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-GameDumpRoot -Root $_.FullName } |
            Select-Object -ExpandProperty FullName
    }

    if ($candidates.Count -eq 0) {
        throw "No game dumps found under: $Root"
    }

    $entries = @()
    foreach ($dump in $candidates) {
        $param = Find-ParamJson -Root $dump
        $titleId = $null
        $source = ''

        if ($param) {
            $titleId = Get-TitleIdFromParam -ParamPath $param
            $source = 'param.json'
        } else {
            $titleId = Normalize-TitleId -Value (Split-Path -Leaf $dump)
            if ($titleId) { $source = 'folder name' }
        }

        if (-not $titleId) {
            Write-Warning "Skipping $(Split-Path -Leaf $dump): no title ID found"
            continue
        }

        $entries += [pscustomobject]@{
            TitleId = $titleId
            Game    = Split-Path -Leaf $dump
            Status  = '-'
            Source  = $source
        }
    }

    return $entries
}

function Ensure-Directory {
    param([string]$Path)
    if ($DryRun) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-RelativePath {
    param(
        [string]$FromDir,
        [string]$ToFile
    )

    $from = (Resolve-Path -LiteralPath $FromDir).Path
    if (-not $from.EndsWith('\')) { $from += '\' }
    $to = (Resolve-Path -LiteralPath $ToFile).Path

    $fromUri = New-Object System.Uri($from)
    $toUri = New-Object System.Uri($to)
    return [Uri]::UnescapeDataString(
        $fromUri.MakeRelativeUri($toUri).ToString()
    ).Replace('/', '\')
}

function Install-AprIntoFakelib {
    param(
        [string]$CanonicalApr,
        [string]$FakelibDir,
        [string]$Mode
    )

    $dest = Join-Path $FakelibDir 'libSceAmpr.sprx'
    Ensure-Directory -Path $FakelibDir

    if ((Test-Path -LiteralPath $dest) -and -not $DryRun) {
        Remove-Item -LiteralPath $dest -Force
    }

    switch ($Mode) {
        'Copy' {
            if ($DryRun) {
                Write-Host "[dry-run] copy -> $dest"
            } else {
                Copy-Item -LiteralPath $CanonicalApr -Destination $dest -Force
            }
        }
        'HardLink' {
            if ($DryRun) {
                Write-Host "[dry-run] hardlink -> $dest"
            } else {
                New-Item -ItemType HardLink -Path $dest -Target $CanonicalApr -Force | Out-Null
            }
        }
        'SymbolicLink' {
            $rel = Get-RelativePath -FromDir $FakelibDir -ToFile $CanonicalApr
            if ($DryRun) {
                Write-Host "[dry-run] symlink $rel -> $dest"
            } else {
                Push-Location -LiteralPath $FakelibDir
                try {
                    New-Item -ItemType SymbolicLink -Path (Split-Path -Leaf $dest) -Target $rel -Force | Out-Null
                } finally {
                    Pop-Location
                }
            }
        }
    }
}

function Write-SidecarReports {
    param(
        [string]$OutRoot,
        [array]$Created,
        [array]$Skipped
    )

    if ($DryRun) { return }

    $metaRoot = Join-Path $OutRoot '.buildr'
    Ensure-Directory -Path $metaRoot

    $manifest = Join-Path $metaRoot 'tracker-manifest.csv'
    $created | Sort-Object TitleId | Export-Csv -LiteralPath $manifest -NoTypeInformation -Encoding UTF8

    if ($Skipped.Count -gt 0) {
        $skipPath = Join-Path $metaRoot 'skipped-no-ppsa.csv'
        $Skipped | Export-Csv -LiteralPath $skipPath -NoTypeInformation -Encoding UTF8
        Write-Host "Skipped $($Skipped.Count) tracker game(s) without PPSA ID -> $skipPath"
    }
}

$aprFile = Resolve-AprSprxPath -Source $AprSource -UseDebug:$UseDebugBuild
$skipped = @()

if ($GamesRoot) {
    Write-Host "Mode: local dumps"
    $titleEntries = @(Get-LocalTitleEntries -Root $GamesRoot)
} else {
    Write-Host "Mode: APR tracker (status filter: $Status)"
    $tracker = Get-TrackerTitleEntries -Url $TrackerUrl -StatusFilter $Status
    $titleEntries = @($tracker.Entries)
    $skipped = @($tracker.Skipped)
}

if (@($titleEntries).Count -eq 0) {
    throw 'No title entries to process.'
}

$outRoot = $OutputRoot
$metaRoot = Join-Path $outRoot '.buildr'
$canonical = Join-Path $metaRoot 'libSceAmpr.sprx'
$backportsRoot = Join-Path $outRoot 'data\homebrew\backports'

Ensure-Directory -Path $outRoot
Ensure-Directory -Path $metaRoot
Ensure-Directory -Path $backportsRoot

if ($DryRun) {
    Write-Host "[dry-run] canonical APR -> $canonical"
} elseif (-not (Test-Path -LiteralPath $canonical) -or
    (Get-FileHash -LiteralPath $canonical).Hash -ne (Get-FileHash -LiteralPath $aprFile).Hash) {
    Copy-Item -LiteralPath $aprFile -Destination $canonical -Force
    Write-Host "Staged canonical APR -> $canonical"
} else {
    Write-Host "Canonical APR already up to date -> $canonical"
}

$created = @()
foreach ($entry in @($titleEntries | Sort-Object TitleId)) {
    $fakelibDir = Join-Path (Join-Path $backportsRoot $entry.TitleId) 'fakelib'
    Write-Host "[$($entry.TitleId)] $($entry.Game) ($($entry.Status)) -> $fakelibDir"
    Install-AprIntoFakelib -CanonicalApr $canonical -FakelibDir $fakelibDir -Mode $LinkMode
    $created += $entry
}

Write-SidecarReports -OutRoot $outRoot -Created $created -Skipped $skipped

Write-Host ""
Write-Host "Done. Created/updated $($created.Count) title(s) under:"
Write-Host "  $backportsRoot"
if (-not $GamesRoot) {
    Write-Host "Tracker rows: $($titleEntries.Count) with PPSA, $($skipped.Count) skipped (no PPSA ID)"
}
Write-Host ""
Write-Host "Deploy to PS5:"
Write-Host "  $(Join-Path $outRoot 'data')\  ->  /data/"
Write-Host "  (backports land at /data/homebrew/backports/PPSAxxxxx/)"
if (-not $DryRun) {
    $deployNote = Join-Path $outRoot 'DEPLOY.txt'
    @(
        'Copy this folder to the PS5:'
        '  export/data/  ->  /data/'
        ''
        'ShadowMount reads:'
        '  /data/homebrew/backports/PPSAxxxxx/fakelib/libSceAmpr.sprx'
        ''
        'Do not upload .buildr/ - PC build metadata only.'
    ) | Set-Content -LiteralPath $deployNote -Encoding UTF8
    Write-Host "Wrote $deployNote"
}
if ($LinkMode -ne 'Copy') {
    Write-Host ""
    Write-Host "Note: re-run with -LinkMode Copy before FTP if links are not preserved."
}
