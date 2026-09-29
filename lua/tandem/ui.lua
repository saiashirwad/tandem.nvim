local M = {}
local api = vim.api
local views = {}
local sequence = 0
local config = {}

function M.notify(message, level)
  vim.notify(tostring(message), level or vim.log.levels.INFO, { title = 'Tandem' })
end

function M.guard(callback)
  return function(...)
    local ok, err = pcall(callback, ...)
    if not ok then
      M.notify(err, vim.log.levels.ERROR)
    end
  end
end

function M.setup(options)
  config = options
end

local function buffer(kind)
  sequence = sequence + 1
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, 'tandem://' .. kind .. '/' .. sequence)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].undofile = false
  vim.b[buf].tandem = true
  return buf
end

local function window_options(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldenable = false
  vim.wo[win].spell = false
  vim.wo[win].winfixbuf = true
  vim.wo[win].conceallevel = 0
end

local function float(buf, title, height, footer)
  local width = math.max(1, math.min(config.width or 76, vim.o.columns - 4))
  height = math.max(1, math.min(height, vim.o.lines - vim.o.cmdheight - 4))
  local border = config.border or 'rounded'
  local bordered = border ~= 'none' and border ~= ''
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    style = 'minimal',
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    border = border,
    title = bordered and (' ' .. title .. ' ') or nil,
    title_pos = bordered and 'left' or nil,
    footer = bordered and footer and (' ' .. footer .. ' ') or nil,
    footer_pos = bordered and 'left' or nil,
  })
  window_options(win)
  return win
end

local preview

function M.close_preview()
  if not preview then
    return
  end
  local previous = preview
  preview = nil
  api.nvim_del_augroup_by_id(previous.group)
  if api.nvim_win_is_valid(previous.win) then
    api.nvim_win_close(previous.win, true)
  end
end

function M.preview(lines)
  M.close_preview()
  local origin = api.nvim_get_current_win()
  local source = api.nvim_get_current_buf()
  local cursor = api.nvim_win_get_cursor(origin)
  local buf = buffer('preview')
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.max(1, math.min(config.width or 76, vim.o.columns - 4))
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  local border = config.border or 'rounded'
  local win = api.nvim_open_win(buf, false, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = math.max(1, math.min(height, 12, math.floor(vim.o.lines / 2))),
    style = 'minimal',
    focusable = false,
    border = border,
    title = border ~= 'none' and border ~= '' and ' Tandem preview ' or nil,
  })
  window_options(win)
  local group = api.nvim_create_augroup('TandemPreview', { clear = true })
  preview = { win = win, group = group }
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    callback = function()
      -- The jump's own delayed CursorMoved event must not dismiss its preview.
      if
        api.nvim_get_current_win() ~= origin
        or api.nvim_get_current_buf() ~= source
        or not vim.deep_equal(api.nvim_win_get_cursor(origin), cursor)
      then
        M.close_preview()
      end
    end,
  })
  api.nvim_create_autocmd({ 'InsertEnter', 'BufLeave', 'WinLeave', 'VimResized', 'TextChanged' }, {
    group = group,
    callback = M.close_preview,
  })
  return win
end

