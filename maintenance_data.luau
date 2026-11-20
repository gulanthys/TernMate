--!strict

local runtime = require("./runtime")
type Repo = runtime.Repo
type Callback = (any, string?) -> ()
type SyncCallback = (any, string?, boolean?) -> ()
type Nested = {name: string, first: number, fields: string, detail: string?}
type Kind = {name: string, typename: string, scalars: string, keys: {string}, nested: {Nested}}
export type Identity = {
	repoId: string, viewerId: string, viewer: string, visibility: string, hasIssues: boolean,
	defaultBranch: string?, webUrl: string, isFork: boolean, parent: any,
}
local data = {}

local repoArgs = "$owner:String!,$name:String!"
local repository = "repository(owner:$owner,name:$name)"
local identityFields = "id nameWithOwner url visibility hasIssuesEnabled isFork defaultBranchRef{name} parent{nameWithOwner url}"
local paging = "pageInfo{hasNextPage endCursor}"
local index = "id number updatedAt state"
local prIndex = "headRefOid baseRefName isDraft reviewDecision"
local issue: Kind = {
	name = "issues", typename = "Issue", scalars = "milestone{id title url}",
	keys = {"milestone"},
	nested = {
		{name = "labels", first = 30, fields = "id name"},
		{name = "assignees", first = 15, fields = "id login"},
	},
}
local pr: Kind = {
	name = "pullRequests", typename = "PullRequest",
	scalars = prIndex .. " isCrossRepository mergeable "
		.. "commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:1){totalCount}}}}}",
	keys = {"headRefOid", "baseRefName", "isCrossRepository", "isDraft", "mergeable", "reviewDecision", "commits"},
	nested = {
		{name = "labels", first = 30, fields = "id name"},
		{name = "closingIssuesReferences", first = 25, fields = "id number url"},
		{name = "reviewThreads", first = 25, fields = "id isResolved"},
		{name = "latestReviews", first = 20, fields = "id state author{login __typename} commit{oid} submittedAt", detail = "url"},
		{name = "reviewRequests", first = 20, fields = "id requestedReviewer{__typename ... on User{login}}"},
	},
}

local function nestedFields(spec: Nested, detail: boolean, after: boolean): string
	return spec.name .. (if after then "(first:50,after:$cursor)" else "(first:" .. spec.first .. ")")
		.. "{totalCount " .. paging .. " nodes{" .. spec.fields
		.. (if detail and spec.detail then " " .. spec.detail else "") .. "}}"
end

local function fields(kind: Kind, detail: boolean): string
	local selections = {index, "author{login}", kind.scalars}
	if detail then table.insert(selections, "title url") end
	for _, spec in kind.nested do table.insert(selections, nestedFields(spec, detail, false)) end
	return table.concat(selections, " ")
end

local function authError(message: string): boolean
	local text = message:lower()
	return text:find("bad credentials", 1, true) ~= nil or text:find("gh auth login", 1, true) ~= nil
		or text:find("not logged", 1, true) ~= nil or text:find("authentication required", 1, true) ~= nil
		or text:find("resource not accessible", 1, true) ~= nil or text:find("permission denied", 1, true) ~= nil
		or text:find("could not resolve to a repository", 1, true) ~= nil
end

