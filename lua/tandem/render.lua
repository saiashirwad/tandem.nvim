local M = {}
local session = require('tandem.session')
local copy = require('tandem.copy')

function M.thread(item)
  if not item then
    return { '# Thread deleted', '', 'Press q to close.' }
  end
  local lines = {
    '# ' .. session.location(item.anchor),
    '',
    'a add · e edit · d delete · o code · r reload · q close',
    '',
  }
  local rows = {}
  for index, annotation in ipairs(item.annotations) do
    local start = #lines + 1
    lines[#lines + 1] = '## ' .. index .. ' · ' .. annotation.createdAt
    lines[#lines + 1] = ''
    vim.list_extend(lines, vim.split(annotation.body, '\n', { plain = true }))
    lines[#lines + 1] = ''
    for row = start, #lines do
      rows[row] = annotation.id
    end
  end
  if item.anchor.range then
    lines[#lines + 1] = '## Original snippet'
    lines[#lines + 1] = ''
    vim.list_extend(
      lines,
      vim.split(copy.fenced(item.anchor.snippet, copy.language(item.anchor.file)), '\n', { plain = true })
    )
  end
  return lines, rows
end

function M.list(root, threads)
  local lines = {
    '# Tandem session',
    '',
    root,
    '',
    '<Enter> thread · o code · a add · e edit · d delete',
    'y copy · r reload · q close',
    '',
  }
  local rows = {}
  for _, item in ipairs(threads) do
    local first = #lines + 1
    lines[#lines + 1] = '## ' .. session.location(item.anchor)
    for _, annotation in ipairs(item.annotations) do
      local summary = annotation.body:gsub('%s+', ' ')
      lines[#lines + 1] = '  ' .. summary
      rows[#lines] = { thread = item.anchor.threadId, annotation = annotation.id }
    end
    rows[first] = { thread = item.anchor.threadId }
    lines[#lines + 1] = ''
  end
  if #threads == 0 then
    lines[#lines + 1] = 'No annotations yet. Select code and run :Tandem annotate.'
  end
  return lines, rows
end

function M.preview(threads, file, target)
  local lines = {}
  for _, item in ipairs(threads) do
    local line = item.anchor.range and item.anchor.range.start.line + 1 or 1
    if item.anchor.file == file and line == target then
      if #lines > 0 then
        lines[#lines + 1] = ''
      end
      lines[#lines + 1] = '# ' .. session.location(item.anchor)
      for _, annotation in ipairs(item.annotations) do
        lines[#lines + 1] = ''
        vim.list_extend(lines, vim.split(annotation.body, '\n', { plain = true }))
      end
    end
  end
  return lines
end

return M
