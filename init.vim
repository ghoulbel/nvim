" ==============================
" Neovim 0.11+ Full DevOps / Dev Setup
" ==============================

" General Settings
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

" Ensure .bal files are recognized as Ballerina
augroup ballerina_filetype
  autocmd!
  autocmd BufRead,BufNewFile *.bal set filetype=ballerina
augroup END

set tabstop=2
set shiftwidth=2
set expandtab
set autoindent
set smartindent
set showmatch
set mouse=a
set clipboard=unnamedplus
set foldmethod=syntax
set foldlevelstart=99

" -----------------------------
" Plugin manager: vim-plug
" -----------------------------
" vim-plug is provided by Nix (see programs.neovim.extraPackages in
" nixos-config), so it is already on the runtimepath.
call plug#begin('~/.local/share/nvim/plugged')

Plug 'morhetz/gruvbox'
Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
Plug 'stephpy/vim-yaml'
Plug 'towolf/vim-helm'
Plug 'neovim/nvim-lspconfig'
Plug 'kyazdani42/nvim-tree.lua'
Plug 'kyazdani42/nvim-web-devicons'
Plug 'numToStr/Comment.nvim'
Plug 'karb94/neoscroll.nvim'

call plug#end()

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
" Force Ballerina commentstring
" -----------------------------
augroup ballerina_comment
  autocmd!
  autocmd FileType ballerina setlocal commentstring=//\ %s
augroup END

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
" Tree-sitter setup
" -----------------------------
lua << EOF
local ok, ts = pcall(require, 'nvim-treesitter.configs')
if ok then
  ts.setup {
    ensure_installed = {
      "python", "java", "xml", "yaml", "bash", "json", "dockerfile", "terraform", "helm","ballerina"
    },
    highlight = { enable = true },
    indent = { enable = true },
    playground = { enable = true },
    sync_install = false,
    auto_install = true
  }
end
EOF

" -----------------------------
" LSP setup (new API)
" -----------------------------
lua << EOF
-- Only register servers whose binary actually exists on this machine; an
-- absent binary would otherwise throw on every buffer open.
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
if have('jdtls') or have('jdt-language-server') then
  vim.lsp.config('jdtls', { cmd = { have('jdtls') and 'jdtls' or 'jdt-language-server' }, filetypes = { 'java' }, root_markers = { 'pom.xml', 'build.gradle' } })
  servers[#servers + 1] = 'jdtls'
end

-- Ballerina LSP (only when the Ballerina toolchain is installed)
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
EOF

" -----------------------------
" Ballerina LSP auto-start
" -----------------------------
lua << EOF
vim.filetype.add({ extension = { bal = 'ballerina' } })

-- Only auto-start when the Ballerina toolchain is actually installed.
if vim.fn.executable('bal') == 1 then
  local function start_ballerina_lsp()
      local found = vim.fs.find({ 'Ballerina.toml' }, { upward = true })[1]
      local root_dir = found and vim.fs.dirname(found) or vim.fn.expand('%:p:h')
      vim.lsp.start({
          name = 'ballerina-lsp',
          cmd = { 'bal', 'start-language-server' },
          root_dir = root_dir,
      })
  end

  vim.api.nvim_create_autocmd('FileType', {
      pattern = 'ballerina',
      callback = start_ballerina_lsp,
  })
end
EOF

" -----------------------------
" LSP keymaps
" -----------------------------
nnoremap <silent> gd <cmd>lua vim.lsp.buf.definition()<CR>
nnoremap <silent> K <cmd>lua vim.lsp.buf.hover()<CR>
nnoremap <silent> gr <cmd>lua vim.lsp.buf.references()<CR>
nnoremap <silent> <leader>rn <cmd>lua vim.lsp.buf.rename()<CR>
nnoremap <silent> <leader>ca <cmd>lua vim.lsp.buf.code_action()<CR>

