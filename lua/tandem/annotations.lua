local M = {}
local api = vim.api
local session = require('tandem.session')
local project = require('tandem.project')
local copy = require('tandem.copy')
local ui = require('tandem.ui')
local render = require('tandem.render')
local operations = require('tandem.operations')
local namespace = api.nvim_create_namespace('tandem.annotations')
local config = {}
local generations, excluded, reported = {}, {}, {}

local snapshots = {}

local function snapshot(data)
  local threads, by_id = session.threads(data)
  return { data = data, threads = threads, by_id = by_id }
end

local function load(root)
  local ok, data, source = pcall(session.load, root)
  if not ok then
    snapshots[root] = { error = tostring(data) }
    error(data, 0)
  end
  snapshots[root] = snapshot(data)
  return data, source
end

local function prepare(root)
  if not config.git_exclude or excluded[root] then
    return
  end
  local ok, err = pcall(project.exclude, root)
  if ok then
    excluded[root] = true
  else
    ui.notify('Could not exclude .tandem/ from Git: ' .. tostring(err), vim.log.levels.WARN)
  end
end

local function current(require_file)
  local buf = api.nvim_get_current_buf()
  local root, file
  if vim.b[buf].tandem_root and not require_file then
    root = vim.b[buf].tandem_root
  else
    root, file = project.resolve(buf, config)
  end
  if require_file and not file then
    error('Open a named file buffer to annotate code.', 0)
  end
  return root, file, buf
end

local function thread(root, id)
  load(root)
  local found = snapshots[root].by_id[id]
  if not found then
    error('This thread was deleted. Reload the session and select the code again.', 0)
  end
  return found
end

function M.decorate(buf, fresh)
  if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  local ok, root, file = pcall(project.resolve, buf, config)
  if not ok or not file then
    return
  end
  local loaded, data = pcall(function()
    if fresh or not snapshots[root] then
      load(root)
    end
    if snapshots[root].error then
      error(snapshots[root].error, 0)
    end
    return snapshots[root]
  end)
  if not loaded then
    if reported[root] ~= tostring(data) then
      reported[root] = tostring(data)
      ui.notify('Annotations unavailable: ' .. tostring(data), vim.log.levels.WARN)
    end
    return
  end
  reported[root] = nil
  local rows = {}
  for _, item in ipairs(data.threads) do
    local anchor = item.anchor
    if anchor.file == file then
      local row = anchor.range and anchor.range.start.line or 0
      rows[row] = (rows[row] or 0) + #item.annotations
    end
  end
  local count = api.nvim_buf_line_count(buf)
  for row, notes in pairs(rows) do
    if row < count then
      api.nvim_buf_set_extmark(buf, namespace, row, 0, {
        sign_text = config.sign,
        sign_hl_group = 'TandemSign',
        priority = 20,
        virt_text = config.virtual_text and {
          { '  ' .. notes .. ' annotation' .. (notes == 1 and '' or 's'), 'TandemHint' },
        } or nil,
      })
    end
  end
end

local function changed(root, data)
  local state = data and snapshot(data) or snapshots[root]
  snapshots[root] = state
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' then
      local ok, buf_root = pcall(project.resolve, buf, config)
      if ok and buf_root == root then
        M.decorate(buf)
      end
    end
  end
  ui.refresh(root, state)
end

local function refresh_root(root)
  pcall(load, root)
  changed(root)
end

local function publish(root, data)
  local ok, err = pcall(changed, root, data)
  if not ok then
    ui.notify('Session saved, but refresh failed: ' .. tostring(err), vim.log.levels.WARN)
  end
end

local function update(root, change)
  prepare(root)
  local data, source = load(root)
  change(data)
  return session.save(root, data, source)
end

local function choose(items, prompt, format, callback)
  if #items == 0 then
    ui.notify('No annotations here.')
  elseif #items == 1 then
    callback(items[1])
  else
    vim.ui.select(
      items,
      { prompt = prompt, format_item = format },
      ui.guard(function(item)
        if item then
          callback(item)
        end
      end)
    )
  end
end