local function graphql(repo: Repo, query: string, vars: { [string]: any }, done: SyncCallback, allowMissingNodes: boolean?)
	vars.owner, vars.name = repo.owner, repo.name
	runtime.exec({"gh", "api", "graphql", "--hostname", repo.host, "--method", "POST", "--input", "-", "--include"},
		{stdin = tern.json.encode({query = query, variables = vars})}, function(raw, err)
			if not raw then done(nil, runtime.failure(raw, err)); return end
			local boundary, bodyStart = raw.stdout:find("\r?\n\r?\n")
			local headers = if boundary then raw.stdout:sub(1, boundary - 1):lower() else ""
			local payload = if bodyStart then runtime.decode(raw.stdout:sub(bodyStart + 1)) else nil
			local response = headers:match("^http/%S+%s+(%d+)") or raw.stderr:match("HTTP (%d+)")
			local message = if payload and type(payload.message) == "string" then payload.message else ""
			local throttled = response == "429" or raw.stderr:lower():find("rate limit", 1, true) ~= nil
				or message:lower():find("rate limit", 1, true) ~= nil
				or headers:find("x%-ratelimit%-remaining:%s*0") ~= nil or headers:find("retry%-after:") ~= nil
			local errors = payload and payload.errors
			local misses, incomplete = false, errors ~= nil and type(errors) ~= "table"
			if type(errors) == "table" then
				for _, problem in errors do
					if type(problem) ~= "table" then incomplete = true; continue end
					local code = problem.type or (type(problem.extensions) == "table" and problem.extensions.code)
					if code == "RATE_LIMITED" then throttled = true end
					local lostRepo = code == "NOT_FOUND" and type(problem.path) == "table" and problem.path[1] == "repository"
					if code == "FORBIDDEN" or code == "UNAUTHORIZED" or code == "UNAUTHENTICATED" or code == "INSUFFICIENT_SCOPES"
						or lostRepo or (type(problem.message) == "string" and authError(problem.message)) then
						done(nil, "无法核对当前 GitHub 账号或仓库访问权限。", true); return
					end
					local path = problem.path
					if allowMissingNodes and code == "NOT_FOUND" and type(path) == "table" and path[1] == "nodes"
						and type(path[2]) == "number" and path[3] == nil then
						misses = true
					else
						incomplete = true
					end
				end
			end
			if response == "401" or response == "404" or authError(raw.stderr) or authError(message)
				or (response == "403" and not throttled) then
				done(nil, runtime.failure(raw, err), true); return
			end
			if raw.status ~= 0 and not (misses and not incomplete and response == "200") then
				done(nil, runtime.failure(raw, err)); return
			end
			if not payload or type(payload.data) ~= "table" or incomplete then
				done(nil, if throttled then "GitHub 限流。等待 GitHub 解除限流后重试。" else "GitHub 返回不完整的维护数据。")
				return
			end
			done(payload.data, nil)
		end)
end

local function checkedRepo(repo: Repo, value: any): boolean
	return type(value) == "table" and type(value.id) == "string" and type(value.nameWithOwner) == "string"
		and value.nameWithOwner:lower() == (repo.owner .. "/" .. repo.name):lower()
end

function data.identity(repo: Repo, done: Callback)
	graphql(repo, "query(" .. repoArgs .. "){viewer{id login} " .. repository .. "{" .. identityFields .. "}}", {}, function(value, err)
		if not value then done(nil, err); return end
		local r, user = value.repository, value.viewer
		if not checkedRepo(repo, r) or type(user) ~= "table" or type(user.id) ~= "string" or type(user.login) ~= "string" then
			done(nil, "无法核对仓库与登录账号。"); return
		end
		done({repoId = r.id, viewerId = user.id, viewer = user.login, visibility = r.visibility, hasIssues = r.hasIssuesEnabled,
			defaultBranch = if type(r.defaultBranchRef) == "table" then r.defaultBranchRef.name else nil,
			webUrl = r.url, isFork = r.isFork, parent = r.parent}, nil)
	end)
end

local function hex(value: string): string
	return (value:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end))
end

local function mirrorScope(repo: Repo, identity: Identity): string?
	if type(identity.repoId) ~= "string" or identity.repoId == "" or type(identity.viewerId) ~= "string"
		or identity.viewerId == "" or type(identity.viewer) ~= "string" or identity.viewer == "" then return nil end
	local scope = hex(repo.host:lower()) .. "-" .. hex(identity.repoId) .. "-" .. hex(identity.viewerId)
	return if #scope <= 240 then scope else nil
end

local function connection(value: any): boolean
	return type(value) == "table" and type(value.nodes) == "table" and type(value.pageInfo) == "table"
		and type(value.pageInfo.hasNextPage) == "boolean" and type(value.totalCount) == "number"
		and value.totalCount >= 0 and value.totalCount % 1 == 0
end

