-- Event bus behind `require("qzss").subscribe()`. Private module.
--
-- Contract (documented in docs/api.md#events):
-- * Callbacks run in the main loop, in subscription order.
-- * A callback that raises is reported once per error through vim.notify and
--   never prevents the remaining callbacks from running.
-- * Re-entrancy: an event emitted from inside a callback is queued and
--   dispatched after the current dispatch finishes (FIFO), so callbacks never
--   nest and ordering is preserved.
-- * Subscribing or unsubscribing inside a callback is safe. A listener removed
--   during a dispatch is not called afterwards; a listener added during a
--   dispatch only receives later events.
-- * Each listener receives its own deep copy of the payload, so mutating it
--   cannot affect other listeners or qzss itself.
local M = {}

M.names = { "symbols", "open", "close", "mode", "state" }
local valid = {}
for _, n in ipairs(M.names) do
  valid[n] = true
end
valid["*"] = true

local listeners = {} -- ordered list of { id, event, fn, active }
local next_id = 0
local queue = {}
local dispatching = false

function M.is_event(name)
  return valid[name] == true
end

function M.subscribe(event, fn)
  next_id = next_id + 1
  local l = { id = next_id, event = event, fn = fn, active = true }
  table.insert(listeners, l)
  return l.id
end

function M.unsubscribe(id)
  for i, l in ipairs(listeners) do
    if l.id == id then
      l.active = false
      table.remove(listeners, i)
      return true
    end
  end
  return false
end

function M.count()
  return #listeners
end

local function report(event, err)
  vim.schedule(function()
    vim.notify(("qzss: subscriber for '%s' failed: %s"):format(event, err), vim.log.levels.ERROR)
  end)
end

local function dispatch(event, payload)
  local snapshot = {}
  for _, l in ipairs(listeners) do
    if l.event == event or l.event == "*" then
      table.insert(snapshot, l)
    end
  end
  for _, l in ipairs(snapshot) do
    if l.active then
      local p = vim.deepcopy(payload)
      p.event = event
      local ok, err = xpcall(l.fn, debug.traceback, p)
      if not ok then
        report(event, err)
      end
    end
  end
end

function M.emit(event, payload)
  table.insert(queue, { event, payload or {} })
  if dispatching then
    return
  end
  dispatching = true
  while #queue > 0 do
    local item = table.remove(queue, 1)
    local ok, err = pcall(dispatch, item[1], item[2])
    if not ok then
      report(item[1], err)
    end
  end
  dispatching = false
end

-- tests only
function M._reset()
  listeners, queue, dispatching = {}, {}, false
end

return M
