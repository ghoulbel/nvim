# Neovim configuration

Portable Neovim configuration built on `vim.pack`, the plugin manager built into
Neovim 0.12+. Works unchanged on NixOS, Ubuntu and macOS.

## Requirements

- Neovim >= 0.12 (for `vim.pack`)
- `git`
- A Nerd Font in your terminal (for file-tree and LSP icons)
- `tree-sitter` CLI and a C compiler (only needed to install parsers)

On NixOS these come from `programs.neovim.extraPackages` in nixos-config. On
Ubuntu/Debian:

```sh
sudo apt install neovim git ripgrep fd-find wl-clipboard
sudo apt install build-essential   # C compiler for tree-sitter parsers
# tree-sitter CLI >= 0.26.1, e.g. via cargo or your distribution's package
```

## Install

```sh
git clone git@github.com:ghoulbel/nvim.git ~/.config/nvim
nvim
```

The first launch installs the plugins and prints which parsers still need to be
built. In a fresh checkout the parsers are not present, so run:

```vim
:TSInstall nix python yaml bash json
```

Parsers install asynchronously and appear on the next restart. After that,
`:TSUpdate` keeps them in step with the plugin.

## Language servers

Servers are enabled only when their binary is on `PATH`; anything missing is
reported once at startup instead of failing per-buffer. Install the ones you
use:

| Server  | Provides                          |
| ------- | --------------------------------- |
| `pyright` | Python                          |
| `yamlls`  | YAML                             |
| `bashls` | Shell                            |
| `jdtls`   | Java (NixOS) / `jdt-language-server` elsewhere |
| `ballerina` | Ballerina                      |

## Keymaps

`<leader>` is space.

| Mapping             | Action                    |
| ------------------- | ------------------------- |
| `<leader>e`, `<C-n>` | Toggle file tree         |
| `gd` / `gD`         | Go to definition / declaration |
| `K`                 | Hover documentation      |
| `gr`, `<leader>vr`  | List references          |
| `<leader>rn`        | Rename symbol            |
| `<leader>ca`        | Code action              |
| `<leader>f`         | Format buffer            |
| `[d` / `]d`         | Previous / next diagnostic |
| `<leader>ld`        | Show line diagnostics    |
| `gcc` / `gbc`       | Toggle line / block comment |
| `<leader>w` / `<leader>q` | Write / quit         |

## Design notes

- `init.lua` is loaded directly. When managed by home-manager,
  `programs.neovim.sideloadInitLua = true` prevents a generated `init.lua`
  stub from shadowing this file.
- Treesitter highlighting is started explicitly via a `FileType` autocmd.
  The `main` branch of nvim-treesitter does not enable it on its own.
- Parsers are declared in `ts_languages` near the top of `init.lua`; missing
  ones are installed automatically on `VimEnter`.
- The system clipboard is only claimed when `wl-copy` or `xclip` exists, so
  yanks do not fail on headless or SSH sessions.
