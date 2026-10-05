# claudio — escolhe um diretório usado recentemente com o Claude e abre uma sessão nova nele.
# Teclas: ↑/↓ navegar · digitar filtra · Enter abre · Ctrl+F favorita · Esc sai
# Se o filtro for um caminho existente, Enter abre esse caminho.

$ErrorActionPreference = 'Stop'
# Console do Windows costuma estar em codepage 850/437: ★ … ↑↓ viram "?".
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
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

function Get-Key([string]$path) { $path.ToLower().TrimEnd('\') }

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
        $key = Get-Key $cwd
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
    $favSet = @{}; foreach ($f in $favorites) { $favSet[(Get-Key $f)] = $true }
    $items = foreach ($r in $recent) {
        [pscustomobject]@{ Path = $r.Path; Last = $r.Last; Count = $r.Count; Fav = $favSet.ContainsKey((Get-Key $r.Path)) }
    }
    # Favoritos que não aparecem nas sessões continuam na lista.
    $known = @{}; foreach ($i in $items) { $known[(Get-Key $i.Path)] = $true }
    $extra = foreach ($f in $favorites) {
        if (-not $known.ContainsKey((Get-Key $f))) { [pscustomobject]@{ Path = $f; Last = [datetime]::MinValue; Count = 0; Fav = $true } }
    }
    $list = @(@($items) + @($extra) | Sort-Object @{ e = { -not $_.Fav } }, @{ e = { $_.Last }; Descending = $true })
    foreach ($i in $list) { $i | Add-Member Exists (Test-Path -LiteralPath $i.Path -PathType Container) }
    $list
}

function Fit([string]$text, [int]$n) {
    if ($text.Length -le $n) { return $text.PadRight($n) }
    '…' + $text.Substring($text.Length - $n + 1)
}

# Card com borda contendo as linhas $idx[$top..] de $view; $rowsH linhas de conteúdo.
function Render-Panel([string]$title, [int[]]$idx, [int]$top, [int]$rowsH, [int]$w) {
    $iw = $w - 4
    $b = "$e[90m"
    $head = " $title ($($idx.Count)) "
    $out = @("$b╭─$e[0m$e[1;33m$head$e[0m$b$('─' * [Math]::Max(0, $w - 3 - $head.Length))╮$e[0m")
    for ($r = 0; $r -lt $rowsH; $r++) {
        $n = $top + $r
        if ($n -ge $idx.Count) { $out += "$b│$e[0m$(' ' * ($w - 2))$b│$e[0m"; continue }
        $i = $idx[$n]; $it = $view[$i]
        $meta = if ($it.Count) { '{0,9} · {1,-11}' -f ('há ' + (Format-Ago $it.Last)), ('{0} {1}' -f $it.Count, $(if ($it.Count -eq 1) { 'sessão' } else { 'sessões' })) } else { '' }
        $text = (Fit $it.Path ($iw - 24)) + $meta.PadLeft(24)
        $style = if ($i -eq $sel) { "$e[7m" } elseif (-not $it.Exists) { "$e[9;2m" } else { '' }
        $out += "$b│$e[0m $style$text$e[0m $b│$e[0m"
    }
    $foot = if ($idx.Count -gt $rowsH) { " $([Math]::Min($idx.Count, $top + $rowsH))/$($idx.Count) " } else { '' }
    $out += "$b╰$('─' * ($w - 3 - $foot.Length))$e[0m$e[2m$foot$e[0m$b─╯$e[0m"
    $out
}

$all = Build-Items
$filter = ''
$sel = 0
$favTop = 0
$recTop = 0
$focusPath = $null

[Console]::TreatControlCAsInput = $true
[Console]::Write("$e[?1049h$e[?25l")
try {
    while ($true) {
        $view = @(if ($filter) {
            $terms = $filter.ToLower() -split '\s+' | Where-Object { $_ }
            $all | Where-Object { $p = $_.Path.ToLower(); -not ($terms | Where-Object { -not $p.Contains($_) }) }
        } else { $all })
        if ($focusPath) {
            for ($i = 0; $i -lt $view.Count; $i++) { if ($view[$i].Path -eq $focusPath) { $sel = $i } }
            $focusPath = $null
        }
        if ($sel -ge $view.Count) { $sel = [Math]::Max(0, $view.Count - 1) }

        # $view já vem com favoritos primeiro.
        $favIdx = [int[]]@(for ($i = 0; $i -lt $view.Count; $i++) { if ($view[$i].Fav) { $i } })
        $recIdx = [int[]]@(for ($i = 0; $i -lt $view.Count; $i++) { if (-not $view[$i].Fav) { $i } })

        $width = [Console]::WindowWidth - 1
        $avail = [Console]::WindowHeight - 3
        $panels = [int]($favIdx.Count -gt 0) + [int]($recIdx.Count -gt 0)
        $content = [Math]::Max(2, $avail - 2 * $panels)
        $favRows = 0; $recRows = 0
        if ($favIdx.Count -and $recIdx.Count) {
            $favRows = [Math]::Min($favIdx.Count, [Math]::Max(1, [int][Math]::Floor($content / 2)))
            $recRows = [Math]::Min($recIdx.Count, $content - $favRows)
            $favRows = [Math]::Min($favIdx.Count, $content - $recRows)
        } elseif ($favIdx.Count) { $favRows = [Math]::Min($favIdx.Count, $content) }
        else { $recRows = [Math]::Min($recIdx.Count, $content) }

        # Rolagem independente em cada card.
        if ($sel -lt $favIdx.Count) {
            if ($sel -lt $favTop) { $favTop = $sel }
            if ($sel -ge $favTop + $favRows) { $favTop = $sel - $favRows + 1 }
        } elseif ($view.Count) {
            $pos = $sel - $favIdx.Count
            if ($pos -lt $recTop) { $recTop = $pos }
            if ($pos -ge $recTop + $recRows) { $recTop = $pos - $recRows + 1 }
        }
        $favTop = [Math]::Max(0, [Math]::Min($favTop, $favIdx.Count - $favRows))
        $recTop = [Math]::Max(0, [Math]::Min($recTop, $recIdx.Count - $recRows))

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("$e[H")
        [void]$sb.Append("$e[1;35m claudio$e[0m  $e[2m↑↓ navegar · digitar filtra · Enter abre · Ctrl+F favorito · Esc sai$e[0m$e[K`n")
        [void]$sb.Append(" $e[36m>$e[0m $filter$e[7m $e[0m$e[K`n$e[K`n")
        if (-not $view.Count) {
            $hint = if ($filter -and (Test-Path -LiteralPath $filter -PathType Container)) { 'Enter abre esse caminho' } else { 'nada encontrado' }
            [void]$sb.Append("   $e[2m$hint$e[0m$e[K`n")
        }
        $lines = @()
        if ($favIdx.Count) { $lines += Render-Panel '★ Favoritos' $favIdx $favTop $favRows $width }
        if ($recIdx.Count) { $lines += Render-Panel 'Recentes' $recIdx $recTop $recRows $width }
        foreach ($l in $lines) { [void]$sb.Append("$l$e[K`n") }
        [void]$sb.Append("$e[J")
        [Console]::Write($sb.ToString())

        $k = [Console]::ReadKey($true)
        $ctrl = $k.Modifiers -band [ConsoleModifiers]::Control
        $page = [Math]::Max(1, $(if ($sel -lt $favIdx.Count) { $favRows } else { $recRows }))
        switch ($k.Key) {
            'Escape'    { if ($filter) { $filter = ''; $sel = 0 } else { return } ; continue }
            'UpArrow'   { if ($sel -gt 0) { $sel-- }; continue }
            'DownArrow' { if ($sel -lt $view.Count - 1) { $sel++ }; continue }
            'PageUp'    { $sel = [Math]::Max(0, $sel - $page); continue }
            'PageDown'  { $sel = [Math]::Max(0, [Math]::Min($view.Count - 1, $sel + $page)); continue }
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
            $existing = @($favorites | Where-Object { (Get-Key $_) -eq (Get-Key $path) })
            if ($existing) { foreach ($x in $existing) { [void]$favorites.Remove($x) } } else { $favorites.Add($path) }
            Save-Favorites $favorites
            $all = Build-Items
            $focusPath = $path
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
