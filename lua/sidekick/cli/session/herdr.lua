local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_session? string herdr session name (discovered source name or sanitized sid; never stored in `mux_session`)
---@field herdr_current? boolean target the current (session-less) server
---@field herdr_pane_id? string
---@field herdr_terminal_id? string
---@field herdr_workspace_id? string
---@field herdr_tab_id? string
local M = {}
M.__index = M
M.priority = 50
M.external = false

---Maximum length of a sanitized herdr session name.
local MAX_SESSION_NAME = 64

---Warn-once bookkeeping, keyed by `sid` and concern (D6/D5/D12).
---Module-level so it survives session instances: P3 discovery creates a fresh
---instance per session, and per-instance flags would re-arm the warning for the
---same session on every discovery pass (F4).
---@type table<string, table<string, boolean>>
M._warned = {}

---Record and report the first time `key` is seen for `sid`.
---@param sid string
---@param key string
---@return boolean true only the first time
local function warn_once(sid, key)
  local per = M._warned[sid]
  if not per then
    per = {}
    M._warned[sid] = per
  end
  if per[key] then
    return false
  end
  per[key] = true
  return true
end

---Resolve the herdr binary.
---Prefers `$HERDR_BIN_PATH` (the official convention when running inside herdr)
---and falls back to `herdr` on `$PATH` (D17).
---@return string
function M.bin()
  return vim.env.HERDR_BIN_PATH or "herdr"
end

---Sanitize a session id into a herdr session name.
---Only `[%w._-]` are kept, anything else becomes `-`.
---The result is truncated to a sane maximum length.
---When sanitizing/truncating actually changed the name, a short deterministic
---hash of the original is appended, so that distinct ids cannot collide (D3).
---@param name string
---@return string
function M.session_name(name)
  local sanitized = name:gsub("[^%w._-]", "-")
  local changed = sanitized ~= name
  if #sanitized > MAX_SESSION_NAME then
    sanitized = sanitized:sub(1, MAX_SESSION_NAME)
    changed = true
  end
  if changed then
    local hash = vim.fn.sha256(name):sub(1, 6)
    sanitized = sanitized:sub(1, MAX_SESSION_NAME - 7) .. "-" .. hash
  end
  return sanitized
end

---Build a herdr command.
---The global `--session <name>` is inserted before the subcommand and
---omitted when `current` is true (session selected implicitely).
---@param session string
---@param args string[]
---@param current? boolean
---@return string[]
function M.cmd(session, args, current)
  local cmd = { M.bin() }
  if not current then
    vim.list_extend(cmd, { "--session", session })
  end
  vim.list_extend(cmd, args)
  return cmd
end

---Run a herdr command and decode its JSON output.
---Tolerates empty stdout (success without payload) and the two response shapes:
---  * wrapped `{ id = ..., result = ... }` (most commands) -> returns `.result`
---  * unwrapped `{ sessions = [ ... ] }` (`session list --json`) -> returns the table
---Malformed output soft-fails with `nil`.
---A structured failure body such as `{ error = { code = ..., message = ... } }`
---is returned **as-is** (information-preserving); parsing it is left to the
---caller (D18). Errors are never silently converted to `nil`.
---@param cmd string[]
---@param opts? { notify?: boolean }
---@return table?
function M.json(cmd, opts)
  opts = opts or {}
  local lines, stdout = Util.exec(cmd, { notify = opts.notify == true })
  if not lines then
    return nil
  end
  if not stdout or stdout == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok or type(decoded) ~= "table" then
    if opts.notify then
      Util.error(("Failed to decode JSON from: `%s`"):format(table.concat(cmd, " ")))
    end
    return nil
  end
  if decoded.id ~= nil and decoded.result ~= nil then
    return decoded.result
  end
  return decoded
end

---Query the herdr server status (session-less / default session).
---Soft-fails (returns `nil`) when the server is unreachable.
---@return table?
function M.status()
  return M.json({ M.bin(), "status", "server", "--json" })
end

---Check whether a herdr server is already running for the given session.
---herdr servers are **per-session** (each session gets its own socket), so the
---probe must target `session` explicitly instead of the default server (D11/D14).
---Soft-fails (`false`) when the status query fails.
---@param session string
---@param current? boolean
---@return boolean
function M.server_running(session, current)
  local ret = M.json(M.cmd(session, { "status", "server", "--json" }, current))
  return ret ~= nil and ret.running == true
end

