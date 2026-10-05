# claudio

TUI para Windows que lista os diretórios onde você usou o [Claude Code](https://claude.com/claude-code) recentemente e abre uma sessão nova no escolhido:

```
cd <dir> && claude --dangerously-skip-permissions
```

Os diretórios vêm do campo `cwd` das sessões em `~/.claude/projects`. A lista é ordenada por último uso, com os favoritos no topo.

## Instalação

Requer PowerShell 7 (`pwsh`) e o `claude` no PATH.

```powershell
git clone https://github.com/arthurbolsoni/claudio $HOME\claudio
& $HOME\claudio\install.ps1
```

O `install.ps1` cria `~/.local/bin/claudio.cmd`, então `~/.local/bin` precisa estar no PATH.

## Uso

| Tecla | Ação |
|---|---|
| ↑ ↓ PgUp PgDn Home End | navegar |
| digitar | filtrar (vários termos separados por espaço) |
| Enter | abrir sessão no diretório |
| Ctrl+F | marcar/desmarcar favorito |
| Esc | limpar filtro / sair |

Se o filtro for um caminho existente e nada da lista bater, Enter abre esse caminho.
Argumentos extras são repassados ao `claude`: `claudio --continue`.

Favoritos ficam em `~/.claudio/favorites.json`. Diretórios que não existem mais aparecem riscados.
