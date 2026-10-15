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

describe("herdr backend", function()
  local orig_exec
  local orig_bin_path
  local orig_herdr_env
  local orig_create
  local orig_jobstart
  local orig_error
  local orig_wait

  before_each(function()
    orig_exec = Util.exec
    orig_bin_path = vim.env.HERDR_BIN_PATH
    orig_herdr_env = vim.env.HERDR_ENV
    orig_create = Config.cli.mux.create
    orig_jobstart = vim.fn.jobstart
    orig_error = Util.error
    orig_wait = vim.wait
  end)

  after_each(function()
    Util.exec = orig_exec
    vim.env.HERDR_BIN_PATH = orig_bin_path
    vim.env.HERDR_ENV = orig_herdr_env
    Config.cli.mux.create = orig_create
    vim.fn.jobstart = orig_jobstart
    Util.error = orig_error
    vim.wait = orig_wait
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
      assert.are.same(
        { error = { code = "workspace_not_found", message = "nope" } },
        Herdr.json({ "herdr" })
      )
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

  describe("lazy methods (P2/P3 boundary)", function()
    it("sessions() returns an empty list", function()
      assert.are.same({}, Herdr.sessions())
    end)

    it("start() and attach() return nil", function()
      local s = new_session({ sid = "s" })
      assert.is_nil(s:start())
      assert.is_nil(s:attach())
    end)

    it("send()/submit()/dump() are honest no-ops", function()
      local s = new_session({ sid = "s" })
      assert.is_nil(s:send("hello"))
      assert.is_nil(s:submit())
      assert.is_nil(s:dump())
    end)

    it("is_running() honestly returns false", function()
      local s = new_session({ sid = "s" })
      assert.is_false(s:is_running())
    end)
  end)
end)
