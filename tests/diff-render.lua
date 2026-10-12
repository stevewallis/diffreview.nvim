vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.diffopt = { "algorithm:histogram", "closeoff", "context:10", "filler", "internal", "indent-heuristic" }
local git = require("diffreview.git")
local review = require("diffreview")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
git.run(root, { "init", "-b", "test" })
git.run(root, { "config", "user.name", "Test" })
git.run(root, { "config", "user.email", "test@example.invalid" })
for _, name in ipairs({ "alpha", "beta", "gamma" }) do
	vim.fn.writefile({ name .. " unchanged", "before", name .. " unchanged end" }, root .. "/" .. name .. ".txt")
end
git.run(root, { "add", "." })
git.run(root, { "commit", "-m", "base" })
for _, name in ipairs({ "alpha", "beta", "gamma" }) do
	vim.fn.writefile({ name .. " unchanged", "after", name .. " unchanged end" }, root .. "/" .. name .. ".txt")
end
vim.cmd.cd(root)
review.setup({ state_dir = root .. "/state", auto_refresh = false })
review.open("HEAD")
local s = review.state()
local function check(label)
	vim.cmd.diffupdate()
	for _, win in ipairs({ s.left_win, s.right_win }) do
		vim.api.nvim_win_call(win, function()
			assert(vim.fn.diff_hlID(1, 1) == 0, label .. ": unchanged first line marked as modified")
			assert(vim.fn.diff_hlID(2, 1) ~= 0, label .. ": changed line not highlighted")
			assert(vim.fn.diff_hlID(3, 1) == 0, label .. ": unchanged last line marked as modified")
		end)
	end
end
check("initial")
for i = 2, 3 do
	vim.cmd.cnext()
	assert(vim.wait(1000, function()
		return s.current == s.entries[i].key
	end))
	check("quickfix file " .. i)
end
review.select(s.entries[1].key)
check("back to first")
-- A refreshed historical snapshot must not leave the old snapshot in the diff.
git.run(root, { "add", "." })
git.run(root, { "commit", "-m", "move base" })
vim.fn.writefile({ "alpha unchanged", "after again", "alpha unchanged end" }, root .. "/alpha.txt")
review.refresh()
check("after base refresh")
print("Diff rendering regression passed")
vim.cmd("qa!")
