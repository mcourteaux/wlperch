-- Installed by wlperch setup; remove there (wlperch setup, "Neovim theme").
-- Makes nvim follow `wlperch theme` (dark / light): sources the colour file
-- wlperch writes at startup and again whenever it changes. Sourcing it twice
-- (your own config may source it too) is harmless.
if vim.g.loaded_wlperch_theme then return end
vim.g.loaded_wlperch_theme = true

local path = [==[@NVIM_FILE@]==]
local uv = vim.uv or vim.loop
local watch, timer = uv.new_fs_event(), uv.new_timer()
if not watch or not timer then return end

local function apply(quiet)
  if vim.fn.filereadable(path) == 0 then return end
  local ok, err = pcall(vim.cmd.source, path)
  if not ok and not quiet then
    vim.notify("wlperch theme: " .. tostring(err), vim.log.levels.WARN)
  end
end

-- Watch the path anew: an inotify watch follows the inode, so after the file
-- was replaced (renamed over) or deleted and recreated the old one is dead.
local function arm(on_event)
  watch:stop()
  return watch:start(path, {}, on_event) == 0
end

local on_event
-- After a change settles (50 ms), or every second while the file is missing.
local function later(ms)
  timer:stop()
  timer:start(ms, 0, function()
    if arm(on_event) then
      vim.schedule(function() apply(false) end)
    else
      later(1000)
    end
  end)
end
on_event = function() later(50) end

apply(true)
if not arm(on_event) then later(1000) end
