--!strict

tern.on("focus", function(ev, cx: WindowCx)
	local pane = cx.session:pane(ev.pane)
	if not pane or pane.kind ~= "plugin" then return end
	local surface = cx.session:surface(ev.pane, { as = "table", depth = 0, nodes = 3 })
	if type(surface) == "table" and surface.surface.role == "plugin.ternmate.workbench" then
		cx.session:event(ev.pane, { ev = "action", id = "main", act = "return_to_list" })
	end
end)
