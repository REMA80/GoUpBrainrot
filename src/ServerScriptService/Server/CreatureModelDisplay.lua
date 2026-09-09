--[[
	CreatureModelDisplay.lua
	Shared "find/clone/scale/place a real creature model, or fall back to a
	colored placeholder" logic — used by BOTH BaseService (pedestals in a
	player's base) and TowerGenerator (the physical claim-spot stands in the
	tower). Extracted from BaseService so both places share the exact same
	model lookup/scale/pivot math instead of duplicating it.

	No Init(deps) here on purpose — this is a plain stateless-ish utility
	(only its own internal cache), not a wired service, so both callers just
	require() it directly like they already do with GameConfig.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Added on request ("kannst du über die Brainrots auch so einen Schimmer
-- wie über die Spieler legen?") — needed to look up a creature's Rarity by
-- name for the pulsing glow below. Everything else in this file stays
-- exactly as stateless as before (see the header comment on why there's no
-- Init(deps) here); GameConfig is a plain data module, not a wired service,
-- so requiring it directly here doesn't change that.
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local CreatureModelDisplay = {}

-- [creatureName] = the Model instance found in ReplicatedStorage.
-- CreatureModels for that creature, ONLY once one has actually been found —
-- a creature with no model yet is deliberately left OUT of this table
-- entirely (see GetTemplate below), not cached as "false"/missing.
--
-- An earlier version DID cache a miss as `false`, on the theory that a
-- creature with no model shouldn't repeat a FindFirstChild lookup on every
-- claim-spot roll. That backfired in practice: a claim spot that rolled a
-- creature BEFORE its model got dropped into Studio would cache that miss
-- forever — dropping the model in seconds later (which Studio DOES sync
-- live into a running Play Solo session) never got picked up for that
-- creature name for the rest of the server's life, only a full Stop+Play
-- would clear it. That's exactly what caused "Ballerina Cappuccina shows a
-- real model at one claim spot but still just the placeholder ball at
-- another, same Play session" — whichever spot rolled it FIRST, before the
-- model existed, was stuck. Only caching HITS (never misses) means a model
-- added mid-session gets picked up by the very next re-roll of that
-- creature, no restart needed — at the cost of one extra FindFirstChild
-- per roll of a creature that still has no model, which is cheap enough
-- (a folder lookup, not a per-frame cost) not to matter.
local modelTemplateCache = {}

-- [creatureName] = Rarity, built ONCE from the static GameConfig.Creatures
-- list — unlike modelTemplateCache above, this never needs to be lazy/
-- re-checked, since the ROSTER itself (which name belongs to which Rarity)
-- doesn't change while the server is running, only which 3D MODELS have
-- been dropped into Studio for it yet. Used by the pulsing rarity glow
-- below (addRarityGlow) to decide whether a given creature qualifies.
local creatureRarityByName = {}
for _, def in ipairs(GameConfig.Creatures) do
	creatureRarityByName[def.Name] = def.Rarity
end

-- Only these two rarities get the glow (on request, "nur Glitchrot und
-- Singularity") — the two brand-new top tiers above Lava, deliberately
-- rarer than everything else in the game (see GameConfig.CreatureRarities'
-- own comment on them). Every other rarity (including Hacker/Lava) is left
-- completely untouched.
local GLOW_RARITIES = {
	Glitchrot = true,
	Singularity = true,
}

-- How bright the glow's own base color needs to be to read clearly, from a
-- distance, as an actual GLOW rather than a faint tint (0-255 scale, same
-- perceived-brightness weights UIBuilder.lua's legibleHeaderColor uses for
-- the exact same underlying problem, just tuned a bit higher here since a
-- glow needs to catch the eye across the room, not just be readable up
-- close like Dex text). Singularity's configured Color, Color3.fromRGB(25,
-- 10, 45), is a near-black purple picked for its normal thumbnail/particle
-- look — gorgeous as a tiny accent, but a glow built straight from it would
-- be almost invisible, so it gets pulled MUCH closer to white (luminance
-- ~18 -> 140). Glitchrot's color (255, 20, 220, a vivid magenta, luminance
-- ~113) only needs a small nudge to clear the same floor — still
-- unmistakably the same magenta, just a hair brighter.
local MIN_GLOW_LUMINANCE = 140
local function legibleGlowColor(color)
	local luminance = (0.299 * color.R + 0.587 * color.G + 0.114 * color.B) * 255
	if luminance >= MIN_GLOW_LUMINANCE then
		return color
	end
	local fraction = math.clamp((MIN_GLOW_LUMINANCE - luminance) / (255 - luminance), 0, 1)
	return color:Lerp(Color3.new(1, 1, 1), fraction)
end

-- Pulse timing/range — a slow ~3s breathing cycle (2π / GLOW_PULSE_SPEED),
-- not a fast blink, so it reads as "shimmer" rather than an alarm. Every
-- glowing creature reads the SAME os.clock()-based phase (no per-model
-- state needed), so they all end up gently pulsing in sync, which looks
-- more like one coherent effect than several independently flickering ones.
local GLOW_PULSE_SPEED = 2
local GLOW_FILL_MIN, GLOW_FILL_MAX = 0.55, 0.85
local GLOW_OUTLINE_MIN, GLOW_OUTLINE_MAX = 0.1, 0.4
local GLOW_STEP_SECONDS = 0.05 -- 20/s — smooth enough for a slow pulse, cheap enough for several at once

-- Adds a pulsing colored Highlight around `model` for `rarity`, or does
-- nothing if `rarity` isn't in GLOW_RARITIES. Same Highlight-based glow
-- technique RebirthCosmeticsService already uses for the player's
-- Rebirth-tier outline (OutlineColor blended toward white, FillTransparency
-- high) — just looping its own Transparency instead of staying fixed.
-- Called from Spawn below for EVERY caller (BaseService's base pedestals
-- AND TowerGenerator's tower claim-spot stands, "Beide" was the answer to
-- where this should show up) since both share this one function — same
-- "runs for every caller" reasoning as the Neon-softening block above.
--
-- The pulsing loop is a plain `task.spawn` + `while model.Parent do ...
-- task.wait() end`, the same "stop on its own once the Instance is gone"
-- idiom already used elsewhere in this codebase (e.g. init.server.lua's
-- leaderstats polling) — no manual disconnect needed: once `model` is
-- destroyed (pedestal cleared, claim spot re-rolled, base rebuilt), its
-- Parent goes nil and the loop just exits on its next check.
local function addRarityGlow(model, rarity)
	if not GLOW_RARITIES[rarity] then
		return
	end

	local rarityDef = GameConfig.CreatureRarities[rarity]
	local baseColor = (rarityDef and rarityDef.Color) or Color3.new(1, 1, 1)
	local glowColor = legibleGlowColor(baseColor)

	local highlight = Instance.new("Highlight")
	highlight.Name = "RarityGlow"
	highlight.FillColor = glowColor
	highlight.OutlineColor = glowColor
	highlight.FillTransparency = GLOW_FILL_MAX
	highlight.OutlineTransparency = GLOW_OUTLINE_MAX
	highlight.Parent = model

	task.spawn(function()
		while model.Parent and highlight.Parent do
			local phase = (math.sin(os.clock() * GLOW_PULSE_SPEED) + 1) / 2 -- 0..1, smooth breathing
			highlight.FillTransparency = GLOW_FILL_MIN + (GLOW_FILL_MAX - GLOW_FILL_MIN) * phase
			highlight.OutlineTransparency = GLOW_OUTLINE_MIN + (GLOW_OUTLINE_MAX - GLOW_OUTLINE_MIN) * phase
			task.wait(GLOW_STEP_SECONDS)
		end
	end)
end

-- [creatureName] = true once its ONE-TIME diagnostic line (see Spawn below)
-- has printed, so joining/rebuilding a base repeatedly doesn't spam the
-- Output window with the same measurement over and over.
local debugLoggedNames = {}

-- Live debug override for pitch/roll, set via the "/pitch <p> <r>" chat
-- command (see init.server.lua) — while set, it overrides EVERY creature's
-- normal pitch/roll (GameConfig.Base default or that creature's own
-- ModelPitchDegrees/ModelRollDegrees) so you can rebuild your base
-- (BaseService.RefreshBase) and see the result INSTANTLY, without editing
-- GameConfig + a full Stop+Play for every value you want to try. nil (the
-- default) means "no override — use each creature's normal value";
-- "/pitch off" clears it back to nil.
local debugOverridePitch = nil
local debugOverrideRoll = nil

-- Same idea, but for the FACING direction (yaw, around Y) instead of the
-- "stand it upright" pitch/roll — set via "/yaw <degrees>" or "/yaw cycle"
-- (see init.server.lua). Kept as its own separate override (not merged
-- into SetDebugOverride above) so you can test facing and upright-ness
-- independently without one clearing the other.
local debugOverrideYaw = nil
local debugYawCycleValues = nil

function CreatureModelDisplay.SetDebugYawOverride(yaw)
	debugOverrideYaw = yaw
	debugYawCycleValues = nil
end

function CreatureModelDisplay.SetDebugYawCycle(values)
	debugYawCycleValues = values
	debugOverrideYaw = nil
end

function CreatureModelDisplay.ClearDebugYawOverride()
	debugOverrideYaw = nil
	debugYawCycleValues = nil
end

-- Live debug CYCLE for pitch/roll, set via "/pitch cycle" or "/pitch
-- cycleroll" (see init.server.lua) — instead of forcing ONE value onto
-- every pedestal (like SetDebugOverride below), this gives pedestal #1 one
-- candidate value, #2 the next, #3 the next, and so on (wrapping back to
-- #1 if you have more pedestals than candidates). That way, if you have 4+
-- creatures out already, you can see all 4 candidate corrections at once
-- in a SINGLE screenshot of your base, instead of testing one value,
-- rebuilding, screenshotting, testing the next value, etc. Values are an
-- array of {Pitch=, Roll=} tables. BaseService looks this up per-pedestal
-- via `debugSlotIndex` in Spawn below, and labels each pedestal with
-- whichever value it actually got (see BaseService's nameLabel).
local debugCycleValues = nil

function CreatureModelDisplay.SetDebugOverride(pitch, roll)
	debugOverridePitch = pitch
	debugOverrideRoll = roll
	debugCycleValues = nil -- a single override and a cycle are mutually exclusive
end

function CreatureModelDisplay.ClearDebugOverride()
	debugOverridePitch = nil
	debugOverrideRoll = nil
	debugCycleValues = nil
end

function CreatureModelDisplay.SetDebugCycle(values)
	debugCycleValues = values
	debugOverridePitch = nil
	debugOverrideRoll = nil
end

-- True while EITHER a single override or a cycle is active — BaseService
-- uses this to decide whether to append the tested Pitch/Roll value onto
-- each pedestal's name label, so you can read straight off a screenshot
-- which value produced which result instead of having to remember/guess.
function CreatureModelDisplay.IsDebugActive()
	return debugOverridePitch ~= nil or debugOverrideRoll ~= nil or debugCycleValues ~= nil
end

-- Same as IsDebugActive above, but for the yaw override/cycle.
function CreatureModelDisplay.IsYawDebugActive()
	return debugOverrideYaw ~= nil or debugYawCycleValues ~= nil
end

-- Makes sure ReplicatedStorage.CreatureModels exists — the folder you drop
-- real creature Models into by hand in Studio, one Model per creature,
-- renamed to match that creature's exact `Name` in GameConfig.Creatures.
-- Only CREATES it if missing; never touches an existing one, so anything
-- already dropped in there survives every server restart untouched.
function CreatureModelDisplay.EnsureFolder()
	if not ReplicatedStorage:FindFirstChild("CreatureModels") then
		local folder = Instance.new("Folder")
		folder.Name = "CreatureModels"
		folder.Parent = ReplicatedStorage
	end
end

-- Finds (and caches) a real 3D model for a creature, by NAME, from
-- ReplicatedStorage.CreatureModels. This replaced an earlier InsertService:
-- LoadAsset(assetId)-based version — loading other creators' Toolbox/Creator
-- Store assets by ID kept failing with "User is not authorized to access
-- Asset", even for a "Save to Roblox" own-copy. A model placed directly in
-- Studio has none of that: it's just part of the place already, no runtime
-- permission check needed at all.
--
-- A missing model is the NORMAL default state (most creatures won't have one
-- yet) so that's not warned about — only a same-named child that ISN'T a
-- Model gets flagged, since that's an actual mistake.
--
-- Only a SUCCESSFUL find gets cached (see modelTemplateCache's comment
-- above) — a miss just returns nil every time, without remembering it, so
-- dropping a model into Studio mid-session is picked up by that creature's
-- very next claim-spot roll instead of needing a full Stop+Play.
function CreatureModelDisplay.GetTemplate(creatureName)
	if modelTemplateCache[creatureName] then
		return modelTemplateCache[creatureName]
	end

	local folder = ReplicatedStorage:FindFirstChild("CreatureModels")
	local template = folder and folder:FindFirstChild(creatureName)
	if not template then
		return nil
	end
	if not template:IsA("Model") then
		warn(
			"[CreatureModelDisplay] ReplicatedStorage.CreatureModels."
				.. creatureName
				.. " exists but isn't a Model (it's a "
				.. template.ClassName
				.. ") — skipping, falling back to the placeholder ball"
		)
		return nil
	end

	modelTemplateCache[creatureName] = template
	return template
end

-- Computes a TRUE world-axis-aligned bounding box directly from every
-- BasePart's actual CFrame/Size — completely bypassing Model:GetBoundingBox()
-- and Model:GetPivot(). Written after discovering that both of those
-- silently orient themselves to a model's PrimaryPart (or an explicit
-- custom pivot some Toolbox creators set with Studio's pivot tool) instead
-- of the world axes — so a model that looks PERFECTLY upright when viewed
-- directly in Studio's Explorer/viewport could still measure/scale/rotate
-- wrong through the normal APIs, for reasons that have nothing to do with
-- how the model actually looks. Working from raw part corners instead means
-- the result only ever depends on where the parts really are, never on
-- whatever pivot convention (or lack of one) the original asset happened
-- to be authored with.
-- True only for an ordinary finite number — false for NaN (x ~= x is Lua's
-- classic NaN test) and +-infinity. A defensive guard: a single descendant
-- BasePart with a corrupted CFrame or Size baked into the ORIGINAL Toolbox
-- asset (not caused by anything this script does) could silently poison
-- this whole function's min/max with NaN — math.min/math.max with a NaN
-- operand doesn't error, it just quietly produces garbage. That's guarded
-- against here even though it turned out NOT to be the actual explanation
-- for the "riesiges Brainrot am Himmel" reports (see scaleModelAround's
-- comment below for what really was) — worth keeping regardless, since a
-- future badly-authored asset could still trip this exact failure mode.
local function isFiniteNumber(n)
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Returns (center, size) as Vector3s, or nil if the model has no BaseParts.
local function computeWorldAABB(model)
	local minPoint, maxPoint

	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local cf = part.CFrame
			local half = part.Size / 2

			-- Skip (not crash on) a part whose own CFrame/Size is already
			-- garbage, instead of letting it poison the whole model's
			-- measurement — see isFiniteNumber's comment above.
			if
				not (
					isFiniteNumber(cf.X)
					and isFiniteNumber(cf.Y)
					and isFiniteNumber(cf.Z)
					and isFiniteNumber(half.X)
					and isFiniteNumber(half.Y)
					and isFiniteNumber(half.Z)
				)
			then
				warn(
					"[CreatureModelDisplay] Skipping "
						.. part:GetFullName()
						.. " — its CFrame/Size contains NaN or infinity (a corrupted part baked into the original model), so it can't be measured."
				)
			else
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = (cf * CFrame.new(half.X * sx, half.Y * sy, half.Z * sz)).Position
						if not minPoint then
							minPoint, maxPoint = corner, corner
						else
							minPoint = Vector3.new(
								math.min(minPoint.X, corner.X),
								math.min(minPoint.Y, corner.Y),
								math.min(minPoint.Z, corner.Z)
							)
							maxPoint = Vector3.new(
								math.max(maxPoint.X, corner.X),
								math.max(maxPoint.Y, corner.Y),
								math.max(maxPoint.Z, corner.Z)
							)
						end
					end
				end
			end
			end
		end
	end

	if not minPoint then
		return nil, nil
	end

	return (minPoint + maxPoint) / 2, (maxPoint - minPoint)
end

-- Rigidly rotates EVERY BasePart in `model` by `rotation` (a pure-rotation
-- CFrame), pivoting around world-space point `center` — i.e. every part
-- keeps its position/orientation RELATIVE TO EVERY OTHER PART exactly the
-- same, the whole assembly just turns in place around `center`. This is
-- the same standard "rotate point p around center C by R" transform
-- (`newPos = C + R*(p - C)`), just applied directly to every part instead
-- of going through Model:PivotTo() (which, per computeWorldAABB's comment
-- above, can't be trusted to rotate around the point we actually want).
local function rotateModelAround(model, center, rotation)
	local delta = CFrame.new(center) * rotation * CFrame.new(-center)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CFrame = delta * part.CFrame
		end
	end
end

-- Translates EVERY BasePart in `model` by the same world-space offset —
-- moves the whole assembly without touching orientation or relative
-- positions at all.
local function translateModel(model, offset)
	local delta = CFrame.new(offset)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CFrame = delta * part.CFrame
		end
	end
end

-- Manually scales EVERY BasePart in `model` by `factor`, around world-space
-- point `center` — replaces Model:ScaleTo(), which turned out to be the
-- ACTUAL root cause of "riesiges Brainrot am Himmel", not the scale-factor
-- math (that part was already fixed and confirmed correct via logging).
-- A handful of creatures (e.g. "Orcalero Orcala") have Bones for skinned-
-- mesh animation (see their "Anims"/"Mesh > Bone" structure in Studio) —
-- and Model:ScaleTo() on a model with Bones is a known-unreliable Roblox
-- API: instead of a clean Nx scale, it can leave some descendant at a wildly
-- wrong position (a Studio Output capture showed a properly-computed,
-- already-sane factor around 0.87 for Orcalero Orcala, yet the model
-- measured ~870-1785 studs afterward — a ~164x blowup ScaleTo introduced
-- entirely on its own). Every OTHER Roblox model-level API this file
-- touches (GetBoundingBox/GetPivot/PivotTo) already turned out to have
-- similar hidden assumptions that don't hold for every Toolbox asset — see
-- computeWorldAABB and rotateModelAround's comments above — so ScaleTo
-- gets the exact same treatment: replaced with plain per-part Size/CFrame
-- math that only ever depends on numbers this script itself computed.
-- Same "rotate point p around center C" shape as rotateModelAround, just
-- scaling the offset instead of rotating it, plus resizing each part.
local function scaleModelAround(model, center, factor)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local rotationOnly = part.CFrame - part.CFrame.Position
			local newPosition = center + (part.Position - center) * factor
			part.Size = part.Size * factor
			part.CFrame = rotationOnly + newPosition
		end
	end
end

-- Clones, scales, and positions a real creature model to stand at a given
-- spot. `tileTopCFrame` is the CFrame right at the surface the model should
-- stand on (no vertical offset applied yet). `heightStuds` is how tall
-- (studs) to scale the model to, regardless of its original authored size.
-- `yRotationDegrees` lets each creature be turned to face the right way —
-- every asset has its own idea of "forward" baked in, so there's no way to
-- guess the correct rotation automatically; dial it in per-creature by eye
-- in Studio via GameConfig.Creatures[].ModelYRotation.
-- `pitchDegrees`/`rollDegrees` correct a model that isn't even standing
-- upright to begin with (tips it around X/Z instead of just spinning it
-- around Y) — see GameConfig.Base.ModelDefaultPitchDegrees/
-- ModelDefaultRollDegrees.
-- `debugSlotIndex`, if given, is only used when a "/pitch cycle", "/pitch
-- cycleroll", or "/yaw cycle" test is active (see SetDebugCycle/
-- SetDebugYawCycle above) — it picks which candidate value THIS particular
-- pedestal gets, so different pedestals in the same base can show
-- different candidates side by side.
-- Returns (model, usedPitch, usedRoll, usedYaw) on success — the used*
-- values are the ACTUAL values this call ended up using (helpful when a
-- debug override/cycle is active and the caller wants to label the
-- pedestal with them) — or nil on failure (no matching model, or the
-- creature has no model yet).
function CreatureModelDisplay.Spawn(creatureName, tileTopCFrame, heightStuds, yRotationDegrees, pitchDegrees, rollDegrees, debugSlotIndex)
	local template = CreatureModelDisplay.GetTemplate(creatureName)
	if not template then
		return nil
	end

	local model = template:Clone()

	-- Every part is purely decorative: anchored (it never needs to move on
	-- its own), and no collision/query/touch so it can never block a
	-- ProximityPrompt, clicking, or an invisible hitbox's own Touched
	-- detection.
	--
	-- Also softens any part still using Neon material (on request, "Farben
	-- ... zu kräftig / Boom-Effekt zu stark" — confirmed via a before/after
	-- screenshot comparison that switching the map boundary wall away from
	-- Neon made basically no visible difference to how bright the base
	-- pedestal creatures looked, which rules out that wall/Bloom-bleed
	-- theory and points at these models' OWN baked-in Neon parts instead —
	-- see this file's header comment for why nothing here ever touched
	-- Material/Color before now). Neon carries a forced self-illumination in
	-- Roblox that ignores actual scene lighting entirely, which is exactly
	-- the "glows regardless of anything else" look in the screenshots.
	-- Switched to SmoothPlastic (a normal, lit-by-the-scene material) plus a
	-- 20% blend toward white, same softening amount as buildStationPart's
	-- pad / the pedestal fallback ball got earlier. ONLY parts that were
	-- actually Neon are touched — a model using MeshPart textures/
	-- SurfaceAppearance for its real look is left completely alone, so this
	-- can't break an intentionally-textured creature.
	--
	-- Runs for EVERY caller of Spawn — both BaseService's base pedestals AND
	-- TowerGenerator's tower claim-spot stands — since both share this one
	-- function; there's no way to soften only the base copy without
	-- duplicating this whole file. Tell me if the claim-spot stands in the
	-- tower should actually stay at full Neon brightness instead (e.g. to
	-- stay eye-catching from a distance) and this can be split.
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false

			if part.Material == Enum.Material.Neon then
				part.Material = Enum.Material.SmoothPlastic
				part.Color = part.Color:Lerp(Color3.new(1, 1, 1), 0.2)
			end
		end
	end

	-- The live "/pitch" debug override/cycle (see above), when set, WINS
	-- over this specific creature's normal pitch/roll — that's what makes
	-- it useful for fast trial-and-error: type "/pitch 90 0", RefreshBase,
	-- look, repeat, without ever touching GameConfig. A cycle takes
	-- priority over a plain override (SetDebugOverride/SetDebugCycle
	-- already clear each other, so in practice only one is ever set) and
	-- picks this pedestal's candidate by its slot index, wrapping around if
	-- there are more pedestals than candidates.
	local effectivePitch, effectiveRoll
	if debugCycleValues and debugSlotIndex then
		local entry = debugCycleValues[((debugSlotIndex - 1) % #debugCycleValues) + 1]
		effectivePitch = entry.Pitch
		effectiveRoll = entry.Roll
	else
		effectivePitch = (debugOverridePitch ~= nil) and debugOverridePitch or (pitchDegrees or 0)
		effectiveRoll = (debugOverrideRoll ~= nil) and debugOverrideRoll or (rollDegrees or 0)
	end

	-- Same idea for yaw (facing direction) — a separate override/cycle from
	-- pitch/roll above, see SetDebugYawOverride/SetDebugYawCycle.
	local effectiveYaw
	if debugYawCycleValues and debugSlotIndex then
		effectiveYaw = debugYawCycleValues[((debugSlotIndex - 1) % #debugYawCycleValues) + 1]
	elseif debugOverrideYaw ~= nil then
		effectiveYaw = debugOverrideYaw
	else
		effectiveYaw = yRotationDegrees or 0
	end

	-- Everything below measures/rotates/moves the model by hand (see
	-- computeWorldAABB/rotateModelAround/translateModel above) instead of
	-- using Model:GetBoundingBox()/GetPivot()/PivotTo() — those turned out
	-- to silently key off a model's PrimaryPart (or an explicit custom
	-- pivot some Toolbox creators set), which has nothing to do with how
	-- the model actually looks. Working from real part corners means the
	-- result is only ever determined by the model's actual geometry.
	local rawCenter, rawSize = computeWorldAABB(model)
	if not rawCenter then
		warn("[CreatureModelDisplay] " .. creatureName .. "'s model has no BaseParts — nothing to display")
		return nil
	end

	-- ONE-TIME diagnostic (per creature name) showing the model's RAW size
	-- (before any rotation/scaling) on all 3 axes, and which pitch/roll/
	-- yRotation values this call actually received. Check Studio's Output
	-- window (Fenster -> Output) if a creature still looks wrong.
	if not debugLoggedNames[creatureName] then
		debugLoggedNames[creatureName] = true
		print(
			string.format(
				"[CreatureModelDisplay] %s | raw size: X=%.1f Y=%.1f Z=%.1f | received pitch=%s roll=%s yaw=%s",
				creatureName,
				rawSize.X,
				rawSize.Y,
				rawSize.Z,
				tostring(effectivePitch),
				tostring(effectiveRoll),
				tostring(effectiveYaw)
			)
		)
	end

	-- Single combined rotation: the tile's own facing (plots are arranged
	-- radially around the tower, so tileTopCFrame is basically never
	-- "unrotated"), THEN the per-creature yaw spin within that facing,
	-- composed with the pitch/roll "stand it upright" correction applied in
	-- the model's OWN original local axes (so it fixes the model's inherent
	-- tilt before the whole thing gets turned to face outward). Applied
	-- once, rigidly, around the model's own raw center — see
	-- rotateModelAround's comment for why that's safe.
	local finalRotation = tileTopCFrame.Rotation
		* CFrame.Angles(0, math.rad(effectiveYaw), 0)
		* CFrame.Angles(math.rad(effectivePitch), 0, math.rad(effectiveRoll))
	rotateModelAround(model, rawCenter, finalRotation)

	-- Scale to a consistent showcase size regardless of whatever size the
	-- original asset was authored at — a Toolbox model could be anywhere
	-- from 1 stud to 100.
	--
	-- ROOT CAUSE of the "riesiges Brainrot am Himmel" report — this took TWO
	-- attempts to actually find:
	--
	-- Attempt 1 (WRONG lead, but a real bug worth keeping fixed): this used
	-- to scale by HEIGHT alone (heightStuds / rotatedSize.Y). Model:
	-- ScaleTo() scales ALL THREE axes by that same one factor — so for a
	-- creature naturally wider/longer than tall (e.g. "Orcalero Orcala", an
	-- orca-shaped model measured at raw X=5.3 Y=6.3 Z=10.9), scaling by
	-- height alone wanted 1.5x for the 6.3-stud height, and that SAME 1.5x
	-- also stretched the 10.9-stud length to ~16.5 studs. Fixed by scaling
	-- from the LARGEST of the three raw dimensions instead — every creature
	-- fits inside a heightStuds-sized cube however it's proportioned. This
	-- fix is correct and stays, but a Studio Output log capture afterward
	-- showed it WASN'T the actual cause of the worst reports: with this fix
	-- alone, "Orcalero Orcala" still measured ~870-1785 studs after
	-- scaling, despite the computed factor itself being a perfectly sane
	-- ~0.87 (a proper SHRINK, not a blow-up).
	--
	-- Attempt 2 (the REAL cause): Model:ScaleTo() itself. A handful of
	-- creatures (Orcalero Orcala included) have Bones for skinned-mesh
	-- animation (see their "Mesh > Bone" structure in Studio), and Model:
	-- ScaleTo() on a model with Bones is a known-unreliable Roblox API —
	-- instead of a clean Nx scale, it can leave some descendant at a wildly
	-- wrong position, which is exactly what turned a proper ~0.87x shrink
	-- into a ~164x blowup ScaleTo introduced entirely on its own (with no
	-- error — Roblox just silently produced garbage geometry). Every OTHER
	-- Roblox model-level API this file touches (GetBoundingBox/GetPivot/
	-- PivotTo) already turned out to have similar hidden assumptions that
	-- don't hold for every Toolbox asset — see computeWorldAABB and
	-- rotateModelAround's comments above — so ScaleTo gets the same
	-- treatment: replaced with scaleModelAround (plain per-part Size/CFrame
	-- math, see its comment above) instead of Roblox's own scaling API.
	local rotatedCenter, rotatedSize = computeWorldAABB(model)
	local largestDimension = math.max(rotatedSize.X, rotatedSize.Y, rotatedSize.Z, 0.01)
	local rawFactor = heightStuds / largestDimension
	-- Still clamped as a last-resort safety net (e.g. a model with no real
	-- geometry on any axis) — should never actually fire now that every
	-- axis is accounted for, but logged if it ever does.
	local factor = math.clamp(rawFactor, 0.1, 3)

	-- FINAL safety net: if `factor` is somehow still not an ordinary finite
	-- number here (NaN or infinity — see isFiniteNumber's comment above
	-- computeWorldAABB), math.clamp does NOT reliably catch it — NaN fails
	-- every comparison. scaleModelAround(model, center, NaN) would just
	-- turn every part's Size/Position into NaN too (silently, no error),
	-- so falling back to 1x (no scaling at all) here is far safer than
	-- risking that.
	if not isFiniteNumber(factor) or factor <= 0 then
		warn(
			"[CreatureModelDisplay] "
				.. creatureName
				.. " computed a non-finite scale factor ("
				.. tostring(factor)
				.. ") — this model has a corrupted part somewhere (see any 'Skipping ...' warning just above). Falling back to 1x."
		)
		factor = 1
	end

	if rawFactor ~= factor then
		warn(
			string.format(
				"[CreatureModelDisplay] %s hit the scale safety clamp! rotated size after pitch=%s/roll=%s/yaw=%s was X=%.2f Y=%.2f Z=%.2f (largest=%.2f) -> wanted factor=%.2f, clamped to %.2f. Check this creature's raw geometry.",
				creatureName,
				tostring(effectivePitch),
				tostring(effectiveRoll),
				tostring(effectiveYaw),
				rotatedSize.X,
				rotatedSize.Y,
				rotatedSize.Z,
				largestDimension,
				rawFactor,
				factor
			)
		)
	end

	scaleModelAround(model, rotatedCenter, factor)

	-- scaleModelAround scales around `rotatedCenter`, which was measured
	-- BEFORE scaling — so the model's true center may have drifted very
	-- slightly (floating-point rounding only, not the wild drift Model:
	-- GetPivot() was prone to). Re-measure fresh rather than assume, then
	-- do a plain translation (no more rotation needed) to land it exactly
	-- on the tile.
	local finalCenter, finalSize = computeWorldAABB(model)
	local targetPosition = tileTopCFrame.Position + Vector3.new(0, finalSize.Y / 2 + 0.3, 0)
	translateModel(model, targetPosition - finalCenter)

	-- ONE-TIME diagnostic (per creature name, same convention as the raw-size
	-- print above) showing the FINAL size AFTER scaling — added specifically
	-- to check whether our own math is actually producing a normal size (in
	-- which case a still-giant-looking creature is a Roblox rendering quirk
	-- with THIS model, e.g. a skinned/animated MeshPart whose Size property
	-- doesn't match its true animated visual extent — nothing left to fix in
	-- this script) or whether the math itself is still wrong somehow (in
	-- which case this number will be huge too, and that's the real lead).
	if not debugLoggedNames["FINAL_" .. creatureName] then
		debugLoggedNames["FINAL_" .. creatureName] = true
		print(
			string.format(
				"[CreatureModelDisplay] %s | FINAL size after scaling: X=%.1f Y=%.1f Z=%.1f (target was %.1f)",
				creatureName,
				finalSize.X,
				finalSize.Y,
				finalSize.Z,
				heightStuds
			)
		)
	end

	-- Pulsing rarity glow (on request, "kannst du über die Brainrots auch so
	-- einen Schimmer wie über die Spieler legen? ... nur Glitchrot und
	-- Singularity ... kann [der] Glow Effekt auch pulsieren?") — see
	-- addRarityGlow's own comment above. No-ops instantly for every other
	-- rarity, so this is a cheap no-op for the other ~85 creatures.
	addRarityGlow(model, creatureRarityByName[creatureName])

	return model, effectivePitch, effectiveRoll, effectiveYaw
end

-- === Continuous "always face the owner" rotation =========================
--
-- Spawn above only sets a STATIC yaw (from GameConfig, mirrored left/right —
-- see BaseService's "mirror" comment) baked in once and never touched again.
-- That's what "die Drehung funktioniert nicht richtig" turned out to mean in
-- practice: a fixed config angle can only ever be "roughly right" for one
-- viewing spot, so from anywhere else in the base (or as the player walks
-- around) it just looks wrong. CaptureRigidPose/RotateToFace below replace
-- that with a live look-at: BaseService calls CaptureRigidPose once, right
-- after Spawn, then calls RotateToFace every tick with the owner's current
-- position, and the model keeps turning to face them.
--
-- [model] = { center=Vector3, tileTopCFrame=CFrame, pitchRad=number,
-- rollRad=number, yawOffsetDeg=number, parts={ {part=BasePart, localCFrame=CFrame}, ... } }
-- `parts` is captured ONCE, right after Spawn finishes (i.e. AFTER
-- scaleModelAround has already resized everything) — RotateToFace only ever
-- re-applies a fresh rigid rotation to these cached offsets, it never
-- re-measures the AABB or touches .Size again, so it's cheap enough to call
-- every tick for every pedestal. Cleared automatically when the model is
-- destroyed (RefreshBase throwing away the old Pedestals folder) so this
-- can never leak entries for a base that no longer exists.
local rigidPoses = {}

-- Live debug override for the calibration correction below — separate
-- values for the LEFT (mirror > 0) and RIGHT (mirror < 0) pedestal columns,
-- set via "/faceoffset <left> <right>" (see init.server.lua). Needed
-- because the correction turned out NOT to be a single constant: the two
-- mirrored columns needed different values (confirmed in-game) — most
-- likely because the old "negate the yaw to mirror it" trick (see
-- BaseService's "mirror" comment) only produces a truly mirrored facing
-- when the raw asset's own front axis lines up with Roblox's own -Z
-- convention exactly, which isn't reliably true across a whole imported
-- creature pack. nil (the default) means "use this side's
-- DEFAULT_FACE_CORRECTION_*_DEG below" — still here so a future creature
-- pack (or a model with a different front-axis quirk) can be re-tuned live
-- the same way, without needing another code round-trip.
local debugFaceOffsetLeft = nil
local debugFaceOffsetRight = nil

-- Confirmed correct in-game via "/faceoffset 90 270" — see the
-- debugFaceOffset comment above for why left/right need different values.
local DEFAULT_FACE_CORRECTION_LEFT_DEG = 90
local DEFAULT_FACE_CORRECTION_RIGHT_DEG = 270

-- Sets the live "/faceoffset" preview — see debugFaceOffsetLeft/Right
-- above. Pass nil for a side to leave it on the default.
function CreatureModelDisplay.SetDebugFaceOffset(leftDegrees, rightDegrees)
	debugFaceOffsetLeft = leftDegrees
	debugFaceOffsetRight = rightDegrees
end

function CreatureModelDisplay.ClearDebugFaceOffset()
	debugFaceOffsetLeft = nil
	debugFaceOffsetRight = nil
end

function CreatureModelDisplay.IsFaceOffsetDebugActive()
	return debugFaceOffsetLeft ~= nil or debugFaceOffsetRight ~= nil
end

-- Converts a horizontal world-space direction (dx, dz) into the same
-- degrees convention CFrame.Angles(0, math.rad(yaw), 0) uses for its yaw
-- parameter — i.e. CFrame.Angles(0, math.rad(headingDegrees(dx, dz)), 0)
-- has a LookVector pointing along (dx, 0, dz) (normalized). Derived from
-- Roblox's own CFrame.Angles(0, ry, 0).LookVector == (-sin(ry), 0, -cos(ry)).
local function headingDegrees(dx, dz)
	return math.deg(math.atan2(-dx, -dz))
end

-- Remembers a just-Spawn'd model's rigid-body pose so RotateToFace can
-- cheaply re-orient it later toward a live target instead of a fixed angle.
--
-- `center` is the WORLD X/Z the model was placed at (its Y doesn't matter —
-- every re-orientation here is a pure Y-axis/yaw rotation, so only the
-- horizontal position of the pivot matters; passing tileTopCFrame.Position
-- is exactly right, since that's the X/Z Spawn already translated the model
-- onto). `referenceYawDegrees` is the SAME yRotationDegrees value Spawn was
-- called with — the static, per-creature-tuned angle that makes it face
-- "inward" at rest. `referenceLookAtWorld` is a world point that static pose
-- ACTUALLY faces (e.g. straight across the carpet from this tile) — from
-- those two, this works out the constant angular offset between "yaw value"
-- and "real-world compass heading" for THIS specific model, without ever
-- needing to know which local axis the raw mesh calls "front". `mirror`
-- (positive = left column, negative = right column — same sign BaseService
-- itself uses) picks which side's DEFAULT_FACE_CORRECTION_*_DEG/debug
-- override applies; pass nil if this call site has no left/right concept
-- (falls back to the left-side value).
function CreatureModelDisplay.CaptureRigidPose(model, center, tileTopCFrame, pitchDegrees, rollDegrees, referenceYawDegrees, referenceLookAtWorld, mirror)
	local pitchRad = math.rad(pitchDegrees)
	local rollRad = math.rad(rollDegrees)
	local referenceRotation = tileTopCFrame.Rotation
		* CFrame.Angles(0, math.rad(referenceYawDegrees), 0)
		* CFrame.Angles(pitchRad, 0, rollRad)
	local referencePivot = CFrame.new(center) * referenceRotation

	local parts = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(parts, { part = part, localCFrame = referencePivot:ToObjectSpace(part.CFrame) })
		end
	end

	local dx0 = referenceLookAtWorld.X - center.X
	local dz0 = referenceLookAtWorld.Z - center.Z
	local referenceHeadingDeg = referenceYawDegrees
	if math.abs(dx0) > 0.001 or math.abs(dz0) > 0.001 then
		referenceHeadingDeg = headingDegrees(dx0, dz0)
	end

	local isRightSide = mirror ~= nil and mirror < 0
	local correctionDeg = isRightSide and debugFaceOffsetRight or debugFaceOffsetLeft
	if correctionDeg == nil then
		correctionDeg = isRightSide and DEFAULT_FACE_CORRECTION_RIGHT_DEG or DEFAULT_FACE_CORRECTION_LEFT_DEG
	end

	rigidPoses[model] = {
		center = center,
		tileTopCFrame = tileTopCFrame,
		pitchRad = pitchRad,
		rollRad = rollRad,
		yawOffsetDeg = referenceHeadingDeg - referenceYawDegrees + correctionDeg,
		parts = parts,
	}

	model.Destroying:Connect(function()
		rigidPoses[model] = nil
	end)
end

-- Re-orients a model (previously Spawn'd + CaptureRigidPose'd) to face
-- `lookAtWorldPosition` — cheap enough to call every tick for every
-- pedestal, since it only re-applies the cached per-part offsets around a
-- fixed pivot, never re-measuring or re-scaling anything. No-op if this
-- model was never captured (e.g. it's still the fallback placeholder ball).
function CreatureModelDisplay.RotateToFace(model, lookAtWorldPosition)
	local pose = rigidPoses[model]
	if not pose then
		return
	end

	local dx = lookAtWorldPosition.X - pose.center.X
	local dz = lookAtWorldPosition.Z - pose.center.Z
	if math.abs(dx) < 0.001 and math.abs(dz) < 0.001 then
		return -- looker is standing right on top of the pivot — keep the current facing rather than spin on a ~0 direction
	end

	local targetYawDeg = headingDegrees(dx, dz) - pose.yawOffsetDeg
	local newRotation = pose.tileTopCFrame.Rotation
		* CFrame.Angles(0, math.rad(targetYawDeg), 0)
		* CFrame.Angles(pose.pitchRad, 0, pose.rollRad)
	local newPivot = CFrame.new(pose.center) * newRotation

	for _, entry in ipairs(pose.parts) do
		entry.part.CFrame = newPivot * entry.localCFrame
	end
end

return CreatureModelDisplay
