-- Neovim configuration
--
-- Portable: requires only Neovim >= 0.12 and git. Plugins are managed by the
-- built-in `vim.pack`, so this works unchanged on NixOS, Ubuntu or macOS.
-- Language servers are picked up from PATH when present and skipped when not,
-- so a missing server never breaks startup.

vim.g.mapleader = ' '
vim.g.maplocalleader = ','

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
local opt = vim.opt

opt.number = true
opt.relativenumber = true
opt.cursorline = true
opt.signcolumn = 'yes'
opt.termguicolors = true
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.wrap = true

opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.shiftround = true
opt.autoindent = true
opt.smartindent = true -- kept for non-treesitter filetypes; treesitter overrides indent

opt.ignorecase = true
opt.smartcase = true
opt.incsearch = true
opt.hlsearch = true
opt.showmatch = true
opt.inccommand = 'nosplit'

opt.splitbelow = true
opt.splitright = true
opt.splitkeep = 'screen'
opt.winborder = 'rounded'
opt.laststatus = 3
opt.showmode = false
opt.confirm = true
opt.hidden = true
opt.undofile = true
opt.updatetime = 250
opt.completeopt = { 'menu', 'menuone', 'noselect' }
opt.mouse = 'a'
opt.list = true

-- Folding driven by treesitter, so folds follow real syntax structure.
opt.foldmethod = 'expr'
opt.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
opt.foldlevel = 99
opt.foldlevelstart = 99

-- Only claim the system clipboard when a provider is actually available;
-- otherwise unnamedplus makes every yank fail on headless/SSH sessions.
if vim.fn.executable('wl-copy') == 1 or vim.fn.executable('xclip') == 1 then
  opt.clipboard = 'unnamedplus'
end

-- ---------------------------------------------------------------------------
-- Treesitter
-- ---------------------------------------------------------------------------
-- Languages to keep parsers for. `nix` is included because this machine is
-- NixOS-based; add more here and they are installed on demand.
local ts_languages = {
  'bash',
  'dockerfile',
  'hcl',
  'helm',
  'java',
  'json',
  'nix',
  'python',
  'terraform',
  'xml',
  'yaml',
}

-- nvim-treesitter's `main` branch ships no `configs` module and, unlike the old
-- `master` branch, does not turn highlighting on by itself: nothing calls
-- `vim.treesitter.start()` unless we do. That is why highlighting has to be
-- started explicitly here rather than left to a setup() call.
local function ts_start(buf)
  local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
    or vim.bo[buf].filetype
  if not lang or lang == '' then
    return
  end
  if vim.treesitter.language.add(lang) then
    vim.treesitter.start(buf, lang)
  end
end

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('UserTreesitter', { clear = true }),
  callback = function(ev)
    ts_start(ev.buf)
  end,
})

-- Install any missing parsers without blocking startup. Requires the
-- tree-sitter CLI and a C compiler; see README.md.
vim.api.nvim_create_autocmd('VimEnter', {
  group = vim.api.nvim_create_augroup('UserTreesitterParsers', { clear = true }),
  callback = function()
    local ok, ts = pcall(require, 'nvim-treesitter')
    if not ok then
      return
    end
    local installed = ts.get_installed()
    local missing = vim.tbl_filter(function(lang)
      return not installed[lang]
    end, ts_languages)
    if #missing > 0 then
      vim.schedule(function()
        pcall(function()
          ts.install(missing)
        end)
      end)
    end
  end,
})

-- ---------------------------------------------------------------------------
-- Plugins (vim.pack, built into Neovim 0.12+)
-- ---------------------------------------------------------------------------
-- nvim-treesitter parsers are version-coupled to the plugin, so parsers must be
-- rebuilt whenever the plugin itself is installed or updated. vim.pack has no
-- per-plugin `build` hook, so the documented PackChanged event is used instead.
-- This autocmd must exist before vim.pack.add() runs.
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    if ev.data.spec.name ~= 'nvim-treesitter' then
      return
    end
    if ev.data.kind ~= 'install' and ev.data.kind ~= 'update' then
      return
    end
    if not ev.data.active then
      pcall(vim.cmd.packadd, 'nvim-treesitter')
    end
    local ok, ts = pcall(require, 'nvim-treesitter')
    if ok then
      pcall(function()
        ts.update():wait(600000)
      end)
    end
  end,
})

-- nvim-web-devicons supplies the file/folder glyphs used by nvim-tree and the
-- LSP symbols on the statusline. Requires a Nerd Font in the terminal.
vim.pack.add({
  'https://github.com/morhetz/gruvbox',
  'https://github.com/nvim-treesitter/nvim-treesitter',
  'https://github.com/nvim-tree/nvim-tree.lua',
  'https://github.com/nvim-tree/nvim-web-devicons',
  'https://github.com/numToStr/Comment.nvim',
  'https://github.com/karb94/neoscroll.nvim',
  'https://github.com/neovim/nvim-lspconfig',
  'https://github.com/towolf/vim-helm',
})

vim.g.skip_redraw_setup = true

pcall(vim.cmd.colorscheme, 'gruvbox')

-- ---------------------------------------------------------------------------
-- Plugin configuration
-- ---------------------------------------------------------------------------
local ok, nvim_tree = pcall(require, 'nvim-tree')
if ok then
  nvim_tree.setup({
    actions = {
      open_file = {
        quit_on_open = false,
      },
    },
    git = { ignore = true },
    renderer = { indent_markers = { enable = true } },
    view = { width = 30 },
  })

  vim.api.nvim_create_autocmd('VimEnter', {
    group = vim.api.nvim_create_augroup('UserNvimTree', { clear = true }),
    callback = function()
      pcall(function()
        require('nvim-tree.api').tree.open()
      end)
    end,
  })
