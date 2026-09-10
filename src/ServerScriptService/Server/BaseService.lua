--[[
	BaseService.lua
	Builds the fixed player-base plots ("Steal a Brainrot"-style creature
	display yards, GameConfig.Base.MaxPlayers of them), assigns one to each
	joining player, and keeps each player's pedestals in sync with their
	claimed creatures. Total slots = StartSlots + Rebirths * SlotsPerRebirth
	(no cap); once more than SlotsPerFloor slots are needed, a new story is
	added above the base automatically.

	IMPORTANT FIX (this revision): the roof used to be built ONCE, fixed at
	ground-floor height, as part of the static shelter. That's fine with only
	one story — but the moment a player got enough Rebirths to unlock a 2nd
	story, that solid, collidable roof slab was left sitting in mid-air right
	between Floor 1 and Floor 2, physically blocking the climbing truss and
	making the upper floor unreachable (and looking like a broken floating
	ceiling). The roof is now rebuilt dynamically every RefreshBase call and
	always sits above whichever floor is currently the TOP floor, with open
	connecting pillars (no mid-building ceilings) between every story below
	it. The corner "stairs" truss was also clipping straight through a corner
	pillar (same X/Z inset as the pillars) — moved to the middle of a side
	wall, clear of every pillar.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local CreatureModelDisplay = require(script.Parent.CreatureModelDisplay)

local BaseService = {}

local PlayerDataManager
local EconomyService
local CreatureService
local LeaderboardService
local MonetizationService
local remotesFolder

local plotFolders = {}    -- [plotIndex] = Folder, the static plot (built once, at server start)
local plotAssignment = {} -- [plotIndex] = player currently occupying it, or nil
local playerPlot = {}     -- [player] = plotIndex

-- [player] = { [globalSlotIndex] = TextLabel } — the money label on every
-- currently-filled pedestal, so EconomyService's per-second tick can just
-- update existing text (cheap) instead of tearing down and rebuilding the
-- whole base every second (expensive, and would restart every rotation
-- animation/ProximityPrompt too). Reset every time RefreshBase rebuilds.
local moneyLabels = {}

-- [player] = { [globalSlotIndex] = Model } — every pedestal's currently
-- spawned real 3D creature model (only entries that actually got a real
-- model, not the placeholder ball), so StartFacingLoop below can keep
-- turning each one to face its owner every tick without walking the whole
-- Pedestals folder looking for them. Reset every time RefreshBase rebuilds,
-- same as moneyLabels above.
local creatureModels = {}

-- [plotIndex] = { Upgrade=StatusLabel, Rebirth=StatusLabel, AutoCollect=StatusLabel,
-- DoubleCash=StatusLabel, RebirthRobux=StatusLabel } — the status TextLabel on every
-- fixed base-station kiosk (see buildStations below). Built ONCE per plot,
-- keyed by plotIndex (not by player) because the kiosks themselves are part
-- of the static plot and outlive any single occupant — only their text
-- changes when someone claims/leaves the plot (see UpdateStationLabels /
-- ReleasePlayer).
local stationLabels = {}

function BaseService.Init(deps)
	PlayerDataManager = deps.PlayerDataManager
	EconomyService = deps.EconomyService
	CreatureService = deps.CreatureService
	LeaderboardService = deps.LeaderboardService
	MonetizationService = deps.MonetizationService
	remotesFolder = deps.Remotes
end

-- Places plots evenly around a circle centered on the tower (0,0) — 4 plots
-- = North/East/South/West — and rotates each one to face the tower, so the
-- pedestal rows read naturally from the tower's side.
local function getPlotCFrame(plotIndex)
	local base = GameConfig.Base
	local angle = (plotIndex - 1) * (2 * math.pi / base.MaxPlayers)
	local position = Vector3.new(math.cos(angle) * base.PlotRadius, 0, math.sin(angle) * base.PlotRadius)
	return CFrame.lookAt(position, Vector3.new(0, position.Y, 0))
end

-- Shared helper: builds the 4 corner pillars of a "room" spanning `height`
-- studs, centered at `centerY` (relative to the plot's own CFrame). Used for
-- the ground floor, every connector between stories, and the top room under
-- the roof — so every story looks like a continuous, fully-open column
-- structure instead of separate floating boxes.
local function buildCornerPillars(parent, plotCFrame, centerY, height, namePrefix)
	local base = GameConfig.Base
	local pillarInsetX = base.PlotSize.X / 2 - base.PillarThickness / 2
	local pillarInsetZ = base.PlotSize.Z / 2 - base.PillarThickness / 2
	for _, dirX in ipairs({ -1, 1 }) do
		for _, dirZ in ipairs({ -1, 1 }) do
			local pillar = Instance.new("Part")
			pillar.Name = namePrefix
			pillar.Anchored = true
			pillar.Size = Vector3.new(base.PillarThickness, height, base.PillarThickness)
			pillar.Material = Enum.Material.Concrete
			pillar.Color = Color3.fromRGB(120, 120, 128)
			pillar.CFrame = plotCFrame * CFrame.new(dirX * pillarInsetX, centerY, dirZ * pillarInsetZ)
			pillar.Parent = parent
		end
	end
end

-- Builds a flat roof, `height` studs above `topY` (typically a floor's top
-- surface), spanning the whole plot plus overhang.
local function buildRoof(parent, plotCFrame, topY, height)
	local base = GameConfig.Base
	local roof = Instance.new("Part")
	roof.Name = "Roof"
	roof.Anchored = true
	roof.Size = Vector3.new(base.PlotSize.X + base.RoofOverhang * 2, base.RoofThickness, base.PlotSize.Z + base.RoofOverhang * 2)
	roof.Material = Enum.Material.Concrete
	roof.Color = Color3.fromRGB(150, 150, 158)
	roof.CFrame = plotCFrame * CFrame.new(0, topY + height + base.RoofThickness / 2, 0)
	roof.Parent = parent
end

-- Formats a Cash/sec number the way big "$700M/s"-style displays do.
-- GetCreatureCashRates always hands this a whole number (minimum 1), so
-- below 1000 it's printed as a plain integer — "1/s", not "1.0/s" — and
-- once it crosses 1000 it gets abbreviated with a K/M/B suffix instead of
-- printing a huge raw number, keeping the pedestal display readable as the
-- economy scales up with rebirths/upgrades later.
-- On request ("schöner kürzen, 1796,6B") the decimal point is swapped for a
-- comma — German number style — since string.format's "%.1f" always uses a
-- plain "." regardless of locale. Only affects THIS file's displays (base
-- cash counter/rate, pedestal cash, sell prompt, rebirth cost); the other
-- files' own formatCashShort copies (Admin-Truhe/Glücksrad/Leaderboard/
-- Mega-Truhe) were deliberately left with a "." on request.
local function toCommaDecimal(str)
	return (str:gsub("%.", ","))
end

-- On request ("was kommt nach B -> T oder kann man das nicht schon mit T
-- schreiben?") extended past B with the standard short-scale names, so a
-- number never just keeps growing as an ever-longer "B" — Trillion (1e12),
-- Quadrillion (1e15, "Qa"), Quintillion (1e18, "Qi"), Sextillion (1e21,
-- "Sx"), Septillion (1e24, "Sp"), Octillion (1e27, "Oc"). Nothing named
-- above Octillion — a value that somehow gets bigger than that just keeps
-- growing as an ever-larger "Oc" number instead of erroring.
local function formatCashRate(value)
	if value >= 1e27 then
		return toCommaDecimal(string.format("%.1f", value / 1e27)) .. "Oc"
	elseif value >= 1e24 then
		return toCommaDecimal(string.format("%.1f", value / 1e24)) .. "Sp"
	elseif value >= 1e21 then
		return toCommaDecimal(string.format("%.1f", value / 1e21)) .. "Sx"
	elseif value >= 1e18 then
		return toCommaDecimal(string.format("%.1f", value / 1e18)) .. "Qi"
	elseif value >= 1e15 then
		return toCommaDecimal(string.format("%.1f", value / 1e15)) .. "Qa"
	elseif value >= 1e12 then
		return toCommaDecimal(string.format("%.1f", value / 1e12)) .. "T"
	elseif value >= 1e9 then
		return toCommaDecimal(string.format("%.1f", value / 1e9)) .. "B"
	elseif value >= 1e6 then
		return toCommaDecimal(string.format("%.1f", value / 1e6)) .. "M"
	elseif value >= 1e3 then
		return toCommaDecimal(string.format("%.1f", value / 1e3)) .. "K"
	else
		return string.format("%d", value)
	end
end

-- Adds a small ambient interior light near the ceiling of one floor's room,
-- so multi-story bases (open framework between stories, not solid walls)
-- don't go pitch dark inside once you're a level or two up.
local function addFloorLight(parent, floorCFrame)
	local lightPost = Instance.new("Part")
	lightPost.Name = "LightPost"
	lightPost.Anchored = true
	lightPost.CanCollide = false
	lightPost.Transparency = 1
	lightPost.Size = Vector3.new(1, 1, 1)
	-- Auf Wunsch ("das Umgebungslicht ... etwas höher stellen, 1 Stufe wenn
	-- das geht") von 6 auf 8 Studs über dem Etagenboden angehoben (+2,
	-- ungefähr eine Treppenstufe hoch, siehe die ~2-Stud-Stufenhöhe der
	-- Treppen weiter unten in dieser Datei) — der Raum ist seit der
	-- FloorHeight-Erhöhung ohnehin 18 Studs hoch, da ist oben noch reichlich
	-- Luft.
	lightPost.CFrame = floorCFrame * CFrame.new(0, 8, 0)
	lightPost.Parent = parent

	local light = Instance.new("PointLight")
	-- On request ("es ist schon eine Lichtquelle auf den Ebenen, kann man
	-- die zurückdrehen?", bestätigt an einer komplett LEEREN Basis ohne
	-- Kreaturen/Kioske — dieses Licht ist also selbst dann noch sichtbar zu
	-- stark) — Brightness fast halbiert (2.5→1.3) und Range deutlich
	-- verkleinert (45→28, war weit größer als eine einzelne Etage/Plot
	-- ohnehin braucht und strahlte dadurch unnötig weit in Nachbar-Etagen
	-- und -Plots hinein). Reicht immer noch, um die offene Etage nicht
	-- pechschwarz wirken zu lassen (siehe Funktionskommentar oben), ist
	-- aber spürbar gedämpfter.
	light.Brightness = 1.3
	light.Range = 28
	light.Color = Color3.fromRGB(255, 244, 214)
	light.Parent = lightPost
end

-- Builds the static "Steal a Brainrot"-style ground shelter around a plot:
-- 4 ground-floor corner pillars, a flat roof, a sign over the entrance
-- (facing the tower — plotCFrame's front already points that way, see
-- getPlotCFrame), a red carpet down the middle, an interior light, and a
-- decorative "Collect Zone" mat just outside. This is static, built once,
-- so EVERY plot has a complete-looking 1-story shelter immediately — even
-- before any player has ever joined it. RefreshBase hides this ground roof
-- (and adds its own, higher up, plus extra floors/lights) only once a
-- player's capacity needs more than 1 story, and restores it when they
-- leave — see RefreshBase / ReleasePlayer.
local function buildStructure(plotFolder, plotCFrame)
	local base = GameConfig.Base
	local halfZ = base.PlotSize.Z / 2
	local platformTopY = base.PlotSize.Y / 2

	local structureFolder = Instance.new("Folder")
	structureFolder.Name = "Structure"
	structureFolder.Parent = plotFolder

	-- Ground floor's 4 corner pillars
	local groundPillarY = platformTopY + base.WallHeight / 2
	buildCornerPillars(structureFolder, plotCFrame, groundPillarY, base.WallHeight, "Pillar")

	-- Floating name tag hovering above the base (replaces the old physical
	-- wooden entrance sign, on request: "Schild entfernen, stattdessen den
	-- Namen über der Base schwebend sehen, grüne Schrift mit schwarzem
	-- Rand"). A BillboardGui on an invisible anchor Part — same convention
	-- as the tower's Floor-number landmarks (TowerGenerator.lua) — always
	-- faces the camera and reads clearly from any angle, unlike the old
	-- SurfaceGui which only read head-on. Deliberately built ONCE here at a
	-- FIXED height above the ground floor (not recomputed per story count
	-- in RefreshBase) — same "stays put regardless of how tall the base
	-- gets" behavior the old entrance sign already had.
	-- No MaxDistance set (on request) — unlike the pedestal/claim-spot
	-- names, which are deliberately capped short to avoid spoiling what's
	-- on display, this is purely an identity tag ("wessen Base ist das"),
	-- meant to read from a genuine distance while approaching, same as the
	-- tower's Floor-number landmarks.
	local nameTagAnchor = Instance.new("Part")
	nameTagAnchor.Name = "NameTagAnchor"
	nameTagAnchor.Anchored = true
	nameTagAnchor.CanCollide = false
	nameTagAnchor.CanQuery = false
	nameTagAnchor.Transparency = 1
	nameTagAnchor.Size = Vector3.new(1, 1, 1)
	nameTagAnchor.CFrame = plotCFrame * CFrame.new(0, platformTopY + base.WallHeight + 4, -halfZ)
	nameTagAnchor.Parent = structureFolder

	local nameTagGui = Instance.new("BillboardGui")
	nameTagGui.Name = "NameTagGui"
	nameTagGui.Size = UDim2.new(0, 280, 0, 60)
	nameTagGui.AlwaysOnTop = true
	nameTagGui.Parent = nameTagAnchor

	local nameTagLabel = Instance.new("TextLabel")
	nameTagLabel.Name = "Text"
	nameTagLabel.Size = UDim2.new(1, 0, 1, 0)
	nameTagLabel.BackgroundTransparency = 1
	nameTagLabel.Text = "Free Base"
	nameTagLabel.TextColor3 = Color3.fromRGB(60, 220, 90) -- green, on request
	nameTagLabel.TextStrokeTransparency = 0 -- solid black outline, on request
	nameTagLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameTagLabel.TextScaled = true
	nameTagLabel.Font = Enum.Font.GothamBlack
	nameTagLabel.Parent = nameTagGui

	-- Red carpet path down the middle
	local carpet = Instance.new("Part")
	carpet.Name = "Carpet"
	carpet.Anchored = true
	carpet.CanCollide = false
	carpet.Size = Vector3.new(base.CarpetWidth, 0.2, base.PlotSize.Z)
	carpet.Material = Enum.Material.Fabric
	carpet.Color = Color3.fromRGB(200, 40, 40)
	carpet.CFrame = plotCFrame * CFrame.new(0, platformTopY + 0.11, 0)
	carpet.Parent = structureFolder

	-- Static ground-floor roof + interior light. Named "Roof" so RefreshBase
	-- can find it (plotFolder.Structure.Roof) and hide it for multi-story
	-- bases instead of leaving two overlapping roofs.
	buildRoof(structureFolder, plotCFrame, platformTopY, base.WallHeight)
	addFloorLight(structureFolder, plotCFrame)
end

-- Normalizes a value from GameConfig.Base.StationIcons into a usable
-- ImageLabel.Image string, or nil if that station has no icon configured
-- (the "" default). Accepts either a bare asset number pasted straight from
-- Studio's "Copy Asset ID" ("123456789") or the full URI form someone might
-- paste instead ("rbxassetid://123456789") — either works, so there's one
-- less way to get this wrong.
local function toAssetIdString(value)
	if not value or value == "" then
		return nil
	end
	local str = tostring(value)
	if str:match("^rbxassetid://") then
		return str
	end
	return "rbxassetid://" .. str
end

-- Builds one fixed base-station INTERACTION SPOT — a thin glowing floor
-- disc (not a solid podium block — CanCollide is off on purpose, so it's a
-- marker to stand on, not an obstacle to walk around) with a floating icon
-- above it: either a real image (if GameConfig.Base.StationIcons has an
-- asset ID for this station) or a big emoji symbol as the fallback, plus a
-- title and a status line, plus a hold-to-interact ProximityPrompt. Used
-- for every action that used to be a persistent screen-HUD button (Jump
-- Upgrade, Rebirth, Auto-Sammeln (formerly Slap Hand), 2x Cash, 1x
-- Wiedergeburt (formerly VIP) — see UIBuilder.lua / init.client.lua, which
-- no longer build those at all) and is now instead
-- something you physically walk up to inside your own base. Returns the
-- disc part, its status TextLabel (for UpdateStationLabels to refresh), and
-- the ProximityPrompt (for the caller to wire a Triggered handler on).
--
-- `emojiIcon` is the always-available fallback (a plain string, e.g.
-- "⬆️"). `assetIdIcon` is the resolved GameConfig.Base.StationIcons value
-- for this station (already run through toAssetIdString by the caller), or
-- nil to just use the emoji. Unlike loading a Toolbox MODEL by ID (which
-- needs InsertService and has repeatedly failed in this project with "User
-- is not authorized to access Asset" — see CreatureModelDisplay's own
-- comments on that), a Decal/Image asset ID on an ImageLabel's .Image
-- property is just a texture reference and loads directly with no special
-- permission needed, so this is safe to wire straight to a config value.
--
-- `hideIcon` (on request, "die Symbole der Kaufstationen ... sollen
-- verschwinden und nur die Schrift in der grünen Farbe kommt") — when true,
-- skips the floating emoji/image symbol entirely and instead grows the
-- Title/Status text to fill that space, both recolored to the same bright
-- green as the HUD's own Cash display (UIBuilder.lua's makeBigStatRow
-- "grün ... leuchtend" accent) instead of white/gray. Defaults to nil/false
-- (icon shown) so the other buildStationPart callers that were never
-- mentioned in that request — buildWheelKiosk, buildFastTravelKiosk —
-- keep their icon exactly as before; only the 5
-- buildStations() calls (Jump Upgrade, Rebirth, Auto-Sammeln, 2x Cash, 1x
-- Wiedergeburt) pass true.
--
-- `onGround` (bug fix, "die Platten schweben in der Luft") — the 4
-- buildStations() kiosks that stand OUTSIDE the plot's own footprint (see
-- frontZ in buildStations) were still measuring their height against
-- base.PlotSize.Y (the PLATFORM's own thickness), which only happens to
-- describe the platform's surface, not the grass out past its edge — those
-- two heights differ (see GameConfig.Base.GroundTopY's own comment), so the
-- pads floated ~1.5 studs above the actual ground. When true, the pad
-- measures against GameConfig.Base.GroundTopY instead — plotCFrame's own
-- world Y position is always 0 and its rotation is yaw-only (see
-- getPlotCFrame), so the grass's world top Y converts to a LOCAL Y offset
-- with no further math needed. Auto-Sammeln (still on the platform itself,
-- at Slap Hand's old spot) and the 3 other kiosks (already sitting on their
-- own small platforms) leave this nil/false and keep using the
-- platform-relative height.
-- `activateOnTouch` (on request, "kann man es auch so machen wenn man
-- darauf steht das sie aktiviert werden?") — when true, REPLACES the
-- hold-to-interact ProximityPrompt entirely with a plain Touched-based
-- trigger: stepping onto the pad fires immediately, no E/hold needed.
-- Started out limited to Jump Upgrade/Rebirth only (both just OPEN a panel/
-- confirmation dialog, so an accidental trigger from merely walking across
-- has no real consequence) — since extended to every other kiosk too
-- (Auto-Sammeln, 2x Cash, 1x Wiedergeburt, all on request), even though
-- those fire a real Robux purchase PROMPT. That's still safe: the prompt
-- itself is Roblox's own confirmation dialog (it always shows the price and
-- needs an explicit second confirm/buy click there), so walking across the
-- pad can at most OPEN that dialog, never complete a purchase by accident.
-- Every one of the 5 buildStations() kiosks, plus the separate shared
-- Glücksrad kiosk (buildWheelKiosk), now uses activateOnTouch=true.
-- The 3rd return value is still called `prompt` and still exposes a
-- `.Triggered` signal either way (a real ProximityPrompt.Triggered, or a
-- plain BindableEvent.Event standing in for it here) — every existing
-- caller's `prompt.Triggered:Connect(function(triggeringPlayer) ... end)`
-- code keeps working completely unchanged regardless of which kind it got.
--
-- `textColor` (on request, "die Farben ... anpassen. Wiedergeburt Blau, 2x
-- Cash Gold") — only meaningful when hideIcon is true; overrides the default
-- bright green (textOnlyGreen below) for THIS kiosk's Title/Status text.
-- Optional/nil for every other caller, so Jump Upgrade/Rebirth/Auto-Sammeln
-- keep the original green untouched — only 2x Cash and 1x Wiedergeburt were
-- asked to change.
local function buildStationPart(parent, plotCFrame, localX, localZ, color, title, actionText, emojiIcon, assetIdIcon, hideIcon, onGround, activateOnTouch, textColor)
	local base = GameConfig.Base
	local platformTopY = base.PlotSize.Y / 2
	local padY = (onGround and base.GroundTopY or platformTopY) + 0.15

	local pad = Instance.new("Part")
	pad.Name = title:gsub("%s+", "") .. "Station"
	pad.Shape = Enum.PartType.Cylinder
	pad.Anchored = true
	pad.CanCollide = false
	pad.Material = Enum.Material.Neon
	-- Blended toward white + given some Transparency (on request, "Farben
	-- ... zu kräftig / Boom-Effekt zu stark", then again "grelle Lichter
	-- sind immer noch zu stark") — softens the Neon glow of every kiosk/
	-- station pad at once, since they all funnel through this one shared
	-- function. Raised a second time (0.2→0.45 Lerp, 0.2→0.35 Transparency)
	-- after the first pass still read as too intense. Still clearly each
	-- station's own color, just noticeably calmer than full-strength Neon.
	-- Raise further still if needed; 0 either would go back to the
	-- original solid, fully-saturated look.
	pad.Color = color:Lerp(Color3.new(1, 1, 1), 0.45)
	pad.Transparency = 0.35
	pad.Size = Vector3.new(0.3, 5, 5)
	-- A Cylinder part's round faces are perpendicular to its own LOCAL X
	-- axis by default (so an unrotated one stands on its side, facing
	-- sideways) — rotating 90° around Z swaps its local X for local Y
	-- (plotCFrame's "up"), which lays it flat on the floor instead, like a
	-- glowing coin.
	pad.CFrame = plotCFrame * CFrame.new(localX, padY, localZ) * CFrame.Angles(0, 0, math.rad(90))
	pad.Parent = parent

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Billboard"
	billboard.Size = UDim2.new(0, 170, 0, 130)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	-- Same MaxDistance fix as the pedestal NameTags and tower claim-spot
	-- names (see their own comments) — AlwaysOnTop with no MaxDistance
	-- draws straight through walls/other bases from basically any range.
	-- 60 here (not the pedestals' 40, not the tower's 100) since this isn't
	-- about hiding anything (there's nothing secret about which base
	-- station is where) — just about not cluttering the view with 5 more
	-- floating icons while looking at a neighboring base or the tower.
	billboard.MaxDistance = 60
	billboard.Parent = pad

	-- The symbol itself — large, on top, so it reads from across the base
	-- (exactly what replaces the old podium block as the "what is this"
	-- visual cue). A real image if one's configured, otherwise the emoji.
	-- Skipped entirely when hideIcon is true (see its own comment above) —
	-- Title/Status below then expand to fill the freed-up space instead.
	if not hideIcon then
		if assetIdIcon then
			local iconImage = Instance.new("ImageLabel")
			iconImage.Name = "IconImage"
			iconImage.Size = UDim2.new(1, 0, 0.55, 0)
			iconImage.BackgroundTransparency = 1
			iconImage.Image = assetIdIcon
			iconImage.ScaleType = Enum.ScaleType.Fit
			iconImage.Parent = billboard
		else
			local iconLabel = Instance.new("TextLabel")
			iconLabel.Name = "IconText"
			iconLabel.Size = UDim2.new(1, 0, 0.55, 0)
			iconLabel.BackgroundTransparency = 1
			iconLabel.Text = emojiIcon
			iconLabel.TextScaled = true
			iconLabel.Font = Enum.Font.GothamBold
			iconLabel.Parent = billboard
		end
	end

	-- Same bright green as the HUD's own glowing Cash display
	-- (UIBuilder.lua's makeBigStatRow CashLabel accent) — only used when
	-- hideIcon is true; the icon-shown kiosks (Robux Trader/Wheel/Fast
	-- Travel) keep the original white title / gray status colors untouched.
	-- `textColor` (see its own comment above) overrides this per-kiosk.
	local textOnlyGreen = Color3.fromRGB(70, 255, 90)
	local hideIconColor = textColor or textOnlyGreen

	-- On request ("etwas kleiner dafür die Schrift Fett") — shrunk from the
	-- original 0.5/0.5 full-height split down to 0.4/0.32 with a little
	-- breathing room above/between/below, so the TextScaled text renders
	-- noticeably smaller instead of filling the whole billboard.
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "TitleText"
	titleLabel.Size = hideIcon and UDim2.new(1, 0, 0.4, 0) or UDim2.new(1, 0, 0.25, 0)
	titleLabel.Position = hideIcon and UDim2.new(0, 0, 0.04, 0) or UDim2.new(0, 0, 0.55, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextColor3 = hideIcon and hideIconColor or Color3.new(1, 1, 1)
	titleLabel.TextStrokeTransparency = 0.3
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.TextScaled = true
	titleLabel.Parent = billboard

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusText"
	statusLabel.Size = hideIcon and UDim2.new(1, 0, 0.32, 0) or UDim2.new(1, 0, 0.2, 0)
	statusLabel.Position = hideIcon and UDim2.new(0, 0, 0.52, 0) or UDim2.new(0, 0, 0.8, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "—"
	statusLabel.TextColor3 = hideIcon and hideIconColor or Color3.fromRGB(210, 210, 210)
	statusLabel.TextStrokeTransparency = 0.3
	-- Was Enum.Font.Gotham (not bold) — changed to GothamBold on request
	-- ("die Schrift Fett"), matching the title's font weight.
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextScaled = true
	statusLabel.Parent = billboard

	local prompt
	if activateOnTouch then
		-- No ProximityPrompt at all here (on request — see activateOnTouch's
		-- comment above). `touching` tracks who's CURRENTLY standing on the
		-- pad so Touched (which can fire more than once per continuous
		-- stand — a character's limbs constantly break/remake contact while
		-- just standing still) only fires the action ONCE per approach, not
		-- repeatedly every fraction of a second; TouchEnded clears it again
		-- so stepping off and back on fires it again, same as walking up to
		-- a real ProximityPrompt a second time. CanCollide = false on `pad`
		-- (see above) does NOT stop Touched from firing — that only affects
		-- physical collision response, not touch detection — so this works
		-- exactly like the pedestal collection hitboxes elsewhere in this
		-- file already do.
		local touching = {} -- [player] = true while standing on the pad
		local touchEvent = Instance.new("BindableEvent")

		local function getTouchingPlayer(hit)
			local character = hit.Parent
			return character and Players:GetPlayerFromCharacter(character)
		end

		pad.Touched:Connect(function(hit)
			local touchingPlayer = getTouchingPlayer(hit)
			if not touchingPlayer or touching[touchingPlayer] then
				return
			end
			touching[touchingPlayer] = true
			touchEvent:Fire(touchingPlayer)
		end)
		pad.TouchEnded:Connect(function(hit)
			local touchingPlayer = getTouchingPlayer(hit)
			if touchingPlayer then
				touching[touchingPlayer] = nil
			end
		end)
		Players.PlayerRemoving:Connect(function(leavingPlayer)
			touching[leavingPlayer] = nil
		end)

		-- A plain Lua table standing in for the ProximityPrompt: exposing
		-- `.Triggered` as the BindableEvent's `.Event` means every existing
		-- caller's `prompt.Triggered:Connect(function(triggeringPlayer) ...
		-- end)` code (see buildStations below) works completely unchanged —
		-- it never needs to know whether it got a real ProximityPrompt or
		-- this touch-based stand-in.
		prompt = { Triggered = touchEvent.Event }
	else
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "Prompt"
		prompt.ActionText = actionText
		prompt.ObjectText = title
		prompt.HoldDuration = 0.3
		prompt.MaxActivationDistance = 15 -- war 10, testweise +5 auf Wunsch
		prompt.RequiresLineOfSight = false
		-- Custom instead of Default: drops Robloxs eingebautes rechteckiges
		-- Prompt-Kästchen (auf Wunsch entfernt — siehe StarterPlayerScripts/
		-- CustomPromptUI.client.lua für die schlanke Ersatz-GUI: nur Kreis ums
		-- Tasten-Symbol + Text) UND behebt nebenbei "Maus bleibt stehen, Kamera
		-- dreht sich nicht mehr", das nur bei Default-Style-Prompts auftrat.
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.Parent = pad
	end

	return pad, statusLabel, prompt
end

-- Builds all 5 fixed base stations for one plot, once, at server start —
-- into their own "Stations" folder (a sibling of Structure), completely
-- separate from the Pedestals folder RefreshBase tears down and rebuilds on
-- every claim/sell/rebirth, so a station's ProximityPrompt/BillboardGui is
-- never reset or reconnected while a player is standing at it. Each one
-- shows as a floating emoji symbol (see buildStationPart) rather than a
-- solid podium block, on request.
--
-- On request ("ich möchte sie hier vor der Base haben", referencing a
-- screenshot of the player standing on the ground just outside the
-- entrance) — 4 of the 5 stations now stand OUTSIDE the plot's own
-- footprint, on the ground right in front of the entrance (the entrance
-- always faces the tower, see getPlotCFrame — that's the -Z side of
-- plotCFrame, same side buildStructure's floating name tag/entrance faces),
-- at frontZ = -(PlotSize.Z/2 + 8) = 8 studs out past the platform edge (the
-- user's own explicit "nah am Eingang" choice over a further-out spread).
-- Still split left/right of where the carpet exits, same grouping as
-- before: 1x Wiedergeburt (localX -28, formerly VIP) + 2x Cash (localX -14)
-- on the LEFT, Rebirth + Jump Upgrade on the RIGHT (localX 14/28). Slap Hand
-- (now Auto-Sammeln) is explicitly EXCLUDED from this move — on the user's
-- own explicit choice, it stays exactly where it
-- always was, back on the platform along the old back-wall row (localX 0,
-- localZ 29), not moved out front with the other 4.
--
-- On request ("die Kauf Felder nach außen schieben ... näher an der
-- Außensäule") — the outer two (Jump Upgrade/1x Wiedergeburt) moved from
-- localX ±16 to ±28, the inner two (Rebirth/2x Cash) from ±8 to ±14. The
-- 4 corner pillars (buildCornerPillars) sit at localX = ±(PlotSize.X/2 -
-- PillarThickness/2) = ±(70/2 - 4/2) = ±33, so ±28 leaves a small ~5-stud
-- gap to the pillar instead of overlapping it, while still reading as
-- "right next to it" compared to the old ±16.
--
-- Every Triggered handler is gated to whoever currently OWNS this plot
-- (plotAssignment[plotIndex]) — unlike the pedestal sell prompts, a
-- visiting player might reasonably walk through someone else's base and
-- try a kiosk out of curiosity, so they get a polite Notice instead of the
-- prompt just silently doing nothing.
local function buildStations(plotFolder, plotIndex, plotCFrame)
	local base = GameConfig.Base
	-- 8 studs out past the platform's front edge (the entrance side, facing
	-- the tower) — see the comment above for why 4 of the 5 stations use
	-- this instead of the old on-platform localZ = 29.
	local frontZ = -(base.PlotSize.Z / 2 + 8)

	local labels = {}
	stationLabels[plotIndex] = labels

	local stationsFolder = Instance.new("Folder")
	stationsFolder.Name = "Stations"
	stationsFolder.Parent = plotFolder

	local function requireOwner(triggeringPlayer)
		if plotAssignment[plotIndex] ~= triggeringPlayer then
			if remotesFolder then
				remotesFolder.Notice:FireClient(triggeringPlayer, "Das ist nicht deine Base!")
			end
			return false
		end
		return true
	end

	-- Jump Upgrade — walking up to it now OPENS the Sprung-Upgrade panel
	-- (bulk-buy multiple Sprung-points at once, see GameConfig.JumpUpgrade /
	-- EconomyService.BuyJumpUpgrade / UIBuilder's Jump Upgrade panel)
	-- instead of buying a single tier directly, same "kiosk just relays an
	-- open-panel event" pattern as the Rebirth altar below.
	do
		local _, statusLabel, prompt = buildStationPart(
			stationsFolder, plotCFrame, 28, frontZ, Color3.fromRGB(40, 170, 90), "Jump Upgrade", "Öffnen",
			"⬆️", toAssetIdString(GameConfig.Base.StationIcons.Upgrade), true, true, true
		)
		labels.Upgrade = statusLabel
		prompt.Triggered:Connect(function(triggeringPlayer)
			if not requireOwner(triggeringPlayer) then
				return
			end
			if remotesFolder then
				remotesFolder.RequestJumpUpgradePanel:FireClient(triggeringPlayer)
			end
		end)
	end

	-- Rebirth altar — like the old RebirthButton, walking up to it only
	-- OPENS the confirmation dialog; the actual Rebirth still happens
	-- through the existing "Rebirth" RemoteFunction once the player
	-- confirms client-side (see init.client.lua's RequestRebirthConfirm
	-- listener, which rebuilds the exact same warning text the button used
	-- to, from the DataUpdated payload it already has).
	do
		local _, statusLabel, prompt = buildStationPart(
			stationsFolder, plotCFrame, 14, frontZ, Color3.fromRGB(255, 200, 0), "Wiedergeburt", "Öffnen",
			"♻️", toAssetIdString(GameConfig.Base.StationIcons.Rebirth), true, true, true
		)
		labels.Rebirth = statusLabel
		prompt.Triggered:Connect(function(triggeringPlayer)
			if not requireOwner(triggeringPlayer) then
				return
			end
			if remotesFolder then
				remotesFolder.RequestRebirthConfirm:FireClient(triggeringPlayer)
			end
		end)
	end

	-- Auto-Sammeln (Auto-Collect) gamepass — on request, REPLACES the old
	-- Slap Hand kiosk at this exact spot ("Slap Hand entfernen und
	-- stattdessen ein Kauf Button für automatisch Geld Sammeln"). Same relay
	-- pattern as 2x Cash below (a Robux gamepass prompt can only open
	-- CLIENT-side) — the actual "automatically collects the Brainrots'
	-- money" behavior lives in EconomyService.StartPassiveIncomeLoop, which
	-- checks MonetizationService.OwnsAutoCollect every payout tick; this
	-- kiosk's only job is opening the purchase prompt. Kept on the platform
	-- at Slap Hand's old spot (localX 0, localZ 29) rather than moved out
	-- front with the other 4 — never asked to move, so left exactly where
	-- it was.
	-- Rebuilt (on request) — same underlying logic as before, but now with
	-- activateOnTouch=true (see buildStationPart's own comment on that
	-- param) added as the 12th argument, so standing on the pad fires it
	-- immediately, no E/hold needed anymore — same "walk onto it" behavior
	-- as the Wiedergeburt altar above. onGround stays false/nil (11th arg)
	-- since Auto-Sammeln is still on the platform itself, not moved out
	-- front onto the grass like Wiedergeburt/2x Cash/Jump Upgrade are.
	do
		local _, statusLabel, prompt = buildStationPart(
			stationsFolder, plotCFrame, 0, 29, Color3.fromRGB(0, 200, 190), "Auto-Sammeln", "Kaufen",
			"🧲", toAssetIdString(GameConfig.Base.StationIcons.AutoCollect), true, false, true
		)
		labels.AutoCollect = statusLabel
		prompt.Triggered:Connect(function(triggeringPlayer)
			if not requireOwner(triggeringPlayer) then
				return
			end
			-- Owned-check added (on request, "kann man es immer wieder
			-- kaufen, aber es soll einmal gekauft werden") — this is a
			-- Developer Product (see GameConfig.Gamepasses.AutoCollect's own
			-- comment), which Roblox happily lets someone buy again and
			-- again for real Robux each time, with zero extra effect once
			-- already owned (EconomyService.StartPassiveIncomeLoop only ever
			-- checks the ONE persisted flag, buying it twice doesn't do
			-- anything twice) — so without this check, a repeat purchase
			-- would just silently take the player's Robux for nothing. Same
			-- "already active" guard the 2x Cash kiosk uses right below.
			if MonetizationService and MonetizationService.OwnsAutoCollect(triggeringPlayer) then
				if remotesFolder then
					remotesFolder.Notice:FireClient(triggeringPlayer, "Auto-Sammeln ist bereits aktiv!")
				end
				return
			end
			if remotesFolder then
				remotesFolder.RequestGamepassPrompt:FireClient(triggeringPlayer, "AutoCollect")
			end
		end)
	end

	-- 2x Cash / 4x Cash — a Robux purchase prompt can only be opened
	-- CLIENT-side (MarketplaceService:PromptProductPurchase — a Developer
	-- Product despite the "gamepass" naming throughout this file, see
	-- GameConfig.Gamepasses.DoubleCash's own big comment on that), so the
	-- server just relays "open the prompt for this one" and the client does
	-- the actual call (see init.client.lua's RequestGamepassPrompt listener).
	--
	-- activateOnTouch=true (on request, "kannst diese Button auch ändern das
	-- man darauf steigen muss" — same change already made to Auto-Sammeln
	-- and matching Wiedergeburt/Jump Upgrade) — standing on the pad fires it
	-- immediately now, no E/hold needed.
	do
		-- Title/Status text color on request ("2x Cash Gold") — a warm gold,
		-- separate from the pad's own disc color above.
		local goldTextColor = Color3.fromRGB(255, 200, 40)
		local _, statusLabel, prompt = buildStationPart(
			stationsFolder, plotCFrame, -14, frontZ, Color3.fromRGB(220, 170, 20), "2x Cash", "Kaufen",
			"💰", toAssetIdString(GameConfig.Base.StationIcons.DoubleCash), true, true, true, goldTextColor
		)
		labels.DoubleCash = statusLabel
		prompt.Triggered:Connect(function(triggeringPlayer)
			if not requireOwner(triggeringPlayer) then
				return
			end
			-- "4x Cash" upgrade (on request) — this same kiosk automatically
			-- offers the QuadCash Game Pass instead of DoubleCash once the
			-- player already owns DoubleCash (see GameConfig.Gamepasses.
			-- QuadCash's own comment for the full design). Someone who
			-- already owns QuadCash has nothing left to buy here.
			local ownsQuadCash = MonetizationService and MonetizationService.OwnsQuadCash(triggeringPlayer)
			local ownsDoubleCash = MonetizationService and MonetizationService.OwnsDoubleCash(triggeringPlayer)
			if ownsQuadCash then
				if remotesFolder then
					remotesFolder.Notice:FireClient(triggeringPlayer, "4x Cash ist bereits aktiv!")
				end
				return
			end
			if remotesFolder then
				remotesFolder.RequestGamepassPrompt:FireClient(triggeringPlayer, ownsDoubleCash and "QuadCash" or "DoubleCash")
			end
		end)
	end

	-- "1x Wiedergeburt" Robux button — on request, REPLACES the old VIP
	-- gamepass kiosk at this exact spot ("den VIP Button ändern in 1x
	-- Wiedergeburt und darunter nur (Robux Zeichen)199"). A Developer
	-- Product (GameConfig.Rebirth.RobuxProduct), not a Gamepass — it grants
	-- exactly one Rebirth per purchase (see EconomyService.
	-- BuyRebirthWithRobux, wired up from MonetizationService.ProcessReceipt)
	-- rather than being owned forever, so it needs its OWN relay event
	-- (RequestRebirthProductPrompt) instead of RequestGamepassPrompt above —
	-- PromptProductPurchase and PromptGamePassPurchase are two different
	-- MarketplaceService calls. Status label text is set in
	-- UpdateStationLabels below, using the Robux icon glyph (\u{E002}) the
	-- user asked for instead of spelling out "Robux".
	--
	-- activateOnTouch=true (on request, "denn musst du noch ändern" —
	-- following the same change already made to Auto-Sammeln and 2x Cash)
	-- — standing on the pad now opens the purchase prompt directly, no E/
	-- hold needed. Same safety reasoning as those two: Roblox's own
	-- purchase dialog still needs an explicit second confirm/buy click, so
	-- walking across the pad can only OPEN that dialog, never complete a
	-- purchase by itself.
	do
		-- Title/Status text color on request ("Wiedergeburt Blau") — a bright
		-- blue, separate from the pad's own purple disc color above.
		local blueTextColor = Color3.fromRGB(60, 160, 255)
		local _, statusLabel, prompt = buildStationPart(
			stationsFolder, plotCFrame, -28, frontZ, Color3.fromRGB(180, 60, 220), "1x Wiedergeburt", "Kaufen",
			"🔁", toAssetIdString(GameConfig.Base.StationIcons.RebirthRobux), true, true, true, blueTextColor
		)
		labels.RebirthRobux = statusLabel
		prompt.Triggered:Connect(function(triggeringPlayer)
			if not requireOwner(triggeringPlayer) then
				return
			end
			-- Bugfix (on report, "ich kann trotz Wiedergeburt 15 trotzdem im
			-- Shop weiter kaufen das darf nicht sein"): unlike the 2x/4x Cash
			-- kiosk above (which already checks ownsQuadCash before relaying
			-- the prompt request), this kiosk used to fire
			-- RequestRebirthProductPrompt unconditionally, opening Roblox's
			-- REAL-MONEY purchase dialog even once MaxRebirths was already
			-- reached — EconomyService.BuyRebirthWithRobux would then just
			-- no-op server-side (see its own comment / MonetizationService.
			-- ProcessReceipt), but the player's Robux would already be spent
			-- for nothing by that point, since Roblox charges before
			-- ProcessReceipt even runs. Guarding it here, before the prompt is
			-- ever opened, is the only way to actually stop that.
			local data = PlayerDataManager.Get(triggeringPlayer)
			if data and data.Rebirths >= GameConfig.Rebirth.MaxRebirths then
				if remotesFolder then
					remotesFolder.Notice:FireClient(triggeringPlayer, "Max Rebirth-Stufe bereits erreicht (" .. GameConfig.Rebirth.MaxRebirths .. ")!")
				end
				return
			end
			if remotesFolder then
				remotesFolder.RequestRebirthProductPrompt:FireClient(triggeringPlayer)
			end
		end)
	end
end

-- The separate SHARED Robux Jump-Upgrade trader kiosk ("Sprung-Händler")
-- that used to be built here (buildRobuxTrader) has been fully removed on
-- request ("diesen Separaten Sprung Händler kann man entfernen") — it only
-- ever opened the exact same Jump Upgrade panel every base's own Jump
-- Upgrade kiosk already opens (see buildStations below), so it was pure
-- redundancy. GameConfig.RobuxTrader is gone too (see its own note); the
-- diagonal gap this kiosk's platform used to stand on is just empty ground
-- now, nothing is built there anymore.

-- Builds the single SHARED Glücksrad (wheel of fortune) kiosk (see
-- GameConfig.WheelOfFortune / WheelService.lua) — same "fake plotCFrame on
-- its own small platform" trick as buildFastTravelKiosk below, same NO
-- requireOwner gate (any player, from any base, can use it). Same "kiosk
-- just OPENS A PANEL" pattern as the Jump Upgrade kiosk above (not the
-- immediate-purchase pattern Auto-Sammeln/2x Cash/1x Wiedergeburt use) — the actual spin
-- (free daily, or Robux) happens from buttons INSIDE that panel (see
-- UIBuilder.lua's Wheel panel / init.client.lua's RequestWheelPanel
-- listener), since the panel needs to show the wheel's 6 prize segments and
-- two separate buttons, not something a single instant Triggered action
-- could drive.
local function buildWheelKiosk()
	local wheel = GameConfig.WheelOfFortune
	local base = GameConfig.Base

	local wheelFolder = Instance.new("Folder")
	wheelFolder.Name = "WheelOfFortune"
	wheelFolder.Parent = Workspace

	local wheelCFrame = CFrame.lookAt(wheel.Position, Vector3.new(0, wheel.Position.Y, 0))

	local platform = Instance.new("Part")
	platform.Name = "Platform"
	platform.Anchored = true
	platform.Size = Vector3.new(20, base.PlotSize.Y, 20)
	platform.Material = Enum.Material.Concrete
	platform.Color = Color3.fromRGB(150, 150, 158)
	platform.CFrame = wheelCFrame
	platform.Parent = wheelFolder

	-- Status text + orange color on request ("eine Schrift wie bei den
	-- andern Verkaufskiosten machen mit der Beschreibung 'Versuch dein
	-- Glück' in der Farbe Orange") — same hideIcon=true "Nur [text]"-style
	-- bigger/colored Title+Status layout the other purchase kiosks (2x
	-- Cash/Auto-Sammeln/1x Wiedergeburt) already use, via buildStationPart's
	-- textColor param. hideIcon=true also means buildStationPart never
	-- creates the old flat emoji/image icon in the first place — which used
	-- to need manually destroying right after (see the removed comment
	-- block this replaced), since a real 3D Spinwheel decoration already
	-- stands on the platform itself. The title text ("Glücksrad") stays, so
	-- the billboard still tells players what the station is. Every other
	-- station (Fast-Travel, Jump-Upgrade, Robux-Trader) still calls
	-- buildStationPart with hideIcon left at its default (false) and keeps
	-- its own icon.
	local orangeTextColor = Color3.fromRGB(255, 140, 0)
	-- activateOnTouch=true on request ("den Button vorziehen und so
	-- einstellen das man darauf stehen muss zu aktivieren") — same reasoning
	-- as the other touch-activated kiosks: this only OPENS the Wheel panel
	-- (see the function's own header comment above), it never spins for
	-- Robux by itself, so walking onto the pad can't accidentally spend
	-- anything.
	--
	-- localZ = -7 (was 0, dead center) on request ("Glücksrad muss noch ein
	-- 2-3 Felder nach vor rutschen ... nur der Trigger, die Plattform bleibt
	-- wo sie ist") — moves ONLY the trigger pad + billboard, towards the
	-- tower (wheelCFrame's LookVector, i.e. negative local Z, points at the
	-- tower — see CFrame.lookAt above), closer to where a player walks in
	-- from. The Platform Part's own Size/CFrame right above is untouched, so
	-- the physical platform (and any manually-placed 3D Spinwheel decoration
	-- standing on it, per the comment above) stays exactly where it was —
	-- only re-position that decoration by hand in Studio too if it needs to
	-- follow the trigger. -7 keeps the 5-stud-wide pad safely inside the
	-- 20-stud platform (10-stud half-width, so up to ~7.5 studs of offset
	-- fits before the pad's own edge would clip past the platform's edge).
	local _, statusLabel, prompt = buildStationPart(
		wheelFolder, wheelCFrame, 0, -7, Color3.fromRGB(220, 80, 200), wheel.Title, wheel.ActionText,
		wheel.EmojiIcon, toAssetIdString(wheel.AssetIdIcon), true, nil, true, orangeTextColor
	)
	statusLabel.Text = "Versuch dein Glück"

	prompt.Triggered:Connect(function(triggeringPlayer)
		if remotesFolder then
			remotesFolder.RequestWheelPanel:FireClient(triggeringPlayer)
		end
	end)
end

-- Builds the single SHARED Fast-Travel kiosk (see GameConfig.FastTravel /
-- FastTravelService.lua) — same "fake plotCFrame on its own small platform"
-- trick as buildWheelKiosk above, same NO requireOwner gate.
-- Same "kiosk just OPENS A PANEL" pattern as the Jump Upgrade/Glücksrad
-- kiosks (not an instant-purchase kiosk like Auto-Sammeln/2x Cash/1x Wiedergeburt) — the
-- panel lists all 4 configured checkpoints with their live Robux price and
-- whether THIS player has reached that floor yet (see UIBuilder.lua's Fast
-- Travel panel), since a single Triggered action can't show that.
local function buildFastTravelKiosk()
	local fastTravel = GameConfig.FastTravel
	local base = GameConfig.Base

	local fastTravelFolder = Instance.new("Folder")
	fastTravelFolder.Name = "FastTravel"
	fastTravelFolder.Parent = Workspace

	local fastTravelCFrame = CFrame.lookAt(fastTravel.Position, Vector3.new(0, fastTravel.Position.Y, 0))

	local platform = Instance.new("Part")
	platform.Name = "Platform"
	platform.Anchored = true
	platform.Size = Vector3.new(20, base.PlotSize.Y, 20)
	platform.Material = Enum.Material.Concrete
	platform.Color = Color3.fromRGB(150, 150, 158)
	platform.CFrame = fastTravelCFrame
	platform.Parent = fastTravelFolder

	local _, _, prompt = buildStationPart(
		fastTravelFolder, fastTravelCFrame, 0, 0, Color3.fromRGB(60, 130, 220), fastTravel.Title, fastTravel.ActionText,
		fastTravel.EmojiIcon, toAssetIdString(fastTravel.AssetIdIcon)
	)
	prompt.Triggered:Connect(function(triggeringPlayer)
		if remotesFolder then
			remotesFolder.RequestFastTravelPanel:FireClient(triggeringPlayer)
		end
	end)
end

-- Builds the single SHARED "Gefällt mir"-Stand (see GameConfig.LikeStation
-- for the full reasoning — no real Roblox Like API exists to hook into, so
-- this is purely a sign + a short popup, no counter). Same "fake plotCFrame
-- on its own small platform" trick as buildWheelKiosk/buildFastTravelKiosk
-- above, at the one diagonal gap (-85,0,-85) that's been empty ground since
-- the old Robux Jump-Upgrade Trader was removed — same NO requireOwner gate
-- (any player, from any base, can use it).
local function buildLikeKiosk()
	local like = GameConfig.LikeStation
	local base = GameConfig.Base

	local likeFolder = Instance.new("Folder")
	likeFolder.Name = "LikeStation"
	likeFolder.Parent = Workspace

	local likeCFrame = CFrame.lookAt(like.Position, Vector3.new(0, like.Position.Y, 0))

	local platform = Instance.new("Part")
	platform.Name = "Platform"
	platform.Anchored = true
	platform.Size = Vector3.new(20, base.PlotSize.Y, 20)
	platform.Material = Enum.Material.Concrete
	platform.Color = Color3.fromRGB(150, 150, 158)
	platform.CFrame = likeCFrame
	platform.Parent = likeFolder

	-- hideIcon=true (text-only, same bigger/colored layout as Glücksrad/2x
	-- Cash/1x Wiedergeburt) + activateOnTouch=true (walking onto the pad
	-- shows the popup immediately, no E/hold needed, same as every other
	-- shared kiosk) + a warm pink textColor of its own, separate from every
	-- other station's color.
	local pinkTextColor = Color3.fromRGB(255, 90, 140)
	local _, statusLabel, prompt = buildStationPart(
		likeFolder, likeCFrame, 0, 0, Color3.fromRGB(255, 90, 140), like.Title, like.ActionText,
		like.EmojiIcon, toAssetIdString(like.AssetIdIcon), true, nil, true, pinkTextColor
	)
	statusLabel.Text = like.HintText

	prompt.Triggered:Connect(function(triggeringPlayer)
		if remotesFolder then
			remotesFolder.Notice:FireClient(triggeringPlayer, like.PopupText)
		end
	end)
end

-- Builds the static ground-floor plots once at server start. The pedestal
-- tiles on top of each plot are built per-player in RefreshBase, since they
-- depend on that player's data (and no player owns a plot yet at this point).
function BaseService.BuildPlots()
	local base = GameConfig.Base

	CreatureModelDisplay.EnsureFolder()

	local basesFolder = Instance.new("Folder")
	basesFolder.Name = "Bases"
	basesFolder.Parent = Workspace

	for plotIndex = 1, base.MaxPlayers do
		local plotFolder = Instance.new("Folder")
		plotFolder.Name = "Plot_" .. plotIndex
		plotFolder.Parent = basesFolder

		local plotCFrame = getPlotCFrame(plotIndex)

		local platform = Instance.new("Part")
		platform.Name = "Platform"
		platform.Anchored = true
		platform.Size = base.PlotSize
		platform.Material = Enum.Material.Concrete
		platform.Color = Color3.fromRGB(150, 150, 158)
		platform.CFrame = plotCFrame
		platform.Parent = plotFolder

		buildStructure(plotFolder, plotCFrame)
		buildStations(plotFolder, plotIndex, plotCFrame)

		plotFolders[plotIndex] = plotFolder
	end

	buildWheelKiosk()
	buildFastTravelKiosk()
	buildLikeKiosk()
end

-- Finds a free plot and assigns it to the player. Returns the plot index,
-- or nil (with a warning) if all plots are already taken.
function BaseService.AssignPlayer(player)
	local base = GameConfig.Base
	for plotIndex = 1, base.MaxPlayers do
		if not plotAssignment[plotIndex] then
			plotAssignment[plotIndex] = player
			playerPlot[player] = plotIndex
			return plotIndex
		end
	end
	warn(
		"[BaseService] No free base plot for "
			.. player.Name
			.. " — raise GameConfig.Base.MaxPlayers and cap Players.MaxPlayers at the same value so this can't happen."
	)
	return nil
end

-- Returns a CFrame just above the player's own base platform, or nil if
-- they don't have a plot (e.g. AssignPlayer failed because all plots were
-- taken). Used for the initial spawn and for the post-claim teleport.
function BaseService.GetSpawnCFrame(player)
	local plotIndex = playerPlot[player]
	if not plotIndex then
		return nil
	end
	local plotFolder = plotFolders[plotIndex]
	if not plotFolder then
		return nil
	end
	local base = GameConfig.Base
	return plotFolder.Platform.CFrame * CFrame.new(0, base.PlotSize.Y / 2 + 4, 0)
end

-- Frees the player's plot and clears its pedestals so the next occupant
-- starts from an empty base.
function BaseService.ReleasePlayer(player)
	local plotIndex = playerPlot[player]
	if not plotIndex then
		return
	end
	plotAssignment[plotIndex] = nil
	playerPlot[player] = nil
	moneyLabels[player] = nil
	creatureModels[player] = nil

	local plotFolder = plotFolders[plotIndex]
	if plotFolder then
		plotFolder.Structure.NameTagAnchor.NameTagGui.Text.Text = "Free Base"
		local pedestals = plotFolder:FindFirstChild("Pedestals")
		if pedestals then
			pedestals:Destroy()
		end
		-- Restore the static ground-floor roof in case it was hidden for a
		-- multi-story base (see RefreshBase) — an empty plot should always
		-- look like a complete 1-story shelter, not a roofless skeleton.
		local staticRoof = plotFolder.Structure:FindFirstChild("Roof")
		if staticRoof then
			staticRoof.Transparency = 0
			staticRoof.CanCollide = true
		end
	end

	-- Reset every kiosk's status label to a neutral placeholder — the
	-- kiosks themselves (built once in buildStations, at server start) stay
	-- exactly where they are for the next occupant; only their text needs
	-- to stop showing the previous owner's numbers until FireDataUpdated
	-- populates them again for whoever claims this plot next.
	local labels = stationLabels[plotIndex]
	if labels then
		for _, label in pairs(labels) do
			if label then
				label.Text = "—"
			end
		end
	end
end

-- Column/row offset (in studs, relative to the floor's own CFrame) for the
-- Nth slot on a single story — walks GameConfig.Base.SlotRowColumns (a fixed
-- "shelf along the back wall" layout, see its comment there) row by row,
-- consuming slotIndexOnFloor until it lands in the row that owns that slot,
-- then looks up that row's Z offset and that slot's column's X offset.
local function slotLocalOffset(slotIndexOnFloor)
	local base = GameConfig.Base
	local remaining = slotIndexOnFloor
	for rowIndex, columns in ipairs(base.SlotRowColumns) do
		if remaining <= #columns then
			local columnIndex = columns[remaining]
			return base.SlotColumnsX[columnIndex], base.SlotRowsZ[rowIndex]
		end
		remaining = remaining - #columns
	end
	-- Fallback: only reachable if SlotsPerFloor is ever raised past the sum
	-- of SlotRowColumns without also extending the layout table — stack any
	-- overflow slots at the plot center rather than erroring outright.
	warn("[BaseService] slotLocalOffset: slot " .. slotIndexOnFloor .. " has no entry in GameConfig.Base.SlotRowColumns — extend that table")
	return 0, 0
end

-- Total pedestal capacity this player currently has — the single source of
-- truth for "how many Brainrots can actually sit in my base right now".
-- CreatureService checks this BEFORE granting a claim (see GivePlayerCreature)
-- so CreatureLog can never grow past what RefreshBase below can actually
-- display, and RefreshBase itself uses the exact same formula for how many
-- pedestals to build — the two can never drift apart.
function BaseService.GetCapacity(player)
	local data = PlayerDataManager.Get(player)
	if not data then
		return 0
	end
	local base = GameConfig.Base
	return base.StartSlots + data.Rebirths * base.SlotsPerRebirth
end

-- Rebuilds this player's pedestals from scratch to match their current
-- capacity (StartSlots + Rebirths * SlotsPerRebirth) and CreatureLog. Safe
-- to call as often as needed (after every claim, every rebirth, and once
-- on join) — it always fully replaces the old "Pedestals" folder, which is
-- also where every dynamic (non-ground-floor) pillar and the roof live, so
-- they're always rebuilt in step with the current floor count.
function BaseService.RefreshBase(player)
	local plotIndex = playerPlot[player]
	if not plotIndex then
		return
	end
	local plotFolder = plotFolders[plotIndex]
	if not plotFolder then
		return
	end
	local data = PlayerDataManager.Get(player)
	if not data then
		return
	end

	local base = GameConfig.Base
	local capacity = BaseService.GetCapacity(player)
	local floorsNeeded = math.max(1, math.ceil(capacity / base.SlotsPerFloor))
	local claimedCount = math.min(#data.CreatureLog, capacity)
	local platformTopY = base.PlotSize.Y / 2

	plotFolder.Structure.NameTagAnchor.NameTagGui.Text.Text = player.Name .. "'s Base (" .. claimedCount .. "/" .. capacity .. ")"

	local oldPedestals = plotFolder:FindFirstChild("Pedestals")
	if oldPedestals then
		oldPedestals:Destroy()
	end

	local pedestalsFolder = Instance.new("Folder")
	pedestalsFolder.Name = "Pedestals"
	pedestalsFolder.Parent = plotFolder

	local plotCFrame = plotFolder.Platform.CFrame

	-- `creatureRates` is the SAME whole-number, minimum-1 per-creature rate
	-- table EconomyService accumulates into PedestalCash every tick (see
	-- EconomyService.GetCreatureCashRates) — used here only for the sell
	-- prompt's price preview now (the money label itself shows the actual
	-- accumulated data.PedestalCash, not a rate — see below).
	local creatureRates = {}
	if EconomyService then
		creatureRates = EconomyService.GetCreatureCashRates(player)
	end

	-- Fresh label map for this rebuild — every pedestal below re-registers
	-- itself here as it's created.
	moneyLabels[player] = {}
	local playerMoneyLabels = moneyLabels[player]

	-- Fresh model map too — every pedestal that gets a real (non-placeholder)
	-- model below registers itself here, so StartFacingLoop can find it.
	creatureModels[player] = {}
	local playerCreatureModels = creatureModels[player]

	for floorNum = 1, floorsNeeded do
		local floorYOffset = base.FloorHeight * (floorNum - 1)
		local floorCFrame = plotCFrame * CFrame.new(0, floorYOffset, 0)

		if floorNum > 1 then
			local floorPlatform = Instance.new("Part")
			floorPlatform.Name = "Floor_" .. floorNum
			floorPlatform.Anchored = true
			floorPlatform.Size = base.PlotSize
			floorPlatform.Material = Enum.Material.Concrete
			floorPlatform.Color = Color3.fromRGB(150, 150, 158)
			floorPlatform.CFrame = floorCFrame
			floorPlatform.Parent = pedestalsFolder

			-- Open connecting pillars between this story and the one right
			-- below it (no mid-building ceiling here — only the roof at the
			-- very top gets one, see below), so the whole tower of stories
			-- reads as one continuous open structure.
			local prevFloorYOffset = base.FloorHeight * (floorNum - 2)
			local connectHeight = base.FloorHeight - base.PlotSize.Y
			local connectCenterY = (prevFloorYOffset + floorYOffset) / 2
			buildCornerPillars(pedestalsFolder, plotCFrame, connectCenterY, connectHeight, "ConnectPillar_" .. floorNum)

			-- Real, walkable staircase up to this story — replaced an
			-- earlier TrussPart (Roblox's native "hold a direction while
			-- touching it" ladder mechanic) because players couldn't
			-- reliably get up it. Plain stacked steps need no special
			-- input: each one is short enough (~2 studs) that a character
			-- just walks straight up them like normal stairs.
			--
			-- FIX (this revision): the staircase used to run INSIDE the
			-- plot's footprint and climb only the open "connectHeight" gap
			-- between the two slabs — which meant the top step landed
			-- exactly against the UNDERSIDE of the solid floorPlatform
			-- above (no hole was ever cut into it), so a player could climb
			-- every step and still not reach the new story. Since the
			-- "walls" here are just open corner pillars (no solid wall
			-- panels), the fix is to build the whole run OUTSIDE the
			-- footprint instead (past base.PlotSize.X/2) — there's no slab
			-- out there at ANY height, so the stairs can climb the FULL
			-- FloorHeight gap, from the lower floor's top surface all the
			-- way to this floor's top surface, with nothing in the way.
			-- Every step is the same width and X position, sized so its
			-- INNER edge sits exactly flush with the platform's edge (see
			-- stepsX/Size.X below) — that keeps the step-on/step-off gap at
			-- zero studs at both the bottom AND the top of the climb, not
			-- just wherever the stairs happened to start. Still centered on
			-- the middle of a side wall (not a corner), clear of every
			-- corner pillar (those only exist at localZ = ±33, far from the
			-- Z range this run spans).
			do
				-- BUG FIX ("die Treppen schließen nicht am Boden ab", dann
				-- "der Sockel muss aber etwas vor schauen man kommt so nicht
				-- die Treppe hinauf") — this whole run sits OUTSIDE the
				-- plot's own footprint (stepsX is past PlotSize.X/2, see the
				-- comment above), where there is NO platform underneath at
				-- any floor level — only the staircase itself. For
				-- floorNum >= 3 that's fine: the previous floor's own
				-- staircase run already climbs up to EXACTLY this run's
				-- climbBottom (floorNum-1's climbTop == floorNum's
				-- climbBottom, since both equal that floor's own FloorHeight
				-- offset), so the runs chain with zero gap. But the very
				-- FIRST run (floorNum == 2, climbing from the ground floor)
				-- has nothing below it — climbBottom there used to be only
				-- the ground floor's own PLATFORM height (base.PlotSize.Y/2),
				-- which the platform itself doesn't reach out to at stepsX
				-- either, so the bottom step floated ~1.5 studs above the
				-- actual grass (GameConfig.Base.GroundTopY) with visible
				-- daylight underneath.
				--
				-- FIRST attempt filled that 1.5-stud gap with a separate
				-- solid "foundation" block directly under Step_1 — but since
				-- it shared Step_1's own footprint (same stepDepth, no
				-- separate tread), it fused into one sheer ~3.4-stud wall
				-- with no ledge to climb up onto from the ground at all.
				-- FIX (this revision): fold the ground-to-climbBottom gap
				-- straight into the step generation itself instead, only for
				-- floorNum == 2 — climbBottom becomes the TRUE ground height,
				-- so the whole run (grass all the way up to Floor_2) is
				-- re-split into the same ~2-stud walkable steps as every
				-- other staircase, one extra step longer than before, with
				-- its own tread sticking out (stepDepth) at ground level like
				-- every other step. No separate riser part needed anymore.
				local groundClimbBottom = (floorNum == 2) and base.GroundTopY or nil
				local climbBottom = groundClimbBottom or (prevFloorYOffset + base.PlotSize.Y / 2) -- top of the floor below (or true ground for the first run)
				local climbTop = floorYOffset + base.PlotSize.Y / 2        -- top of THIS (new) floor
				local totalClimbHeight = climbTop - climbBottom
				local targetStepHeight = 2
				local stepCount = math.max(1, math.ceil(totalClimbHeight / targetStepHeight))
				local actualStepHeight = totalClimbHeight / stepCount
				local stepDepth = 3
				local startZ = -(stepCount * stepDepth) / 2 + stepDepth / 2
				local stepSizeX = 6
				local stepsX = base.PlotSize.X / 2 + stepSizeX / 2 -- inner edge flush with the platform edge

				for stepNum = 1, stepCount do
					local step = Instance.new("Part")
					step.Name = "Stairs_" .. floorNum .. "_Step_" .. stepNum
					step.Anchored = true
					step.Material = Enum.Material.WoodPlanks
					step.Color = Color3.fromRGB(120, 85, 45)
					step.Size = Vector3.new(stepSizeX, actualStepHeight, stepDepth)
					local stepCenterY = climbBottom + actualStepHeight * (stepNum - 0.5)
					local stepZ = startZ + (stepNum - 1) * stepDepth
					step.CFrame = plotCFrame * CFrame.new(stepsX, stepCenterY, stepZ)
					step.Parent = pedestalsFolder
				end
			end

			-- Interior light for this floor (the ground floor's own light
			-- lives permanently in Structure, built once in buildStructure).
			addFloorLight(pedestalsFolder, floorCFrame)
		end

		local slotsOnThisFloor = math.min(base.SlotsPerFloor, capacity - (floorNum - 1) * base.SlotsPerFloor)

		for slotOnFloor = 1, slotsOnThisFloor do
			local globalSlotIndex = (floorNum - 1) * base.SlotsPerFloor + slotOnFloor
			local localX, localZ = slotLocalOffset(slotOnFloor)
			local tileCFrame = floorCFrame * CFrame.new(localX, base.PlotSize.Y / 2 + base.TileSize.Y / 2, localZ)

			local tile = Instance.new("Part")
			tile.Name = "Tile_" .. globalSlotIndex
			tile.Anchored = true
			tile.Size = base.TileSize
			tile.Material = Enum.Material.SmoothPlastic
			tile.Color = Color3.fromRGB(70, 200, 90)
			tile.CFrame = tileCFrame
			tile.Parent = pedestalsFolder

			local creatureName = data.CreatureLog[globalSlotIndex]
			if creatureName then
				local creatureDef
				local rarityName
				for _, def in ipairs(GameConfig.Creatures) do
					if def.Name == creatureName then
						creatureDef = def
						rarityName = def.Rarity
						break
					end
				end
				local rarityDef = rarityName and GameConfig.CreatureRarities[rarityName]
				local displayColor = rarityDef and rarityDef.Color or Color3.new(1, 1, 1)

				-- Every pedestal showing this creature contributes fully —
				-- duplicates are not worth less, see GetCreatureCashRates.
				local cashPerSec = creatureRates[creatureName] or 0
				local accumulated = (data.PedestalCash and data.PedestalCash[globalSlotIndex]) or 0

				-- The round "stand here to collect/sell" platform: Touched,
				-- the sell ProximityPrompt, and the money BillboardGui all
				-- attach to THIS part regardless of whether a real model
				-- shows on the tile behind it, so collection/selling keeps
				-- working identically no matter what the asset's own part
				-- layout looks like.
				--
				-- On request ("die Position des Geld einsammeln ist momentan
				-- direkt auf den Brainrots ... davor ... auf einer runden
				-- Platform") — this used to be a small floating ball offset
				-- only 1.2 studs from the tile's own center (barely off the
				-- creature's own spot, and hidden entirely the moment a real
				-- 3D model loaded — see the removed `display.Transparency =
				-- 1` further below). Now it's a genuinely separate, always-
				-- visible platform: the same "glowing coin" Cylinder-on-its-
				-- side style every other station in the base already uses
				-- (see buildStationPart's own pad), sized the same
				-- (GameConfig.Base.CollectPadSize, 5-stud diameter), sitting
				-- flush with the floor rather than floating above the tile.
				--
				-- Offset toward the carpet (see the "mirror" comment on the
				-- model below — same sign convention: localX > 0 is the
				-- right column, where "toward the carpet" is -X; localX <= 0
				-- is the left column, where it's +X). collectPadOffset (6.5)
				-- = the 8-stud tile's own half-width (4 studs) plus the new
				-- platform's own radius (2.5 studs, see CollectPadSize's
				-- 5-stud diameter) — puts the platform's near edge exactly
				-- at the tile's edge with zero overlap, so it reads as a
				-- clearly separate round platform sitting right in front of
				-- the creature, never cutting into/overlapping its tile.
				local towardCarpetX = (localX > 0) and -1 or 1
				local collectPadOffset = 6.5
				local display = Instance.new("Part")
				display.Name = "Display"
				display.Shape = Enum.PartType.Cylinder
				display.Size = base.CollectPadSize
				display.Anchored = true
				display.CanCollide = false
				display.Material = Enum.Material.Neon
				-- Same "too intense" softening as buildStationPart's pad —
				-- this platform is now permanently visible (rarity-colored),
				-- not just a hidden-once-loaded fallback, so it gets the
				-- same toned-down glow every other station pad already has.
				-- Raised a second time to match buildStationPart's own
				-- second pass (0.2→0.45 Lerp, 0.2→0.35 Transparency).
				display.Color = displayColor:Lerp(Color3.new(1, 1, 1), 0.45)
				display.Transparency = 0.35
				-- Same "lay the Cylinder flat like a coin" rotation as
				-- buildStationPart's own pad (a Cylinder's round faces are
				-- perpendicular to its LOCAL X by default; rotating 90°
				-- around Z swaps local X for local Y/"up"). Positioned off
				-- floorCFrame directly (not tile.CFrame) at the same flush-
				-- with-the-floor height buildStationPart's pads use
				-- (PlotSize.Y / 2 + 0.15) — this platform sits ON THE FLOOR
				-- beside the tile, not elevated on top of it.
				display.CFrame = floorCFrame * CFrame.new(localX + towardCarpetX * collectPadOffset, base.PlotSize.Y / 2 + 0.15, localZ) * CFrame.Angles(0, 0, math.rad(90))
				display.Parent = pedestalsFolder

				-- Real 3D model, if a Model named exactly `creatureName`
				-- exists in ReplicatedStorage.CreatureModels — see
				-- CreatureModelDisplay.Spawn/GetTemplate. No per-creature
				-- flag needed: every creature just tries the lookup; if
				-- nothing's there yet, the tile itself (still colored by
				-- rarity) is the only fallback visual now — the collect
				-- platform (`display`) is never a stand-in for a missing
				-- model anymore, see its own comment above.
				local visualModel, usedPitch, usedRoll, usedYaw
				do
					local tileTopCFrame = tile.CFrame * CFrame.new(0, base.TileSize.Y / 2, 0)

					-- Pedestals sit in two columns flanking the carpet
					-- (localX < 0 = left, > 0 = right) — a model tuned to
					-- face inward from the left needs the MIRROR of that
					-- rotation to also face inward from the right, otherwise
					-- one whole column always faces the wrong way. Negating
					-- the angle mirrors it across the carpet.
					local mirror = (localX > 0) and -1 or 1
					local modelYRotation = (creatureDef and creatureDef.ModelYRotation or 0) * mirror

					-- Pitch/Roll are an UPRIGHT-ness fix, not a facing
					-- direction, so unlike ModelYRotation above they're
					-- never mirrored — a model lying on its side is lying
					-- on its side the same way in both carpet columns.
					local modelPitch = (creatureDef and creatureDef.ModelPitchDegrees) or base.ModelDefaultPitchDegrees
					local modelRoll = (creatureDef and creatureDef.ModelRollDegrees) or base.ModelDefaultRollDegrees

					visualModel, usedPitch, usedRoll, usedYaw = CreatureModelDisplay.Spawn(
						creatureName,
						tileTopCFrame,
						base.CreatureModelHeight,
						modelYRotation,
						modelPitch,
						modelRoll,
						globalSlotIndex
					)
					if visualModel then
						-- Unlike before, `display` is NOT hidden here anymore —
						-- it's a genuinely separate collect/sell platform now
						-- (see its own long comment above), not a fallback
						-- stand-in for a missing model, so it stays visible
						-- alongside the real model regardless.
						visualModel.Parent = pedestalsFolder

						-- "Die Drehung funktioniert nicht richtig" — a static,
						-- once-baked yaw can only ever look right from one
						-- spot. Replaced with a live look-at: capture this
						-- model's rigid pose now (usedPitch/usedRoll/usedYaw —
						-- NOT modelPitch/modelRoll/modelYRotation — since
						-- those are the ACTUAL values Spawn just rotated the
						-- model to, which can differ from what was requested
						-- while a "/pitch" or "/yaw" debug override/cycle is
						-- active; referenceLookAtWorld is the point straight
						-- across the carpet that pose faces — see
						-- CreatureModelDisplay's own comment on
						-- CaptureRigidPose for why that's enough to calibrate
						-- ANY future look-at target), then register it so
						-- StartFacingLoop can keep turning it to face the
						-- plot's owner every tick.
						local referenceLookAtWorld = (plotCFrame * CFrame.new(0, 0, localZ)).Position
						CreatureModelDisplay.CaptureRigidPose(
							visualModel,
							tileTopCFrame.Position,
							tileTopCFrame,
							usedPitch,
							usedRoll,
							usedYaw,
							referenceLookAtWorld,
							mirror
						)
						playerCreatureModels[globalSlotIndex] = visualModel
					else
						-- No real model available for this creature (missing
						-- or failed to load) — tint the tile itself by
						-- rarity color instead of leaving it the default
						-- green, so there's still SOME visual telling you
						-- what's here, same purpose the old placeholder ball
						-- used to serve before it became a permanent,
						-- separate collect platform (see `display`'s own
						-- comment above) that no longer sits on the
						-- creature's own tile at all.
						tile.Color = displayColor
					end
				end

				local nameTag = Instance.new("BillboardGui")
				nameTag.Name = "NameTag"
				-- Taller than before (96 -> 124) to fit a 4th row: the
				-- rarity tier ("Diamond", "Lava", ...) sits at the very top
				-- now — it used to only be implied by the name's text color,
				-- which wasn't legible enough to actually tell tiers apart
				-- at a glance ("man sieht die Rarity Stufe in der Base
				-- nicht").
				nameTag.Size = UDim2.new(0, 170, 0, 124)
				nameTag.StudsOffset = Vector3.new(0, 2, 0)
				nameTag.AlwaysOnTop = true
				-- "man sieht die Namen der Brainrots auf der Karte, damit es
				-- nicht so offensichtlich ist wo ein Gutes Brainrot steht"
				-- — no MaxDistance meant this (and AlwaysOnTop, which draws
				-- straight through walls/other pedestals too) was readable
				-- from basically anywhere, spoiling which base/pedestal has
				-- something good before you've even walked over. Went
				-- 40 -> 15 -> 22 while tuning this from code, then set
				-- straight to 40 in Studio directly — matching that here.
				-- Purely visual: the Touched-based collection/sell hitbox
				-- below is completely unaffected by this.
				nameTag.MaxDistance = 40
				nameTag.Parent = display

				-- Order top-to-bottom is Name -> Rate -> Rarity -> Money (on
				-- request): the name is the first thing you read, then how
				-- fast it earns, then which tier it's from, with the
				-- collected-money total staying at the very bottom same as
				-- always.
				local nameLabel = Instance.new("TextLabel")
				nameLabel.Name = "Text"
				nameLabel.Size = UDim2.new(1, 0, 0.27, 0)
				nameLabel.Position = UDim2.new(0, 0, 0, 0)
				nameLabel.BackgroundTransparency = 1
				-- While a "/pitch" and/or "/yaw" preview (single override OR
				-- cycle) is active, show exactly which value(s) THIS
				-- pedestal is currently using — makes a "cycle" screenshot
				-- self-explanatory (no need to remember which slot got
				-- which candidate) and confirms a plain override really did
				-- reach this pedestal.
				local debugSuffix = ""
				if CreatureModelDisplay.IsDebugActive() and usedPitch then
					debugSuffix = debugSuffix .. " [P" .. usedPitch .. "/R" .. usedRoll .. "]"
				end
				if CreatureModelDisplay.IsYawDebugActive() and usedYaw then
					debugSuffix = debugSuffix .. " [Y" .. usedYaw .. "]"
				end
				nameLabel.Text = creatureName .. debugSuffix
				nameLabel.TextColor3 = displayColor
				nameLabel.TextStrokeTransparency = 0.4
				nameLabel.TextScaled = true
				nameLabel.Font = Enum.Font.GothamBold
				nameLabel.Parent = nameTag

				-- Rate label ("+X/s") — how fast this Brainrot is EARNING
				-- right now (same whole-number rate GetCreatureCashRates
				-- computes for the sell-price preview below). Purely
				-- informational — it doesn't move Cash by itself, the
				-- MoneyText total underneath does that; this just tells you
				-- how quickly that total is currently growing. Styled the
				-- same white GothamBold as the HUD's own Cash/Upgrade numbers.
				local rateLabel = Instance.new("TextLabel")
				rateLabel.Name = "RateText"
				rateLabel.Size = UDim2.new(1, 0, 0.24, 0)
				rateLabel.Position = UDim2.new(0, 0, 0.27, 0)
				rateLabel.BackgroundTransparency = 1
				rateLabel.TextScaled = true
				rateLabel.TextStrokeTransparency = 0.3
				rateLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
				rateLabel.Text = "+$" .. formatCashRate(cashPerSec) .. "/s"
				rateLabel.TextColor3 = Color3.new(1, 1, 1)
				rateLabel.Font = Enum.Font.GothamBold
				rateLabel.Parent = nameTag

				-- Rarity label — the tier name itself, spelled out, colored
				-- (and stroked) with the same rarity Color as everything else
				-- on this pedestal, so it doubles as a legend for what that
				-- color means the very first time you see it.
				local rarityLabel = Instance.new("TextLabel")
				rarityLabel.Name = "RarityText"
				rarityLabel.Size = UDim2.new(1, 0, 0.22, 0)
				rarityLabel.Position = UDim2.new(0, 0, 0.51, 0)
				rarityLabel.BackgroundTransparency = 1
				rarityLabel.TextScaled = true
				rarityLabel.TextStrokeTransparency = 0.2
				rarityLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
				rarityLabel.Text = rarityName or "?"
				rarityLabel.TextColor3 = displayColor
				rarityLabel.Font = Enum.Font.GothamBold
				rarityLabel.Parent = nameTag

				-- Money label — like "Steal a Brainrot": this Brainrot's
				-- earnings pile up HERE (data.PedestalCash[globalSlotIndex],
				-- ticked by EconomyService.StartPassiveIncomeLoop) instead of
				-- flowing straight into Cash. Walking over the Display below
				-- collects it (see the Touched connection further down).
				-- Styled to match the HUD's own Cash/Upgrade numbers (white
				-- GothamBold, see UIBuilder.lua) so it reads as the same kind
				-- of number as "75/100 Cash" right above it.
				local moneyLabel = Instance.new("TextLabel")
				moneyLabel.Name = "MoneyText"
				moneyLabel.Size = UDim2.new(1, 0, 0.27, 0)
				moneyLabel.Position = UDim2.new(0, 0, 0.73, 0)
				moneyLabel.BackgroundTransparency = 1
				moneyLabel.TextScaled = true
				moneyLabel.TextStrokeTransparency = 0.3
				moneyLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
				moneyLabel.Text = "$" .. formatCashRate(accumulated)
				moneyLabel.TextColor3 = Color3.new(1, 1, 1)
				moneyLabel.Font = Enum.Font.GothamBold
				moneyLabel.Parent = nameTag

				-- Popping flag prevents EconomyService's per-second
				-- UpdateMoneyDisplay tick from stomping the "+$X!" pop text
				-- below while it's still showing (task.delay(0.6, ...) below
				-- clears it again) — without this, a tick landing mid-pop
				-- would silently replace "+$50!" with the new (already-zero)
				-- running total before the player even saw it.
				local labelState = { Label = moneyLabel, Popping = false }
				playerMoneyLabels[globalSlotIndex] = labelState

				-- NOTE: pedestals used to slowly spin (both the placeholder
				-- ball and any real model) — removed on request. The model
				-- is still placed once, standing still, by
				-- CreatureModelDisplay.Spawn above.

				-- Walk into the Display to collect whatever this pedestal has
				-- earned so far. Idempotent by nature — Touched can fire many
				-- times while standing on it, but PedestalCash is already 0
				-- after the first collect, so extra fires are harmless. Only
				-- the plot's OWNER can collect (matches the sell prompt below).
				display.Touched:Connect(function(hit)
					local character = hit.Parent
					local hitPlayer = character and Players:GetPlayerFromCharacter(character)
					if hitPlayer ~= player then
						return
					end

					local playerData = PlayerDataManager.Get(player)
					if not playerData or not playerData.PedestalCash then
						return
					end

					local collected = playerData.PedestalCash[globalSlotIndex] or 0
					if collected <= 0 then
						return
					end

					playerData.Cash += collected
					-- Lifetime total for the global Hall of Fame's "Top
					-- Gesamt-Cash" ranking (see PlayerDataManager's
					-- LifetimeCashEarned comment and LeaderboardService.lua)
					-- — grows by the exact same amount as Cash here, but is
					-- never reduced by anything, unlike Cash itself.
					playerData.LifetimeCashEarned = (playerData.LifetimeCashEarned or 0) + collected
					playerData.PedestalCash[globalSlotIndex] = 0

					if EconomyService then
						EconomyService.FireDataUpdated(player)
					end

					-- "beim Sammeln von Geld ist es nicht live" — pedestal
					-- collection can fire far more often than a Rebirth or a
					-- sale (every payout tick, on every pedestal, for up to 4
					-- players), so unlike EconomyService.Rebirth/CreatureService.
					-- SellCreature this does NOT call RequestImmediateRefresh
					-- directly — NotifyCashCollected applies its OWN per-player
					-- cooldown first (see LeaderboardService.lua), so even a
					-- player farming every pedestal in their base at once can
					-- only push a real DataStore write at most once every few
					-- seconds, not once per Touched fire.
					if LeaderboardService then
						LeaderboardService.NotifyCashCollected(player)
					end

					-- Quick "+$X!" pop right on the label, then back to
					-- showing the (now zero, growing again) pedestal total.
					labelState.Popping = true
					moneyLabel.Text = "+$" .. formatCashRate(collected) .. "!"
					moneyLabel.TextColor3 = Color3.fromRGB(120, 255, 140)
					task.delay(0.6, function()
						if moneyLabel.Parent then
							moneyLabel.Text = "$" .. formatCashRate(playerData.PedestalCash[globalSlotIndex] or 0)
							moneyLabel.TextColor3 = Color3.new(1, 1, 1)
						end
						labelState.Popping = false
					end)
				end)

				-- Sell prompt — hold-to-interact, standard Roblox affordance
				-- (works with mouse, touch, and gamepad automatically). Only
				-- the plot's OWNER can trigger it; capture `player` and
				-- `globalSlotIndex` from this closure so the handler always
				-- relays the confirm for the exact pedestal it's attached to,
				-- even after later RefreshBase calls replace this whole
				-- Pedestals folder.
				--
				-- On request ("das nachgefragt wird ob du es verkaufen
				-- willst") — Triggered no longer sells immediately. It only
				-- asks the client to show a Yes/No confirmation dialog (see
				-- init.client.lua's RequestSellConfirm listener +
				-- UIBuilder.ShowSellConfirm); the actual sale still only
				-- happens through CreatureService.SellCreature, via the new
				-- ConfirmSellCreature RemoteFunction, once the player
				-- actually clicks "Yes" — same "ask first, commit later"
				-- split as the Rebirth altar above.
				local sellValue = cashPerSec * GameConfig.Economy.SellValueSeconds
				local sellPrompt = Instance.new("ProximityPrompt")
				sellPrompt.Name = "SellPrompt"
				sellPrompt.ActionText = "Verkaufen (+" .. formatCashRate(sellValue) .. ")"
				sellPrompt.ObjectText = creatureName
				sellPrompt.HoldDuration = 0.5
				-- Was 10 — with rows only SlotRowsZ apart (9 studs), a 10-stud
				-- radius meant almost the ENTIRE row was in range of two (or
				-- even three) pedestals' prompts at once: exactly the
				-- "dozen overlapping ProximityPrompt bubbles + BillboardGuis"
				-- clutter seen in a base with several claimed creatures
				-- ("Maus bleibt stehen, wenn ich mit der Maus darüber
				-- fahre" — several simultaneous prompt UIs stacked on each
				-- other under the cursor). 6 keeps a comfortable trigger
				-- radius around each individual pedestal (still well inside
				-- reach from the tile itself, even from a far corner — see
				-- the display's carpet-ward offset above) while only rarely
				-- overlapping the next one over.
				-- Testweise +5 auf Wunsch (11 statt 6) — liegt jetzt wieder
				-- ÜBER dem 9-Stud-Row-Abstand, adjazente Pedestal-Ringe
				-- können sich also wieder gleichzeitig zeigen. Das alte
				-- "Maus bleibt stehen"-Problem kann dadurch nicht mehr
				-- zurückkommen (das hing an Robloxs Default-Style-GUI, nicht
				-- an der Distanz), höchstens optische Häufung mehrerer Ringe
				-- nebeneinander — falls das stört, einfach wieder runter auf
				-- 6-8 setzen.
				sellPrompt.MaxActivationDistance = 11
				sellPrompt.RequiresLineOfSight = false
				-- Custom statt Default: kein rechteckiges Prompt-Kästchen mehr
				-- (siehe CustomPromptUI.client.lua) — behebt außerdem endgültig
				-- das oben beschriebene "Maus bleibt stehen"-Kamera-Problem,
				-- das GuiNavigationEnabled=false allein nicht gelöst hat, weil
				-- es an Robloxs eigener Default-Style-Prompt-GUI selbst hängt.
				sellPrompt.Style = Enum.ProximityPromptStyle.Custom
				sellPrompt.Parent = display

				sellPrompt.Triggered:Connect(function(triggeringPlayer)
					if triggeringPlayer ~= player then
						return
					end
					-- `sellValue` here is only an ESTIMATE for the dialog's
					-- text — it doesn't include any uncollected PedestalCash
					-- currently sitting on this pedestal, unlike
					-- CreatureService.SellCreature's own calculation, which
					-- includes it. The player will typically end up with the
					-- same or a slightly HIGHER amount than shown, never
					-- less.
					if remotesFolder then
						remotesFolder.RequestSellConfirm:FireClient(triggeringPlayer, {
							SlotIndex = globalSlotIndex,
							Name = creatureName,
							Value = sellValue,
						})
					end
				end)
			end
		end
	end

	-- The static ground-floor roof (built once in buildStructure, always
	-- present by default — see its comment) is correct as-is for a 1-story
	-- base. Only once a 2nd+ story is needed do we hide it and build a new
	-- one above the actual top floor instead — otherwise the ground roof
	-- would sit in mid-air between stories and block the climb (the bug
	-- from before). ReleasePlayer restores it when the player leaves.
	local staticRoof = plotFolder.Structure:FindFirstChild("Roof")
	if floorsNeeded > 1 then
		if staticRoof then
			staticRoof.Transparency = 1
			staticRoof.CanCollide = false
		end

		local topFloorYOffset = base.FloorHeight * (floorsNeeded - 1)
		local topFloorCFrame = plotCFrame * CFrame.new(0, topFloorYOffset, 0)
		local topPillarY = platformTopY + base.WallHeight / 2
		buildCornerPillars(pedestalsFolder, topFloorCFrame, topPillarY, base.WallHeight, "TopPillar")
		buildRoof(pedestalsFolder, topFloorCFrame, platformTopY, base.WallHeight)
	elseif staticRoof then
		staticRoof.Transparency = 0
		staticRoof.CanCollide = true
	end
end

-- Keeps every pedestal's real 3D creature model turned to face its OWNER
-- (on request — a static baked-in yaw only ever looked right from one
-- angle). Ticks on its own timer (not every RunService.Heartbeat frame —
-- there's no need for that for a base decoration, and this stays cheap
-- enough at a few times a second even with all MaxPlayers=4 bases full).
-- Only bothers with a player who actually has a plot AND a character right
-- now (no point turning creatures to face someone who isn't there to see
-- it); CreatureModelDisplay.RotateToFace itself is a no-op for any model
-- that was never CaptureRigidPose'd (still the fallback ball) or has
-- already been destroyed by a RefreshBase rebuild since the last tick.
function BaseService.StartFacingLoop()
	task.spawn(function()
		while true do
			task.wait(0.15)
			for player in pairs(playerPlot) do
				local character = player.Character
				local rootPart = character and character:FindFirstChild("HumanoidRootPart")
				local models = creatureModels[player]
				if rootPart and models then
					local lookAt = rootPart.Position
					for _, model in pairs(models) do
						CreatureModelDisplay.RotateToFace(model, lookAt)
					end
				end
			end
		end
	end)
end

-- Called every PayoutTickSeconds by EconomyService.StartPassiveIncomeLoop
-- after it accumulates that tick's earnings into data.PedestalCash. Cheap on
-- purpose: just updates existing TextLabels' .Text from the (already-built)
-- moneyLabels[player] map — no parts are created, destroyed, or moved, so
-- this is safe to call once a second per player without any base flicker,
-- rotation restart, or ProximityPrompt reset.
function BaseService.UpdateMoneyDisplay(player)
	local playerMoneyLabels = moneyLabels[player]
	if not playerMoneyLabels then
		return
	end
	local data = PlayerDataManager.Get(player)
	if not data or not data.PedestalCash then
		return
	end

	for globalSlotIndex, labelState in pairs(playerMoneyLabels) do
		-- Skip a label that's mid-"+$X!" pop (see the Touched handler above)
		-- so the tick doesn't erase that feedback before the player reads it.
		if not labelState.Popping and labelState.Label.Parent then
			labelState.Label.Text = "$" .. formatCashRate(data.PedestalCash[globalSlotIndex] or 0)
		end
	end
end

-- "Nur [Robux icon][price]" — on request, matching the reference
-- screenshots' style exactly — for every Robux-priced kiosk's status label
-- (2x Cash, Auto-Sammeln, 1x Wiedergeburt). \u{E002} is Roblox's own
-- built-in Robux icon character — only usable from a script (Studio's
-- property panel can't type it), which is exactly what this is. `cost` is
-- the DISPLAYED price only — the real, charged price is whatever is
-- actually set on the Game Pass/Developer Product in Studio, so keep them
-- in sync (see each GameConfig RobuxCost field's own comment).
local function formatRobuxPrice(cost)
	return "Nur \u{E002}" .. cost
end

-- Cheap per-call refresh of a player's own 5 kiosk status labels — same
-- "just update existing TextLabels' .Text" pattern as UpdateMoneyDisplay
-- above, no parts touched. Hooked into EconomyService.FireDataUpdated (see
-- EconomyService.lua), which is already the single funnel-point every
-- Cash/Tier/Rebirth-affecting action calls (BuyJumpUpgrade, Rebirth,
-- the Auto-Sammeln gamepass's auto-collect tick, claiming/selling a
-- creature) — so every one of those already keeps these labels fresh with
-- no extra plumbing needed at each call site.
function BaseService.UpdateStationLabels(player)
	local plotIndex = playerPlot[player]
	if not plotIndex then
		return
	end
	local labels = stationLabels[plotIndex]
	if not labels then
		return
	end
	local data = PlayerDataManager.Get(player)
	if not data then
		return
	end

	if labels.Upgrade then
		local jumpState = EconomyService.GetJumpUpgradeState(player)
		if jumpState and jumpState.JumpPoints < jumpState.MaxJumpPoints then
			-- Zeigt die Sprungkraft (JumpPower/MaxJumpPower) statt der rohen
			-- Sprung-Punkte — gleiche Umstellung wie UIBuilder.
			-- PopulateJumpUpgrade, siehe dessen Kommentar. Die "fertig
			-- gekauft?"-Prüfung bleibt an JumpPoints hängen (die tatsächliche
			-- Kauf-Grenze), nur die angezeigte Zahl ändert sich.
			local jumpPower = math.floor(jumpState.JumpPower + 0.5)
			local maxJumpPower = math.floor(jumpState.MaxJumpPower + 0.5)
			labels.Upgrade.Text = jumpPower .. " / " .. maxJumpPower .. " Sprungkraft"
		else
			labels.Upgrade.Text = "MAX SPRUNG"
		end
	end

	if labels.Rebirth then
		local nextCost = GameConfig.Rebirth.Costs[data.Rebirths + 1]
		if nextCost then
			labels.Rebirth.Text = "$" .. formatCashRate(nextCost) .. " (Stufe " .. (data.Rebirths + 1) .. ")"
		else
			labels.Rebirth.Text = "MAX STUFE (" .. GameConfig.Rebirth.MaxRebirths .. ")"
		end
	end

	-- "4x Cash" upgrade (on request): unlike a plain one-shot purchase, this
	-- one needs an owned-check — the label (and, in the Triggered handler
	-- above, the actual purchase prompt) switches through 3 states as the
	-- player progresses: not owned yet -> "2x Cash" price, owns DoubleCash
	-- only -> the QuadCash upgrade's price, owns QuadCash -> a plain
	-- "aktiv" confirmation with nothing left to buy. See GameConfig.
	-- Gamepasses.QuadCash's own comment for the full design.
	if labels.DoubleCash then
		local ownsQuadCash = MonetizationService and MonetizationService.OwnsQuadCash(player)
		local ownsDoubleCash = MonetizationService and MonetizationService.OwnsDoubleCash(player)
		if ownsQuadCash then
			labels.DoubleCash.Text = "4x Cash aktiv ✓"
		elseif ownsDoubleCash then
			labels.DoubleCash.Text = "Upgrade 4x: " .. formatRobuxPrice(GameConfig.Gamepasses.QuadCash.RobuxCost)
		else
			labels.DoubleCash.Text = formatRobuxPrice(GameConfig.Gamepasses.DoubleCash.RobuxCost)
		end
	end
	-- Owned-check added (on request, "nicht ersichtlich das man das erworben
	-- hat") — was always just formatRobuxPrice(...) no matter what, so a
	-- player who'd already bought it saw the exact same "Nur [price]" text
	-- forever, with nothing telling them it was already active. Same 2-state
	-- shape as the simpler kiosks (not owned -> price, owned -> "aktiv"),
	-- just without DoubleCash's extra middle upgrade-tier state.
	if labels.AutoCollect then
		local ownsAutoCollect = MonetizationService and MonetizationService.OwnsAutoCollect(player)
		if ownsAutoCollect then
			labels.AutoCollect.Text = "Aktiv ✓"
		else
			labels.AutoCollect.Text = formatRobuxPrice(GameConfig.Gamepasses.AutoCollect.RobuxCost)
		end
	end
	if labels.RebirthRobux then
		-- Same MaxRebirths check as the Triggered handler above (and the same
		-- "MAX STUFE" text the normal Cash-Rebirth label already used) — this
		-- label used to always show the Robux price no matter what, even once
		-- there was nothing left to buy.
		if data.Rebirths >= GameConfig.Rebirth.MaxRebirths then
			labels.RebirthRobux.Text = "MAX STUFE (" .. GameConfig.Rebirth.MaxRebirths .. ")"
		else
			labels.RebirthRobux.Text = formatRobuxPrice(GameConfig.Rebirth.RobuxProduct.RobuxCost)
		end
	end
end

return BaseService
