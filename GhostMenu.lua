--[[
	GhostMenu (LocalScript)
	PUT IT IN: StarterPlayer > StarterPlayerScripts   (nothing else needed, the UI is built by code)

	- Every player gets a white, semi-transparent "ghost" clone of their avatar that replays
	  the last RECORD_SECONDS of their movement (it trails the real player by that long).
	- Everything runs on the client only, so it costs the server nothing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Market = game:GetService("MarketplaceService")
local lp = Players.LocalPlayer

------------------------------------------------------------------ CONFIG
local CFG = {
	RECORD_SECONDS = 10,        -- how much movement is kept / how far behind the ghost trails
	SAMPLE_HZ = 15,             -- recording rate (ghosts are interpolated, so 15 looks smooth)
	GHOST_TRANSPARENCY = 0.55,
	MENU_TRANSPARENCY = 0.8,    -- menu + closed icon
	WIDGET_TRANSPARENCY = 0.4,  -- boxes inside the menu (kept more solid so text stays readable)
	MENU_COLOR = Color3.fromRGB(255, 208, 140),
	GAME_NAME = nil,            -- nil = auto from the place name
	ICON_IN_CLOSED = true,      -- show the game icon inside the closed (draggable) box
	TAP_SLOP = 10,              -- px a finger may move and still count as a tap
	DRAG_SLOP = 8,              -- px a finger must move before the closed icon starts dragging
}

local INK, WHITE = Color3.new(0, 0, 0), Color3.new(1, 1, 1)
local C = {
	cyan = Color3.fromRGB(150, 235, 255),
	green = Color3.fromRGB(150, 255, 150),
	pink = Color3.fromRGB(255, 115, 200),
	red = Color3.fromRGB(255, 140, 140),
	grey = Color3.fromRGB(184, 172, 172),
}

local STEP = 1 / CFG.SAMPLE_HZ
local CAP = math.ceil(CFG.RECORD_SECONDS * CFG.SAMPLE_HZ) + 2   -- ring buffer length (frames)
local recs, conns, hooks = {}, {}, {}   -- recs[Player] = record
local ghostsOn, dead, sel, leaveCount, order = true, false, nil, 0, 0

local function conn(c) conns[#conns + 1] = c return c end

------------------------------------------------------------------ SMALL HELPERS
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props do o[k] = v end
	o.Parent = parent
	return o
end
local function round(o, px) new("UICorner", { CornerRadius = UDim.new(0, px or 8) }, o) return o end
local function pill(o) new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, o) return o end
local function stroke(o, th)
	return new("UIStroke", { Thickness = th or 2, Color = INK, Transparency = 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end
local function label(p, parent, class)
	local o = Instance.new(class or "TextLabel")
	o.Text = ""
	o.BackgroundTransparency = 1
	o.BorderSizePixel = 0
	o.Font = Enum.Font.GothamMedium
	o.TextColor3 = INK
	o.TextSize = 13
	if o:IsA("TextButton") then o.AutoButtonColor = false o.Selectable = false end
	for k, v in p do o[k] = v end
	o.Parent = parent
	return o
end
local function box(p, parent, color, class)
	p.BackgroundColor3 = color or C.cyan
	p.BackgroundTransparency = CFG.WIDGET_TRANSPARENCY
	local o = label(p, parent, class)
	round(o, 8)
	stroke(o, 1.5)
	return o
end
local function fit(o, max)
	o.TextScaled = true
	new("UITextSizeConstraint", { MaxTextSize = max or 13, MinTextSize = 7 }, o)
	return o
end
local function esc(s) return (tostring(s):gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })) end
local function thumb(id, px) return ("rbxthumb://type=AvatarHeadShot&id=%d&w=%d&h=%d"):format(id, px, px) end
local function fmt(s)
	s = math.floor(s)
	if s >= 3600 then return ("%dh %02dm"):format(s // 3600, s % 3600 // 60) end
	return ("%dm %02ds"):format(s // 60, s % 60)
end

------------------------------------------------------------------ GHOST CORE
local ghostFolder = new("Folder", { Name = "_Ghosts" }, workspace)
local cubeFolder = new("Folder", { Name = "_GhostCubes" }, workspace)

-- things removed from the avatar clone (it only needs meshes + accessory welds)
local JUNK = {
	Motor6D = true, Humanoid = true, Animator = true, BodyColors = true, Shirt = true, Pants = true,
	ShirtGraphic = true, SurfaceAppearance = true, Sound = true, ParticleEmitter = true, Trail = true,
	Beam = true, Fire = true, Smoke = true, Sparkles = true, ForceField = true, BillboardGui = true,
	PointLight = true, SpotLight = true, SurfaceLight = true, Highlight = true,
}

local function buildGhost(char)
	local was = char.Archivable
	char.Archivable = true
	local g = char:Clone()
	char.Archivable = was
	if not g then return nil end
	g.Name = "Ghost"
	for _, d in g:GetDescendants() do
		if JUNK[d.ClassName] or d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored, d.CanCollide, d.CanTouch, d.CanQuery, d.CastShadow = true, false, false, false, false
			d.Color, d.Material = WHITE, Enum.Material.SmoothPlastic
			d.Transparency = d.Transparency >= 0.95 and 1 or CFG.GHOST_TRANSPARENCY
			if d:IsA("MeshPart") then d.TextureID = "" end
		elseif d:IsA("SpecialMesh") then
			d.TextureId = ""
		elseif d:IsA("Decal") then
			d.Transparency = CFG.GHOST_TRANSPARENCY
		end
	end
	return g
end

-- ring buffer: ts[slot] = time, cf[(slot-1)*np + i] = CFrame of body part i
local function record(r, now)
	local parts, root = r.parts, r.root
	if not parts or not root.Parent then return end
	local np = r.np
	local n = r.n + 1
	r.n = n
	local slot = (n - 1) % CAP + 1
	r.ts[slot] = now
	local cf, base = r.cf, (slot - 1) * np
	for i = 1, np do cf[base + i] = parts[i].CFrame end
end

-- works for the live ring buffer and for linear history snapshots (cap == n)
local function pose(b, T, gp)
	local n, cap, np, ts, cf = b.n, b.cap, b.np, b.ts, b.cf
	if n == 0 then return end
	local lo, hi = math.max(1, n - cap + 1), n
	if T <= ts[(lo - 1) % cap + 1] then
		hi = lo
	elseif T >= ts[(hi - 1) % cap + 1] then
		lo = hi
	else
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if ts[(mid - 1) % cap + 1] <= T then lo = mid else hi = mid end
		end
	end
	local a = ((lo - 1) % cap) * np
	if lo == hi then
		for i = 1, np do gp[i].CFrame = cf[a + i] end
	else
		local sa, sb = (lo - 1) % cap + 1, (hi - 1) % cap + 1
		local alpha = (T - ts[sa]) / (ts[sb] - ts[sa])
		local b0 = ((hi - 1) % cap) * np
		for i = 1, np do gp[i].CFrame = cf[a + i]:Lerp(cf[b0 + i], alpha) end
	end
end

local function play(r, now)
	local h = r.hist
	if h then
		local span = h.ts[h.n] - h.ts[1]
		pose(h, h.ts[1] + (span > 0 and (now - h.t0) % span or 0), r.gp)
	else
		pose(r, now - CFG.RECORD_SECONDS, r.gp)
	end
end

local function refresh(r)
	local g = r.ghost
	if not g then return end
	local show = r.hist or (ghostsOn and r.eye)
	if show then play(r, os.clock()) end
	g.Parent = show and ghostFolder or nil
end

local function snapshot(r)
	local n = math.min(r.n, CAP)
	if n < 2 then return nil end
	local np = r.np
	local h = { n = n, cap = n, np = np, ts = {}, cf = {}, t0 = os.clock() }
	local first = r.n - n + 1
	for k = 1, n do
		local slot = (first + k - 2) % CAP + 1
		h.ts[k] = r.ts[slot]
		local sb, db = (slot - 1) * np, (k - 1) * np
		for i = 1, np do h.cf[db + i] = r.cf[sb + i] end
	end
	return h
end

local function setup(r, char)
	r.char = char
	if dead or not char then return end
	local hum = char:WaitForChild("Humanoid", 15)
	local root = char:WaitForChild("HumanoidRootPart", 15)
	if not hum or not root then return end
	local t = 0
	while not r.plr:HasAppearanceLoaded() and t < 8 do t += task.wait(0.25) end
	if dead or r.char ~= char or not root.Parent then return end

	local g = buildGhost(char)
	if not g then return end
	local parts, gp, hi = {}, {}, 1
	for _, c in char:GetChildren() do
		if c:IsA("BasePart") then
			local gpart = g:FindFirstChild(c.Name)
			if gpart and gpart:IsA("BasePart") then
				parts[#parts + 1], gp[#gp + 1] = c, gpart
				if c.Name == "Head" then hi = #parts end
			end
		end
	end
	if r.ghost then r.ghost:Destroy() end
	r.ghost, r.parts, r.gp, r.root, r.hi = g, parts, gp, root, hi
	r.np, r.n, r.ts, r.cf, r.hist = #parts, 0, {}, {}, nil
	record(r, os.clock())
	refresh(r)
	hooks.char(r)
end

local function makeCube(pos, n)
	local p = new("Part", {
		Name = "LeftCube" .. n, Size = Vector3.one * 1.5, Position = pos, Anchored = true,
		CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false,
		Color = Color3.fromRGB(255, 40, 40), Material = Enum.Material.SmoothPlastic,
	}, cubeFolder)
	local bb = new("BillboardGui", { Size = UDim2.fromOffset(34, 34), AlwaysOnTop = true, MaxDistance = 250, Adornee = p }, p)
	label({
		Size = UDim2.fromScale(1, 1), Text = tostring(n), Font = Enum.Font.GothamBold, TextSize = 24,
		TextColor3 = WHITE, TextStrokeTransparency = 0,
	}, bb)
end

local function track(plr, early)
	if dead or recs[plr] then return end
	local r = { plr = plr, eye = true, early = early, joined = os.clock(), cap = CAP, n = 0, np = 0, ts = {}, cf = {} }
	recs[plr] = r
	hooks.join(r)
	plr.CharacterAdded:Connect(function(c) task.spawn(setup, r, c) end)
	if plr.Character then task.spawn(setup, r, plr.Character) end
end

local function untrack(plr)
	local r = recs[plr]
	if not r then return end
	recs[plr] = nil
	r.char = nil
	leaveCount += 1
	local cubed = false
	if r.parts and r.n > 0 then
		makeCube(r.cf[((r.n - 1) % CAP) * r.np + r.hi].Position, leaveCount)
		cubed = true
	end
	if r.ghost then r.ghost:Destroy() end   -- ghost + recorded data are dropped with the record
	hooks.leave(r, leaveCount, cubed)
end

------------------------------------------------------------------ UI
local gui = new("ScreenGui", {
	Name = "GhostMenu", ResetOnSpawn = false, DisplayOrder = 50, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, lp:WaitForChild("PlayerGui"))
local gameIcon = ("rbxthumb://type=GameIcon&id=%d&w=150&h=150"):format(game.GameId)

-- tap handling: a tap only counts if the finger barely moved, was quick, and the list did not scroll.
-- This stops "click while scrolling" on phones. One shared InputEnded resolves it.
local pend, drag, lastScroll = nil, nil, 0
local function live(i) local s = i.UserInputState return s ~= Enum.UserInputState.End and s ~= Enum.UserInputState.Cancel end
local function pointer(i) local t = i.UserInputType return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch end
local function onTap(obj, fn, scroll)
	obj.InputBegan:Connect(function(i)
		if not pointer(i) or (pend and live(pend.i)) then return end
		local now = os.clock()
		pend = {
			i = i, p = i.Position, t = now, fn = fn, sc = scroll,
			y = scroll and scroll.CanvasPosition.Y or 0,
			bad = scroll ~= nil and now - lastScroll < 0.12,   -- touch that merely stopped a fling
		}
	end)
end

-- menu (open state: fixed in place, never draggable)
local menu = new("Frame", {
	Name = "Menu", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.9, 0.9), BackgroundColor3 = CFG.MENU_COLOR,
	BackgroundTransparency = CFG.MENU_TRANSPARENCY, BorderSizePixel = 0, Active = true, Visible = false,
}, gui)
round(menu, 16)
stroke(menu, 2)
new("UISizeConstraint", { MinSize = Vector2.new(320, 220), MaxSize = Vector2.new(520, 340) }, menu)

-- title bar
local titleIcon = new("ImageLabel", {
	Position = UDim2.fromOffset(8, 5), Size = UDim2.fromOffset(34, 34), BackgroundColor3 = C.cyan,
	BackgroundTransparency = CFG.WIDGET_TRANSPARENCY, BorderSizePixel = 0, Image = gameIcon,
}, menu)
round(titleIcon, 8)
stroke(titleIcon, 1.5)
local nameLbl = box({
	Position = UDim2.fromOffset(50, 6), Size = UDim2.new(1, -136, 0, 32), Text = CFG.GAME_NAME or game.Name,
	Font = Enum.Font.GothamBold, TextSize = 16, TextTruncate = Enum.TextTruncate.AtEnd,
}, menu, C.pink)
if not CFG.GAME_NAME then
	task.spawn(function()
		local ok, info = pcall(Market.GetProductInfo, Market, game.PlaceId)
		if ok and info and info.Name and not dead then nameLbl.Text = info.Name end
	end)
end
local minBtn = box({
	Position = UDim2.new(1, -80, 0, 6), Size = UDim2.fromOffset(32, 32), Text = "–",
	Font = Enum.Font.GothamBold, TextSize = 18,
}, menu, C.cyan, "TextButton")
local closeBtn = box({
	Position = UDim2.new(1, -42, 0, 6), Size = UDim2.fromOffset(32, 32), Text = "X",
	Font = Enum.Font.GothamBold, TextSize = 16,
}, menu, C.cyan, "TextButton")

-- solid black dividers (not transparent)
new("Frame", { Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = INK, BorderSizePixel = 0 }, menu)
new("Frame", { Position = UDim2.new(0.36, 0, 0, 46), Size = UDim2.new(0, 2, 1, -46), BackgroundColor3 = INK, BorderSizePixel = 0 }, menu)

-- left: player list
local left = new("Frame", { Position = UDim2.fromOffset(0, 46), Size = UDim2.new(0.36, 0, 1, -46), BackgroundTransparency = 1 }, menu)
box({ Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 0, 26), Text = "Player List", Font = Enum.Font.GothamBold }, left, WHITE)
local list = new("ScrollingFrame", {
	Position = UDim2.fromOffset(8, 40), Size = UDim2.new(1, -16, 1, -48), BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 6, ScrollBarImageColor3 = Color3.fromRGB(90, 90, 90), ScrollingDirection = Enum.ScrollingDirection.Y,
	AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ElasticBehavior = Enum.ElasticBehavior.Never,
}, left)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, list)
new("UIPadding", { PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3) }, list)

-- right: status / toggle / selected-or-log
local right = new("Frame", { Position = UDim2.new(0.36, 2, 0, 46), Size = UDim2.new(0.64, -2, 1, -46), BackgroundTransparency = 1 }, menu)
local function title(y, text)
	return label({ Position = UDim2.fromOffset(10, y), Size = UDim2.new(1, -20, 0, 18), Text = text, TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold }, right)
end
title(4, "Status:")
local infoRow = new("Frame", { Position = UDim2.fromOffset(10, 24), Size = UDim2.new(1, -20, 0, 28), BackgroundTransparency = 1 }, right)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), VerticalAlignment = Enum.VerticalAlignment.Center }, infoRow)
fit(box({ Size = UDim2.fromScale(0.2, 1), Text = "Online" }, infoRow, C.green))
local countBox = fit(box({ Size = UDim2.fromScale(0.36, 1) }, infoRow))
local timeBox = fit(box({ Size = UDim2.fromScale(0.4, 1) }, infoRow))

