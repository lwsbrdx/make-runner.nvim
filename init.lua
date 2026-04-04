local M = {}

---@alias OpenIn 'tab'|'split'

---@class MakeRunnerConfig
---@field prompt_title? string
---@field open_in? OpenIn
---@field use_telescope? boolean
local defaults = {
    prompt_title = "Makefile Runner",
    open_in = "tab",
    use_telescope = true,
}

local valid_options = {
    open_in = {
        tab = true,
        split = true,
    }
}

---@type MakeRunnerConfig
local config = {}

---@param opts MakeRunnerConfig
function M.setup(opts)
    opts = opts or {}

    if opts.open_in and not valid_options.open_in[opts.open_in] then
        vim.notify("make-runner: open_in must be 'tab' or 'split'", vim.log.levels.ERROR)
    end

    config = vim.tbl_deep_extend("force", defaults, opts)

    vim.keymap.set("n", "<leader>mr", function() M.run() end,
        { desc = "Select and run a Makefile recipe", noremap = true })
end

function M.find_makefile()
    local makefile_path = vim.fn.getcwd() .. "/Makefile"

    if vim.fn.filereadable(makefile_path) == 0 then
        return nil
    end

    return makefile_path
end

function M.parse_makefile(filepath)
    local recipes = {}

    if vim.fn.filereadable(filepath) == 0 then
        return {}
    end

    for line in io.lines(filepath) do
        local match = line:match("^([%a%d%-_]+)%s*:%s*")

        if match ~= nil and not line:find("^[%a%d-_]+%s*:=") then
            table.insert(recipes, match)
        end
    end

    return recipes
end

function M.get_recipe_content(filepath, recipe)
    if recipe == nil or recipe == "" then
        return {}
    end

    local recipe_content = {}
    local record = false

    for line in io.lines(filepath) do
        if line:find("^" .. vim.pesc(recipe) .. ":") and record == false then
            record = true
            table.insert(recipe_content, (line:gsub("^%s+", "")))
            goto continue
        end

        if line:find("^%s+") and record then
            table.insert(recipe_content, line)
        end

        if not line:find("^%s+") and record then
            record = false
        end

        ::continue::
    end

    return recipe_content
end

---@param recipe string
local function run_recipe(recipe)
    local open_cmd = { tab = 'tabnew', split = 'split' }
    local cmd = open_cmd[config.open_in] .. "|terminal make " .. recipe
    vim.cmd(cmd)
end

---@param tbl table
---@param needle unknown
---@return integer?
function table.index_of(tbl, needle)
    for i, e in ipairs(tbl) do
        if e == needle then
            return i
        end
    end

    return nil
end

---@param tbl table
---@param needle unknown
---@return boolean
function table.has(tbl, needle)
    if table.index_of(tbl, needle) ~= nil then
        return true
    end
    return false
end

---@param makefile_path string
---@param recipes table<string>
local function run_with_telescope(makefile_path, recipes)
    local ok_pickers, pickers = pcall(require, "telescope.pickers")
    local ok_finders, finders = pcall(require, "telescope.finders")
    local ok_config, t_config = pcall(require, "telescope.config")
    local ok_previewers, previewers = pcall(require, "telescope.previewers")
    local ok_actions, actions = pcall(require, "telescope.actions")
    local ok_act_state, actions_state = pcall(require, "telescope.actions.state")

    local can_use_telescope = ok_pickers and ok_finders and ok_config and ok_previewers and ok_actions and ok_act_state

    if not can_use_telescope or config.use_telescope == false then
        return nil
    end

    local selected_recipes = {}

    pickers.new({}, {
        prompt_title = config.prompt_title,
        finder = finders.new_table({ results = recipes }),
        sorter = t_config.values.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            map({ "i", "n" }, "<Tab>", function()
                local selected_recipe = actions_state.get_selected_entry()[1]
                if table.has(selected_recipes, selected_recipe) == false then
                    table.insert(selected_recipes, selected_recipe)
                else
                    table.remove(selected_recipes, table.index_of(selected_recipes, selected_recipe))
                end

                actions.toggle_selection(prompt_bufnr)
                actions.move_selection_next(prompt_bufnr)
            end)

            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local recipe = nil
                if #selected_recipes > 0 then
                    recipe = table.concat(selected_recipes, " ")
                else
                    recipe = actions_state.get_selected_entry()[1]
                end

                run_recipe(recipe)
            end)

            return true
        end,
        previewer = previewers.new_buffer_previewer({
            define_preview = function(self, entry)
                local lines = M.get_recipe_content(makefile_path, entry[1])
                vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
                vim.bo[self.state.bufnr].filetype = "make"
            end,
        })
    }):find()

    return true
end

---@param t table
---@return table
function table.copy(t)
    local u = {}
    for k, v in pairs(t) do
        u[k] = v
    end
    return setmetatable(u, getmetatable(t))
end

---@param recipes table
local function run_with_select(recipes)
    local choices = table.copy(recipes)
    table.insert(choices, "-> Run")

    local selected_recipes = {}

    local function pick(remaining_recipes)
        vim.ui.select(
            remaining_recipes,
            {
                prompt = config.prompt_title,
            },
            function(recipe)
                if recipe == nil then return end

                if recipe ~= "-> Run" and not recipe:find("^Selected:") then
                    table.remove(
                        remaining_recipes,
                        table.index_of(remaining_recipes, recipe)
                    )
                    table.insert(selected_recipes, recipe)

                    if remaining_recipes[1]:find("^Selected:") then
                        table.remove(remaining_recipes, 1)
                    end
                    table.insert(remaining_recipes, 1, "Selected: " .. table.concat(selected_recipes, " "))

                    pick(remaining_recipes)
                end

                if recipe == "-> Run" then
                    run_recipe(table.concat(selected_recipes, " "))
                    return
                end
            end
        )
    end

    pick(choices)
end

function M.run()
    local makefile_path = M.find_makefile()

    if makefile_path == nil then
        vim.notify("No Makefile found", vim.log.levels.WARN)
        return
    end

    local recipes = M.parse_makefile(makefile_path)

    if not run_with_telescope(makefile_path, recipes) then
        run_with_select(recipes)
    end
end

return M
