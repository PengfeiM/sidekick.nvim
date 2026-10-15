---@module 'luassert'

local Config = require("sidekick.config")
local Herdr = require("sidekick.cli.session.herdr")
local Util = require("sidekick.util")

---Create a bare herdr session instance, bypassing `session/init.lua`
---@param state table
---@return sidekick.cli.Session
local function new_session(state)
  return setmetatable(state, Herdr) --[[@as sidekick.cli.Session]]
end

---Stub `Util.exec` so it returns the given stdout (offline).
---@param stdout string
local function stub_exec(stdout)
  Util.exec = function()
    return { stdout }, stdout
  end
end

---Stub `Util.exec`, returning the given stdout and capturing the command it saw.
---@param stdout string
---@param sink table
local function stub_exec_capture(stdout, sink)
  Util.exec = function(cmd)
    sink.cmd = cmd
    return { stdout }, stdout
  end
end

---`pane process-info` payload reporting the fake tool as a foreground process (F2).
local TOOL_PROC = '{"id":"1","result":{"process_info":{"shell_pid":100,'
  .. '"foreground_processes":[{"pid":101,"cmdline":"tool arg","cwd":"/tmp/cwd"}]}}}'
---`pane process-info` payload with no foreground process yet (F2).
local NO_PROC = '{"id":"1","result":{"process_info":{"shell_pid":100,"foreground_processes":[]}}}'
---`pane process-info` payload whose foreground no longer matches the idle shell
---but does not match the fake tool either: a `proc_running` false negative after
---the tool already started (R14).
local OTHER_PROC = '{"id":"1","result":{"process_info":{"shell_pid":100,'
  .. '"foreground_processes":[{"pid":101,"cmdline":"zsh -l","cwd":"/tmp/cwd"}]}}}'
---`pane process-info` payload for a fresh pane idling at its shell: a concrete
---foreground identity (shell `name`/`argv0`) forming the R14 pre-injection
---baseline. Its identity differs from `OTHER_PROC`, which stands in for a
---*changed* foreground that `is_proc` fails to match.
local SHELL_PROC = '{"id":"1","result":{"process_info":{"shell_pid":100,'
  .. '"foreground_processes":[{"pid":100,"name":"zsh","argv0":"zsh","cmdline":"zsh -l","cwd":"/tmp/cwd"}]}}}'
---`pane process-info` payload for the R15 false negative: the injected binary `q`
---is a foreground token, but the discovery token `qchat` (mirroring `amazon_q`) is
---absent, so `is_proc` alone would miss the running tool.
local Q_PROC = '{"id":"1","result":{"process_info":{"shell_pid":100,'
  .. '"foreground_processes":[{"pid":101,"cmdline":"q --version","cwd":"/tmp/cwd"}]}}}'
---`pane process-info` payload that merely contains the short injected token `q`
---inside a flag: it must not be mistaken for a started tool (R15 false positive).
local FLAG_PROC = '{"id":"1","result":{"process_info":{"shell_pid":100,'
  .. '"foreground_processes":[{"pid":101,"cmdline":"zsh -q","cwd":"/tmp/cwd"}]}}}'

---Build a herdr session instance with a fake tool.
---@param overrides? table
---@return sidekick.cli.Session
local function tool_session(overrides)
  local state = {
    sid = "sid",
    cwd = "/tmp/cwd",
    herdr_session = "sess",
    external = false,
    tool = {
      name = "tool",
      cmd = { "tool", "arg" },
      is_proc = function(_, proc)
        return (proc.cmd or ""):find("tool", 1, true) ~= nil
      end,
    },
  }
  local s = vim.tbl_deep_extend("force", state, overrides or {})
  -- mirror `init()`: created external sessions target the current server
  if s.herdr_current == nil then
    s.herdr_current = s.external == true
  end
  return setmetatable(s, Herdr) --[[@as sidekick.cli.Session]]
end

---Build a herdr session whose injected binary and `is_proc` token differ,
---mirroring `amazon_q` (`cmd = { "q" }`, `is_proc` matching `qchat`) (R15).
---Built directly (not via `tool_session`) so `cmd` is exactly `{ "q" }`.
---@return sidekick.cli.Session
local function q_session()
  return new_session({
    sid = "sid",
    cwd = "/tmp/cwd",
    herdr_session = "sess",
    external = false,
    herdr_current = false,
    tool = {
      name = "amazon_q",
      cmd = { "q" },
      is_proc = function(_, proc)
        return (proc.cmd or ""):find("qchat", 1, true) ~= nil
      end,
    },
  })
end

---Build a minimal fake tool that matches any process whose command contains `name`.
---@param name string
---@return sidekick.cli.Tool
local function fake_tool(name)
  return {
    name = name,
    cmd = { name },
    is_proc = function(_, proc)
      return (proc.cmd or ""):find(name, 1, true) ~= nil
    end,
  }
end

---`pane list` payload with a single pane running the fake tool.
local TOOL_PANE = '{"id":"1","result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1",'
  .. '"workspace_id":"w1","tab_id":"w1:t1","cwd":"/tmp/cwd","foreground_cwd":"/tmp/cwd"}]}}'

---`api snapshot` payload: workspace `w7` labelled `Alpha Site`, tab `w7:t2T`
---labelled `2 · …`. The tab's `number` is deliberately the session-wide counter
---(90) rather than the displayed index, so the fixture fails if `number` is used.
local SNAPSHOT = '{"id":"1","result":{"snapshot":{'
  .. '"workspaces":[{"workspace_id":"w7","label":"Alpha Site","number":1,"active_tab_id":"w7:t2T"}],'
  .. '"tabs":[{"tab_id":"w7:t2T","workspace_id":"w7","number":90,"label":"2 · sidekick.nvim › dev/herdr"}]}}}'

---`pane list` payload for workspace `w7`, tab `w7:t2T`, pane `w7:p77`.
---The pane carries a `label` (real `pane list` always does) that must **not** be
---used for the composed label — the pane id is the identity (they differ).
local PANE_W7 = '{"id":"1","result":{"panes":[{"pane_id":"w7:p77","terminal_id":"t77",'
  .. '"workspace_id":"w7","tab_id":"w7:t2T","label":"sidekick.nvim › dev/herdr",'
  .. '"cwd":"/tmp/cwd","foreground_cwd":"/tmp/cwd"}]}}'

---Two panes sharing workspace+tab+cwd **and** name (a real collision: one tab
---holding two panes both labelled `demo-repo › feat/1.2.3`), so only the pane id
---separates them — the exact collision the `mux_label` was added to resolve.
local PANE_W7_TWO = '{"id":"1","result":{"panes":['
  .. '{"pane_id":"w7:p76","terminal_id":"t76","workspace_id":"w7","tab_id":"w7:t2T","label":"demo-repo › feat/1.2.3","cwd":"/tmp/cwd","foreground_cwd":"/tmp/cwd"},'
  .. '{"pane_id":"w7:p77","terminal_id":"t77","workspace_id":"w7","tab_id":"w7:t2T","label":"demo-repo › feat/1.2.3","cwd":"/tmp/cwd","foreground_cwd":"/tmp/cwd"}]}}'

