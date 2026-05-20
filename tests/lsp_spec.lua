-- Tests for the LSP bridge. Exercises resolve_declaration's three
-- paths: no-LSP (nil), declaration response, definition fallback.
local lsp = require("rtlbuddy.lsp")

local function with_stub(target_tbl, key, replacement, body)
  local original = target_tbl[key]
  target_tbl[key] = replacement
  local ok, err = pcall(body)
  target_tbl[key] = original
  if not ok then
    error(err)
  end
end

-- Build a stub LSP client. By default it claims to support every
-- method (matches the pre-supports_method behaviour); pass a set of
-- supported method names to constrain it for capability-gating tests.
local function fake_client(name, supported)
  return {
    name = name,
    supports_method = function(_self, method)
      if supported == nil then
        return true
      end
      return supported[method] == true
    end,
  }
end

describe("rtlbuddy.lsp.resolve_declaration", function()
  it("returns nil when no LSP client is attached", function()
    with_stub(vim.lsp, "get_clients", function()
      return {}
    end, function()
      assert.is_nil(lsp.resolve_declaration(0))
    end)
  end)

  it("returns the declaration Location when LSP answers textDocument/declaration", function()
    local saw_method
    with_stub(vim.lsp, "get_clients", function()
      return { fake_client("verible") }
    end, function()
      with_stub(vim.lsp.util, "make_position_params", function()
        return {}
      end, function()
        with_stub(vim.lsp, "buf_request_sync", function(_, method, _, _)
          saw_method = method
          if method == "textDocument/declaration" then
            return {
              [1] = {
                result = {
                  uri = "file:///tmp/decl.sv",
                  range = {
                    ["start"] = { line = 41, character = 6 },
                    ["end"] = { line = 41, character = 9 },
                  },
                },
              },
            }
          end
          return {}
        end, function()
          local loc = lsp.resolve_declaration(0)
          assert.are.equal("textDocument/declaration", saw_method)
          assert.are.equal("/tmp/decl.sv", loc.file)
          assert.are.equal(42, loc.line) -- 1-based
          assert.are.equal(7, loc.col) -- 1-based
        end)
      end)
    end)
  end)

  it("falls back to textDocument/definition when declaration returns empty", function()
    local methods_tried = {}
    with_stub(vim.lsp, "get_clients", function()
      return { fake_client("verible") }
    end, function()
      with_stub(vim.lsp.util, "make_position_params", function()
        return {}
      end, function()
        with_stub(vim.lsp, "buf_request_sync", function(_, method, _, _)
          table.insert(methods_tried, method)
          if method == "textDocument/declaration" then
            return { [1] = { result = nil } }
          end
          if method == "textDocument/definition" then
            -- LocationLink shape, single (not array).
            return {
              [1] = {
                result = {
                  targetUri = "file:///abs/path/defn.sv",
                  targetSelectionRange = { ["start"] = { line = 9, character = 4 } },
                  targetRange = { ["start"] = { line = 9, character = 0 } },
                },
              },
            }
          end
          return {}
        end, function()
          local loc = lsp.resolve_declaration(0)
          assert.are.same({ "textDocument/declaration", "textDocument/definition" }, methods_tried)
          assert.are.equal("/abs/path/defn.sv", loc.file)
          assert.are.equal(10, loc.line)
          assert.are.equal(5, loc.col)
        end)
      end)
    end)
  end)

  it("returns nil when both methods return empty", function()
    with_stub(vim.lsp, "get_clients", function()
      return { fake_client("verible") }
    end, function()
      with_stub(vim.lsp.util, "make_position_params", function()
        return {}
      end, function()
        with_stub(vim.lsp, "buf_request_sync", function()
          return { [1] = { result = {} } }
        end, function()
          assert.is_nil(lsp.resolve_declaration(0))
        end)
      end)
    end)
  end)

  it("skips buf_request_sync for methods the attached clients don't support", function()
    -- Reproduces the verible-LSP case: declaration is not in the
    -- server capabilities, only definition is. Without the
    -- supports_method gate, nvim emits a user-visible "method X is
    -- not supported" notification before falling through to
    -- definition. The gate filters declaration out of the loop
    -- entirely, so buf_request_sync is only invoked for definition.
    local methods_tried = {}
    local verible = fake_client("verible", { ["textDocument/definition"] = true })
    with_stub(vim.lsp, "get_clients", function()
      return { verible }
    end, function()
      with_stub(vim.lsp.util, "make_position_params", function()
        return {}
      end, function()
        with_stub(vim.lsp, "buf_request_sync", function(_, method, _, _)
          table.insert(methods_tried, method)
          if method == "textDocument/definition" then
            return {
              [1] = {
                result = {
                  uri = "file:///rtl/fifo.sv",
                  range = { ["start"] = { line = 0, character = 0 } },
                },
              },
            }
          end
          return {}
        end, function()
          local loc = lsp.resolve_declaration(0)
          assert.are.same({ "textDocument/definition" }, methods_tried)
          assert.are.equal("/rtl/fifo.sv", loc.file)
        end)
      end)
    end)
  end)

  it("returns nil when no attached client supports either method", function()
    -- Edge case: an LSP attached but it answers no for everything. We
    -- shouldn't call buf_request_sync at all, and we shouldn't crash.
    local minimal = fake_client("nothing-supported", {})
    local saw_request = false
    with_stub(vim.lsp, "get_clients", function()
      return { minimal }
    end, function()
      with_stub(vim.lsp.util, "make_position_params", function()
        return {}
      end, function()
        with_stub(vim.lsp, "buf_request_sync", function()
          saw_request = true
          return {}
        end, function()
          assert.is_nil(lsp.resolve_declaration(0))
          assert.is_false(saw_request)
        end)
      end)
    end)
  end)
end)
