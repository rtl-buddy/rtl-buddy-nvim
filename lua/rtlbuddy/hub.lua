-- TCP client to rtl-buddy-hub. Line-delimited JSON; one envelope per
-- line. Reconnects with exponential backoff. Hub-incoming requests are
-- dispatched via on_request callback; responses to our own requests fire
-- the per-id callback registered with `request()`.
local proto = require("rtlbuddy.protocol")
local discovery = require("rtlbuddy.discovery")

local M = {}
M.__index = M

local PLUGIN_VERSION = "0.1.0"
local CAPABILITIES = { "open_source", "source_focused" }

local STATE_DISCONNECTED = "disconnected"
local STATE_CONNECTING = "connecting"
local STATE_HANDSHAKE = "handshake"
local STATE_READY = "ready"

local INITIAL_BACKOFF_MS = 500
local MAX_BACKOFF_MS = 30000

function M.new(opts)
  local self = setmetatable({}, M)
  self.state = STATE_DISCONNECTED
  self.handle = nil
  self.buffer = ""
  self.pending = {}        -- id -> callback(env, err)
  self.on_request = opts and opts.on_request or function() end
  self.on_event = opts and opts.on_event or function() end
  self.on_state_change = opts and opts.on_state_change or function() end
  self.server_version = nil
  self.registered_clients = {}
  self.last_error = nil
  self.last_endpoint = nil
  self.backoff_ms = INITIAL_BACKOFF_MS
  self.reconnect_timer = nil
  self.auto_reconnect = true
  return self
end

local function set_state(self, state)
  if self.state == state then return end
  self.state = state
  pcall(self.on_state_change, state)
end

local function schedule_reconnect(self)
  if not self.auto_reconnect then return end
  if self.reconnect_timer then return end
  local delay = self.backoff_ms
  self.backoff_ms = math.min(self.backoff_ms * 2, MAX_BACKOFF_MS)
  self.reconnect_timer = vim.uv.new_timer()
  self.reconnect_timer:start(delay, 0, function()
    if self.reconnect_timer then
      self.reconnect_timer:close()
      self.reconnect_timer = nil
    end
    vim.schedule(function() M.connect(self) end)
  end)
end

local function teardown(self, err)
  if self.handle and not self.handle:is_closing() then
    self.handle:close()
  end
  self.handle = nil
  self.buffer = ""
  for id, cb in pairs(self.pending) do
    pcall(cb, nil, err or "connection closed")
    self.pending[id] = nil
  end
  self.last_error = err
  set_state(self, STATE_DISCONNECTED)
  schedule_reconnect(self)
end

local function dispatch_line(self, line)
  local ok, env = pcall(proto.decode, line)
  if not ok then
    vim.schedule(function()
      vim.notify("rtlbuddy: malformed frame: " .. tostring(env), vim.log.levels.DEBUG)
    end)
    return
  end

  if env.kind == proto.KIND.RESPONSE or env.kind == proto.KIND.ERROR then
    local cb = self.pending[env.id]
    if cb then
      self.pending[env.id] = nil
      vim.schedule(function() cb(env, nil) end)
    end
    return
  end

  if env.kind == proto.KIND.REQUEST then
    vim.schedule(function()
      local ok2, result = pcall(self.on_request, env)
      if not ok2 then
        result = { ok = false, error = tostring(result) }
      end
      M.send(self, proto.response(env.id, env.type, result or { ok = true }))
    end)
    return
  end

  if env.kind == proto.KIND.EVENT then
    vim.schedule(function() pcall(self.on_event, env) end)
  end
end

local function on_chunk(self, chunk)
  self.buffer = self.buffer .. chunk
  while true do
    local nl = self.buffer:find("\n", 1, true)
    if not nl then break end
    local line = self.buffer:sub(1, nl - 1)
    self.buffer = self.buffer:sub(nl + 1)
    if #line > 0 then
      dispatch_line(self, line)
    end
  end
end

local function start_handshake(self)
  set_state(self, STATE_HANDSHAKE)
  local hello = proto.hello(PLUGIN_VERSION, CAPABILITIES)
  self.pending[hello.id] = function(env, err)
    if err or not env or env.kind == proto.KIND.ERROR then
      teardown(self, err or (env and env.payload and env.payload.message) or "hello failed")
      return
    end
    self.server_version = env.payload and env.payload.server_version
    self.registered_clients = (env.payload and env.payload.registered_clients) or {}
    self.backoff_ms = INITIAL_BACKOFF_MS
    set_state(self, STATE_READY)
  end
  M.send(self, hello)
end

function M.connect(self)
  if self.state == STATE_CONNECTING or self.state == STATE_HANDSHAKE or self.state == STATE_READY then
    return
  end
  local loc = discovery.locate()
  if loc.error then
    self.last_error = loc.error
    set_state(self, STATE_DISCONNECTED)
    schedule_reconnect(self)
    return
  end
  self.last_endpoint = string.format("%s:%d", loc.host, loc.port)

  set_state(self, STATE_CONNECTING)
  local handle = vim.uv.new_tcp()
  self.handle = handle
  handle:connect(loc.host, loc.port, function(err)
    if err then
      vim.schedule(function() teardown(self, "connect: " .. err) end)
      return
    end
    handle:read_start(function(rerr, data)
      if rerr then
        vim.schedule(function() teardown(self, "read: " .. rerr) end)
        return
      end
      if not data then
        vim.schedule(function() teardown(self, "eof") end)
        return
      end
      vim.schedule(function() on_chunk(self, data) end)
    end)
    vim.schedule(function() start_handshake(self) end)
  end)
end

function M.send(self, env)
  if not self.handle or self.handle:is_closing() then
    return false, "not connected"
  end
  self.handle:write(proto.encode(env) .. "\n")
  return true
end

-- Send a request and invoke cb(env, err) on response/error/timeout.
function M.request(self, env, cb, timeout_ms)
  if self.state ~= STATE_READY then
    vim.schedule(function() cb(nil, "hub not ready (state=" .. self.state .. ")") end)
    return
  end
  self.pending[env.id] = cb
  local ok, err = M.send(self, env)
  if not ok then
    self.pending[env.id] = nil
    vim.schedule(function() cb(nil, err) end)
    return
  end
  if timeout_ms and timeout_ms > 0 then
    local t = vim.uv.new_timer()
    t:start(timeout_ms, 0, function()
      t:close()
      vim.schedule(function()
        local pending = self.pending[env.id]
        if pending then
          self.pending[env.id] = nil
          pending(nil, "timeout")
        end
      end)
    end)
  end
end

function M.disconnect(self)
  self.auto_reconnect = false
  if self.reconnect_timer then
    self.reconnect_timer:close()
    self.reconnect_timer = nil
  end
  if self.handle and not self.handle:is_closing() then
    pcall(function() M.send(self, proto.bye()) end)
  end
  teardown(self, "user disconnect")
end

function M.status(self)
  return {
    state = self.state,
    server_version = self.server_version,
    registered_clients = self.registered_clients,
    last_error = self.last_error,
    endpoint = self.last_endpoint,
  }
end

return M
