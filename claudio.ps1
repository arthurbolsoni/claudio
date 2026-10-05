# claudio — escolhe um diretório usado recentemente com o Claude e abre uma sessão nova nele.
# Teclas: setas navegar · digitar filtra · Enter abre · Ctrl+F favorita · Esc sai
# Se o filtro for um caminho existente, Enter abre esse caminho.

$ErrorActionPreference = 'Stop'
# Console do Windows costuma estar em codepage 850/437: ★ … ↑↓ viram "?".
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$projectsDir = Join-Path $HOME '.claude\projects'
$stateDir    = Join-Path $HOME '.claudio'
$favFile     = Join-Path $stateDir 'favorites.json'
$e = [char]27

$cardMinWidth = 34
$cardHeight   = 5

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
    if ($d.TotalMinutes -lt 60) { return 'há {0}min' -f [int]$d.TotalMinutes }
    if ($d.TotalHours -lt 24)   { return 'há {0}h' -f [int]$d.TotalHours }
    return 'há {0}d' -f [int]$d.TotalDays
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

function Fit([string]$text, [int]$n, [switch]$KeepEnd) {
    if ($text.Length -le $n) { return $text.PadRight($n) }
    if ($KeepEnd) { return '…' + $text.Substring($text.Length - $n + 1) }
    return $text.Substring(0, $n - 1) + '…'
}

# Devolve as $cardHeight linhas de um card com largura visível $w.
function Render-Card($it, [int]$w, [bool]$selected) {
    $iw = $w - 4
    $leaf = Split-Path $it.Path -Leaf
    if (-not $leaf) { $leaf = $it.Path }
    $parent = Split-Path $it.Path -Parent
    if (-not $parent) { $parent = $it.Path }
    $meta = if ($it.Count) { '{0} · {1} {2}' -f (Format-Ago $it.Last), $it.Count, $(if ($it.Count -eq 1) { 'sessão' } else { 'sessões' }) } else { 'sem sessões' }
    if (-not $it.Exists) { $meta = 'diretório não existe' }

    $b = if ($selected) { "$e[1;95m" } else { "$e[90m" }
    $prefix = if ($it.Fav) { '★ ' } else { '' }
    $nameStyle = if (-not $it.Exists) { "$e[9;2m" } elseif ($selected) { "$e[1;95m" } else { "$e[1m" }
    $name = Fit ($prefix + $leaf) $iw
    if ($it.Fav) { $name = "$e[33m★$e[0m$nameStyle" + $name.Substring(1) }

    @(
        "$b╭$('─' * ($w - 2))╮$e[0m"
        "$b│$e[0m $nameStyle$name$e[0m $b│$e[0m"
        "$b│$e[0m $e[2m$(Fit $parent $iw -KeepEnd)$e[0m $b│$e[0m"
        "$b│$e[0m $e[2m$(Fit $meta $iw)$e[0m $b│$e[0m"
        "$b╰$('─' * ($w - 2))╯$e[0m"
    )
}

