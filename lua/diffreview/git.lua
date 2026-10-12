local M = {}

function M.run(root, args, stdin)
	local cmd = { "git", "-C", root }
	vim.list_extend(cmd, args)
	local r = vim.system(cmd, { text = false, stdin = stdin }):wait()
	assert(r.code == 0, r.stderr ~= "" and r.stderr or "Git command failed")
	return r.stdout
end

function M.resolve(root, ref)
	return vim.trim(M.run(root, { "rev-parse", "--verify", "--end-of-options", ref .. "^{commit}" }))
end

local function content(root, rev, path, mode, oid, cache)
	if mode == "000000" then
		return nil
	end
	if mode == "160000" then
		return "Submodule " .. oid .. "\n"
	end
	if rev then
		return assert(cache[oid], "Missing historical blob")
	end
	if mode == "120000" then
		return assert(vim.uv.fs_readlink(root .. "/" .. path))
	end
	local f = assert(io.open(root .. "/" .. path, "rb"))
	local data = f:read("*a")
	f:close()
	return data
end

function M.entries(root, base, target, opts)
	opts = opts or {}
	local cache = opts.cache or {}
	local left, right = M.resolve(root, base), target and M.resolve(root, target)
	local args = { "diff", "--raw", "-z", "--no-abbrev", "--no-ext-diff", "--no-textconv", "-M", left }
	if right then
		args[#args + 1] = right
	end
	args[#args + 1] = "--"
	vim.list_extend(args, opts.paths or {})
	local fields = vim.split(M.run(root, args), "\0", { plain = true, trimempty = true })
	local records, wanted, seen, i = {}, {}, {}, 1
	local function want(mode, oid)
		if mode ~= "000000" and mode ~= "160000" and not cache[oid] and not seen[oid] then
			wanted[#wanted + 1], seen[oid] = oid, true
		end
	end
	while i <= #fields do
		local lm, rm, lo, ro, status = fields[i]:match("^:(%d+) (%d+) (%x+) (%x+) (%S+)$")
		assert(status, "Unexpected git diff record")
		local old, path = fields[i + 1], fields[i + 1]
		i = i + 2
		if status:match("^[RC]") then
			path, i = fields[i], i + 1
		end
		assert(not status:match("^U"), "Resolve merge conflicts before reviewing")
		assert(right or rm ~= "160000", "Working-tree submodule changes are not supported yet")
		records[#records + 1] = { lm = lm, rm = rm, lo = lo, ro = ro, old = old, path = path, status = status }
		want(lm, lo)
		if right then
			want(rm, ro)
		end
	end
	if #wanted > 0 then
		local output = M.run(root, { "cat-file", "--batch" }, table.concat(wanted, "\n") .. "\n")
		local offset = 1
		for _, oid in ipairs(wanted) do
			local stop = assert(output:find("\n", offset, true), "Incomplete Git blob header")
			local size = tonumber(output:sub(offset, stop - 1):match("^%x+ blob (%d+)$"))
			assert(size, "Unexpected Git blob response")
			assert(#output >= stop + size + 1, "Incomplete Git blob content")
			cache[oid] = output:sub(stop + 1, stop + size)
			offset = stop + size + 2
		end
	end
	local entries = {}
	for _, record in ipairs(records) do
		local lm, rm, lo, ro = record.lm, record.rm, record.lo, record.ro
		local old, path, status = record.old, record.path, record.status
		local a, b = content(root, left, old, lm, lo, cache), content(root, right, path, rm, ro, cache)
		local key = vim.json.encode({ old, path })
		local fingerprint = vim.fn.sha256(vim.json.encode({
			old,
			path,
			lm,
			rm,
			a == nil and "missing" or vim.fn.sha256(vim.base64.encode(a)),
			b == nil and "missing" or vim.fn.sha256(vim.base64.encode(b)),
		}))
		entries[#entries + 1] = {
			key = key,
			path = path,
			old = old,
			status = status:sub(1, 1),
			left = a,
			right = b,
			fingerprint = fingerprint,
			mode = rm,
			binary = (a and a:find("\0", 1, true) or b and b:find("\0", 1, true)) ~= nil,
		}
	end
	return entries
end

return M
