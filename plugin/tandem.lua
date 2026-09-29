if vim.g.loaded_tandem then
  return
end
vim.g.loaded_tandem = true

vim.api.nvim_create_user_command('Tandem', function(options)
  require('tandem')._command(options)
end, {
  nargs = '*',
  range = true,
  complete = function(prefix)
    return require('tandem')._complete(prefix)
  end,
  desc = 'Annotate code and manage the Tandem session',
})

local maps = {
  Annotate = 'annotate',
  AnnotateFile = 'annotate_file',
  Show = 'show',
  List = 'list',
  Copy = 'copy',
  Next = 'next',
  Prev = 'prev',
}
for plug, method in pairs(maps) do
  vim.keymap.set('n', '<Plug>(Tandem' .. plug .. ')', function()
    require('tandem')[method]()
  end, { desc = 'Tandem ' .. method })
end
vim.keymap.set('x', '<Plug>(TandemAnnotate)', function()
  require('tandem').annotate_visual()
end, { desc = 'Annotate selected lines' })

if vim.fn.has('nvim-0.11') == 1 then
  require('tandem')._ensure_setup()
end
