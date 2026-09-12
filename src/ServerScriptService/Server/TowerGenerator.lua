--[[
	TowerGenerator.lua
	Procedurally builds the entire climbing tower at server start — no manual
	part-placement in Studio needed. Also wires up floor-reached detectors,
	respawn checkpoints, creature pickup spawns, and the route-variety
	obstacles (jump pads, ladders, bridges, hazards) from GameConfig.Obstacles.
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local CreatureModelDisplay = require(script.Parent.CreatureModelDisplay)

local TowerGenerator = {}

-- [floorNumber] = the checkpoint Part built for that floor (Floor 1's real
-- SpawnLocation, or the plain Part every later i % 5 == 0 floor gets) —
-- populated during Build() below, read by GetCheckpointCFrame for
-- FastTravelService.lua's paid teleport (GameConfig.FastTravel.Checkpoints
-- only ever targets floors that ARE checkpoint floors, so every lookup this
-- ever does is expected to hit).
local checkpointPartsByFloor = {}

-- Used by FastTravelService.Teleport — returns (CFrame, Part) for a given
-- checkpoint floor, or nil if that floor was never built/tracked as a
-- checkpoint (shouldn't happen for GameConfig.FastTravel's configured
-- floors, but a nil here just means the teleport silently does nothing
-- rather than erroring). Lifted a few studs above the checkpoint's own
-- surface so the player doesn't land embedded in it.
function TowerGenerator.GetCheckpointCFrame(floorNumber)
	local part = checkpointPartsByFloor[floorNumber]
	if not part then
		return nil
	end
	return part.CFrame * CFrame.new(0, 3, 0), part
end

-- [floorNumber] = that floor's platform Part — EVERY floor, not just
-- checkpoints (unlike checkpointPartsByFloor above). Populated during
-- Build() below. Used by AdminAbuseService.lua to scatter its timed
-- "Glücks-Truhen" across random floors during a "/adminabuse" window.
local allFloorPlatforms = {}

-- Returns a random floor's platform Part, or nil if the tower hasn't been
-- built yet (shouldn't happen — AdminAbuseService only ever runs after
-- TowerGenerator.Build has already populated this during server start).
function TowerGenerator.GetRandomFloorPlatform()
	local count = #allFloorPlatforms
	if count == 0 then
		return nil
	end
	return allFloorPlatforms[math.random(1, count)]
end

-- === Mega-Truhe model (optional real 3D asset instead of the plain gold
-- Part) ==========================================================================
-- Same "drop it in Studio by hand, never InsertService:LoadAsset an ID at
-- runtime" convention as CreatureModelDisplay.GetTemplate (see its own long
-- comment for why: loading another creator's Toolbox/Creator Store asset by
-- ID at runtime kept failing in this project with "User is not authorized
-- to access Asset", even for the user's own inserted copy — a model that's
-- already sitting in the place needs no such runtime permission check at
-- all). On request: replace the Mega-Truhe's plain gold Part with a real
-- chest asset (Asset Id 11302807028) —
--   1. Toolbox (or the Creator Store) -> paste that ID into the search bar
--      -> Insert into the place
--   2. Rename the inserted instance to exactly "Chest" (whatever it came in
--      as — a Model if the asset is a rig of several parts, OR a single
--      MeshPart/Part/UnionOperation if it's one simple prop; Insert-by-ID
--      commonly gives you a bare MeshPart for something this simple, and
--      that's handled below just as well as a full Model, no manual
--      "group it into a Model yourself" step needed)
--   3. Drag it into ReplicatedStorage.SummitAssets (EnsureSummitAssetsFolder
--      below creates that empty Folder for you at server start if it's not
--      there yet — just drop it inside)
-- Missing, or something that's neither a Model nor a BasePart, silently
-- falls back to the original gold Part (see the isSummitFloor block in
-- Build below) — nothing breaks if you haven't done this yet, or the
-- name's wrong.
local summitChestTemplateCache -- only a HIT is cached (a miss isn't), so dropping the asset in mid-session is picked up on the next server start without needing a code change

function TowerGenerator.EnsureSummitAssetsFolder()
	if not ReplicatedStorage:FindFirstChild("SummitAssets") then
		local folder = Instance.new("Folder")
		folder.Name = "SummitAssets"
		folder.Parent = ReplicatedStorage
	end
end

local function getSummitChestTemplate()
	if summitChestTemplateCache then
		return summitChestTemplateCache
	end

	local folder = ReplicatedStorage:FindFirstChild("SummitAssets")
	local template = folder and folder:FindFirstChild("Chest")
	if not template then
		return nil
	end
	if not (template:IsA("Model") or template:IsA("BasePart")) then
		warn(
			"[TowerGenerator] ReplicatedStorage.SummitAssets.Chest exists but is neither a Model nor a"
				.. " BasePart (it's a "
				.. template.ClassName
				.. ") — falling back to the placeholder gold Part"
		)
		return nil
	end

	summitChestTemplateCache = template
	return template
end

local ZONE_COLORS = {
	Color3.fromRGB(60, 179, 113),  -- zone 1: sewer green
	Color3.fromRGB(70, 130, 220),  -- zone 2: city blue
	Color3.fromRGB(255, 165, 0),   -- zone 3: sky orange
	Color3.fromRGB(148, 0, 211),   -- zone 4: space purple
	Color3.fromRGB(220, 20, 60),   -- zone 5: brainrot-core red
	Color3.fromRGB(255, 215, 0),   -- zone 6+: gold (loops for any extra zones)
}

local function getZoneColor(floorIndex)
	local zoneSize = GameConfig.Floors.ZoneSize
	local zoneIndex = math.floor((floorIndex - 1) / zoneSize) + 1
	return ZONE_COLORS[((zoneIndex - 1) % #ZONE_COLORS) + 1]
end

-- Each floor's vertical gap comes directly from the "Gap" field on the
-- JumpTiers entry expected to be active for that stretch of floors (hand
-- tuned in GameConfig.lua — see the comment there for how to retune it).
--
-- bandSize is FIXED at 6 (the original 60 floors / 10 tiers), not
-- recomputed from GameConfig.Floors.Count anymore — Count now goes up to
-- 100 (extended on request), but recomputing this from Count would shift
-- EVERY tier boundary below Floor 60 too (e.g. bandSize would become 10,
-- so Floor 7 — already-tuned as Tier 2 — would suddenly become Tier 1
-- again), silently re-tuning the difficulty of floors that were already
-- playtested. Floors past Tier 10's band (55+) stay on Tier 10's base Gap
-- (102) UNTIL LateHeightBoostStartFloor, then climb further — see
-- GameConfig.Floors' LateHeightBoostStartFloor/LateHeightBoostMaxExtraGap
-- comment for the physics behind that number. getHorizontalOffsetForFloor
-- right below does the same thing for horizontal distance, starting
-- earlier (Floor 50) — together they're what keeps Floor 50-100 getting
-- harder at all, since the JumpTiers band system alone plateaus at 55.
--
-- Floor 101-120 (the Prestige-Turm, floorIndex > floors.Count) is a
-- SEPARATE branch below, reading GameConfig.PrestigeJumpTiers (Tier 11-20)
-- instead of GameConfig.JumpTiers — deliberately NOT folded into the band
-- logic above, because that would either (a) overlap with the
-- LateHeightBoost ramp that already pushes Floor 90-100 up toward its own
-- peak (362 studs), double-counting difficulty and silently re-tuning
-- already-playtested floors, or (b) require recomputing bandSize globally,
-- which has exactly the same "shifts every earlier tier boundary" problem
-- called out above. The new branch uses its own fixed prestigeBandSize (2
-- floors per new tier — 10 tiers * 2 = 20 floors) and does NOT re-apply
-- LateHeightBoost, since PrestigeJumpTiers' own escalating Gap values
-- already encode Floor 101-120's difficulty ramp on their own. Gap values
-- there deliberately START at 380 — above Floor 100's actual peak Gap of
-- 362 (102 + LateHeightBoostMaxExtraGap 260) — so Floor 101 doesn't
-- regress to being easier than Floor 100 already was.
local function getGapForFloor(floorIndex)
	if floorIndex <= 1 then
		return 0
	end
	local floors = GameConfig.Floors

	if floorIndex > floors.Count then
		local prestigeTiers = GameConfig.PrestigeJumpTiers
		local prestigeBandSize = 2
		local prestigeFloorIndex = floorIndex - floors.Count
		local band = math.min(math.ceil(prestigeFloorIndex / prestigeBandSize), #prestigeTiers)
		return prestigeTiers[band].Gap
	end

	local tiers = GameConfig.JumpTiers
	local bandSize = 6
	local band = math.min(math.ceil(floorIndex / bandSize), #tiers)
	local gap = tiers[band].Gap

	if floorIndex > floors.LateHeightBoostStartFloor then
		local span = math.max(floors.Count - floors.LateHeightBoostStartFloor, 1)
		local t = math.clamp((floorIndex - floors.LateHeightBoostStartFloor) / span, 0, 1)
		gap += t * floors.LateHeightBoostMaxExtraGap
	end

	return gap
end

-- Floors 1-6 (the same Tier-1 band as getGapForFloor above) use
-- GameConfig.Floors.EarlyHorizontalOffset instead of the normal
-- HorizontalOffset — a smaller sideways jump specifically for the very
-- first climb, see the comment on EarlyHorizontalOffset in GameConfig.lua.
-- bandSize is fixed at 6 for the same reason as getGapForFloor above.
local function getHorizontalOffsetForFloor(floorIndex)
	local floors = GameConfig.Floors
	local tiers = GameConfig.JumpTiers
	local bandSize = 6
	local band = math.min(math.ceil(math.max(floorIndex, 1) / bandSize), #tiers)
	local baseOffset
	if band <= 1 then
		baseOffset = floors.EarlyHorizontalOffset
	else
		baseOffset = floors.HorizontalOffset
	end

	-- Late-game horizontal spread ("ab Floor 50 ... auch weiter springen")
	-- — see GameConfig.Floors' LateSpreadStartFloor/LateSpreadMaxExtraOffset
	-- comment. Ramps linearly from +0 extra studs at LateSpreadStartFloor
	-- up to +LateSpreadMaxExtraOffset at the very last floor, ON TOP of the
	-- normal offset above — independent of, and in addition to, the
	-- vertical Gap plateauing at Tier 10.
	if floorIndex > floors.LateSpreadStartFloor then
		local span = math.max(floors.Count - floors.LateSpreadStartFloor, 1)
		local t = math.clamp((floorIndex - floors.LateSpreadStartFloor) / span, 0, 1)
		baseOffset += t * floors.LateSpreadMaxExtraOffset
	end

	-- Prestige-Turm (Floor > floors.Count, see GameConfig.Prestige) — flat
	-- extra distance ON TOP of the normal late-game plateau above (which by
	-- itself stops growing past Floor 100). Originally this was meant to be
	-- crossable via a dedicated WalkSpeed upgrade (the removed Tempo-Schuhe
	-- system) rather than a taller jump — on request: "das man nicht
	-- unbedingt höher Springen muss sondern weiter". That system didn't work
	-- out and was replaced by the extended/more-expensive jump-height system
	-- instead (see GameConfig.PrestigeJumpTiers / getGapForFloor above), but
	-- this extra horizontal distance is KEPT on top of it per explicit
	-- request — Floor 101-120 is now BOTH wider (this offset) AND taller
	-- (the new Tier 11-20 Gap values), crossable via the new tiers'
	-- correspondingly higher JumpPower. Flat (not ramped) across all 20
	-- Prestige floors — first pass, please playtest.
	if floorIndex > floors.Count then
		baseOffset += GameConfig.Prestige.ExtraHorizontalOffset
	end

	return baseOffset
end

-- 1.0 at Floor 1, shrinking down to Floors.FunnelTopRadiusFactor at the very
-- top floor (linear in between) — multiplied into every floor's radius
-- below, so the whole tower narrows toward the top like a real funnel/spire
-- instead of staying the same width all the way up.
local function getFunnelFactor(floorIndex)
	local floors = GameConfig.Floors
	local t = 0
	if floors.Count > 1 then
		t = (floorIndex - 1) / (floors.Count - 1)
	end
	t = math.clamp(t, 0, 1)
	return 1 + (floors.FunnelTopRadiusFactor - 1) * t
end

-- Which obstacle type connects floor (floorIndex - 1) to floorIndex. Cycles
-- through GameConfig.Obstacles.Pattern.
local function getObstacleType(floorIndex)
	if floorIndex <= 1 then
		return "Jump"
	end
	local pattern = GameConfig.Obstacles.Pattern
	local index = ((floorIndex - 2) % #pattern) + 1
	return pattern[index]
end

-- buildJumpPad (a launch pad that flung you across automatically) and
-- buildLadder (a climbable TrussPart, no jump power needed) used to live
-- here — removed on request, along with the "JumpPad"/"Ladder" entries in
-- GameConfig.Obstacles.Pattern (see that file's comment) and the
-- obstacleType branches below that called them. Pattern can never produce
-- those values anymore, so every floor now gets a normal "Jump" or "Bridge"
-- crossing.

-- Small stepping-stones spanning the horizontal reach of a Bridge-type gap.
local function buildBridgeStones(fromPlatform, toPlatform)
	local segments = GameConfig.Obstacles.BridgeSegments
	local fromPos = fromPlatform.Position
	local toPos = toPlatform.Position
	for s = 1, segments do
		local t = s / (segments + 1)
		local pos = fromPos:Lerp(toPos, t)
		local stone = Instance.new("Part")
		stone.Name = "BridgeStone"
		stone.Size = Vector3.new(5, 1, 5)
		stone.Anchored = true
		stone.CanCollide = true
		stone.Material = Enum.Material.WoodPlanks
		stone.Color = Color3.fromRGB(160, 120, 80)
		stone.CFrame = CFrame.new(pos)
		stone.Parent = fromPlatform.Parent
	end
end

-- Independently of the connector type, some floors get a swinging hazard bar
-- that sends the player back to their last checkpoint on touch.
--
-- FIX: never on a checkpoint floor. Checkpoint floors (Floor 1 and every
-- i % 5 == 0) are exactly where players RESPAWN after dying, and where the
-- paid Fast-Travel teleport (FastTravelService.Teleport ->
-- GetCheckpointCFrame) drops them — landing straight into an instant-kill
-- hazard bar with no warning and no chance to react is exactly what
-- happened here ("ich habe gezahlt und bin in eine Falle gekommen und war
-- Tot"). moveMakeFloorMoving/maybeMakeFloorCrumbling already excluded
-- checkpoint floors for the same reason (a fixed, predictable spot); traps
-- had that same guard missing.
local function maybeBuildTrap(platform, floorIndex, isCheckpointFloor)
	if floorIndex <= 1 or isCheckpointFloor then
		return
	end
	if math.random() > GameConfig.Obstacles.TrapChance then
		return
	end

	local hazard = Instance.new("Part")
	hazard.Name = "Hazard"
	hazard.Size = Vector3.new(6, 1, 1)
	hazard.Anchored = true
	hazard.CanCollide = false
	hazard.Material = Enum.Material.Neon
	-- On request ("grelle Lichter sind immer noch zu stark") — softened
	-- from the original full-saturation (255,30,30) the same way as every
	-- other Neon surface in the game (see buildStationPart's own comment),
	-- just a smaller Lerp fraction and almost no Transparency, since this
	-- one is a lethal hazard and needs to stay clearly readable as
	-- "dangerous, don't touch" (see the comment above about the Fast-
	-- Travel-into-an-invisible-trap complaint this same function already
	-- guards against) — dimming it too far would risk the same "unfair,
	-- didn't see it coming" problem again.
	hazard.Color = Color3.fromRGB(255, 30, 30):Lerp(Color3.new(1, 1, 1), 0.35)
	hazard.Transparency = 0.1
	hazard.CFrame = platform.CFrame * CFrame.new(0, GameConfig.Floors.Size.Y / 2 + 3, 0)
	hazard.Parent = platform

	hazard.Touched:Connect(function(hit)
		local character = hit.Parent
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid.Health = 0
		end
	end)

	local swayDistance = GameConfig.Obstacles.TrapSwayDistance
	local swaySpeed = GameConfig.Obstacles.TrapSwaySpeed
	local baseCFrame = hazard.CFrame
	task.spawn(function()
		local t = 0
		while hazard.Parent do
			t += task.wait(0.05)
			local offset = math.sin(t * swaySpeed) * swayDistance
			hazard.CFrame = baseCFrame * CFrame.new(offset, 0, 0)
		end
	end)
end

-- Cycles through GameConfig.Obstacles.ZoneEffects by visual zone (same
-- ZoneSize banding as getZoneColor) — gives whole stretches of the tower a
-- different feel (slippery Ice) instead of every floor behaving identically.
-- Floor 1's zone is "Normal" in the default config, same protective
-- principle as getGapForFloor(1) = 0.
-- The "Bouncy" branch (an automatic AssemblyLinearVelocity launch on
-- landing) was removed on request ("der Spieler hüpft manchmal
-- unkontrolliert") — it only ever hit some floors, not all of them, which
-- read as an uncontrollable random bounce rather than an intentional
-- mechanic. GameConfig.Obstacles.ZoneEffects can no longer contain "Bouncy",
-- so this function will never need that branch again.
local function applyZoneFloorEffect(platform, floorIndex)
	local effects = GameConfig.Obstacles.ZoneEffects
	if not effects or #effects == 0 then
		return
	end
	local zoneIndex = math.floor((floorIndex - 1) / GameConfig.Floors.ZoneSize) + 1
	local effect = effects[((zoneIndex - 1) % #effects) + 1]

	if effect == "Ice" then
		platform.Material = Enum.Material.Ice
		platform.Color = platform.Color:Lerp(Color3.fromRGB(200, 235, 255), 0.55)
	end
	-- "Normal" (or anything unrecognized) leaves the floor exactly as-is.
end

-- Some plain "Jump"-type floors (never Floor 1, a checkpoint, or a
-- creature-pickup floor — those need to stay in a fixed, predictable spot)
-- slide back and forth instead of sitting still, so you have to time your
-- jump instead of just walking up and hopping. Returns true if this floor
-- became one, so maybeMakeFloorCrumbling/maybeBuildTrap below can skip it —
-- stacking a swinging hazard or a vanishing floor ON TOP of a moving one
-- gets unfair fast.
local function maybeMakeFloorMoving(platform, detector, floorIndex, obstacleType, hasClaimSpot, isCheckpointFloor)
	if floorIndex <= 1 or obstacleType ~= "Jump" or hasClaimSpot or isCheckpointFloor then
		return false
	end
	if math.random() > GameConfig.Obstacles.MovingFloorChance then
		return false
	end

	platform.Material = Enum.Material.Neon
	-- On request ("grelle Lichter sind immer noch zu stark") — raised from
	-- 0.35 to 0.55 and given some Transparency too (same treatment as
	-- buildStationPart's kiosk pads), so a moving floor still visibly
	-- glows/stands out from a normal floor (the whole point — it needs to
	-- read as "special, watch this one") without being as blindingly
	-- bright as before.
	platform.Color = platform.Color:Lerp(Color3.fromRGB(255, 255, 255), 0.55)
	platform.Transparency = 0.15

	local baseCFrame = platform.CFrame
	local detectorLocalOffset = CFrame.new(0, GameConfig.Floors.Size.Y / 2 + 0.5, 0)
	local distance = GameConfig.Obstacles.MovingFloorDistance
	local speed = GameConfig.Obstacles.MovingFloorSpeed

	-- Moves the platform (and its Detector along with it, so "floor reached"
	-- detection and OnFloorReached still line up) via small per-frame CFrame
	-- steps instead of teleport-y jumps — slow/smooth enough that standing
	-- characters get carried along naturally, the same trick most Roblox
	-- moving-platform obbies use.
	task.spawn(function()
		local t = 0
		while platform.Parent do
			t += task.wait(0.03)
			local newCFrame = baseCFrame * CFrame.new(math.sin(t * speed) * distance, 0, 0)
			platform.CFrame = newCFrame
			if detector and detector.Parent then
				detector.CFrame = newCFrame * detectorLocalOffset
			end
		end
	end)

	return true
end

-- Some plain "Jump"-type floors (same exclusions as maybeMakeFloorMoving,
-- plus never one that's already moving) start shaking the moment someone
-- steps on them and vanish about a second later — long enough to jump
-- onward, not long enough to stand around and think. Reappears a few
-- seconds later so the SHARED tower stays climbable for the other 3
-- players too — nobody can permanently strand anyone else by breaking one.
local function maybeMakeFloorCrumbling(platform, floorIndex, obstacleType, hasClaimSpot, isCheckpointFloor, isMoving)
	if floorIndex <= 1 or obstacleType ~= "Jump" or hasClaimSpot or isCheckpointFloor or isMoving then
		return
	end
	if math.random() > GameConfig.Obstacles.CrumbleChance then
		return
	end

	local originalTransparency = platform.Transparency
	platform.Color = Color3.fromRGB(200, 110, 40) -- one consistent warning color across every zone

	local busy = false
	platform.Touched:Connect(function(hit)
		if busy then
			return
		end
		local character = hit.Parent
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end
		busy = true

		task.spawn(function()
			local blinkUntil = os.clock() + GameConfig.Obstacles.CrumbleWarningSeconds
			while os.clock() < blinkUntil and platform.Parent do
				platform.Transparency = 0.55
				task.wait(0.1)
				platform.Transparency = originalTransparency
				task.wait(0.1)
			end
		end)

		task.delay(GameConfig.Obstacles.CrumbleWarningSeconds, function()
			if not platform.Parent then
				return
			end
			platform.CanCollide = false
			platform.Transparency = 0.85

			task.delay(GameConfig.Obstacles.CrumbleHiddenSeconds, function()
				if not platform.Parent then
					return
				end
				platform.CanCollide = true
				platform.Transparency = originalTransparency
				busy = false
			end)
		end)
	end)
end

-- Collision walls ("Kartenrand-Wand") around the very edge of the 900x900
-- ground plate built by buildGround below — on request ("damit man nicht
-- vom Rand der Karte fällt"): nothing previously stopped a player from just
-- walking (or being knocked back) straight off the grass and falling into
-- the void underneath the whole map. This closes the WHOLE map off in a
-- box, not just the area under the tower — the tower itself and all 4 base
-- plots (GameConfig.Base.PlotRadius = 130, plots are 70x70, so they reach
-- out to roughly 130 + 35 = 165 studs from center at most) sit well inside
-- these walls at the 450-stud mark, so there's still a wide ring of open
-- grass before you'd ever reach one.
--
-- Sized generously so it can't accidentally be circumvented:
--   * wallHeight = 800 studs tall — more than double even a fully
--     maxed-out Jump Tier 10's idealized max jump height (JumpPower 370,
--     ~349 studs, see GameConfig.Floors' own jump-physics comments), which
--     already leaves headroom given this project's own finding that real
--     Roblox jump physics can be noticeably more forgiving than that
--     idealized formula.
--   * Buried 50 studs below the ground's own top surface (y = -1) up to
--     y = 750, so there's no gap underneath to slip through either.
--
-- VISIBLE "Galaxy" look (on request: "mach die Kartenrand-Wand sichtbar und
-- Färbe sie in Galaxy") — a slow, endless color cycle through a blue ->
-- violet -> magenta hue band (a "galaxy" range, not a full rainbow) so the
-- box reads as a shifting nebula rather than 4 identical static-colored
-- slabs. Each wall's cycle starts at a different phase (huePhaseOffset
-- below) so they don't all shift in lockstep. No actual space/star texture
-- used — same "no runtime asset loading" reasoning as the Mega-Truhe comment
-- far above (a real galaxy image would need an asset dropped into Studio by
-- hand); this is a pure color effect. CanCollide stays true throughout —
-- still the exact same physical barrier as before, only its look changed.
-- Still deliberately does NOT touch death, respawn, or checkpoint logic at
-- all.
--
-- Material is Glass, NOT Neon (changed on request, "kommt mir vor als wäre
-- es erst seit dem die Wände stehen mit dem Galaxy Hintergrund" — the "zu
-- kräftige Farben / Boom-Effekt" reports). Neon material in Roblox carries a
-- built-in glow/self-illumination that Studio's Bloom PostEffect reacts to
-- REGARDLESS of the actual Color3 assigned — and since Bloom is a
-- screen-space effect that reads the WHOLE rendered frame, not just the one
-- object, a giant (800-stud-tall, map-spanning) Neon surface visible
-- anywhere in a shot can inflate how blown-out everything else on screen
-- looks too, including base pedestals nowhere near the wall itself. Glass
-- keeps the same translucent, faintly shimmering look (and the exact same
-- color-cycle logic below still applies, just to a non-glowing material)
-- without that forced glow, so it should no longer feed Bloom the same way.
-- If this still isn't enough, the actual Lighting.Bloom PostEffect's own
-- Intensity/Size (Studio-only, not in this codebase — see this project's
-- own chat history) is the next thing to check.
local function buildMapBoundaryWalls(groundFolder)
	local halfSize = 450 -- buildGround's ground.Size.X / 2 and ground.Size.Z / 2 (900x900)
	local thickness = 10
	local wallHeight = 800
	local wallCenterY = 350 -- spans y = -50 .. 750

	local specs = {
		-- East / West walls (span the full Z width, plus corners overlap)
		{ size = Vector3.new(thickness, wallHeight, halfSize * 2 + thickness * 2), cframe = CFrame.new(halfSize + thickness / 2, wallCenterY, 0) },
		{ size = Vector3.new(thickness, wallHeight, halfSize * 2 + thickness * 2), cframe = CFrame.new(-(halfSize + thickness / 2), wallCenterY, 0) },
		-- North / South walls (span the full X width, plus corners overlap)
		{ size = Vector3.new(halfSize * 2 + thickness * 2, wallHeight, thickness), cframe = CFrame.new(0, wallCenterY, halfSize + thickness / 2) },
		{ size = Vector3.new(halfSize * 2 + thickness * 2, wallHeight, thickness), cframe = CFrame.new(0, wallCenterY, -(halfSize + thickness / 2)) },
	}

	for i, spec in ipairs(specs) do
		local wall = Instance.new("Part")
		wall.Name = "MapBoundaryWall_" .. i
		wall.Anchored = true
		wall.CanCollide = true
		wall.CanTouch = false
		-- Was Neon — switched to Glass (see this function's own comment
		-- above) specifically to drop Neon's forced glow/Bloom contribution
		-- while keeping the same translucent, color-shifting look.
		wall.Material = Enum.Material.Glass
		-- Was 0.15 — raised on request ("Farben ... zu kräftig / Boom-Effekt
		-- zu stark") to let more of the actual color through as see-through
		-- instead of a near-opaque slab. Easy to dial further: higher = more
		-- subtle/washed out, lower = more solid/vivid.
		wall.Transparency = 0.4
		wall.CastShadow = false
		wall.Size = spec.size
		wall.CFrame = spec.cframe
		wall.Parent = groundFolder

		-- Slow blue/violet/magenta hue oscillation, phase-offset per wall
		-- (see the function's own comment above for why) — a gentle back-
		-- and-forth via sin(), not a spinning rainbow, so it reads as a
		-- calm nebula shimmer rather than a strobing disco wall.
		local huePhaseOffset = (i - 1) / #specs
		task.spawn(function()
			local t = huePhaseOffset * 10
			while wall.Parent do
				t += task.wait(0.1)
				local hue = 0.62 + (math.sin(t * 0.3) * 0.5 + 0.5) * (0.83 - 0.62)
				-- Saturation 0.75->0.5 and Value 1->0.8 (both on request, same
				-- "too intense" feedback as Transparency above) — softer,
				-- less blown-out colors while keeping the same hue range/
				-- animation, so it's still recognizably the same Galaxy
				-- shimmer, just calmer. Tune back toward (0.75, 1) if this
				-- ends up too washed out.
				wall.Color = Color3.fromHSV(hue, 0.5, 0.8)
			end
		end)
	end
end

-- A large grass meadow under the tower's base, plus a scattered ring of
-- simple low-poly trees for a "schöne Wiese" look. Also removes the default
-- Studio "Baseplate" part so it doesn't sit underneath/clip our own ground.
local function buildGround()
	local existingBaseplate = Workspace:FindFirstChild("Baseplate")
	if existingBaseplate then
		existingBaseplate:Destroy()
	end

	local groundFolder = Instance.new("Folder")
	groundFolder.Name = "Ground"
	groundFolder.Parent = Workspace

	local ground = Instance.new("Part")
	ground.Name = "Meadow"
	ground.Anchored = true
	ground.CanCollide = true
	ground.Size = Vector3.new(900, 4, 900) -- big enough to also fit the 4 base plots (BaseService)
	ground.CFrame = CFrame.new(0, -3, 0)
	ground.Material = Enum.Material.Grass
	ground.Color = Color3.fromRGB(74, 151, 62)
	ground.TopSurface = Enum.SurfaceType.Smooth
	ground.Parent = groundFolder

	-- A ring of simple trees around the spawn area — inside the tower's own
	-- footprint clearance but well short of the base plots (GameConfig.Base.
	-- PlotRadius, currently 130), so trees never block the tower, Floor_1,
	-- the obstacles above it, or the 4 base plots surrounding everything.
	local treeCount = 16
	local minRadius = 40
	local maxRadius = 70
	for _ = 1, treeCount do
		local angle = math.random() * math.pi * 2
		local radius = minRadius + math.random() * (maxRadius - minRadius)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius

		local trunkHeight = 6 + math.random() * 3
		local trunk = Instance.new("Part")
		trunk.Name = "TreeTrunk"
		trunk.Shape = Enum.PartType.Cylinder
		trunk.Size = Vector3.new(trunkHeight, 1.4, 1.4)
		trunk.Anchored = true
		trunk.Material = Enum.Material.Wood
		trunk.Color = Color3.fromRGB(92, 64, 40)
		trunk.CFrame = CFrame.new(x, -1 + trunkHeight / 2, z) * CFrame.Angles(0, 0, math.rad(90))
		trunk.Parent = groundFolder

		local leafSize = 7 + math.random() * 2
		local leaves = Instance.new("Part")
		leaves.Name = "TreeLeaves"
		leaves.Shape = Enum.PartType.Ball
		leaves.Size = Vector3.new(leafSize, leafSize, leafSize)
		leaves.Anchored = true
		leaves.Material = Enum.Material.Grass
		leaves.Color = Color3.fromRGB(46, 125, 50)
		leaves.CFrame = CFrame.new(x, -1 + trunkHeight + leafSize / 2.5, z)
		leaves.Parent = groundFolder
	end

	buildMapBoundaryWalls(groundFolder)
end

-- Builds a SHARED physical claim spot on a floor: GameConfig.CreatureSpawn.
-- StandCount (2-3) real Brainrots stand on the platform at once, visible
-- and claimable by EVERY player in the tower — first-come-first-served,
-- real competition (same spirit as the Slap Hand), not a private per-player
-- roll like the old "pick 1 of 3 on your own screen" system. Each stand
-- shows a real 3D model if one exists in ReplicatedStorage.CreatureModels
-- (via CreatureModelDisplay, same lookup BaseService's pedestals use),
-- otherwise the same colored placeholder ball convention. The instant one
-- is claimed, that ONE stand clears and re-rolls a brand new Brainrot after
-- GameConfig.CreatureSpawn.RestockDelaySeconds, so the spot never runs dry.
--
-- onRollClaimChoices(floorIndex, count) -> array of `count` creature defs
-- onClaimCreature(player, def, floorIndex) -> true if the claim succeeded
local function buildClaimSpot(platform, floorIndex, onRollClaimChoices, onClaimCreature)
	local floors = GameConfig.Floors
	local base = GameConfig.Base
	local count = GameConfig.CreatureSpawn.StandCount

	local spotFolder = Instance.new("Folder")
	spotFolder.Name = "ClaimSpot"
	spotFolder.Parent = platform

	-- Stands sit in the platform's 4 CORNERS instead of a straight row down
	-- the middle (on request) — on the doubled 36x36 claim-spot platform
	-- (see TowerGenerator.Build), a single row was easy to walk right past
	-- without noticing the outer stands; corners spread them out so you
	-- see at least one no matter which side you land/jump in from, and
	-- they're not all clustered in the exact spot everyone's camera is
	-- already pointed at. cornerMargin insets each stand from the true
	-- edge so a scaled-up creature (up to CreatureModelHeight=9.5 studs on
	-- its largest axis, see CreatureModelDisplay.Spawn) doesn't hang off
	-- the side of the platform. With StandCount=3 (the current default),
	-- 3 of the 4 corners get used and the 4th sits empty; if StandCount is
	-- ever raised to 4, all four corners fill up automatically — anything
	-- above 4 just wraps back around to corner 1.
	local cornerMargin = 5
	local halfX = math.max(platform.Size.X / 2 - cornerMargin, 1)
	local halfZ = math.max(platform.Size.Z / 2 - cornerMargin, 1)
	local cornerOffsets = {
		Vector2.new(-halfX, -halfZ),
		Vector2.new(halfX, -halfZ),
		Vector2.new(-halfX, halfZ),
		Vector2.new(halfX, halfZ),
	}

	-- Forward-declared so showStand can reference it for the re-roll-after-
	-- claim step below.
	local showStand

	local function clearStand(hitbox)
		if hitbox and hitbox.Parent then
			hitbox:Destroy()
		end
	end

	-- On request ("die Brainrots nach 5-10 min neu spawnen lassen damit
	-- Abwechslung reinkommt") — an UNCLAIMED stand also re-rolls itself on
	-- its own after GameConfig.CreatureSpawn.IdleRefreshMinSeconds..Max
	-- Seconds, so the same few Brainrots can't just sit there forever if
	-- nobody claims them. Re-armed by showStand itself every single time it
	-- runs (initial spawn, post-claim restock, AND a previous idle-refresh),
	-- so this keeps going on its own forever without any extra wiring.
	--
	-- The `hitbox.Parent` check mirrors the exact same "did this stand
	-- already get destroyed/replaced by something else in the meantime"
	-- guard the claim-restock callback below uses — if a player claimed
	-- this exact stand (or a faster idle-refresh already fired for it)
	-- while this one was still waiting, hitbox.Parent is nil (Destroy()
	-- clears it) and there's nothing left to refresh. Lua/Roblox event
	-- handlers and task.delay callbacks never interleave mid-function, so
	-- there's no race where two of these could both act on the same stand.
	local function scheduleIdleRefresh(standIndex, hitbox)
		local delaySeconds = math.random(
			GameConfig.CreatureSpawn.IdleRefreshMinSeconds,
			GameConfig.CreatureSpawn.IdleRefreshMaxSeconds
		)
		task.delay(delaySeconds, function()
			if not spotFolder.Parent or not hitbox.Parent then
				return
			end
			clearStand(hitbox)
			local newDefs = onRollClaimChoices(floorIndex, 1)
			if newDefs and newDefs[1] then
				showStand(standIndex, newDefs[1])
			end
		end)
	end

	showStand = function(standIndex, def)
		local corner = cornerOffsets[((standIndex - 1) % #cornerOffsets) + 1]
		local standCFrame = platform.CFrame * CFrame.new(corner.X, floors.Size.Y / 2, corner.Y)

		local rarityDef = GameConfig.CreatureRarities[def.Rarity]
		local displayColor = (rarityDef and rarityDef.Color) or Color3.new(1, 1, 1)

		-- Invisible-when-a-real-model-loads hitbox — the ProximityPrompt and
		-- claim logic attach to THIS part regardless of whether a real
		-- model shows on top, same convention BaseService's pedestals use.
		local hitbox = Instance.new("Part")
		hitbox.Name = "Stand_" .. standIndex
		hitbox.Shape = Enum.PartType.Ball
		hitbox.Size = Vector3.new(2.4, 2.4, 2.4)
		hitbox.Anchored = true
		hitbox.CanCollide = false
		hitbox.Material = Enum.Material.Neon
		-- On request ("grelle Lichter sind immer noch zu stark") — same
		-- softening as every other Neon surface in the game (see
		-- buildStationPart's own comment). This one is usually hidden under
		-- the real creature model anyway, but still glows through/around it
		-- and shows fully if the model fails to load, so it gets the same
		-- treatment.
		hitbox.Color = displayColor:Lerp(Color3.new(1, 1, 1), 0.45)
		hitbox.Transparency = 0.35
		hitbox.CFrame = standCFrame * CFrame.new(0, 1.8, 0)
		hitbox.Parent = spotFolder

		-- Arms this stand's own idle-refresh timer (see scheduleIdleRefresh's
		-- comment above) — every showStand call gets a fresh one, so an
		-- unclaimed Brainrot doesn't sit here forever between claims either.
		scheduleIdleRefresh(standIndex, hitbox)

		-- Parented under the hitbox (not spotFolder directly) purely so
		-- destroying the hitbox on a claim/re-roll also cleans up the model
		-- in one go — plain Instance parenting doesn't apply any relative
		-- transform, so this doesn't affect the model's world position at
		-- all (it was already placed in world space by Spawn above).
		local modelPitch = def.ModelPitchDegrees or base.ModelDefaultPitchDegrees
		local modelRoll = def.ModelRollDegrees or base.ModelDefaultRollDegrees
		local model = CreatureModelDisplay.Spawn(
			def.Name,
			standCFrame,
			base.CreatureModelHeight,
			def.ModelYRotation,
			modelPitch,
			modelRoll
		)
		if model then
			hitbox.Transparency = 1
			model.Parent = hitbox
		end

		local nameTag = Instance.new("BillboardGui")
		nameTag.Size = UDim2.new(0, 150, 0, 56)
		nameTag.StudsOffset = Vector3.new(0, 2.2, 0)
		nameTag.AlwaysOnTop = true
		-- Same fix as the base pedestal NameTags in BaseService.lua (see its
		-- comment): no MaxDistance meant these claim-spot names on the tower
		-- itself were readable from way off — e.g. while flying/looking up
		-- at the tower from a base, per the report that names still showed
		-- "am Tower" even after the base pedestals were fixed. Set to 100
		-- directly in Studio (matched here) — bigger than the base
		-- pedestals' 40 on purpose, since claim spots are the shared prize
		-- everyone in the tower is racing for and are meant to be visible
		-- from a genuine distance while climbing, unlike a base pedestal
		-- someone's deliberately trying to hide.
		nameTag.MaxDistance = 100
		nameTag.Parent = hitbox

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = def.Name
		nameLabel.TextColor3 = displayColor
		nameLabel.TextStrokeTransparency = 0.3
		nameLabel.TextScaled = true
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.Parent = nameTag

		local rarityLabel = Instance.new("TextLabel")
		rarityLabel.Size = UDim2.new(1, 0, 0.4, 0)
		rarityLabel.Position = UDim2.new(0, 0, 0.55, 0)
		rarityLabel.BackgroundTransparency = 1
		rarityLabel.Text = def.Rarity
		rarityLabel.TextColor3 = Color3.new(1, 1, 1)
		rarityLabel.TextStrokeTransparency = 0.3
		rarityLabel.TextScaled = true
		rarityLabel.Font = Enum.Font.Gotham
		rarityLabel.Parent = nameTag

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Claim"
		prompt.ObjectText = def.Name
		prompt.HoldDuration = 0.5
		-- Zurück auf 8 (war zwischenzeitlich 13) und zurück auf Default-Style
		-- (siehe BaseService.lua's buildStationPart für die volle Begründung):
		-- der Custom-Style-Umbau hat Einsammeln/Claim auf echten Handys
		-- zuverlässig kaputt gemacht, ein kleinerer Radius hält Robloxs
		-- Default-Kästchen dafür seltener im Weg.
		prompt.MaxActivationDistance = 8
		prompt.Parent = hitbox

		-- Guards against two players triggering the SAME stand at once —
		-- Roblox server Lua runs event handlers to completion before the
		-- next one starts, and nothing in this handler yields before
		-- `busy` is set, so this is a solid single-winner guard even
		-- though the tower is shared by up to 4 players.
		local busy = false
		prompt.Triggered:Connect(function(player)
			if busy then
				return
			end
			busy = true

			local success = onClaimCreature(player, def, floorIndex)
			if success then
				clearStand(hitbox)
				task.delay(GameConfig.CreatureSpawn.RestockDelaySeconds, function()
					if not spotFolder.Parent then
						return
					end
					local newDefs = onRollClaimChoices(floorIndex, 1)
					if newDefs and newDefs[1] then
						showStand(standIndex, newDefs[1])
					end
				end)
			else
				busy = false
			end
		end)
	end

	local initialDefs = onRollClaimChoices(floorIndex, count)
	for standIndex = 1, count do
		if initialDefs[standIndex] then
			showStand(standIndex, initialDefs[standIndex])
		end
	end
end

-- onFloorReached(player, floorIndex)
-- onRollClaimChoices(floorIndex, count) -> array of creature defs
-- onClaimCreature(player, def, floorIndex) -> true if the claim succeeded (floorIndex is this claim spot's own floor, added for the anti-cheat "must have really reached this floor" check — see init.server.lua's wiring)
-- onSummitChestOpened(player) -- called from the Mega-Truhe's ProximityPrompt at Floor 100 (see GameConfig.Summit / SummitChestService.lua)
function TowerGenerator.Build(onFloorReached, onRollClaimChoices, onClaimCreature, onSummitChestOpened)
	local floors = GameConfig.Floors

	-- So ReplicatedStorage.SummitAssets exists and is ready for you to drop
	-- a "Chest" Model into (see getSummitChestTemplate's long comment above)
	-- even on a server that's never had one before — never touches an
	-- existing folder (and whatever's already inside it), only creates it
	-- when missing, same as CreatureModelDisplay.EnsureFolder.
	TowerGenerator.EnsureSummitAssetsFolder()

	buildGround()

	local towerFolder = Instance.new("Folder")
	towerFolder.Name = "Tower"
	towerFolder.Parent = Workspace

	local floorParts = {}
	local cumulativeY = 0

	-- Prestige-Turm (see GameConfig.Prestige's own long comment): 20 more
	-- floors (101-120) get appended straight onto the end of the normal
	-- loop below, deliberately reusing EVERY floor-building mechanic as-is
	-- (obstacles, traps, moving/crumbling floors, claim spots every
	-- CreatureSpawn.FloorInterval floors, checkpoints every 5 floors, ...) —
	-- the only things that behave differently for i > floors.Count are the
	-- extra horizontal offset (getHorizontalOffsetForFloor below), the
	-- platform look (isPrestigeFloor further down), and the Gap itself,
	-- which reads GameConfig.PrestigeJumpTiers instead of plateauing (see
	-- getGapForFloor's own branch above).
	--
	-- GameConfig.Prestige.Enabled is a master kill-switch (on request:
	-- "kann ich die Änderung von Floor 101-120 momentan noch weg lassen,
	-- damit kein Spieler es nutzen kann aber wenn ich will kann ich es
	-- aktivieren") — false by default, which makes totalFloorCount fall
	-- back to exactly floors.Count, so the loop below builds ONLY the
	-- normal 100 floors, same as before the Prestige-Turm existed at all.
	-- No Floor_101+ parts exist at all while disabled, so there's nothing
	-- for a player to reach no matter what — this is a stronger guarantee
	-- than the Rebirth-count gate alone (EconomyService.OnFloorReached's
	-- prestigeLocked check), which still applies underneath as a second
	-- layer once this is turned on. Flip to true and republish/restart the
	-- server (the tower is only built once, at server start, so a live
	-- toggle without a restart wouldn't actually grow the tower) whenever
	-- ready to test or launch it for real.
	local totalFloorCount = floors.Count
	if GameConfig.Prestige.Enabled then
		totalFloorCount += GameConfig.Prestige.FloorCount
	end

	for i = 1, totalFloorCount do
		local obstacleType = getObstacleType(i)
		local isCheckpointFloor = (i == 1) or (i % 5 == 0)
		local isSummitFloor = (i == floors.Count)
		-- Floor 100 is excluded on purpose (on request) — it's the Summit's
		-- own special reward floor (Mega-Truhe), so it never doubles up as a
		-- claim-spot floor too, even when FloorInterval's multiples would
		-- otherwise land exactly on it (e.g. FloorInterval=5 -> ...,95,100).
		local hasClaimSpot = i > 1 and i % GameConfig.CreatureSpawn.FloorInterval == 0 and not isSummitFloor
		local isPrestigeFloor = i > floors.Count

		local platform = Instance.new("Part")
		platform.Name = "Floor_" .. i
		platform.Anchored = true
		-- Claim-spot floors (every GameConfig.CreatureSpawn.FloorInterval-th
		-- floor, e.g. 5/10/15/...) get a DOUBLED platform footprint on
		-- request — with real 3D creature models standing on them (see
		-- CreatureModelDisplay), the normal 18x18 floor felt cramped for 3
		-- stands side by side. Only X/Z double, Size.Y (thickness) stays the
		-- same — so the vertical jump math (getGapForFloor etc., all
		-- Y-based) is completely unaffected; this only makes the floor a
		-- bigger, more forgiving target to land ON, never a harder or
		-- easier jump to reach.
		platform.Size = hasClaimSpot and (floors.Size * Vector3.new(2, 1, 2)) or floors.Size
		-- Floor 100 gets its own fixed look instead of the normal zone-cycle
		-- color (on request: "Floor 100 möchte ich besonders machen") — see
		-- GameConfig.Summit's own comment. Prestige-Turm floors (101+) get
		-- their own fixed dark-violet look too (GameConfig.Prestige.
		-- FloorColor/FloorMaterial), so the transition into the new section
		-- is instantly visible instead of just continuing the normal zone
		-- color cycle.
		if isSummitFloor then
			platform.Material = GameConfig.Summit.PlatformMaterial
			platform.Color = GameConfig.Summit.PlatformColor
		elseif isPrestigeFloor then
			platform.Material = GameConfig.Prestige.FloorMaterial
			platform.Color = GameConfig.Prestige.FloorColor
		else
			platform.Material = Enum.Material.SmoothPlastic
			platform.Color = getZoneColor(i)
		end

		if i > 1 then
			if obstacleType == "Bridge" then
				cumulativeY += GameConfig.Obstacles.BridgeHeightStep
			else
				cumulativeY += getGapForFloor(i)
			end
		end

		-- SPIRAL/FUNNEL LAYOUT: each floor sits on a circle around the
		-- tower's central vertical axis, rotated SpiralAngleStep degrees
		-- from the last one (150° — not a clean divisor of 360, so the jump
		-- direction keeps changing instead of repeating the same left-right
		-- pattern forever) and at a radius that shrinks the higher you go
		-- (getFunnelFactor) — that's what gives the whole tower its
		-- narrowing "Trichter" silhouette from outside.
		local funnelFactor = getFunnelFactor(i)
		local angle = math.rad(i * floors.SpiralAngleStep)

		local radius
		if obstacleType == "Bridge" then
			radius = GameConfig.Obstacles.BridgeHorizontalReach * funnelFactor
		elseif i > 1 and getObstacleType(i - 1) == "Bridge" then
			-- The floor right after a Bridge floor used to snap back to the
			-- normal small offset, leaving a leftover gap of up to
			-- BridgeHorizontalReach (46 studs) ON TOP OF the floor's own
			-- vertical Gap — an unfair, often uncrossable jump that repeated
			-- at every Bridge floor in the pattern. Instead, step back
			-- INWARD by the normal small increment FROM the Bridge floor's
			-- own radius, so this jump is just as reasonable as any other
			-- floor-to-floor jump.
			local prevPos = floorParts[i - 1].Position
			local prevRadius = Vector2.new(prevPos.X, prevPos.Z).Magnitude
			local step = getHorizontalOffsetForFloor(i) * funnelFactor
			radius = math.max(prevRadius - step, step)
		else
			radius = getHorizontalOffsetForFloor(i) * funnelFactor
		end

		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius

		platform.CFrame = CFrame.new(x, cumulativeY, z)
		platform.Parent = towerFolder
		floorParts[i] = platform
		allFloorPlatforms[i] = platform

		-- Skipped for the Summit floor — its golden look (set above) is
		-- fixed on purpose and shouldn't get overwritten by whichever zone
		-- effect (e.g. "Ice") its zone-cycle position would otherwise land
		-- on. Same reasoning for Prestige-Turm floors and their own fixed
		-- dark-violet look.
		if not isSummitFloor and not isPrestigeFloor then
			applyZoneFloorEffect(platform, i)
		end

		-- Invisible detector: fires when a player's character touches the top of this floor.
		-- Sized off platform.Size (not floors.Size) so it still covers the
		-- WHOLE floor on a doubled claim-spot platform instead of just the
		-- old, smaller middle portion of it.
		local detector = Instance.new("Part")
		detector.Name = "Detector"
		detector.Size = Vector3.new(platform.Size.X, 1, platform.Size.Z)
		detector.Transparency = 1
		detector.CanCollide = false
		detector.Anchored = true
		detector.CFrame = platform.CFrame * CFrame.new(0, floors.Size.Y / 2 + 0.5, 0)
		detector.Parent = platform

		detector.Touched:Connect(function(hit)
			local character = hit.Parent
			local player = Players:GetPlayerFromCharacter(character)
			if player then
				onFloorReached(player, i)
			end
		end)

		local isMoving = maybeMakeFloorMoving(platform, detector, i, obstacleType, hasClaimSpot, isCheckpointFloor)
		maybeMakeFloorCrumbling(platform, i, obstacleType, hasClaimSpot, isCheckpointFloor, isMoving)

		-- Floor 1 is the ONLY real SpawnLocation in the game. Roblox spawns a
		-- brand-new character at a random SpawnLocation if there's more than
		-- one — with just this one, there's no randomness, everyone starts here.
		if i == 1 then
			local spawnPoint = Instance.new("SpawnLocation")
			spawnPoint.Name = "Checkpoint_" .. i
			spawnPoint.Anchored = true
			spawnPoint.Size = Vector3.new(6, 1, 6)
			spawnPoint.Transparency = 1
			spawnPoint.CanCollide = true
			spawnPoint.Neutral = true
			spawnPoint.Duration = 0
			spawnPoint.CFrame = platform.CFrame * CFrame.new(0, floors.Size.Y / 2 + 0.5, 0)
			spawnPoint.Parent = platform
			checkpointPartsByFloor[i] = spawnPoint
		elseif i % 5 == 0 then
			-- Later checkpoints are plain Parts, not SpawnLocations, so they
			-- never compete with Floor 1 for a new player's first spawn.
			-- Touching one just updates THIS player's personal respawn point.
			-- CanCollide = false on purpose (was true) — this pad sits raised
			-- 0.5 studs directly on top of the platform's own solid surface,
			-- so as a solid box it could catch a landing character's feet on
			-- its edge and shove/launch them, which read as an unrelated
			-- "unkontrolliertes Hüpfen" alongside the since-removed Bouncy
			-- zone effect. Touched still fires without CanCollide (Roblox's
			-- CanTouch, on by default, is what drives Touched — independent
			-- of CanCollide), so the respawn-tracking below is unaffected;
			-- only the physical collision is gone.
			local checkpoint = Instance.new("Part")
			checkpoint.Name = "Checkpoint_" .. i
			checkpoint.Anchored = true
			checkpoint.CanCollide = false
			-- On request ("grelle Lichter sind immer noch zu stark") — raised
			-- from 0.6 to 0.75, same reasoning as every other Neon surface in
			-- the game (see buildStationPart's own comment) — still visible
			-- as a checkpoint marker, just noticeably calmer.
			checkpoint.Transparency = 0.75
			checkpoint.Material = Enum.Material.Neon
			checkpoint.Color = Color3.fromRGB(255, 255, 255)
			checkpoint.Size = Vector3.new(6, 1, 6)
			checkpoint.CFrame = platform.CFrame * CFrame.new(0, floors.Size.Y / 2 + 0.5, 0)
			checkpoint.Parent = platform
			checkpointPartsByFloor[i] = checkpoint

			checkpoint.Touched:Connect(function(hit)
				local character = hit.Parent
				local player = Players:GetPlayerFromCharacter(character)
				-- Only actually reassign if it's a NEW checkpoint — Touched
				-- keeps firing repeatedly while a character stands on/walks
				-- across the part, and re-setting RespawnLocation to the
				-- SAME Part every single time was spamming Studio's Output
				-- with a harmless-but-noisy "Expected SpawnLocation got
				-- Part" warning (plain Parts are used here on purpose, see
				-- above, so that warning can never fully go away — this just
				-- stops it firing dozens of times per second).
				if player and player.RespawnLocation ~= checkpoint then
					player.RespawnLocation = checkpoint
				end
			end)
		end

		-- Floor-number landmark ("jeden 10 Floor beschriften, damit man ca.
		-- sieht wo man ist") — every 10th floor gets a big floating
		-- "Floor N" label well above the platform, clear of the checkpoint
		-- mat/claim stands below it. AlwaysOnTop so it stays readable even
		-- when partially hidden behind other floors of the spiral tower —
		-- and, UNLIKE the pedestal NameTags in BaseService.lua (which just
		-- got a MaxDistance specifically so they DON'T read from far away),
		-- this one is deliberately left with no distance limit: the whole
		-- point here is to be spottable from a ways off while climbing.
		if i % 10 == 0 or isSummitFloor then
			-- The "or isSummitFloor" guard makes sure the Summit's own
			-- golden title always builds even if GameConfig.Floors.Count
			-- were ever changed to a number that isn't a multiple of 10 —
			-- otherwise the very last floor could silently lose its special
			-- label.
			local floorLabelAnchor = Instance.new("Part")
			floorLabelAnchor.Name = "FloorLabelAnchor"
			floorLabelAnchor.Anchored = true
			floorLabelAnchor.CanCollide = false
			floorLabelAnchor.CanQuery = false
			floorLabelAnchor.Transparency = 1
			floorLabelAnchor.Size = Vector3.new(1, 1, 1)
			floorLabelAnchor.CFrame = platform.CFrame * CFrame.new(0, floors.Size.Y / 2 + 6, 0)
			floorLabelAnchor.Parent = platform

			local floorBillboard = Instance.new("BillboardGui")
			floorBillboard.Name = "FloorLabel"
			floorBillboard.Size = UDim2.new(0, 160, 0, 50)
			floorBillboard.AlwaysOnTop = true
			floorBillboard.Parent = floorLabelAnchor

			-- The Summit floor gets its own bigger, golden title
			-- (GameConfig.Summit.TitleText, e.g. "🏆 GIPFEL") here INSTEAD OF
			-- the plain "Floor 100" text every other 10th floor gets — same
			-- BillboardGui/anchor, just styled to stand out as the actual
			-- top of the tower rather than just another landmark.
			local floorText = Instance.new("TextLabel")
			floorText.Name = "Text"
			floorText.Size = UDim2.new(1, 0, 1, 0)
			floorText.BackgroundTransparency = 1
			floorText.TextStrokeTransparency = 0
			floorText.TextStrokeColor3 = Color3.new(0, 0, 0)
			floorText.Font = Enum.Font.GothamBlack
			floorText.TextScaled = true
			if isSummitFloor then
				floorBillboard.Size = UDim2.new(0, 220, 0, 70)
				floorText.Text = GameConfig.Summit.TitleText
				floorText.TextColor3 = GameConfig.Summit.PlatformColor
			else
				floorText.Text = "Floor " .. i
				floorText.TextColor3 = Color3.new(1, 1, 1)
			end
			floorText.Parent = floorBillboard
		end

		-- The "Mega-Truhe" — a physical chest ONLY at Floor 100 (see
		-- GameConfig.Summit's own comment / SummitChestService.lua), openable
		-- once per real day per player. Built as a small glowing chest-like
		-- Part right next to the checkpoint mat, with its own ProximityPrompt
		-- — same overall shape (Part + ProximityPrompt) as buildClaimSpot's
		-- creature stands below, just far simpler (single instant action,
		-- no restock/choice UI needed).
		if isSummitFloor then
			local chestCFrame = platform.CFrame * CFrame.new(0, floors.Size.Y / 2 + 1.5, -7)
			local chestTemplate = getSummitChestTemplate()
			local chest, chestAnchor -- chestAnchor is whichever BasePart the light/billboard/prompt below actually attach to

			if chestTemplate then
				-- Real dropped-in asset (see getSummitChestTemplate's comment) —
				-- PivotTo works identically whether `chest` is a Model or a bare
				-- BasePart (both are PVInstances), so positioning needs no
				-- branching at all. Scaling does: Model:ScaleTo doesn't exist on
				-- a plain BasePart, so a lone MeshPart/Part/Union scales by
				-- multiplying its own Size instead — captured BEFORE that
				-- happens since `chest.Size` would otherwise already reflect
				-- the new scale by the time it's read.
				chest = chestTemplate:Clone()
				chest.Name = "SummitChest"
				chest.Parent = platform
				chest:PivotTo(chestCFrame * CFrame.new(0, GameConfig.Summit.ChestModelYOffset, 0))

				local originalPartSize = chest:IsA("BasePart") and chest.Size or nil
				if GameConfig.Summit.ChestModelScale ~= 1 then
					if chest:IsA("Model") then
						chest:ScaleTo(GameConfig.Summit.ChestModelScale)
					elseif originalPartSize then
						chest.Size = originalPartSize * GameConfig.Summit.ChestModelScale
					end
				end

				-- A Toolbox asset's parts can come in with CanCollide/Anchored
				-- set however that creator happened to leave them — force both
				-- to the same "solid, fixed in place" state every other piece
				-- of tower geometry uses, rather than trusting the asset. Covers
				-- BOTH shapes: `chest` itself being a BasePart (a lone MeshPart
				-- has no descendants to iterate), and `chest` being a Model
				-- (GetDescendants finds every BasePart inside it).
				if chest:IsA("BasePart") then
					chest.Anchored = true
					chest.CanCollide = true
				end
				for _, part in ipairs(chest:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = true
						part.CanCollide = true
					end
				end

				chestAnchor = chest:IsA("BasePart") and chest
					or (chest.PrimaryPart or chest:FindFirstChildWhichIsA("BasePart", true))
			else
				-- No "Chest" Model dropped into ReplicatedStorage.SummitAssets
				-- yet (or it's not a Model) — same plain gold-Neon-block
				-- placeholder as before, so the chest is always interactable
				-- even before you've inserted the real asset.
				chest = Instance.new("Part")
				chest.Name = "SummitChest"
				chest.Anchored = true
				chest.CanCollide = true
				chest.Material = Enum.Material.Neon
				chest.Color = GameConfig.Summit.PlatformColor
				chest.Shape = Enum.PartType.Block
				chest.Size = Vector3.new(4, 3, 3)
				chest.CFrame = chestCFrame
				chest.Parent = platform

				chestAnchor = chest
			end

			-- chestAnchor can be nil for a template Model with zero BaseParts
			-- anywhere in it (an empty/misbuilt asset) — skip the light/label/
			-- prompt entirely rather than erroring, same "fail safe, not loud"
			-- spirit as the rest of this block.
			if chestAnchor then
				local chestLight = Instance.new("PointLight")
				chestLight.Color = GameConfig.Summit.PlatformColor
				chestLight.Range = 16
				chestLight.Brightness = 2
				chestLight.Parent = chestAnchor

				local chestBillboard = Instance.new("BillboardGui")
				chestBillboard.Name = "ChestLabel"
				chestBillboard.Size = UDim2.new(0, 140, 0, 36)
				chestBillboard.StudsOffset = Vector3.new(0, 2.5, 0)
				chestBillboard.AlwaysOnTop = true
				chestBillboard.Adornee = chestAnchor
				chestBillboard.Parent = chestAnchor

				local chestLabelText = Instance.new("TextLabel")
				chestLabelText.Size = UDim2.new(1, 0, 1, 0)
				chestLabelText.BackgroundTransparency = 1
				chestLabelText.Text = "🏆 " .. GameConfig.Summit.ChestTitle
				chestLabelText.TextColor3 = Color3.new(1, 1, 1)
				chestLabelText.TextStrokeTransparency = 0
				chestLabelText.Font = Enum.Font.GothamBlack
				chestLabelText.TextScaled = true
				chestLabelText.Parent = chestBillboard

				local chestPrompt = Instance.new("ProximityPrompt")
				chestPrompt.ActionText = GameConfig.Summit.ChestActionText
				chestPrompt.ObjectText = GameConfig.Summit.ChestTitle
				chestPrompt.HoldDuration = 0.5
				-- Zurück auf 10 (war zwischenzeitlich 15) und zurück auf
				-- Default-Style (siehe BaseService.lua's buildStationPart für
				-- die volle Begründung) — Custom-Style hat das auf echten
				-- Handys zuverlässig kaputt gemacht.
				chestPrompt.MaxActivationDistance = 10
				chestPrompt.Parent = chestAnchor

				chestPrompt.Triggered:Connect(function(triggeringPlayer)
					if onSummitChestOpened then
						onSummitChestOpened(triggeringPlayer)
					end
				end)
			end
		end

		-- Claim spot every N floors (the extra guaranteed spawn on Bridge
		-- floors has been removed on request — Bridge floors no longer get
		-- one unless they also happen to land on a normal FloorInterval
		-- multiple): 2-3 REAL Brainrots stand on the platform, shared by
		-- everyone in the tower — see buildClaimSpot.
		if hasClaimSpot then
			buildClaimSpot(platform, i, onRollClaimChoices, onClaimCreature)
		end

		-- Route-variety obstacle for the connection INTO this floor
		-- (JumpPad/Ladder branches removed along with Pattern's entries for
		-- them — see the comment above where buildJumpPad/buildLadder used
		-- to be defined)
		if i > 1 then
			if obstacleType == "Bridge" then
				buildBridgeStones(floorParts[i - 1], platform)
			end
		end

		if not isMoving then
			maybeBuildTrap(platform, i, isCheckpointFloor)
		end
	end

	-- Reset players who fall well below the tower base (simple fall-damage-free respawn)
	RunService.Heartbeat:Connect(function()
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and root.Position.Y < -50 and humanoid.Health > 0 then
				humanoid.Health = 0
			end
		end
	end)

	return floorParts
end

return TowerGenerator
