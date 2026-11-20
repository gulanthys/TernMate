--!strict

tern.command({
	id = "open",
	title = "New TernMate",
	icon = "git-branch",
	run = function(cx: WindowCx)
		local focused = cx.session:focused()
		local source = if focused then cx.session:pane(focused) else nil
		if not focused or not source then
			cx:toast("error", "无法打开 TernMate", "请先聚焦要分屏的来源面板。")
			return
		end
		local cwd = if source.cwd ~= "" then source.cwd else nil
		if not cx.layout:split(focused, "right", { block = "ternmate.workbench", cwd = cwd }) then
			cx:toast("error", "无法打开 TernMate", "来源面板无法分屏，或其宿主未加载 TernMate。")
		end
	end,
})

tern.on("focus", function(ev, cx: WindowCx)
	local pane = cx.session:pane(ev.pane)
	if not pane or pane.kind ~= "plugin" then return end
	local surface = cx.session:surface(ev.pane, { as = "table", depth = 0, nodes = 3 })
	if type(surface) == "table" and surface.surface.role == "plugin.ternmate.workbench" then
		cx.session:event(ev.pane, { ev = "action", id = "main", act = "return_to_list" })
	end
end)
