---@module 'luassert'

local Select = require("sidekick.cli.ui.select")

local CWD = "/tmp/proj"

---Build a minimal `sidekick.cli.State`-shaped table for `Select.format`.
---@param opts table
---@return table
local function state(opts)
  return {
    attached = false,
    started = true,
    installed = true,
    external = opts.external,
    tool = { name = opts.tool or "opencode" },
    session = vim.tbl_extend("force", { backend = opts.backend or "herdr", cwd = CWD }, opts.session or {}),
  }
end

---A discovered herdr session: external, source name `default` in `mux_session`.
---@param session table
---@return table
local function herdr(session)
  return state({ external = true, session = vim.tbl_extend("force", { mux_session = "default" }, session) })
end

---Fully rendered row text (the `format_item` path).
---@param s table
---@return string
local function row(s)
  return table.concat(vim.tbl_map(function(p)
    return p[1]
  end, Select.format(s)))
end

---The `[...]` mux token in the row.
---@param s table
---@return string
local function token(s)
  return row(s):match("%[[^%]]*%]") or ""
end

---1-based display column where the right-aligned cwd column starts.
---@param s table
---@return integer
local function cwd_col(s)
  local w = 0
  for _, p in ipairs(Select.format(s)) do
    if p[2] == "Directory" then
      break
    end
    w = w + vim.api.nvim_strwidth(p[1])
  end
  return w + 1
end

describe("cli select format", function()
  describe("mux token fallback (unchanged backends)", function()
    local cases = {
      { "tmux", state({ external = true, backend = "tmux", tool = "qwen", session = { mux_session = "work" } }) },
      { "zellij", state({ external = true, backend = "zellij", tool = "qwen", session = { mux_session = "dev" } }) },
      {
        "terminal child",
        state({
          external = false,
          backend = "terminal",
          session = { mux_backend = "herdr", mux_session = "default" },
        }),
      },
      { "terminal", state({ external = false, backend = "terminal", tool = "qwen" }) },
      { "opencode", state({ external = true, backend = "opencode", session = { mux_session = "12345" } }) },
      { "herdr without label", herdr({}) },
    }
    local expected = {
      "[tmux:work]",
      "[zellij:dev]",
      "[herdr]",
      "[terminal]",
      "[opencode:12345]",
      "[herdr:default]",
    }
    for i, case in ipairs(cases) do
      it(case[1], function()
        assert.are.equal(expected[i], token(case[2]))
      end)
    end
  end)

  describe("herdr display label", function()
    it("shows the workspace/tab/pane label instead of the session name", function()
      assert.are.equal("[herdr:w7 · t2T · p77]", token(herdr({ mux_label = "w7 · t2T · p77" })))
    end)

    it("distinguishes panes sharing a workspace, tab and cwd", function()
      local a = token(herdr({ mux_label = "w7 · t2T · p76" }))
      local b = token(herdr({ mux_label = "w7 · t2T · p77" }))
      assert.are_not.equal(a, b)
    end)

    it("keeps a label of exactly the budget width intact", function()
      -- a 10-column workspace label: `Alpha Site · 2 · p77` is 20 columns == the herdr budget
      assert.are.equal("[herdr:Alpha Site · 2 · p77]", token(herdr({ mux_label = "Alpha Site · 2 · p77" })))
    end)

    it("shortens a long workspace but keeps the tab and pane segments", function()
      -- 21 columns: one past the budget, so the leading segment gives way
      assert.are.equal("[herdr:Alpha Si… · 12 · p77]", token(herdr({ mux_label = "Alpha Site · 12 · p77" })))
    end)

    it("keeps panes sharing a workspace, tab and cwd distinct past the budget", function()
      local a = token(herdr({ mux_label = "Alpha Site · 12 · p76" }))
      local b = token(herdr({ mux_label = "Alpha Site · 12 · p77" }))
      assert.are.equal("[herdr:Alpha Si… · 12 · p76]", a)
      assert.are.equal("[herdr:Alpha Si… · 12 · p77]", b)
      assert.are_not.equal(a, b)
    end)

    it("keeps the trailing pane id of a long workspace label", function()
      local s = herdr({ mux_label = "internal_service_repo · 1 · p77" })
      assert.are.equal("[herdr:internal_… · 1 · p77]", token(s))
      assert.is_true(vim.api.nvim_strwidth(token(s)) <= 28)
    end)

    it("truncates a CJK workspace without splitting a wide character", function()
      local s = herdr({ mux_label = "网络配置服务集群 · 1 · p77" })
      -- 4 of the 8 wide chars fit (8 cols) + the ellipsis; the 5th would overflow
      assert.are.equal("[herdr:网络配置… · 1 · p77]", token(s))
      assert.is_true(vim.api.nvim_strwidth(token(s)) <= 28)
      assert.are.equal("p77", token(s):match("(%w+)%]$"))
    end)

    it("never splits a wide (CJK) character in half", function()
      assert.are.equal(
        "[herdr:OC | ABC DEF字字字…]",
        token(herdr({ mux_label = "OC | ABC DEF字字字字字字字字" }))
      )
    end)

    it("falls back to the session name for an empty label", function()
      assert.are.equal("[herdr:default]", token(herdr({ mux_label = "" })))
    end)

    it("keeps the cwd column aligned with the fallback rows", function()
      local labeled = herdr({ mux_label = "w7 · t2T · p77" })
      local plain = state({ external = true, backend = "tmux", tool = "qwen", session = { mux_session = "work" } })
      assert.are.equal(cwd_col(plain), cwd_col(labeled))
    end)

    it("keeps the cwd column aligned when the label is truncated", function()
      -- a full-budget token must not shift the cwd column of the other rows
      local plain = state({ external = true, backend = "tmux", tool = "qwen", session = { mux_session = "work" } })
      for _, label in ipairs({
        "Alpha Site · 12 · p77",
        "internal_service_repo · 1 · p77",
        "网络配置服务集群 · 1 · p77",
      }) do
        assert.are.equal(cwd_col(plain), cwd_col(herdr({ mux_label = label })))
      end
    end)
  end)

  describe("degradation (never errors)", function()
    it("ignores non-string labels", function()
      assert.are.equal("[herdr:default]", token(herdr({ mux_label = true })))
    end)

    it("ignores a nil label", function()
      assert.are.equal("[herdr:default]", token(herdr({ mux_label = nil })))
    end)
  end)
end)
