-- Per-type payload validation for inbound hub envelopes.
--
-- The wire envelope itself (`v`, `id`, `origin`, `kind`, `type`) is
-- already validated by protocol.decode. This module covers what the
-- envelope schema's allOf / if-then blocks pin down: the shape of
-- each `type`-and-`kind` payload.
--
-- The source of truth is the vendored schema at
-- lua/rtlbuddy/schema/hub-protocol-v1.json (copied verbatim from
-- rtl_buddy/src/rtl_buddy/hub/schema/hub-protocol-v1.json). Pure-Lua
-- JSON-Schema validators are heavyweight and not always reliable, so
-- we hand-roll the per-type rules. If a rule disagrees with the JSON
-- schema, the JSON schema wins — fix the rule.
--
-- Per protocol §11 unknown types are silently dropped, so they pass
-- validation here. Loop-prevention / dedupe is the hub's job, not
-- ours.

local M = {}

M._schema_path = nil -- set on first call to validate()
M._reported = {} -- (type .. ":" .. kind) -> true, to dedupe notify spam

local function is_nonempty_string(v)
  return type(v) == "string" and #v > 0
end

local function is_positive_int(v)
  return type(v) == "number" and v == math.floor(v) and v >= 1
end

local function is_nonneg_int(v)
  return type(v) == "number" and v == math.floor(v) and v >= 0
end

local function is_nonempty_string_array(v)
  if type(v) ~= "table" then
    return false
  end
  if #v == 0 then
    return false
  end
  for _, item in ipairs(v) do
    if not is_nonempty_string(item) then
      return false
    end
  end
  return true
end

local function check_object_keys(payload, allowed)
  -- The schema sets additionalProperties: false everywhere. Mirror that.
  local set = {}
  for _, k in ipairs(allowed) do
    set[k] = true
  end
  for k in pairs(payload) do
    if not set[k] then
      return ("payload has unknown field: %s"):format(k)
    end
  end
end

-- Each entry is keyed by `type`; the value is a table keyed by `kind`
-- whose values are validators receiving the payload and returning nil
-- on success or an error string on violation. Unknown `type` is OK
-- (protocol §11). Unknown `kind` for a known `type` is a violation.

local RULES = {}

local function rule(type_, kind, allowed_fields, check)
  RULES[type_] = RULES[type_] or {}
  RULES[type_][kind] = function(payload)
    if type(payload) ~= "table" then
      return "payload must be an object"
    end
    local extra = check_object_keys(payload, allowed_fields)
    if extra then
      return extra
    end
    return check(payload)
  end
end

rule("selection_changed", "event", { "instance_path" }, function(p)
  if p.instance_path == nil then
    return "payload.instance_path missing"
  end
  if type(p.instance_path) == "string" then
    if #p.instance_path == 0 then
      return "payload.instance_path must be non-empty"
    end
    return nil
  end
  if not is_nonempty_string_array(p.instance_path) then
    return "payload.instance_path must be a non-empty string or array of non-empty strings"
  end
end)

rule("signal_selected", "event", { "signal", "wave_scope" }, function(p)
  if not is_nonempty_string(p.signal) then
    return "payload.signal must be a non-empty string"
  end
  if not is_nonempty_string(p.wave_scope) then
    return "payload.wave_scope must be a non-empty string"
  end
end)

rule("cursor_time_changed", "event", { "t_fs" }, function(p)
  if not is_nonempty_string(p.t_fs) then
    return "payload.t_fs must be a non-empty string"
  end
  if not p.t_fs:match("^%-?[0-9]+$") then
    return "payload.t_fs must match /^-?[0-9]+$/ (decimal-encoded fs)"
  end
end)

rule("scope_changed", "event", { "wave_scope" }, function(p)
  if not is_nonempty_string(p.wave_scope) then
    return "payload.wave_scope must be a non-empty string"
  end
end)

