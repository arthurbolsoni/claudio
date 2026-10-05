# claudio — escolhe um diretório usado recentemente com o Claude e abre uma sessão nova nele.
# Teclas: ↑/↓ navegar · digitar filtra · Enter abre · Ctrl+F favorita · Esc sai
# Se o filtro for um caminho existente, Enter abre esse caminho.

$ErrorActionPreference = 'Stop'
$projectsDir = Join-Path $HOME '.claude\projects'
$stateDir    = Join-Path $HOME '.claudio'
$favFile     = Join-Path $stateDir 'favorites.json'
$e = [char]27

function Load-Favorites {
    if (Test-Path $favFile) { @(Get-Content $favFile -Raw | ConvertFrom-Json) } else { @() }
}

function Save-Favorites($list) {
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory $stateDir | Out-Null }
    ConvertTo-Json -InputObject @($list) | Set-Content $favFile -Encoding utf8
}

# Lê o "cwd" real das sessões (o nome da pasta em ~/.claude/projects é lossy).
function Get-RecentDirs {
    $byPath = @{}
    foreach ($proj in Get-ChildItem $projectsDir -Directory -ErrorAction SilentlyContinue) {
        $sessions = @(Get-ChildItem $proj.FullName -Filter *.jsonl -File | Sort-Object LastWriteTime -Descending)
        if (-not $sessions) { continue }
        $cwd = $null
        foreach ($s in $sessions | Select-Object -First 3) {
            foreach ($line in Get-Content $s.FullName -TotalCount 50) {
                if ($line -match '"cwd":"((?:[^"\\]|\\.)*)"') { $cwd = $Matches[1] -replace '\\\\', '\'; break }
            }
            if ($cwd) { break }
        }
        if (-not $cwd) { continue }
        $key = $cwd.ToLower().TrimEnd('\')
        $last = $sessions[0].LastWriteTime
        if ($byPath.ContainsKey($key)) {
            $byPath[$key].Count += $sessions.Count
            if ($last -gt $byPath[$key].Last) { $byPath[$key].Last = $last }
        } else {
            $byPath[$key] = [pscustomobject]@{ Path = $cwd; Last = $last; Count = $sessions.Count }
        }
    }
    $byPath.Values
}

function Format-Ago([datetime]$t) {
    $d = (Get-Date) - $t
    if ($d.TotalMinutes -lt 60) { return '{0}min' -f [int]$d.TotalMinutes }
    if ($d.TotalHours -lt 24)   { return '{0}h' -f [int]$d.TotalHours }
    return '{0}d' -f [int]$d.TotalDays
}

$recent = @(Get-RecentDirs)
$favorites = [System.Collections.Generic.List[string]]::new()
foreach ($f in Load-Favorites) { $favorites.Add($f) }

function Build-Items {
    $favSet = @{}; foreach ($f in $favorites) { $favSet[$f.ToLower().TrimEnd('\')] = $true }
    $items = foreach ($r in $recent) {
        [pscustomobject]@{ Path = $r.Path; Last = $r.Last; Count = $r.Count; Fav = $favSet.ContainsKey($r.Path.ToLower().TrimEnd('\')) }
    }
    # Favoritos que não aparecem nas sessões continuam na lista.
    $known = @{}; foreach ($i in $items) { $known[$i.Path.ToLower().TrimEnd('\')] = $true }
    $extra = foreach ($f in $favorites) {
        if (-not $known.ContainsKey($f.ToLower().TrimEnd('\'))) { [pscustomobject]@{ Path = $f; Last = [datetime]::MinValue; Count = 0; Fav = $true } }
    }
    @(@($items) + @($extra) | Sort-Object @{ e = { -not $_.Fav } }, @{ e = { $_.Last }; Descending = $true })
}

$all = Build-Items
$filter = ''
$sel = 0
$top = 0

[Console]::TreatControlCAsInput = $true
[Console]::Write("$e[?1049h$e[?25l")
try {
    while ($true) {
        $view = @(if ($filter) {
            $terms = $filter.ToLower() -split '\s+' | Where-Object { $_ }
            $all | Where-Object { $p = $_.Path.ToLower(); -not ($terms | Where-Object { -not $p.Contains($_) }) }
        } else { $all })

        if ($sel -ge $view.Count) { $sel = [Math]::Max(0, $view.Count - 1) }
        $rows = [Math]::Max(3, [Console]::WindowHeight - 5)
        $width = [Console]::WindowWidth - 1
        if ($sel -lt $top) { $top = $sel }
        if ($sel -ge $top + $rows) { $top = $sel - $rows + 1 }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("$e[H$e[2J")
        [void]$sb.Append("$e[1;35m claudio$e[0m  $e[2m↑↓ navegar · digitar filtra · Enter abre · Ctrl+F favorito · Esc sai$e[0m`n")
        [void]$sb.Append(" $e[36m>$e[0m $filter$e[7m $e[0m`n`n")
        if (-not $view.Count) {
            $hint = if ($filter -and (Test-Path -LiteralPath $filter -PathType Container)) { 'Enter abre esse caminho' } else { 'nada encontrado' }
            [void]$sb.Append("   $e[2m$hint$e[0m`n")
        }
        for ($i = $top; $i -lt [Math]::Min($view.Count, $top + $rows); $i++) {
            $it = $view[$i]
            $star = if ($it.Fav) { "$e[33m★$e[0m" } else { ' ' }
            $meta = if ($it.Count) { '{0,5}  {1,3}x' -f (Format-Ago $it.Last), $it.Count } else { '' }
            $exists = Test-Path -LiteralPath $it.Path -PathType Container
            $maxPath = $width - 18
            $p = if ($it.Path.Length -gt $maxPath) { '…' + $it.Path.Substring($it.Path.Length - $maxPath + 1) } else { $it.Path }
            $line = ' {0} {1}' -f $p.PadRight($maxPath), $meta
            if ($i -eq $sel)      { [void]$sb.Append("$star$e[7m$line$e[0m`n") }
            elseif (-not $exists) { [void]$sb.Append("$star$e[9;2m$line$e[0m`n") }
            else                  { [void]$sb.Append("$star$line`n") }
        }
        [Console]::Write($sb.ToString())

        $k = [Console]::ReadKey($true)
        $ctrl = $k.Modifiers -band [ConsoleModifiers]::Control
        switch ($k.Key) {
            'Escape'    { if ($filter) { $filter = ''; $sel = 0 } else { return } ; continue }
            'UpArrow'   { if ($sel -gt 0) { $sel-- }; continue }
            'DownArrow' { if ($sel -lt $view.Count - 1) { $sel++ }; continue }
            'PageUp'    { $sel = [Math]::Max(0, $sel - $rows); continue }
            'PageDown'  { $sel = [Math]::Max(0, [Math]::Min($view.Count - 1, $sel + $rows)); continue }
            'Home'      { $sel = 0; continue }
            'End'       { $sel = [Math]::Max(0, $view.Count - 1); continue }
            'Backspace' { if ($filter) { $filter = $filter.Substring(0, $filter.Length - 1); $sel = 0 }; continue }
            'Enter' {
                $target = if ($view.Count) { $view[$sel].Path } elseif ($filter -and (Test-Path -LiteralPath $filter -PathType Container)) { (Resolve-Path -LiteralPath $filter).Path }
                if ($target) {
                    if (-not (Test-Path -LiteralPath $target -PathType Container)) { continue }
                    [Console]::Write("$e[?25h$e[?1049l")
                    [Console]::TreatControlCAsInput = $false
                    Set-Location -LiteralPath $target
                    Write-Host "cd $target" -ForegroundColor DarkGray
                    & claude --dangerously-skip-permissions @args
                    exit $LASTEXITCODE
                }
                continue
            }
        }
        if ($ctrl -and $k.Key -eq 'F' -and $view.Count) {
            $path = $view[$sel].Path
            $existing = $favorites | Where-Object { $_.ToLower().TrimEnd('\') -eq $path.ToLower().TrimEnd('\') }
            if ($existing) { foreach ($x in @($existing)) { [void]$favorites.Remove($x) } } else { $favorites.Add($path) }
            Save-Favorites $favorites
            $all = Build-Items
            $sel = [Math]::Max(0, [Array]::FindIndex([object[]]$all, [Predicate[object]] { param($o) $o.Path -eq $path }))
            if ($filter) { $sel = 0 }
            continue
        }
        if ($ctrl -and $k.Key -eq 'C') { return }
        if (-not $ctrl -and $k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { $filter += $k.KeyChar; $sel = 0 }
    }
}
finally {
    [Console]::TreatControlCAsInput = $false
    [Console]::Write("$e[?25h$e[?1049l")
}
