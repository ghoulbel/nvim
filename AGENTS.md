# AGENTS.md — guidance for LLM agents (and humans) working on this config

Shared Neovim config used on two devices. Read this before changing anything.

## Architecture: dual provisioning, selected by `/etc/NIXOS`

- **NixOS device**: plugins and tree-sitter parsers are pinned by nix (see the
  header comment in `init.vim`). `init.vim` is the only file that matters here.
- **Other devices (Ubuntu etc.)**: `init.vim` bootstraps lazy.nvim on first
  start (guarded by `if not vim.uv.fs_stat('/etc/NIXOS')`) and installs:
  nvim-web-devicons, nvim-tree.lua, Comment.nvim, neoscroll.nvim,
  ellisonleao/gruvbox.nvim, and nvim-treesitter. `:TSInstall` provides parsers.
- The lockfile lives in `stdpath('data')/lazy-lock.json` (NOT in this repo —
  nix pins versions on NixOS).

## Per-device files (NOT in this repo — do not try to find them here)

- `~/.bashrc`: aliases `vim`/`vi` to `nvim` (the config only loads in nvim).
- `~/.local/share/nvim/site/syntax/ballerina.vim`: Ballerina regex syntax.
- pyright installed via `pipx install pyright`; tree-sitter CLI 0.27 in
  `~/.local/bin` (nvim-treesitter's main branch compiles parsers with it).
- Tree-sitter parsers under `~/.local/share/nvim/site/parser/` via `:TSInstall`.

## Ballerina: do NOT add a tree-sitter parser

- nvim-treesitter has never had a ballerina parser (checked registry + full git
  history), nixpkgs has none, and the ONLY community grammar
  (heshanpadmasiri/tree-sitter-ballerina, "nballerina subset 14") MIS-PARSES
  modern ballerina: a realistic service file (annotations, service decl,
  `{| |}` records, `check`, query expressions) yields ROOT=ERROR with 62
  ERROR nodes. Its output made highlighting look broken.
- Ballerina highlighting is therefore: device-local regex syntax file (above)
  + the Ballerina LSP's semantic tokens layered on top in projects — the same
  model as the VS Code Ballerina extension. The LSP advertises
  `semanticTokensProvider`, but its legend has NO string/keyword/comment types.

## Ballerina LSP launch (non-obvious)

- `bal start-language-server` and `bal start --stdio` DO NOT EXIST (verified).
- The distribution's bundled `language-server-launcher.sh` is not executable
  and its legacy "JDK 1.8" check rejects the bundled JDK 21 — unusable.
- `init.vim` therefore builds the java classpath invocation directly:
  `java -Dballerina.home=<distro> -cp "<distro>/bre/lib/*:<distro>/lib/tools/lang-server/lib/*"
   org.ballerinalang.langserver.launchers.stdio.Main`
  with `<distro>` resolved from `/usr/lib/ballerina/distributions/ballerina-version`.

## Coding conventions in init.vim

- All LSP servers follow the `have(cmd)` auto-detect pattern
  (`vim.lsp.config` + `vim.lsp.enable`); absent binaries stay inert — no
  warnings, no errors. Keep it that way.
- Neovim compatibility target: 0.11.x AND 0.12 (NixOS is on 0.12).

## Verification

- `scripts/verify-nvim-config.sh` — 35 behavioral checks (headless load, LSP
  clients attach with real handshakes, rendered highlighting via synID at real
  positions, NvimTree, colorscheme, aliases). For non-NixOS devices; needs
  `bal`, `java`, and `git`. Takes ~1-2 min.
- Run it after ANY change to `init.vim` or the device-local files.

## Testing gotchas (learned the hard way)

- NvimTree hijacks the current buffer/window on VimEnter: tests must resolve
  file buffers by name and switch to their window before measuring.
- `synID` only sees `:syntax`-based highlighting (not extmark/semantic), and it
  measures the CURRENT window's buffer.
- `vim.lsp.config['name']` is always truthy on 0.11 — probe LSP state with
  `vim.lsp.get_clients({ name = ... })` instead.
- In vim syntax files, same-position ties are won by the LATER-defined item:
  define generic operator matches BEFORE comment matches, or `//` comments
  render partially uncolored.
