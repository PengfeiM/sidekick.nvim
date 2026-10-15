local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_session? string sanitized herdr session name (never stored in `mux_session`)
---@field herdr_pane_id? string
---@field herdr_terminal_id? string
local M = {}
M.__index = M
M.priority = 50
M.external = false

---Maximum length of a sanitized herdr session name.
local MAX_SESSION_NAME = 64

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

---Initialize the session backend.
---Mirrors the tmux semantics (D14). The sanitized name is stored in
---`self.herdr_session` and is *never* written to `self.mux_session`,
---otherwise every embedded session would be treated as external.
function M:init()
  if self.started then
    self.external = self.sid ~= self.mux_session
  else
    self.external = vim.env.HERDR_ENV == "1" and Config.cli.mux.create ~= "terminal"
    self.mux_session = self.sid
  end
  self.herdr_session = M.session_name(self.sid)
  self.priority = self.external and 10 or 50
end

---List all active sessions for this backend (discovery: P3).
---@return sidekick.cli.session.State[]
function M.sessions()
  return {}
end

---Start a new session (creation: P2).
---@return sidekick.cli.terminal.Cmd?
function M:start() end

---Attach to an existing session (attach: P2).
---@return sidekick.cli.terminal.Cmd?
function M:attach() end

---Send text to the session (P2).
---@param text string
function M:send(text) end

---Submit the current input to the session (P2).
function M:submit() end

---Dump the session scrollback (P2).
---@return string?
function M:dump() end

---Check if the session is still running.
---Discovery is not implemented yet, so this honestly reports `false`.
---@return boolean
function M:is_running()
  return false
end

return M
