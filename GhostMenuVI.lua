--[[
	GhostMenu (LocalScript)
	PUT IT IN: StarterPlayer > StarterPlayerScripts   (nothing else needed, the UI is built by code)

	- Every player gets a white, semi-transparent "ghost" clone of their avatar that replays
	  the last RECORD_SECONDS of their movement (it trails the real player by that long).
	- Modes (menu > Mode):
	    Ghost  = the delayed replay ghost described above
	    Sande  = white ghost afterimages left behind moving players; each one disappears after 10 seconds
	    Trail  = a solid line (not glowing) in the player's own random color: 1-10 s full color, 11-30 s slightly faded,
	             31-60 s dulled, then it is gone
	    Forever = the same line, never removed (after 60 s it just stays plain gray)
	  Trail and Forever each keep their OWN trails per player, so switching modes only hides / shows them, it never deletes them.
	  Where several different players walk the same way (Trail / Forever), a red zigzag "lightning" line is drawn along the
	  average of their paths (see HOT ROUTES below).
	- Everything runs on the client only, so it costs the server nothing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Market = game:GetService("MarketplaceService")
local lp = Players.LocalPlayer

if _G.GhostMenuShutdown then pcall(_G.GhostMenuShutdown) end   -- only one copy runs at a time (a re-run replaces the old one)

------------------------------------------------------------------ CONFIG
local CFG = {
	RECORD_SECONDS = 10,        -- how much movement is kept / how far behind the ghost trails
	SAMPLE_HZ = 12,             -- recording rate (lower = lighter; ghosts are interpolated, so 12 still looks smooth)
	GHOST_FPS = 30,             -- how often ghost poses are updated per second (lower = lighter)
	GHOST_MAX_DIST = 250,       -- ghosts further than this from your camera are not animated
	GHOST_TRANSPARENCY = 0.55,
	MENU_TRANSPARENCY = 0.8,    -- menu + closed icon
	WIDGET_TRANSPARENCY = 0.4,  -- boxes inside the menu (kept more solid so text stays readable)
	MENU_COLOR = Color3.fromRGB(255, 208, 140),
	GAME_NAME = nil,            -- nil = auto from the place name
	ICON_IN_CLOSED = true,      -- show the game icon inside the closed (draggable) box
	TAP_SLOP = 10,              -- px a finger may move and still count as a tap
	DRAG_SLOP = 8,              -- px a finger must move before the closed icon starts dragging
	-- Sandevistan mode (trail of white ghost afterimages)
	SANDE_LIFE = 10,            -- seconds an afterimage stays fully visible, then it disappears
	SANDE_INTERVAL = 0.35,      -- seconds between afterimages while moving (bigger = fewer = lighter)
	SANDE_MIN_MOVE = 1.5,       -- studs a player must move since the last afterimage (standing still = no trail)
	SANDE_MAX_DIST = 120,       -- only leave afterimages for players this close to your camera
	SANDE_MAX_TOTAL = 250,      -- hard cap on afterimages alive at the same time (all players together)
	-- Trail / Forever modes (one random color per player, it ages as the trail gets older)
	TRAIL_ENDS = { 10, 30, 60 },            -- seconds: end of "full color", of "slight fade", of "dulled" (= life of a normal Trail)
	TRAIL_ALPHA = { 0.1, 0.35, 0.6, 0.7 },  -- transparency in stage 1 / 2 / 3 / gray (61+ s, Forever mode only)
	TRAIL_MIX = { 0, 0.3, 0.65 },           -- how far the player's color is turned gray in stage 1 / 2 / 3
	TRAIL_GRAY = Color3.fromRGB(140, 140, 140),
	TRAIL_SPACING = 5,          -- studs between trail pieces (bigger = fewer parts = lighter)
	TRAIL_MIN_INTERVAL = 0.3,   -- never add trail pieces faster than this (seconds)
	TRAIL_WIDTH = 0.4,
	TRAIL_OFFSET = Vector3.new(0, -1.5, 0),   -- where on the body the line is drawn (relative to the root part)
	TRAIL_MAX_FOREVER = 600,    -- Forever mode: pieces kept per player, after that the oldest are recycled
	TRAIL_MAX_DIST = 250,       -- only draw trails for players this close to your camera
	TRAIL_MATERIAL = Enum.Material.SmoothPlastic,   -- solid, no glow (Neon was the glow)
	TRAIL_SAT = 0.6, TRAIL_VAL = 0.85,   -- how strong the random player colors are (lower = calmer)
	-- hot routes: red lightning where several different players walk the same way (Trail / Forever)
	HEAT_CELL = 14,             -- studs: size of one grid cell the paths are averaged in
	HEAT_PLAYERS = 3,           -- different players needed on a spot before it turns red (use 2 for small servers)
	HEAT_MAX_CELLS = 4000,      -- memory caps: once full, new cells / links are simply ignored (nothing is deleted)
	HEAT_MAX_EDGES = 8000,
	BOLT_COLOR = Color3.fromRGB(205, 35, 35),
	BOLT_WIDTH = 0.7,
	BOLT_PIECES = 5,            -- straight pieces per lightning link (more = more jagged)
	BOLT_JITTER = 1.8,          -- studs the zigzag swings left / right
	BOLT_MAX = 300,             -- max lightning links drawn at once
	BOLT_FLICKER_BATCH = 12,    -- bolts re-rolled 4x per second so they crackle (0 = static)
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
local POOL = math.ceil(CFG.SANDE_LIFE / CFG.SANDE_INTERVAL) + 2   -- afterimages kept per player (reused)
local TCAP = math.ceil(CFG.TRAIL_ENDS[3] / CFG.TRAIL_MIN_INTERVAL) + 2   -- trail pieces a normal Trail can need per player
local recs, conns, hooks = {}, {}, {}   -- recs[Player] = record
local ghostsOn, dead, sel, joinCount, leaveCount, order = true, false, nil, 0, 0, 0
local mode = "normal"   -- "normal" (delayed replay ghost), "sande" (afterimages), "trail" or "forever"

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
local trailRoot = new("Folder", { Name = "_GhostTrails" }, workspace)

-- things removed from the avatar clone (it only needs meshes + accessory welds)
local JUNK = {
	Motor6D = true, Humanoid = true, Animator = true, BodyColors = true, Shirt = true, Pants = true,
	ShirtGraphic = true, SurfaceAppearance = true, Sound = true, ParticleEmitter = true, Trail = true,
	Beam = true, Fire = true, Smoke = true, Sparkles = true, ForceField = true, BillboardGui = true,
	PointLight = true, SpotLight = true, SurfaceLight = true, Highlight = true,
	WeldConstraint = true, Tool = true,   -- no joints at all: every part is placed directly, so nothing can snap back to an old spot
}

-- pairs every BasePart of `o` with its twin in `c` (a clone of o, maybe with some things deleted).
-- Children are matched by name + class in order, so accessories that share a name still pair up correctly.
local function pairUp(o, c, out)
	local oc, oi = o:GetChildren(), 1
	for _, cc in c:GetChildren() do
		for j = oi, #oc do
			local oo = oc[j]
			if oo.Name == cc.Name and oo.ClassName == cc.ClassName then
				oi = j + 1
				if cc:IsA("BasePart") then out[#out + 1] = { oo, cc } end
				pairUp(oo, cc, out)
				break
			end
		end
	end
end

-- for every part in `list` (parts of `src`), returns the matching part inside `dst` (a clone of src), same order
local function mapParts(src, dst, list)
	local pr, lookup, out = {}, {}, {}
	pairUp(src, dst, pr)
	for _, p in pr do lookup[p[1]] = p[2] end
	for i, part in list do out[i] = lookup[part] end
	return out
end

local function buildGhost(char)
	local was = char.Archivable
	char.Archivable = true
	local g = char:Clone()
	char.Archivable = was
	if not g then return nil end
	g.Name = "Ghost"
	for _, d in g:GetDescendants() do
		if JUNK[d.ClassName] or d:IsA("LuaSourceContainer") or d:IsA("JointInstance") or d:IsA("Constraint") then
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
	local pr = {}
	pairUp(char, g, pr)   -- body parts AND accessory handles (hair, hats, ...)
	return g, pr
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

-- Sandevistan mode: while a player moves, they leave white ghost copies of their current pose behind them.
-- Each copy stays for SANDE_LIFE seconds and then disappears. Copies come from a small per-player pool (reused),
-- and one shared counter keeps all copies together under SANDE_MAX_TOTAL.
local afterCount = 0

local function clearAfter(r)
	for _, a in r.pool do
		if a.on then
			a.on = false
			afterCount -= 1
			a.m.Parent = nil
		end
	end
end

local function destroyPool(r)
	for _, a in r.pool do
		if a.on then afterCount -= 1 end
		a.m:Destroy()
	end
	r.pool, r.pi = {}, 0
end

local function afterimage(r, now)
	if afterCount >= CFG.SANDE_MAX_TOTAL then return end
	local pos = r.root.Position
	if not r.lastPos then
		r.lastPos, r.lastAfter = pos, now
		return
	end
	if (pos - r.lastPos).Magnitude < CFG.SANDE_MIN_MOVE or now - r.lastAfter < CFG.SANDE_INTERVAL then return end
	r.lastPos, r.lastAfter = pos, now
	local idx = r.pi % POOL + 1
	r.pi = idx
	local a = r.pool[idx]
	if not a then
		local m = r.ghost:Clone()   -- already a white ghost, so the afterimage looks exactly like one
		if not m then return end
		a = { m = m, pp = mapParts(r.ghost, m, r.gp), on = false, born = 0 }
		r.pool[idx] = a
	end
	local parts, pp = r.parts, a.pp
	for i = 1, r.np do
		local p = pp[i]
		if p then p.CFrame = parts[i].CFrame end
	end
	if not a.on then afterCount += 1 end
	a.on, a.born = true, now
	a.m.Parent = ghostFolder
end

-- an afterimage stays exactly as it is for SANDE_LIFE seconds, then disappears
local function expire(r, now)
	local life = CFG.SANDE_LIFE
	for _, a in r.pool do
		if a.on and now - a.born >= life then
			a.on = false
			afterCount -= 1
			a.m.Parent = nil
		end
	end
end

-- Trail / Forever modes: every player gets ONE random color; moving leaves a thin solid (not glowing) line in that color.
-- The line ages: 0-10 s full color, 11-30 s slightly faded, 31-60 s dulled. "Trail" removes it after 60 s,
-- "Forever" keeps it (plain gray) until the per-player piece cap recycles the oldest pieces.
-- Trail and Forever are two SEPARATE stores per player (r.trails.trail / r.trails.forever): switching modes only hides one
-- and shows the other, so a mode change never deletes anything.
-- Light on purpose: pieces are pooled + reused, each piece is touched only 3 times in its whole life
-- (three moving pointers, no per-frame loops), and nothing is drawn for players far from your camera.
local hueBase, hueN = math.random(), 0
local function playerColors()
	hueN += 1
	local full = Color3.fromHSV((hueBase + hueN * 0.618034) % 1, CFG.TRAIL_SAT, CFG.TRAIL_VAL)   -- golden-ratio steps: random but never two alike
	local mix, gray = CFG.TRAIL_MIX, CFG.TRAIL_GRAY
	return { full:Lerp(gray, mix[1]), full:Lerp(gray, mix[2]), full:Lerp(gray, mix[3]), gray }
end

local function clearTrail(r)
	for kind, tr in r.trails do
		tr.folder:Destroy()
		r.trails[kind] = nil
	end
end

local function newTrail(r, kind)
	local forever = kind == "forever"
	local tr = {
		folder = new("Folder", { Name = r.plr.Name }, trailRoot),
		segs = {}, n = 0, p = { 1, 1, 1 }, forever = forever,
		cap = forever and CFG.TRAIL_MAX_FOREVER or TCAP,
	}
	r.trails[kind] = tr
	return tr
end

local function addSeg(tr, col, a, b, now)
	local n = tr.n + 1
	tr.n = n
	local slot = (n - 1) % tr.cap + 1
	local s = tr.segs[slot]
	if not s then
		s = { part = new("Part", { Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false }) }
		tr.segs[slot] = s
	end
	local part = s.part
	part.Size = Vector3.new(CFG.TRAIL_WIDTH, CFG.TRAIL_WIDTH, (b - a).Magnitude)
	part.CFrame = CFrame.lookAt((a + b) * 0.5, b)
	part.Color, part.Material, part.Transparency = col[1], CFG.TRAIL_MATERIAL, CFG.TRAIL_ALPHA[1]
	s.born = now
	part.Parent = tr.folder
end

-- moves pieces into their next stage when they pass 10 s / 30 s / 60 s (pieces are in birth order, so a pointer is enough)
local function trailAge(tr, col, now)
	local top, ends, alpha = tr.n, CFG.TRAIL_ENDS, CFG.TRAIL_ALPHA
	local oldest = top - tr.cap + 1
	for k = 1, 3 do
		local ptr = tr.p[k]
		if ptr < oldest then ptr = oldest end
		local limit = ends[k]
		while ptr <= top do
			local s = tr.segs[(ptr - 1) % tr.cap + 1]
			if now - s.born < limit then break end
			local part = s.part
			if k == 3 and not tr.forever then
				part.Parent = nil   -- normal Trail: gone after 60 s
			else
				part.Color, part.Transparency = col[k + 1], alpha[k + 1]
			end
			ptr += 1
		end
		tr.p[k] = ptr
	end
end

-- HOT ROUTES (Trail / Forever): where several DIFFERENT players walk the same way, a red zigzag "lightning" line is drawn.
-- Every new trail piece also feeds a coarse 3D grid (HEAT_CELL studs per cell). A cell is "hot" when HEAT_PLAYERS different
-- players went through it or right next to it. Two hot cells that players really walked between get joined by a red zigzag
-- between their AVERAGE positions, so the red line follows the middle of where most people go, not one player's own line.
-- Trail mode only counts the last 60 s, Forever counts everything. Bolts are pooled and capped (BOLT_MAX).
local heats = {}
for _, kind in { "trail", "forever" } do
	heats[kind] = {
		window = kind == "trail" and CFG.TRAIL_ENDS[3] or nil,   -- nil = no time limit
		cells = {}, nc = 0, edges = {}, ne = 0, dirty = {}, hot = {},
		blist = {}, free = {}, nb = 0, fi = 0, tick = 0,
		folder = new("Folder", { Name = "_Bolts_" .. kind }),   -- parented only while its mode is active
	}
end
local rng, scratch = Random.new(), {}

local function newBolt(h)
	local b = #h.free > 0 and table.remove(h.free) or nil
	if b then return b end
	b = { parts = {} }
	for i = 1, CFG.BOLT_PIECES do
		b.parts[i] = new("Part", {
			Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false,
			Color = CFG.BOLT_COLOR, Material = Enum.Material.SmoothPlastic, Transparency = 0.05,
		})
	end
	return b
end

-- lays the straight pieces of one bolt between the AVERAGE positions of its two cells, swinging left / right
local function shapeBolt(b)
	local P, Q = b.a.sum / b.a.n, b.b.sum / b.b.n
	local dir = Q - P
	local len = dir.Magnitude
	if len < 0.05 then
		Q = P + Vector3.xAxis * 0.05
		dir, len = Q - P, 0.05
	end
	local unit = dir / len
	local side = unit:Cross(Vector3.yAxis)
	if side.Magnitude < 0.1 then side = unit:Cross(Vector3.xAxis) end
	side = side.Unit
	local up = side:Cross(unit)
	local K, amp, w = CFG.BOLT_PIECES, CFG.BOLT_JITTER, CFG.BOLT_WIDTH
	local prev = P
	for i = 1, K do
		local nxt = Q
		if i < K then   -- alternate sides so it zigzags like lightning
			local sgn = i % 2 == 0 and 1 or -1
			nxt = P + dir * (i / K) + side * (sgn * rng:NextNumber(0.4, 1) * amp) + up * (rng:NextNumber(-1, 1) * amp * 0.5)
		end
		local sl = (nxt - prev).Magnitude
		if sl < 0.05 then nxt, sl = prev + unit * 0.05, 0.05 end
		local part = b.parts[i]
		part.Size = Vector3.new(w, w, sl)
		part.CFrame = CFrame.lookAt((prev + nxt) * 0.5, nxt)
		prev = nxt
	end
end

-- a link (edge) between two cells shows a bolt exactly while BOTH cells are hot
local function setBolt(h, e, want)
	local b = e.bolt
	if want and not b then
		if h.nb >= CFG.BOLT_MAX then return end
		b = newBolt(h)
		b.a, b.b = e.a, e.b
		e.bolt = b
		h.nb += 1
		local bl = h.blist
		bl[#bl + 1] = b
		b.i = #bl
		shapeBolt(b)
		for _, p in b.parts do p.Parent = h.folder end
	elseif b and not want then
		e.bolt = nil
		h.nb -= 1
		local bl = h.blist
		local last = bl[#bl]
		bl[b.i] = last
		last.i = b.i
		bl[#bl] = nil
		for _, p in b.parts do p.Parent = nil end
		b.a, b.b = nil, nil
		h.free[#h.free + 1] = b
	end
end

-- true when at least HEAT_PLAYERS different players are in this cell or one of its 8 neighbours (same height)
local function isHot(h, c, now)
	local need, win, cells = CFG.HEAT_PLAYERS, h.window, h.cells
	table.clear(scratch)
	local n = 0
	for dx = -1, 1 do
		for dz = -1, 1 do
			local o = cells[(c.cx + dx) .. "," .. c.cy .. "," .. (c.cz + dz)]
			if o then
				for uid, t in o.who do
					if not scratch[uid] and (not win or now - t <= win) then
						scratch[uid] = true
						n += 1
						if n >= need then return true end
					end
				end
			end
		end
	end
	return false
end

-- called for every new trail piece a -> b of one player: samples the line into cells and links the cells it passes
local function heatAdd(h, tr, uid, a, b, now)
	local S, win, cells = CFG.HEAT_CELL, h.window, h.cells
	local steps = math.max(1, math.ceil((b - a).Magnitude / (S * 0.5)))
	for i = 1, steps do
		local p = a:Lerp(b, i / steps)
		local cx, cy, cz = math.floor(p.X / S) + 0, math.floor(p.Y / S) + 0, math.floor(p.Z / S) + 0   -- "+ 0" avoids a "-0" key
		local k = cx .. "," .. cy .. "," .. cz
		local c = cells[k]
		if not c and h.nc < CFG.HEAT_MAX_CELLS then
			c = { k = k, cx = cx, cy = cy, cz = cz, who = {}, sum = Vector3.zero, n = 0, last = now, hot = false, edges = {} }
			cells[k] = c
			h.nc += 1
		end
		if not c then
			tr.pc = nil
		else
			local t = c.who[uid]
			c.who[uid] = now
			c.sum += p
			c.n += 1
			c.last = now
			h.dirty[c] = true
			if not t or (win and now - t > win) then   -- a player's first visit here also changes the count of the cells around it
				for dx = -1, 1 do
					for dz = -1, 1 do
						local o = cells[(cx + dx) .. "," .. cy .. "," .. (cz + dz)]
						if o then h.dirty[o] = true end
					end
				end
			end
			local pc = tr.pc
			if pc and pc ~= c and not pc.dead and h.ne < CFG.HEAT_MAX_EDGES then
				local ek = pc.k < k and (pc.k .. "|" .. k) or (k .. "|" .. pc.k)
				if not h.edges[ek] then
					local e = { a = pc, b = c }
					h.edges[ek] = e
					h.ne += 1
					pc.edges[ek] = e
					c.edges[ek] = e
				end
			end
			tr.pc = c
		end
	end
end

-- re-checks the cells that changed since last time and lights / unlights the bolts around them
local function heatEval(h, now)
	for c in h.dirty do
		h.dirty[c] = nil
		if not c.dead then
			local hot = isHot(h, c, now)
			if hot ~= c.hot then
				c.hot = hot
				h.hot[c] = hot or nil
				for _, e in c.edges do setBolt(h, e, e.a.hot and e.b.hot) end
			elseif hot then
				for _, e in c.edges do
					if not e.bolt and e.a.hot and e.b.hot then setBolt(h, e, true) end
				end
			end
		end
	end
end

-- once a second: Trail mode lets busy spots cool down when the players left (Forever never cools down)
local function heatRevalidate(h, now)
	for c in h.hot do
		if h.window and not isHot(h, c, now) then
			c.hot = false
			h.hot[c] = nil
			for _, e in c.edges do setBolt(h, e, false) end
		else
			for _, e in c.edges do   -- retry bolts that were skipped while BOLT_MAX was full
				if not e.bolt and e.a.hot and e.b.hot then setBolt(h, e, true) end
			end
		end
	end
end

-- Trail mode only: forget cells nobody used for 60 s (Forever keeps its data, it is only limited by HEAT_MAX_*)
local function heatPrune(h, now)
	local win = h.window
	if not win then return end
	for k, c in h.cells do
		if not c.hot and now - c.last > win then
			c.dead = true
			for ek, e in c.edges do
				setBolt(h, e, false)
				h.edges[ek] = nil
				h.ne -= 1
				local o = e.a == c and e.b or e.a
				o.edges[ek] = nil
			end
			h.cells[k] = nil
			h.nc -= 1
			h.dirty[c] = nil
		end
	end
end

local function heatTick(h, now)
	h.tick += 1
	heatEval(h, now)
	if h.tick % 4 == 0 then heatRevalidate(h, now) end
	if h.tick % 20 == 0 then heatPrune(h, now) end
	local bl, batch = h.blist, CFG.BOLT_FLICKER_BATCH
	if batch > 0 and #bl > 0 and h.folder.Parent then   -- crackle: re-roll the zigzag of a few visible bolts
		for _ = 1, math.min(#bl, batch) do
			h.fi = h.fi % #bl + 1
			shapeBolt(bl[h.fi])
		end
	end
end

-- bolts only show while their own mode (Trail or Forever) is selected and the toggle is On
local function syncHeat()
	for kind, h in heats do
		h.folder.Parent = (ghostsOn and mode == kind) and trailRoot or nil
	end
end

local function trailStep(r, now, camPos)
	local kind = mode   -- "trail" or "forever": each has its own trails, so switching modes never deletes anything
	local tr = r.trails[kind] or newTrail(r, kind)
	local pos = r.root.Position + CFG.TRAIL_OFFSET
	if (pos - camPos).Magnitude > CFG.TRAIL_MAX_DIST then
		tr.last, tr.pc = nil, nil
		return
	end
	local last = tr.last
	if not last then
		tr.last, tr.lastT = pos, now
		return
	end
	local d = (pos - last).Magnitude
	if d < CFG.TRAIL_SPACING or now - tr.lastT < CFG.TRAIL_MIN_INTERVAL then return end
	tr.last, tr.lastT = pos, now
	if d < 60 then
		addSeg(tr, r.tcol, last, pos, now)
		heatAdd(heats[kind], tr, r.plr.UserId, last, pos, now)
	else
		tr.pc = nil   -- a bigger jump is a teleport/respawn: don't draw a line across the map (or link heat cells across it)
	end
end

local function refresh(r)
	local g = r.ghost
	if not g then return end
	local on = ghostsOn and r.eye
	local show = r.hist or (on and mode == "normal")
	if show then play(r, os.clock()) end
	g.Parent = show and ghostFolder or nil
	if not (on and mode == "sande") then clearAfter(r) end
	for kind, tr in r.trails do
		local vis = on and mode == kind
		tr.folder.Parent = vis and trailRoot or nil
		if not vis then tr.last, tr.pc = nil, nil end   -- so no long line gets drawn from the old spot when it shows again
	end
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

	local g, pr = buildGhost(char)
	if not g then return end
	local parts, gp, hi = {}, {}, 1
	for _, p in pr do
		if p[2].Transparency < 1 then   -- invisible parts (root part...) are not recorded or moved: less work
			parts[#parts + 1], gp[#gp + 1] = p[1], p[2]
			if p[1].Name == "Head" and p[1].Parent == char then hi = #parts end
		end
	end
	if r.ghost then r.ghost:Destroy() end
	destroyPool(r)
	r.ghost, r.parts, r.gp, r.root, r.hi = g, parts, gp, root, hi
	r.np, r.n, r.ts, r.cf, r.hist, r.lastPos = #parts, 0, {}, {}, nil, nil
	for _, tr in r.trails do tr.last, tr.pc = nil, nil end
	record(r, os.clock())
	refresh(r)
	hooks.char(r)
end

-- The number is built from real little bars (a 7-segment digit display) stuck on the cube's FRONT face.
-- They are ordinary parts, so they can only ever be seen ON the cube, from the front, and walls/the cube hide them.
local CUBE = 1.5
local DIGITS = {
	[0] = "abcdef", [1] = "bc", [2] = "abged", [3] = "abgcd", [4] = "fgbc",
	[5] = "afgcd", [6] = "afgedc", [7] = "abc", [8] = "abcdefg", [9] = "abcdfg",
}
local function makeCube(cf, n)
	local p = new("Part", {
		Name = "LeftCube" .. n, Size = Vector3.one * CUBE, CFrame = cf, Anchored = true,
		CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false,
		Color = Color3.fromRGB(255, 40, 40), Material = Enum.Material.SmoothPlastic,
	}, cubeFolder)
	local str = tostring(n)
	local k = #str
	local gap, h, t, depth = CUBE * 0.08, CUBE * 0.64, CUBE * 0.09, 0.04
	local w = math.min(CUBE * 0.4, (CUBE * 0.8 - (k - 1) * gap) / k)   -- width of one digit
	local total = k * w + (k - 1) * gap
	for di = 1, k do
		local cx = -total / 2 + (di - 1) * (w + gap) + w / 2   -- digit centre, left-to-right as seen from the front
		for c in DIGITS[tonumber(str:sub(di, di))]:gmatch(".") do
			local lx, ly, sx, sy
			if c == "a" then lx, ly, sx, sy = 0, h / 2 - t / 2, w, t
			elseif c == "g" then lx, ly, sx, sy = 0, 0, w, t
			elseif c == "d" then lx, ly, sx, sy = 0, -h / 2 + t / 2, w, t
			elseif c == "b" then lx, ly, sx, sy = w / 2 - t / 2, h / 4, t, h / 2
			elseif c == "c" then lx, ly, sx, sy = w / 2 - t / 2, -h / 4, t, h / 2
			elseif c == "e" then lx, ly, sx, sy = -w / 2 + t / 2, -h / 4, t, h / 2
			else lx, ly, sx, sy = -w / 2 + t / 2, h / 4, t, h / 2 end   -- "f"
			new("Part", {
				Size = Vector3.new(sx, sy, depth), Anchored = true, CanCollide = false, CanTouch = false,
				CanQuery = false, CastShadow = false, Color = WHITE, Material = Enum.Material.Neon,
				-- the front face is the cube's -Z side, and the viewer's right is the cube's -X
				CFrame = cf * CFrame.new(-(cx + lx), ly, -(CUBE / 2 + depth / 2)),
			}, p)
		end
	end
end

-- cube sits where the head was, turned to face the way the head was looking (so the number is the "face")
local function cubeCFrame(r)
	local cf = r.cf[((r.n - 1) % CAP) * r.np + r.hi]
	if not cf then return nil end
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then return CFrame.new(cf.Position) end
	return CFrame.lookAt(cf.Position, cf.Position + flat)
end

local function track(plr, early)
	if dead or recs[plr] then return end
	local r = { plr = plr, eye = true, early = early, joined = os.clock(), cap = CAP, n = 0, np = 0, ts = {}, cf = {}, pool = {}, pi = 0, tcol = playerColors(), trails = {} }
	recs[plr] = r
	joinCount += 1
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
	local n = leaveCount
	local cf = r.parts and r.n > 0 and cubeCFrame(r) or nil
	-- ghost, afterimages and recorded data go first, so nothing below can leave a stale ghost behind
	if r.ghost then
		r.ghost:Destroy()
		r.ghost = nil
	end
	destroyPool(r)
	clearTrail(r)
	r.ts, r.cf = {}, {}
	local cubed = cf ~= nil and pcall(makeCube, cf, n)
	hooks.leave(r, n, cubed)
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

local trow = new("Frame", { Position = UDim2.fromOffset(10, 56), Size = UDim2.new(1, -20, 0, 50), BackgroundTransparency = 1 }, right)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, trow)
local function column(size, text)
	local f = new("Frame", { Size = size, BackgroundTransparency = 1 }, trow)
	label({ Size = UDim2.new(1, 0, 0, 18), Text = text, TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold }, f)
	local b = box({ Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 30) }, f, WHITE)
	round(b, 10)
	return b
end
local tgl = column(UDim2.new(0, 104, 1, 0), "Toggle:")
local modeBox = column(UDim2.new(1, -110, 1, 0), "Mode (tap):")
local function seg(parent, x, w, text, color)
	local b = fit(label({ Position = UDim2.new(x, x == 0 and 3 or 1, 0, 3), Size = UDim2.new(w, -4, 1, -6), Text = text, Font = Enum.Font.GothamBold, BackgroundTransparency = 0, BackgroundColor3 = color }, parent, "TextButton"), 12)
	round(b, 8)
	return b
end
local onBtn, offBtn = seg(tgl, 0, 0.5, "On", C.green), seg(tgl, 0.5, 0.5, "Off", C.red)
-- ONE big button that fills the whole Mode box and shows the current mode; every tap goes to the next mode
local modeBtn = fit(label({
	Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6), Text = "Ghost", Font = Enum.Font.GothamBold,
	BackgroundTransparency = 0, BackgroundColor3 = C.cyan,
}, modeBox, "TextButton"), 13)
round(modeBtn, 8)

local panelTitle = title(114, "Log:")
-- running totals for the whole session: everyone who ever joined / left (so Joined - Left = players online now)
local totalsLbl = fit(label({
	Position = UDim2.new(0.42, 0, 0, 114), Size = UDim2.new(0.58, -10, 0, 18), RichText = true,
	TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.GothamBold,
}, right), 12)
local function updateTotals()
	totalsLbl.Text = ('<font color="#1f7a1f">Joined %d</font> <font color="#555555">·</font> <font color="#b01818">Left %d</font>'):format(joinCount, leaveCount)
end
updateTotals()

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
	panelTitle.Text = r and "Selected:" or "Log:"
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
	-- count our own records, not Players:GetPlayers(): PlayerRemoving fires while the leaving player is still in that list
	local n = 0
	for _ in recs do n += 1 end
	countBox.Text = ("Players: %d/%d"):format(n, Players.MaxPlayers)
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
	updateTotals()
	addLog(('<b>%s</b> <font color="#555555">@%s</font> <font color="#2e9e2e">joined</font>'):format(esc(r.plr.DisplayName), esc(r.plr.Name)))
end
hooks.leave = function(r, n, cubed)
	if r.ui then r.ui.row:Destroy() end
	if sel == r.plr then sel = nil end
	refreshSel()
	updateCount()
	updateTotals()
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
	syncHeat()
	onBtn.BackgroundTransparency = on and 0 or 1
	offBtn.BackgroundTransparency = on and 1 or 0
end
setGhosts(true)
onTap(onBtn, function() setGhosts(true) end)
onTap(offBtn, function() setGhosts(false) end)

local MODES = {
	{ "normal", "Ghost", C.cyan },
	{ "sande", "Sande", C.pink },
	{ "trail", "Trail", C.green },
	{ "forever", "Forever", Color3.fromRGB(255, 225, 120) },
}
local modeIdx = 1
local function setMode(m)
	mode = m
	for i, v in MODES do
		if v[1] == m then
			modeIdx = i
			modeBtn.Text, modeBtn.BackgroundColor3 = v[2], v[3]
		end
	end
	for _, r in recs do refresh(r) end
	syncHeat()
end
setMode("normal")
onTap(modeBtn, function() setMode(MODES[modeIdx % #MODES + 1][1]) end)   -- Ghost > Sande > Trail > Forever > Ghost ...
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
	if _G.GhostMenuShutdown == shutdown then _G.GhostMenuShutdown = nil end
	for _, c in conns do c:Disconnect() end
	table.clear(conns)
	for _, r in recs do
		if r.ghost then r.ghost:Destroy() end
		clearTrail(r)
	end
	table.clear(recs)
	ghostFolder:Destroy()
	cubeFolder:Destroy()
	trailRoot:Destroy()
	for _, h in heats do h.folder:Destroy() end
	gui:Destroy()
end
_G.GhostMenuShutdown = shutdown

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
-- ghosts that are far away or off-screen are simply not animated (their pose catches up the moment they come back)
local function ghostVisible(r, cam, camPos)
	local head = r.gp[r.hi]
	if not cam or not head then return true end
	local p = head.Position
	local d = (p - camPos).Magnitude
	if d > CFG.GHOST_MAX_DIST then return false end
	if d < 40 then return true end
	local _, onScreen = cam:WorldToViewportPoint(p)
	return onScreen
end

local acc, gacc, hacc, GSTEP = 0, 0, 0, 1 / CFG.GHOST_FPS
conn(RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	local cam = workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position

	-- recording tick (SAMPLE_HZ): record poses, spawn afterimages / trail pieces, age them
	acc += dt
	if acc >= STEP then
		acc %= STEP
		local on = ghostsOn
		local sande, trailing = mode == "sande", mode == "trail" or mode == "forever"
		for _, r in recs do
			record(r, now)
			if r.pool[1] then expire(r, now) end
			for _, tr in r.trails do
				if tr.n > 0 then trailAge(tr, r.tcol, now) end
			end
			if on and r.eye and camPos and r.ghost and r.root.Parent then
				if sande then
					if (r.root.Position - camPos).Magnitude < CFG.SANDE_MAX_DIST then afterimage(r, now) end
				elseif trailing then
					trailStep(r, now, camPos)
				end
			end
		end
	end
	-- hot-route upkeep (4x per second): re-check busy spots, add / remove red lightning, make a few bolts crackle
	hacc += dt
	if hacc >= 0.25 then
		hacc = 0
		for _, h in heats do heatTick(h, now) end
	end

	-- ghost animation tick (GHOST_FPS): only ghosts that are shown, close, and on-screen
	gacc += dt
	if gacc >= GSTEP then
		gacc %= GSTEP
		for _, r in recs do
			local g = r.ghost
			if g and g.Parent and (not camPos or ghostVisible(r, cam, camPos)) then play(r, now) end
		end
	end
end))

conn(Players.PlayerAdded:Connect(function(plr) track(plr, false) end))
conn(Players.PlayerRemoving:Connect(untrack))
for _, plr in Players:GetPlayers() do track(plr, plr ~= lp) end
refreshSel()

task.spawn(function()
	while not dead do
		task.wait(1)
		for plr in recs do
			if plr.Parent ~= Players then untrack(plr) end   -- safety net: anyone no longer in the server is cleaned up
		end
		if menu.Visible then refreshStats() end
	end
end)