local function at_cursor(threads, file, line, whole_file)
  local matches = {}
  for _, item in ipairs(threads) do
    local anchor = item.anchor
    local covers = anchor.range and anchor.range.start.line <= line and line <= anchor.range['end'].line
    if anchor.file == file and (whole_file and not anchor.range or not whole_file and covers) then
      matches[#matches + 1] = item
    end
  end
  return matches
end

local function describe(item)
  return session.location(item.anchor) .. ' — ' .. item.annotations[1].body:gsub('%s+', ' '):sub(1, 70)
end

local function compose(root, anchor, existing, source_buf)
  local generation = generations[root] or 0
  local tick = source_buf and api.nvim_buf_get_changedtick(source_buf)
  ui.compose((existing and 'Add to ' or 'Annotate ') .. session.location(anchor), '', function(body)
    if generation ~= (generations[root] or 0) then
      error('The session was cleared while you wrote. Select the code again.', 0)
    end
    -- Returning post-commit work lets the editor finish saving before refreshing UI.
    local data = update(root, function(data)
      operations.append(data, anchor, existing, body, session.id(), os.date('!%Y-%m-%dT%H:%M:%SZ'))
    end)
    return function()
      publish(root, data)
      if
        source_buf
        and api.nvim_buf_is_valid(source_buf)
        and api.nvim_buf_get_changedtick(source_buf) ~= tick
      then
        ui.notify('Saved. Code changed while you wrote; the original snippet was kept.')
      else
        ui.notify('Annotation saved.')
      end
    end
  end, root)
end

function M.annotate(first, last)
  local root, file, buf = current(true)
  local explicit = first ~= nil
  first = first or api.nvim_win_get_cursor(0)[1]
  last = last or first
  if first > last then
    first, last = last, first
  end
  if first < 1 or last > api.nvim_buf_line_count(buf) then
    error('Selection is outside this file.', 0)
  end
  prepare(root)
  load(root)
  local function create()
    local lines = api.nvim_buf_get_lines(buf, first - 1, last, false)
    local anchor = {
      threadId = session.id(),
      file = file,
      range = {
        start = { line = first - 1, character = 0 },
        ['end'] = { line = last - 1, character = vim.str_utfindex(lines[#lines], 'utf-16') },
      },
      snippet = table.concat(lines, vim.bo[buf].fileformat == 'dos' and '\r\n' or '\n'),
    }
    compose(root, anchor, false, buf)
  end
  local matches = not explicit and at_cursor(snapshots[root].threads, file, first - 1, false) or {}
  if #matches == 0 then
    create()
  else
    choose(matches, 'Add to which thread?', describe, function(item)
      compose(root, item.anchor, true)
    end)
  end
end

function M.annotate_file()
  local root, file = current(true)
  prepare(root)
  load(root)
  local matches = at_cursor(snapshots[root].threads, file, 0, true)
  if #matches == 0 then
    compose(root, { threadId = session.id(), file = file, snippet = '' }, false)
  else
    choose(matches, 'Add to which file thread?', describe, function(item)
      compose(root, item.anchor, true)
    end)
  end
end

function M.add(root, id)
  compose(root, thread(root, id).anchor, true)
end

local function select_annotation(root, id, annotation_id, callback)
  local annotations = thread(root, id).annotations
  if annotation_id then
    for _, annotation in ipairs(annotations) do
      if annotation.id == annotation_id then
        callback(annotation)
        return
      end
    end
    error('This annotation was deleted.', 0)
  end
  choose(annotations, 'Which annotation?', function(annotation)
    return annotation.body:gsub('%s+', ' '):sub(1, 100)
  end, callback)
end

function M.edit(root, id, annotation_id)
  select_annotation(root, id, annotation_id, function(original)
    ui.compose('Edit ' .. session.location(original), original.body, function(body)
      local data = update(root, function(data)
        operations.edit(data, original, body)
      end)
      return function()
        publish(root, data)
        ui.notify('Annotation updated.')
      end
    end, root)
  end)
end

function M.delete(root, id, annotation_id)
  select_annotation(root, id, annotation_id, function(original)
    vim.ui.select(
      { 'Keep annotation', 'Delete annotation' },
      { prompt = 'Delete this annotation?' },
      ui.guard(function(choice)
        if choice ~= 'Delete annotation' then
          return
        end
        local data = update(root, function(data)
          operations.delete(data, original)
        end)
        publish(root, data)
        ui.notify('Annotation deleted.')
      end)
    )
  end)
end

function M.open_code(root, anchor, origin)
  local path = project.file(root, anchor.file)
  if vim.fn.filereadable(path) ~= 1 then
    error('File is missing: ' .. anchor.file .. '. Its saved snippet is still in the thread.', 0)
  end
  if origin and api.nvim_win_is_valid(origin) and not vim.wo[origin].winfixbuf then
    api.nvim_set_current_win(origin)
  else
    vim.cmd('botright new')
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  api.nvim_win_set_buf(0, buf)
  local line = anchor.range and anchor.range.start.line + 1 or 1
  api.nvim_win_set_cursor(0, { math.min(line, api.nvim_buf_line_count(buf)), 0 })
  vim.cmd('normal! zz')
end

function M.show_thread(root, id)
  load(root)
  local function render_view(snapshot)
    return render.thread(snapshot.by_id[id])
  end
  return ui.view({
    key = root .. ':' .. id,
    kind = 'thread',
    root = root,
    title = 'Tandem thread',
    render = render_view,
    snapshot = snapshots[root],
    load = function()
      load(root)
      return snapshots[root]
    end,
    actions = {
      a = function()
        M.add(root, id)
      end,
      e = function(annotation_id)
        M.edit(root, id, annotation_id)
      end,
      d = function(annotation_id)
        M.delete(root, id, annotation_id)
      end,
      o = function(_, origin)
        M.open_code(root, thread(root, id).anchor, origin)
      end,
    },
  })
end

function M.show()
  local root, file = current(true)
  load(root)
  local threads = snapshots[root].threads
  local matches = at_cursor(threads, file, api.nvim_win_get_cursor(0)[1] - 1, false)
  vim.list_extend(matches, at_cursor(threads, file, 0, true))
  choose(matches, 'Open which thread?', describe, function(item)
    M.show_thread(root, item.anchor.threadId)
  end)
end

function M.list()
  local root = current(false)
  load(root)
  local function render_view(snapshot)
    return render.list(root, snapshot.threads)
  end
  local function action(callback)
    return function(row, origin)
      if row then
        callback(row, origin)
      end
    end
  end
  return ui.view({
    key = root .. ':session',
    kind = 'session',
    root = root,
    title = 'Tandem session',
    render = render_view,
    snapshot = snapshots[root],
    load = function()
      load(root)
      return snapshots[root]
    end,
    actions = {
      ['<CR>'] = action(function(row)
        M.show_thread(root, row.thread)
      end),
      o = action(function(row, origin)
        M.open_code(root, thread(root, row.thread).anchor, origin)
      end),
      a = action(function(row)
        M.add(root, row.thread)
      end),
      e = action(function(row)
        M.edit(root, row.thread, row.annotation)
      end),
      d = action(function(row)
        M.delete(root, row.thread, row.annotation)
      end),
      y = function()
        M.copy(root)
      end,
    },
  })
end

function M.copy(root)
  root = root or current(false)
  local data = load(root)
  if #data.annotations == 0 then
    ui.notify('No annotations to copy.')
    return
  end
  local text = copy.format(data)
  -- Register 0 always works, including remote Neovim without a clipboard provider.
  vim.fn.setreg('0', text, 'v')
  if vim.fn.has('clipboard') == 1 then
    local ok, err = pcall(vim.fn.setreg, '+', text, 'v')
    if ok and err == 0 then
      ui.notify(
        'Copied ' .. #data.annotations .. ' annotations to register 0; requested system clipboard copy.'
      )
      return text
    end
  end
  ui.notify('Copied to register 0 ("0p). No working system clipboard; :Tandem export opens the text.')
  return text
end

function M.export()
  local root = current(false)
  load(root)
  return ui.export(
    root,
    function(state)
      return copy.format(state.data)
    end,
    snapshots[root],
    function()
      load(root)
      return snapshots[root]
    end
  )
end

function M.clear()
  local root = current(false)
  local original, source = load(root)
  if #original.annotations == 0 then
    ui.notify('No annotations to clear.')
    return
  end
  vim.ui.select(
    { 'Keep session', 'Clear session' },
    { prompt = 'Delete all ' .. #original.annotations .. ' annotations?' },
    ui.guard(function(choice)
      if choice ~= 'Clear session' then
        return
      end
      prepare(root)
      local data = session.save(root, { annotations = {} }, source)
      generations[root] = (generations[root] or 0) + 1
      publish(root, data)
      ui.notify('Session cleared.')
    end)
  )
end

function M.jump(direction)
  ui.close_preview()
  local root, file = current(true)
  local positions, seen = {}, {}
  load(root)
  local threads = snapshots[root].threads
  for _, item in ipairs(threads) do
    if item.anchor.file == file then
      local line = item.anchor.range and item.anchor.range.start.line + 1 or 1
      if not seen[line] and line <= api.nvim_buf_line_count(0) then
        positions[#positions + 1], seen[line] = line, true
      end
    end
  end
  table.sort(positions, function(a, b)
    return direction > 0 and a < b or direction < 0 and a > b
  end)
  if #positions == 0 then
    ui.notify('No annotations in this file.')
    return
  end
  local cursor = api.nvim_win_get_cursor(0)[1]
  local target = positions[1]
  for _, line in ipairs(positions) do
    if (line - cursor) * direction > 0 then
      target = line
      break
    end
  end
  api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd('normal! zvzz')
  ui.preview(render.preview(threads, file, target))
end

function M.reload()
  local root = current(false)
  load(root)
  changed(root)
  ui.notify('Session reloaded.')
end

function M.setup(options)
  config = options
  ui.setup(options)
  local function highlights()
    api.nvim_set_hl(0, 'TandemSign', { default = true, link = 'DiagnosticInfo' })
    api.nvim_set_hl(0, 'TandemHint', { default = true, link = 'Comment' })
  end
  highlights()
  local group = api.nvim_create_augroup('Tandem', { clear = true })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
  api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'TextChanged', 'TextChangedI' }, {
    group = group,
    callback = function(event)
      if vim.bo[event.buf].buftype == '' then
        vim.schedule(ui.guard(function()
          if not api.nvim_buf_is_valid(event.buf) then
            return
          end
          if event.event == 'TextChanged' or event.event == 'TextChangedI' then
            M.decorate(event.buf)
          else
            local ok, root = pcall(project.resolve, event.buf, config)
            if ok then
              refresh_root(root)
            end
          end
        end))
      end
    end,
  })
  api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = ui.guard(function()
      local roots = {}
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' then
          local ok, root = pcall(project.resolve, buf, config)
          if ok and not roots[root] then
            roots[root] = true
            refresh_root(root)
          end
        end
      end
    end),
  })
  vim.schedule(function()
    M.decorate(api.nvim_get_current_buf())
  end)
end

return M
