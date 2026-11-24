--!strict

local runtime = require("./runtime")
type Repo = runtime.Repo
type Callback = (any, string?) -> ()
type SyncCallback = (any, string?, boolean?, boolean?) -> ()
type Progress = ("issues" | "prs", {any}) -> ()
type Nested = {name: string, first: number, fields: string, detail: string?, args: string?}
type Kind = {name: string, typename: string, scalars: string, keys: {string}, nested: {Nested}}
export type Identity = {
	repoId: string, viewerId: string, viewer: string, visibility: string, hasIssues: boolean,
	defaultBranch: string?, webUrl: string, isFork: boolean, parent: any,
}
local data = {}

local repoArgs = "$owner:String!,$name:String!"
local repository = "repository(owner:$owner,name:$name)"
local identitySelection = "viewer{id login} " .. repository .. "{id nameWithOwner}"
local identityFields = "id nameWithOwner url visibility hasIssuesEnabled isFork defaultBranchRef{name} parent{nameWithOwner url}"
local paging = "pageInfo{hasNextPage endCursor}"
local index = "id number updatedAt state"
local prIndex = "headRefOid baseRefName isDraft reviewDecision"
local issue: Kind = {
	name = "issues", typename = "Issue", scalars = "stateReason milestone{id title url}",
	keys = {"milestone", "stateReason"},
	nested = {
		{name = "labels", first = 30, fields = "id name"},
		{name = "assignees", first = 15, fields = "id login"},
		{name = "closedByPullRequestsReferences", first = 10, args = ",includeClosedPrs:true",
			fields = "id number state isDraft repository{id nameWithOwner}"},
	},
}
local pr: Kind = {
	name = "pullRequests", typename = "PullRequest",
	scalars = prIndex .. " isCrossRepository mergeable bodyHTML "
		.. "commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:1){totalCount}}}}}",
	keys = {"headRefOid", "baseRefName", "isCrossRepository", "isDraft", "mergeable", "reviewDecision", "commits", "bodyIssueReferences"},
	nested = {
		{name = "labels", first = 30, fields = "id name"},
		{name = "closingIssuesReferences", first = 25, fields = "id number url"},
		{name = "reviewThreads", first = 25, fields = "id isResolved"},
		{name = "latestReviews", first = 20, fields = "id state author{login __typename} commit{oid} submittedAt", detail = "url"},
		{name = "reviewRequests", first = 20, fields = "id requestedReviewer{__typename ... on User{login}}"},
	},
}

local function nestedFields(spec: Nested, detail: boolean, after: boolean): string
	return spec.name .. (if after then "(first:50,after:$cursor" else "(first:" .. spec.first) .. (spec.args or "") .. ")"
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

local function identityScope(repo: Repo, identity: any): string?
	if repo.host == "" or type(identity) ~= "table" or type(identity.repoId) ~= "string" or identity.repoId == ""
		or type(identity.viewerId) ~= "string" or identity.viewerId == "" then return nil end
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
	if spec.name == "closedByPullRequestsReferences" then
		return type(value.number) == "number" and value.number > 0 and value.number % 1 == 0
			and (value.state == "OPEN" or value.state == "MERGED" or value.state == "CLOSED")
			and type(value.isDraft) == "boolean" and itemId(value.repository) and type(value.repository.nameWithOwner) == "string"
	end
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
			-- Legacy caches are still browseable; the next scan hydrates this evidence.
			if spec.name == "closedByPullRequestsReferences" and value == nil then continue end
			if not connection(value) or value.pageInfo.hasNextPage or #value.nodes ~= value.totalCount then return nil end
			if not acceptChildren(spec, value.nodes, true, {}) then return nil end
		end
		if kind == pr and item.bodyIssueReferences ~= nil then
			local refs = item.bodyIssueReferences
			if type(refs) ~= "table" or type(refs.nodes) ~= "table" or type(refs.complete) ~= "boolean" then return nil end
			for _, node in refs.nodes do
				if type(node) ~= "table" or type(node.number) ~= "number" or node.number < 1 or node.number % 1 ~= 0
					or type(node.url) ~= "string" then return nil end
			end
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

local persisted: {[any]: string} = {}
setmetatable(persisted, {__mode = "k"})
local revoked: {[string]: boolean} = {}
local mirrorLimit = 128 * 1024 * 1024

local function validGeneration(value: any): boolean
	return type(value) == "string" and value:match("^%d+%-%w+$") ~= nil
