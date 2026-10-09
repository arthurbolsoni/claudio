# claudio

TUI para Windows que lista os diretórios onde você usou o [Claude Code](https://claude.com/claude-code) recentemente e abre uma sessão nova no escolhido, na conta escolhida:

```
cd <dir> && claude --dangerously-skip-permissions
```

Os diretórios vêm do campo `cwd` das sessões em `~/.claude/projects`. A tela tem dois cards: Favoritos em cima e Recentes embaixo, cada um com sua lista ordenada por último uso e rolagem própria.

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
| Enter | escolher o diretório e ir para a tela de contas (com uma conta só, abre direto) |
| Ctrl+F | marcar/desmarcar favorito |
| Esc | limpar filtro / sair |

Se o filtro for um caminho existente e nada da lista bater, Enter abre esse caminho.
Argumentos extras são repassados ao `claude`: `claudio --continue`.

Favoritos ficam em `~/.claudio/favorites.json`. Diretórios que não existem mais aparecem riscados.

## Contas

Cada pasta de configuração do Claude Code com login é uma conta: `~/.claude` é a conta 1 e cada `~/.claude-*` com `.credentials.json` vem em seguida, em ordem alfabética. As contas além da 1 abrem com `CLAUDE_CONFIG_DIR` apontando para a pasta delas.

O topo da lista mostra o uso da sessão (5h) e da semana de cada conta. Na tela de contas cada uma tem um card com todos os limites, a barra de uso e o horário de reset.

| Tecla | Ação |
|---|---|
| ↑ ↓ Tab | escolher conta |
| 1–9 | abrir direto na conta N |
| Enter | abrir |
| Esc | voltar para a lista |

A última conta usada vem pré-selecionada (`~/.claudio/state.json`).

Origem do uso, por tipo de token:

- token de `/login` (escopo `user:profile`): `GET /api/oauth/usage`, o mesmo dado do `/usage`;
- token de `claude setup-token` (só `user:inference`), ou quando o endpoint acima responde erro (ex.: 429): uma chamada de 1 token ao Haiku, lendo os headers `anthropic-ratelimit-unified-5h-*` e `-7d-*`;
- token expirado ou sem rede: o último uso que o Claude Code gravou no `.claude.json` da conta, marcado como cache.