title(56, "Toggle:")
local tgl = box({ Position = UDim2.fromOffset(10, 76), Size = UDim2.fromOffset(124, 30) }, right, WHITE)
round(tgl, 10)
local onBtn = label({ Position = UDim2.fromOffset(3, 3), Size = UDim2.new(0.5, -4, 1, -6), Text = "On", Font = Enum.Font.GothamBold }, tgl, "TextButton")
local offBtn = label({ Position = UDim2.new(0.5, 1, 0, 3), Size = UDim2.new(0.5, -4, 1, -6), Text = "Off", Font = Enum.Font.GothamBold }, tgl, "TextButton")
round(onBtn, 8)
round(offBtn, 8)
onBtn.BackgroundColor3, offBtn.BackgroundColor3 = C.green, C.red

local panelTitle = title(114, "Log:")

-- selected-player panel
local selPanel = box({ Position = UDim2.fromOffset(10, 134), Size = UDim2.new(1, -20, 1, -142), Visible = false }, right, C.grey)
round(selPanel, 10)
local selAvatar = new("ImageLabel", {
	Position = UDim2.fromOffset(8, 8), Size = UDim2.fromOffset(80, 80), BackgroundColor3 = Color3.fromRGB(140, 130, 130), BorderSizePixel = 0,
}, selPanel)
round(selAvatar, 12)
local selInfo = fit(label({
	Position = UDim2.fromOffset(96, 6), Size = UDim2.new(1, -104, 1, -44), RichText = true, TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, selPanel))
local histRow = new("Frame", { Position = UDim2.new(0, 96, 1, -34), Size = UDim2.new(1, -104, 0, 26), BackgroundTransparency = 1 }, selPanel)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, histRow)
local showBtn = fit(box({ Size = UDim2.new(0.5, -3, 1, 0), Text = "Show History", Font = Enum.Font.GothamBold }, histRow, C.green, "TextButton"))
local hideBtn = fit(box({ Size = UDim2.new(0.5, -3, 1, 0), Text = "Unshow History", Font = Enum.Font.GothamBold }, histRow, C.red, "TextButton"))

