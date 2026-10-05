# Cria o shim `claudio` em ~/.local/bin (precisa estar no PATH).
$bin = Join-Path $HOME '.local\bin'
New-Item -ItemType Directory -Force $bin | Out-Null
Set-Content (Join-Path $bin 'claudio.cmd') "@pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\claudio.ps1`" %*" -Encoding ascii
Write-Host "claudio instalado em $bin"
