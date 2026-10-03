" =============================================================================
" Neovim configuration
"
" Every plugin and every Tree-sitter parser is declared in nixos-config
" (flake input `nvim-config` + programs.neovim.extraPackages), which pins them in
" flake.lock. This file therefore contains no plugin-manager bootstrap and no
" runtime downloads: the same config and the same versions land on every device
" from a single `nixos-rebuild`.
" =============================================================================

" -----------------------------
" General settings
" -----------------------------
set number
set relativenumber
set cursorline
set termguicolors
set background=dark
set scrolloff=8
set sidescrolloff=8
set ttyfast
filetype plugin indent on
syntax on

set tabstop=2
set shiftwidth=2
set expandtab
set autoindent
set smartindent
set showmatch
set mouse=a
set splitbelow
set splitright
set confirm
set hidden
set undofile

" Folds follow the Tree-sitter structure rather than `syntax` lines, so they
" match how the code is actually nested.
set foldmethod=expr
set foldexpr=v:lua.vim.treesitter.foldexpr()
set foldlevel=99
set foldlevelstart=99

" Claiming the clipboard needs a running Wayland/X11 helper. Without one,
" unnamedplus silently turns every yank into a no-op, so only enable it when a
" provider is actually present.
if executable('wl-copy') || executable('xclip')
  set clipboard=unnamedplus
endif

" -----------------------------
" Ensure .bal files are recognized as Ballerina
" -----------------------------
augroup ballerina_filetype
  autocmd!
  autocmd BufRead,BufNewFile *.bal set filetype=ballerina
augroup END

" -----------------------------
" Tree-sitter highlighting
" -----------------------------
" Parsers and queries come from nixpkgs via
" lib/nvim-treesitter-grammars.nix, which lays them out as
" parser/<lang>.so and queries/<lang>/*.scm on the runtimepath.
"
" Neovim 0.12 core does all the work, so nvim-treesitter is not needed here.
" Its `nvim-treesitter.configs` module no longer exists on the `main` branch,
" which is why highlighting has to be started explicitly rather than through a
" setup() call.
lua << EOF
local group = vim.api.nvim_create_augroup('UserTreesitter', { clear = true })

vim.api.nvim_create_autocmd('FileType', {
  group = group,
  callback = function(ev)
    local lang = vim.treesitter.language.get_lang(vim.bo[ev.buf].filetype)
    if not lang or lang == '' then
      return
    end
    -- language.add() loads parser/<lang>.so when Nix provides it, and returns
    -- false when it does not, so filestypes without a parser are skipped
    -- rather than throwing.
    if vim.treesitter.language.add(lang) then
      vim.treesitter.start(ev.buf, lang)
    end
  end,
})
EOF

" -----------------------------
" LSP setup
" -----------------------------
" Only register servers whose binary actually exists on this machine; an
" absent binary would otherwise throw on every buffer open.
lua << EOF
local function have(cmd) return vim.fn.executable(cmd) == 1 end
local servers = {}

