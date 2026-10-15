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
  return setmetatable(vim.tbl_deep_extend("force", state, overrides or {}), Herdr) --[[@as sidekick.cli.Session]]
end

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

  before_each(function()
    orig_exec = Util.exec
    orig_bin_path = vim.env.HERDR_BIN_PATH
    orig_herdr_env = vim.env.HERDR_ENV
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

  describe("sessions() (P3 boundary)", function()
    it("returns an empty list", function()
      assert.are.same({}, Herdr.sessions())
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
      assert.are.same({ "herdr", "--session", "sess", "pane", "run", "w1:p1", "exec 'tool' 'arg'" }, calls[1])
      assert.are.same({ "herdr", "--session", "sess", "pane", "process-info", "--pane", "w1:p1" }, calls[2])
    end)

    it("retries `pane run` until process-info shows the tool (F2)", function()
      vim.env.HERDR_BIN_PATH = "herdr"
      local s = tool_session()
      vim.wait = function() end
      local runs, polls = 0, 0
      stub_herdr(function(cmd)
        if vim.tbl_contains(cmd, "process-info") then
          polls = polls + 1
          -- the tool only shows up on the second attempt (after PROC_POLLS polls)
          return polls > 5 and TOOL_PROC or NO_PROC
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
