--!strict

local runtime = require("./runtime")
type Repo = runtime.Repo
type Callback = (any, string?) -> ()
local data = {}

local repoArgs = "$owner:String!,$name:String!"
local repository = "repository(owner:$owner,name:$name)"
local identityFields = "id nameWithOwner url visibility hasIssuesEnabled isFork defaultBranchRef{name} parent{nameWithOwner url}"
local paging = "pageInfo{hasNextPage endCursor}"
local issueFields = "id number title state url updatedAt author{login} milestone{id title url} labels(first:30){nodes{name} " .. paging .. "} assignees(first:15){nodes{login} " .. paging .. "}"
local prFields = [[
 id number title state url updatedAt author{login} headRefOid isCrossRepository isDraft mergeable reviewDecision
 closingIssuesReferences(first:25){nodes{id number url} pageInfo{hasNextPage endCursor}}
 reviewThreads(first:25){nodes{isResolved} pageInfo{hasNextPage endCursor}}
 latestReviews(first:20){nodes{url state author{login __typename} commit{oid} submittedAt} pageInfo{hasNextPage endCursor}}
 commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:1){totalCount}}}}}
]]
local nested: {[string]: {string}} = {
	issues = { "labels:nodes{name}", "assignees:nodes{login}" },
	pullRequests = {
		"closingIssuesReferences:nodes{id number url}",
		"reviewThreads:nodes{isResolved}",
		"latestReviews:nodes{url state author{login __typename} commit{oid} submittedAt}",
	},
}

