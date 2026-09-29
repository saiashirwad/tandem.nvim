local M = {}
local uv = vim.uv
local serial = 0

local function expect(condition, message)
  if not condition then
    error('Invalid session: ' .. message, 0)
  end
end

local function integer(value)
  return type(value) == 'number' and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

local function nonempty(value)
  return type(value) == 'string' and value ~= ''
end

local function position(value)
  expect(type(value) == 'table' and integer(value.line) and integer(value.character), 'invalid position')
  return { line = value.line, character = value.character }
end

local function timestamp(value)
  if type(value) ~= 'string' then
    return false
  end
  local y, m, d, h, min, s, suffix = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$')
  if not y then
    return false
  end
  y, m, d, h, min, s = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(min), tonumber(s)
  local days = {
    31,
    (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  }
  suffix = suffix:gsub('^%.%d+', '')
  local zh, zm = suffix:match('^[+-](%d%d):(%d%d)$')
  local zone = suffix == 'Z' or (zh and tonumber(zh) <= 23 and tonumber(zm) <= 59)
  return zone and days[m] and d >= 1 and d <= days[m] and h <= 23 and min <= 59 and s <= 59
end

function M.anchor(annotation)
  return {
    threadId = annotation.threadId,
    file = annotation.file,
    range = annotation.range and vim.deepcopy(annotation.range) or nil,
    snippet = annotation.snippet,
  }
end

function M.validate(value)
  expect(type(value) == 'table' and type(value.annotations) == 'table', 'expected an annotations array')
  expect(vim.islist(value.annotations), 'annotations must be an array')
  local result, ids, anchors = { annotations = {} }, {}, {}
  for _, item in ipairs(value.annotations) do
    expect(type(item) == 'table', 'annotation must be an object')
    expect(
      nonempty(item.id) and nonempty(item.threadId),
      'annotation and thread IDs must be nonempty strings'
    )
    expect(not ids[item.id], 'duplicate annotation ID: ' .. item.id)
    expect(nonempty(item.file), 'file must be a nonempty relative path')
    expect(
      not item.file:match('^[/\\]') and not item.file:match('^%a:') and not item.file:find('\0', 1, true),
      'invalid file path'
    )
    for part in item.file:gmatch('[^/\\]+') do
      expect(part ~= '..', 'file path must stay inside the project')
    end
    expect(type(item.body) == 'string' and type(item.snippet) == 'string', 'body and snippet must be strings')
    expect(timestamp(item.createdAt), 'createdAt must be an ISO 8601 timestamp')
    local range
    if item.range ~= nil then
      expect(type(item.range) == 'table', 'range must be an object or omitted')
      range = { start = position(item.range.start), ['end'] = position(item.range['end']) }
      local a, b = range.start, range['end']
      expect(
        b.line > a.line or (b.line == a.line and b.character >= a.character),
        'range ends before it starts'
      )
    else
      expect(item.snippet == '', 'whole-file annotations must have an empty snippet')
    end
    local annotation = {
      id = item.id,
      threadId = item.threadId,
      file = item.file,
      range = range,
      snippet = item.snippet,
      body = item.body,
      createdAt = item.createdAt,
    }
    local anchor = M.anchor(annotation)
    expect(
      not anchors[item.threadId] or vim.deep_equal(anchor, anchors[item.threadId]),
      'inconsistent thread anchors'
    )
    ids[item.id], anchors[item.threadId] = true, anchor
    result.annotations[#result.annotations + 1] = annotation
  end
  return result
end

function M.id()
  serial = serial + 1
  local hash =
    vim.fn.sha256(table.concat({ tostring(uv.hrtime()), tostring(uv.os_getpid()), tostring(serial) }, ':'))
  return hash:sub(1, 8)
    .. '-'
    .. hash:sub(9, 12)
    .. '-4'
    .. hash:sub(14, 16)
    .. '-a'
    .. hash:sub(18, 20)
    .. '-'
    .. hash:sub(21, 32)
end

function M.path(root)
  return vim.fs.joinpath(root, '.tandem', 'session.json')
end

local function read(path)
  local fd, err, code = uv.fs_open(path, 'r', 438)
  if not fd then
    if code == 'ENOENT' then
      return nil
    end
    error(err, 0)
  end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat or stat.type ~= 'file' then
    uv.fs_close(fd)
    error(stat_err or 'Session path is not a regular file', 0)
  end
  local source, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not source then
    error(read_err, 0)
  end
  return source
end

function M.load(root)
  local source = read(M.path(root))
  if source == nil then
    return { annotations = {} }, nil
  end
  local ok, value = pcall(vim.json.decode, source)
  if not ok then
    error('Cannot read .tandem/session.json: ' .. tostring(value), 0)
  end
  return M.validate(value), source
end

function M.save(root, data, expected_source)
  data = M.validate(data)
  local path = M.path(root)
  if read(path) ~= expected_source then
    error('Session changed on disk. Reload and try again; your draft is still open.', 0)
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local source = vim.json.encode(data) .. '\n'
  local temp = path .. '.tmp-' .. M.id()
  local fd, open_err = uv.fs_open(temp, 'wx', 384)
  if not fd then
    error(open_err, 0)
  end
  local ok, err = pcall(function()
    local offset = 0
    while offset < #source do
      local written, write_err = uv.fs_write(fd, source:sub(offset + 1), offset)
      if not written or written == 0 then
        error(write_err or 'Could not finish writing session', 0)
      end
      offset = offset + written
    end
    local synced, sync_err = uv.fs_fsync(fd)
    if not synced then
      error(sync_err, 0)
    end
  end)
  local closed, close_err = uv.fs_close(fd)
  if ok and not closed then
    ok, err = false, close_err
  end
  if ok then
    -- Recheck after writing the temporary file, before replacing the shared session.
    ok, err = pcall(function()
      if read(path) ~= expected_source then
        error('Session changed on disk. Reload and try again; your draft is still open.', 0)
      end
      local renamed, rename_err = uv.fs_rename(temp, path)
      if not renamed then
        error(rename_err, 0)
      end
    end)
  end
  if not ok then
    uv.fs_unlink(temp)
    error(err, 0)
  end
  return data, source
end

function M.threads(data)
  local threads, by_id = {}, {}
  for _, annotation in ipairs(data.annotations) do
    local thread = by_id[annotation.threadId]
    if not thread then
      thread = { anchor = M.anchor(annotation), annotations = {} }
      by_id[annotation.threadId] = thread
      threads[#threads + 1] = thread
    end
    thread.annotations[#thread.annotations + 1] = annotation
  end
  return threads, by_id
end

function M.location(anchor)
  if not anchor.range then
    return anchor.file .. ' (file)'
  end
  local first, last = anchor.range.start.line + 1, anchor.range['end'].line + 1
  return anchor.file .. ':' .. first .. (last ~= first and '-' .. last or '')
end

return M