-- join/leave log panel (shown when nobody is selected)
local logPanel = new("ScrollingFrame", {
	Position = UDim2.fromOffset(10, 134), Size = UDim2.new(1, -20, 1, -142), BackgroundColor3 = C.grey,
	BackgroundTransparency = CFG.WIDGET_TRANSPARENCY, BorderSizePixel = 0, ScrollBarThickness = 5,
	ScrollBarImageColor3 = Color3.fromRGB(90, 90, 90), ScrollingDirection = Enum.ScrollingDirection.Y,
	AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ElasticBehavior = Enum.ElasticBehavior.Never,
}, right)
round(logPanel, 10)
stroke(logPanel, 1.5)
new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, logPanel)
new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5) }, logPanel)
conn(list:GetPropertyChangedSignal("CanvasPosition"):Connect(function() lastScroll = os.clock() end))
conn(logPanel:GetPropertyChangedSignal("CanvasPosition"):Connect(function() lastScroll = os.clock() end))

local logQ, logN = {}, 0
local function addLog(text)
	local atEnd = logPanel.CanvasPosition.Y + logPanel.AbsoluteWindowSize.Y >= logPanel.AbsoluteCanvasSize.Y - 8
	logN += 1
	logQ[#logQ + 1] = label({
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, RichText = true, TextWrapped = true,
		TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = logN,
		Text = ('<font color="#555555">[%s]</font> %s'):format(fmt(workspace.DistributedGameTime), text),
	}, logPanel)
	if #logQ > 80 then table.remove(logQ, 1):Destroy() end
	if atEnd then task.defer(function() logPanel.CanvasPosition = Vector2.new(0, 1e6) end) end
