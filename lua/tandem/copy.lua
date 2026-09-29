local M = {}

function M.language(file)
  local basename = file:match('[^/\\]+$') or file
  local stem, extension = basename:match('^(.*)%.([^.]*)$')
  return stem and stem ~= '' and extension or ''
end

function M.fenced(code, language)
  if code == '' then
    return ''
  end
  local fence = '```'
  while code:find(fence, 1, true) do
    fence = fence .. '`'
  end
  return fence .. (language or '') .. '\n' .. code .. (code:sub(-1) == '\n' and '' or '\n') .. fence
end

function M.format(data)
  local blocks, printed = {}, {}
  for _, annotation in ipairs(data.annotations) do
    local location = annotation.file
    if annotation.range then
      local first, last = annotation.range.start.line + 1, annotation.range['end'].line + 1
      location = location .. ':' .. first .. (last ~= first and '-' .. last or '')
    end
    local parts = { '## ' .. location }
    if annotation.range and not printed[annotation.threadId] and annotation.snippet ~= '' then
      parts[#parts + 1] = M.fenced(annotation.snippet, M.language(annotation.file))
    end
    if annotation.body ~= '' then
      parts[#parts + 1] = annotation.body
    end
    blocks[#blocks + 1] = table.concat(parts, '\n\n')
    printed[annotation.threadId] = true
  end
  return table.concat(blocks, '\n\n')
end

return M