---Ensure a herdr server is running for the given session.
---Uses the per-session status query as a fast path, otherwise starts a detached
---server and waits (bounded) for it to come up. Soft-fails with `Util.error`.
---@param session string
---@param current? boolean
---@return boolean
function M.ensure_server(session, current)
  if M.server_running(session, current) then
    return true
  end
  local job = vim.fn.jobstart(M.cmd(session, { "server" }, current), { detach = true })
  if job <= 0 then
    Util.error(("Failed to start herdr server for session `%s`"):format(session))
    return false
  end
  local started = vim.wait(3000, function()
    return M.server_running(session, current)
  end, 50)
  if not started then
    Util.error(("Timed out waiting for herdr server for session `%s`"):format(session))
    return false
  end
  return true
end

---Maximum number of `pane run` attempts before giving up (macOS may reject
---an oversized line and a fresh pane's shell may not be ready yet; F2).
local LAUNCH_ATTEMPTS = 3
---Delay between `pane run` attempts, in milliseconds.
local LAUNCH_RETRY_DELAY = 100
---Number of `pane process-info` polls per attempt used to confirm the tool
---process actually came up after `pane run` (F2).
local PROC_POLLS = 5
---Delay between `pane process-info` polls, in milliseconds.
---Worst case per launch: 3 x (5 polls x 100ms) + 2 x 100ms retry ≈ 1.4s (≲3s).
---The R14 foreground-idle probes (one before the loop, one per attempt —
---including the first, since the guard snapshot is taken unconditionally) add
---spawns but no extra waits, so the poll budget above is unchanged.
local PROC_POLL_INTERVAL = 100

---Build a `Proc`-shaped table from a `process-info` foreground entry (D19).
---The command chain mirrors D19: `cmdline -> argv joined -> argv0 -> name`.
---@param info table `process_info` payload (carries `shell_pid`)
---@param entry table foreground process entry
---@return sidekick.cli.Proc
local function to_proc(info, entry)
  local cmd = entry.cmdline
  if (cmd == nil or cmd == "") and type(entry.argv) == "table" then
    cmd = table.concat(entry.argv, " ")
  end
  if cmd == nil or cmd == "" then
    cmd = entry.argv0 or entry.name
  end
  return {
    pid = entry.pid,
    ppid = info.shell_pid,
    cmd = cmd,
    cwd = entry.cwd,
  }
end

---Capture a pane's foreground identity for the R14 re-injection guard.
---`pane run` only injects input; `exec` replaces the shell image so the pid is
---unchanged and cannot tell the tool apart from the shell. The first foreground
---entry's `name`/`argv0`/`cmdline` does change once something starts, so it
---answers "is this pane still idle at its shell?". Returns `nil` both while the
---pane has no foreground process yet (a fresh pane's shell is not up) and on any
---soft-failed probe; `launch_pane` reads `nil` either way as "no evidence the
---tool started", so it never suppresses a re-injection on a `nil` snapshot
---(R14/F1).
---@param session string
---@param pane_id string
---@param current boolean
---@return string?
local function foreground_id(session, pane_id, current)
  local ret = M.json(M.cmd(session, { "pane", "process-info", "--pane", pane_id }, current))
  local info = type(ret) == "table" and ret.process_info or nil
  local entry = type(info) == "table" and (info.foreground_processes or {})[1] or nil
  if type(entry) ~= "table" then
    return nil
  end
  return table.concat({ entry.name or "", entry.argv0 or entry.cmdline or "" }, "\0")
end

---Match a foreground entry against the binary we injected (`tool.cmd[1]`).
---Launch-only evidence (R15): `tool:is_proc` is tuned for *discovery* — claiming a
---tool found among arbitrary processes — and is not guaranteed to match the
---command line **we ourselves injected** (`exec <tool.cmd>`). Two gaps:
---  * token mismatch, e.g. `amazon_q` has `cmd = { "q" }` but `is_proc` matches
---    `\<qchat\>`; and
---  * wrapper-launched tools (`sh -c …`, `npx …`, `node …`) whose `is_proc` token
---    never appears in the immediate `foreground_processes` entry.
---The injected binary is compared as a whole token against `name`/`argv0` (by
---basename) and each whitespace-delimited `cmdline` token, so a short binary such
---as `q` cannot false-positive on a flag (`-q`, `--quiet`). This is deliberately
---stricter than a word-boundary regex, which matches the `q` inside `-q`.
---@param entry table foreground process entry
---@param bin? string `tool.cmd[1]`, the binary we injected
---@return boolean
local function matches_injected(entry, bin)
  if type(bin) ~= "string" or bin == "" then
    return false
  end
  ---@param v any
  ---@return string?
  local function base(v)
    return type(v) == "string" and (v:match("[^/\\]+$") or v) or nil
  end
  if base(entry.name) == bin or base(entry.argv0) == bin then
    return true
  end
  if type(entry.cmdline) == "string" then
    for token in entry.cmdline:gmatch("%S+") do
      -- strip shell quotes so an `exec 'q'`-style rendering still matches
      local unquoted = token:gsub("^['\"]", ""):gsub("['\"]$", "")
      if base(unquoted) == bin then
        return true
      end
    end
  end
  return false
end

---Extract the list of panes from a `pane list` response.
---Tolerates the wrapped `{ result = { panes = ... } }` shape as well as a bare
---list. Returns an empty list when the payload is missing or unexpected.
---@param ret table?
---@return table[]
local function panes(ret)
  if type(ret) ~= "table" then
    return {}
  end
  if type(ret.panes) == "table" then
    return ret.panes
  end
  if ret[1] ~= nil then
    return ret
  end
  return {}
end

---Build the per-source `workspace_id -> label` / `tab_id -> number` lookup used
---to compose the picker `mux_label`. One session-scoped `api snapshot` call per
---source (memoized by the caller), since `pane list` carries ids only.
---Never raises: an absent/failed/unexpected payload yields empty tables, so the
---label degrades to ids instead of erroring.
---@param source sidekick.cli.session.HerdrSource
---@return { workspaces: table<string,string>, tabs: table<string,integer> }
local function snapshot_labels(source)
  ---@type { workspaces: table<string,string>, tabs: table<string,integer> }
  local lookup = { workspaces = {}, tabs = {} }
  local ret = M.json(M.cmd(source.name, { "api", "snapshot" }, source.current))
  local snapshot = type(ret) == "table" and ret.snapshot or nil
  if type(snapshot) ~= "table" then
    return lookup
  end
  -- sections are optional and must never raise: a scalar (or otherwise
  -- non-list) section degrades to "no names", not to a crash inside discovery
  local workspaces = snapshot.workspaces
  if type(workspaces) ~= "table" then
    workspaces = {}
  end
  local tabs = snapshot.tabs
  if type(tabs) ~= "table" then
    tabs = {}
  end
  for _, ws in ipairs(workspaces) do
    if type(ws) == "table" and type(ws.workspace_id) == "string" and type(ws.label) == "string" and ws.label ~= "" then
      lookup.workspaces[ws.workspace_id] = ws.label
    end
  end
  for _, tab in ipairs(tabs) do
    if type(tab) == "table" and type(tab.tab_id) == "string" and type(tab.label) == "string" then
      -- `tab.number` is a session-wide monotonic id counter (measured: 28/31/83/90),
      -- not the index herdr shows. The displayed index is the leading integer of
      -- the tab label (`"2 · sidekick.nvim › dev/herdr"` -> 2); when it cannot be
      -- parsed the label degrades to the stripped tab id instead.
      local index = tonumber(tab.label:match("^(%d+)"))
      if index then
        lookup.tabs[tab.tab_id] = index
      end
    end
  end
  return lookup
end

---Strip a leading `"<workspace_id>:"` prefix from an id.
---Falls back to stripping any `<token>:` prefix when the workspace id is unknown.
---@param id string
---@param workspace_id? string
---@return string
local function strip_workspace(id, workspace_id)
  if type(workspace_id) == "string" and workspace_id ~= "" then
    local prefix = workspace_id .. ":"
    if id:sub(1, #prefix) == prefix then
      return id:sub(#prefix + 1)
    end
  end
  return id:match("^[^:]+:(.+)$") or id
end

---Compose the picker `mux_label` (`workspace · tab · pane`) for a pane.
---Segments degrade to ids (never status words/glyphs); nil/empty segments are
---dropped, and a missing pane id yields `nil` so the UI keeps `[herdr:<session>]`.
---@param pane table a `pane list` record
---@param lookup { workspaces: table<string,string>, tabs: table<string,integer> }
---@return string?
local function compose_mux_label(pane, lookup)
  local pane_id = pane.pane_id or pane.id
  if type(pane_id) ~= "string" or pane_id == "" then
    return nil
  end
  local workspace_id = pane.workspace_id or pane_id:match("^([^:]+):")
  local segments = {} ---@type string[]

  local workspace = workspace_id and lookup.workspaces[workspace_id] or nil
  if type(workspace) ~= "string" or workspace == "" then
    workspace = workspace_id
  end
  if type(workspace) == "string" and workspace ~= "" then
    segments[#segments + 1] = workspace
  end

  local tab_id = pane.tab_id
  if type(tab_id) == "string" and tab_id ~= "" then
    local number = lookup.tabs[tab_id]
    local tab = number ~= nil and tostring(number) or strip_workspace(tab_id, workspace_id)
    if tab ~= "" then
      segments[#segments + 1] = tab
    end
  end

  local pane_segment = strip_workspace(pane_id, workspace_id)
  if pane_segment ~= "" then
    segments[#segments + 1] = pane_segment
  end

  if #segments == 0 then
    return nil
  end
  return table.concat(segments, " · ")
end

---Resolve the herdr pane backing this session.
---Runs `pane list` (session scoped via the global `--session`, since `pane list`
---only accepts `--workspace`) and matches by `terminal_id`, falling back to
---`pane_id`. The resolved ids are cached back onto `self`.
---With `refresh = true` the cache is bypassed and `pane list` is re-queried, so
---a stale cache can never make a dead session look alive. A lookup that finds no
---matching pane invalidates both cached ids (D18).
---@param refresh? boolean bypass the cache and re-query `pane list`
---@return table?
function M:pane(refresh)
  if not refresh and self.herdr_pane_id and self.herdr_terminal_id then
    return { pane_id = self.herdr_pane_id, terminal_id = self.herdr_terminal_id }
  end
  if not self.external and not self.herdr_session then
    return nil
  end
  local ret = M.json(M.cmd(self.herdr_session, { "pane", "list" }, self.herdr_current == true))
  local match ---@type table?
  for _, pane in ipairs(panes(ret)) do
    local pane_id = pane.pane_id or pane.id
    if self.herdr_terminal_id and pane.terminal_id == self.herdr_terminal_id then
      match = pane
      break
    end
    if self.herdr_pane_id and pane_id == self.herdr_pane_id then
      match = match or pane
    end
  end
  if match then
    self.herdr_pane_id = match.pane_id or match.id
    self.herdr_terminal_id = match.terminal_id
    -- The matched pane carries the location that a create/split payload may have
    -- omitted (the same guarded capture as `launch_pane`); remember it here so a
    -- later lookup can still recover the tab and reveal it (F3).
    if match.workspace_id then
      self.herdr_workspace_id = self.herdr_workspace_id or match.workspace_id
    end
    if match.tab_id then
      self.herdr_tab_id = self.herdr_tab_id or match.tab_id
    end
    return match
  end
  -- D18: a failed lookup invalidates the cached identity so `is_running()`
  -- can transition to false instead of reporting a stale pane forever.
  self.herdr_pane_id = nil
  self.herdr_terminal_id = nil
  return nil
end

---Resolve the herdr pane id backing this session.
---@return string?
function M:pane_id()
  if self.herdr_pane_id then
    return self.herdr_pane_id
  end
  local pane = self:pane()
  return pane and (pane.pane_id or pane.id) or nil
end

---Reveal the pane backing this session (D9, revised).
---herdr exposes **no absolute pane focus**: `pane focus` is directional-only
---(`--direction left|right|up|down`) and moves to a *neighbor*. The only
---absolute primitives are `workspace focus <id>` and `tab focus <id>`, so
---sidekick brings the pane's workspace and then its tab forward. The pane
---becomes visible, but intra-tab split focus is not set.
---Best effort: returns `self` without running any focus command when no location
---can be resolved (a cold cache may still run one `pane list` lookup).
---@return sidekick.cli.Session
function M:focus()
  local pane = self:pane()
  local pane_id = self.herdr_pane_id or (pane and (pane.pane_id or pane.id))
  local ws = self.herdr_workspace_id or (pane and pane.workspace_id) or (pane_id and pane_id:match("^([^:]+):"))
  -- best effort: nothing to reveal when neither a pane nor a workspace resolved
  if not pane and not ws then
    return self
  end
  local session, current = self.herdr_session, self.herdr_current == true
  if ws then
    Util.exec(M.cmd(session, { "workspace", "focus", ws }, current), { notify = true })
  end
  local tab = self.herdr_tab_id or (pane and pane.tab_id)
  if tab then
    Util.exec(M.cmd(session, { "tab", "focus", tab }, current), { notify = true })
  end
  return self
end

---Warn once per session when an embedded terminal would nest inside herdr (D6).
---Never rewrites the user's configuration.
function M:nested_warn()
  if vim.env.HERDR_ENV == "1" and Config.cli.mux.create == "terminal" then
    if warn_once(self.sid, "nested") then
      Util.warn({
        "herdr: starting an embedded terminal from inside herdr creates a nested session.",
        'Consider setting `opts.cli.mux.create` to `"split"` or `"window"`.',
      })
    end
  end
end

---Append `--env K=V` for every entry in `tool.env` (D5).
---herdr cannot unset variables, so `false` values are skipped and a single
---warning per session is emitted to make the ignored unset explicit.
---@param cmd string[]
function M:add_env(cmd)
  for key, value in pairs(self.tool.env or {}) do
    if value == false then
      if warn_once(self.sid, "env") then
        Util.warn(
          ("herdr cannot unset environment variables; ignoring `%s=false` for **%s**"):format(key, self.tool.name)
        )
      end
    else
      vim.list_extend(cmd, { "--env", ("%s=%s"):format(key, tostring(value)) })
    end
  end
end

---Check whether the tool process actually runs inside the given pane (F2).
---`pane run` maps to input injection (no spawn), so a swallowed line leaves a
---live idle pane that looks started. Polling `pane process-info` and matching
---each foreground process with `tool:is_proc` is the primary signal.
---R15: a launch is also confirmed when the foreground entry matches the binary we
---injected (`tool.cmd[1]`), so a working tool is not killed on an `is_proc`
---false negative. This OR lives only here: discovery (`M.sessions()`) keeps
---matching via `tool:is_proc` alone.
---@param pane_id string
---@return boolean
function M:proc_running(pane_id)
  local ret =
    M.json(M.cmd(self.herdr_session, { "pane", "process-info", "--pane", pane_id }, self.herdr_current == true))
  local info = type(ret) == "table" and ret.process_info or nil
  if type(info) ~= "table" then
    return false
  end
  local bin = self.tool.cmd and self.tool.cmd[1]
  for _, entry in ipairs(info.foreground_processes or {}) do
    if self.tool:is_proc(to_proc(info, entry)) or matches_injected(entry, bin) then
      return true
    end
  end
  return false
end

---Poll `pane process-info` a bounded number of times, waiting for the tool
---process to appear (F2). Returns as soon as it is observed.
---@param pane_id string
---@return boolean
function M:wait_proc(pane_id)
  for poll = 1, PROC_POLLS do
    if self:proc_running(pane_id) then
      return true
    end
    if poll < PROC_POLLS then
      vim.wait(PROC_POLL_INTERVAL)
    end
  end
  return false
end

---Start the tool inside an existing (or freshly created) pane (D4).
---Uses `pane run <pane> "exec <cmd>"`, retrying a bounded number of times
---because a fresh pane's shell may not be ready yet and macOS can reject an
---oversized line (D11). Because `pane run` only injects input, each attempt is
---confirmed via `pane process-info` before it counts as success (F2); on final
---failure the pane is closed, the cached identity is cleared and an error is
---reported.
---R14: the retry re-injects unless a concrete change of foreground identity is
---observed. A `wait_proc` false negative (transient `process-info` failure, or
---`is_proc` not matching the tool) must not type a stray duplicate line into a
---live TUI, so once both the pre-injection baseline and the current foreground
---are concrete and differ, the remaining budget is spent polling instead of
---re-running `pane run`. A `nil` snapshot (the pane has no foreground process
---yet, or the probe soft-failed) proves nothing started, so re-injection is
---still allowed (R14/F1).
---@param pane table pane with `pane_id` (or `id`) and `terminal_id`
---@return boolean
function M:launch_pane(pane)
  local pane_id = pane.pane_id or pane.id
  if not pane_id then
    return false
  end
  local session, current = self.herdr_session, self.herdr_current == true
  local tool_cmd = table.concat(
    vim.tbl_map(function(a)
      return vim.fn.shellescape(a)
    end, self.tool.cmd),
    " "
  )
  local cmd = M.cmd(session, { "pane", "run", pane_id, "exec " .. tool_cmd }, current)
  -- R14 baseline: what the pane's foreground looks like before any injection
  local baseline = foreground_id(session, pane_id, current)
  for attempt = 1, LAUNCH_ATTEMPTS do
    -- attempt 1 always injects; later attempts re-inject unless a concrete
    -- change of foreground identity was observed since the baseline (R14/F1)
    local cur = foreground_id(session, pane_id, current)
    -- Discriminate only when both snapshots are concrete: `nil` means "no
    -- foreground process yet" or a soft-failed probe, neither of which proves
    -- the tool started, so the legacy re-inject is kept in that case (R14/F1).
    local idle = attempt == 1 or cur == nil or baseline == nil or cur == baseline
    if (not idle or Util.exec(cmd, { notify = false })) and self:wait_proc(pane_id) then
      self.herdr_pane_id = pane_id
      self.herdr_terminal_id = pane.terminal_id
      -- location is optional on create/split responses (D9 reveal); only
      -- overwrite when the payload actually carries it
      if pane.workspace_id then
        self.herdr_workspace_id = pane.workspace_id
      end
      if pane.tab_id then
        self.herdr_tab_id = pane.tab_id
      end
      self.started = true
      return true
    end
    if attempt < LAUNCH_ATTEMPTS then
      vim.wait(LAUNCH_RETRY_DELAY)
    end
  end
  self.started = nil
  self.herdr_pane_id = nil
  self.herdr_terminal_id = nil
  Util.exec(M.cmd(session, { "pane", "close", pane_id }, current), { notify = false })
  Util.error(("Failed to start **%s** in herdr pane `%s`"):format(self.tool.name, pane_id))
  return false
end

---Initialize the session backend.
---Mirrors the tmux semantics (D14). Discovered states already carry their
---source identity (`herdr_session` / `herdr_current` / `mux_session`), so they
---are never clobbered here; the sanitized `session_name(sid)` is only the
---fallback for sessions created by Neovim. The sanitized name is *never*
---written to `self.mux_session`, otherwise every embedded session would be
---treated as external.
function M:init()
  if self.started then
    self.external = self.sid ~= self.mux_session
  else
    self.external = vim.env.HERDR_ENV == "1" and Config.cli.mux.create ~= "terminal"
    self.mux_session = self.sid
  end
  self.herdr_session = self.herdr_session or M.session_name(self.sid)
  if self.herdr_current == nil then
    self.herdr_current = self.external == true
  end
  self.priority = self.external and 10 or 50
  self:nested_warn()
end

---@class sidekick.cli.session.HerdrSource
---@field name? string herdr session name (`nil` for the implicit current session)
---@field current boolean query the current (session-less) server

---List the session sources to scan for running tools (D8/D16).
---Includes the current (session-less) server when running inside herdr, plus
---every running named session from `session list`. Sources are deduplicated by
---name so the current session cannot be scanned twice when it is also reported
---by `session list` (D16).
---@return sidekick.cli.session.HerdrSource[]
function M.sources()
  local ret = {} ---@type sidekick.cli.session.HerdrSource[]
  local seen = {} ---@type table<string, boolean>

  local named = {} ---@type table[]
  local list = M.json({ M.bin(), "session", "list", "--json" })
  if type(list) == "table" and type(list.sessions) == "table" then
    named = list.sessions
  end

  ---@param name? string
  ---@param current boolean
  local function add(name, current)
    local key = name or "\0current"
    if seen[key] then
      return
    end
    seen[key] = true
    ret[#ret + 1] = { name = name, current = current }
  end

  if vim.env.HERDR_ENV == "1" or vim.env.HERDR_SOCKET_PATH then
    -- Resolve the current session's name so the matching entry from
    -- `session list` is deduplicated (D16).
    local name
    for _, s in ipairs(named) do
      if vim.env.HERDR_SOCKET_PATH and s.socket_path == vim.env.HERDR_SOCKET_PATH then
        name = s.name
        break
      end
    end
    if not name then
      for _, s in ipairs(named) do
        if s.default then
          name = s.name
          break
        end
      end
    end
    add(name, true)
  end

  for _, s in ipairs(named) do
    if s.running and s.name then
      add(s.name, false)
    end
  end

  return ret
end

---List all active sessions for this backend (discovery: D8/D16).
---For every source, lists its panes and inspects each pane's foreground
---processes, matching them against the configured tools. Emits one state per
---matching pane, deduplicated by `terminal_id` (a duplicate id would hit the
---`assert` in `session/init.lua`). `pane list` / `process-info` are memoized
---within a single call, so discovery costs O(sources + panes) spawns.
---Any failed query soft-fails and is counted; a single bounded warning makes
---discovery failures visible instead of silently returning nothing (D18).
---@return sidekick.cli.session.State[]
function M.sessions()
  local Session = require("sidekick.cli.session")
  local Terminal = require("sidekick.cli.terminal")
  local tools = Config.tools()

  ---Collect the pids of the embedded terminal that owns a discovered pane (D15).
  ---Matches by `sid` first, then by `terminal_id`, so a tool that changed its
  ---working directory since launch still merges into the same session.
  ---@param sid string
  ---@param terminal_id? string
  ---@return integer[]
  local function find_pids(sid, terminal_id)
    local pids = {} ---@type integer[]
    for _, t in pairs(Terminal.terminals) do
      if t.mux_backend == "herdr" then
        local parent_id = t.parent and t.parent.herdr_terminal_id
        if t.mux_session == sid or (terminal_id ~= nil and parent_id == terminal_id) then
          vim.list_extend(pids, t.pids or {})
        end
      end
    end
    return pids
  end

  local ret = {} ---@type sidekick.cli.session.State[]
  local by_id = {} ---@type table<string, sidekick.cli.session.State>
  -- memoized per call so discovery is O(sources + panes), not O(sources * panes)
  local pane_cache = {} ---@type table<string, table[]>
  local proc_cache = {} ---@type table<string, table|false>
  -- at most one `api snapshot` lookup per source, reused by all its panes
  local label_cache = {} ---@type table<string, { workspaces: table<string,string>, tabs: table<string,integer> }>
  local failed = 0

  for _, source in ipairs(M.sources()) do
    local skey = source.name or "\0current"
    local lookup = label_cache[skey]
    if not lookup then
      lookup = snapshot_labels(source)
      label_cache[skey] = lookup
    end
    local pane_list = pane_cache[skey]
    if not pane_list then
      local list = M.json(M.cmd(source.name, { "pane", "list" }, source.current))
      if list == nil or list.error then
        failed = failed + 1
      end
      pane_list = panes(list)
      pane_cache[skey] = pane_list
    end
    for _, pane in ipairs(pane_list) do
      local pane_id = pane.pane_id or pane.id
      if pane_id then
        local pkey = skey .. "\0" .. pane_id
        local info = proc_cache[pkey]
        if info == nil then
          local response = M.json(M.cmd(source.name, { "pane", "process-info", "--pane", pane_id }, source.current))
          if response == nil or response.error then
            failed = failed + 1
          end
          info = (type(response) == "table" and response.process_info) or false
          proc_cache[pkey] = info
        end
        if info then
          local matched, proc_pid ---@type sidekick.cli.Tool?, integer?
          for _, entry in ipairs(info.foreground_processes or {}) do
            local proc = to_proc(info, entry)
            for _, tool in pairs(tools) do
              if tool:is_proc(proc) then
                matched, proc_pid = tool, proc.pid
                break
              end
            end
            if matched then
              break
            end
          end
          if matched then
            local cwd = pane.foreground_cwd or pane.cwd
            local sid = Session.sid({ tool = matched.name, cwd = cwd })
            -- include the source in the fallback so ids cannot collide across
            -- sources when a pane exposes no `terminal_id`
            local id = ("herdr %s"):format(pane.terminal_id or (skey .. ":" .. pane_id))
            local state = by_id[id]
            if not state then
              state = {
                id = id,
                sid = sid,
                tool = matched.name,
                cwd = cwd,
                herdr_pane_id = pane_id,
                herdr_terminal_id = pane.terminal_id,
                herdr_workspace_id = pane.workspace_id,
                herdr_tab_id = pane.tab_id,
                herdr_session = source.name,
                herdr_current = source.current,
                mux_session = source.name,
                mux_label = compose_mux_label(pane, lookup),
                pids = {},
              }
              by_id[id] = state
              ret[#ret + 1] = state
            end
            local pids = state.pids ---@type integer[]
            local function push(pid)
              if pid ~= nil and not vim.tbl_contains(pids, pid) then
                pids[#pids + 1] = pid
              end
            end
            push(info.shell_pid)
            push(proc_pid)
            for _, pid in ipairs(find_pids(sid, pane.terminal_id)) do
              push(pid)
            end
          end
        end
      end
    end
  end

  if failed > 0 and warn_once("discovery", "failed") then
    Util.warn(("herdr: failed to query %d discovery target(s); is the herdr server running?"):format(failed))
  end

  return ret
end

---Start a new session (creation: P2).
---@return sidekick.cli.terminal.Cmd?
function M:start()
  self:nested_warn()
  local current = self.herdr_current == true
  if not self.external then
    if not M.ensure_server(self.herdr_session, current) then
      return nil
    end
    local cmd = M.cmd(self.herdr_session, {
      "workspace",
      "create",
      "--cwd",
      self.cwd,
      "--label",
      self.sid,
      "--no-focus",
    }, current)
    self:add_env(cmd)
    local ret = M.json(cmd, { notify = true })
    local pane = ret and ret.root_pane
    if not pane or not self:launch_pane(pane) then
      -- R16: this workspace was created by us for the embedded terminal, so it
      -- must not outlive a failed launch. Best-effort, silent close (the failure
      -- is already reported by `Util.error`); skipped defensively when the create
      -- payload carried no workspace id. The `window`/`split` branches below never
      -- do this: they open into the user's *existing* workspace, which must be
      -- left alone.
      local ws = ret and ret.workspace and ret.workspace.workspace_id
      if ws then
        Util.exec(M.cmd(self.herdr_session, { "workspace", "close", ws }, current), { notify = false })
      end
      return nil
    end
    return {
      cmd = { M.bin(), "--session", self.herdr_session, "terminal", "attach", self.herdr_terminal_id },
    }
  elseif Config.cli.mux.create == "window" then
    local args = { "tab", "create" }
    if vim.env.HERDR_WORKSPACE_ID then
      vim.list_extend(args, { "--workspace", vim.env.HERDR_WORKSPACE_ID })
    end
    vim.list_extend(args, { "--cwd", self.cwd, "--label", self.sid, "--no-focus" })
    self:add_env(args)
    local ret = M.json(M.cmd(self.herdr_session, args, current), { notify = true })
    local pane = ret and ret.root_pane
    if not pane or not self:launch_pane(pane) then
      return nil
    end
    Util.info(("Started **%s** in a new herdr window"):format(self.tool.name))
  elseif Config.cli.mux.create == "split" then
    local args = {
      "pane",
      "split",
      "--current",
      "--direction",
      Config.cli.mux.split.vertical and "right" or "down",
      "--cwd",
      self.cwd,
      "--no-focus",
    }
    local size = Config.cli.mux.split.size
    if size then
      vim.list_extend(args, { "--ratio", tostring(1 - size) })
    end
    self:add_env(args)
    local ret = M.json(M.cmd(self.herdr_session, args, current), { notify = true })
    local pane = ret and ret.pane
    if not pane or not self:launch_pane(pane) then
      return nil
    end
    Util.info(("Started **%s** in a new herdr split"):format(self.tool.name))
  end
end

---Attach to an existing session.
---Embedded sessions attach to their pane via `terminal attach` (Linux/macOS
---only). External sessions run in a herdr-managed pane and are not attached
---from Neovim (D12).
---@return sidekick.cli.terminal.Cmd?
function M:attach()
  if self.external then
    return nil
  end
  if vim.fn.has("win32") == 1 then
    if warn_once(self.sid, "win") then
      Util.warn("herdr `terminal attach` is only supported on Linux/macOS; not attaching on Windows.")
    end
    return nil
  end
  local terminal_id = self.herdr_terminal_id
  if not terminal_id then
    local pane = self:pane()
    terminal_id = pane and pane.terminal_id
  end
  if not terminal_id then
    return nil
  end
  return { cmd = { M.bin(), "--session", self.herdr_session, "terminal", "attach", terminal_id } }
end

---Send text to the session's pane (`pane send-text`).
---Mirrors tmux's `mux_focus` handling: some TUIs ignore input while unfocused,
---so a focus-in escape is sent first and the actual text follows after a short
---delay.
---@param text string
function M:send(text)
  local pane_id = self:pane_id()
  if not pane_id then
    return
  end
  local session, current = self.herdr_session, self.herdr_current == true
  local function send()
    Util.exec(M.cmd(session, { "pane", "send-text", pane_id, text }, current), { notify = true })
  end
  if self.tool.mux_focus then
    Util.exec(M.cmd(session, { "pane", "send-keys", pane_id, "Escape", "[", "I" }, current), { notify = true })
    vim.defer_fn(send, 50)
  else
    send()
  end
end

---Submit the current input to the session's pane (`pane send-keys <pane> Enter`).
function M:submit()
  local pane_id = self:pane_id()
  if not pane_id then
    return
  end
  local session, current = self.herdr_session, self.herdr_current == true
  Util.exec(M.cmd(session, { "pane", "send-keys", pane_id, "Enter" }, current), { notify = true })
end

---Dump the session scrollback.
---Returns the raw stdout of `pane read --ansi` (D10), never parsed JSON.
---@return string?
function M:dump()
  local pane_id = self:pane_id()
  if not pane_id then
    return
  end
  local session, current = self.herdr_session, self.herdr_current == true
  local args = {
    "pane",
    "read",
    pane_id,
    "--source",
    "recent-unwrapped",
    "--lines",
    tostring(Config.cli.mux.dump),
    "--ansi",
  }
  local _, stdout = Util.exec(M.cmd(session, args, current), { notify = true })
  return stdout
end

---Check if the session is still running.
---Refreshes the pane lookup (bypassing the cache) so a dead session reports
---`false` and the cached identity is invalidated (D18).
---@return boolean
function M:is_running()
  return self:pane(true) ~= nil
end

return M