local function itemId(value: any): boolean
	return type(value) == "table" and type(value.id) == "string" and value.id ~= ""
end

local function indexShape(kind: Kind, value: any): boolean
	return itemId(value) and type(value.number) == "number" and value.number > 0 and value.number % 1 == 0
		and type(value.updatedAt) == "string" and type(value.state) == "string"
		and (kind == issue or (type(value.headRefOid) == "string" and type(value.baseRefName) == "string"
			and type(value.isDraft) == "boolean"))
end

local function itemShape(kind: Kind, value: any, detail: boolean): boolean
	if not indexShape(kind, value) or (detail and (type(value.title) ~= "string" or type(value.url) ~= "string"))
		or (value.author ~= nil and (type(value.author) ~= "table" or type(value.author.login) ~= "string")) then return false end
	return kind == issue or (type(value.isCrossRepository) == "boolean"
		and type(value.mergeable) == "string" and type(value.commits) == "table" and type(value.commits.nodes) == "table")
end

local function childShape(spec: Nested, value: any, detail: boolean): boolean
	if not itemId(value) then return false end
	if spec.name == "labels" then return type(value.name) == "string" end
	if spec.name == "assignees" then return type(value.login) == "string" end
	if spec.name == "closingIssuesReferences" then return type(value.number) == "number" and type(value.url) == "string" end
	if spec.name == "reviewThreads" then return type(value.isResolved) == "boolean" end
	if spec.name == "latestReviews" then return type(value.state) == "string" and (not detail or type(value.url) == "string") end
	local reviewer = value.requestedReviewer
	return reviewer == nil or (type(reviewer) == "table" and type(reviewer.__typename) == "string"
		and (reviewer.__typename ~= "User" or type(reviewer.login) == "string"))
end

local function acceptChildren(spec: Nested, nodes: {any}, detail: boolean, seen: {[string]: boolean}): boolean
	for position, node in nodes do
		if type(position) ~= "number" or position < 1 or position > #nodes or not childShape(spec, node, detail) or seen[node.id] then
			return false
		end
		seen[node.id] = true
	end
	return true
end

local function indexItems(kind: Kind, items: any): {[string]: any}?
	if type(items) ~= "table" then return nil end
	local indexed: {[string]: any} = {}
	local numbers: {[number]: boolean} = {}
	local count = 0
	for position, item in items do
		if type(position) ~= "number" or position < 1 or position > #items or not itemShape(kind, item, true)
			or indexed[item.id] or numbers[item.number] then
			return nil
		end
		for _, spec in kind.nested do
			local value = item[spec.name]
			if not connection(value) or value.pageInfo.hasNextPage or #value.nodes ~= value.totalCount then return nil end
			if not acceptChildren(spec, value.nodes, true, {}) then return nil end
		end
		indexed[item.id] = item
		numbers[item.number] = true
		count += 1
	end
	return if count == #items then indexed else nil
end

local function sameScope(repo: Repo, identity: Identity, snapshot: any): boolean
	return type(snapshot) == "table" and snapshot.complete == true and snapshot.host == repo.host:lower()
		and snapshot.repoId == identity.repoId and snapshot.viewerId == identity.viewerId and type(snapshot.observedAt) == "string"
end

local persisted: {[any]: boolean} = {}
setmetatable(persisted, {__mode = "k"})
local revoked: {[string]: boolean} = {}
local mirrorLimit = 128 * 1024 * 1024

local function mirrorIO(scope: string, mode: string, stdin: string?, done: (runtime.Result?, string?) -> ())
	runtime.exec({"/bin/sh", tern.plugin.dir .. "/maintenance-store.sh", tern.plugin.data, scope, "snapshot", mode},
		{stdin = stdin}, done)
end

