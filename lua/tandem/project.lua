local M = {}
local uv = vim.uv

function M.canonical(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p')):gsub('/+$', '')
  if path == '' then
    path = '/'
  end
  local real = uv.fs_realpath(path)
  if real then
    return vim.fs.normalize(real)
  end
  local parent = vim.fs.dirname(path)
  if parent and parent ~= path then
    return vim.fs.joinpath(M.canonical(parent), vim.fs.basename(path))
  end
  return path
end

function M.relative(root, path)
  local prefix = root:gsub('/+$', '') .. '/'
  if path:sub(1, #prefix) ~= prefix then
    error('Only files inside ' .. root .. ' can be annotated', 0)
  end
  return path:sub(#prefix + 1)
end

function M.resolve(buf, config)
  local name = vim.api.nvim_buf_get_name(buf)
  local is_file = vim.bo[buf].buftype == '' and name ~= '' and not name:match('^%a[%w+.-]*://')
  local path = is_file and M.canonical(name) or nil
  local root = config.root
  if type(root) == 'function' then
    root = root(buf)
  end
  root = root or vim.fs.root(path or vim.fn.getcwd(), { '.tandem', '.git' }) or vim.fn.getcwd()
  root = M.canonical(root)
  if not uv.fs_stat(root) or uv.fs_stat(root).type ~= 'directory' then
    error('Project root is not a directory: ' .. root, 0)
  end
  return root, path and M.relative(root, path) or nil
end

function M.file(root, file)
  local path = M.canonical(vim.fs.joinpath(root, file))
  M.relative(root, path)
  return path
end

function M.exclude(root)
  if vim.fn.executable('git') ~= 1 then
    return
  end
  local result = vim
    .system({ 'git', 'rev-parse', '--git-path', 'info/exclude' }, {
      cwd = root,
      text = true,
      env = { LC_ALL = 'C' },
    })
    :wait()
  if result.code ~= 0 then
    if (result.stderr or ''):find('not a git repository', 1, true) then
      return
    end
    error(vim.trim(result.stderr or 'Could not find Git exclude file'), 0)
  end
  local path = vim.trim(result.stdout)
  if not path:match('^/') and not path:match('^%a:') then
    path = vim.fs.joinpath(root, path)
  end
  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  if vim.tbl_contains(lines, '.tandem/') then
    return
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local file, err = io.open(path, 'a+')
  if not file then
    error(err, 0)
  end
  local size = file:seek('end')
  local prefix = ''
  if size and size > 0 then
    file:seek('set', size - 1)
    prefix = file:read(1) == '\n' and '' or '\n'
  end
  local ok, write_err = file:write(prefix .. '.tandem/\n')
  local closed, close_err = file:close()
  if not ok or not closed then
    error(write_err or close_err, 0)
  end
end

return M
