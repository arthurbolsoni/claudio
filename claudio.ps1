# claudio — escolhe um diretório usado recentemente com o Claude e a conta, e abre uma sessão nova nele.
# Teclas: ↑/↓ navegar · digitar filtra · Enter abre · Ctrl+F favorita · Esc sai
# Se o filtro for um caminho existente, Enter abre esse caminho.
# Contas: ~/.claude e cada ~/.claude-* com .credentials.json (abertas com CLAUDE_CONFIG_DIR).

$ErrorActionPreference = 'Stop'
# Console do Windows costuma estar em codepage 850/437: ★ … ↑↓ viram "?".
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$scriptArgs  = $args
$projectsDir = Join-Path $HOME '.claude\projects'
$stateDir    = Join-Path $HOME '.claudio'
$favFile     = Join-Path $stateDir 'favorites.json'
$stateFile   = Join-Path $stateDir 'state.json'
$cwdCacheFile = Join-Path $stateDir 'cwd-cache.json'
$e = [char]27

function Load-Favorites {
    if (Test-Path $favFile) { @(Get-Content $favFile -Raw | ConvertFrom-Json) } else { @() }
}

function Save-Favorites($list) {
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory $stateDir | Out-Null }
    ConvertTo-Json -InputObject @($list) | Set-Content $favFile -Encoding utf8
}

function Read-Json([string]$path) {
    if (Test-Path -LiteralPath $path) { try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null } }
}

function Save-State([string]$account) {
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory $stateDir | Out-Null }
    ConvertTo-Json -InputObject @{ account = $account } | Set-Content $stateFile -Encoding utf8
}