function data.cached(repo: Repo, identity: Identity, done: Callback)
	local scope = mirrorScope(repo, identity)
	if not scope then done(nil, "本地镜像身份无效。"); return end
	if revoked[scope] then done(nil, nil); return end
	mirrorIO(scope, "mirror-probe", nil, function(raw, err)
		if revoked[scope] then done(nil, nil); return end
		if not raw or raw.status ~= 0 then done(nil, "无法打开本地镜像：" .. runtime.failure(raw, err)); return end
		if runtime.trim(raw.stdout) == "false" then done(nil, nil); return end
		if runtime.trim(raw.stdout) ~= "true" then done(nil, "本地镜像状态无效。"); return end
		-- Process stdout is capped at 16 MiB. Read the atomic file itself, with a bound
		-- that also rejects non-regular files and final-component symlinks.
		local path = tern.plugin.data .. "/maintenance-mirror-v1/" .. scope .. "/snapshot.json"
		local ok, text = pcall(tern.fs.read, path, mirrorLimit)
		if not ok then done(nil, "无法读取本地镜像文件。"); return end
		local value = runtime.decode(text)
		if not sameScope(repo, identity, value) then done(nil, "本地镜像不完整或身份不符。"); return end
		if value.repoUrl ~= identity.webUrl then done(nil, nil); return end
		if not indexItems(issue, value.issues) or not indexItems(pr, value.prs) then
			done(nil, "本地镜像不完整。"); return
		end
		value.viewer = identity.viewer -- Login can change; the cache key cannot.
		persisted[value] = true
		done(value, nil)
	end)
end

local function equal(a: any, b: any, omitUrl: boolean?): boolean
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for key, value in a do
		if not (omitUrl and key == "url") and not equal(value, b[key], omitUrl) then return false end
	end
	for key in b do
		if not (omitUrl and key == "url") and a[key] == nil then return false end
	end
	return true
end

local function sameVersion(a: any, b: any): boolean
	return a.id == b.id and a.number == b.number and a.updatedAt == b.updatedAt and a.headRefOid == b.headRefOid
end

local function sameIndex(a: any, b: any): boolean
	return sameVersion(a, b) and a.state == b.state and a.baseRefName == b.baseRefName
		and a.isDraft == b.isDraft and a.reviewDecision == b.reviewDecision
end

local function sameProbe(kind: Kind, a: any, b: any): boolean
	if not sameIndex(a, b) or not equal(a.author, b.author) then return false end
	for _, key in kind.keys do if not equal(a[key], b[key]) then return false end end
	-- Timestamps and head OIDs are not enough: check rollups, review requests,
	-- dismissals and resolved threads can change independently. Compare every
	-- observed node, not just a count or the first page.
	for _, spec in kind.nested do
		if not equal(a[spec.name].nodes, b[spec.name].nodes, spec.detail == "url") then return false end
	end
	return true
end

