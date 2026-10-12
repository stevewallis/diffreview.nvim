local M = {}
local git = require("diffreview.git")
local session
local options = { auto_refresh = true, show_reviewed = true }

local function protect(fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			vim.notify("DiffReview: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

local function current()
	assert(session and vim.api.nvim_tabpage_is_valid(session.tab), "No active review")
	return session
end

local function snapshot(s, e, side)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.b[buf].diffreview_snapshot = true
	vim.api.nvim_buf_set_name(buf, ("diffreview://%s/%s/%s/%s"):format(s.id, buf, side, e.path))
	local data = e[side]
	local lines = data and vim.split(data, "\n", { plain = true }) or { "[File absent]" }
	if e.binary then
		lines = { "[Binary file: " .. side .. "]" }
	end
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	vim.bo[buf].bufhidden = "hide"
	-- Syntax highlighting without FileType events that would start language servers.
	vim.b[buf].diffreview_syntax = vim.filetype.match({ filename = e.path }) or ""
	vim.diagnostic.enable(false, { bufnr = buf })
	s.buffers[#s.buffers + 1] = buf
	return buf
end

local function visible(s)
	return vim.tbl_filter(function(e)
		return s.all or not e.done
	end, s.entries)
end

local function publish(s)
	local items, idx = {}, 1
	local pending = 0
	for _, e in ipairs(s.entries) do
		if not e.done then
			pending = pending + 1
		end
	end
	for _, e in ipairs(visible(s)) do
		items[#items + 1] = {
			bufnr = e.buf,
			lnum = 1,
			text = (e.done and "[x] " or "[ ] ") .. e.status .. " " .. e.path,
			user_data = { diffreview = true, key = e.key },
		}
		if e.key == s.current then
			idx = #items
		end
	end
	local what = {
		title = ("DiffReview (%d/%d pending)"):format(pending, #s.entries),
		items = items,
		idx = #items > 0 and idx or 0,
		context = { diffreview = true },
		quickfixtextfunc = function(info)
			local list = vim.fn.getqflist({ id = info.id, items = 1 }).items
			local lines = {}
			for i = info.start_idx, info.end_idx do
				lines[#lines + 1] = list[i].text
			end
			return lines
		end,
	}
	if s.qfid then
		what.id = s.qfid
	end
	vim.fn.setqflist({}, s.qfid and "r" or " ", what)
	s.qfid = s.qfid or vim.fn.getqflist({ id = 0 }).id
end

function M.select(key)
	local s = current()
	local e
	for _, item in ipairs(s.entries) do
		if item.key == key then
			e = item
			break
		end
	end
	if not e then
		return
	end
	assert(
		vim.api.nvim_win_is_valid(s.left_win) and vim.api.nvim_win_is_valid(s.right_win),
		"Review windows closed; start a new review"
	)
	s.switching = true
	local ok, err = pcall(function()
		vim.api.nvim_set_current_tabpage(s.tab)
		-- Hidden buffers remain diff participants when a window changes buffers.
		-- Clear the tab's previous comparison before enabling the new pair.
		vim.cmd("diffoff!")
		for _, buf in ipairs({ e.left_buf, e.buf }) do
			local syntax = vim.b[buf].diffreview_syntax
			if syntax then
				vim.bo[buf].syntax = syntax
				vim.b[buf].diffreview_syntax = nil
			end
		end
		vim.api.nvim_win_set_buf(s.left_win, e.left_buf)
		vim.api.nvim_win_set_buf(s.right_win, e.buf)
		for _, win in ipairs({ s.left_win, s.right_win }) do
			vim.api.nvim_win_call(win, vim.cmd.diffthis)
			-- :diffthis turns wrap off; keep the review-wide wrap choice across files.
			if s.wrap ~= nil then
				vim.wo[win].wrap = s.wrap
			end
		end
		vim.cmd.diffupdate()
		s.current = key
		local items = vim.fn.getqflist({ id = s.qfid, items = 1 }).items
		for i, item in ipairs(items) do
			if item.user_data.key == key then
				vim.fn.setqflist({}, "a", { id = s.qfid, idx = i })
				break
			end
		end
		vim.api.nvim_set_current_win(s.right_win)
	end)
	s.switching = false
	if not ok then
		error(err)
	end
end

local function save(s)
	local tmp = s.statefile .. "." .. vim.uv.os_getpid() .. ".tmp"
	assert(vim.fn.writefile({ vim.json.encode(s.marks) }, tmp) == 0, "Cannot save review state")
	assert(vim.uv.fs_rename(tmp, s.statefile))
end

function M.refresh(initial_entries)
	local s = current()
	local entries = initial_entries or git.entries(s.root, s.base, s.target, { cache = s.git_cache })
	local old = {}
	for _, e in ipairs(s.entries) do
		old[e.key] = e
	end
	for _, e in ipairs(entries) do
		e.done = s.marks[e.key] == e.fingerprint
		local previous = old[e.key]
		if previous and previous.fingerprint == e.fingerprint then
			e.buf, e.left_buf = previous.buf, previous.left_buf
		else
			e.left_buf = snapshot(s, e, "left")
			if not s.target and e.right and not e.binary and (e.mode == "100644" or e.mode == "100755") then
				e.buf = vim.fn.bufadd(s.root .. "/" .. e.path)
				if vim.api.nvim_buf_is_loaded(e.buf) and not vim.bo[e.buf].modified then
					vim.api.nvim_buf_call(e.buf, vim.cmd.checktime)
				end
			else
				e.buf = snapshot(s, e, "right")
			end
		end
	end
	s.entries = entries
	publish(s)
	-- Never steal focus from notes or a picker during an automatic refresh.
	local win = vim.api.nvim_get_current_win()
	if win == s.left_win or win == s.right_win then
		for _, e in ipairs(entries) do
			if e.key == s.current then
				M.select(e.key)
				break
			end
		end
	end
end

function M.toggle(key, advance)
	local s = current()
	if not key and vim.bo.buftype == "quickfix" then
		local qf = vim.fn.getqflist({ id = 0, items = 1 })
		local item = qf.items[vim.api.nvim_win_get_cursor(0)[1]]
		if qf.id == s.qfid and item then
			key = item.user_data.key
		end
	end
	key = key or s.current
	for index, e in ipairs(s.entries) do
		if e.key == key then
			if not e.done then
				assert(not vim.bo[e.buf].modified, "Save the file before marking it reviewed")
				local latest = git.entries(s.root, s.base, s.target, {
					cache = s.git_cache,
					paths = { ":(literal)" .. e.old, ":(literal)" .. e.path },
				})
				local match
				for _, item in ipairs(latest) do
					if item.key == key then
						match = item
					end
				end
				assert(match and match.fingerprint == e.fingerprint, "Comparison changed; refresh and review it again")
			end
			s.marks[key] = not e.done and e.fingerprint or nil
			save(s)
			e.done = not e.done
			publish(s)
			if e.done and not s.all and advance ~= false then
				for offset = 1, #s.entries do
					local next_entry = s.entries[(index + offset - 1) % #s.entries + 1]
					if not next_entry.done then
						M.select(next_entry.key)
						return
					end
				end
				vim.notify("DiffReview: all files reviewed")
			end
			return
		end
	end
end

function M.toggle_all()
	local s = current()
	s.all = not s.all
	publish(s)
end

function M.notes()
	local s = current()
	local ok, Snacks = pcall(require, "snacks")
	if not ok or not Snacks.scratch then
		vim.cmd("botright split " .. vim.fn.fnameescape(s.notesfile))
		return
	end
	-- Include identity in the name: older Snacks versions ignore filekey.id.
	local win = Snacks.scratch({
		name = ("Review %s: %s → %s [%s]"):format(
			vim.fs.basename(s.root),
			s.base,
			s.target or "working tree",
			s.id:sub(1, 12)
		),
		ft = "markdown",
		filekey = { id = "diffreview-" .. s.id, cwd = false, branch = false, count = false },
	})
	-- Preserve notes from the original split-based implementation. Never replace
	-- an existing scratch file or in-memory edits, and retain the original file.
	if win and vim.fn.filereadable(s.notesfile) == 1 then
		local path = vim.api.nvim_buf_get_name(win.buf)
		local lines = vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
		if vim.fn.filereadable(path) == 0 and not vim.bo[win.buf].modified and #lines == 1 and lines[1] == "" then
			vim.api.nvim_buf_set_lines(win.buf, 0, -1, false, vim.fn.readfile(s.notesfile))
		end
	end
	return win
end

function M.pick()
	local s = current()
	local ok, Snacks = pcall(require, "snacks")
	assert(ok and Snacks.picker, "Snacks picker is not installed; use :copen")
	return Snacks.picker({
		title = "DiffReview" .. (s.all and " — all" or " — pending"),
		cwd = s.root,
		finder = function()
			local items = {}
			for _, e in ipairs(visible(s)) do
				items[#items + 1] = {
					text = (e.done and "[x] " or "[ ] ") .. e.status .. " " .. e.path,
					file = s.root .. "/" .. e.path,
					key = e.key,
				}
			end
			return items
		end,
		format = function(item)
			return { { item.text } }
		end,
		preview = false,
		confirm = function(picker, item)
			picker:close()
			if item then
				vim.schedule(protect(function()
					M.select(item.key)
				end))
			end
		end,
		actions = {
			review_toggle = protect(function(picker, item)
				if item then
					M.toggle(item.key, false)
					picker:find()
				end
			end),
			review_all = function(picker)
				M.toggle_all()
				picker:find()
			end,
		},
		win = {
			input = {
				keys = {
					["<C-d>"] = { "review_toggle", mode = { "n", "i" }, desc = "Toggle reviewed" },
					["<C-a>"] = { "review_all", mode = { "n", "i" }, desc = "Toggle all/pending" },
				},
			},
		},
	})
end

function M.open(base, target)
	base = base or "HEAD"
	local root = vim.trim(git.run(vim.fn.getcwd(), { "rev-parse", "--show-toplevel" }))
	if session and vim.api.nvim_tabpage_is_valid(session.tab) then
		error("Close the current review tab before starting another review")
	end
	local cache = {}
	local entries = git.entries(root, base, target, { cache = cache }) -- Validate before changing the UI.
	local branch = vim.trim(git.run(root, { "rev-parse", "--abbrev-ref", "HEAD" }))
	local id = vim.fn.sha256(vim.json.encode({ root, branch, base, target or "WORKTREE" }))
	local dir = options.state_dir or vim.fn.stdpath("state") .. "/diffreview"
	vim.fn.mkdir(dir, "p")
	local statefile = dir .. "/" .. id .. ".json"
	local marks = {}
	if vim.fn.filereadable(statefile) == 1 then
		marks = vim.json.decode(table.concat(vim.fn.readfile(statefile), "\n"))
		assert(type(marks) == "table", "Invalid review state")
	end
	vim.cmd.tabnew()
	local s = {
		root = root,
		base = base,
		target = target,
		id = id,
		marks = marks,
		all = options.show_reviewed,
		git_cache = cache,
		statefile = statefile,
		notesfile = dir .. "/" .. id .. ".md",
		entries = {},
		buffers = {},
		tab = vim.api.nvim_get_current_tabpage(),
		left_win = vim.api.nvim_get_current_win(),
	}
	vim.cmd("rightbelow vsplit")
	s.right_win = vim.api.nvim_get_current_win()
	session = s
	M.refresh(entries)
	vim.cmd("botright copen")
	local first = visible(s)[1]
	if first then
		M.select(first.key)
	else
		vim.notify("DiffReview: no pending files")
	end
end

function M.state()
	return session
end

-- Whether the current tab is the review tab; lets callers route their own keys to review actions.
function M.active()
	return session ~= nil
		and vim.api.nvim_tabpage_is_valid(session.tab)
		and vim.api.nvim_get_current_tabpage() == session.tab
end

function M.setup(opts)
	options = vim.tbl_extend("force", options, opts or {})
	local commands = {
		DiffReviewDone = M.toggle,
		DiffReviewRefresh = M.refresh,
		DiffReviewAll = M.toggle_all,
		DiffReviewPick = M.pick,
		DiffReviewNotes = M.notes,
	}
	for name, fn in pairs(commands) do
		vim.api.nvim_create_user_command(
			name,
			protect(function()
				fn()
			end),
			{}
		)
	end
	vim.api.nvim_create_user_command(
		"DiffReview",
		protect(function(args)
			assert(#args.fargs <= 2, "Usage: DiffReview [base [target]]")
			M.open(args.fargs[1], args.fargs[2])
		end),
		{ nargs = "*" }
	)
	local group = vim.api.nvim_create_augroup("diffreview", { clear = true })
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		callback = function(ev)
			local s = session
			if not s or s.switching or vim.api.nvim_get_current_tabpage() ~= s.tab then
				return
			end
			local qf = vim.fn.getqflist({ id = 0, idx = 0, items = 1 })
			local item = qf.items[qf.idx]
			if qf.id == s.qfid and item and item.bufnr == ev.buf and item.user_data then
				local key = item.user_data.key
				if key ~= s.current then
					vim.schedule(protect(function()
						if session == s and vim.api.nvim_get_current_tabpage() == s.tab then
							M.select(key)
						end
					end))
				end
			end
		end,
	})
	-- Diff panes scroll-bind by screen row, so wrapping only one side misaligns them.
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "wrap",
		callback = function()
			local s = session
			local win = vim.api.nvim_get_current_win()
			if not s or s.switching or (win ~= s.left_win and win ~= s.right_win) then
				return
			end
			s.wrap = vim.wo[win].wrap
			local other = win == s.left_win and s.right_win or s.left_win
			if vim.api.nvim_win_is_valid(other) and vim.wo[other].wrap ~= s.wrap then
				vim.wo[other].wrap = s.wrap
			end
		end,
	})
	local generation = 0
	vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
		group = group,
		callback = function()
			local s = session
			if not options.auto_refresh or not s or not vim.api.nvim_tabpage_is_valid(s.tab) then
				return
			end
			generation = generation + 1
			local expected = generation
			vim.defer_fn(
				protect(function()
					if generation == expected and session == s and vim.api.nvim_tabpage_is_valid(s.tab) then
						M.refresh()
					end
				end),
				200
			)
		end,
	})
end

return M
