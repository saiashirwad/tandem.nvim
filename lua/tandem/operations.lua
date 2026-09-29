local M = {}
local session = require('tandem.session')

function M.append(data, anchor, existing, body, id, created_at)
  if existing then
    local _, by_id = session.threads(data)
    if not by_id[anchor.threadId] or not vim.deep_equal(by_id[anchor.threadId].anchor, anchor) then
      error('The thread was deleted or its anchor changed. Select the code again.', 0)
    end
  end
  local annotation = vim.deepcopy(anchor)
  annotation.id, annotation.body, annotation.createdAt = id, body, created_at
  data.annotations[#data.annotations + 1] = annotation
end

local function unchanged(data, original, action)
  for index, annotation in ipairs(data.annotations) do
    if annotation.id == original.id then
      if not vim.deep_equal(annotation, original) then
        error('This annotation changed on disk. Reopen it before ' .. action .. '.', 0)
      end
      return annotation, index
    end
  end
  error('This annotation was deleted. Your draft is still open.', 0)
end

function M.edit(data, original, body)
  unchanged(data, original, 'editing').body = body
end

function M.delete(data, original)
  local _, index = unchanged(data, original, 'deleting')
  table.remove(data.annotations, index)
end

return M
