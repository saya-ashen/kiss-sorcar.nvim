local Actions = require("kiss-sorcar.actions").Actions
local Controller = require("kiss-sorcar.controller").Controller
local TabLifecycle = require("kiss-sorcar.tab_lifecycle").TabLifecycle
local UI = require("kiss-sorcar.ui").UI

local M = {}
local instance

local function socket_path(options)
  if options.socket_path and options.socket_path ~= "" then
    return vim.fn.expand(options.socket_path)
  end
  if vim.env.KISS_SORCAR_SOCK and vim.env.KISS_SORCAR_SOCK ~= "" then
    return vim.fn.expand(vim.env.KISS_SORCAR_SOCK)
  end
  local home = vim.env.KISS_HOME
  if not home or home == "" then
    home = vim.fn.expand("~/.kiss")
  end
  return home .. "/sorcar.sock"
end

local function workspace(options)
  if options.work_dir and options.work_dir ~= "" then
    local path = vim.fn.fnamemodify(options.work_dir, ":p")
    return path == "/" and path or path:gsub("/$", "")
  end
  return vim.fn.getcwd()
end

---Configure client. Existing instance is closed before replacement.
---@param options? table {socket_path?:string,work_dir?:string,tab_id?:string,connect?:boolean}
---@return table client
function M.setup(options)
  options = options or {}
  if instance then
    M.close()
  end
  local errors = {}
  local work_dir = workspace(options)
  local controller = Controller.new({
    path = socket_path(options),
    work_dir = work_dir,
    on_error = function(err)
      errors[#errors + 1] = tostring(err)
      if instance and instance.ui then
        instance.ui:_schedule_update()
      end
    end,
  })
  local lifecycle = TabLifecycle.new(controller)
  local actions = Actions.new(controller)
  local ui = UI.new({
    actions = actions,
    controller = controller,
    errors = errors,
    run_options = options.run_options,
    tab_id = options.tab_id,
    tab_lifecycle = lifecycle,
    work_dir = work_dir,
  })
  instance = {
    actions = actions,
    controller = controller,
    lifecycle = lifecycle,
    ui = ui,
  }
  if options.connect ~= false then
    local accepted, err = controller:connect()
    if not accepted then
      errors[#errors + 1] = err
    end
  end
  return instance
end

---Return current client, creating default instance when absent.
---@return table client
function M.get()
  return instance or M.setup()
end

---Open UI and optionally submit task text.
---@param task? string
---@return boolean accepted
---@return string|nil error
function M.open(task)
  local client = M.get()
  client.ui:open()
  if task and task ~= "" then
    return client.ui:submit(task)
  end
  return true, nil
end

---Stop current UI task through guarded actions.
---@return boolean accepted
---@return string|nil error
function M.stop()
  return M.get().ui:stop()
end

---Steer current UI task through guarded actions.
---@param prompt string
---@return boolean accepted
---@return string|nil error
function M.steer(prompt)
  return M.get().ui:steer(prompt)
end

---Close client resources.
function M.close()
  if not instance then
    return
  end
  instance.ui:close()
  instance.lifecycle:close()
  instance.controller:close()
  instance = nil
end

return M