end

-- selection / info
local function infoText(r)
	local plr = r.plr
	local stats = {}
	local ls = plr:FindFirstChild("leaderstats")
	if ls then
		for _, v in ls:GetChildren() do
			if v:IsA("ValueBase") then
				stats[#stats + 1] = esc(v.Name) .. " " .. esc(v.Value)
				if #stats >= 4 then break end
			end
		end
	end
	return ("<b>%s</b>\n@%s\nAge: %s days\nIn server: %s%s\nTeam: %s\nStats: %s"):format(
		esc(plr.DisplayName), esc(plr.Name), plr.AccountAge, fmt(os.clock() - r.joined), r.early and "+" or "",
		esc(plr.Team and plr.Team.Name or "None"), #stats > 0 and table.concat(stats, " · ") or "none")
end

local function refreshSel()
	local r = sel and recs[sel]
	if not r then sel = nil end
	selPanel.Visible, logPanel.Visible = r ~= nil, r == nil
	panelTitle.Text = r and "Player Selected:" or "Log:"
	for _, x in recs do
		if x.ui then x.ui.st.Thickness = (x == r) and 3 or 1.5 end
	end
	if r then
		selAvatar.Image = thumb(r.plr.UserId, 150)
		selInfo.Text = infoText(r)
		showBtn.BackgroundTransparency = r.hist and 0.75 or CFG.WIDGET_TRANSPARENCY
		hideBtn.BackgroundTransparency = r.hist and CFG.WIDGET_TRANSPARENCY or 0.75
	end
end

local function updateCount()
	countBox.Text = ("Players: %d/%d"):format(#Players:GetPlayers(), Players.MaxPlayers)
end
local function refreshStats()
	timeBox.Text = "Server Time: " .. fmt(workspace.DistributedGameTime)
	updateCount()
	local r = sel and recs[sel]
	if r then selInfo.Text = infoText(r) end
end

local function eyeVis(r)
	local u = r.ui
	u.body.Size = r.eye and UDim2.fromOffset(22, 13) or UDim2.fromOffset(22, 3)
	u.body.BackgroundColor3 = r.eye and WHITE or INK
	u.pupil.Visible = r.eye
end

local function addRow(r)
	local plr = r.plr
	order += 1
	local row = new("Frame", {
		Name = tostring(plr.UserId), Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = C.cyan,
		BackgroundTransparency = CFG.WIDGET_TRANSPARENCY, BorderSizePixel = 0, LayoutOrder = plr == lp and 0 or order,
	}, list)
	round(row, 10)
	local st = stroke(row, 1.5)
	-- two sibling buttons (never nested) so a tap on the eye can't also select the row
	local main = label({ Size = UDim2.new(1, -36, 1, 0) }, row, "TextButton")
	local av = new("ImageLabel", {
		Position = UDim2.fromOffset(5, 5), Size = UDim2.fromOffset(36, 36), BackgroundColor3 = C.grey,
		BorderSizePixel = 0, Image = thumb(plr.UserId, 48),
	}, main)
	pill(av)
	label({
		Position = UDim2.fromOffset(46, 6), Size = UDim2.new(1, -50, 0, 18), Text = plr.DisplayName, Font = Enum.Font.GothamBold,
		TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, main)
	label({
		Position = UDim2.fromOffset(46, 24), Size = UDim2.new(1, -50, 0, 16), Text = "@" .. plr.Name, TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, main)
	local eyeBtn = label({ Position = UDim2.new(1, -34, 0, 0), Size = UDim2.new(0, 34, 1, 0) }, row, "TextButton")
	local body = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = WHITE, BorderSizePixel = 0 }, eyeBtn)
	pill(body)
	stroke(body, 1.5)
	local pupil = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = Color3.fromRGB(255, 150, 0), BorderSizePixel = 0,
	}, body)
	pill(pupil)
	r.ui = { row = row, st = st, body = body, pupil = pupil }
	eyeVis(r)

	onTap(main, function()
		sel = (sel ~= plr) and plr or nil   -- tap again = deselect
		refreshSel()
	end, list)
	onTap(eyeBtn, function()
		r.eye = not r.eye
		eyeVis(r)
		refresh(r)
	end, list)
end

hooks.join = function(r)
	addRow(r)
	updateCount()
	addLog(('<b>%s</b> <font color="#555555">@%s</font> <font color="#2e9e2e">joined</font>'):format(esc(r.plr.DisplayName), esc(r.plr.Name)))
end
hooks.leave = function(r, n, cubed)
	if r.ui then r.ui.row:Destroy() end
	if sel == r.plr then sel = nil end
	refreshSel()
	updateCount()
	addLog(('<b>%s</b> <font color="#555555">@%s</font> <font color="#d02020">left the server</font> %s'):format(
		esc(r.plr.DisplayName), esc(r.plr.Name), cubed and ('(red cube "%d")'):format(n) or "(no position recorded)"))
end
hooks.char = function(r)
	if sel == r.plr then refreshSel() end
end

-- toggle + history buttons
local function setGhosts(on)
	ghostsOn = on
	cubeFolder.Parent = on and workspace or nil
	for _, r in recs do refresh(r) end
	onBtn.BackgroundTransparency = on and 0 or 1
	offBtn.BackgroundTransparency = on and 1 or 0
end
setGhosts(true)
onTap(onBtn, function() setGhosts(true) end)
onTap(offBtn, function() setGhosts(false) end)
onTap(showBtn, function()
	local r = sel and recs[sel]
	if r and r.ghost then
		r.hist = snapshot(r)   -- loops the recorded last seconds of that player, even if ghosts are toggled off
		refresh(r)
		refreshSel()
	end
end)
onTap(hideBtn, function()
	local r = sel and recs[sel]
	if r then
		r.hist = nil
		refresh(r)
		refreshSel()
	end
end)

-- closed state: small outlined box, same color / transparency as the menu, draggable
local icon = new("TextButton", {
	Name = "Icon", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12), Size = UDim2.fromOffset(46, 46),
	BackgroundColor3 = CFG.MENU_COLOR, BackgroundTransparency = CFG.MENU_TRANSPARENCY, Text = "", AutoButtonColor = false,
	Selectable = false, BorderSizePixel = 0,
}, gui)
round(icon, 12)
stroke(icon, 2)
if CFG.ICON_IN_CLOSED then
	round(new("ImageLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -12, 1, -12),
		BackgroundTransparency = 1, BorderSizePixel = 0, Image = gameIcon,
	}, icon), 8)
