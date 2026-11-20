--!strict

export type Repo = { host: string, owner: string, name: string }
export type Result = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Options = { cwd: string?, env: { [string]: string }?, stdin: string?, timeout_ms: number? }
export type Exec = (argv: { string }, opts: Options?, done: (Result?, string?) -> ()) -> ()

local runtime = {}

local macGhPath: string? = nil
if tern.runtime.os == "macos" then
	local path = tern.getenv("PATH")
	macGhPath = (if path and path ~= "" then path else "/usr/bin:/bin:/usr/sbin:/sbin")
		.. ":/opt/homebrew/bin:/usr/local/bin"
end

function runtime.trim(value: string): string
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function runtime.repoKey(repo: Repo): string
	return (repo.host .. "/" .. repo.owner .. "/" .. repo.name):lower()
end

function runtime.exec(argv: { string }, opts: Options?, done: (Result?, string?) -> ())
	local options: Options = if opts then table.clone(opts) else {}
	options.timeout_ms = options.timeout_ms or 30000
	local env: { [string]: string } = if options.env then table.clone(options.env) else {}
	if argv[1] == "gh" then
		-- A GUI-launched daemon can have only the macOS system PATH.
		if macGhPath and not env.PATH then env.PATH = macGhPath end
		env.GH_PROMPT_DISABLED = "1"
		env.GH_PAGER = "cat"
		env.GH_DEBUG = ""
	end
	options.env = env
	local ok = pcall(tern.process.run, argv, options, function(result: Result)
		done(result, nil)
	end)
	if not ok then
		done(nil, "无法启动「" .. (argv[1]:match("[^/]+$") or argv[1]) .. "」：检查安装、权限和工作目录。")
	end
end

function runtime.failure(result: Result?, err: string?): string
	if not result then return err or "无法启动宿主进程。" end
	if result.timed_out then return "请求超时。检查网络后重试。" end
	local text = result.stderr:lower()
	if text:find("rate limit", 1, true) or text:find("http 429", 1, true) or result.stdout:lower():find("x%-ratelimit%-remaining:%s*0") then
		local retry = result.stdout:lower():match("retry%-after:%s*(%d+)")
		local reset = tonumber(result.stdout:lower():match("x%-ratelimit%-reset:%s*(%d+)"))
		return "GitHub 限流。" .. (if retry then "新请求请等待 " .. retry .. " 秒。" elseif reset then "可在 " .. os.date("!%Y-%m-%d %H:%M UTC", reset) .. " 后重试。" else "等待 GitHub 解除限流后重试。")
	end
	if text:find("gh auth login", 1, true) or text:find("http 401", 1, true) or text:find("bad credentials", 1, true) then
		return "GitHub 未登录或登录已失效。运行 gh auth status 检查。"
	end
	if text:find("http 403", 1, true) or text:find("resource not accessible", 1, true) or text:find("permission denied", 1, true) then
		return "权限不足。检查当前 GitHub 账号和仓库权限。"
	end
	if text:find("http 404", 1, true) or text:find("could not resolve to a repository", 1, true) then
		return "目标不存在，或当前账号无权访问。"
	end
	if text:find("network", 1, true) or text:find("no such host", 1, true) or text:find("connection", 1, true) or text:find("could not resolve host", 1, true) or text:find("dial tcp", 1, true) then
		return "无法连接。检查网络与 GitHub 主机后重试。"
	end
	return "请求失败（退出码 " .. tostring(result.status) .. "）。"
end

function runtime.decode(text: string): (any, string?)
	local ok, value = pcall(tern.json.decode, text)
	if ok and type(value) == "table" then return value, nil end
	return nil, "无法读取宿主返回的 JSON。"
end

function runtime.json(result: Result?, err: string?): (any, string?)
	if not result or result.status ~= 0 then return nil, runtime.failure(result, err) end
	return runtime.decode(result.stdout)
end

function runtime.alive(pane: number): boolean
	for _, info in tern.pane.list() do
		if info.pane == pane then return true end
	end
	return false
end

return runtime