end

local function validRevision(value: any): boolean
	return type(value) == "string" and (value == "0" or value:match("^r[1-9]%d*$") ~= nil)
end

local function validEpoch(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0
end

local function mirrorIO(scope: string, mode: string, stdin: string?, done: (runtime.Result?, string?) -> (), ...: string)
	runtime.exec({"/bin/sh", tern.plugin.dir .. "/maintenance-store.sh", tern.plugin.data, scope, "snapshot", mode, ...},
		{stdin = stdin}, done)
end

function data.cached(repo: Repo, identity: Identity, done: Callback)
	local scope = identityScope(repo, identity)
	if not scope then done(nil, "本地镜像身份无效。"); return end
	if revoked[scope] then done(nil, nil); return end
	mirrorIO(scope, "mirror-probe", nil, function(raw, err)
		if revoked[scope] then done(nil, nil); return end
		if not raw or raw.status ~= 0 then done(nil, "无法打开本地镜像：" .. runtime.failure(raw, err)); return end
		local probe = runtime.trim(raw.stdout)
		if probe == "false" then done(nil, nil); return end
		local revision, stamp = probe:match("^true\n([^\n]+)\n?(.*)$")
		if not revision or not validRevision(revision) then done(nil, "本地镜像失效标记无效。"); return end
		-- Process stdout is capped at 16 MiB. Read the atomic file itself, with a bound
		-- that also rejects non-regular files and final-component symlinks.
		local path = tern.plugin.data .. "/maintenance-mirror-v1/" .. scope .. "/snapshot.json"
		local ok, text = pcall(tern.fs.read, path, mirrorLimit + 128) -- Allow the generation envelope.
		if not ok then done(nil, "无法读取本地镜像文件。"); return end
		local value = runtime.decode(text)
		local generation: string? = nil
		if type(value) == "table" and validGeneration(value.generation) then
			generation, value = value.generation, value.snapshot
		end
		if not sameScope(repo, identity, value) then done(nil, "本地镜像不完整或身份不符。"); return end
		if value.repoUrl ~= identity.webUrl then done(nil, nil); return end
		local cachedIssues = indexItems(issue, value.issues)
		local cachedPrs = indexItems(pr, value.prs)
		if not cachedIssues or not cachedPrs then
			done(nil, "本地镜像不完整。"); return
		end
		value.viewer = identity.viewer -- Login can change; the cache key cannot.
		local confirmed = value.resultRevision or "0"
		if generation then
			local stamped, checked, reconciled, checkedRevision = (stamp or ""):match("^(%d+%-%w+) (%d+) (%d+) ?(%S*)$")
			local checkedEpoch, reconciledEpoch = tonumber(checked), tonumber(reconciled)
			-- Read and probe can straddle a concurrent replacement. Only trust a
			-- stamp for the exact payload we read, never the prior generation.
			if stamped == generation and validEpoch(checkedEpoch) and validEpoch(reconciledEpoch) then
				value.reconciledEpoch = reconciledEpoch
				if (if checkedRevision == "" then "0" else checkedRevision) == revision then
					value.checkedEpoch, confirmed = checkedEpoch, revision
				end
			end
			persisted[value] = generation
		end
		value.resultRevision = confirmed
		if confirmed ~= revision then value.checkedEpoch = nil end
		for _, item in cachedIssues do
			if not item.closedByPullRequestsReferences then value.checkedEpoch = nil; break end
		end
		for _, item in cachedPrs do
			if not item.bodyIssueReferences then value.checkedEpoch = nil; break end
		end
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

local function pageError(kind: Kind, current: any, detail: boolean, covered: number, expected: number?,
	seen: {[string]: boolean}, numbers: {[number]: boolean}, cursors: {[string]: boolean}): string?
	if not connection(current) or (expected ~= nil and expected ~= current.totalCount) then
		return "分页响应不完整或远端列表数量已变化。"
	end
	for position, item in current.nodes do
		local valid = if detail then itemShape(kind, item, true) else indexShape(kind, item)
		if type(position) ~= "number" or position < 1 or position > #current.nodes
			or not valid or seen[item.id] or numbers[item.number] then
			return "扫描期间列表变化或对象身份缺失；请重新扫描。"
		end
		seen[item.id], numbers[item.number] = true, true
	end
	local after, hasNext = current.pageInfo.endCursor, current.pageInfo.hasNextPage
	covered += #current.nodes
	if (hasNext and (#current.nodes == 0 or covered >= current.totalCount or type(after) ~= "string" or after == "" or cursors[after]))
		or (not hasNext and covered ~= current.totalCount) then
		return "列表游标不完整、重复或条目未读完；请重新扫描。"
	end
	return nil
end

local function bodyIssueReferences(html: any): any
	local refs = {nodes = {}, complete = type(html) == "string"}
	if type(html) ~= "string" then return refs end
	local seen: {[string]: boolean} = {}
	for attributes in html:gmatch("<a%s+([^>]-)>") do
		local values: {[string]: string} = {}
		for key, quote, value in attributes:gmatch("([%w_-]+)%s*=%s*(['\"])(.-)%2") do
			values[key] = value
		end
		-- GitHub's rendered links distinguish Issues from PRs even for plain
		-- “关联 #522”. Do not infer types from “#number” or data-url (PRs use /issues/ there too).
		if values["data-hovercard-type"] ~= "issue" then continue end
		local url = values.href
		local number = if url then tonumber(url:match("^https://[^/]+/[^/]+/[^/]+/issues/(%d+)$")) else nil
		if not number or number < 1 then refs.complete = false; continue end
		if not seen[url] then
			seen[url] = true
			table.insert(refs.nodes, {number = number, url = url})
		end
	end
	return refs
end

local function expand(identity: Identity, request: (string, {[string]: any}, (any) -> ()) -> (),
	fail: (string) -> (), alive: () -> boolean, kind: Kind, items: {any}, detail: boolean, ready: () -> ())
	local jobs: {{item: any, spec: Nested, seen: {[string]: boolean}}} = {}
	for _, item in items do
		if kind == pr then
			-- Persist only the resolved Issue identifiers, never the PR body.
			item.bodyIssueReferences = bodyIssueReferences(item.bodyHTML)
			item.bodyHTML = nil
		end
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

local function syncScope(repo: Repo, identity: Identity, scope: string, revision: string, previous: any,
	isAlive: () -> boolean, done: SyncCallback, progress: Progress?, lastVisible: any?)
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
		observedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", now), resultRevision = revision}
	local unchanged = oldIssues ~= nil and oldPrs ~= nil
		and previous.repoUrl == identity.webUrl and previous.viewer == identity.viewer
	local remaining = 2
	local stopped = false
	local function alive(): boolean return not stopped and isAlive() end
	local function fail(err: string?, scopeChanged: boolean?, revisionChanged: boolean?)
		if not alive() then return end
		stopped = true
		if scopeChanged or revisionChanged then
			done(nil, err, scopeChanged, revisionChanged)
			return
		end
		-- A new Issue can change the connection count before publication.
		-- Detect that local invalidation even if pagination aborted first.
		data.resultRevision(repo, identity, function(latest)
			if not isAlive() then return end
			if latest and latest ~= revision then done(nil, nil, nil, true)
			else done(nil, err) end
		end)
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
		local function settle(result: any, err: string?)
			if not alive() then return end
			stopped = true
			result.checkedEpoch, result.reconciledEpoch = snapshot.checkedEpoch, snapshot.reconciledEpoch
			if not err then result.resultRevision = revision end
			done(result, err)
		end
		local generation = if unchanged and not revoked[scope] then persisted[previous] else nil
		if generation then
			mirrorIO(scope, "mirror-stamp", nil, function(raw, err)
				if not alive() then return end
				if raw and raw.status == 5 then fail(nil, nil, true); return end
				-- Missing/replaced payload: don't attach freshness to it or
				-- overwrite it based on this stamp attempt. Retry on a later sync.
				if raw and raw.status == 4 then persisted[previous] = nil end
				settle(previous, if raw and raw.status == 0 then nil else "无法保存本地镜像核对时间：" .. runtime.failure(raw, err))
			end, revision, generation, tostring(snapshot.checkedEpoch), tostring(snapshot.reconciledEpoch))
			return
		end
		local encoded, text = pcall(tern.json.encode, snapshot)
		if not encoded or #text > mirrorLimit then
			settle(snapshot, "本地镜像无法编码或超过存储上限。")
			return
		end
		if not alive() then return end
		mirrorIO(scope, "mirror-write", text, function(raw, err)
			if not alive() then return end
			if raw and raw.status == 5 then fail(nil, nil, true); return end
			if not raw or raw.status ~= 0 then
				settle(snapshot, "无法保存本地镜像：" .. runtime.failure(raw, err)); return
			end
			local saved = runtime.trim(raw.stdout)
			if not validGeneration(saved) then settle(snapshot, "本地镜像版本无效。"); return end
			persisted[snapshot] = saved
			revoked[scope] = nil
			settle(snapshot, nil)
		end, revision)
	end
	local function scan(kind: Kind, destination: {any}, old: {[string]: any}?)
		local cursors: {[string]: boolean} = {}
		local seen: {[string]: boolean} = {}
		-- A failed scan can leave newer rows visible without changing the
		-- complete mirror. Compare progress against those rows independently.
		local visible = old
		if lastVisible then
			local rows: {[string]: any} = {}
			for _, item in lastVisible[if kind == issue then "issues" else "prs"] do rows[item.id] = item end
			visible = rows
		end
		local numbers: {[number]: boolean} = {}
		local count: number? = nil
		local progressKind: "issues" | "prs" = if kind == issue then "issues" else "prs"
		local detailFields = fields(kind, true)
		local inventoryFields = if warm then index .. (if kind == pr then " " .. prIndex else "") else detailFields
		local function pageQuery(first: number, selection: string): string
			return "query(" .. repoArgs .. ",$cursor:String){viewer{id login} " .. repository .. "{id nameWithOwner " .. kind.name
				.. "(first:" .. first .. ",after:$cursor,orderBy:{field:CREATED_AT,direction:DESC}){totalCount "
				.. paging .. " nodes{" .. selection .. "}}}}"
		end
		-- Start each connection with recent details, then continue the same
		-- creation-ordered cursor without making warm scans fetch all details.
		local firstQuery = pageQuery(20, detailFields)
		local nextQuery = pageQuery(if warm then 100 else 30, inventoryFields)
		-- Old mirrors can be ordered differently. Match by stable node ID.
		local function publish(items: {any})
			local updates: {any}? = nil
			for _, item in items do
				local prior = old and old[item.id]
				if unchanged and not equal(item, prior) then unchanged = false end
				if progress and not equal(item, visible and visible[item.id]) then
					local batch = updates or {}
					table.insert(batch, item)
					updates = batch
				end
			end
			if progress and updates and alive() then progress(progressKind, updates) end
		end
		local function nodeQuery(selection: string): string
			return "query(" .. repoArgs .. ",$ids:[ID!]!){" .. identitySelection
				.. " nodes(ids:$ids){... on " .. kind.typename .. "{repository{id} " .. selection .. "}}}"
		end
		local detailQuery = if warm then nodeQuery(detailFields) else ""
		local openProbeQuery = if warm then nodeQuery(fields(kind, false)) else ""
		local function resolve(inventory: {any}, detail: boolean, complete: ({any}) -> ())
			if detail then
				expand(identity, request, fail, alive, kind, inventory, true, function()
					publish(inventory)
					if alive() then complete(inventory) end
				end)
				return
			end
			local items: {any} = table.create(#inventory)
			local changed: {number} = {}
			local open: {number} = {}
			for position, entry in inventory do
				local prior = old and old[entry.id]
				if not prior or not sameIndex(entry, prior) or (kind == issue and not prior.closedByPullRequestsReferences)
					or (kind == pr and not prior.bodyIssueReferences)
					or (lastVisible and visible and visible[entry.id] ~= prior) then
					table.insert(changed, position)
				else
					items[position] = prior
					if entry.state == "OPEN" then table.insert(open, position) end
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
						expand(identity, request, fail, alive, kind, value.nodes, detail, function()
							for offset = 1, #ids do use(positions[first + offset - 1], value.nodes[offset]) end
							if detail then publish(value.nodes) end
							if not alive() then return end
							local after = first + #ids
							if after > #positions then ready() else tern.timer(0, function() batch(after) end) end
						end)
					end)
				end
				batch(1)
			end
			local function useDetail(position: number, item: any) items[position] = item end
			-- Publish known changes before probing unchanged open PRs for
			-- reviews and checks that can move without an index change.
			load(changed, true, useDetail, function()
				table.clear(changed)
				load(open, false, function(position, observed)
					if not sameProbe(kind, observed, items[position]) then table.insert(changed, position) end
				end, function()
					load(changed, true, useDetail, function() complete(items) end)
				end)
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
			local detail = cursor == nil or not warm
			request(if cursor == nil then firstQuery else nextQuery, {cursor = cursor}, function(value)
				local current = value.repository[kind.name]
				local err = pageError(kind, current, detail, #destination, count, seen, numbers, cursors)
				if err then fail(err); return end
				count = current.totalCount
				local after = current.pageInfo.endCursor
				local hasNext = current.pageInfo.hasNextPage
				resolve(current.nodes, detail, function(items)
					for _, item in items do table.insert(destination, item) end
					if not hasNext then confirmMissing(); return end
					cursors[after] = true
					tern.timer(0, function() page(after) end)
				end)
			end)
		end
		page(nil)
	end
	scan(issue, snapshot.issues, oldIssues)
	scan(pr, snapshot.prs, oldPrs)
end

-- Refresh volatile PR evidence independently of the historical mirror sweep.
-- Every returned row is freshly hydrated; no cache writes or freshness stamps.
function data.refreshPRs(repo: Repo, identity: Identity, previous: any, isAlive: () -> boolean,
	done: (any, string?, boolean?) -> ())
	if not isAlive() then return end
	if not identityScope(repo, identity) or type(identity.viewer) ~= "string" or identity.viewer == "" then
		done(nil, "无法核对仓库与登录账号。", true); return
	end
	local old: {[string]: any}? = nil
	if previous ~= nil then
		if not sameScope(repo, identity, previous) then done(nil, "PR 基线身份不符。", true); return end
		old = indexItems(pr, previous.prs)
		if not old then done(nil, "PR 基线不完整。"); return end
	end
	local stopped = false
	local rows: {any} = {}
	local seen: {[string]: boolean} = {}
	local numbers: {[number]: boolean} = {}
	local cursors: {[string]: boolean} = {}
	local count: number? = nil
	local function alive(): boolean return not stopped and isAlive() end
	local function fail(err: string, identityChanged: boolean?)
		if not alive() then return end
		stopped = true
		done(nil, err, identityChanged)
	end
	local function request(query: string, vars: {[string]: any}, received: (any) -> ())
		if not alive() then return end
		graphql(repo, query, vars, function(value, err, identityChanged)
			if not alive() then return end
			if not value then fail(err or "PR 刷新中断。", identityChanged); return end
			local r, user = value.repository, value.viewer
			if not checkedRepo(repo, r) or r.id ~= identity.repoId or type(user) ~= "table"
				or user.id ~= identity.viewerId or user.login ~= identity.viewer then
				fail("刷新期间仓库或账号身份无法核对；请刷新。", true); return
			end
			received(value)
		end)
	end
	local selection = fields(pr, true)
	local lookup = "query(" .. repoArgs .. ",$ids:[ID!]!){" .. identitySelection
		.. " nodes(ids:$ids){... on PullRequest{repository{id nameWithOwner} " .. selection .. "}}}"
	local function finish()
		if not alive() then return end
		stopped = true
		done(rows, nil)
	end
	local function transitioned()
		local missing: {string} = {}
		if old then
			for id, item in old do
				if item.state == "OPEN" and not seen[id] then table.insert(missing, id) end
			end
		end
		local function batch(first: number)
			if not alive() then return end
			if first > #missing then finish(); return end
			local ids: {string} = {}
			for i = first, math.min(first + 29, #missing) do table.insert(ids, missing[i]) end
			request(lookup, {ids = ids}, function(value)
				if type(value.nodes) ~= "table" or #value.nodes ~= #ids then fail("缺失 PR 的响应不完整。"); return end
				for position, id in ids do
					local item = value.nodes[position]
					local prior = old and old[id]
					if not itemShape(pr, item, true) or item.id ~= id or not prior or item.number ~= prior.number
						or (item.state ~= "CLOSED" and item.state ~= "MERGED") or numbers[item.number]
						or not checkedRepo(repo, item.repository) or item.repository.id ~= identity.repoId then
						fail("PR 列表遗漏了开放对象，或对象已移动、删除；请重新刷新。"); return
					end
					numbers[item.number] = true
					item.repository = nil
				end
				expand(identity, request, fail, alive, pr, value.nodes, true, function()
					for _, item in value.nodes do table.insert(rows, item) end
					if alive() then tern.timer(0, function() batch(first + #ids) end) end
				end)
			end)
		end
		batch(1)
	end
	local query = "query(" .. repoArgs .. ",$cursor:String){viewer{id login} " .. repository
		.. "{id nameWithOwner pullRequests(first:30,after:$cursor,states:[OPEN],orderBy:{field:CREATED_AT,direction:DESC})"
		.. "{totalCount " .. paging .. " nodes{" .. selection .. "}}}}"
	local function page(cursor: string?)
		request(query, {cursor = cursor}, function(value)
			local current = value.repository.pullRequests
			local err = pageError(pr, current, true, #rows, count, seen, numbers, cursors)
			if err then fail(err); return end
			count = current.totalCount
			for _, item in current.nodes do
				if item.state ~= "OPEN" then fail("开放 PR 列表在刷新期间发生变化。"); return end
			end
			local after, hasNext = current.pageInfo.endCursor, current.pageInfo.hasNextPage
			expand(identity, request, fail, alive, pr, current.nodes, true, function()
				for _, item in current.nodes do table.insert(rows, item) end
				if not alive() then return end
				if not hasNext then transitioned(); return end
				cursors[after] = true
				tern.timer(0, function() page(after) end)
			end)
		end)
	end
	page(nil)
end

function data.resultRevision(repo: Repo, identity: Identity, done: (string?, string?) -> ())
	local scope = identityScope(repo, identity)
	if not scope then done(nil, "本地镜像身份无效。"); return end
	-- Local read only: the immutable result records are the source of truth,
	-- independently of whether the mirror directory can be written.
	mirrorIO(scope, "mirror-revision", nil, function(raw, err)
		if not raw or raw.status ~= 0 then done(nil, "无法核对本地提交结果版本：" .. runtime.failure(raw, err)); return end
		local revision = runtime.trim(raw.stdout)
		if not validRevision(revision) then done(nil, "本地提交结果版本无效。"); return end
		done(revision, nil)
	end)
end

function data.sync(repo: Repo, identity: Identity, previous: any, isAlive: () -> boolean, done: SyncCallback,
	progress: Progress?, lastVisible: any?)
	if not isAlive() then return end
	local scope = identityScope(repo, identity)
	if not scope then done(nil, "本地镜像身份无效。", true); return end
	-- Capture the version before any GitHub read to fence out pre-receipt scans.
	data.resultRevision(repo, identity, function(revision, err)
		if not isAlive() then return end
		if not revision then done(nil, err); return end
		syncScope(repo, identity, scope, revision, previous, isAlive, done, progress, lastVisible)
	end)
end

function data.store(repo: Repo, identity: any, key: string, mode: string, value: any, done: Callback)
	if #key > 180 or not key:match("^[%w_-]+$") then done(nil, "私有记录键无效。"); return end
	local scope = identityScope(repo, identity)
	if not scope then done(nil, "私有记录身份无效。"); return end
	local structured = mode == "draft-save" or mode == "draft-settle"
	local stdin = if mode == "write" or mode == "create" or mode == "append" or structured then tern.json.encode(value) else nil
	runtime.exec({"/bin/sh", tern.plugin.dir .. "/maintenance-store.sh", tern.plugin.data, scope, key, mode}, {stdin = stdin}, function(raw, err)
		if not raw or raw.status ~= 0 then
			done(nil, if raw and raw.status == 3 then "该记录已存在或无法独占创建。" else "私有记录操作失败：" .. runtime.failure(raw, err))
			return
		end
		if mode ~= "read" and mode ~= "list" and not structured then done(true, nil); return end
		if mode == "read" and runtime.trim(raw.stdout) == "null" then done(nil, nil); return end
		local decoded, decodeError = runtime.decode(raw.stdout)
		done(decoded, decodeError)
	end)
end

function data.createIssue(repo: Repo, identity: Identity, slot: number, draft: any, title: string, body: string,
	labelIds: {string}?, done: (string?) -> ())
	local scope = identityScope(repo, identity)
	if not scope then done("storage_error"); return end
	local stdin = tern.json.encode({host=repo.host, owner=repo.owner, name=repo.name, identity=identity,
		slot=slot, draft=draft, title=title, body=body, labelIds=labelIds})
	runtime.exec({"/usr/bin/ruby", tern.plugin.dir .. "/issue-create.rb", tern.plugin.data, scope},
		{stdin=stdin, cwd="/", timeout_ms=45000, env={RUBYOPT="", RUBYLIB="", BUNDLE_GEMFILE="", GEM_HOME="", GEM_PATH=""}},
		function(raw)
			done(if raw and raw.status == 0 then runtime.trim(raw.stdout) else nil)
		end)
end

return data