rule("source_focused", "event", { "file", "line", "col" }, function(p)
  if not is_nonempty_string(p.file) then
    return "payload.file must be a non-empty string"
  end
  if not is_positive_int(p.line) then
    return "payload.line must be a positive integer"
  end
  if not is_positive_int(p.col) then
    return "payload.col must be a positive integer"
  end
end)

rule("open_source", "request", { "file", "line", "col" }, function(p)
  if not is_nonempty_string(p.file) then
    return "payload.file must be a non-empty string"
  end
  if not is_positive_int(p.line) then
    return "payload.line must be a positive integer"
  end
  if not is_positive_int(p.col) then
    return "payload.col must be a positive integer"
  end
end)
rule("open_source", "response", { "ok" }, function(p)
  if type(p.ok) ~= "boolean" then
    return "payload.ok must be a boolean"
  end
end)

rule("wave_add_variables", "request", { "variables" }, function(p)
  if not is_nonempty_string_array(p.variables) then
    return "payload.variables must be a non-empty array of non-empty strings"
  end
end)
rule("wave_add_variables", "response", { "ids" }, function(p)
  if type(p.ids) ~= "table" then
    return "payload.ids must be an array of non-negative integers"
  end
  for i, v in ipairs(p.ids) do
    if not is_nonneg_int(v) then
      return ("payload.ids[%d] must be a non-negative integer"):format(i - 1)
    end
  end
end)

rule("wave_set_scope", "request", { "wave_scope" }, function(p)
  if not is_nonempty_string(p.wave_scope) then
    return "payload.wave_scope must be a non-empty string"
  end
end)
rule("wave_set_scope", "response", { "ok" }, function(p)
  if type(p.ok) ~= "boolean" then
    return "payload.ok must be a boolean"
  end
end)

rule("wave_set_cursor", "request", { "t_fs" }, function(p)
  if not is_nonempty_string(p.t_fs) or not p.t_fs:match("^%-?[0-9]+$") then
    return "payload.t_fs must match /^-?[0-9]+$/"
  end
end)
rule("wave_set_cursor", "response", { "ok" }, function(p)
  if type(p.ok) ~= "boolean" then
    return "payload.ok must be a boolean"
  end
end)

rule("view_pan_to", "request", { "instance_path" }, function(p)
  if not is_nonempty_string(p.instance_path) then
    return "payload.instance_path must be a non-empty string"
  end
end)
rule("view_pan_to", "response", { "ok" }, function(p)
  if type(p.ok) ~= "boolean" then
    return "payload.ok must be a boolean"
  end
end)

rule("resolve_view_to_wave", "request", { "instance_path" }, function(p)
  if not is_nonempty_string(p.instance_path) then
    return "payload.instance_path must be a non-empty string"
  end
end)
rule("resolve_view_to_wave", "response", { "wave_scope" }, function(p)
  if not is_nonempty_string(p.wave_scope) then
    return "payload.wave_scope must be a non-empty string"
  end
end)

rule("resolve_signal_to_view", "request", { "signal", "wave_scope" }, function(p)
  if not is_nonempty_string(p.signal) then
    return "payload.signal must be a non-empty string"
  end
  if not is_nonempty_string(p.wave_scope) then
    return "payload.wave_scope must be a non-empty string"
  end
end)
rule("resolve_signal_to_view", "response", { "instance_path", "port" }, function(p)
  if not is_nonempty_string_array(p.instance_path) then
    return "payload.instance_path must be a non-empty array of non-empty strings"
  end
  if not is_nonempty_string(p.port) then
    return "payload.port must be a non-empty string"
  end
end)

rule("hello", "request", { "client", "version", "capabilities" }, function(p)
  local valid_origin = { view = true, wave = true, src = true, cli = true }
  if not valid_origin[p.client] then
    return "payload.client must be one of view|wave|src|cli"
  end
  if not is_nonempty_string(p.version) then
    return "payload.version must be a non-empty string"
  end
  if type(p.capabilities) ~= "table" then
    return "payload.capabilities must be an array"
  end
  local seen = {}
  for i, cap in ipairs(p.capabilities) do
    if not is_nonempty_string(cap) then
      return ("payload.capabilities[%d] must be a non-empty string"):format(i - 1)
    end
    if seen[cap] then
      return ("payload.capabilities[%d] duplicates earlier item"):format(i - 1)
    end
    seen[cap] = true
  end
end)