if have('pyright-langserver') then
  vim.lsp.config('pyright', { cmd = { 'pyright-langserver', '--stdio' }, filetypes = { 'python' }, root_markers = { 'pyproject.toml', 'setup.py', 'requirements.txt' } })
  servers[#servers + 1] = 'pyright'
end
if have('yaml-language-server') then
  vim.lsp.config('yamlls', { cmd = { 'yaml-language-server', '--stdio' }, filetypes = { 'yaml' }, root_markers = { '.git' } })
  servers[#servers + 1] = 'yamlls'
end
if have('bash-language-server') then
  vim.lsp.config('bashls', { cmd = { 'bash-language-server', 'start' }, filetypes = { 'sh' }, root_markers = { '.git' } })
  servers[#servers + 1] = 'bashls'
end
-- NixOS ships the Eclipse JDT language server as `jdtls`; other distributions
-- use `jdt-language-server`. Accept either so the guard matches reality.
if have('jdtls') || have('jdt-language-server') then
  vim.lsp.config('jdtls', { cmd = { have('jdtls') and 'jdtls' or 'jdt-language-server' }, filetypes = { 'java' }, root_markers = { 'pom.xml', 'build.gradle' } })
  servers[#servers + 1] = 'jdtls'
end

-- Ballerina is registered and started in one place only: vim.lsp.enable()
-- below attaches the client on the matching filetype, so an extra FileType
-- autocmd would register the same server a second time under another name.
if have('bal') then
  vim.lsp.config('ballerina', {
    cmd = { 'bal', 'start-language-server' },
    filetypes = { 'ballerina' },
    root_markers = { 'Ballerina.toml', '.bal' },
  })
  servers[#servers + 1] = 'ballerina'
end

if #servers > 0 then
  vim.lsp.enable(servers)
end

-- Report servers that are configured but absent from PATH once per session,
-- instead of letting them fail silently on every buffer.
local missing = {}
for _, cmd in ipairs({
  'pyright-langserver',
  'yaml-language-server',
  'bash-language-server',
  'jdtls',
  'jdt-language-server',
  'bal',
}) do
  if not have(cmd) then missing[#missing + 1] = cmd end
end

if #missing > 0 then
  vim.api.nvim_create_autocmd('VimEnter', {
    group = vim.api.nvim_create_augroup('UserLspNotice', { clear = true }),
    callback = function()
      vim.schedule(function()
        vim.notify(
          'nvim: these LSP servers are not on PATH: ' .. table.concat(missing, ', '),
          vim.log.levels.WARN
        )
      end)
    end,
  })
end
EOF

" -----------------------------
" Force Ballerina commentstring
" -----------------------------
augroup ballerina_comment
  autocmd!
  autocmd FileType ballerina setlocal commentstring=//\ %s
augroup END

" -----------------------------
" Smooth scrolling (neoscroll)
" -----------------------------
lua << EOF
local ok, neoscroll = pcall(require, 'neoscroll')
if ok then
  neoscroll.setup({
    easing_function = "quadratic",
    hide_cursor = true,
    stop_eof = true,
  })
end
EOF

" -----------------------------
" Comment.nvim setup (with Ballerina support)
" -----------------------------
lua << EOF
local ok, comment = pcall(require, 'Comment')
if ok then
    comment.setup({
        padding = true,
        sticky = true,
        toggler = { line = 'gcc', block = 'gbc' },
        opleader = { line = 'gc', block = 'gb' },
    })
end
EOF

" -----------------------------
" NvimTree settings
" -----------------------------
lua << EOF
local ok, nvim_tree = pcall(require, 'nvim-tree')
if not ok then return end

nvim_tree.setup({
  -- Quit tree when opening a file
  actions = {
    open_file = {
      quit_on_open = false,  -- change to true if you want the tree to close automatically
    },
  },

  -- Git integration
  git = { ignore = true },

  -- Renderer settings
  renderer = { indent_markers = { enable = true } },

  -- Tree view width
  view = { width = 30 },
})

-- Keymap to toggle
vim.api.nvim_set_keymap('n', '<C-n>', ':NvimTreeToggle<CR>', { noremap = true, silent = true })

-- Open tree on VimEnter
local api_ok, nvim_tree_api = pcall(require, 'nvim-tree.api')
if api_ok then
  vim.api.nvim_create_autocmd('VimEnter', {
    callback = function()
      nvim_tree_api.tree.open()
    end
  })
end
EOF

" Colorscheme
colorscheme gruvbox

" -----------------------------
" LSP keymaps
" -----------------------------
nnoremap <silent> gd <cmd>lua vim.lsp.buf.definition()<CR>
nnoremap <silent> K <cmd>lua vim.lsp.buf.hover()<CR>
nnoremap <silent> gr <cmd>lua vim.lsp.buf.references()<CR>
nnoremap <silent> <leader>rn <cmd>lua vim.lsp.buf.rename()<CR>
nnoremap <silent> <leader>ca <cmd>lua vim.lsp.buf.code_action()<CR>
nnoremap <silent> <leader>f <cmd>lua vim.lsp.buf.format({ async = true })<CR>
nnoremap <silent> [d <cmd>lua vim.diagnostic.goto_prev()<CR>
nnoremap <silent> ]d <cmd>lua vim.diagnostic.goto_next()<CR>
nnoremap <silent> <leader>ld <cmd>lua vim.diagnostic.open_float()<CR>