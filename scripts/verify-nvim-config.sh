#!/usr/bin/env bash
# verify_nvim_config.sh — verification for the ~/.config/nvim/init.vim changes:
#   warmup) device provisioning, idempotent: ensures the tree-sitter CLI (the
#      nvim-treesitter main branch compiles parsers with it), runs a first
#      headless nvim so lazy.nvim bootstraps and installs the plugins, installs
#      the Tree-sitter parsers (:TSInstall is async -> poll until loadable),
#      and tries ballerina (informational; no parser expected)
#   a) config loads headless: exit 0, no "E185", no targeted "Error"
#      (line-start "Error" or E[0-9]{3}); the missing-servers WARN line is
#      expected output and must not be treated as failure
#   b) ballerina LSP client (initialized + attached to the opened buffer) on a
#      real `bal new` project (cwd = project)
#   c) jdtls client (initialized + attached to the opened buffer) on a
#      git-initialized java project (cwd = project)
#   d) grep assertions: deprecations gone, new lines present
#   e) self-test (non-counting unless it fails): a mutated copy with plain
#      `colorscheme gruvbox` must trip the script's own E185 assertion
#   f) vim/vi are aliased to nvim in interactive bash
#   g) headless state: colorscheme applied (vim.g.colors_name == 'gruvbox'),
#      nvim-tree requireable, java parser loadable, no missing-servers WARN
#   h) `nvim .` (directory arg) opens/hijacks into an NvimTree buffer
#   i) pyright-langserver on PATH and a pyright client attaches to a .py file
#   j) ballerina highlighting (round 5, the VS Code model): device-local
#      regex syntax file (~/.local/share/nvim/site/syntax/ballerina.vim —
#      outside the config repo) + LSP semantic tokens. On a standalone .bal
#      (NO Ballerina.toml, NO .git): filetype=ballerina and synID at
#      keyword/comment/string/type/line-comment positions (slashes, text and
#      quotes inside // comments) resolves to >=3 distinct groups with
#      non-empty fg; in a project the ballerina LSP attaches AND advertises
#      semanticTokensProvider; the mis-parsing treesitter ballerina parser
#      (62 ERROR nodes on realistic code) stays REMOVED. The main.bal buffer is resolved BY NAME and
#      polled every 500ms until the treesitter highlighter is active (the
#      current buffer cannot be trusted: init.vim opens NvimTree on VimEnter,
#      which hijacks focus a couple of seconds into startup). Also asserted:
#      >=3 DISTINCT capture names whose `@name` groups resolve to a
#      foreground color (the actual "no color differentiation" complaint),
#      and a cursor-position proof (get_captures_at_cursor on a keyword
#      returns 'keyword' — Inspect-equivalent). The installed
#      highlights.scm gets an idempotent cosmetic normalization
#      ("equals"@keyword -> "equals" @keyword); the upstream clone
#      (/tmp/opencode/tsb) is deliberately NOT touched.
set -u

CONFIG="${CONFIG:-/home/ghoulbel/.config/nvim/init.vim}"
WORK=/tmp/opencode
POLL="$WORK/poll_client.lua"
TREEPOLL="$WORK/poll_tree.lua"
STATE="$WORK/check_state.lua"
TSPOLL="$WORK/ts_install_poll.lua"
MAXBALLERINA=90000   # ms — Ballerina LS boots slowly
MAXJAVA=120000       # ms — JDTLS is even slower
MAXPYRIGHT=120000    # ms — pyright is quick, but node startup is not instant
TSLANGS="java python bash yaml lua json toml markdown vim vimdoc"

PASS=0
FAIL=0
report() { # name status [detail]
  local name="$1" status="$2" detail="${3:-}"
  if [ "$status" = PASS ]; then
    PASS=$((PASS + 1)); printf 'PASS  %s%s\n' "$name" "${detail:+  [$detail]}"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %s%s\n' "$name" "${detail:+  [$detail]}"
  fi
}

mkdir -p "$WORK"

