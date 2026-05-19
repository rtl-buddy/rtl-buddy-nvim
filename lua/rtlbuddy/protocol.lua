-- Hub protocol v1 envelope codec.
-- Wire contract: line-delimited JSON over TCP. Envelope shape and the
-- catalog of `type` values are frozen in rtl-buddy-view#19 /
-- src/rtl_buddy/hub/schema/hub-protocol-v1.json.
local M = {}

M.PROTOCOL_VERSION = 1

M.ORIGIN = { VIEW = "view", WAVE = "wave", SRC = "src", CLI = "cli" }
M.KIND = { EVENT = "event", REQUEST = "request", RESPONSE = "response", ERROR = "error" }

local VALID_ORIGIN = { view = true, wave = true, src = true, cli = true }
local VALID_KIND = { event = true, request = true, response = true, error = true }

-- RFC 4122 v4 UUID. vim.uv has no UUID helper; math.random is seeded
-- in init.lua so successive calls within one nvim session do not collide.
function M.new_id()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end))
end

-- Build an envelope dict. Caller fills payload (may be nil).
function M.envelope(origin, kind, type_, payload, id)
  assert(VALID_ORIGIN[origin], "bad origin: " .. tostring(origin))
  assert(VALID_KIND[kind], "bad kind: " .. tostring(kind))
  assert(type(type_) == "string" and #type_ > 0, "bad type")
  local env = {
    v = M.PROTOCOL_VERSION,
    id = id or M.new_id(),
    origin = origin,
    kind = kind,
    type = type_,
  }
  if payload ~= nil then
    env.payload = payload
  end
  return env
end

-- Decode one wire line into an envelope table; raises on malformed input.
-- Schema strictness mirrors the hub: we check envelope shape, not
-- type-specific payloads (those are validated by the server).
function M.decode(line)
  if type(line) ~= "string" or #line == 0 then
    error("rtlbuddy.protocol: empty frame")
  end
  local ok, env = pcall(vim.json.decode, line)
  if not ok or type(env) ~= "table" then
    error("rtlbuddy.protocol: invalid JSON")
  end
  if env.v ~= M.PROTOCOL_VERSION then
    error("rtlbuddy.protocol: version mismatch: " .. tostring(env.v))
  end
  if not VALID_ORIGIN[env.origin] then
    error("rtlbuddy.protocol: bad origin: " .. tostring(env.origin))
  end
  if not VALID_KIND[env.kind] then
    error("rtlbuddy.protocol: bad kind: " .. tostring(env.kind))
  end
  if type(env.type) ~= "string" or #env.type == 0 then
    error("rtlbuddy.protocol: bad type")
  end
  if type(env.id) ~= "string" or #env.id == 0 then
    error("rtlbuddy.protocol: bad id")
  end
  return env
end

function M.encode(env)
  return vim.json.encode(env)
end

-- Convenience constructors used throughout the plugin. Origin is always
-- "src" — that's the contract the hub uses to suppress echo-back to us.

function M.hello(version, capabilities)
  return M.envelope(M.ORIGIN.SRC, M.KIND.REQUEST, "hello", {
    client = M.ORIGIN.SRC,
    version = version,
    capabilities = capabilities or {},
  })
end

function M.source_focused(file, line, col)
  return M.envelope(M.ORIGIN.SRC, M.KIND.EVENT, "source_focused", {
    file = file,
    line = line,
    col = col,
  })
end

function M.wave_add_variables(variables)
  return M.envelope(M.ORIGIN.SRC, M.KIND.REQUEST, "wave_add_variables", {
    variables = variables,
  })
end

function M.view_pan_to(instance_path)
  return M.envelope(M.ORIGIN.SRC, M.KIND.REQUEST, "view_pan_to", {
    instance_path = instance_path,
  })
end

function M.resolve_signal_to_view(signal, wave_scope)
  return M.envelope(M.ORIGIN.SRC, M.KIND.REQUEST, "resolve_signal_to_view", {
    signal = signal,
    wave_scope = wave_scope,
  })
end

function M.response(in_reply_to, type_, payload)
  return M.envelope(M.ORIGIN.SRC, M.KIND.RESPONSE, type_, payload, in_reply_to)
end

function M.bye()
  return M.envelope(M.ORIGIN.SRC, M.KIND.EVENT, "bye")
end

return M
