return function(context)
  local api = vim.api
  local session = require('tandem.session')
  local copy = require('tandem.copy')
  local project = require('tandem.project')
  local tandem = require('tandem')
  local annotations = require('tandem.annotations')
  local ui = require('tandem.ui')
  local operations = require('tandem.operations')
  local eq, fails, write = context.eq, context.fails, context.write
  local root
  local function check(name, callback)
    context.test(name, function()
      root = project.canonical(vim.fn.tempname())
      vim.fn.mkdir(root, 'p')
      local data =
        session.validate(vim.json.decode(table.concat(vim.fn.readfile('tests/fixtures/session.json'), '\n')))
      session.save(root, data, nil)
      tandem.setup({ root = root, git_exclude = false })
      local refresh, load, exclude, decorate = ui.refresh, session.load, project.exclude, annotations.decorate
      local ok, err = xpcall(callback, debug.traceback)
      ui.refresh, session.load, project.exclude, annotations.decorate = refresh, load, exclude, decorate
      ui.close_preview()
      vim.cmd.stopinsert()
      for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_config(win).relative ~= '' then
          api.nvim_win_close(win, true)
        else
          api.nvim_set_current_win(win)
        end
      end
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_valid(buf) then
          api.nvim_buf_delete(buf, { force = true })
        end
      end
      vim.cmd('silent only')
      vim.wo.winfixbuf = false
      vim.wait(10, function()
        return false
      end, 1)
      vim.fn.delete(root, 'rf')
      if not ok then
        error(err, 0)
      end
    end)
  end
  check('shared protocol fixture preserves the VS Code export byte-for-byte', function()
    local data =
      session.validate(vim.json.decode(table.concat(vim.fn.readfile('tests/fixtures/session.json'), '\n')))
    eq(copy.format(data), table.concat(vim.fn.readfile('tests/fixtures/session.md'), '\n'))
    eq(session.validate(vim.json.decode(vim.json.encode(data))), data)
  end)

  check('safe Markdown fences and global annotation order match Tandem', function()
    local data = session.load(root)
    local first = vim.deepcopy(data.annotations[1])
    first.snippet = '```\n````\n'
    first.body = 'first'
    local second = vim.deepcopy(first)
    second.id, second.body = 'other', 'second'
    local file = vim.deepcopy(data.annotations[2])
    file.body = 'between'
    local text = copy.format({ annotations = { first, file, second } })
    eq(
      text,
      '## src/emoji.ts:5-6\n\n`````ts\n```\n````\n`````\n\nfirst\n\n## .env\n\nbetween\n\n## src/emoji.ts:5-6\n\nsecond'
    )
    eq(copy.language('.bashrc'), '')
    eq(copy.language('src/.config.lua'), 'lua')
    eq(copy.language('src/file.'), '')
    eq(copy.language('src/example.d.ts'), 'ts')
  end)

  check('atomic save rejects external modification without changing the newer file', function()
    local data, source = session.load(root)
    local newer = vim.deepcopy(data)
    newer.annotations[1].body = 'External edit'
    session.save(root, newer, source)
    fails(function()
      session.save(root, data, source)
    end, 'Session changed on disk')
    eq(session.load(root).annotations[1].body, 'External edit')
    eq(vim.fn.glob(session.path(root) .. '.tmp-*'), '')
  end)

  check(
    'validator rejects duplicate IDs, inconsistent anchors, invalid dates, nulls and traversal',
    function()
      local data = session.load(root)
      local one = vim.deepcopy(data.annotations[1])
      local two = vim.deepcopy(one)
      fails(function()
        session.validate({ annotations = { one, two } })
      end, 'duplicate')
      two.id, two.snippet = 'different', 'different'
      fails(function()
        session.validate({ annotations = { one, two } })
      end, 'inconsistent')
      for _, file in ipairs({ '../escape', '/absolute', 'C:\\absolute', 'a/../b', 'a\\..\\b' }) do
        local bad = vim.deepcopy(one)
        bad.file = file
        fails(function()
          session.validate({ annotations = { bad } })
        end, 'file path')
      end
      local bad = vim.deepcopy(one)
      bad.createdAt = '2026-02-30T12:00:00Z'
      fails(function()
        session.validate({ annotations = { bad } })
      end, 'timestamp')
      bad = vim.deepcopy(one)
      bad.range = vim.NIL
      fails(function()
        session.validate({ annotations = { bad } })
      end, 'range')
      fails(function()
        session.validate(vim.json.decode('{"annotations":{}}'))
      end, 'array')
    end
  )

  check('canonical project paths reject outside files and symlink escapes', function()
    fails(function()
      project.relative(root, root .. '-other/file')
    end, 'Only files inside')
    local outside = vim.fn.tempname()
    write(outside, 'outside')
    assert(vim.uv.fs_symlink(outside, root .. '/escape'))
    fails(function()
      project.file(root, 'escape')
    end, 'Only files inside')
    vim.fn.delete(outside)
  end)

  check('Git exclusion uses the worktree-aware path and is idempotent', function()
    if vim.fn.executable('git') ~= 1 then
      return
    end
    local repo = root .. '/git-project'
    vim.fn.mkdir(repo, 'p')
    assert(vim.system({ 'git', 'init', '-q', repo }):wait().code == 0)
    write(repo .. '/.git/info/exclude', '# keep this without newline')
    project.exclude(repo)
    project.exclude(repo)
    eq(vim.fn.readfile(repo .. '/.git/info/exclude'), { '# keep this without newline', '.tandem/' })
    eq(vim.fn.filereadable(repo .. '/.gitignore'), 0)
    write(repo .. '/file.lua', 'return true\n')
    assert(vim.system({ 'git', '-C', repo, 'add', 'file.lua' }):wait().code == 0)
    assert(vim
      .system({
        'git',
        '-C',
        repo,
        '-c',
        'user.name=Tandem Test',
        '-c',
        'user.email=test@example.invalid',
        '-c',
        'commit.gpgsign=false',
        'commit',
        '-qm',
        'fixture',
      })
      :wait().code == 0)
    local worktree = root .. '/worktree'
    assert(
      vim.system({ 'git', '-C', repo, 'worktree', 'add', '--detach', worktree, 'HEAD' }):wait().code == 0
    )
    project.exclude(worktree)
    eq(vim.fn.readfile(repo .. '/.git/info/exclude'), { '# keep this without newline', '.tandem/' })
    local buf = vim.fn.bufadd(worktree .. '/file.lua')
    local resolved, file = project.resolve(buf, {})
    eq(resolved, worktree)
    eq(file, 'file.lua')
  end)

  check('session operations preserve snapshots and reject stale edits and appends', function()
    local data = session.load(root)
    local original = vim.deepcopy(data.annotations[1])
    operations.edit(data, original, 'replacement')
    local expected = vim.deepcopy(original)
    expected.body = 'replacement'
    eq(data.annotations[1], expected)
    fails(function()
      operations.delete(data, original)
    end, 'changed on disk')
    local anchor = session.anchor(original)
    anchor.snippet = 'changed anchor'
    fails(function()
      operations.append(data, anchor, true, 'reply', 'new-id', original.createdAt)
    end, 'anchor changed')
    operations.delete(data, expected)
    assert(copy.format(data):find(original.snippet, 1, true))
  end)

  check('refresh failures cannot retain or duplicate a committed draft', function()
    write(root .. '/source.lua', 'one\ntwo\n')
    vim.cmd.edit(root .. '/source.lua')
    local before = #session.load(root).annotations
    tandem.annotate(1, 1)
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { 'committed note' })
    ui.refresh = function()
      error('simulated refresh failure')
    end
    vim.cmd.write()
    eq(vim.bo[buf].modified, false)
    -- A second write before the scheduled close must not commit again.
    vim.cmd.write()
    eq(#session.load(root).annotations, before + 1)
    vim.wait(50, function()
      return not api.nvim_buf_is_valid(buf)
    end, 1)
    assert(not api.nvim_buf_is_valid(buf))
  end)

  check('refresh reads once per root and text changes reuse the snapshot', function()
    write(root .. '/one.lua', 'one\n')
    write(root .. '/two.lua', 'two\n')
    vim.cmd.edit(root .. '/one.lua')
    vim.cmd('vsplit ' .. root .. '/two.lua')
    local list = tandem.list()
    tandem.export()
    vim.wait(10, function()
      return false
    end, 1)
    local original, reads = session.load, 0
    session.load = function(...)
      reads = reads + 1
      return original(...)
    end
    tandem.reload()
    eq(reads, 1)
    local buf = vim.fn.bufnr(root .. '/one.lua')
    api.nvim_exec_autocmds('TextChanged', { buffer = buf })
    vim.wait(10, function()
      return false
    end, 1)
    eq(reads, 1)
    assert(api.nvim_buf_is_valid(list))
    api.nvim_exec_autocmds('FocusGained', {})
    eq(reads, 2)
  end)

  check('reused and nested views navigate to the latest source window', function()
    write(root .. '/src/emoji.ts', 'one\ntwo\nthree\nfour\nfive\nsix\n')
    vim.cmd.edit(root .. '/src/emoji.ts')
    local first = api.nvim_get_current_win()
    local list = tandem.list()
    api.nvim_set_current_win(first)
    vim.cmd.vsplit()
    local second = api.nvim_get_current_win()
    eq(tandem.list(), list)
    api.nvim_win_set_cursor(0, { 8, 0 })
    vim.fn.maparg('o', 'n', false, true).callback()
    eq(api.nvim_get_current_win(), second)
    tandem.list()
    api.nvim_win_set_cursor(0, { 8, 0 })
    vim.fn.maparg('<CR>', 'n', false, true).callback()
    vim.fn.maparg('o', 'n', false, true).callback()
    eq(api.nvim_get_current_win(), second)
  end)

  check('exports retain their root, reload content and stay separate across projects', function()
    write(root .. '/source.lua', 'one\n')
    vim.cmd.edit(root .. '/source.lua')
    local source_win = api.nvim_get_current_win()
    tandem.setup({
      root = function(buf)
        return vim.bo[buf].buftype == '' and root or nil
      end,
      git_exclude = false,
    })
    local first = tandem.export()
    eq(vim.b[first].tandem_root, root)
    eq(tandem.copy(), copy.format(session.load(root)))
    local data, text = session.load(root)
    data.annotations[1].body = 'updated export'
    session.save(root, data, text)
    vim.fn.maparg('r', 'n', false, true).callback()
    assert(table.concat(api.nvim_buf_get_lines(first, 0, -1, false), '\n'):find('updated export', 1, true))
    local other = root .. '/other'
    write(other .. '/source.lua', 'other\n')
    api.nvim_set_current_win(source_win)
    tandem.setup({ root = other, git_exclude = false })
    vim.cmd.edit(other .. '/source.lua')
    local second = tandem.export()
    assert(first ~= second)
    eq(vim.b[second].tandem_root, other)
    eq(api.nvim_buf_get_lines(first, 0, 1, false), { '## src/emoji.ts:5-6' })
  end)

  check('reads never exclude Git files and failed preparation is retried', function()
    write(root .. '/source.lua', 'one\n')
    local attempts = 0
    project.exclude = function()
      attempts = attempts + 1
      if attempts == 1 then
        error('temporary exclusion failure')
      end
    end
    tandem.setup({ root = root, git_exclude = true })
    vim.cmd.edit(root .. '/source.lua')
    tandem.list()
    tandem.copy()
    annotations.decorate(vim.fn.bufnr(root .. '/source.lua'), true)
    eq(attempts, 0)
    local code_win
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_buf_get_name(api.nvim_win_get_buf(win)) == root .. '/source.lua' then
        code_win = win
      end
    end
    api.nvim_set_current_win(assert(code_win))
    tandem.annotate(1, 1)
    eq(attempts, 1)
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, { 'retry exclusion on save' })
    vim.fn.maparg('<C-s>', 'n', false, true).callback()
    eq(attempts, 2)
    tandem.annotate(1, 1)
    eq(attempts, 2)
  end)

  check('refreshing one project leaves other projects alone', function()
    local other = root .. '/other'
    write(root .. '/source.lua', 'one\n')
    write(other .. '/source.lua', 'other\n')
    session.save(other, session.load(root), nil)
    tandem.setup({ git_exclude = false })
    vim.cmd.edit(root .. '/source.lua')
    local first_win = api.nvim_get_current_win()
    vim.cmd('vsplit ' .. other .. '/source.lua')
    local other_buf = api.nvim_get_current_buf()
    vim.wait(10, function()
      return false
    end, 1)
    api.nvim_set_current_win(first_win)
    vim.wait(10, function()
      return false
    end, 1)
    local decorate, unrelated = annotations.decorate, 0
    annotations.decorate = function(buf, ...)
      if buf == other_buf then
        unrelated = unrelated + 1
      end
      return decorate(buf, ...)
    end
    local load, reads = session.load, {}
    session.load = function(project_root)
      reads[project_root] = (reads[project_root] or 0) + 1
      return load(project_root)
    end
    tandem.reload()
    eq(unrelated, 0)
    eq(reads, { [root] = 1 })
  end)

  check('external malformed sessions clear marks and show errors until repaired', function()
    write(root .. '/src/emoji.ts', 'one\ntwo\nthree\nfour\nfive\nsix\n')
    vim.cmd.edit(root .. '/src/emoji.ts')
    local code_buf = api.nvim_get_current_buf()
    local list = tandem.list()
    vim.wait(10, function()
      return false
    end, 1)
    local _, source = session.load(root)
    local namespace = api.nvim_get_namespaces()['tandem.annotations']
    assert(#api.nvim_buf_get_extmarks(code_buf, namespace, 0, -1, {}) > 0)
    write(session.path(root), '{broken')
    api.nvim_exec_autocmds('FocusGained', {})
    eq(api.nvim_buf_get_extmarks(code_buf, namespace, 0, -1, {}), {})
    eq(api.nvim_buf_get_lines(list, 0, 1, false), { '# Unable to read session' })
    write(session.path(root), source)
    api.nvim_exec_autocmds('FocusGained', {})
    assert(#api.nvim_buf_get_extmarks(code_buf, namespace, 0, -1, {}) > 0)
    eq(api.nvim_buf_get_lines(list, 0, 1, false), { '# Tandem session' })
  end)

  check('configuration rejects invalid values before opening a buffer', function()
    for key, value in pairs({
      width = 0,
      editor_height = -1,
      list_width = 1.5,
      spell = 'yes',
      git_exclude = 'yes',
      virtual_text = 'yes',
      border = 'invalid',
    }) do
      fails(function()
        tandem.setup({ [key] = value })
      end, key)
    end
    tandem.setup({ root = root, git_exclude = false, border = { '+', '-' } })
  end)
end