end

local ok_comment, comment = pcall(require, 'Comment')
if ok_comment then
  comment.setup({
    padding = true,
    sticky = true,
    toggler = { line = 'gcc', block = 'gbc' },
    opleader = { line = 'gc', block = 'gb' },
  })
end

local ok_scroll, neoscroll = pcall(require, 'neoscroll')
if ok_scroll then
  neoscroll.setup({
    easing_function = 'quadratic',
    hide_cursor = true,
    stop_eof = true,
  })
end

-- ---------------------------------------------------------------------------
-- LSP
-- ---------------------------------------------------------------------------
-- Ballerina is not a built-in filetype.
vim.filetype.add({ extension = { bal = 'ballerina' } })

-- Native LSP completion (Neovim 0.11+). This replaces nvim-cmp/blink without
-- pulling in an extra plugin.
pcall(vim.lsp.completion.enable, true)

-- Register a server only if its binary is on PATH. A missing server is
-- reported at startup instead of throwing on every buffer open.
local function have(cmd)
  return vim.fn.executable(cmd) == 1
end

local configured = {}
local unavailable = {}

---@param name string
---@param cmd string[]
---@param opts table
local function add_server(name, cmd, opts)
  if not have(cmd[1]) then
    unavailable[#unavailable + 1] = name
    return
  end
  vim.lsp.config(name, vim.tbl_extend('force', { cmd = cmd }, opts))
  configured[#configured + 1] = name
end

add_server('pyright', { 'pyright-langserver', '--stdio' }, {
  filetypes = { 'python' },
  root_markers = { 'pyproject.toml', 'setup.py', 'requirements.txt', '.git' },
})

add_server('yamlls', { 'yaml-language-server', '--stdio' }, {
  filetypes = { 'yaml' },
  root_markers = { '.git' },
})

add_server('bashls', { 'bash-language-server', 'start' }, {
  filetypes = { 'sh' },
  root_markers = { '.git' },
})

-- NixOS ships the Eclipse JDT language server as `jdtls`; other distributions
-- call it `jdt-language-server`. Accept either so the check matches reality.
add_server('jdtls', { have('jdtls') and 'jdtls' or 'jdt-language-server' }, {
  filetypes = { 'java' },
  root_markers = { 'pom.xml', 'build.gradle' },
})

-- Only registered here; the FileType autocmd below is deliberately omitted so
-- the server is not started twice under two different client names.
add_server('ballerina', { 'bal', 'start-language-server' }, {
  filetypes = { 'ballerina' },
  root_markers = { 'Ballerina.toml', '.bal' },
})

if #configured > 0 then
  vim.lsp.enable(configured)
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------
local map = vim.keymap.set

-- Files and windows
map('n', '<leader>e', '<cmd>NvimTreeToggle<CR>', { desc = 'Toggle file tree' })
map('n', '<leader>w', '<cmd>write<CR>', { desc = 'Write file' })
map('n', '<leader>q', '<cmd>quit<CR>', { desc = 'Quit window' })
map('n', '<leader>h', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight' })

-- LSP
map('n', 'gd', vim.lsp.buf.definition, { desc = 'Go to definition' })
map('n', 'gD', vim.lsp.buf.declaration, { desc = 'Go to declaration' })
map('n', 'K', vim.lsp.buf.hover, { desc = 'Hover documentation' })
map('n', '<leader>rn', vim.lsp.buf.rename, { desc = 'Rename symbol' })
map('n', '<leader>ca', vim.lsp.buf.code_action, { desc = 'Code action' })

map({ 'n', 'v' }, 'gr', vim.lsp.buf.references, { desc = 'List references' })
map({ 'n', 'v' }, '<leader>vr', vim.lsp.buf.references, { desc = 'List references' })

map('n', '<leader>f', function()
  if vim.lsp.buf.format then
    vim.lsp.buf.format({ async = true })
  end
end, { desc = 'Format buffer' })

-- Diagnostics
map('n', '[d', vim.diagnostic.goto_prev, { desc = 'Previous diagnostic' })
map('n', ']d', vim.diagnostic.goto_next, { desc = 'Next diagnostic' })
map('n', '<leader>ld', vim.diagnostic.open_float, { desc = 'Line diagnostics' })
map('n', '<leader>lD', vim.diagnostic.setloclist, { desc = 'Diagnostics to loclist' })
map({ 'n', 'v' }, '<leader>ld', vim.diagnostic.open_float, { desc = 'Line diagnostics' })

if vim.fn.executable('Trouble') == 0 then
  map('n', '<leader>xx', '<cmd>qa<CR>', { desc = 'Quit all windows' })
end

map('n', '<C-n>', '<cmd>NvimTreeToggle<CR>', { desc = 'Toggle file tree' })

-- ---------------------------------------------------------------------------
-- Startup notice
-- ---------------------------------------------------------------------------
-- Surface missing language servers once per session instead of letting them
-- fail silently. On NixOS they come from programs.neovim.extraPackages; on
-- other distributions install them with your package manager.
vim.api.nvim_create_autocmd('VimEnter', {
  group = vim.api.nvim_create_augroup('UserStartupNotice', { clear = true }),
  callback = function()
    if #unavailable > 0 then
      vim.schedule(function()
        vim.notify(
          'nvim: language servers not found on PATH: ' .. table.concat(unavailable, ', '),
          vim.log.levels.WARN
        )
      end)
    end
  end,
})