$all = Build-Items
$filter = ''
$sel = 0
$top = 0
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

        $width  = [Console]::WindowWidth - 1
        $height = [Console]::WindowHeight
        $cols   = [int][Math]::Max(1, [Math]::Floor(($width + 1) / ($cardMinWidth + 1)))
        $cardW  = [int][Math]::Floor(($width + 1) / $cols) - 1

        # Layout: bloco de favoritos em cima, recentes embaixo; cada bloco é uma grade de cards.
        $body = [System.Collections.Generic.List[string]]::new()
        $rows = [System.Collections.Generic.List[object]]::new()   # @{ Start; Items; First }
        $rowOf = @{}; $colOf = @{}
        $favIdx  = @(for ($i = 0; $i -lt $view.Count; $i++) { if ($view[$i].Fav) { $i } })
        $restIdx = @(for ($i = 0; $i -lt $view.Count; $i++) { if (-not $view[$i].Fav) { $i } })
        foreach ($section in @(@{ Title = '★ Favoritos'; Idx = $favIdx }, @{ Title = 'Recentes'; Idx = $restIdx })) {
            if (-not $section.Idx.Count) { continue }
            if ($body.Count) { $body.Add('') }
            $body.Add(" $e[1;33m$($section.Title)$e[0m $e[2m($($section.Idx.Count))$e[0m")
            for ($r = 0; $r -lt $section.Idx.Count; $r += $cols) {
                $chunk = @($section.Idx[$r..([Math]::Min($r + $cols, $section.Idx.Count) - 1)])
                foreach ($c in 0..($chunk.Count - 1)) { $rowOf[$chunk[$c]] = $rows.Count; $colOf[$chunk[$c]] = $c }
                $rows.Add(@{ Start = $body.Count; Items = $chunk; First = ($r -eq 0) })
                $cards = @(foreach ($i in $chunk) { , (Render-Card $view[$i] $cardW ($i -eq $sel)) })
                for ($l = 0; $l -lt $cardHeight; $l++) { $body.Add((@($cards | ForEach-Object { $_[$l] }) -join ' ')) }
            }
        }

        $viewH = [Math]::Max($cardHeight + 1, $height - 3)
        if ($view.Count) {
            $row = $rows[$rowOf[$sel]]
            $start = if ($row.First) { $row.Start - 1 } else { $row.Start }
            if ($start -lt $top) { $top = $start }
            if ($row.Start + $cardHeight -gt $top + $viewH) { $top = $row.Start + $cardHeight - $viewH }
        }
        $top = [Math]::Max(0, [Math]::Min($top, $body.Count - $viewH))

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("$e[H")
        [void]$sb.Append("$e[1;35m claudio$e[0m  $e[2msetas navegar · digitar filtra · Enter abre · Ctrl+F favorito · Esc sai$e[0m$e[K`n")
        [void]$sb.Append(" $e[36m>$e[0m $filter$e[7m $e[0m$e[K`n$e[K`n")
        if (-not $view.Count) {
            $hint = if ($filter -and (Test-Path -LiteralPath $filter -PathType Container)) { 'Enter abre esse caminho' } else { 'nada encontrado' }
            [void]$sb.Append("   $e[2m$hint$e[0m$e[K`n")
        }
        for ($l = $top; $l -lt [Math]::Min($body.Count, $top + $viewH); $l++) { [void]$sb.Append("$($body[$l])$e[K`n") }
        [void]$sb.Append("$e[J")
        [Console]::Write($sb.ToString())

        $k = [Console]::ReadKey($true)
        $ctrl = $k.Modifiers -band [ConsoleModifiers]::Control
        $cur = if ($view.Count) { $rowOf[$sel] } else { 0 }
        switch ($k.Key) {
            'Escape'     { if ($filter) { $filter = ''; $sel = 0 } else { return } ; continue }
            'LeftArrow'  { if ($sel -gt 0) { $sel-- }; continue }
            'RightArrow' { if ($sel -lt $view.Count - 1) { $sel++ }; continue }
            'UpArrow'    { if ($cur -gt 0) { $it = $rows[$cur - 1].Items; $sel = $it[[Math]::Min($colOf[$sel], $it.Count - 1)] }; continue }
            'DownArrow'  { if ($cur -lt $rows.Count - 1) { $it = $rows[$cur + 1].Items; $sel = $it[[Math]::Min($colOf[$sel], $it.Count - 1)] }; continue }
            'PageUp'     { if ($view.Count) { $it = $rows[[Math]::Max(0, $cur - [Math]::Floor($viewH / $cardHeight))].Items; $sel = $it[[Math]::Min($colOf[$sel], $it.Count - 1)] }; continue }
            'PageDown'   { if ($view.Count) { $it = $rows[[Math]::Min($rows.Count - 1, $cur + [Math]::Floor($viewH / $cardHeight))].Items; $sel = $it[[Math]::Min($colOf[$sel], $it.Count - 1)] }; continue }
            'Home'       { $sel = 0; continue }
            'End'        { $sel = [Math]::Max(0, $view.Count - 1); continue }
            'Backspace'  { if ($filter) { $filter = $filter.Substring(0, $filter.Length - 1); $sel = 0 }; continue }
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