function Get-Key([string]$path) { $path.ToLower().TrimEnd('\') }

# Primeiro "cwd" nos 512 KB iniciais da sessão. Ler por linha é lento: a 1ª linha pode ter vários MB.
function Find-Cwd([string]$file) {
    try {
        $fs = [IO.FileStream]::new($file, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            $buf = [byte[]]::new(512KB)
            $n = $fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
        if ([Text.Encoding]::UTF8.GetString($buf, 0, $n) -match '"cwd":"((?:[^"\\]|\\.)*)"') { return $Matches[1] -replace '\\\\', '\' }
    } catch { }
}

# Lê o "cwd" real das sessões (o nome da pasta em ~/.claude/projects é lossy).
# O cwd de cada pasta de projeto fica em ~/.claudio/cwd-cache.json; só pasta nova abre arquivo.
function Get-RecentDirs {
    $cache = @{}
    $saved = Read-Json $cwdCacheFile
    if ($saved) { foreach ($p in $saved.PSObject.Properties) { $cache[$p.Name] = $p.Value } }
    $dirty = $false
    $byPath = @{}
    if (-not [IO.Directory]::Exists($projectsDir)) { return }
    foreach ($proj in [IO.DirectoryInfo]::new($projectsDir).GetDirectories()) {
        $sessions = $proj.GetFiles('*.jsonl')
        if (-not $sessions.Count) { continue }
        $last = $sessions[0].LastWriteTime
        foreach ($s in $sessions) { if ($s.LastWriteTime -gt $last) { $last = $s.LastWriteTime } }
        $cwd = $cache[$proj.Name]
        if (-not $cwd) {
            foreach ($s in $sessions | Sort-Object LastWriteTime -Descending | Select-Object -First 3) {
                $cwd = Find-Cwd $s.FullName
                if ($cwd) { $cache[$proj.Name] = $cwd; $dirty = $true; break }
            }
        }
        if (-not $cwd) { continue }
        $key = Get-Key $cwd
        if ($byPath.ContainsKey($key)) {
            $byPath[$key].Count += $sessions.Count
            if ($last -gt $byPath[$key].Last) { $byPath[$key].Last = $last }
        } else {
            $byPath[$key] = [pscustomobject]@{ Path = $cwd; Last = $last; Count = $sessions.Count }
        }
    }
    if ($dirty) {
        try {
            if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory $stateDir | Out-Null }
            ConvertTo-Json -InputObject $cache | Set-Content $cwdCacheFile -Encoding utf8
        } catch { }
    }
    $byPath.Values
}

function Format-Ago([datetime]$t) {
    $d = (Get-Date) - $t
    if ($d.TotalMinutes -lt 60) { return '{0}min' -f [int]$d.TotalMinutes }
    if ($d.TotalHours -lt 24)   { return '{0}h' -f [int]$d.TotalHours }
    return '{0}d' -f [int]$d.TotalDays
}

function Format-Until($t) {
    if (-not $t) { return '' }
    $t = $t.AddSeconds(30)  # a API manda 19:59:59.9 para 20:00
    $d = $t - (Get-Date)
    if ($d.TotalMinutes -lt 1) { return 'reseta agora' }
    if ($d.TotalHours -lt 1)   { return 'reseta em {0}min' -f [int][Math]::Ceiling($d.TotalMinutes) }
    if ($d.TotalHours -lt 24)  { return 'reseta em {0}h{1:00}' -f [int][Math]::Floor($d.TotalHours), $d.Minutes }
    'reseta ' + $t.ToString('ddd HH:mm', [cultureinfo]::GetCultureInfo('pt-BR')).Replace('.', '')
}

# --- Contas e uso ---

# Datas chegam como [datetime] (ConvertFrom-Json converte ISO 8601) ou como string.
function To-Local($v) {
    if ($null -eq $v -or $v -eq '') { return $null }
    if ($v -is [datetime]) { return $(if ($v.Kind -eq 'Utc') { $v.ToLocalTime() } else { $v }) }
    [datetimeoffset]::Parse([string]$v).LocalDateTime
}

# O .claude.json passa de 100 KB e ConvertFrom-Json nele custa ~50 ms: tira só os dois campos usados.
function Read-AccountConfig([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $doc = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($path))
        try {
            $cfg = @{}
            foreach ($name in 'oauthAccount', 'cachedUsageUtilization') {
                $v = [Text.Json.JsonElement]::new()
                if ($doc.RootElement.TryGetProperty($name, [ref]$v)) { $cfg[$name] = $v.GetRawText() | ConvertFrom-Json }
            }
            [pscustomobject]$cfg
        } finally { $doc.Dispose() }
    } catch { }
}

function Get-Accounts {
    $dirs = @(Join-Path $HOME '.claude') + @(Get-ChildItem $HOME -Directory -Force -Filter '.claude-*' |
        Where-Object { Test-Path (Join-Path $_.FullName '.credentials.json') } | Sort-Object Name | ForEach-Object FullName)
    $n = 0
    foreach ($dir in $dirs) {
        $n++
        $default = $n -eq 1
        # Sem CLAUDE_CONFIG_DIR o .claude.json fica em ~, não dentro de ~/.claude.
        $cfg = Read-AccountConfig $(if ($default) { Join-Path $HOME '.claude.json' } else { Join-Path $dir '.claude.json' })
        $cred = (Read-Json (Join-Path $dir '.credentials.json')).claudeAiOauth
        $plan = ''
        if ($cred.subscriptionType) {
            $plan = (Get-Culture).TextInfo.ToTitleCase($cred.subscriptionType)
            if ($cred.rateLimitTier -match '_(\d+x)$') { $plan += ' ' + $Matches[1] }
        }
        $info = @($cfg.oauthAccount.emailAddress, $plan | Where-Object { $_ }) -join ' · '
        [pscustomobject]@{
            Name = "conta $n"; Dir = $dir; Default = $default
            Info = $(if ($info) { $info } else { $dir.Replace($HOME, '~') })
            Token = $cred.accessToken; ExpiresAt = $cred.expiresAt; Scopes = "$($cred.scopes)" -split ' '
            Cache = $cfg.cachedUsageUtilization
            State = 'carregando'; Note = ''; Limits = @(); Task = $null; Probe = $false
        }
    }
}

function Convert-Usage($u) {
    if ($u.limits) {
        foreach ($l in $u.limits) {
            $label, $short = switch ($l.kind) {
                'session'       { 'Sessão (5h)', 'sessão' }
                'weekly_all'    { 'Semana', 'semana' }
                'weekly_scoped' { ('Semana · ' + $(if ($l.scope.model.display_name) { $l.scope.model.display_name } else { 'outro' })), '' }
                default         { $l.kind, '' }
            }
            [pscustomobject]@{ Label = $label; Short = $short; Percent = [double]$l.percent; Resets = To-Local $l.resets_at }
        }
        return
    }
    if ($u.five_hour) { [pscustomobject]@{ Label = 'Sessão (5h)'; Short = 'sessão'; Percent = [double]$u.five_hour.utilization; Resets = To-Local $u.five_hour.resets_at } }
    if ($u.seven_day) { [pscustomobject]@{ Label = 'Semana'; Short = 'semana'; Percent = [double]$u.seven_day.utilization; Resets = To-Local $u.seven_day.resets_at } }
}

# Último uso que o próprio Claude Code gravou no .claude.json da conta.
function Use-Cache($a, [string]$why) {
    if ($a.Cache.utilization) {
        $a.Limits = @(Convert-Usage $a.Cache.utilization)
        $a.State = 'cache'
        $a.Note = '{0} · cache de {1} atrás' -f $why, (Format-Ago ([DateTimeOffset]::FromUnixTimeMilliseconds($a.Cache.fetchedAtMs).LocalDateTime))
    } else { $a.State = 'erro'; $a.Note = $why }
}

$http = [System.Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(10)

# Token de /login (escopo user:profile) lê /api/oauth/usage, o mesmo dado do /usage.
# Token de `claude setup-token` só tem user:inference: uma chamada de 1 token no Haiku
# devolve o uso nos headers anthropic-ratelimit-unified-*.
function Start-Usage($a) {
    if (-not $a.Token) { $a.State = 'erro'; $a.Note = 'sem login'; return }
    if ($a.ExpiresAt -and $a.ExpiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { Use-Cache $a 'token expirado'; return }
    $a.Probe = $a.Scopes -notcontains 'user:profile'
    Send-Usage $a
}

function Send-Usage($a) {
    if ($a.Probe) {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://api.anthropic.com/v1/messages')
        $body = @{ model = 'claude-haiku-5-5'; max_tokens = 1; system = "You are Claude Code, Anthropic's official CLI for Claude."; messages = @(@{ role = 'user'; content = '.' }) } | ConvertTo-Json -Depth 4 -Compress
        $req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
        $req.Headers.Add('anthropic-version', '2023-06-01')
    } else {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, 'https://api.anthropic.com/api/oauth/usage')
    }
    $req.Headers.Add('Authorization', "Bearer $($a.Token)")
    $req.Headers.Add('anthropic-beta', 'oauth-2025-04-20')
    $a.Task = $http.SendAsync($req)
}

function Complete-Usage($a) {
    $t = $a.Task; $a.Task = $null
    if ($t.IsFaulted -or $t.IsCanceled) { Use-Cache $a 'sem conexão'; return }
    $resp = $t.Result
    try {
        if (-not $resp.IsSuccessStatusCode) {
            # /api/oauth/usage tem limite de chamadas próprio (429): tenta a chamada de 1 token.
            if (-not $a.Probe -and $a.Scopes -contains 'user:inference') { $a.Probe = $true; Send-Usage $a; return }
            $msg = try { ($resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).error.message } catch { '' }
            Use-Cache $a ('HTTP {0}{1}' -f [int]$resp.StatusCode, $(if ($msg) { ": $msg" }))
            return
        }
        if ($a.Probe) {
            $h = $resp.Headers
            $get = { param($n) $v = $null; if ($h.TryGetValues("anthropic-ratelimit-unified-$n", [ref]$v)) { @($v)[0] } }
            $a.Limits = @(foreach ($w in @(@('5h', 'Sessão (5h)', 'sessão'), @('7d', 'Semana', 'semana'))) {
                $p = & $get "$($w[0])-utilization"
                if ($null -eq $p) { continue }
                $r = & $get "$($w[0])-reset"
                [pscustomobject]@{ Label = $w[1]; Short = $w[2]; Percent = [double]$p * 100; Resets = $(if ($r) { [DateTimeOffset]::FromUnixTimeSeconds([long]$r).LocalDateTime }) }
            })
        } else {
            $a.Limits = @(Convert-Usage ($resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json))
        }
        if ($a.Limits.Count) { $a.State = 'ok'; $a.Note = '' } else { Use-Cache $a 'uso não informado' }
    } finally { $resp.Dispose() }
}

# $true se alguma consulta terminou desde a última chamada.
function Update-Usage {
    $changed = $false
    foreach ($a in $accounts) {
        if ($a.Task -and $a.Task.IsCompleted) {
            try { Complete-Usage $a } catch { $a.State = 'erro'; $a.Note = "$_" }
            $changed = $true
        }
    }
    $changed
}

# Espera tecla; devolve $null quando a tela precisa ser redesenhada (uso chegou, janela mudou).
function Wait-Key {
    $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
    while (-not [Console]::KeyAvailable) {
        if (Update-Usage) { return $null }
        if ([Console]::WindowWidth -ne $w -or [Console]::WindowHeight -ne $h) { return $null }
        Start-Sleep -Milliseconds 10
    }
    [Console]::ReadKey($true)
}

# Contas e uso carregam depois do primeiro quadro (Load-Accounts no loop principal).
$accounts = $null
function Load-Accounts {
    $script:accounts = @(Get-Accounts)
    foreach ($a in $script:accounts) { try { Start-Usage $a } catch { $a.State = 'erro'; $a.Note = "$_" } }
    $script:lastAccount = (Read-Json $stateFile).account
}

$recent = @(Get-RecentDirs)
$favorites = [System.Collections.Generic.List[string]]::new()
foreach ($f in Load-Favorites) { $favorites.Add($f) }

# Lower e Meta saem prontos daqui: o filtro e o desenho rodam a cada tecla.
function New-Row([string]$path, [datetime]$last, [int]$count, [bool]$fav) {
    $meta = if ($count) { '{0,9} · {1,-11}' -f ('há ' + (Format-Ago $last)), ('{0} {1}' -f $count, $(if ($count -eq 1) { 'sessão' } else { 'sessões' })) } else { '' }
    [pscustomobject]@{ Path = $path; Lower = $path.ToLower(); Last = $last; Count = $count; Fav = $fav; Meta = $meta.PadLeft(24); Exists = [IO.Directory]::Exists($path) }
}

function Build-Items {
    $favSet = @{}; foreach ($f in $favorites) { $favSet[(Get-Key $f)] = $true }
    $known = @{}
    $items = foreach ($r in $recent) {
        $k = Get-Key $r.Path
        $known[$k] = $true
        New-Row $r.Path $r.Last $r.Count $favSet.ContainsKey($k)
    }
    # Favoritos que não aparecem nas sessões continuam na lista.
    $extra = foreach ($f in $favorites) {
        if (-not $known.ContainsKey((Get-Key $f))) { New-Row $f ([datetime]::MinValue) 0 $true }
    }
    @(@($items) + @($extra) | Sort-Object @{ e = { -not $_.Fav } }, @{ e = { $_.Last }; Descending = $true })
}

function Fit([string]$text, [int]$n) {
    if ($text.Length -le $n) { return $text.PadRight($n) }
    '…' + $text.Substring($text.Length - $n + 1)
}

function Cut([string]$text, [int]$n) {
    if ($text.Length -le $n) { return $text }
    $text.Substring(0, [Math]::Max(0, $n - 1)) + '…'
}

function Strip([string]$s) { $s -replace "$e\[[0-9;?]*[A-Za-z]", '' }

function Pct-Color([double]$p) { if ($p -ge 80) { 31 } elseif ($p -ge 50) { 33 } else { 32 } }

function Color-Pct([double]$p, [int]$pad = 0) { "$e[$(Pct-Color $p)m{0,$pad`:0}%$e[0m" -f $p }

function Bar([double]$p, [int]$w) {
    $fill = [int][Math]::Round([Math]::Min(100, [Math]::Max(0, $p)) / 100 * $w)
    "$e[$(Pct-Color $p)m$('█' * $fill)$e[90m$('░' * ($w - $fill))$e[0m"
}

# Linha do topo da lista: uso de sessão e semana de cada conta.
function Format-Summary([int]$w) {
    if ($null -eq $accounts) { return " $e[2mcarregando contas…$e[0m" }
    $parts = foreach ($a in $accounts) {
        $body = switch ($a.State) {
            'carregando' { "$e[2m…$e[0m" }
            'erro'       { "$e[2m—$e[0m" }
            default {
                (@($a.Limits | Where-Object Short) | ForEach-Object { "$e[2m$($_.Short)$e[0m $(Color-Pct $_.Percent)" }) -join '  '
                if ($a.State -eq 'cache') { " $e[2m(cache)$e[0m" }
            }
        }
        "$e[1m$($a.Name)$e[0m  $(-join $body)"
    }
    $s = ' ' + ($parts -join "$e[90m   │   $e[0m")
    if ((Strip $s).Length -gt $w) { $s = Cut (Strip $s) $w }
    $s
}

# Card de uma conta: uma linha por limite (sessão, semana, semana por modelo).
function Render-Account($a, [bool]$selected, [int]$w) {
    $iw = $w - 4
    $b = if ($selected) { "$e[96m" } else { "$e[90m" }
    $name = if ($selected) { "$e[1;33m$($a.Name)$e[0m" } else { "$e[1m$($a.Name)$e[0m" }
    $info = Cut $a.Info ([Math]::Max(0, $w - 9 - $a.Name.Length))
    $headLen = $a.Name.Length + $info.Length + 4
    $out = @("$b╭─$e[0m $name  $e[2m$info$e[0m $b$('─' * [Math]::Max(0, $w - 3 - $headLen))╮$e[0m")
    $rows = switch ($a.State) {
        'carregando' { "$e[2mconsultando uso…$e[0m" }
        'erro'       { "$e[31m$(Cut $a.Note $iw)$e[0m" }
        default {
            $bw = [Math]::Max(5, [Math]::Min(40, $iw - 52))
            foreach ($l in $a.Limits) {
                '{0} {1} {2} usado  {3}' -f (Cut $l.Label 20).PadRight(20), (Bar $l.Percent $bw), (Color-Pct $l.Percent 4), "$e[2m$(Format-Until $l.Resets)$e[0m"
            }
        }
    }
    foreach ($r in $rows) { $out += "$b│$e[0m $r$(' ' * [Math]::Max(0, $iw - (Strip $r).Length)) $b│$e[0m" }
    $foot = if ($a.State -eq 'cache') { " $(Cut $a.Note ($w - 8)) " } else { '' }
    $out += "$b╰$('─' * ($w - 3 - $foot.Length))$e[0m$e[2m$foot$e[0m$b─╯$e[0m"
    $out
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
        $text = (Fit $it.Path ($iw - 24)) + $it.Meta
        $style = if ($i -eq $sel) { "$e[7m" } elseif (-not $it.Exists) { "$e[9;2m" } else { '' }
        $out += "$b│$e[0m $style$text$e[0m $b│$e[0m"
    }
    $foot = if ($idx.Count -gt $rowsH) { " $([Math]::Min($idx.Count, $top + $rowsH))/$($idx.Count) " } else { '' }
    $out += "$b╰$('─' * ($w - 3 - $foot.Length))$e[0m$e[2m$foot$e[0m$b─╯$e[0m"
    $out
}

# Tela de escolha da conta. Devolve a conta ou $null (Esc volta para a lista).
function Select-Account([string]$target) {
    $sel = 0
    for ($i = 0; $i -lt $accounts.Count; $i++) { if ($accounts[$i].Dir -eq $lastAccount) { $sel = $i } }
    while ($true) {
        $width = [Console]::WindowWidth - 1
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("$e[H")
        [void]$sb.Append("$e[1;35m claudio$e[0m  $e[2m↑↓ escolher conta · Enter abre · 1-$($accounts.Count) abre direto · Esc volta$e[0m$e[K`n")
        [void]$sb.Append(" $e[36m>$e[0m $target$e[K`n$e[K`n")
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            foreach ($l in Render-Account $accounts[$i] ($i -eq $sel) $width) { [void]$sb.Append("$l$e[K`n") }
        }
        [void]$sb.Append("$e[J")
        [Console]::Write($sb.ToString())

        $k = Wait-Key
        if (-not $k) { continue }
        switch ($k.Key) {
            'Escape'    { return $null }
            'UpArrow'   { if ($sel -gt 0) { $sel-- } }
            'DownArrow' { if ($sel -lt $accounts.Count - 1) { $sel++ } }
            'Tab'       { $sel = ($sel + 1) % $accounts.Count }
            'Enter'     { return $accounts[$sel] }
        }
        if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C') { exit 0 }
        $d = [int]$k.KeyChar - [int][char]'1'
        if ($d -ge 0 -and $d -lt $accounts.Count) { return $accounts[$d] }
    }
}

function Start-Claude([string]$target, $acc) {
    [Console]::Write("$e[?25h$e[?1049l")
    [Console]::TreatControlCAsInput = $false
    Save-State $acc.Dir
    Set-Location -LiteralPath $target
    if ($acc.Default) { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_CONFIG_DIR = $acc.Dir }
    Write-Host "cd $target · $($acc.Name)" -ForegroundColor DarkGray
    & claude --dangerously-skip-permissions @scriptArgs
    exit $LASTEXITCODE
}

$all = Build-Items
$filter = ''
$sel = 0
$favTop = 0
$recTop = 0
$focusPath = $null

# Recalcula $view, $favIdx e $recIdx; roda no escopo do loop (dot-source).
$refreshView = {
    $view = @(if ($filter) {
        $terms = $filter.ToLower().Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        foreach ($it in $all) {
            $ok = $true
            foreach ($t in $terms) { if (-not $it.Lower.Contains($t)) { $ok = $false; break } }
            if ($ok) { $it }
        }
    } else { $all })
    if ($focusPath) {
        for ($i = 0; $i -lt $view.Count; $i++) { if ($view[$i].Path -eq $focusPath) { $sel = $i } }
        $focusPath = $null
    }
    if ($sel -ge $view.Count) { $sel = [Math]::Max(0, $view.Count - 1) }
    # $view já vem com favoritos primeiro.
    $favIdx = [int[]]@(for ($i = 0; $i -lt $view.Count; $i++) { if ($view[$i].Fav) { $i } })
    $recIdx = [int[]]@(for ($i = 0; $i -lt $view.Count; $i++) { if (-not $view[$i].Fav) { $i } })
}
. $refreshView

[Console]::TreatControlCAsInput = $true
[Console]::Write("$e[?1049h$e[?25l")
try {
    while ($true) {
        $width = [Console]::WindowWidth - 1
        $avail = [Console]::WindowHeight - 4
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

        # ?2026 = synchronized output: o terminal pinta o quadro inteiro de uma vez, sem piscar.
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("$e[?2026h$e[H")
        [void]$sb.Append("$e[1;35m claudio$e[0m  $e[2m↑↓ navegar · digitar filtra · Enter abre · Ctrl+F favorito · Esc sai$e[0m$e[K`n")
        [void]$sb.Append("$(Format-Summary $width)$e[K`n")
        [void]$sb.Append(" $e[36m>$e[0m $filter$e[7m $e[0m$e[K`n$e[K`n")
        if (-not $view.Count) {
            $hint = if ($filter -and (Test-Path -LiteralPath $filter -PathType Container)) { 'Enter abre esse caminho' } else { 'nada encontrado' }
            [void]$sb.Append("   $e[2m$hint$e[0m$e[K`n")
        }
        if ($favIdx.Count) { foreach ($l in Render-Panel '★ Favoritos' $favIdx $favTop $favRows $width) { [void]$sb.Append("$l$e[K`n") } }
        if ($recIdx.Count) { foreach ($l in Render-Panel 'Recentes' $recIdx $recTop $recRows $width) { [void]$sb.Append("$l$e[K`n") } }
        [void]$sb.Append("$e[J$e[?2026l")
        [Console]::Write($sb.ToString())

        if ($null -eq $accounts) { Load-Accounts; continue }

        # Processa todas as teclas já digitadas antes de redesenhar: segurar ↓ ou digitar rápido não acumula fila.
        $k = Wait-Key
        while ($k) {
            $ctrl = $k.Modifiers -band [ConsoleModifiers]::Control
            $page = [Math]::Max(1, $(if ($sel -lt $favIdx.Count) { $favRows } else { $recRows }))
            $changed = $false
            switch ($k.Key) {
                'Escape'    { if ($filter) { $filter = ''; $sel = 0; $changed = $true } else { return } }
                'UpArrow'   { if ($sel -gt 0) { $sel-- } }
                'DownArrow' { if ($sel -lt $view.Count - 1) { $sel++ } }
                'PageUp'    { $sel = [Math]::Max(0, $sel - $page) }
                'PageDown'  { $sel = [Math]::Max(0, [Math]::Min($view.Count - 1, $sel + $page)) }
                'Home'      { $sel = 0 }
                'End'       { $sel = [Math]::Max(0, $view.Count - 1) }
                'Backspace' { if ($filter) { $filter = $filter.Substring(0, $filter.Length - 1); $sel = 0; $changed = $true } }
                'Enter' {
                    $target = if ($view.Count) { $view[$sel].Path } elseif ($filter -and (Test-Path -LiteralPath $filter -PathType Container)) { (Resolve-Path -LiteralPath $filter).Path }
                    if ($target -and (Test-Path -LiteralPath $target -PathType Container)) {
                        $acc = if ($accounts.Count -gt 1) { Select-Account $target } else { $accounts[0] }
                        if ($acc) { Start-Claude $target $acc }
                    }
                }
                default {
                    if ($ctrl -and $k.Key -eq 'F') {
                        if ($view.Count) {
                            $path = $view[$sel].Path
                            $existing = @($favorites | Where-Object { (Get-Key $_) -eq (Get-Key $path) })
                            if ($existing) { foreach ($x in $existing) { [void]$favorites.Remove($x) } } else { $favorites.Add($path) }
                            Save-Favorites $favorites
                            $all = Build-Items
                            $focusPath = $path
                            $changed = $true
                        }
                    }
                    elseif ($ctrl -and $k.Key -eq 'C') { return }
                    elseif (-not $ctrl -and $k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { $filter += $k.KeyChar; $sel = 0; $changed = $true }
                }
            }
            if ($changed) { . $refreshView }
            $k = if ([Console]::KeyAvailable) { [Console]::ReadKey($true) }
        }
    }
}
finally {
    [Console]::TreatControlCAsInput = $false
    [Console]::Write("$e[?25h$e[?1049l")
}
