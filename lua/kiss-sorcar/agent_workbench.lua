local Backend = require("kiss-sorcar.backend")

local M = {}

---Register Sorcar BackendSession with Agent Workbench.
function M.register()
  require("agent-workbench").register_backend("sorcar", function(options)
    return Backend.new(options)
  end)
end

return M