function M.compose(title, body, save, root)
  local origin = api.nvim_get_current_win()
  local buf = buffer('draft')
  vim.b[buf].tandem_root = root
  vim.bo[buf].buftype = 'acwrite'
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body or '', '\n', { plain = true }))
  vim.bo[buf].modified = false
  local win = float(buf, title, config.editor_height or 10, ':w / Ctrl-S save · q cancel (normal mode)')
  vim.wo[win].spell = config.spell == true

  local function close()
    if api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
      api.nvim_buf_delete(buf, { force = true })
    end
    if api.nvim_win_is_valid(origin) then
      api.nvim_set_current_win(origin)
    end
  end

  local saving = false
  local function submit(from_write)
    if saving or not api.nvim_buf_is_valid(buf) then
      return
    end
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if vim.trim(text) == '' then
      M.notify('Write an annotation before saving.', vim.log.levels.WARN)
      return
    end
    local ok, err = pcall(save, text)
    if not ok then
      M.notify(err, vim.log.levels.ERROR)
      return
    end
    saving = true
    vim.bo[buf].modified = false
    vim.cmd.stopinsert()
    -- Let :wq finish in the draft window before restoring the source window.
    if from_write then
      vim.schedule(close)
    else
      close()
    end
  end

  local function cancel()
    if not vim.bo[buf].modified then
      close()
      return
    end
    vim.ui.select(
      { 'Keep editing', 'Discard draft' },
      { prompt = 'Discard this annotation draft?' },
      function(choice)
        if choice == 'Discard draft' then
          close()
        end
      end
    )
  end

  api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      submit(true)
    end,
  })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = buf, desc = 'Save annotation' })
  vim.keymap.set('n', 'q', cancel, { buffer = buf, desc = 'Cancel annotation' })
  vim.keymap.set('n', '<Esc>', cancel, { buffer = buf, desc = 'Cancel annotation' })
  api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
  vim.cmd.startinsert({ bang = true })
  return buf
end

local function refresh(view)
  if not api.nvim_buf_is_valid(view.buf) then
    return
  end
  local ok, lines, rows = pcall(view.render)
  if not ok then
    lines, rows =
      { '# Unable to read session', '', tostring(lines), '', 'Fix session.json, then press r.' }, {}
  end
  view.rows = rows or {}
  local positions = {}
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    positions[win] = api.nvim_win_call(win, vim.fn.winsaveview)
  end
  vim.bo[view.buf].modifiable = true
  api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.bo[view.buf].modified = false
  for win, position in pairs(positions) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_call(win, function()
        vim.fn.winrestview(position)
      end)
    end
  end
end

function M.refresh(root)
  for key, view in pairs(views) do
    if not api.nvim_buf_is_valid(view.buf) then
      views[key] = nil
    elseif view.root == root then
      refresh(view)
    end
  end
end

function M.view(options)
  local previous = views[options.key]
  if previous and api.nvim_buf_is_valid(previous.buf) then
    local win = vim.fn.bufwinid(previous.buf)
    if win ~= -1 then
      previous.render = options.render
      refresh(previous)
      api.nvim_set_current_win(win)
      return previous.buf
    end
  end
  local origin = api.nvim_get_current_win()
  local buf = buffer(options.kind)
  vim.b[buf].tandem_root = options.root
  local view = { buf = buf, root = options.root, render = options.render }
  views[options.key] = view
  refresh(view)
  local win
  if options.kind == 'session' then
    win = api.nvim_open_win(buf, true, {
      split = 'right',
      win = -1,
      width = math.max(1, math.min(config.list_width or 50, math.floor(vim.o.columns / 2))),
    })
    window_options(win)
  else
    win = float(
      buf,
      options.title,
      math.min(24, api.nvim_buf_line_count(buf)),
      options.kind == 'export' and 'yank with normal Vim commands · q close'
        or 'a add · e edit · d delete · o code · q close'
    )
  end
  vim.wo[win].cursorline = true
  local function close()
    api.nvim_buf_delete(buf, { force = true })
    if api.nvim_win_is_valid(origin) then
      api.nvim_set_current_win(origin)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, desc = 'Close Tandem view' })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, desc = 'Close Tandem view' })
  vim.keymap.set('n', 'r', function()
    refresh(view)
  end, { buffer = buf, desc = 'Reload Tandem view' })
  for key, action in pairs(options.actions or {}) do
    vim.keymap.set(
      'n',
      key,
      M.guard(function()
        local row = api.nvim_win_get_cursor(0)[1]
        action(view.rows[row], origin)
      end),
      { buffer = buf, desc = 'Tandem ' .. key }
    )
  end
  return buf
end

function M.export(text)
  return M.view({
    key = 'export',
    kind = 'export',
    title = 'Tandem session export',
    render = function()
      return vim.split(text, '\n', { plain = true })
    end,
  })
end

return M
