if vim.g.loaded_kiss_sorcar then
  return
end
vim.g.loaded_kiss_sorcar = true

local sorcar = require("kiss-sorcar")

local function report(accepted, err)
  if not accepted and err then
    vim.notify("Sorcar: " .. err, vim.log.levels.ERROR)
  end
end

vim.api.nvim_create_user_command("Sorcar", function(command)
  report(sorcar.open(command.args))
end, { desc = "Open Sorcar client or start task", nargs = "*" })

vim.api.nvim_create_user_command("SorcarStop", function()
  report(sorcar.stop())
end, { desc = "Stop current Sorcar task" })

vim.api.nvim_create_user_command("SorcarSteer", function(command)
  report(sorcar.steer(command.args))
end, { desc = "Steer current Sorcar task", nargs = "+" })