end

local function setOpen(open)
	pend, drag = nil, nil
	menu.Visible = open
	icon.Visible = not open
	if open then refreshStats() end
end

local function clampIcon()
	local ap, as, go, gs = icon.AbsolutePosition, icon.AbsoluteSize, gui.AbsolutePosition, gui.AbsoluteSize
	local x = math.clamp(ap.X, go.X, math.max(go.X, go.X + gs.X - as.X))
	local y = math.clamp(ap.Y, go.Y, math.max(go.Y, go.Y + gs.Y - as.Y))
	if x ~= ap.X or y ~= ap.Y then
		local p = icon.Position
		icon.Position = UDim2.new(p.X.Scale, p.X.Offset + x - ap.X, p.Y.Scale, p.Y.Offset + y - ap.Y)
	end
end
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(clampIcon)   -- keeps it on-screen after rotating the phone

-- drag only follows the ONE input that started on the icon; tiny movements are treated as a tap
icon.InputBegan:Connect(function(i)
	if not pointer(i) or (drag and live(drag.i)) then return end
	drag = { i = i, p = i.Position, o = icon.Position, ap = icon.AbsolutePosition, moved = false }
end)
conn(UIS.InputChanged:Connect(function(i)
	local d = drag
	if not d then return end
	local same = i == d.i or (i.UserInputType == Enum.UserInputType.MouseMovement and d.i.UserInputType == Enum.UserInputType.MouseButton1)
	if not same then return end
	if not live(d.i) then drag = nil return end
	local delta = i.Position - d.p
	if not d.moved then
		if delta.Magnitude < CFG.DRAG_SLOP then return end
		d.moved = true
	end
	local go, gs, as = gui.AbsolutePosition, gui.AbsoluteSize, icon.AbsoluteSize
	local x = math.clamp(d.ap.X + delta.X, go.X, math.max(go.X, go.X + gs.X - as.X))
	local y = math.clamp(d.ap.Y + delta.Y, go.Y, math.max(go.Y, go.Y + gs.Y - as.Y))
	icon.Position = UDim2.new(d.o.X.Scale, d.o.X.Offset + (x - d.ap.X), d.o.Y.Scale, d.o.Y.Offset + (y - d.ap.Y))
end))

