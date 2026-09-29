local M = {}

function M.check()
  vim.health.start('tandem.nvim')
  if vim.fn.has('nvim-0.11') == 1 then
    vim.health.ok('Neovim 0.11+ available')
  else
    vim.health.error('Neovim 0.11 or newer is required')
  end
  if vim.fn.executable('git') == 1 then
    vim.health.ok('Git available for local .tandem/ exclusion')
  else
    vim.health.info('Git unavailable; annotation storage still works')
  end
  if vim.fn.has('clipboard') == 1 then
    vim.health.ok('Clipboard provider available; register 0 is also populated')
  else
    vim.health.info('No clipboard provider; use register 0 or :Tandem export')
  end
  vim.health.info('Sessions live at the project root in .tandem/session.json. See :help tandem-storage.')
end

return M