# ------------------------------------------------------------------ poll helper
# Registers run_poll(name, timeout_ms): polls vim.lsp.get_clients({ name })
# every second via a uv timer until a client for `name` exists that is fully
# initialized AND attached to the buffer that was current when the poll
# started, or the timeout elapses; prints the result, then quits (exit 0 on
# attach, 1 on timeout).
cat > "$POLL" <<'LUA'
function run_poll(name, timeout_ms)
  local bufnr = vim.api.nvim_get_current_buf()
  local timer = vim.uv.new_timer()
  local waited = 0
  timer:start(1000, 1000, vim.schedule_wrap(function()
    waited = waited + 1000
    local clients = vim.lsp.get_clients({ name = name })
    for _, client in ipairs(clients) do
      if client.initialized == true and client.attached_buffers[bufnr] then
        timer:stop(); timer:close()
        print(string.format('%s_CLIENT=attached after %dms (%d client(s))', name, waited, #clients))
        vim.cmd('qa!')
        return
      end
    end
    if waited >= timeout_ms then
      timer:stop(); timer:close()
      print(string.format('%s_CLIENT=timeout after %dms', name, waited))
      vim.cmd('cquit 1')
    end
  end))
end
LUA

# ------------------------------------------------------------------ tree poll
# Registers run_tree_poll(timeout_ms): polls every second for an NvimTree
# buffer (focused or merely existing) — `nvim .` must open/hijack into the
# tree. Prints the result, then quits (exit 0 on success, 1 on timeout).
cat > "$TREEPOLL" <<'LUA'
function run_tree_poll(timeout_ms)
  local timer = vim.uv.new_timer()
  local waited = 0
  timer:start(1000, 1000, vim.schedule_wrap(function()
    waited = waited + 1000
    local ft = vim.bo.filetype
    local exists = false
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == 'NvimTree' then exists = true end
    end
    if ft == 'NvimTree' or exists then
      timer:stop(); timer:close()
      print(string.format('NVIMTREE=open after %dms (focused=%s exists=%s)',
        waited, tostring(ft == 'NvimTree'), tostring(exists)))
      vim.cmd('qa!')
    elseif waited >= timeout_ms then
      timer:stop(); timer:close()
      print('NVIMTREE=timeout after ' .. waited .. 'ms')
      vim.cmd('cquit 1')
    end
  end))
end
LUA

# ------------------------------------------------------------------ state poll
# Registers run_state_checks(timeout_ms): polls every second until
#   - vim.g.colors_name == 'gruvbox'   (colorscheme actually applied)
#   - pcall(require, 'nvim-tree')      (lazy-installed plugin loadable)
#   - vim.treesitter.language.add('java')  (parser installed + loadable)
# or the timeout elapses; prints each state, then quits (exit 0 when all hold).
# NOTE: io.write, not print — print()'s newline is unreliable in headless uv
# timer callbacks (lines end up concatenated and break anchored greps).
cat > "$STATE" <<'LUA'
function run_state_checks(timeout_ms)
  local timer = vim.uv.new_timer()
  local waited = 0
  timer:start(1000, 1000, vim.schedule_wrap(function()
    waited = waited + 1000
    local colors = vim.g.colors_name
    local tree_ok = (pcall(require, 'nvim-tree')) and true or false
    local ts_java = vim.treesitter.language.add('java') and true or false
    if (colors == 'gruvbox' and tree_ok and ts_java) or waited >= timeout_ms then
      timer:stop(); timer:close()
      io.write('STATE colors_name=' .. tostring(colors) .. '\n')
      io.write('STATE nvim_tree=' .. tostring(tree_ok) .. '\n')
      io.write('STATE ts_java=' .. tostring(ts_java) .. '\n')
      if colors == 'gruvbox' and tree_ok and ts_java then
        vim.cmd('qa!')
      else
        vim.cmd('cquit 1')
      end
    end
  end))
end
LUA

# ------------------------------------------------------------- ts install poll
# Registers ts_install_poll(langs, timeout_ms): runs :TSInstall (async) and
# polls vim.treesitter.language.add() every 2s until every parser is installed
# and loadable or the timeout elapses. Prints the result, then quits
# (exit 0 on success, 1 on timeout).
cat > "$TSPOLL" <<'LUA'
function ts_install_poll(langs, timeout_ms)
  vim.cmd('TSInstall ' .. table.concat(langs, ' '))
  local wanted = {}
  for _, lang in ipairs(langs) do wanted[lang] = true end

  local timer = vim.uv.new_timer()
  local waited = 0
  timer:start(2000, 2000, vim.schedule_wrap(function()
    waited = waited + 2000
    local missing = {}
    for lang in pairs(wanted) do
      if not vim.treesitter.language.add(lang) then
        missing[#missing + 1] = lang
      end
    end
    if #missing == 0 then
      timer:stop(); timer:close()
      print(string.format('TSINSTALL=complete after %dms (%d parsers)', waited, #vim.tbl_keys(wanted)))
      vim.cmd('qa!')
    elseif waited >= timeout_ms then
      timer:stop(); timer:close()
      print('TSINSTALL=timeout after ' .. waited .. 'ms; still missing: ' .. table.concat(missing, ', '))
      vim.cmd('cquit 1')
    end
  end))
end
LUA

# ---------------------------------------------------------------------- warmup
# Idempotent device provisioning: the FIRST nvim run triggers the lazy
# bootstrap (git clone of lazy.nvim + the plugin spec + ':TSUpdate' build),
# which can take minutes; parser compilation needs the tree-sitter CLI.
echo '== (warmup) device provisioning (idempotent; informational) =='
warmup_fail=0

# pyright via pipx (no sudo needed) so the pyright LSP check can attach.
if ! command -v pyright-langserver >/dev/null 2>&1; then
  if command -v pipx >/dev/null 2>&1 && pipx install pyright >/dev/null 2>&1; then
    echo 'WARMUP  pyright installed via pipx'
  else
    echo 'WARMUP FAIL  could not install pyright via pipx'; warmup_fail=1
  fi
fi

# tree-sitter CLI: nvim-treesitter (main branch) compiles parsers with
# `tree-sitter build`, not cc directly.
if ! command -v tree-sitter >/dev/null 2>&1; then
  curl -sL --fail -o "$WORK/tree-sitter.gz" \
    https://github.com/tree-sitter/tree-sitter/releases/download/v0.27.0/tree-sitter-linux-x64.gz \
    && gunzip -f "$WORK/tree-sitter.gz" \
    && mkdir -p "$HOME/.local/bin" \
    && mv "$WORK/tree-sitter" "$HOME/.local/bin/tree-sitter" \
    && chmod +x "$HOME/.local/bin/tree-sitter"
  if command -v tree-sitter >/dev/null 2>&1; then
    echo 'WARMUP  tree-sitter CLI installed to ~/.local/bin'
  else
    echo 'WARMUP FAIL  could not install tree-sitter CLI'; warmup_fail=1
  fi
fi

# 1) lazy bootstrap: installs lazy.nvim + the plugin spec on first run.
if ! timeout 300 nvim --headless -u "$CONFIG" +qall >/dev/null 2>&1; then
  echo 'WARMUP FAIL  nvim --headless +qall (lazy bootstrap) failed'; warmup_fail=1
fi

# 2) Tree-sitter parsers: :TSInstall is async, so run it and poll until every
#    parser is loadable. Idempotent (already-installed parsers are skipped).
if ! ts_out=$(timeout 400 nvim --headless -u "$CONFIG" \
    -c "luafile $TSPOLL" -c "lua ts_install_poll({$(
      for l in $TSLANGS; do printf "'%s'," "$l"; done | sed 's/,$//')}, 300000)" 2>&1); then
  echo 'WARMUP FAIL  parser install poll failed'; printf '%s\n' "$ts_out" | sed 's/^/      /'
  warmup_fail=1
fi
printf '%s\n' "$ts_out" | grep -o 'TSINSTALL=[a-z]*.*' | sed 's/^/      /'

# 3) ballerina (informational, non-counting): nvim-treesitter has no ballerina
#    parser — .bal keeps LSP-only highlighting via semantic tokens.
bal_ts=$(timeout 60 nvim --headless -u "$CONFIG" \
  "+TSInstall ballerina" "+sleep 20000" \
  -c "lua print('BALLERINA_TS=' .. tostring(vim.treesitter.language.add('ballerina')))" \
  "+qall" 2>&1 | grep -o 'BALLERINA_TS=[a-z]*' | head -1)
echo "WARMUP  ballerina tree-sitter parser: ${bal_ts:-BALLERINA_TS=false (not available — LSP-only highlighting)}"

if [ "$warmup_fail" -ne 0 ]; then
  FAIL=$((FAIL + 1)); printf 'FAIL  warmup device provisioning\n'
else
  echo 'WARMUP  ok'
fi

# ------------------------------------------------------------------------ (a)
echo '== (a) headless load =='
out=$(nvim --headless -u "$CONFIG" +qall 2>&1)
rc=$?
[ "$rc" -eq 0 ] && report 'a) nvim --headless exits 0' PASS || report 'a) nvim --headless exits 0' FAIL "rc=$rc"
if printf '%s\n' "$out" | grep -q 'E185'; then
  report 'a) no E185 in output' FAIL "$(printf '%s\n' "$out" | grep 'E185' | head -1)"
else
  report 'a) no E185 in output' PASS
fi
if printf '%s\n' "$out" | grep -qE '^Error|E[0-9]{3}'; then
  report 'a) no Error in output' FAIL "$(printf '%s\n' "$out" | grep -E '^Error|E[0-9]{3}' | head -1)"
else
  report 'a) no Error in output' PASS
fi
[ -n "$out" ] && printf '      output: %s\n' "$out"

# ------------------------------------------------------------------------ (b)
echo '== (b) ballerina LSP =='
rm -rf "$WORK/lsp_test_ballerina"
(cd "$WORK" && bal new lsp_test_ballerina >/dev/null 2>&1)
if [ -f "$WORK/lsp_test_ballerina/Ballerina.toml" ]; then
  report 'b) bal new project created' PASS
else
  report 'b) bal new project created' FAIL 'Ballerina.toml missing'
fi

if [ -d "$WORK/lsp_test_ballerina" ]; then
  out=$(cd "$WORK/lsp_test_ballerina" && timeout 150 \
    nvim --headless -u "$CONFIG" main.bal \
    -c "luafile $POLL" -c "lua run_poll('ballerina', $MAXBALLERINA)" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed 's/^/      /'
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'ballerina_CLIENT=attached'; then
    report 'b) ballerina client attached' PASS "$(printf '%s\n' "$out" | grep -o 'attached after [0-9]*ms' | head -1)"
  else
    report 'b) ballerina client attached' FAIL "rc=$rc"
  fi
fi

# ------------------------------------------------------------------------ (c)
echo '== (c) jdtls =='
rm -rf "$WORK/lsp_test_java"
mkdir -p "$WORK/lsp_test_java"
(cd "$WORK/lsp_test_java" && git init -q && printf 'public class Test {\n  public static void main(String[] args) {}\n}\n' > Test.java)
[ -d "$WORK/lsp_test_java/.git" ] && report 'c) git project created' PASS || report 'c) git project created' FAIL

out=$(cd "$WORK/lsp_test_java" && timeout 180 \
  nvim --headless -u "$CONFIG" Test.java \
  -c "luafile $POLL" -c "lua run_poll('jdtls', $MAXJAVA)" 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'jdtls_CLIENT=attached'; then
  report 'c) jdtls client attached' PASS "$(printf '%s\n' "$out" | grep -o 'attached after [0-9]*ms' | head -1)"
else
  report 'c) jdtls client attached' FAIL "rc=$rc"
fi

# ------------------------------------------------------------------------ (d)
echo '== (d) init.vim grep assertions =='
if grep -nE 'goto_prev|goto_next|ttyfast' "$CONFIG" >/dev/null 2>&1; then
  report 'd) no goto_prev/goto_next/ttyfast remain' FAIL "$(grep -nE 'goto_prev|goto_next|ttyfast' "$CONFIG" | tr '\n' '|')"
else
  report 'd) no goto_prev/goto_next/ttyfast remain' PASS
fi
grep -q 'silent! colorscheme gruvbox' "$CONFIG" \
  && report 'd) silent! colorscheme gruvbox present' PASS \
  || report 'd) silent! colorscheme gruvbox present' FAIL
grep -q 'vim.lsp.enable(servers)' "$CONFIG" \
  && report 'd) vim.lsp.enable(servers) still present' PASS \
  || report 'd) vim.lsp.enable(servers) still present' FAIL
grep -q "vim.lsp.config('ballerina'" "$CONFIG" \
  && report "d) ballerina config block present" PASS \
  || report "d) ballerina config block present" FAIL
grep -q "vim.lsp.config('jdtls'" "$CONFIG" \
  && report "d) jdtls config block present" PASS \
  || report "d) jdtls config block present" FAIL

# ------------------------------------------------------------------------ (e)
# Self-test: copy the config to /tmp, swap the guarded colorscheme line for an
# unguarded reference to a colorscheme that cannot exist, and assert the
# script's own E185 assertion WOULD fail the mutated copy (i.e. E185 appears
# in its output). Printed as a separate self-test line; it counts toward the
# totals only when it fails.
echo '== (e) self-test: E185 mutation check =='
MUT="$WORK/init_vim_mutated"
cp "$CONFIG" "$MUT"
sed -i 's/^silent! colorscheme gruvbox$/colorscheme verify_no_such_colorscheme/' "$MUT"
if ! grep -q '^colorscheme verify_no_such_colorscheme$' "$MUT" || grep -q '^silent! colorscheme gruvbox$' "$MUT"; then
  printf 'SELF-TEST FAIL  mutation did not apply to %s\n' "$MUT"
  FAIL=$((FAIL + 1))
else
  mut_out=$(nvim --headless -u "$MUT" +qall 2>&1)
  mut_rc=$?
  if printf '%s\n' "$mut_out" | grep -q 'E185'; then
    printf 'SELF-TEST PASS  mutated config trips E185 as expected (rc=%s)\n' "$mut_rc"
  else
    printf 'SELF-TEST FAIL  mutated config did not trip E185 (rc=%s)\n' "$mut_rc"
    printf '%s\n' "$mut_out" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
fi
rm -f "$MUT"

# ------------------------------------------------------------------------ (f)
echo '== (f) vim/vi aliases =='
vim_type=$(bash -ic 'type vim' 2>&1)
if printf '%s\n' "$vim_type" | grep -q "aliased to" && printf '%s\n' "$vim_type" | grep -q 'nvim'; then
  report 'f) vim is aliased to nvim' PASS "($(printf '%s\n' "$vim_type" | grep -o 'vim is aliased to.*' | head -1))"
else
  report 'f) vim is aliased to nvim' FAIL "($(printf '%s\n' "$vim_type" | grep -o 'vim is aliased to.*' | head -1))"
fi
vi_type=$(bash -ic 'type vi' 2>&1)
if printf '%s\n' "$vi_type" | grep -q "aliased to" && printf '%s\n' "$vi_type" | grep -q 'nvim'; then
  report 'f) vi is aliased to nvim' PASS "($(printf '%s\n' "$vi_type" | grep -o 'vi is aliased to.*' | head -1))"
else
  report 'f) vi is aliased to nvim' FAIL "($(printf '%s\n' "$vi_type" | grep -o 'vi is aliased to.*' | head -1))"
fi

# ------------------------------------------------------------------------ (g)
# Headless state with the regular user config: the colorscheme must actually
# apply, nvim-tree must be requireable (lazy installed it), the java parser
# must be loadable, and the missing-servers WARN notice must NOT appear on
# this non-NixOS device (it is NixOS-only now).
echo '== (g) headless state (colorscheme, nvim-tree, java parser, no WARN) =='
out=$(timeout 90 nvim --headless -u "$CONFIG" \
  -c "luafile $STATE" -c "lua run_state_checks(30000)" 2>&1)
rc=$?
printf '%s\n' "$out" | grep '^STATE' | sed 's/^/      /'
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^STATE colors_name=gruvbox$'; then
  report 'g) colorscheme applied (colors_name=gruvbox)' PASS
else
  report 'g) colorscheme applied (colors_name=gruvbox)' FAIL "rc=$rc"
fi
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^STATE nvim_tree=true$'; then
  report 'g) nvim-tree requireable' PASS
else
  report 'g) nvim-tree requireable' FAIL "rc=$rc"
fi
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^STATE ts_java=true$'; then
  report 'g) java parser installed+loadable' PASS
else
  report 'g) java parser installed+loadable' FAIL "rc=$rc"
fi
if printf '%s\n' "$out" | grep -q 'not on PATH'; then
  report 'g) no missing-servers WARN on non-NixOS' FAIL "($(printf '%s\n' "$out" | grep 'not on PATH' | head -1))"
else
  report 'g) no missing-servers WARN on non-NixOS' PASS
fi

# ------------------------------------------------------------------------ (h)
echo '== (h) nvim . opens NvimTree =='
rm -rf "$WORK/tree_test"
mkdir -p "$WORK/tree_test"
out=$(cd "$WORK/tree_test" && timeout 60 \
  nvim --headless . \
  -c "luafile $TREEPOLL" -c "lua run_tree_poll(20000)" 2>&1)
rc=$?
printf '%s\n' "$out" | grep 'NVIMTREE' | sed 's/^/      /'
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'NVIMTREE=open'; then
  report 'h) nvim . opens NvimTree buffer' PASS "$(printf '%s\n' "$out" | grep -o 'after [0-9]*ms' | head -1)"
else
  report 'h) nvim . opens NvimTree buffer' FAIL "rc=$rc"
fi

# ------------------------------------------------------------------------ (i)
echo '== (i) pyright =='
if command -v pyright-langserver >/dev/null 2>&1; then
  report 'i) pyright-langserver on PATH' PASS "($(command -v pyright-langserver))"
else
  report 'i) pyright-langserver on PATH' FAIL 'not found'
fi

rm -rf "$WORK/lsp_test_pyright"
mkdir -p "$WORK/lsp_test_pyright"
printf '[project]\nname = "verify-pyright"\nversion = "0.0.1"\n' > "$WORK/lsp_test_pyright/pyproject.toml"
printf 'def add(a, b):\n    return a + b\n' > "$WORK/lsp_test_pyright/test.py"

out=$(cd "$WORK/lsp_test_pyright" && timeout 150 \
  nvim --headless -u "$CONFIG" test.py \
  -c "luafile $POLL" -c "lua run_poll('pyright', $MAXPYRIGHT)" 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'pyright_CLIENT=attached'; then
  report 'i) pyright client attached' PASS "$(printf '%s\n' "$out" | grep -o 'attached after [0-9]*ms' | head -1)"
else
  report 'i) pyright client attached' FAIL "rc=$rc"
fi

# ------------------------------------------------------------------------ (j)
# Ballerina highlighting (round 5 — the VS Code model):
#   regex syntax (device-local syntax/ballerina.vim) + LSP semantic tokens.
# The round-4 device-local treesitter parser was REMOVED: the only community
# grammar mis-parses modern ballerina (62 ERROR nodes on a realistic service
# file), which made highlighting look broken. Checks:
#   j1) standalone .bal (NO Ballerina.toml, NO .git): filetype=ballerina and
#       :syntax coloring actually applies — synID at keyword/comment/string/
#       type positions resolves to >=3 DISTINCT groups with non-empty fg
#       (synID sees :syntax-based highlighting, not extmark/semantic one)
#   j2) project .bal: the ballerina LSP attaches (check b) AND its client
#       advertises semanticTokensProvider (semantic coloring on top), and the
#       mis-parsing treesitter parser stays gone
echo '== (j) ballerina highlighting (syntax + LSP semantic tokens) =='

SITEDIR="$HOME/.local/share/nvim/site"
[ -f "$SITEDIR/syntax/ballerina.vim" ] \
  && report 'j) syntax/ballerina.vim installed (device-local)' PASS "($SITEDIR/syntax/ballerina.vim)" \
  || report 'j) syntax/ballerina.vim installed (device-local)' FAIL "$SITEDIR/syntax/ballerina.vim missing"

# j2a) The mis-parsing treesitter ballerina parser must stay gone.
if [ ! -f "$SITEDIR/parser/ballerina.so" ]; then
  report 'j) mis-parsing ballerina treesitter parser removed' PASS
else
  report 'j) mis-parsing ballerina treesitter parser removed' FAIL "$SITEDIR/parser/ballerina.so still present"
fi

# j1) standalone .bal fixture: real content (import + doc comment + public main
#     + string + io:println), deliberately NO Ballerina.toml and NO .git.
BALCHECK="$WORK/bal_syntax_check.lua"
rm -rf "$WORK/bal_highlight_test"
mkdir -p "$WORK/bal_highlight_test"
cat > "$WORK/bal_highlight_test/main.bal" <<'BAL'
import ballerina/io;

# Greets the given name.
// Also a line comment, with a "quoted" word inside.
public function main() {
    string name = "world";
    io:println("Hello, " + name);
}
BAL
if [ -f "$WORK/bal_highlight_test/main.bal" ] && [ ! -f "$WORK/bal_highlight_test/Ballerina.toml" ] && [ ! -d "$WORK/bal_highlight_test/.git" ]; then
  report 'j) standalone main.bal fixture (no Ballerina.toml/.git)' PASS
else
  report 'j) standalone main.bal fixture (no Ballerina.toml/.git)' FAIL
fi

# run_bal_syntax_checks(bal_path, timeout_ms): resolve the buffer BY NAME
# (NvimTree hijacks the current buffer on VimEnter) and poll until the syntax
# file is sourced (b:current_syntax == 'ballerina'); then measure the RENDERED
# highlight via synID/synIDtrans/synIDattr at keyword/comment/string/type
# positions and report group name + fg per position. synID sees :syntax-based
# highlighting (NOT extmark/semantic highlighting — semantic state is checked
# in j2 via client capabilities). Positions are located dynamically.
# NOTE: io.write, not print — print()'s newline is unreliable in headless uv
# timer callbacks (lines end up concatenated and break anchored greps).
cat > "$BALCHECK" <<'LUA'
function run_bal_syntax_checks(bal_path, timeout_ms)
  local timer = vim.uv.new_timer()
  local waited = 0
  timer:start(500, 500, vim.schedule_wrap(function()
    waited = waited + 500
    -- Resolve the .bal buffer by full path on EVERY tick.
    local bufnr = vim.fn.bufnr(bal_path)
    if bufnr == -1 then
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == bal_path then bufnr = b end
      end
    end
    -- Poll until the syntax file is sourced for this buffer.
    local sourced = bufnr ~= -1
      and vim.bo[bufnr].filetype == 'ballerina'
      and vim.b[bufnr].current_syntax == 'ballerina'
    if not sourced and waited < timeout_ms then return end
    timer:stop(); timer:close()

    if bufnr == -1 then
      io.write('BAL_BUF=not-found\n')
      vim.cmd('cquit 1')
      return
    end
    io.write('BAL_FT=' .. vim.bo[bufnr].filetype .. '\n')

    -- synID measures the CURRENT window's buffer, and NvimTree usually owns
    -- the current window after the VimEnter hijack — so switch to the window
    -- actually displaying main.bal and redraw before measuring.
    local bal_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == bufnr then bal_win = w break end
    end
    if not bal_win then
      io.write('BAL_WIN=none\n')
      vim.cmd('cquit 1')
      return
    end
    if not pcall(vim.api.nvim_set_current_win, bal_win) then
      io.write('BAL_WIN=set-failed\n')
      vim.cmd('cquit 1')
      return
    end
    vim.cmd('redraw')

    -- Locate the positions to measure, dynamically. The `//` line comment is
    -- measured at BOTH the slashes AND inside the comment text: a regression
    -- where the operator match wins the same-position tie would leave the
    -- slashes orange and the text uncolored (round-5 bug this guards against).
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local pos = { kw = nil, cmt = nil, str = nil, typ = nil, lcmt = nil, lcmt_text = nil, lcmt_quote = nil }
    for i, l in ipairs(lines) do
      if l:find('public function') and not pos.kw then pos.kw = { lnum = i, col = 1 } end
      if l:sub(1, 1) == '#' and not pos.cmt then pos.cmt = { lnum = i, col = 1 } end
      local q = l:find('"')
      if l:find('world') and q and not pos.str then pos.str = { lnum = i, col = q + 1 } end
      local t = l:find('string ')
      if t and not pos.typ then pos.typ = { lnum = i, col = t } end
      local lc = l:find('//')
      if lc and not pos.lcmt then
        pos.lcmt = { lnum = i, col = lc }
        pos.lcmt_text = { lnum = i, col = lc + 12 } -- inside 'line comment,'
        local qq = l:find('"')
        if qq then pos.lcmt_quote = { lnum = i, col = qq } end
      end
    end

    local function hl_at(p)
      if not p then return 'MISSING fg=' end
      local ok, res = pcall(function()
        local eff = vim.fn.synIDtrans(vim.fn.synID(p.lnum, p.col, 1))
        return vim.fn.synIDattr(eff, 'name') .. ' fg=' .. vim.fn.synIDattr(eff, 'fg')
      end)
      return ok and res or 'pcall-failed fg='
    end

    local reports = {
      { name = 'keyword',     h = hl_at(pos.kw) },
      { name = 'comment',     h = hl_at(pos.cmt) },
      { name = 'string',      h = hl_at(pos.str) },
      { name = 'type',        h = hl_at(pos.typ) },
      { name = 'linecomment', h = hl_at(pos.lcmt) },
      { name = 'lcmt-text',   h = hl_at(pos.lcmt_text) },
      { name = 'lcmt-quote',  h = hl_at(pos.lcmt_quote) },
    }
    local groups, fgs = {}, {}
    for _, r in ipairs(reports) do
      io.write('BAL_HL ' .. r.name .. ': ' .. r.h .. '\n')
      local g = r.h:match('^(%S+) fg=')
      local f = r.h:match('fg=(%S+)')
      if g and g ~= 'MISSING' and f and f ~= '' then
        groups[g] = true
        fgs[f] = true
      end
    end
    io.write('BAL_SYNTAX_GROUPS=' .. vim.tbl_count(groups) .. '\n')
    io.write('BAL_SYNTAX_FGS=' .. vim.tbl_count(fgs) .. '\n')
    vim.cmd('qa!')
  end))
end
LUA

out=$(cd "$WORK/bal_highlight_test" && timeout 60 \
  nvim --headless -u "$CONFIG" main.bal \
  -c "luafile $BALCHECK" -c "lua run_bal_syntax_checks('$WORK/bal_highlight_test/main.bal', 20000)" 2>&1)
rc=$?
printf '%s\n' "$out" | grep -E '^BAL_' | sed 's/^/      /'

if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^BAL_FT=ballerina$'; then
  report 'j) standalone .bal: filetype=ballerina' PASS
else
  report 'j) standalone .bal: filetype=ballerina' FAIL "rc=$rc"
fi
bal_groups=$(printf '%s\n' "$out" | grep -o '^BAL_SYNTAX_GROUPS=[0-9]*' | cut -d= -f2)
if [ -n "$bal_groups" ] && [ "$bal_groups" -ge 3 ] 2>/dev/null; then
  report 'j) standalone .bal: >=3 distinct syntax groups colored' PASS "($bal_groups groups)"
else
  report 'j) standalone .bal: >=3 distinct syntax groups colored' FAIL "(groups=${bal_groups:-none})"
fi
bal_fgs=$(printf '%s\n' "$out" | grep -o '^BAL_SYNTAX_FGS=[0-9]*' | cut -d= -f2)
if [ -n "$bal_fgs" ] && [ "$bal_fgs" -ge 3 ] 2>/dev/null; then
  report 'j) standalone .bal: >=3 distinct fg colors' PASS "($bal_fgs colors)"
else
  report 'j) standalone .bal: >=3 distinct fg colors' FAIL "(colors=${bal_fgs:-none})"
fi
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep '^BAL_HL keyword:' | grep -q 'fg=#'; then
  report 'j) keyword rendered colored (synID)' PASS "$(printf '%s\n' "$out" | grep '^BAL_HL keyword:' | head -1 | sed 's/^BAL_HL keyword: *//')"
else
  report 'j) keyword rendered colored (synID)' FAIL
fi
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep '^BAL_HL comment:' | grep -q 'fg=#'; then
  report 'j) comment rendered colored (synID)' PASS "$(printf '%s\n' "$out" | grep '^BAL_HL comment:' | head -1 | sed 's/^BAL_HL comment: *//')"
else
  report 'j) comment rendered colored (synID)' FAIL
fi
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep '^BAL_HL string:' | grep -q 'fg=#'; then
  report 'j) string rendered colored (synID)' PASS "$(printf '%s\n' "$out" | grep '^BAL_HL string:' | head -1 | sed 's/^BAL_HL string: *//')"
else
  report 'j) string rendered colored (synID)' FAIL
fi
# `//` line comment: measured at the slashes AND inside the comment text —
# both must resolve to the Comment group (round-5 operator-tie regression).
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep '^BAL_HL linecomment:' | grep -qE '\bComment\b'; then
  report 'j) // comment rendered colored (synID)' PASS "$(printf '%s\n' "$out" | grep '^BAL_HL linecomment:' | head -1 | sed 's/^BAL_HL linecomment: *//')"
else
  report 'j) // comment rendered colored (synID)' FAIL "$(printf '%s\n' "$out" | grep '^BAL_HL linecomment:' | head -1 | sed 's/^BAL_HL linecomment: *//')"
fi
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep '^BAL_HL lcmt-text:' | grep -qE '\bComment\b'; then
  report 'j) // comment TEXT rendered colored (synID)' PASS "$(printf '%s\n' "$out" | grep '^BAL_HL lcmt-text:' | head -1 | sed 's/^BAL_HL lcmt-text: *//')"
else
  report 'j) // comment TEXT rendered colored (synID)' FAIL "$(printf '%s\n' "$out" | grep '^BAL_HL lcmt-text:' | head -1 | sed 's/^BAL_HL lcmt-text: *//')"
fi
# A "quoted" word inside the comment must ALSO stay Comment (a regression would
# let the string region start inside the comment and color it green).
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep '^BAL_HL lcmt-quote:' | grep -qE '\bComment\b'; then
  report 'j) quotes inside // comment stay Comment (synID)' PASS "$(printf '%s\n' "$out" | grep '^BAL_HL lcmt-quote:' | head -1 | sed 's/^BAL_HL lcmt-quote: *//')"
else
  report 'j) quotes inside // comment stay Comment (synID)' FAIL "$(printf '%s\n' "$out" | grep '^BAL_HL lcmt-quote:' | head -1 | sed 's/^BAL_HL lcmt-quote: *//')"
fi

# j2) project context: ballerina LSP client with semanticTokensProvider
# (semantic coloring layered on top of syntax = the VS Code model).
STCHECK="$WORK/bal_semantic_check.lua"
cat > "$STCHECK" <<'LUA'
function run_st_checks(bal_path, timeout_ms)
  local timer = vim.uv.new_timer()
  local waited = 0
  timer:start(1000, 1000, vim.schedule_wrap(function()
    waited = waited + 1000
    local bufnr = vim.fn.bufnr(bal_path)
    if bufnr == -1 then
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == bal_path then bufnr = b end
      end
    end
    local client
    for _, c in ipairs(vim.lsp.get_clients({ name = 'ballerina' })) do
      if c.initialized and c.attached_buffers[bufnr] then client = c end
    end
    if not client and waited < timeout_ms then return end
    timer:stop(); timer:close()
    if not client then
      io.write('BAL_ST_CLIENT=timeout\n')
      vim.cmd('cquit 1')
      return
    end
    io.write('BAL_ST_CLIENT=attached\n')
    io.write('BAL_ST_PROVIDER=' .. tostring(client.server_capabilities.semanticTokensProvider ~= nil) .. '\n')
    vim.cmd('qa!')
  end))
end
LUA

rm -rf "$WORK/lsp_test_ballerina"
(cd "$WORK" && bal new lsp_test_ballerina >/dev/null 2>&1)
out=$(cd "$WORK/lsp_test_ballerina" && timeout 150 \
  nvim --headless -u "$CONFIG" main.bal \
  -c "luafile $STCHECK" -c "lua run_st_checks('$WORK/lsp_test_ballerina/main.bal', 90000)" 2>&1)
rc=$?
printf '%s\n' "$out" | grep -E '^BAL_ST' | sed 's/^/      /'
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^BAL_ST_CLIENT=attached$'; then
  report 'j) project: ballerina LSP attached' PASS
else
  report 'j) project: ballerina LSP attached' FAIL "rc=$rc"
fi
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^BAL_ST_PROVIDER=true$'; then
  report 'j) project: LSP advertises semanticTokensProvider' PASS
else
  report 'j) project: LSP advertises semanticTokensProvider' FAIL "rc=$rc"
fi


echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