-- one shared release handler: finishes icon drag/tap and normal taps
conn(UIS.InputEnded:Connect(function(i)
	local d = drag
	if d and d.i == i then
		drag = nil
		if not d.moved and i.UserInputState ~= Enum.UserInputState.Cancel then setOpen(true) end
	end
	local p = pend
	if p and p.i == i then
		pend = nil
		if i.UserInputState == Enum.UserInputState.Cancel or p.bad then return end
		if (i.Position - p.p).Magnitude > CFG.TAP_SLOP or os.clock() - p.t > 0.6 then return end
		if p.sc and math.abs(p.sc.CanvasPosition.Y - p.y) > 3 then return end
		p.fn()
	end
end))

onTap(minBtn, function() setOpen(false) end)

local function shutdown()
	dead = true
	for _, c in conns do c:Disconnect() end
	table.clear(conns)
	for _, r in recs do
		if r.ghost then r.ghost:Destroy() end
	end
	table.clear(recs)
	ghostFolder:Destroy()
	cubeFolder:Destroy()
	gui:Destroy()
end

local armed = false
onTap(closeBtn, function()
	if armed then shutdown() return end
	armed = true
	closeBtn.Text, closeBtn.BackgroundColor3 = "?", C.red   -- tap again within 2s to fully shut everything down
	task.delay(2, function()
		if dead then return end
		armed = false
		closeBtn.Text, closeBtn.BackgroundColor3 = "X", C.cyan
	end)
end)

------------------------------------------------------------------ RUN
local acc = 0
conn(RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	acc += dt
	if acc >= STEP then
		acc %= STEP
		for _, r in recs do record(r, now) end
	end
	for _, r in recs do
		local g = r.ghost
		if g and g.Parent then play(r, now) end
	end
end))

conn(Players.PlayerAdded:Connect(function(plr) track(plr, false) end))
conn(Players.PlayerRemoving:Connect(untrack))
for _, plr in Players:GetPlayers() do track(plr, plr ~= lp) end
refreshSel()

task.spawn(function()
	while not dead do
		task.wait(1)
		if menu.Visible then refreshStats() end
	end
end)
