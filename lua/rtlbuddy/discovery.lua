-- Locate the running hub by walking up from CWD looking for
-- <project>/.rtl-buddy/hub.json. RTL_BUDDY_HUB env var overrides.
-- Mirrors rtl_buddy/src/rtl_buddy/hub/discovery.py.
local M = {}

local ENV_OVERRIDE = "RTL_BUDDY_HUB"
local HUB_DIR_NAME = ".rtl-buddy"
local HUB_DISCOVERY_FILENAME = "hub.json"

-- What marks a project root, in the order rtl_buddy's own
-- discover_project_root walks for them.
local ROOT_MARKERS = { "root_config.yaml", ".git" }

local function read_json(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return nil
  end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not data then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok then
    return nil
  end
  return decoded
end

-- Walk from `start` up to the filesystem root, returning the first non-nil
-- `probe(dir)`. Shared by hub discovery and project-root finding: the two walk
-- identically and differ only in what they are looking for.
local function walk_up(start, probe)
  local cur = vim.fs.normalize(start)
  while cur and cur ~= "" do
    local hit = probe(cur)
    if hit then
      return hit
    end
    local parent = vim.fs.dirname(cur)
    if not parent or parent == cur then
      return nil
    end
    cur = parent
  end
  return nil
end

local function find_discovery(start)
  return walk_up(start, function(dir)
    local candidate = dir .. "/" .. HUB_DIR_NAME .. "/" .. HUB_DISCOVERY_FILENAME
    if vim.uv.fs_stat(candidate) then
      return candidate
    end
    return nil
  end)
end

-- The project root above `start`: the nearest ancestor carrying a marker from
-- ROOT_MARKERS, or nil when `start` is in no project at all. This is the
-- directory an `rb` subprocess must be run in, since that is what decides
-- which project's artefacts the verb discovers — the hub is not involved, so
-- it is found by markers rather than from hub.json.
function M.project_root(start)
  return walk_up(start or vim.uv.cwd(), function(dir)
    for _, marker in ipairs(ROOT_MARKERS) do
      if vim.uv.fs_stat(dir .. "/" .. marker) then
        return dir
      end
    end
    return nil
  end)
end

-- Returns { host, port, pid, server_version, project_root, source } on
-- success; { error = string } on failure. `source` is the path that was
-- read (or "env" if RTL_BUDDY_HUB was used).
function M.locate(cwd)
  local override = vim.env[ENV_OVERRIDE]
  if override and override ~= "" then
    local host, port = override:match("^([^:]+):(%d+)$")
    if not host then
      return { error = "RTL_BUDDY_HUB must be host:port, got: " .. override }
    end
    return { host = host, port = tonumber(port), source = "env" }
  end

  cwd = cwd or vim.uv.cwd()
  local path = find_discovery(cwd)
  if not path then
    return { error = "no .rtl-buddy/hub.json found (walked up from " .. cwd .. ")" }
  end

  local record = read_json(path)
  if type(record) ~= "table" or type(record.tcp) ~= "string" then
    return { error = "malformed hub.json at " .. path }
  end

  local host, port = record.tcp:match("^([^:]+):(%d+)$")
  if not host then
    return { error = "hub.json tcp field is not host:port: " .. record.tcp }
  end

  return {
    host = host,
    port = tonumber(port),
    pid = record.pid,
    server_version = record.server_version,
    project_root = record.project_root,
    source = path,
  }
end

return M