function data.sync(repo: Repo, identity: Identity, previous: any, isAlive: () -> boolean, done: SyncCallback, progress: ((any) -> ())?)
	if not isAlive() then return end
	local scope = mirrorScope(repo, identity)
	if not scope then done(nil, "本地镜像身份无效。", true); return end
	local oldIssues: {[string]: any}? = nil
	local oldPrs: {[string]: any}? = nil
	if sameScope(repo, identity, previous) then
		oldIssues = indexItems(issue, previous.issues)
		oldPrs = indexItems(pr, previous.prs)
	end
	local now = os.time()
	local lastReconciled = if oldIssues and oldPrs then previous.reconciledEpoch else nil
	-- Deep sweeps catch changes with no parent timestamp (e.g. a renamed label
	-- on an old closed issue) without paying for historical detail every refresh.
	local warm = type(lastReconciled) == "number" and now >= lastReconciled and now - lastReconciled < 86400
		and previous.repoUrl == identity.webUrl
	local snapshot: any = {host = repo.host:lower(), repoId = identity.repoId, repoUrl = identity.webUrl,
		viewerId = identity.viewerId, viewer = identity.viewer, issues = {}, prs = {}, complete = false,
		observedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", now)}
	local unchanged = warm and previous.viewer == identity.viewer
	local remaining, reported = 2, 0
	local stopped = false
	local identitySelection = "viewer{id login} " .. repository .. "{id nameWithOwner}"
	local function alive(): boolean return not stopped and isAlive() end
	local function fail(err: string, scopeChanged: boolean?)
		if not alive() then return end
		stopped = true
		done(nil, err, scopeChanged)
	end
	local function revoke()
		revoked[scope] = true
		mirrorIO(scope, "mirror-remove", nil, function() end)
	end
	local function request(query: string, vars: {[string]: any}, received: (any) -> (), allowMissingNodes: boolean?)
		if not alive() then return end
		graphql(repo, query, vars, function(value, err, scopeChanged)
			if not alive() then return end
			if not value then
				if scopeChanged then revoke() end
				fail(err or "扫描中断。", scopeChanged); return
			end
			local r, user = value.repository, value.viewer
			local viewerMatches = type(user) == "table" and user.id == identity.viewerId and user.login == identity.viewer
			if not checkedRepo(repo, r) or r.id ~= identity.repoId or not viewerMatches then
				if r == nil and viewerMatches then revoke() end
				fail("扫描期间仓库或账号身份无法核对；请刷新。", true); return
			end
			received(value)
		end, allowMissingNodes)
	end
	local function finish()
		remaining -= 1
		if remaining > 0 or not alive() then return end
		snapshot.complete = true
		snapshot.checkedEpoch = os.time()
		snapshot.reconciledEpoch = if warm then lastReconciled else snapshot.checkedEpoch
		local result = if unchanged then previous else snapshot
		if persisted[result] and not revoked[scope] then stopped = true; done(result, nil); return end
		local encoded, text = pcall(tern.json.encode, result)
		if not encoded or #text > mirrorLimit then
			stopped = true
			done(result, "本地镜像无法编码或超过存储上限。")
			return
		end
		mirrorIO(scope, "mirror-write", text, function(raw, err)
			local saved = raw ~= nil and raw.status == 0
			if saved then
				persisted[result] = true
				revoked[scope] = nil
			end
			if not alive() then return end
			stopped = true
			done(result, if saved then nil else "无法保存本地镜像：" .. runtime.failure(raw, err))
		end)
	end
	local function expand(kind: Kind, items: {any}, detail: boolean, ready: () -> ())
		local jobs: {{item: any, spec: Nested, seen: {[string]: boolean}}} = {}
		for _, item in items do
			for _, spec in kind.nested do
				local part = item[spec.name]
				local seen: {[string]: boolean} = {}
				if not connection(part) or not acceptChildren(spec, part.nodes, detail, seen) or (if part.pageInfo.hasNextPage
					then #part.nodes == 0 or #part.nodes >= part.totalCount else #part.nodes ~= part.totalCount) then
					fail("#" .. item.number .. " 的 " .. spec.name .. " 响应不完整。"); return
				end
				if part.pageInfo.hasNextPage then table.insert(jobs, {item = item, spec = spec, seen = seen}) end
			end
		end
		local function nextJob(index: number)
			if not alive() then return end
			local job = jobs[index]
			if not job then ready(); return end
			local item, spec = job.item, job.spec
			local part = item[spec.name]
			local query = "query(" .. repoArgs .. ",$id:ID!,$cursor:String!){" .. identitySelection
				.. " node(id:$id){... on " .. kind.typename .. "{id number updatedAt repository{id} "
				.. (if kind == pr then "headRefOid " else "") .. nestedFields(spec, detail, true) .. "}}}"
			local visited: {[string]: boolean} = {}
			local function more()
				local cursor = part.pageInfo.endCursor
				if type(cursor) ~= "string" or cursor == "" or visited[cursor] then
					fail("#" .. item.number .. " 的 " .. spec.name .. " 游标缺失或重复。"); return
				end
				visited[cursor] = true
				request(query, {id = item.id, cursor = cursor}, function(value)
					local node = value.node
					local page = if type(node) == "table" then node[spec.name] else nil
					if type(node) ~= "table" or not sameVersion(node, item) or type(node.repository) ~= "table"
						or node.repository.id ~= identity.repoId or not connection(page) or page.totalCount ~= part.totalCount
						or #page.nodes == 0 or not acceptChildren(spec, page.nodes, detail, job.seen) then
						fail("#" .. item.number .. " 的 " .. spec.name .. " 已变化或未读完。"); return
					end
					for _, child in page.nodes do table.insert(part.nodes, child) end
					part.pageInfo = page.pageInfo
					if part.pageInfo.hasNextPage and #part.nodes < part.totalCount then
						tern.timer(0, more)
					elseif not part.pageInfo.hasNextPage and #part.nodes == part.totalCount then
						nextJob(index + 1)
					else
						fail("#" .. item.number .. " 的 " .. spec.name .. " 分页数量变化。")
					end
				end)
			end
			more()
		end
		nextJob(1)
	end
	local function scan(kind: Kind, destination: {any}, old: {[string]: any}?, oldList: {any}?)
		local cursors: {[string]: boolean} = {}
		local seen: {[string]: boolean} = {}
		local numbers: {[number]: boolean} = {}
		local count: number? = nil
		local inventoryFields = if warm then index .. (if kind == pr then " " .. prIndex else "") else fields(kind, true)
		local query = "query(" .. repoArgs .. ",$cursor:String){viewer{id login} " .. repository .. "{id nameWithOwner " .. kind.name
			.. "(first:" .. (if warm then "100" else "30") .. ",after:$cursor,orderBy:{field:CREATED_AT,direction:ASC}){totalCount "
			.. paging .. " nodes{" .. inventoryFields .. "}}}}"
		local function nodeQuery(detail: boolean): string
			return "query(" .. repoArgs .. ",$ids:[ID!]!){" .. identitySelection
				.. " nodes(ids:$ids){... on " .. kind.typename .. "{repository{id} " .. fields(kind, detail) .. "}}}"
		end
		local detailQuery = if warm then nodeQuery(true) else ""
		local openProbeQuery = if warm and kind == pr then nodeQuery(false) else ""
		local function resolve(inventory: {any}, complete: ({any}) -> ())
			if not warm or not old then expand(kind, inventory, true, function() complete(inventory) end); return end
			local items: {any} = table.create(#inventory)
			local changed: {number} = {}
			local open: {number} = {}
			for position, entry in inventory do
				local prior = old[entry.id]
				if not prior or not sameIndex(entry, prior) then
					table.insert(changed, position)
				else
					items[position] = prior
					if kind == pr and entry.state == "OPEN" then table.insert(open, position) end
				end
			end
			local function load(positions: {number}, detail: boolean, use: (number, any) -> (), ready: () -> ())
				local function batch(first: number)
					if first > #positions then ready(); return end
					local ids: {string} = {}
					for i = first, math.min(first + 29, #positions) do table.insert(ids, inventory[positions[i]].id) end
					request(if detail then detailQuery else openProbeQuery, {ids = ids}, function(value)
						if type(value.nodes) ~= "table" or #value.nodes ~= #ids then fail("对象详情响应不完整。"); return end
						for offset = 1, #ids do
							local item = value.nodes[offset]
							local entry = inventory[positions[first + offset - 1]]
							if not itemShape(kind, item, detail) or not sameVersion(item, entry) or item.state ~= entry.state
								or type(item.repository) ~= "table" or item.repository.id ~= identity.repoId then
								fail("扫描期间对象已移动、删除或更新；请重新扫描。"); return
							end
							item.repository = nil
						end
						expand(kind, value.nodes, detail, function()
							for offset = 1, #ids do use(positions[first + offset - 1], value.nodes[offset]) end
							local after = first + #ids
							if after > #positions then ready() else tern.timer(0, function() batch(after) end) end
						end)
					end)
				end
				batch(1)
			end
			load(open, false, function(position, observed)
				if not sameProbe(kind, observed, items[position]) then table.insert(changed, position) end
			end, function()
				load(changed, true, function(position, item) items[position] = item end, function() complete(items) end)
			end)
		end
		local function confirmMissing()
			local missing: {string} = {}
			if old then
				for id in old do if not seen[id] then table.insert(missing, id) end end
			end
			if #missing == 0 then finish(); return end
			unchanged = false
			-- A delete/insert race can leave a connection's totalCount unchanged
			-- while skipping an existing object. Check only IDs absent from the scan.
			local lookup = "query(" .. repoArgs .. ",$ids:[ID!]!){" .. identitySelection .. " nodes(ids:$ids){id ... on "
				.. kind.typename .. "{repository{id}}}}"
			local function batch(first: number)
				local ids: {string} = {}
				for i = first, math.min(first + 29, #missing) do table.insert(ids, missing[i]) end
				request(lookup, {ids = ids}, function(value)
					if type(value.nodes) ~= "table" or #value.nodes ~= #ids then fail("缺失对象的核对响应不完整。"); return end
					for index, id in ids do
						local node = value.nodes[index]
						if node ~= tern.json.null and (not itemId(node) or node.id ~= id or not itemId(node.repository)
							or node.repository.id == identity.repoId) then
							fail("列表遗漏了仍存在的对象，或缺失对象无法核对；请重新扫描。"); return
						end
					end
					local after = first + #ids
					if after > #missing then finish() else tern.timer(0, function() batch(after) end) end
				end, true)
			end
			batch(1)
		end
		local function page(cursor: string?)
			request(query, {cursor = cursor}, function(value)
				local current = value.repository[kind.name]
				if not connection(current) or (count ~= nil and count ~= current.totalCount) then
					fail("分页响应不完整或远端列表数量已变化。"); return
				end
				local expected: number = current.totalCount
				count = expected
				for position, item in current.nodes do
					local valid = if warm then indexShape(kind, item) else itemShape(kind, item, true)
					if type(position) ~= "number" or position < 1 or position > #current.nodes
						or not valid or seen[item.id] or numbers[item.number] then
						fail("扫描期间列表变化或对象身份缺失；请重新扫描。"); return
					end
					seen[item.id], numbers[item.number] = true, true
				end
				local after = current.pageInfo.endCursor
				local hasNext = current.pageInfo.hasNextPage
				local covered = #destination + #current.nodes
				if (hasNext and (#current.nodes == 0 or covered >= expected or type(after) ~= "string" or after == "" or cursors[after]))
					or (not hasNext and covered ~= expected) then
					fail("列表游标不完整、重复或条目未读完；请重新扫描。"); return
				end
				resolve(current.nodes, function(items)
					for _, item in items do
						if unchanged and oldList and oldList[#destination + 1] ~= item then unchanged = false end
						table.insert(destination, item)
					end
					local total = #snapshot.issues + #snapshot.prs
					if progress and total > 0 and (reported == 0 or total - reported >= 150) then
						reported = total
						progress(snapshot)
					end
					if not hasNext then confirmMissing(); return end
					cursors[after] = true
					tern.timer(0, function() page(after) end)
				end)
			end)
		end
		page(nil)
	end
	scan(issue, snapshot.issues, oldIssues, if oldIssues then previous.issues else nil)
	scan(pr, snapshot.prs, oldPrs, if oldPrs then previous.prs else nil)
end

function data.store(repo: Repo, identity: any, key: string, mode: string, value: any, done: Callback)
	if #key > 180 or not key:match("^[%w_-]+$") then done(nil, "私有记录键无效。"); return end
	local scope = hex(repo.host) .. "-" .. hex(identity.repoId) .. "-" .. hex(identity.viewer:lower())
	if #scope > 240 then done(nil, "私有记录身份过长。"); return end
	local stdin = if mode == "write" or mode == "create" or mode == "append" then tern.json.encode(value) else nil
	runtime.exec({"/bin/sh", tern.plugin.dir .. "/maintenance-store.sh", tern.plugin.data, scope, key, mode}, {stdin = stdin}, function(raw, err)
		if not raw or raw.status ~= 0 then
			done(nil, if raw and raw.status == 3 then "该记录已存在或无法独占创建。" else "私有记录操作失败：" .. runtime.failure(raw, err))
			return
		end
		if mode ~= "read" and mode ~= "list" then done(true, nil); return end
		if mode == "read" and runtime.trim(raw.stdout) == "null" then done(nil, nil); return end
		local decoded, decodeError = runtime.decode(raw.stdout)
		done(decoded, decodeError)
	end)
end

return data
