-- Installed by wlperch setup; remove there (wlperch setup, "Neovim theme").
-- Makes nvim follow `wlperch theme` (dark / light): reads wlperch's saved mode
-- at startup and whenever it changes, and applies the [theme] nvim settings
-- of wlperch's config.ini for it (read anew each time, so edits need no
-- reinstall): 'background', and `colorscheme` when [theme.<mode>]
-- nvim_colorscheme is set. Without one, 'background' only flips while
-- [theme] nvim_background is true (as wlperch did in its nvim colour file).
if vim.g.loaded_wlperch_theme then return end
vim.g.loaded_wlperch_theme = true

local mode_file = [==[@MODE_FILE@]==]
local config_file = [==[@CONFIG_FILE@]==]
local dir, name = mode_file:match('^(.*)/([^/]+)$')
local uv = vim.uv or vim.loop
local watch, timer = uv.new_fs_event(), uv.new_timer()
if not dir or not watch or not timer then return end

-- A value as wlperch reads it: a "quoted" one with \ escapes, then one more
-- pair of matching quotes off. No inline comments: `a ; b` is all value.
local function unquote(v)
  if #v >= 2 and v:sub(1, 1) == '"' and v:sub(-1) == '"' then
    local esc = { n = '\n', t = '\t', r = '\r' }
    v = v:sub(2, -2):gsub('\\(.)', function(c) return esc[c] or c end)
  end
  v = vim.trim(v)
  local q = v:sub(1, 1)
  if #v >= 2 and (q == '"' or q == "'") and v:sub(-1) == q then v = v:sub(2, -2) end
  return v
end

-- config.ini: [section] headers, `key = value` lines (the last one wins),
-- ; and # comment lines. The " =" rule lets keys contain '='.
local function read_config()
  local out = {}
  local f = io.open(config_file, 'r')
  if not f then return out end
  local section = ''
  for raw in f:lines() do
    local line = vim.trim(raw)
    local c = line:sub(1, 1)
    if c == '[' then
      local e = line:find(']', 1, true)
      section = line:sub(2, (e or #line + 1) - 1)
    elseif line ~= '' and c ~= ';' and c ~= '#' then
      local eq = line:find(' =', 1, true)
      local q = line:find('"', 1, true)
      if not eq or (q and q > 1 and q < eq) then eq = line:find('=', 1, true) else eq = eq + 1 end
      if eq then
        out[section] = out[section] or {}
        out[section][vim.trim(line:sub(1, eq - 1))] = unquote(vim.trim(line:sub(eq + 1)))
      end
    end
  end
  f:close()
  return out
end

local function truthy(v)
  v = v:lower()
  if v == 'false' or v == 'no' or v == '0' or v == 'off' then return false end
  return true -- true / yes / 1 / on, and the default for anything else
end

local warned = {}
local function apply(quiet)
  local f = io.open(mode_file, 'r')
  if not f then return end -- no mode saved yet: the watch sees it appear
  local text = vim.trim(f:read('*a') or '')
  f:close()
  if text == '' then return end -- half written; the next event follows
  local mode = text == 'light' and 'light' or 'dark'
  local cfg = read_config()
  local function get(section, key, default)
    local s = cfg[section]
    if s and s[key] ~= nil then return s[key] end
    return default
  end
  local scheme = get('theme.' .. mode, 'nvim_colorscheme', '')
  if scheme ~= '' or truthy(get('theme', 'nvim_background', 'true')) then
    if vim.o.background ~= mode then vim.o.background = mode end
  end
  if scheme == '' then return end
  local ok, err = pcall(vim.cmd.colorscheme, scheme)
  if not ok and not quiet and not warned[scheme] then
    warned[scheme] = true
    vim.notify('wlperch theme: ' .. tostring(err), vim.log.levels.WARN)
  end
end

-- The directory, not the file: that sees the mode written in place, renamed
-- over, or created for the first time. Armed anew after every change, so a
-- recreated directory is followed too.
local on_event
local function arm()
  watch:stop()
  return watch:start(dir, {}, on_event) == 0
end

-- After a change settles (50 ms), or every 2 s while the directory is missing.
local function later(ms)
  timer:stop()
  timer:start(ms, 0, function()
    if arm() then
      vim.schedule(function() apply(false) end)
    else
      later(2000)
    end
  end)
end
on_event = function(err, fname)
  if err or fname == nil or fname == name then later(50) end
end

-- At VimEnter, after init.lua and everything it loads: lazy.nvim sources
-- this file from within lazy.setup(), and a config may still set its own
-- colorscheme (or source an old colour file) after that.
if vim.v.vim_did_enter == 1 then
  apply(true)
else
  vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function() apply(true) end })
end
if not arm() then later(2000) end
