-- ~/.config/nvim/lua/plugins.lua:
return require('packer').startup(function(use)
    use 'wbthomason/packer.nvim' -- Packer can manage itself
    use 'nvim-neo-tree/neo-tree.nvim' -- NeoTree sidebar
    use 'nvim-lua/plenary.nvim' -- dependency
    use 'nvim-tree/nvim-web-devicons' -- optional, icons

    -- ===== Comment.nvim =====
    use {
        'numToStr/Comment.nvim',
        config = function()
            require('Comment').setup({
                padding = true,   -- Add a space after comment symbol
                sticky = true,    -- Keep comment on current line when moving
                toggler = {
                    line = 'gcc',  -- Normal mode: toggle line comment
                    block = 'gbc', -- Normal mode: toggle block comment
                },
                opleader = {
                    line = 'gc',   -- Visual mode: toggle line comment
                    block = 'gb',  -- Visual mode: toggle block comment
                },
            })
        end
    }
end)
