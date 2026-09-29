# tandem.nvim

Annotate code in Neovim and copy your notes, with source snippets, to a coding agent.

Requires **Neovim 0.11+**.

## Install locally

Add this to your lazy.nvim plugins, replacing `dir` with your local checkout:

```lua
{
  dir = vim.fn.expand('~/code/tandem.nvim'),
  cmd = 'Tandem',
  opts = {},
}
```

## Use

1. Open a source file and select lines with **V**.
2. Press **:**, type `Tandem annotate`, and press **Enter**. Neovim adds the selected range (`'<,'>`) automatically.
3. Write your note—for example, “Why is this value hard-coded?” Press **Escape**, then run **`:w`** to save.
4. Run **`:Tandem list`** to browse your annotations. Press **Enter** to read a thread and **q** to close a view.
5. Run **`:Tandem copy`** and paste the notes into your coding agent.

System clipboard copying requires a working Neovim clipboard provider. The text is also available in register `0` (paste with **`"0p`**) or through **`:Tandem export`**.

See **`:help tandem`** or the [full reference](doc/tandem.txt) for commands, key mappings, configuration, and storage details.

## Development

Run the checks with Neovim 0.11 or newer:

```sh
nvim --headless -u NONE -l tests/run.lua
stylua --check lua plugin tests
```

Standalone checks use fresh project fixtures; the annotation journey exercises
commands, windows, mappings, drafts, and storage together.

[MIT License](LICENSE).
