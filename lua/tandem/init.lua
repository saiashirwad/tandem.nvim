local M = {}
local configured = false

local defaults = {
  root = nil,
  sign = '●',
  virtual_text = false,
  git_exclude = true,
  border = 'rounded',
  width = 76,
  editor_height = 10,
  list_width = 50,
  spell = false,
}

function M.setup(options)
  if vim.fn.has('nvim-0.11') ~= 1 then
    error('tandem.nvim requires Neovim 0.11 or newer')
  end
  local config = vim.tbl_deep_extend('force', defaults, options or {})
  local function expect(condition, message)
    assert(condition, 'Tandem ' .. message)
  end
  expect(
    type(config.sign) == 'string' and vim.fn.strdisplaywidth(config.sign) <= 2,
    'sign must fit in two cells'
  )
  expect(
    config.root == nil or type(config.root) == 'string' or type(config.root) == 'function',
    'root must be a path or function'
  )
  for _, name in ipairs({ 'virtual_text', 'git_exclude', 'spell' }) do
    expect(type(config[name]) == 'boolean', name .. ' must be a boolean')
  end
  for _, name in ipairs({ 'width', 'editor_height', 'list_width' }) do
    local value = config[name]
    expect(
      type(value) == 'number' and value > 0 and value < math.huge and value % 1 == 0,
      name .. ' must be a positive integer'
    )
  end
  local borders = { '', 'none', 'single', 'double', 'rounded', 'solid', 'shadow' }
  local border = config.border
  local valid_border = type(border) == 'string' and vim.tbl_contains(borders, border)
  if type(border) == 'table' and vim.islist(border) and #border > 0 and 8 % #border == 0 then
    valid_border = true
    for _, part in ipairs(border) do
      local text = type(part) == 'table' and part[1] or part
      if type(text) ~= 'string' or vim.fn.strdisplaywidth(text) > 1 then
        valid_border = false
      end
      if type(part) == 'table' and (not vim.islist(part) or #part ~= 2 or type(part[2]) ~= 'string') then
        valid_border = false
      end
    end
  end
  expect(valid_border, 'border must be a supported style or border array')
  require('tandem.annotations').setup(config)
  configured = true
end

function M._ensure_setup()
  if not configured then
    M.setup()
  end
end

local function run(name, ...)
  M._ensure_setup()
  local args = { ... }
  local result
  require('tandem.ui').guard(function()
    result = require('tandem.annotations')[name](unpack(args))
  end)()
  return result
end

function M.annotate(first, last)
  return run('annotate', first, last)
end

function M.annotate_visual()
  local mode = vim.fn.mode()
  local active = mode == 'v' or mode == 'V' or mode == '\22'
  local start = vim.fn.getpos(active and 'v' or "'<")
  local finish = vim.fn.getpos(active and '.' or "'>")
  local regions = vim.fn.getregionpos(start, finish, { type = active and mode or vim.fn.visualmode() })
  if #regions == 0 then
    return
  end
  local first, last = regions[1][1][2], regions[#regions][2][2]
  if active then
    local escape = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
    vim.api.nvim_feedkeys(escape, 'nx', false)
  end
  return M.annotate(first, last)
end

for _, name in ipairs({ 'annotate_file', 'show', 'list', 'copy', 'export', 'clear', 'reload' }) do
  M[name] = function()
    return run(name)
  end
end

function M.next()
  return run('jump', 1)
end

function M.prev()
  return run('jump', -1)
end

local commands = { 'annotate', 'file', 'show', 'list', 'copy', 'export', 'clear', 'next', 'prev', 'reload' }

function M._command(options)
  local action = options.fargs[1] or 'list'
  if #options.fargs > 1 or not vim.tbl_contains(commands, action) then
    vim.notify('Usage: :Tandem ' .. table.concat(commands, '|'), vim.log.levels.ERROR, { title = 'Tandem' })
    return
  end
  if action == 'annotate' then
    if options.range > 0 then
      M.annotate(options.line1, options.line2)
    else
      M.annotate()
    end
  elseif action == 'file' then
    M.annotate_file()
  else
    M[action]()
  end
end

function M._complete(prefix)
  return vim.tbl_filter(function(command)
    return command:sub(1, #prefix) == prefix
  end, commands)
end

return M