local function graphql(repo: Repo, query: string, vars: { [string]: any }, done: Callback)
	vars.owner, vars.name = repo.owner, repo.name
	runtime.exec({"gh", "api", "graphql", "--hostname", repo.host, "--method", "POST", "--input", "-", "--include"},
		{stdin = tern.json.encode({query = query, variables = vars})}, function(raw, err)
			if not raw or raw.status ~= 0 then done(nil, runtime.failure(raw, err)); return end
			local body = raw.stdout:match("\r?\n\r?\n(.+)")
			local payload = if body then runtime.decode(body) else nil
			if not payload or type(payload.data) ~= "table" or (type(payload.errors) == "table" and #payload.errors > 0) then
				done(nil, "GitHub 返回不完整的维护数据。")
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
	graphql(repo, "query(" .. repoArgs .. "){viewer{login} " .. repository .. "{" .. identityFields .. "}}", {}, function(value, err)
		if not value then done(nil, err); return end
		local r, user = value.repository, value.viewer
		if not checkedRepo(repo, r) or type(user) ~= "table" or type(user.login) ~= "string" then
			done(nil, "无法核对仓库与登录账号。"); return
		end
		done({repoId = r.id, viewer = user.login, visibility = r.visibility, hasIssues = r.hasIssuesEnabled,
			defaultBranch = if type(r.defaultBranchRef) == "table" then r.defaultBranchRef.name else nil,
			webUrl = r.url, isFork = r.isFork, parent = r.parent}, nil)
	end)
end

function data.fetch(repo: Repo, identity: any, alive: () -> boolean, done: Callback, progress: ((any) -> ())?)
	local snapshot: any = {repoId = identity.repoId, viewer = identity.viewer, issues = {}, prs = {}, complete = false,
		observedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time())}
	local remaining = 2
	local errors: {string} = {}
	local reported = 0
	local function finish(err: string?)
		if err then table.insert(errors, err) end
		remaining -= 1
		if remaining ~= 0 then return end
		snapshot.complete = #errors == 0
		snapshot.error = if #errors > 0 then table.concat(errors, " · ") else nil
		done(snapshot, snapshot.error)
	end
	local function expand(connection: string, items: {any}, donePage: () -> ())
		local queued: {{item: any, name: string, fields: string}} = {}
		for _, item in items do
			for _, selector in nested[connection] do
				local name, fields = selector:match("^([^:]+):(.+)$")
				assert(name and fields)
				local partial = item[name]
				if type(partial) == "table" and type(partial.pageInfo) == "table" and partial.pageInfo.hasNextPage then
					table.insert(queued, {item = item, name = name, fields = fields})
				end
			end
		end
		local function nextItem(index: number)
			if not alive() then return end
			local target = queued[index]
			if not target then donePage(); return end
			local item = target.item
			local isIssue = connection == "issues"
			local query = "query($id:ID!,$cursor:String){viewer{login} node(id:$id){... on " .. (if isIssue then "Issue" else "PullRequest")
				.. "{id " .. (if isIssue then "updatedAt" else "headRefOid") .. " " .. target.name
				.. "(first:50,after:$cursor){" .. target.fields .. " " .. paging .. "}}}}"
			local visited: {[string]: boolean} = {}
			local partial = item[target.name]
			local function more()
				if not alive() then return end
				local cursor = partial.pageInfo.endCursor
				if type(cursor) ~= "string" or visited[cursor] then
					table.insert(errors, "#" .. item.number .. " 的 " .. target.name .. " 游标不完整。")
					nextItem(index + 1); return
				end
				visited[cursor] = true
				graphql(repo, query, {id = item.id, cursor = cursor}, function(value, err)
					if not alive() then return end
					local node = value and value.node
					local result = if type(node) == "table" then node[target.name] else nil
					if not value or type(value.viewer) ~= "table" or value.viewer.login ~= identity.viewer
						or type(node) ~= "table" or node.id ~= item.id
						or (if isIssue then node.updatedAt ~= item.updatedAt else node.headRefOid ~= item.headRefOid)
						or type(result) ~= "table" or type(result.nodes) ~= "table" or type(result.pageInfo) ~= "table"
						or type(result.pageInfo.hasNextPage) ~= "boolean" then
						table.insert(errors, "#" .. item.number .. " 的 " .. target.name .. " 不完整：" .. (err or "版本或响应已变化。"))
						nextItem(index + 1); return
					end
					for _, child in result.nodes do table.insert(partial.nodes, child) end
					partial.pageInfo = result.pageInfo
					if partial.pageInfo.hasNextPage then tern.timer(0, more) else nextItem(index + 1) end
				end)
			end
			more()
		end
		nextItem(1)
	end
	local function scan(connection: string, fields: string, destination: {any})
		local cursors: {[string]: boolean} = {}
		local seen: {[string]: boolean} = {}
		local query = "query(" .. repoArgs .. ",$cursor:String){viewer{login} " .. repository .. "{id nameWithOwner " .. connection
			.. "(first:30,after:$cursor,orderBy:{field:CREATED_AT,direction:ASC}){" .. paging .. " nodes{" .. fields .. "}}}}"
		local function page(cursor: string?)
			if not alive() then return end
			graphql(repo, query, {cursor = cursor}, function(value, err)
				if not alive() then return end
				if not value then finish(err or "扫描中断。"); return end
				local r, user = value.repository, value.viewer
				if not checkedRepo(repo, r) or r.id ~= identity.repoId or type(user) ~= "table" or user.login ~= identity.viewer then
					finish("扫描期间仓库或账号变化。"); return
				end
				local con = r[connection]
				if type(con) ~= "table" or type(con.nodes) ~= "table" or type(con.pageInfo) ~= "table"
					or type(con.pageInfo.hasNextPage) ~= "boolean" then finish("分页响应不完整。"); return end
				for _, item in con.nodes do
					if type(item) ~= "table" or type(item.id) ~= "string" or type(item.number) ~= "number" or type(item.title) ~= "string" or seen[item.id] then
						finish("扫描期间列表变化或对象身份缺失；请刷新。"); return
					end
					seen[item.id] = true
					table.insert(destination, item)
				end
				expand(connection, con.nodes, function()
					local total = #snapshot.issues + #snapshot.prs
					if progress and (reported == 0 or total - reported >= 150) then
						reported = total
						progress(snapshot)
					end
					if not con.pageInfo.hasNextPage then finish(nil); return end
					local nextCursor = con.pageInfo.endCursor
					if type(nextCursor) ~= "string" or cursors[nextCursor] then finish("分页游标缺失或重复。"); return end
					cursors[nextCursor] = true
					tern.timer(0, function() page(nextCursor) end)
				end)
			end)
		end
		page(nil)
	end
	scan("issues", issueFields, snapshot.issues)
	scan("pullRequests", prFields, snapshot.prs)
end

local function hex(value: string): string
	return (value:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end))
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
