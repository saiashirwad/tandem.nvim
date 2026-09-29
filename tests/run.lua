vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.hidden = true
vim.o.columns = 120
vim.o.lines = 40
vim.g.clipboard = {
  name = 'Tandem test provider',
  copy = { ['+'] = { 'sh', '-c', 'exit 1' }, ['*'] = { 'sh', '-c', 'exit 1' } },
  paste = {
    ['+'] = function()
      return {}
    end,
    ['*'] = function()
      return {}
    end,
  },
  cache_enabled = 0,
}
vim.cmd('runtime plugin/tandem.lua')

local api = vim.api
local session = require('tandem.session')
local copy = require('tandem.copy')
local tandem = require('tandem')
local annotations = require('tandem.annotations')
local project = require('tandem.project')
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local root = project.canonical(temp)
local messages = {}
vim.notify = function(message)
  messages[#messages + 1] = tostring(message)
end
local original_select = vim.ui.select
vim.ui.select = function(items, _, callback)
  callback(items[#items])
end
local count = 0

local function eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(
      (label or 'Values differ')
        .. '\nexpected: '
        .. vim.inspect(expected)
        .. '\nactual: '
        .. vim.inspect(actual)
    )
  end
end

local function fails(callback, pattern)
  local ok, err = pcall(callback)
  assert(not ok, 'Expected failure')
  assert(tostring(err):find(pattern, 1, true), tostring(err))
end

local function test(name, callback)
  local has, rename = vim.fn.has, vim.uv.fs_rename
  local ok, err = xpcall(callback, debug.traceback)
  vim.fn.has, vim.uv.fs_rename = has, rename
  if not ok then
    error(err, 0)
  end
  count = count + 1
  print('ok ' .. count .. ' - ' .. name)
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local file = assert(io.open(path, 'wb'))
  assert(file:write(text))
  assert(file:close())
end

local function draft(text)
  assert(api.nvim_buf_get_name(0):find('tandem://draft/', 1, true), 'Expected an annotation editor')
  local buf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.cmd.write()
  vim.cmd.stopinsert()
  vim.wait(50, function()
    return not api.nvim_buf_is_valid(buf)
  end, 1)
end

local function run()
  dofile('tests/checks.lua')({ test = test, eq = eq, fails = fails, write = write })
  tandem.setup({ root = root, git_exclude = false })

  -- One complete annotation journey shares its session across the following steps.
  write(root .. '/sample.lua', 'first\nlocal smile = "🙂"\nlast\n')
  vim.cmd.edit(vim.fn.fnameescape(root .. '/sample.lua'))
  local code_buf, code_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local function code()
    api.nvim_set_current_win(code_win)
    api.nvim_win_set_buf(code_win, code_buf)
  end

  test('command range captures whole lines, multiline body and UTF-16 end columns', function()
    vim.cmd('2,2Tandem annotate')
    draft('Why this value?\nA second line.')
    local data = session.load(root)
    eq(#data.annotations, 1)
    eq(data.annotations[1].snippet, 'local smile = "🙂"')
    eq(
      data.annotations[1].range,
      { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 18 } }
    )
    eq(data.annotations[1].body, 'Why this value?\nA second line.')
    eq(vim.bo[code_buf].modified, false, 'Annotating must not edit the source')
    local ns = api.nvim_get_namespaces()['tandem.annotations']
    eq(#api.nvim_buf_get_extmarks(code_buf, ns, 0, -1, {}), 1)
  end)

  test('annotation jumps preview without focus and dismiss on movement or insert', function()
    code()
    api.nvim_win_set_cursor(code_win, { 1, 0 })
    local function preview_win()
      for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_buf_get_name(api.nvim_win_get_buf(win)):find('tandem://preview/', 1, true) then
          return win
        end
      end
    end
    tandem.next()
    eq(api.nvim_get_current_win(), code_win)
    eq(api.nvim_win_get_cursor(code_win), { 2, 0 })
    local win = assert(preview_win())
    eq(api.nvim_win_get_config(win).focusable, false)
    local text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), '\n')
    assert(text:find('Why this value?', 1, true))
    api.nvim_exec_autocmds('CursorMoved', {})
    assert(api.nvim_win_is_valid(win), 'Jump event must not close preview')
    tandem.prev()
    assert(not api.nvim_win_is_valid(win), 'Repeated jump replaces preview')
    win = assert(preview_win())
    api.nvim_win_set_cursor(code_win, { 3, 0 })
    api.nvim_exec_autocmds('CursorMoved', {})
    assert(not api.nvim_win_is_valid(win))
    tandem.next()
    win = assert(preview_win())
    api.nvim_exec_autocmds('InsertEnter', {})
    assert(not api.nvim_win_is_valid(win))
    eq(vim.bo[code_buf].modified, false)
  end)

  test('normal-mode annotate appends to a thread; editing preserves its ID, time and snapshot', function()
    code()
    api.nvim_win_set_cursor(0, { 2, 0 })
    tandem.annotate()
    draft('Answer')
    local data = session.load(root)
    eq(data.annotations[1].threadId, data.annotations[2].threadId)
    local original = vim.deepcopy(data.annotations[1])
    annotations.edit(root, original.threadId, original.id)
    draft('Edited\nStill multiline')
    data = session.load(root)
    original.body = 'Edited\nStill multiline'
    eq(data.annotations[1], original)
    eq(
      copy.format(data),
      '## sample.lua:2\n\n```lua\nlocal smile = "🙂"\n```\n\nEdited\nStill multiline\n\n## sample.lua:2\n\nAnswer'
    )
  end)

  test('file annotations omit range and use an empty snippet', function()
    code()
    tandem.annotate_file()
    draft('About this file')
    local data = session.load(root)
    eq(data.annotations[3].range, nil)
    eq(data.annotations[3].snippet, '')
    tandem.annotate_file()
    draft('More about this file')
    data = session.load(root)
    eq(data.annotations[3].threadId, data.annotations[4].threadId)
  end)

  test('snapshots survive edits while composing and extmark positions remain fixed', function()
    code()
    tandem.annotate(3, 3)
    api.nvim_buf_set_lines(code_buf, 0, 0, false, { 'inserted' })
    draft('Original last line')
    local data = session.load(root)
    eq(data.annotations[5].snippet, 'last')
    eq(data.annotations[5].range.start.line, 2)
    local ns = api.nvim_get_namespaces()['tandem.annotations']
    local marks = api.nvim_buf_get_extmarks(code_buf, ns, 0, -1, {})
    local rows = vim.tbl_map(function(mark)
      return mark[2]
    end, marks)
    table.sort(rows)
    eq(rows, { 0, 1, 2 })
  end)

  test('explicit overlapping selection creates a new thread; chooser can append to it', function()
    code()
    tandem.annotate(2, 3)
    draft('Overlap')
    local data = session.load(root)
    assert(data.annotations[6].threadId ~= data.annotations[1].threadId)
    api.nvim_win_set_cursor(code_win, { 2, 0 })
    tandem.annotate()
    draft('Chosen overlapping thread')
    data = session.load(root)
    eq(data.annotations[7].threadId, data.annotations[6].threadId)
  end)

  test('session split and thread float provide working navigation and editing actions', function()
    code()
    local list = tandem.list()
    assert(vim.b[list].tandem)
    assert(not vim.bo[list].modifiable)
    local lines = api.nvim_buf_get_lines(list, 0, -1, false)
    assert(table.concat(lines, '\n'):find('Edited Still multiline', 1, true))
    api.nvim_win_set_cursor(0, { 9, 0 })
    local mapping = vim.fn.maparg('<CR>', 'n', false, true)
    mapping.callback()
    assert(api.nvim_buf_get_name(0):find('tandem://thread/', 1, true))
    assert(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Original snippet', 1, true))
    local edit = vim.fn.maparg('e', 'n', false, true)
    api.nvim_win_set_cursor(0, { 5, 0 })
    edit.callback()
    draft('Edited from thread view')
    eq(session.load(root).annotations[1].body, 'Edited from thread view')
    vim.fn.maparg('q', 'n', false, true).callback()
    code()
  end)

  test('deleted first annotation re-emits the snippet for the next annotation', function()
    local data = session.load(root)
    annotations.delete(root, data.annotations[1].threadId, data.annotations[1].id)
    data = session.load(root)
    eq(data.annotations[1].body, 'Answer')
    assert(copy.format(data):find('```lua\nlocal smile = "🙂"\n```', 1, true))
  end)

  test('copy falls back to register 0 and export is available without a clipboard', function()
    code()
    local expected = copy.format(session.load(root))
    local has = vim.fn.has
    vim.fn.has = function(feature)
      return feature == 'clipboard' and 0 or has(feature)
    end
    tandem.copy()
    vim.fn.has = has
    eq(vim.fn.getreg('0'), expected)
    local buf = tandem.export()
    eq(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n'), expected)
    vim.fn.maparg('q', 'n', false, true).callback()
  end)

  test('a failing clipboard provider retains the register without claiming delivery', function()
    code()
    local expected = copy.format(session.load(root))
    vim.cmd('silent! lua require("tandem").copy()')
    eq(vim.fn.getreg('0'), expected)
    assert(messages[#messages]:find('requested system clipboard copy', 1, true))
    assert(not messages[#messages]:find('to the clipboard', 1, true))
  end)

  test('stale annotation edit preserves the external edit and keeps the draft', function()
    code()
    local data, source = session.load(root)
    annotations.edit(root, data.annotations[1].threadId, data.annotations[1].id)
    local draft_buf = api.nvim_get_current_buf()
    data.annotations[1].body = 'Newer external edit'
    session.save(root, data, source)
    draft('Stale local edit')
    eq(api.nvim_get_current_buf(), draft_buf)
    eq(session.load(root).annotations[1].body, 'Newer external edit')
    api.nvim_buf_delete(draft_buf, { force = true })
    code()
  end)

  test('malformed sessions are preserved and recover on reload', function()
    local _, source = session.load(root)
    write(session.path(root), '{broken')
    fails(function()
      session.load(root)
    end, 'Cannot read')
    tandem.annotate(1, 1)
    eq(api.nvim_get_current_buf(), code_buf)
    eq(table.concat(vim.fn.readfile(session.path(root)), '\n'), '{broken')
    write(session.path(root), source)
    tandem.reload()
  end)

  test('missing files retain readable thread snapshots', function()
    local data, source = session.load(root)
    local note = vim.deepcopy(data.annotations[1])
    note.file, note.id, note.threadId = 'missing.lua', session.id(), session.id()
    data.annotations[#data.annotations + 1] = note
    session.save(root, data, source)
    annotations.show_thread(root, note.threadId)
    assert(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Original snippet', 1, true))
    fails(function()
      annotations.open_code(root, note, code_win)
    end, 'File is missing')
    vim.fn.maparg('q', 'n', false, true).callback()
    code()
  end)

  test('CRLF snapshots preserve line endings without a final newline', function()
    vim.bo[code_buf].fileformat = 'dos'
    tandem.annotate(1, 2)
    draft('DOS lines')
    local data = session.load(root)
    eq(data.annotations[#data.annotations].snippet, 'inserted\r\nfirst')
    vim.bo[code_buf].fileformat = 'unix'
  end)

  test('native :wq and :x save without closing the source window', function()
    for _, command in ipairs({ 'wq', 'x' }) do
      code()
      tandem.annotate(1, 1)
      local buf = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(buf, 0, -1, false, { 'Saved via :' .. command })
      vim.cmd.stopinsert()
      vim.cmd(command)
      vim.wait(50, function()
        return not api.nvim_buf_is_valid(buf)
      end, 1)
      assert(api.nvim_win_is_valid(code_win), 'Saving closed the source window')
      local data = session.load(root)
      eq(data.annotations[#data.annotations].body, 'Saved via :' .. command)
    end
  end)

  test('insert-mode Ctrl-S saves and normal-mode q cancels a changed draft', function()
    code()
    tandem.annotate(1, 1)
    local buf = api.nvim_get_current_buf()
    vim.cmd.stopinsert()
    local keys = api.nvim_replace_termcodes('iSaved from the keyboard<C-s>', true, false, true)
    api.nvim_feedkeys(keys, 'xt', false)
    assert(not api.nvim_buf_is_valid(buf))
    local data, original = session.load(root)
    eq(data.annotations[#data.annotations].body, 'Saved from the keyboard')
    code()
    tandem.annotate(1, 1)
    buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { 'Discard this draft' })
    vim.fn.maparg('q', 'n', false, true).callback()
    assert(not api.nvim_buf_is_valid(buf))
    local _, after = session.load(root)
    eq(after, original)
  end)

  test('visual mapping handles reversed, exclusive and blockwise selections and empty lines', function()
    code()
    api.nvim_buf_set_lines(code_buf, 0, -1, false, { 'one', 'two', 'three', '' })
    local function selected(keys, row, selection, expected)
      code()
      vim.o.selection = selection
      api.nvim_win_set_cursor(0, { row, 0 })
      vim.cmd('normal! ' .. keys)
      tandem.annotate_visual()
      draft('Visual selection')
      local data = session.load(root)
      eq(data.annotations[#data.annotations].snippet, expected)
    end
    selected('Vk', 3, 'inclusive', 'two\nthree')
    selected('vj0', 1, 'exclusive', 'one')
    selected('vj0', 1, 'inclusive', 'one\ntwo')
    selected('\22jj', 1, 'inclusive', 'one\ntwo\nthree')
    code()
    tandem.annotate(4, 4)
    draft('An empty source line')
    local data = session.load(root)
    eq(data.annotations[#data.annotations].snippet, '')
    eq(data.annotations[#data.annotations].range['end'].character, 0)
  end)

  test('failed filesystem replacement preserves both the session and draft', function()
    code()
    local _, original = session.load(root)
    tandem.annotate(1, 1)
    local buf = api.nvim_get_current_buf()
    local rename = vim.uv.fs_rename
    vim.uv.fs_rename = function()
      return nil, 'simulated rename failure'
    end
    draft('Keep my unsaved annotation')
    vim.uv.fs_rename = rename
    eq(api.nvim_get_current_buf(), buf)
    assert(vim.bo[buf].modified)
    local _, current_source = session.load(root)
    eq(current_source, original)
    eq(vim.fn.glob(session.path(root) .. '.tmp-*'), '')
    draft('Retry after storage recovers')
    assert(not api.nvim_buf_is_valid(buf))
  end)

  test('non-file buffers are rejected without opening a draft', function()
    code()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(code_win, buf)
    fails(function()
      annotations.annotate()
    end, 'named file buffer')
    vim.bo[buf].buftype = ''
    api.nvim_buf_set_name(buf, 'scp://example.test/source.lua')
    fails(function()
      annotations.annotate()
    end, 'named file buffer')
    code()
    api.nvim_buf_delete(buf, { force = true })
  end)

  test('clear session preserves walk/review files and invalidates an open draft', function()
    write(root .. '/.tandem/walk.json', '{"title":"untouched","steps":[]}')
    write(root .. '/.tandem/review.json', '{"title":"untouched","steps":[]}')
    code()
    tandem.annotate(1, 1)
    local draft_buf = api.nvim_get_current_buf()
    code()
    tandem.clear()
    eq(session.load(root).annotations, {})
    eq(vim.json.decode(table.concat(vim.fn.readfile(session.path(root)), '\n')).annotations, {})
    eq(vim.fn.readfile(root .. '/.tandem/walk.json'), { '{"title":"untouched","steps":[]}' })
    eq(vim.fn.readfile(root .. '/.tandem/review.json'), { '{"title":"untouched","steps":[]}' })
    local win = vim.fn.bufwinid(draft_buf)
    api.nvim_set_current_win(win)
    draft('Must not resurrect cleared session')
    eq(api.nvim_get_current_buf(), draft_buf)
    eq(session.load(root).annotations, {})
    api.nvim_buf_delete(draft_buf, { force = true })
  end)
end

local ok, err = xpcall(run, debug.traceback)
vim.ui.select = original_select
vim.fn.delete(temp, 'rf')
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  io.stderr:write('Notifications: ' .. vim.inspect(messages) .. '\n')
  vim.cmd('cquit 1')
else
  print('Passed ' .. count .. ' integration checks')
  vim.cmd('qa!')
end