rule("welcome", "response", { "server_version", "registered_clients" }, function(p)
  if not is_nonempty_string(p.server_version) then
    return "payload.server_version must be a non-empty string"
  end
  if type(p.registered_clients) ~= "table" then
    return "payload.registered_clients must be an array"
  end
  local valid_origin = { view = true, wave = true, src = true, cli = true }
  local seen = {}
  for i, c in ipairs(p.registered_clients) do
    if not valid_origin[c] then
      return ("payload.registered_clients[%d] must be one of view|wave|src|cli"):format(i - 1)
    end
    if seen[c] then
      return ("payload.registered_clients[%d] duplicate"):format(i - 1)
    end
    seen[c] = true
  end
end)

-- `bye` accepts either no payload or an empty object.
RULES["bye"] = {
  event = function(payload)
    if payload == nil then
      return nil
    end
    if type(payload) ~= "table" then
      return "payload must be null or empty object"
    end
    for _ in pairs(payload) do
      return "payload must be empty object"
    end
  end,
}

rule("error", "error", { "code", "message", "context" }, function(p)
  local codes =
    { unresolvable = true, not_connected = true, bad_request = true, protocol_mismatch = true }
  if not codes[p.code] then
    return "payload.code must be one of unresolvable|not_connected|bad_request|protocol_mismatch"
  end
  if not is_nonempty_string(p.message) then
    return "payload.message must be a non-empty string"
  end
  if p.context ~= nil and type(p.context) ~= "table" then
    return "payload.context must be an object"
  end
end)

-- The schema file itself; loaded lazily on first call to ensure_schema_loaded
-- so import is cheap and tests can clear it.
function M.ensure_schema_loaded()
  if M._schema_path then
    return M._schema_path
  end
  local src = debug.getinfo(1, "S").source:sub(2) -- "@/abs/path/schema.lua" → "/abs/path/schema.lua"
  local dir = src:match("(.*)/")
  M._schema_path = dir .. "/schema/hub-protocol-v1.json"
  return M._schema_path
end

-- Validate one envelope's payload against the per-type rules.
-- Returns nil on success, an error string on violation.
function M.validate(env)
  M.ensure_schema_loaded()
  if type(env) ~= "table" then
    return "envelope must be a table"
  end
  local rules_for_type = RULES[env.type]
  if not rules_for_type then
    return nil
  end -- unknown type: drop per §11
  local validator = rules_for_type[env.kind]
  if not validator then
    return ("kind=%s not allowed for type=%s"):format(tostring(env.kind), tostring(env.type))
  end
  return validator(env.payload)
end

-- Wrapper used by hub.lua. On the first failure of each (type, kind)
-- pair within an nvim session, emits a vim.notify WARN; subsequent
-- failures of the same shape are silent so a chatty bug does not
-- flood the message area. Returns true on valid, false on violation
-- (the caller drops the message either way; we still surface it once).
function M.validate_or_report(env)
  local err = M.validate(env)
  if not err then
    return true
  end
  local key = tostring(env and env.type) .. ":" .. tostring(env and env.kind)
  if not M._reported[key] then
    M._reported[key] = true
    vim.schedule(function()
      vim.notify(
        ("rtlbuddy: schema violation [%s/%s]: %s"):format(
          tostring(env and env.type),
          tostring(env and env.kind),
          err
        ),
        vim.log.levels.WARN
      )
    end)
  end
  return false
end

-- Test helper: forget previously-reported failures so a test can
-- observe a notify on a key the previous test already used.
function M._reset_reported()
  M._reported = {}
end

return M
