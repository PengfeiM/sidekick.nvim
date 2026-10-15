local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.Select: sidekick.cli.With
---@field cb fun(state?:sidekick.cli.State)
---@field auto? boolean Automatically select if only one tool matches the filter

local M = {}

---Cut `str` down to at most `max` display columns, keeping its prefix and
---appending `…`. Wide (CJK) characters are never split in half.
---@param str string
---@param max integer
---@return string
local function truncate_head(str, max)
  if max <= 0 then
    return ""
  end
  local sw = vim.api.nvim_strwidth
  if sw(str) <= max then
    return str
  end
  max = max - 1 -- reserve one column for the ellipsis
  local chars, len = {}, 0
  for _, ch in ipairs(Util.split_chars(str)) do
    local w = sw(ch)
    if len + w > max then
      break
    end
    chars[#chars + 1] = ch
    len = len + w
  end
  return table.concat(chars) .. "…"
end

---Separator between the segments of a mux display label: `<ws> · <tab> · <pane>`.
local SEP = " · "

---Truncate a mux display label to at most `max` display columns, appending `…`
---when it is cut; labels that already fit are returned untouched.
---
---The trailing segments carry the discriminator (the pane id), so a label that is
---too long is shortened at its leading workspace segment while the ` · `
---separators and the remaining segments stay intact:
---`Alpha Site · 12 · p77` -> `Alpha Si… · 12 · p77`. Should the tail alone
---overflow the budget, the next segment boundary is used instead, so the pane id
---survives as long as it fits in `max - 4` columns. Only a label without a usable
---boundary is cut from the end. Wide (CJK) characters are never split in half.
---@param str string
---@param max integer
---@return string
local function truncate(str, max)
  if max <= 0 then
    return ""
  end
  local sw = vim.api.nvim_strwidth
  if sw(str) <= max then
    return str
  end
  -- keep the longest trailing suffix that leaves room for a leading `…`
  local from = 0
  while true do
    local i = str:find(SEP, from + 1, true)
    if not i then
      break
    end
    local head, tail = str:sub(1, i - 1), str:sub(i + #SEP)
    local head_max = max - sw(SEP) - sw(tail)
    if head_max >= 1 then
      return truncate_head(head, head_max) .. SEP .. tail
    end
    from = i
  end
  return truncate_head(str, max)
end

---@param opts sidekick.cli.Select
function M.select(opts)
  assert(type(opts) == "table", "opts must be a table")
  local tools = require("sidekick.cli.state").get(opts.filter)

  ---@param state? sidekick.cli.State
  local on_select = function(state)
    if state and not state.installed then
      M.on_missing(state.tool)
      state = nil
    end
    opts.cb(state)
  end

  if #tools == 0 then
    Util.warn("No tools match the given filter")
    return
  elseif #tools == 1 and opts.auto then
    on_select(tools[1])
    return
  end

  ---@type snacks.picker.ui_select.Opts
  local select_opts = {
    prompt = "Select CLI tool:",
    kind = "sidekick_cli",
    ---@param tool sidekick.cli.State
    format_item = function(tool)
      local parts = M.format(tool)
      return table.concat(vim.tbl_map(function(p)
        return p[1]
      end, parts))
    end,
    snacks = { format = M.format },
  }

  vim.ui.select(tools, select_opts, on_select)
end

---@param tool sidekick.cli.Tool
function M.on_missing(tool)
  Util.error(("Tool `%s` is not installed"):format(tool.name))
  if tool.url then
    local ok, err = vim.ui.open(tool.url)
    if ok then
      Util.info(("Opening %s in your browser..."):format(tool.url))
    else
      Util.error(("Failed to open %s: %s"):format(tool.url, err))
    end
  end
end

---@param state sidekick.cli.State|snacks.picker.Item
---@param picker? snacks.Picker
function M.format(state, picker)
  local sw = vim.api.nvim_strwidth
  local ret = {} ---@type snacks.picker.Highlight[]

  local status = state.attached and "attached"
    or state.started and "started"
    or state.installed and "installed"
    or "missing"

  local status_hl = "SidekickCli" .. status:gsub("^%l", string.upper)

  if picker then
    local count = picker:count()
    local idx = tostring(state.idx)
    idx = (" "):rep(#tostring(count) - #idx) .. idx
    ret[#ret + 1] = { idx .. ".", "SnacksPickerIdx" }
    ret[#ret + 1] = { " " }
  end
  ret[#ret + 1] = { Config.ui.icons[status], status_hl }
  ret[#ret + 1] = { " " }
  ret[#ret + 1] = { state.tool.name }
  local len = sw(state.tool.name) + 2
  if state.session then
    ret[#ret + 1] = { string.rep(" ", 12 - len) }

    if state.external then
      ret[#ret + 1] = { Config.ui.icons["external_" .. status], status_hl }
    else
      ret[#ret + 1] = { Config.ui.icons["terminal_" .. status], status_hl }
    end
    len = len + 2

    -- Keep this for debugging purposes
    -- ret[#ret + 1] = { table.concat(state.session.pids or {}, ",") }

    -- mux token: `[<backend>:<session>]`. Backends that expose a display label
    -- (herdr panes) show the label in place of the session name, truncated so the
    -- right-aligned cwd column below stays put. Sessions without the label render
    -- exactly as before.
    local base = state.session.mux_backend or state.session.backend
    local backend
    local label = state.external and state.session.mux_label or nil
    if type(label) == "string" and label ~= "" then
      -- 40 (cwd column) - 12 (fixed tool/icon prefix, see above) - 1 (closing `]`)
      -- minus the `[<base>:` prefix; a token of exactly 28 columns still lands the
      -- cwd on the same column as every other row (padding becomes 0)
      local budget = 28 - sw(("[" .. base .. ":")) - 1
      backend = ("[%s:%s]"):format(base, truncate(label, budget))
    else
      local backends = {} ---@type string[]
      backends[#backends + 1] = base
      if state.external then
        backends[#backends + 1] = state.session.mux_session
      end
      backend = ("[%s]"):format(table.concat(backends, ":"))
    end

    ret[#ret + 1] = { backend, "Special" }
    len = 12 + sw(backend)
    ret[#ret + 1] = { string.rep(" ", 40 - len) }
    if picker then
      local item = setmetatable({}, state) --[[@as snacks.picker.Item]]
      item.file = state.session.cwd
      item.dir = true
      vim.list_extend(ret, require("snacks").picker.format.filename(item, picker))
    else
      ret[#ret + 1] = { vim.fn.fnamemodify(state.session.cwd, ":p:~"), "Directory" }
    end
  end
  return ret
end

return M
