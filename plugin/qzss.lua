if vim.g.loaded_qzss then
  return
end
vim.g.loaded_qzss = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("qzss.nvim requires Neovim 0.11 or newer", vim.log.levels.ERROR)
  return
end

local function qzss()
  local q = require("qzss")
  if not q._did_setup then
    q.setup()
  end
  return q
end

local cmd = vim.api.nvim_create_user_command

cmd("Qzss", function()
  qzss().toggle()
end, { desc = "Toggle the qzss outline sidebar" })
cmd("QzssOpen", function(a)
  qzss().open({ focus = not a.bang })
end, { bang = true, desc = "Open the qzss outline (! keeps focus in the source)" })
cmd("QzssClose", function()
  qzss().close()
end, { desc = "Close the qzss outline" })
cmd("QzssRefresh", function()
  qzss().refresh()
end, { desc = "Recompute the outline" })
cmd("QzssInfo", function()
  qzss().info()
end, { desc = "Show qzss sources, LSP clients and errors" })
cmd("QzssFilter", function(a)
  qzss().set_filter(a.fargs)
end, {
  nargs = "*",
  desc = "Show only the given kinds (no args clears)",
  complete = function(lead)
    return vim.tbl_filter(function(k)
      return k:find(lead, 1, true) == 1
    end, require("qzss.kinds").list)
  end,
})
