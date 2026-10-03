" =============================================================================
" Neovim configuration
"
" Dual provisioning, selected by the presence of /etc/NIXOS:
"
"   * NixOS: every plugin and every Tree-sitter parser is declared in
"     nixos-config (flake input `nvim-config` + programs.neovim.extraPackages),
"     which pins them in flake.lock. No plugin-manager bootstrap and no runtime
"     downloads: the same config and the same versions land on every device
"     from a single `nixos-rebuild`.
"
"   * Other devices (no /etc/NIXOS): the same config would otherwise find no
"     plugins or parsers at all, so this file bootstraps lazy.nvim on first
"     start and installs the same plugins (see the "Plugin provisioning" block
"     below); Tree-sitter parsers are installed on demand with :TSInstall.
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
" Plugin provisioning for non-NixOS devices
" -----------------------------
" On NixOS, plugins and tree-sitter parsers are pinned by nix (see the header
" comment). On other devices, bootstrap lazy.nvim and install the same plugins
" so the pcall-guarded setup() calls below actually find them. The guard makes
" this a no-op when /etc/NIXOS exists.
lua << EOF
if not vim.uv.fs_stat('/etc/NIXOS') then
  local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
  if not vim.uv.fs_stat(lazypath) then
    vim.fn.system({
      'git', 'clone', '--filter=blob:none',
      'https://github.com/folke/lazy.nvim.git', '--branch=stable', lazypath,
    })
  end
  vim.opt.rtp:prepend(lazypath)
  require('lazy').setup({
    { 'nvim-tree/nvim-web-devicons' },
    { 'nvim-tree/nvim-tree.lua' },
    { 'numToStr/Comment.nvim' },
    { 'karb94/neoscroll.nvim' },
    { 'ellisonleao/gruvbox.nvim' },
    -- nvim-treesitter main HEAD requires Neovim 0.12 (vim.list.unique); pin to
    -- the last main-branch commit that supports 0.11 so :TSInstall/:TSUpdate
    -- keep working here. Parsers still compile through the tree-sitter CLI.
    { 'nvim-treesitter/nvim-treesitter', commit = '4d9916e477e5d4e3b245845dfd285edf429f3252', build = ':TSUpdate' },
  }, {
    -- Keep the lockfile out of the config repo (nix pins versions there).
    lockfile = vim.fn.stdpath('data') .. '/lazy-lock.json',
  })
end
EOF

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
-- Ballerina: the distro's bundled launcher script is not executable and its
-- legacy JDK 1.8 check rejects the bundled JDK 21, so the java classpath
-- invocation is built directly (verified working via LSP initialize handshake).
-- The classpath invocation runs `java` from PATH, so java must exist too.
if have('bal') and have('java') then
  local bal_bin = vim.fn.resolve(vim.fn.exepath('bal'))
  local bal_home = vim.fn.fnamemodify(bal_bin, ':h:h')
  local distro_dir
  local version_file = bal_home .. '/distributions/ballerina-version'
  if vim.uv.fs_stat(version_file) then
    local f = io.open(version_file, 'r')
    if f then
      distro_dir = bal_home .. '/distributions/' .. vim.trim(f:read('*a'))
      f:close()
    end
  else
    -- No version file: fall back to the newest installed distribution dir.
    local distros = vim.fn.glob(bal_home .. '/distributions/ballerina-*', true, true)
    table.sort(distros)
    distro_dir = distros[#distros]
  end
  -- Register only when the distro has the language server classpath layout;
  -- otherwise skip silently.
  if distro_dir
    and vim.uv.fs_stat(distro_dir .. '/bre')
    and vim.uv.fs_stat(distro_dir .. '/lib/tools/lang-server/lib') then
    vim.lsp.config('ballerina', { cmd = { 'java', '-Dballerina.home=' .. distro_dir, '-cp', distro_dir .. '/bre/lib/*:' .. distro_dir .. '/lib/tools/lang-server/lib/*', 'org.ballerinalang.langserver.launchers.stdio.Main' }, filetypes = { 'ballerina' }, root_markers = { 'Ballerina.toml', '.git' } })
    servers[#servers + 1] = 'ballerina'
  end
end

-- Java (JDT): prefer jdtls on PATH, else fall back to the newest VS Code
-- redhat.java extension launcher; the launcher auto-creates per-project data
-- dirs under ~/.cache/jdtls, so no -data argument is passed.
if have('java') then
  local jdtls_cmd
  if have('jdtls') then
    jdtls_cmd = { 'jdtls' }
  else
    local candidates = vim.fn.glob('~/.vscode/extensions/redhat.java-*/server/bin/jdtls', true, true)
    table.sort(candidates)
    local candidate = candidates[#candidates]
    if candidate and vim.fn.executable(candidate) == 1 then
      jdtls_cmd = { candidate }
    end
  end
  if jdtls_cmd then
    vim.lsp.config('jdtls', { cmd = jdtls_cmd, filetypes = { 'java' }, root_markers = { '.git', 'pom.xml', 'build.gradle', 'settings.gradle', 'gradlew', 'mvnw' } })
    servers[#servers + 1] = 'jdtls'
  end
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
}) do
  if not have(cmd) then missing[#missing + 1] = cmd end
end

-- The notice exists to tell the Nix user which pinned servers nix did not
-- install; on non-Nix devices the binaries are managed directly, so the WARN
-- would be noise on every startup. Only NixOS gets the notice.
if vim.uv.fs_stat('/etc/NIXOS') and #missing > 0 then
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

" Colorscheme. The gruvbox plugin is Nix-provisioned on other devices; the
" guard suppresses E185 here, where it is absent.
silent! colorscheme gruvbox

" -----------------------------
" LSP keymaps
" -----------------------------
nnoremap <silent> gd <cmd>lua vim.lsp.buf.definition()<CR>
nnoremap <silent> K <cmd>lua vim.lsp.buf.hover()<CR>
nnoremap <silent> gr <cmd>lua vim.lsp.buf.references()<CR>
nnoremap <silent> <leader>rn <cmd>lua vim.lsp.buf.rename()<CR>
nnoremap <silent> <leader>ca <cmd>lua vim.lsp.buf.code_action()<CR>
nnoremap <silent> <leader>f <cmd>lua vim.lsp.buf.format({ async = true })<CR>
nnoremap <silent> [d <cmd>lua vim.diagnostic.jump({ count = -1, float = true })<CR>
nnoremap <silent> ]d <cmd>lua vim.diagnostic.jump({ count = 1, float = true })<CR>
nnoremap <silent> <leader>ld <cmd>lua vim.diagnostic.open_float()<CR>