---Stub `Util.exec` with a per-command handler, recording every argv.
---The handler returns stdout (success) or `nil` (failure).
---@param handler fun(cmd:string[]):string?
---@return string[][]
local function stub_herdr(handler)
  local calls = {} ---@type string[][]
  Util.exec = function(cmd)
    calls[#calls + 1] = cmd
    local out = handler(cmd)
    if out == nil then
      return nil
    end
    return { out }, out
  end
  return calls
end

---Stub a running named session `work` whose single pane runs the fake tool.
---@return string[][]
local function stub_named_discovery()
  Config.tools = function()
    return { tool = fake_tool("tool") }
  end
  return stub_herdr(function(cmd)
    if vim.tbl_contains(cmd, "session") then
      return '{"sessions":[{"name":"work","running":true,"default":true}]}'
    elseif vim.tbl_contains(cmd, "process-info") then
      return TOOL_PROC
    end
    return TOOL_PANE
  end)
end

---Stub discovery for the current (session-less) source.
---@param sessions? string raw `session list` payload
---@return string[][]
local function stub_current_discovery(sessions)
  Config.tools = function()
    return { tool = fake_tool("tool") }
  end
  return stub_herdr(function(cmd)
    if vim.tbl_contains(cmd, "session") then
      return sessions or '{"sessions":[{"name":"work","running":true,"default":true}]}'
    elseif vim.tbl_contains(cmd, "process-info") then
      return TOOL_PROC
    end
    return TOOL_PANE
  end)
end

---Stub a named `work` source whose single `w7:p77` pane matches the fake tool,
---answering the `api snapshot` probe with `snapshot` (`nil` simulates failure).
---@param snapshot string? raw snapshot payload
---@return string[][]
local function stub_w7_discovery(snapshot)
  Config.tools = function()
    return { tool = fake_tool("tool") }
  end
  return stub_herdr(function(cmd)
    if vim.tbl_contains(cmd, "snapshot") then
      return snapshot
    elseif vim.tbl_contains(cmd, "session") then
      return '{"sessions":[{"name":"work","running":true,"default":true}]}'
    elseif vim.tbl_contains(cmd, "process-info") then
      return TOOL_PROC
    end
    return PANE_W7
  end)
end

---Drive a discovered state through the production path (`Session.new`).
---@param state table
---@return sidekick.cli.Session
local function discover_new(state)
  local Session = require("sidekick.cli.session")
  Config.get_tool = function(name)
    return fake_tool(name)
  end
  Session.setup()
  state.backend = "herdr"
  state.started = true
  return Session.new(state)
end

---Find the first recorded command whose argv contains all of `parts`.
---@param calls string[][]
---@param parts string[]
---@return string[]?
local function find_call(calls, parts)
  for _, cmd in ipairs(calls) do
    local ok = true
    for _, part in ipairs(parts) do
      if not vim.tbl_contains(cmd, part) then
        ok = false
        break
      end
    end
    if ok then
      return cmd
    end
  end
  return nil
end

describe("herdr backend", function()
  local orig_exec
  local orig_bin_path
  local orig_herdr_env
  local orig_create
  local orig_jobstart
  local orig_error
  local orig_wait
  local orig_warn
  local orig_info
  local orig_defer_fn
  local orig_has
  local orig_workspace_id
  local orig_vertical
  local orig_size
  local orig_socket_path
  local orig_tools
  local orig_get_tool

  before_each(function()
    orig_exec = Util.exec
    orig_bin_path = vim.env.HERDR_BIN_PATH
    orig_herdr_env = vim.env.HERDR_ENV
    orig_socket_path = vim.env.HERDR_SOCKET_PATH
    orig_tools = Config.tools
    orig_get_tool = Config.get_tool
    orig_create = Config.cli.mux.create
    orig_jobstart = vim.fn.jobstart
    orig_error = Util.error
    orig_wait = vim.wait
    orig_warn = Util.warn
    orig_info = Util.info
    orig_defer_fn = vim.defer_fn
    orig_has = vim.fn.has
    orig_workspace_id = vim.env.HERDR_WORKSPACE_ID
    orig_vertical = Config.cli.mux.split.vertical
    orig_size = Config.cli.mux.split.size
    -- avoid inheriting a real herdr environment from the parent shell
    vim.env.HERDR_BIN_PATH = "herdr"
    vim.env.HERDR_ENV = nil
    vim.env.HERDR_SOCKET_PATH = nil
    vim.env.HERDR_WORKSPACE_ID = nil
    -- reset module-level warn-once bookkeeping (F4) for test isolation
    Herdr._warned = {}
    -- silence notifications by default; individual tests capture them as needed
    Util.warn = function() end
    Util.info = function() end
    vim.defer_fn = function(fn)
      fn()
    end
  end)

  after_each(function()
    Util.exec = orig_exec
    vim.env.HERDR_BIN_PATH = orig_bin_path
    vim.env.HERDR_ENV = orig_herdr_env
    vim.env.HERDR_SOCKET_PATH = orig_socket_path
    Config.tools = orig_tools
    Config.get_tool = orig_get_tool
    Config.cli.mux.create = orig_create
    vim.fn.jobstart = orig_jobstart
    Util.error = orig_error
    vim.wait = orig_wait
    Util.warn = orig_warn
    Util.info = orig_info
    vim.defer_fn = orig_defer_fn
    vim.fn.has = orig_has
    vim.env.HERDR_WORKSPACE_ID = orig_workspace_id
    Config.cli.mux.split.vertical = orig_vertical
    Config.cli.mux.split.size = orig_size
  end)

  describe("bin()", function()
    it("prefers $HERDR_BIN_PATH", function()
      vim.env.HERDR_BIN_PATH = "/opt/herdr/bin/herdr"
      assert.are.equal("/opt/herdr/bin/herdr", Herdr.bin())
    end)

    it("falls back to `herdr`", function()
      vim.env.HERDR_BIN_PATH = nil
      assert.are.equal("herdr", Herdr.bin())
    end)
  end)

  describe("session_name()", function()
    it("keeps safe characters untouched", function()
      assert.are.equal("valid.name_1-2", Herdr.session_name("valid.name_1-2"))
    end)

    it("replaces unsafe characters and appends a deterministic hash", function()
      local hash = vim.fn.sha256("tool abc"):sub(1, 6)
      assert.are.equal("tool-abc-" .. hash, Herdr.session_name("tool abc"))
    end)

    it("caps the sanitized length at 64 characters", function()
      local long = string.rep("a", 200)
      local name = Herdr.session_name(long)
      assert.are.equal(64, #name)
      assert.matches("%-" .. vim.fn.sha256(long):sub(1, 6) .. "$", name)
    end)

    it("avoids collisions for ids that sanitize to the same value", function()
      assert.is_true(Herdr.session_name("tool a/b") ~= Herdr.session_name("tool a-b"))
    end)
  end)

  describe("cmd()", function()
    it("inserts the global --session before the subcommand", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      assert.are.same({ "herdr", "--session", "s", "pane", "list" }, Herdr.cmd("s", { "pane", "list" }))
    end)

    it("omits --session for the current session", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      assert.are.same({ "herdr", "pane", "list" }, Herdr.cmd("s", { "pane", "list" }, true))
    end)

    it("uses the resolved binary", function()
      vim.env.HERDR_BIN_PATH = "/x/herdr"
      assert.are.same({ "/x/herdr", "--session", "s" }, Herdr.cmd("s", {}))
    end)
  end)

  describe("json()", function()
    it("returns the result of a wrapped response", function()
      stub_exec('{"id":"1","result":{"running":true}}')
      assert.are.same({ running = true }, Herdr.json({ "herdr" }))
    end)

    it("returns an unwrapped response as-is", function()
      stub_exec('{"sessions":[{"name":"a","running":true}]}')
      assert.are.same({ sessions = { { name = "a", running = true } } }, Herdr.json({ "herdr" }))
    end)

    it("tolerates empty stdout", function()
      stub_exec("")
      assert.are.same({}, Herdr.json({ "herdr" }))
    end)

    it("returns nil for malformed json", function()
      stub_exec("definitely not json")
      assert.is_nil(Herdr.json({ "herdr" }))
    end)

    it("returns nil when the command fails", function()
      Util.exec = function()
        return nil
      end
      assert.is_nil(Herdr.json({ "herdr" }))
    end)

    it("returns a structured `error` body as-is (D18)", function()
      stub_exec('{"error":{"code":"workspace_not_found","message":"nope"}}')
      assert.are.same({ error = { code = "workspace_not_found", message = "nope" } }, Herdr.json({ "herdr" }))
    end)

    it("returns nil for a non-table JSON scalar", function()
      stub_exec("42")
      assert.is_nil(Herdr.json({ "herdr" }))
    end)
  end)

  describe("status() / server_running()", function()
    it("reports a running server", function()
      stub_exec('{"status":"running","running":true,"version":"0.9.4","protocol":22}')
      assert.is_true(Herdr.server_running("s"))
      assert.are.equal("0.9.4", Herdr.status().version)
    end)

    it("reports down when the server is not running (exit 0, running=false)", function()
      stub_exec('{"status":"not_running","running":false,"version":null}')
      assert.is_false(Herdr.server_running("s"))
      local status = Herdr.status()
      assert.are.equal("not_running", status.status)
      assert.is_false(status.running)
    end)

    it("soft-fails when the status query fails", function()
      Util.exec = function()
        return nil
      end
      assert.is_false(Herdr.server_running("s"))
      assert.is_nil(Herdr.status())
    end)

    it("ensure_server() is a no-op when the server already runs", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      stub_exec('{"running":true}')
      vim.fn.jobstart = function()
        error("ensure_server must not spawn when the server is already running")
      end
      assert.is_true(Herdr.ensure_server("s"))
    end)

    it("ensure_server() returns false when the spawn fails", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      stub_exec('{"running":false}')
      vim.fn.jobstart = function()
        return 0
      end
      local errors = {}
      Util.error = function(msg)
        errors[#errors + 1] = msg
      end
      assert.is_false(Herdr.ensure_server("s"))
      assert.is_true(#errors > 0)
    end)

    it("ensure_server() returns false when the wait times out", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      stub_exec('{"running":false}')
      vim.fn.jobstart = function()
        return 1234
      end
      vim.wait = function()
        return false
      end
      local errors = {}
      Util.error = function(msg)
        errors[#errors + 1] = msg
      end
      assert.is_false(Herdr.ensure_server("s"))
      assert.is_true(#errors > 0)
    end)

    it("ensure_server() waits for a freshly started server (real vim.wait)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local calls = 0
      Util.exec = function()
        calls = calls + 1
        if calls == 1 then
          return { '{"running":false}' }, '{"running":false}'
        end
        return { '{"running":true}' }, '{"running":true}'
      end
      vim.fn.jobstart = function()
        return 1234
      end
      assert.is_true(Herdr.ensure_server("s"))
      assert.is_true(calls >= 2)
    end)
  end)

  describe("server_running() session targeting (D14)", function()
    it("includes --session when probing a specific session", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local sink = {}
      stub_exec_capture('{"running":true}', sink)
      assert.is_true(Herdr.server_running("my session"))
      assert.are.same({ "herdr", "--session", "my session", "status", "server", "--json" }, sink.cmd)
    end)

    it("omits --session for the current session", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local sink = {}
      stub_exec_capture('{"running":true}', sink)
      assert.is_true(Herdr.server_running("s", true))
      assert.are.same({ "herdr", "status", "server", "--json" }, sink.cmd)
    end)
  end)

  describe("init() (D14)", function()
    it("embedded terminal: embedded, mux_session = sid, high priority", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "terminal"
      local s = new_session({ sid = "tool abc", started = false })
      s:init()
      assert.is_false(s.external)
      assert.are.equal("tool abc", s.mux_session)
      assert.are.equal(50, s.priority)
    end)

    it("never stores the sanitized name in mux_session", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "terminal"
      local s = new_session({ sid = "tool abc", started = false })
      s:init()
      assert.are.equal(Herdr.session_name("tool abc"), s.herdr_session)
      assert.is_true(s.herdr_session ~= s.mux_session)
    end)

    it("external when inside herdr and create ~= terminal", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      local s = new_session({ sid = "tool abc", started = false })
      s:init()
      assert.is_true(s.external)
      assert.are.equal(10, s.priority)
    end)

    it("embedded when not inside herdr", function()
      vim.env.HERDR_ENV = nil
      Config.cli.mux.create = "split"
      local s = new_session({ sid = "tool abc", started = false })
      s:init()
      assert.is_false(s.external)
      assert.are.equal(50, s.priority)
    end)

    it("started sessions are external when sid ~= mux_session", function()
      local s = new_session({ sid = "sid", mux_session = "other", started = true })
      s:init()
      assert.is_true(s.external)
      assert.are.equal(10, s.priority)
    end)

    it("started sessions are embedded when sid == mux_session", function()
      local s = new_session({ sid = "sid", mux_session = "sid", started = true })
      s:init()
      assert.is_false(s.external)
      assert.are.equal(50, s.priority)
    end)
  end)

  describe("sources() (P3/D8/D16)", function()
    it("includes the current session and drops non-running named sessions", function()
      vim.env.HERDR_ENV = "1"
      stub_herdr(function()
        return '{"sessions":[{"name":"work","running":true,"default":true},{"name":"down","running":false}]}'
      end)
      assert.are.same({ { name = "work", current = true } }, Herdr.sources())
    end)

    it("deduplicates the current session against the matching socket entry (D16)", function()
      vim.env.HERDR_ENV = "1"
      vim.env.HERDR_SOCKET_PATH = "/tmp/sock"
      stub_herdr(function()
        return '{"sessions":[{"name":"a","running":true,"socket_path":"/tmp/sock"},{"name":"b","running":true}]}'
      end)
      assert.are.same({ { name = "a", current = true }, { name = "b", current = false } }, Herdr.sources())
    end)

    it("lists only running named sessions when outside herdr", function()
      vim.env.HERDR_ENV = nil
      stub_herdr(function()
        return '{"sessions":[{"name":"a","running":true},{"name":"b","running":false}]}'
      end)
      assert.are.same({ { name = "a", current = false } }, Herdr.sources())
    end)

    it("returns no sources when the server is down", function()
      vim.env.HERDR_ENV = nil
      Util.exec = function()
        return nil
      end
      assert.are.same({}, Herdr.sources())
    end)
  end)

  describe("sessions() (P3/D8/D15/D16/D18)", function()
    local Session = require("sidekick.cli.session")

    it("maps a pane + process-info to a state with the right sid/mux_session/id", function()
      vim.env.HERDR_ENV = nil
      local calls = stub_named_discovery()
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      local sid = Session.sid({ tool = "tool", cwd = "/tmp/cwd" })
      assert.are.equal("herdr t1", ret[1].id)
      assert.are.equal(sid, ret[1].sid)
      -- F1/F2: the source identity is carried, not the sid
      assert.are.equal("work", ret[1].mux_session)
      assert.are.equal("work", ret[1].herdr_session)
      assert.is_false(ret[1].herdr_current)
      assert.are.equal("tool", ret[1].tool)
      assert.are.equal("/tmp/cwd", ret[1].cwd)
      assert.are.equal("w1:p1", ret[1].herdr_pane_id)
      assert.are.equal("t1", ret[1].herdr_terminal_id)
      assert.are.equal("w1", ret[1].herdr_workspace_id)
      assert.are.equal("w1:t1", ret[1].herdr_tab_id)
      assert.is_true(vim.tbl_contains(ret[1].pids, 100))
      assert.is_true(vim.tbl_contains(ret[1].pids, 101))
      -- named source is targeted via the global --session
      assert.are.same({ "herdr", "--session", "work", "pane", "list" }, find_call(calls, { "pane", "list" }))
    end)

    it("queries the current source without --session", function()
      vim.env.HERDR_ENV = "1"
      local calls = stub_current_discovery()
      Herdr.sessions()
      assert.are.same({ "herdr", "pane", "list" }, find_call(calls, { "pane", "list" }))
    end)

    it("merges pids from the embedded Terminal registry (D15)", function()
      vim.env.HERDR_ENV = nil
      stub_named_discovery()
      local Terminal = require("sidekick.cli.terminal")
      local sid = Session.sid({ tool = "tool", cwd = "/tmp/cwd" })
      local orig = Terminal.terminals
      Terminal.terminals = { { mux_backend = "herdr", mux_session = sid, pids = { 55 } } }
      local ret = Herdr.sessions()
      Terminal.terminals = orig
      assert.is_true(vim.tbl_contains(ret[1].pids, 55))
    end)

    it("merges pids by terminal_id when the sid drifted (D15)", function()
      vim.env.HERDR_ENV = nil
      stub_named_discovery()
      local Terminal = require("sidekick.cli.terminal")
      local orig = Terminal.terminals
      Terminal.terminals = {
        { mux_backend = "herdr", mux_session = "drifted sid", parent = { herdr_terminal_id = "t1" }, pids = { 77 } },
      }
      local ret = Herdr.sessions()
      Terminal.terminals = orig
      assert.is_true(vim.tbl_contains(ret[1].pids, 77))
    end)

    it("collapses a duplicate terminal_id across sources to a single id (D16)", function()
      vim.env.HERDR_ENV = "1"
      vim.env.HERDR_SOCKET_PATH = "/tmp/sock"
      Config.tools = function()
        return { tool = fake_tool("tool") }
      end
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "session") then
          -- the current session is not named here, so it cannot be deduplicated
          return '{"sessions":[{"name":"b","running":true}]}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return TOOL_PANE
      end)
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("herdr t1", ret[1].id)
      -- two sources scanned the same pane, but only one process-info per source
      assert.are.equal(2, #vim.tbl_filter(function(cmd)
        return vim.tbl_contains(cmd, "process-info")
      end, calls))
    end)

    it("memoizes pane list / process-info within a single call (D8)", function()
      vim.env.HERDR_ENV = nil
      Config.tools = function()
        return { tool = fake_tool("tool") }
      end
      local counts = { session = 0, snapshot = 0, pane_list = 0, process = 0 }
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "snapshot") then
          counts.snapshot = counts.snapshot + 1
          return SNAPSHOT
        elseif vim.tbl_contains(cmd, "session") then
          counts.session = counts.session + 1
          return '{"sessions":[{"name":"work","running":true,"default":true}]}'
        elseif vim.tbl_contains(cmd, "process-info") then
          counts.process = counts.process + 1
          return TOOL_PROC
        end
        counts.pane_list = counts.pane_list + 1
        return '{"id":"1","result":{"panes":['
          .. '{"pane_id":"w1:p1","terminal_id":"t1","cwd":"/tmp/cwd"},'
          .. '{"pane_id":"w1:p2","terminal_id":"t2","cwd":"/tmp/cwd"}]}}'
      end)
      local ret = Herdr.sessions()
      assert.are.equal(2, #ret)
      assert.are.equal(1, counts.session)
      -- the display-label lookup is one `api snapshot` per source, not per pane
      assert.are.equal(1, counts.snapshot)
      assert.are.equal(1, counts.pane_list)
      assert.are.equal(2, counts.process)
    end)

    it("soft-fails and warns once when the server is down (D18)", function()
      vim.env.HERDR_ENV = nil
      Config.tools = function()
        return { tool = fake_tool("tool") }
      end
      local warns = {}
      Util.warn = function(msg)
        warns[#warns + 1] = msg
      end
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "session") then
          return '{"sessions":[{"name":"work","running":true,"default":true}]}'
        end
        return nil -- pane list fails: the server is down
      end)
      assert.are.same({}, Herdr.sessions())
      assert.are.equal(1, #warns)
      Herdr.sessions() -- a second failure must not warn again (bounded)
      assert.are.equal(1, #warns)
    end)

    it("does not apply the launch-only injected-binary rule during discovery (R15)", function()
      vim.env.HERDR_ENV = nil
      -- amazon_q-style tool: `is_proc` matches `qchat`, but the foreground only
      -- shows the injected `q`. Discovery must keep matching via `is_proc` alone
      -- (the `matches_injected` OR is launch-only), so no session is emitted.
      Config.tools = function()
        return { amazon_q = q_session().tool }
      end
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "session") then
          return '{"sessions":[{"name":"work","running":true,"default":true}]}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return Q_PROC
        end
        return TOOL_PANE
      end)
      assert.are.same({}, Herdr.sessions())
    end)
  end)

  describe("mux_label (picker display label)", function()
    it("composes the workspace label, tab number and pane id (named source)", function()
      local calls = stub_w7_discovery(SNAPSHOT)
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("Alpha Site · 2 · p77", ret[1].mux_label)
      -- the extra lookup is session-scoped like every other command
      assert.are.same({ "herdr", "--session", "work", "api", "snapshot" }, find_call(calls, { "api", "snapshot" }))
    end)

    it("omits --session for the current source", function()
      vim.env.HERDR_ENV = "1"
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "snapshot") then
          return SNAPSHOT
        elseif vim.tbl_contains(cmd, "session") then
          return '{"sessions":[{"name":"default","running":true,"default":true}]}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return PANE_W7
      end)
      Config.tools = function()
        return { tool = fake_tool("tool") }
      end
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("Alpha Site · 2 · p77", ret[1].mux_label)
      assert.are.same({ "herdr", "api", "snapshot" }, find_call(calls, { "api", "snapshot" }))
    end)

    it("distinguishes two panes sharing workspace, tab and cwd", function()
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "snapshot") then
          return SNAPSHOT
        elseif vim.tbl_contains(cmd, "session") then
          return '{"sessions":[{"name":"work","running":true,"default":true}]}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return PANE_W7_TWO
      end)
      Config.tools = function()
        return { tool = fake_tool("tool") }
      end
      local ret = Herdr.sessions()
      assert.are.equal(2, #ret)
      assert.are.equal(ret[1].cwd, ret[2].cwd)
      local labels = { ret[1].mux_label, ret[2].mux_label }
      table.sort(labels)
      assert.are.same({ "Alpha Site · 2 · p76", "Alpha Site · 2 · p77" }, labels)
      assert.are.equal(1, #vim.tbl_filter(function(cmd)
        return vim.tbl_contains(cmd, "snapshot")
      end, calls))
    end)

    it("falls back to ids when the snapshot probe fails", function()
      stub_w7_discovery(nil)
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("w7 · t2T · p77", ret[1].mux_label)
    end)

    it("falls back to ids when the snapshot payload is unexpected", function()
      stub_w7_discovery('{"id":"1","result":{"snapshot":{"workspaces":[],"tabs":[]}}}')
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("w7 · t2T · p77", ret[1].mux_label)
    end)

    it("never raises when a snapshot section is not a list", function()
      -- a scalar section used to hit `ipairs` and abort the whole picker
      stub_w7_discovery('{"id":"1","result":{"snapshot":{"workspaces":"oops","tabs":42}}}')
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("w7 · t2T · p77", ret[1].mux_label)
    end)

    it("degrades per segment when the snapshot omits an entity", function()
      -- workspace label missing, tab display index still parseable from the label
      stub_w7_discovery(
        '{"id":"1","result":{"snapshot":{"workspaces":[{"workspace_id":"w7","label":""}],'
          .. '"tabs":[{"tab_id":"w7:t2T","number":90,"label":"2 · sidekick.nvim"}]}}}'
      )
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("w7 · 2 · p77", ret[1].mux_label)
    end)

    it("degrades to the tab id when the tab label carries no index", function()
      stub_w7_discovery(
        '{"id":"1","result":{"snapshot":{"workspaces":[{"workspace_id":"w7","label":"Alpha Site"}],'
          .. '"tabs":[{"tab_id":"w7:t2T","number":90,"label":"sidekick.nvim"}]}}}'
      )
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("Alpha Site · t2T · p77", ret[1].mux_label)
    end)

    it("omits the tab segment when the pane reports no tab id", function()
      local pane = '{"id":"1","result":{"panes":[{"pane_id":"w7:p77","terminal_id":"t77",'
        .. '"workspace_id":"w7","cwd":"/tmp/cwd","foreground_cwd":"/tmp/cwd"}]}}'
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "snapshot") then
          return SNAPSHOT
        elseif vim.tbl_contains(cmd, "session") then
          return '{"sessions":[{"name":"work","running":true,"default":true}]}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return pane
      end)
      Config.tools = function()
        return { tool = fake_tool("tool") }
      end
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      assert.are.equal("Alpha Site · p77", ret[1].mux_label)
    end)

    it("leaves mux_label unset when the pane carries no id", function()
      local pane = '{"id":"1","result":{"panes":[{"pane_id":"","terminal_id":"t9",'
        .. '"workspace_id":"w7","tab_id":"w7:t2T","cwd":"/tmp/cwd","foreground_cwd":"/tmp/cwd"}]}}'
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "snapshot") then
          return SNAPSHOT
        elseif vim.tbl_contains(cmd, "session") then
          return '{"sessions":[{"name":"work","running":true,"default":true}]}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return pane
      end)
      Config.tools = function()
        return { tool = fake_tool("tool") }
      end
      local ret = Herdr.sessions()
      assert.are.equal(1, #ret)
      -- the UI then keeps rendering `[herdr:<session>]`
      assert.is_nil(ret[1].mux_label)
    end)
  end)

  describe("focus() (D9)", function()
    it("reveals the workspace and tab derived from the pane id", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      -- no workspace_id/tab_id: the workspace is derived from the `w1:p19` prefix
      local s = tool_session({ herdr_pane_id = "w1:p19", herdr_terminal_id = "t1" })
      local calls = stub_herdr(function()
        return ""
      end)
      assert.are.equal(s, s:focus())
      assert.are.same({ "herdr", "--session", "sess", "workspace", "focus", "w1" }, calls[1])
      assert.are.equal(1, #calls) -- no tab id resolvable → only the workspace
    end)

    it("uses a known tab id", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({
        herdr_pane_id = "w1:p1",
        herdr_terminal_id = "t1",
        herdr_workspace_id = "w1",
        herdr_tab_id = "w1:t1",
      })
      local calls = stub_herdr(function()
        return ""
      end)
      s:focus()
      assert.are.same({ "herdr", "--session", "sess", "workspace", "focus", "w1" }, calls[1])
      assert.are.same({ "herdr", "--session", "sess", "tab", "focus", "w1:t1" }, calls[2])
    end)

    it("omits --session for the current (session-less) source", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ external = true, herdr_pane_id = "w7:p1", herdr_terminal_id = "t7" })
      local calls = stub_herdr(function()
        return ""
      end)
      s:focus()
      assert.are.same({ "herdr", "workspace", "focus", "w7" }, calls[1])
    end)

    it("does nothing when no pane resolves", function()
      local s = tool_session({ herdr_terminal_id = "nope" })
      local calls = stub_herdr(function()
        return '{"result":{"panes":[]}}'
      end)
      assert.are.equal(s, s:focus())
      -- only the pane lookup ran; no workspace/tab focus was spawned
      assert.are.equal(1, #calls)
      assert.are.same({ "herdr", "--session", "sess", "pane", "list" }, calls[1])
    end)

    it("spawns nothing when pane() has no source to list (early return)", function()
      -- not external and no herdr session: `pane()` returns early before listing
      -- panes, so the best-effort reveal spawns no herdr command. Note this entry
      -- state is only reachable directly; `init()` always assigns a `herdr_session`.
      local s = new_session({ sid = "sid", cwd = "/tmp/cwd" })
      Util.exec = function()
        error("focus must not spawn when no location can be resolved")
      end
      assert.are.equal(s, s:focus())
    end)

    it("skips the workspace but still reveals a known tab", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      -- opaque pane id (no `w1:` prefix) and no workspace_id → only the tab resolves
      local s = tool_session({ herdr_pane_id = "opaque", herdr_terminal_id = "t1", herdr_tab_id = "w1:t1" })
      local calls = stub_herdr(function()
        return ""
      end)
      assert.are.equal(s, s:focus())
      assert.are.equal(1, #calls)
      assert.are.same({ "herdr", "--session", "sess", "tab", "focus", "w1:t1" }, calls[1])
    end)
  end)

  describe("discovered session identity (F1/F2)", function()
    it("classifies a named-source pane as external, priority 10, and targets --session", function()
      vim.env.HERDR_ENV = nil
      local calls = stub_named_discovery()
      local s = discover_new(Herdr.sessions()[1])
      assert.is_true(s.external)
      assert.are.equal(10, s.priority)
      assert.are.equal("work", s.mux_session)
      assert.are.equal("work", s.herdr_session)
      assert.is_false(s.herdr_current)
      -- external sessions are not attached from Neovim (tmux parity)
      assert.is_nil(s:attach())
      -- a discovered pane whose session exists reports running, and commands
      -- are scoped to the real source name
      assert.is_true(s:is_running())
      assert.are.equal("w1", s.herdr_workspace_id)
      assert.are.equal("w1:t1", s.herdr_tab_id)
      s:focus()
      assert.are.same(
        { "herdr", "--session", "work", "workspace", "focus", "w1" },
        find_call(calls, { "workspace", "focus" })
      )
      assert.are.same({ "herdr", "--session", "work", "tab", "focus", "w1:t1" }, find_call(calls, { "tab", "focus" }))
    end)

    it("classifies a current-source pane as external and omits --session", function()
      vim.env.HERDR_ENV = "1"
      local calls = stub_current_discovery('{"sessions":[]}')
      local states = Herdr.sessions()
      assert.are.equal(1, #states)
      -- the session-less source carries no name
      assert.is_nil(states[1].mux_session)
      assert.is_nil(states[1].herdr_session)
      assert.is_true(states[1].herdr_current)
      local s = discover_new(states[1])
      assert.is_true(s.external)
      assert.are.equal(10, s.priority)
      assert.is_nil(s.mux_session)
      assert.is_true(s.herdr_current)
      assert.is_true(s:is_running())
      assert.are.same({ "herdr", "pane", "list" }, find_call(calls, { "pane", "list" }))
      s:focus()
      -- D9 revised: no absolute pane focus; reveal workspace then tab, without --session
      assert.are.same({ "herdr", "workspace", "focus", "w1" }, find_call(calls, { "workspace", "focus" }))
      assert.are.same({ "herdr", "tab", "focus", "w1:t1" }, find_call(calls, { "tab", "focus" }))
    end)
  end)

  describe("focus wiring through cli.state (D9 / PR #198)", function()
    local Session = require("sidekick.cli.session")

    it("focuses a discovered external session", function()
      vim.env.HERDR_ENV = nil
      local State = require("sidekick.cli.state")
      local calls = stub_named_discovery()
      local s = discover_new(Herdr.sessions()[1])
      assert.is_true(s.external)
      -- mark it attached so `Session.attach` is a no-op and does not emit
      Session._attached[s.id] = s
      local ok = pcall(State.attach, { session = s, tool = s.tool }, { focus = true })
      Session._attached[s.id] = nil
      assert.is_true(ok)
      -- D9 revised: the workspace/tab are revealed, scoped to the source session
      assert.are.same(
        { "herdr", "--session", "work", "workspace", "focus", "w1" },
        find_call(calls, { "workspace", "focus" })
      )
      assert.are.same({ "herdr", "--session", "work", "tab", "focus", "w1:t1" }, find_call(calls, { "tab", "focus" }))
    end)
  end)

  describe("pane() / pane_id()", function()
    it("lists panes scoped to the session and caches the matched ids", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ herdr_terminal_id = "t1" })
      local calls = stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1"}]}}'
      end)
      local pane = s:pane()
      assert.are.equal("w1:p1", pane.pane_id)
      assert.are.equal("w1:p1", s.herdr_pane_id)
      assert.are.equal("t1", s.herdr_terminal_id)
      assert.are.same({ "herdr", "--session", "sess", "pane", "list" }, calls[1])
    end)

    it("falls back to matching by pane_id", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ herdr_pane_id = "w1:p1" })
      stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1"}]}}'
      end)
      assert.are.equal("t1", s:pane().terminal_id)
      assert.are.equal("t1", s.herdr_terminal_id)
      assert.are.equal("w1:p1", s:pane_id())
    end)

    it("backfills a missing workspace/tab from the matched pane (F3)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ herdr_terminal_id = "t1" })
      stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1",'
          .. '"workspace_id":"w1","tab_id":"w1:t1"}]}}'
      end)
      assert.is_true(s:pane() ~= nil)
      assert.are.equal("w1", s.herdr_workspace_id)
      assert.are.equal("w1:t1", s.herdr_tab_id)
    end)

    it("keeps an already known workspace/tab over the pane record (F3)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({
        herdr_terminal_id = "t1",
        herdr_workspace_id = "w9",
        herdr_tab_id = "w9:t9",
      })
      stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1",'
          .. '"workspace_id":"w1","tab_id":"w1:t1"}]}}'
      end)
      assert.is_true(s:pane() ~= nil)
      assert.are.equal("w9", s.herdr_workspace_id)
      assert.are.equal("w9:t9", s.herdr_tab_id)
    end)

    it("returns nil when no pane matches", function()
      local s = tool_session({ herdr_terminal_id = "nope" })
      stub_herdr(function()
        return '{"result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1"}]}}'
      end)
      assert.is_nil(s:pane())
    end)

    it("refresh bypasses the cache and re-queries pane list (F1)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ herdr_pane_id = "w1:p1", herdr_terminal_id = "t1" })
      local calls = stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1"}]}}'
      end)
      assert.is_true(s:pane(true) ~= nil)
      assert.are.same({ "herdr", "--session", "sess", "pane", "list" }, calls[1])
    end)

    it("a missed refresh invalidates both cached ids (F1/D18)", function()
      local s = tool_session({ herdr_pane_id = "w1:p1", herdr_terminal_id = "t1" })
      stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w9:p9","terminal_id":"t9"}]}}'
      end)
      assert.is_nil(s:pane(true))
      assert.is_nil(s.herdr_pane_id)
      assert.is_nil(s.herdr_terminal_id)
    end)

    it("returns the cached pane without running a command", function()
      local s = tool_session({ herdr_pane_id = "w1:p1", herdr_terminal_id = "t1" })
      Util.exec = function()
        error("must not run a command when ids are cached")
      end
      assert.are.equal("w1:p1", s:pane_id())
    end)

    it("targets the current session for external sessions", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ external = true, herdr_terminal_id = "t1" })
      local calls = stub_herdr(function()
        return '{"result":{"panes":[{"pane_id":"w7:p1","terminal_id":"t1"}]}}'
      end)
      s:pane()
      assert.are.same({ "herdr", "pane", "list" }, calls[1])
    end)
  end)

  describe("start() embedded (create = terminal)", function()
    it("creates a workspace, launches the pane and attaches", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      Config.cli.mux.create = "terminal"
      local s = tool_session()
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "status") then
          return '{"running":true}'
        elseif vim.tbl_contains(cmd, "workspace") then
          return '{"id":"1","result":{"root_pane":{"pane_id":"w2:p1","terminal_id":"t2"}}}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return "" -- pane run
      end)
      local ret = s:start()
      assert.are.same({ cmd = { "herdr", "--session", "sess", "terminal", "attach", "t2" } }, ret)
      assert.is_true(s.started)
      assert.are.same({
        "herdr",
        "--session",
        "sess",
        "workspace",
        "create",
        "--cwd",
        "/tmp/cwd",
        "--label",
        "sid",
        "--no-focus",
      }, find_call(calls, { "workspace", "create" }))
      assert.are.same(
        { "herdr", "--session", "sess", "pane", "run", "w2:p1", "exec 'tool' 'arg'" },
        find_call(calls, { "pane", "run" })
      )
    end)

    it("appends --env and skips false values with a single warning", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      Config.cli.mux.create = "terminal"
      local warns = {}
      Util.warn = function(msg)
        warns[#warns + 1] = msg
      end
      local s = tool_session({ tool = { env = { FOO = "bar", GONE = false } } })
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "status") then
          return '{"running":true}'
        elseif vim.tbl_contains(cmd, "workspace") then
          return '{"id":"1","result":{"root_pane":{"pane_id":"w2:p1","terminal_id":"t2"}}}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return ""
      end)
      s:start()
      assert.are.same({
        "herdr",
        "--session",
        "sess",
        "workspace",
        "create",
        "--cwd",
        "/tmp/cwd",
        "--label",
        "sid",
        "--no-focus",
        "--env",
        "FOO=bar",
      }, find_call(calls, { "workspace", "create" }))
      assert.are.equal(1, #warns)
    end)

    it("returns nil when the workspace creation fails", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      Config.cli.mux.create = "terminal"
      Util.error = function() end
      local s = tool_session()
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "status") then
          return '{"running":true}'
        end
        return '{"error":{"code":"boom","message":"nope"}}'
      end)
      assert.is_nil(s:start())
    end)

    it("closes the workspace it created when the launch fails (R16)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      Config.cli.mux.create = "terminal"
      Util.error = function() end
      vim.wait = function() end
      local s = tool_session()
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "status") then
          return '{"running":true}'
        elseif vim.tbl_contains(cmd, "workspace") then
          return '{"id":"1","result":{"workspace":{"workspace_id":"w2"},'
            .. '"root_pane":{"pane_id":"w2:p1","terminal_id":"t2"}}}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return NO_PROC -- the tool never comes up: launch fails
        end
        return "" -- pane run accepted
      end)
      assert.is_nil(s:start())
      assert.is_nil(s.started)
      assert.is_nil(s.herdr_pane_id)
      assert.is_nil(s.herdr_terminal_id)
      assert.are.same(
        { "herdr", "--session", "sess", "workspace", "close", "w2" },
        find_call(calls, { "workspace", "close" })
      )
    end)
  end)

  describe("start() window (create = window)", function()
    it("creates a tab in the current workspace and launches the pane", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      vim.env.HERDR_WORKSPACE_ID = "w7"
      Config.cli.mux.create = "window"
      local infos = {}
      Util.info = function(msg)
        infos[#infos + 1] = msg
      end
      local s = tool_session({ external = true })
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "tab") then
          return '{"id":"1","result":{"root_pane":{"pane_id":"w7:p9","terminal_id":"t9"}}}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return ""
      end)
      assert.is_nil(s:start())
      assert.are.same({
        "herdr",
        "tab",
        "create",
        "--workspace",
        "w7",
        "--cwd",
        "/tmp/cwd",
        "--label",
        "sid",
        "--no-focus",
      }, find_call(calls, { "tab", "create" }))
      assert.are.same({ "herdr", "pane", "run", "w7:p9", "exec 'tool' 'arg'" }, find_call(calls, { "pane", "run" }))
      assert.are.equal(1, #infos)
    end)

    it("omits --workspace when $HERDR_WORKSPACE_ID is unset", function()
      vim.env.HERDR_WORKSPACE_ID = nil
      Config.cli.mux.create = "window"
      local s = tool_session({ external = true })
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "tab") then
          return '{"id":"1","result":{"root_pane":{"pane_id":"w7:p9","terminal_id":"t9"}}}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return ""
      end)
      s:start()
      assert.are.same({
        "herdr",
        "tab",
        "create",
        "--cwd",
        "/tmp/cwd",
        "--label",
        "sid",
        "--no-focus",
      }, find_call(calls, { "tab", "create" }))
    end)

    it("does not close the user's workspace when the launch fails (R16)", function()
      vim.env.HERDR_WORKSPACE_ID = "w7"
      Config.cli.mux.create = "window"
      Util.error = function() end
      vim.wait = function() end
      local s = tool_session({ external = true })
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "tab") then
          return '{"id":"1","result":{"root_pane":{"pane_id":"w7:p9","terminal_id":"t9"}}}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return NO_PROC -- the tool never comes up: launch fails
        end
        return ""
      end)
      assert.is_nil(s:start())
      -- only the pane we opened is closed; the pre-existing workspace is left alone
      assert.are.same({ "herdr", "pane", "close", "w7:p9" }, calls[#calls])
      assert.is_nil(find_call(calls, { "workspace", "close" }))
    end)
  end)

  describe("start() split (create = split)", function()
    it("splits to the right with --ratio derived from size", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      Config.cli.mux.create = "split"
      Config.cli.mux.split.vertical = true
      Config.cli.mux.split.size = 0.25
      local s = tool_session({ external = true })
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "split") then
          return '{"id":"1","result":{"pane":{"pane_id":"w7:p8","terminal_id":"t8"}}}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return ""
      end)
      assert.is_nil(s:start())
      assert.are.same({
        "herdr",
        "pane",
        "split",
        "--current",
        "--direction",
        "right",
        "--cwd",
        "/tmp/cwd",
        "--no-focus",
        "--ratio",
        "0.75",
      }, find_call(calls, { "split" }))
      assert.are.same({ "herdr", "pane", "run", "w7:p8", "exec 'tool' 'arg'" }, find_call(calls, { "pane", "run" }))
    end)

    it("splits downward when not vertical", function()
      Config.cli.mux.create = "split"
      Config.cli.mux.split.vertical = false
      Config.cli.mux.split.size = 0.5
      local s = tool_session({ external = true })
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "split") then
          return '{"id":"1","result":{"pane":{"pane_id":"w7:p8","terminal_id":"t8"}}}'
        elseif vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return ""
      end)
      s:start()
      assert.are.same({
        "herdr",
        "pane",
        "split",
        "--current",
        "--direction",
        "down",
        "--cwd",
        "/tmp/cwd",
        "--no-focus",
        "--ratio",
        "0.5",
      }, find_call(calls, { "split" }))
    end)
  end)

  describe("proc_running() launch confirmation (R15)", function()
    local function info_cmd(cmd)
      return vim.tbl_contains(cmd, "process-info")
    end

    it("matches the injected binary when is_proc does not (false negative fixed)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = q_session()
      stub_herdr(function(cmd)
        return info_cmd(cmd) and Q_PROC or ""
      end)
      assert.is_true(s:proc_running("w1:p1"))
    end)

    it("ignores the short injected token inside a flag (no false positive)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = q_session()
      stub_herdr(function(cmd)
        return info_cmd(cmd) and FLAG_PROC or ""
      end)
      assert.is_false(s:proc_running("w1:p1"))
    end)

    it("ignores a plainly unrelated foreground process (no false positive)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = q_session()
      stub_herdr(function(cmd)
        return info_cmd(cmd) and OTHER_PROC or ""
      end)
      assert.is_false(s:proc_running("w1:p1"))
    end)
  end)

  describe("launch_pane()", function()
    it("runs `pane run exec` and records the pane once the process is up (F2)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      vim.wait = function() end
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return ""
      end)
      assert.is_true(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.is_true(s.started)
      assert.are.equal("w1:p1", s.herdr_pane_id)
      assert.are.equal("t1", s.herdr_terminal_id)
      -- R14: the first call captures the pre-injection foreground baseline and
      -- the second is attempt 1's own guard probe (taken unconditionally)
      assert.are.same({ "herdr", "--session", "sess", "pane", "process-info", "--pane", "w1:p1" }, calls[1])
      assert.are.same({ "herdr", "--session", "sess", "pane", "process-info", "--pane", "w1:p1" }, calls[2])
      assert.are.same({ "herdr", "--session", "sess", "pane", "run", "w1:p1", "exec 'tool' 'arg'" }, calls[3])
      assert.are.same({ "herdr", "--session", "sess", "pane", "process-info", "--pane", "w1:p1" }, calls[4])
    end)

    it("records the location carried by the create/split payload (D9 reveal)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      vim.wait = function() end
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return ""
      end)
      assert.is_true(s:launch_pane({
        pane_id = "w1:p1",
        terminal_id = "t1",
        workspace_id = "w1",
        tab_id = "w1:t1",
      }))
      assert.are.equal("w1", s.herdr_workspace_id)
      assert.are.equal("w1:t1", s.herdr_tab_id)
    end)

    it("leaves the location untouched when the payload omits it", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ herdr_workspace_id = "w1", herdr_tab_id = "w1:t1" })
      vim.wait = function() end
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          return TOOL_PROC
        end
        return ""
      end)
      assert.is_true(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.are.equal("w1", s.herdr_workspace_id)
      assert.are.equal("w1:t1", s.herdr_tab_id)
    end)

    it("retries `pane run` until process-info shows the tool (F2)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      vim.wait = function() end
      local runs, polls = 0, 0
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          polls = polls + 1
          -- the pane stays idle at its shell until a second injection happens;
          -- the tool only shows up once that attempt has run (R14: still idle,
          -- so re-injecting is safe)
          return runs > 1 and TOOL_PROC or NO_PROC
        end
        if vim.tbl_contains(cmd, "run") then
          runs = runs + 1
        end
        return "" -- pane run accepted
      end)
      assert.is_true(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.are.equal(2, runs)
      assert.is_true(polls > 5)
    end)

    it("still re-injects while the pane stays idle at its baseline shell (F2/R14)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      vim.wait = function() end
      local runs = 0
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          -- foreground never leaves the idle baseline until the tool is up
          return runs >= 2 and TOOL_PROC or NO_PROC
        end
        if vim.tbl_contains(cmd, "run") then
          runs = runs + 1
        end
        return ""
      end)
      assert.is_true(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.are.equal(2, runs)
    end)

    it("re-injects when a nil baseline later shows an idle shell (R14/F1)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      vim.wait = function() end
      local errors = {}
      Util.error = function(msg)
        errors[#errors + 1] = msg
      end
      local polls = 0
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          polls = polls + 1
          -- fresh pane: no foreground process at all through attempt 1, so the
          -- baseline is `nil` and nothing proves the tool started...
          if polls <= 7 then
            return NO_PROC
          end
          -- ...the shell only appears by attempt 2's guard probe. A `nil`
          -- baseline must not be read as "the tool started", so the guard has
          -- to allow a second injection (F1).
          if polls == 8 then
            return SHELL_PROC
          end
          return TOOL_PROC
        end
        return ""
      end)
      assert.is_true(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.is_true(s.started)
      -- the second injection is what finally started the tool
      assert.are.equal(2, #vim.tbl_filter(function(c)
        return vim.tbl_contains(c, "run")
      end, calls))
      assert.is_nil(find_call(calls, { "pane", "close" }))
      assert.are.equal(0, #errors)
    end)

    it("does not re-inject once the foreground changed, but keeps polling to success (R14)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      vim.wait = function() end
      local runs, polls = 0, 0
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          polls = polls + 1
          -- concrete idle-shell baseline (baseline probe + attempt 1's guard)
          if polls <= 2 then
            return SHELL_PROC
          end
          -- attempt 1's injection did start something (foreground changed away
          -- from the baseline) but `proc_running` misses it until later
          return polls >= 9 and TOOL_PROC or OTHER_PROC
        end
        if vim.tbl_contains(cmd, "run") then
          runs = runs + 1
        end
        return ""
      end)
      assert.is_true(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      -- the tool is only observed after the first attempt gave up polling
      assert.is_true(polls >= 9)
      -- ...and crucially the pane was never injected a second time
      assert.are.equal(1, runs)
    end)

    it("does not re-inject when the foreground changed and the tool never appears (R14)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      local errors = {}
      Util.error = function(msg)
        errors[#errors + 1] = msg
      end
      vim.wait = function() end
      local runs, polls = 0, 0
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          polls = polls + 1
          -- concrete idle-shell baseline, then a changed foreground that never
          -- matches the tool: the outcome follows `wait_proc`, not a re-injection
          return polls <= 2 and SHELL_PROC or OTHER_PROC
        end
        if vim.tbl_contains(cmd, "run") then
          runs = runs + 1
        end
        return ""
      end)
      assert.is_false(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.are.equal(1, runs)
      -- exhaustion still clears the cached identity, closes the pane and errors
      assert.is_nil(s.started)
      assert.is_nil(s.herdr_pane_id)
      assert.is_nil(s.herdr_terminal_id)
      assert.are.equal(1, #errors)
      assert.are.same({ "herdr", "--session", "sess", "pane", "close", "w1:p1" }, calls[#calls])
    end)

    it("closes the pane and errors when the process never appears (F2)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      local errors = {}
      Util.error = function(msg)
        errors[#errors + 1] = msg
      end
      vim.wait = function() end
      local runs = 0
      local calls = stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          return NO_PROC
        end
        if vim.tbl_contains(cmd, "run") then
          runs = runs + 1
        end
        return "" -- pane run accepted but nothing comes up
      end)
      assert.is_false(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.is_nil(s.started)
      assert.is_nil(s.herdr_pane_id)
      assert.is_nil(s.herdr_terminal_id)
      assert.are.equal(3, runs)
      assert.are.equal(1, #errors)
      assert.are.same({ "herdr", "--session", "sess", "pane", "close", "w1:p1" }, calls[#calls])
    end)

    it("closes the pane and errors after exhausting retries", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      local errors = {}
      Util.error = function(msg)
        errors[#errors + 1] = msg
      end
      vim.wait = function()
        return true
      end
      local calls = stub_herdr(function()
        return nil
      end)
      assert.is_false(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.is_nil(s.started)
      assert.are.equal(1, #errors)
      assert.are.same({ "herdr", "--session", "sess", "pane", "close", "w1:p1" }, calls[#calls])
    end)

    it("confirms a launch via the injected binary without exhausting or closing (R15)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = q_session()
      vim.wait = function() end
      local errors = {}
      Util.error = function(msg)
        errors[#errors + 1] = msg
      end
      local calls = stub_herdr(function(cmd)
        return vim.tbl_contains(cmd, "process-info") and Q_PROC or ""
      end)
      assert.is_true(s:launch_pane({ pane_id = "w1:p1", terminal_id = "t1" }))
      assert.is_true(s.started)
      -- one injection only: the tool was confirmed, so the pane is neither
      -- re-injected nor closed and no failure is reported
      assert.are.equal(1, #vim.tbl_filter(function(c)
        return vim.tbl_contains(c, "run")
      end, calls))
      assert.is_nil(find_call(calls, { "pane", "close" }))
      assert.are.equal(0, #errors)
    end)
  end)

  describe("add_env()", function()
    it("appends --env for set values", function()
      local s = tool_session({ tool = { env = { A = "1", B = "2" } } })
      local cmd = {}
      s:add_env(cmd)
      table.sort(cmd)
      assert.are.same({ "--env", "--env", "A=1", "B=2" }, cmd)
    end)

    it("skips false values and warns once per session", function()
      local warns = {}
      Util.warn = function(msg)
        warns[#warns + 1] = msg
      end
      local s = tool_session({ tool = { env = { A = false, B = false } } })
      local cmd = {}
      s:add_env(cmd)
      s:add_env(cmd)
      assert.are.same({}, cmd)
      assert.are.equal(1, #warns)
    end)
  end)

  describe("attach()", function()
    it("attaches embedded sessions to their pane", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ herdr_terminal_id = "t1" })
      assert.are.same({ cmd = { "herdr", "--session", "sess", "terminal", "attach", "t1" } }, s:attach())
    end)

    it("returns nil for external sessions", function()
      local s = tool_session({ external = true, herdr_terminal_id = "t1" })
      assert.is_nil(s:attach())
    end)

    it("returns nil and warns once on win32", function()
      local warns = {}
      Util.warn = function(msg)
        warns[#warns + 1] = msg
      end
      vim.fn.has = function(what)
        return what == "win32" and 1 or orig_has(what)
      end
      local s = tool_session({ herdr_terminal_id = "t1" })
      assert.is_nil(s:attach())
      assert.is_nil(s:attach())
      assert.are.equal(1, #warns)
    end)

    it("resolves the terminal_id via pane list when unknown", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session({ herdr_pane_id = "w1:p1" })
      stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1"}]}}'
      end)
      assert.are.same({ cmd = { "herdr", "--session", "sess", "terminal", "attach", "t1" } }, s:attach())
    end)
  end)

  describe("send() / submit() / dump()", function()
    local ids = { herdr_pane_id = "w1:p1", herdr_terminal_id = "t1" }

    it("sends text with `pane send-text`", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session(ids)
      local calls = stub_herdr(function()
        return ""
      end)
      s:send("hello")
      assert.are.same({ "herdr", "--session", "sess", "pane", "send-text", "w1:p1", "hello" }, calls[1])
    end)

    it("sends a focus-in escape first for mux_focus tools", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session(vim.tbl_extend("force", ids, { tool = { mux_focus = true } }))
      local calls = stub_herdr(function()
        return ""
      end)
      s:send("hello")
      assert.are.same({ "herdr", "--session", "sess", "pane", "send-keys", "w1:p1", "Escape", "[", "I" }, calls[1])
      assert.are.same({ "herdr", "--session", "sess", "pane", "send-text", "w1:p1", "hello" }, calls[2])
    end)

    it("submits with `pane send-keys Enter`", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session(ids)
      local calls = stub_herdr(function()
        return ""
      end)
      s:submit()
      assert.are.same({ "herdr", "--session", "sess", "pane", "send-keys", "w1:p1", "Enter" }, calls[1])
    end)

    it("dumps the raw pane read output", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session(ids)
      local calls = stub_herdr(function()
        return "\027[31mraw\027[0m"
      end)
      assert.are.equal("\027[31mraw\027[0m", s:dump())
      assert.are.same({
        "herdr",
        "--session",
        "sess",
        "pane",
        "read",
        "w1:p1",
        "--source",
        "recent-unwrapped",
        "--lines",
        "2000",
        "--ansi",
      }, calls[1])
    end)
  end)

  describe("is_running()", function()
    it("is false when cached ids no longer resolve, and clears the cache (F1/F3)", function()
      local s = tool_session({ herdr_pane_id = "w1:p1", herdr_terminal_id = "t1" })
      stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w9:p9","terminal_id":"t9"}]}}'
      end)
      assert.is_false(s:is_running())
      assert.is_nil(s.herdr_pane_id)
      assert.is_nil(s.herdr_terminal_id)
    end)

    it("is true when the listing still contains the cached pane (F3)", function()
      local s = tool_session({ herdr_pane_id = "w1:p1", herdr_terminal_id = "t1" })
      stub_herdr(function()
        return '{"id":"1","result":{"panes":[{"pane_id":"w1:p1","terminal_id":"t1"}]}}'
      end)
      assert.is_true(s:is_running())
      assert.are.equal("w1:p1", s.herdr_pane_id)
    end)

    it("is false when no pane can be resolved", function()
      local s = tool_session({ herdr_terminal_id = "nope" })
      stub_herdr(function()
        return '{"result":{"panes":[]}}'
      end)
      assert.is_false(s:is_running())
    end)
  end)

  describe("nested_warn() (D6)", function()
    it("warns once when embedded inside herdr", function()
      local warns = {}
      Util.warn = function(msg)
        warns[#warns + 1] = msg
      end
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "terminal"
      local s = tool_session()
      s:nested_warn()
      s:nested_warn()
      assert.are.equal(1, #warns)
    end)

    it("warns once across instances of the same session (F4)", function()
      local warns = {}
      Util.warn = function(msg)
        warns[#warns + 1] = msg
      end
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "terminal"
      tool_session():nested_warn()
      tool_session():nested_warn()
      assert.are.equal(1, #warns)
    end)

    it("does not warn for split/window", function()
      local warns = {}
      Util.warn = function(msg)
        warns[#warns + 1] = msg
      end
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      tool_session():nested_warn()
      assert.are.equal(0, #warns)
    end)
  end)
end)
