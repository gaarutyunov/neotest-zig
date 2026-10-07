# Neotest Zig ⚡

![Zig v0.17.0](https://img.shields.io/badge/Zig-v0.17-orange?logo=zig)
![Neovim v0.10](https://img.shields.io/badge/Neovim-v0.10-green?logo=neovim)

[Neotest](https://github.com/nvim-neotest/neotest) test runner for [Zig](https://github.com/ziglang/zig).

## ⚙️ Requirements
- [`zig` v0.17 installed](https://ziglang.org/download/) and available in PATH
- [Neotest](https://github.com/nvim-neotest/neotest#installation)
- [Treesitter](https://github.com/nvim-treesitter/nvim-treesitter#installation) with the Zig parser installed (`:TSInstall zig`)

## 📦 Setup
Install & configure using the package manager of your choice.
Example using lazy.nvim:
```lua
return {
	"nvim-neotest/neotest",
	dependencies = {
		"ahmedalhulaibi/neotest-zig", -- Installation
		"nvim-neotest/nvim-nio",
		"nvim-lua/plenary.nvim",
		"nvim-treesitter/nvim-treesitter",
		"antoinemadec/FixCursorHold.nvim",
	},
	config = function()
		require("neotest").setup({
			adapters = {
				-- Registration
				require("neotest-zig")({
					dap = {
						adapter = "lldb",
					}
				}),
			}
		})
	end
}
```

## ⭐ Features
 - Runs tests in individual `.zig` files and projects using `build.zig`
   - Does not support a mix of individual files and `build.zig`
   - `build.zig` must have a standard `test` step
 - Exact test filtering
 - Timing all tests individually

## 📄 Logs
Enabling logging in `neotest` automatically enables logging in `neotest-zig` as well:
```lua
require("neotest").setup({
    log_level = vim.log.levels.TRACE,
    -- ...
})
```
The logs can be openned by:
```vim
:exe 'edit' stdpath('log').'/neotest-zig.log'
```
