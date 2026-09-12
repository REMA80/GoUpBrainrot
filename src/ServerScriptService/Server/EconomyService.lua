--[[
	EconomyService.lua
	Owns jump-power application, cash multiplier math, passive income, the
	jump-upgrade purchase flow, and the rebirth/prestige reset.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local EconomyService = {}

local PlayerDataManager
local CreatureService
local MonetizationService
local RebirthCosmeticsService
local BaseService
local EventService
local LeaderboardService
local AntiCheatReportService
local remotesFolder

-- [player] = os.time() this player's temporary Glücksrad "2x Cash" prize
-- expires (see GrantTemporaryCashMultiplier/HasTemporaryCashMultiplier
-- below, and GameConfig.WheelOfFortune's "DoubleCash" prize type).
-- Deliberately in-memory only, NOT persisted — same reasoning as
-- ShopService's Slap Hand cooldown: a short-lived bonus doesn't need to
-- survive a rejoin, unlike the wheel's own spin cooldown (see
-- PlayerDataManager's LastWheelSpinAt, which IS persisted).
local doubleCashBuffUntil = {}

-- [player] = 0..1 fraction, this player's own personal "Sprunghöhe"
-- comfort preference, on request ("für jeden Spieler eigens einstellbar,
-- aber nur mit dem Fortschritt den er auch gekauft hat"): 0 = the absolute
-- floor (GameConfig.JumpTiers[1].JumpPower, the very first, un-upgraded
-- tier), 1 = this player's own currently EARNED ceiling (whatever their
-- purchased JumpPoints computes to right now) — NEVER higher than that, so
-- this can only ever make someone jump LOWER than what they've already
-- bought, never higher. Missing/nil means "1" (full earned height), so a
-- player who never touches this new control behaves exactly as before.
-- Deliberately in-memory only, NOT persisted (on request: "immer zurück auf
-- Maximum" rather than remembered across sessions) — reset to nil (=1, full
-- height) on every Rebirth too (see Rebirth below), since a fresh
-- JumpPoints=0 curve makes an old fraction from the previous "life"
-- meaningless anyway. See SetJumpHeightFraction/ApplyJumpPower below.
local jumpHeightFraction = {}

-- Anti-cheat floor-skip plausibility tracking (see GameConfig.AntiCheat's own
-- long comment for the full design). [player] = { Floor = number, Time =
-- os.clock() this floor was last legitimately touched/accepted } —
-- deliberately in-memory only (os.clock() isn't even meaningful across a
-- server restart), same "doesn't need to survive a rejoin" reasoning as
-- doubleCashBuffUntil above. Updated on every Detector touch (see
-- OnFloorReached below) AND explicitly reset by FastTravelService.Teleport,
-- so a legitimate paid teleport is never mistaken for an impossible jump.
local lastFloorProgress = {}

-- [player] = how many implausible floor-skips this player has triggered THIS
-- SESSION (see isFloorSkipPlausible/OnFloorReached below) — resets to
-- nothing on rejoin, same spirit as every other in-memory-only table here.
-- Purely for the server-side warn() log's "(flag #N this session)" counter
-- (server-owner visibility only) — on request, this no longer drives any
-- player-facing warning; a real player could trigger this honestly (e.g. a
-- Rebirth immediately followed by a Jump-Upgrade purchase) and kept seeing
-- an accusatory-feeling message for entirely legitimate play.
local floorSkipFlagCount = {}

-- [player] = current additive Cash-multiplier fraction (e.g. 0.15) from
-- real Roblox friends present in this same server (see GameConfig.
-- FriendBoost, RecalculateFriendBoosts below, and its use inside
-- getCashMultiplierFactor). Deliberately in-memory only, recomputed on
-- every player join/leave rather than persisted or checked per-tick — see
-- RecalculateFriendBoosts' own comment for why that's both correct
-- (friends can join/leave the SERVER, not just the game) and cheap.
local friendBoostFraction = {}

-- Recomputes EVERY currently-connected player's friendBoostFraction from
-- scratch — on request ("10% Cash Boost solange der Freund oder die
-- Freunde da sind ... echte Roblox-Freunde im selben Server"). Called from
-- init.server.lua on Players.PlayerAdded/PlayerRemoving (a friend joining
-- or leaving the SERVER is exactly when this can change for everyone else
-- still in it) — deliberately NOT called from the passive-income tick or
-- anywhere else per-player, since Player:IsFriendsWith is a real API call;
-- with GameConfig.Base.MaxPlayers capped at 4 this is at most 4x3 = 12
-- checks per join/leave, so no throttling concerns, but there's still no
-- reason to repeat that work every payout tick when it can only actually
-- change on join/leave.
-- `excludePlayer` (optional) — used by init.server.lua's PlayerRemoving
-- handler: during that event the leaving player can still briefly show up
-- in Players:GetPlayers() themselves, so passing them here keeps everyone
-- ELSE'S recalculation from momentarily still counting a friend who's
-- already on their way out.
function EconomyService.RecalculateFriendBoosts(excludePlayer)
	local boost = GameConfig.FriendBoost
	local players = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= excludePlayer then
			table.insert(players, player)
		end
	end

	for _, player in ipairs(players) do
		local friendCount = 0
		for _, other in ipairs(players) do
			if other ~= player then
				-- pcall'd — IsFriendsWith can throw if Roblox's friend
				-- service hiccups; a failed check should just not count as
				-- a friend, never error out and skip every other player's
				-- recalculation.
				local ok, isFriend = pcall(function()
					return player:IsFriendsWith(other.UserId)
				end)
				if ok and isFriend then
					friendCount += 1
				end
			end
		end

		if friendCount > 0 then
			friendBoostFraction[player] = boost.FirstFriendBonus + (friendCount - 1) * boost.AdditionalFriendBonus
		else
			friendBoostFraction[player] = nil
		end
	end
end

-- Called from init.server.lua's PlayerRemoving, BEFORE
-- RecalculateFriendBoosts runs again for whoever's left — same "clear this
-- player's own entry" pattern as ReleaseJumpHeightPreference/
-- ReleaseFloorProgressTracking below.
function EconomyService.ReleaseFriendBoost(player)
	friendBoostFraction[player] = nil
end

function EconomyService.Init(deps)
	PlayerDataManager = deps.PlayerDataManager
	CreatureService = deps.CreatureService
	MonetizationService = deps.MonetizationService
	RebirthCosmeticsService = deps.RebirthCosmeticsService
	BaseService = deps.BaseService
	EventService = deps.EventService
	LeaderboardService = deps.LeaderboardService
	AntiCheatReportService = deps.AntiCheatReportService
	remotesFolder = deps.Remotes
end

-- === Offline earnings ("Willkommen zurück"-Popup) =============================
-- [player] = Cash amount computed by ComputeOfflineEarnings below, still
-- sitting unclaimed until ClaimOfflineEarnings or DoubleOfflineEarnings pays
-- it out. Deliberately in-memory only (same reasoning as doubleCashBuffUntil
-- above) — if a player disconnects before ever claiming it, the NEXT join's
-- ComputeOfflineEarnings just recomputes fresh from data.LastSeenAt, so
-- nothing is lost, it just gets folded into the next popup's total instead.
local pendingOfflineEarnings = {}

-- Called once, right after a player's data is loaded and their base/pedestals
-- exist (see init.server.lua's PlayerAdded, right after the first
-- FireDataUpdated — so GetCreatureCashRates below already sees their real
-- CreatureLog). Works out how long they were away since data.LastSeenAt (set
-- by PlayerDataManager.Save every time it runs), converts that into Cash at
-- GameConfig.OfflineEarnings.RateFraction of their current Cash/sec rate, and
-- — if it's worth showing at all — stashes it in pendingOfflineEarnings and
-- fires ShowOfflineEarnings so the client can display the popup (see
-- UIBuilder.ShowOfflineEarnings / init.client.lua's listener).
--
-- data.LastSeenAt == 0 (a brand-new player, or an old save from before this
-- field existed — PlayerDataManager's backfill sets it to the DEFAULT_DATA
-- value of 0) deliberately shows NOTHING rather than treating "never saved"
-- as an enormous offline gap.
function EconomyService.ComputeOfflineEarnings(player)
	local cfg = GameConfig.OfflineEarnings
	if not cfg.Enabled then
		return
	end

	local data = PlayerDataManager.Get(player)
	if not data or not data.LastSeenAt or data.LastSeenAt <= 0 then
		return
	end

	local elapsedSeconds = os.time() - data.LastSeenAt
	if elapsedSeconds < cfg.MinSecondsToShow then
		return
	end

	local cappedSeconds = math.min(elapsedSeconds, cfg.MaxSeconds)
	local _, cashPerSecond = EconomyService.GetCreatureCashRates(player)
	local amount = math.floor((cashPerSecond or 0) * cappedSeconds * cfg.RateFraction + 0.5)
	if amount <= 0 then
		return
	end

	pendingOfflineEarnings[player] = amount

	if remotesFolder then
		remotesFolder.ShowOfflineEarnings:FireClient(player, {
			Amount = amount,
			OfflineSeconds = cappedSeconds,
			RatePerSecond = cashPerSecond,
			RateFraction = cfg.RateFraction,
			DoubleProductId = cfg.DoubleRobuxProduct.ProductId,
		})
	end
end

-- "Abholen" button — pays out whatever's currently pending for `player` at
-- face value (no doubling) and clears it. Returns the amount granted (0 if
-- nothing was pending, e.g. a stale/duplicate click after the popup already
-- closed). Called from the ClaimOfflineEarnings RemoteFunction, see
-- init.server.lua.
function EconomyService.ClaimOfflineEarnings(player)
	local amount = pendingOfflineEarnings[player]
	if not amount or amount <= 0 then
		return 0
	end
	local data = PlayerDataManager.Get(player)
	if not data then
		return 0
	end

	pendingOfflineEarnings[player] = nil
	data.Cash += amount
	data.LifetimeCashEarned = (data.LifetimeCashEarned or 0) + amount
	EconomyService.FireDataUpdated(player)

	return amount
end

-- "Verdoppeln (Robux)" button — called from MonetizationService.ProcessReceipt
-- once the GameConfig.OfflineEarnings.DoubleRobuxProduct purchase is
-- confirmed. Pays out DOUBLE whatever was pending and clears it, same as
-- ClaimOfflineEarnings but at 2x — if nothing was pending anymore (e.g. the
-- player already clicked "Abholen" first, or the popup expired), this simply
-- grants nothing extra; the Robux purchase still gets marked Granted by
-- ProcessReceipt regardless (same "already-charged, nothing left to do"
-- reasoning as its other branches). Fires OfflineEarningsDoubled (not just
-- the usual FireDataUpdated) so the client can close the popup and show the
-- final doubled amount even though this resolves asynchronously, out of band
-- from any button click — same reasoning as WheelService's WheelSpinResult.
function EconomyService.DoubleOfflineEarnings(player)
	local amount = pendingOfflineEarnings[player]
	if not amount or amount <= 0 then
		return 0
	end
	local data = PlayerDataManager.Get(player)
	if not data then
		return 0
	end

	pendingOfflineEarnings[player] = nil
	local doubled = amount * 2
	data.Cash += doubled
	data.LifetimeCashEarned = (data.LifetimeCashEarned or 0) + doubled
	EconomyService.FireDataUpdated(player)

	if remotesFolder then
		remotesFolder.OfflineEarningsDoubled:FireClient(player, { Amount = doubled })
	end

	return doubled
end

-- Combined jump-tier curve: the original 10 hand-tuned Floor 1-100
-- checkpoints (GameConfig.JumpTiers, UNTOUCHED — see that table's own
-- comments) followed directly by the 10 new Prestige-Turm checkpoints
-- (GameConfig.PrestigeJumpTiers, Tier 11-20, Floor 101-120) — but ONLY while
-- GameConfig.Prestige.Enabled is true (see that field's own comment). While
-- disabled, ALL_JUMP_TIERS is just GameConfig.JumpTiers as-is: the Jump
-- Upgrade panel caps out at Tier 10 exactly like before the Prestige-Turm
-- existed, with no visible trace of Tier 11-20 anywhere — consistent with
-- TowerGenerator not building Floor 101-120 at all while disabled, so there
-- would be nowhere to use the extra jump power anyway. Built once here at
-- module load rather than duplicating GameConfig.JumpTiers into a second
-- table — the existing Jump-Upgrade purchase flow/panel below then just
-- reads from ALL_JUMP_TIERS instead of GameConfig.JumpTiers directly, and
-- transparently extends through Tier 20 with no new UI/remotes needed once
-- turned on (replaces the removed separate Tempo-Schuhe/SpeedTiers system).
local ALL_JUMP_TIERS = {}
for _, tier in ipairs(GameConfig.JumpTiers) do
	table.insert(ALL_JUMP_TIERS, tier)
end
if GameConfig.Prestige.Enabled then
	for _, tier in ipairs(GameConfig.PrestigeJumpTiers) do
		table.insert(ALL_JUMP_TIERS, tier)
	end
end

-- Total number of purchasable Sprung-points across the WHOLE curve
-- (original + Prestige tiers combined) — point 0 is ALL_JUMP_TIERS[1]'s
-- baseline, point TOTAL_JUMP_POINTS is ALL_JUMP_TIERS[#ALL_JUMP_TIERS]'s
-- (fully maxed, Tier 20). See GameConfig.JumpUpgrade's comment for the full
-- reasoning.
local TOTAL_JUMP_POINTS = (#ALL_JUMP_TIERS - 1) * GameConfig.JumpUpgrade.PointsPerTier

-- Which tier-segment `points` currently falls in, plus the 0..1 fraction of
-- the way through that segment. `lowerIndex` is always in
-- [1, #ALL_JUMP_TIERS-1] so tiers[lowerIndex+1] is always a valid anchor to
-- interpolate toward.
local function getJumpSegment(points)
	local pointsPerTier = GameConfig.JumpUpgrade.PointsPerTier
	local tierCount = #ALL_JUMP_TIERS
	points = math.clamp(points or 0, 0, TOTAL_JUMP_POINTS)

	local lowerIndex = math.floor(points / pointsPerTier) + 1
	if lowerIndex >= tierCount then
		return tierCount - 1, 1
	end
	local fraction = (points - (lowerIndex - 1) * pointsPerTier) / pointsPerTier
	return lowerIndex, fraction
end

-- Interpolated {JumpPower, Gap, TierName} at any point 0..TOTAL_JUMP_POINTS
-- along the curve anchored by ALL_JUMP_TIERS' 20 hand-tuned checkpoints — a
-- straight lerp between the two nearest anchors, so every checkpoint this
-- session already balance-tested (Tier 1 = point 0, Tier 2 = point
-- PointsPerTier, etc.) is reproduced EXACTLY, with everything between
-- smoothly graded instead of one lump jump. Gap is included for possible
-- future UI use (e.g. showing "reach"), but floor generation itself
-- (TowerGenerator) still reads the RAW anchor Gaps directly, unaffected by
-- this interpolation.
local function getJumpStatsAtPoint(points)
	local tiers = ALL_JUMP_TIERS
	local lowerIndex, fraction = getJumpSegment(points)
	local lower = tiers[lowerIndex]
	local upper = tiers[lowerIndex + 1]
	return {
		JumpPower = lower.JumpPower + (upper.JumpPower - lower.JumpPower) * fraction,
		Gap = lower.Gap + (upper.Gap - lower.Gap) * fraction,
		TierName = fraction < 1 and lower.Name or upper.Name,
	}
end

-- Cost of buying the SINGLE point right after `pointsAlready` (i.e. the
-- (pointsAlready+1)-th point overall). A geometric ramp WITHIN its tier
-- segment (GameConfig.JumpUpgrade.CostCurveRatio per point), calibrated so
-- buying an entire segment's worth of points (PointsPerTier of them) costs
-- EXACTLY that segment's ALL_JUMP_TIERS[...].Cost, times GameConfig.
-- JumpUpgrade.CostMultiplier (see that field's own long comment — keeps the
-- WHOLE grind meaningful at high Rebirth, not just early on, since Floor
-- 100's Mega-Truhe needs maxed-out JumpPower to even reach, and Floor
-- 101-120's own Cost values in GameConfig.PrestigeJumpTiers are already set
-- deliberately high on top of that).
--
-- RAW value only — because each tier segment's geometric ramp is scaled
-- independently to fit THAT segment's own total budget, the raw formula is
-- NOT monotonic across a tier boundary: the last few points of one segment
-- can cost noticeably MORE than the first few points of the next one (e.g.
-- point 59 ~$187K, then point 60 drops back down to ~$32K), reported as a
-- bug on 2026-09-09 ("+10 Sprung wird bei mehr Fortschritt günstiger").
-- getSinglePointCost below clamps this into a proper non-decreasing curve —
-- do not call this directly from anywhere else.
local function rawSinglePointCost(pointsAlready)
	local pointsPerTier = GameConfig.JumpUpgrade.PointsPerTier
	local ratio = GameConfig.JumpUpgrade.CostCurveRatio
	local tiers = ALL_JUMP_TIERS

	local segmentIndex = math.floor(pointsAlready / pointsPerTier) + 1 -- tiers[segmentIndex+1] is this segment's target
	local indexWithinSegment = pointsAlready % pointsPerTier -- 0-based

	local segmentTotalCost = tiers[segmentIndex + 1].Cost * (GameConfig.JumpUpgrade.CostMultiplier or 1)
	local firstPointCost
	if ratio == 1 then
		firstPointCost = segmentTotalCost / pointsPerTier
	else
		firstPointCost = segmentTotalCost * (ratio - 1) / (ratio ^ pointsPerTier - 1)
	end
	return firstPointCost * (ratio ^ indexWithinSegment)
end

-- Monotonicity fix ("Monotonie-Sperre") — built ONCE at module load, same
-- pattern as ALL_JUMP_TIERS above. The raw per-segment curve dips below the
-- previous segment's peak right after most tier boundaries (e.g. segment 6
-- starts at point 100 needing ~161K, but segment 5 just ended at point 99
-- costing ~1.04M) — left alone, that would mean paying LESS for the next
-- point after a big purchase, reported as a bug on 2026-09-09 ("+10 Sprung
-- wird bei mehr Fortschritt günstiger").
--
-- A first version of this fix just FROZE the price at the previous peak
-- until the raw curve climbed back past it — simple, and technically
-- monotonic (never decreasing), but at some boundaries the raw curve takes
-- a long time to catch back up: reported as a NEW bug on 2026-09-10 ("bei
-- dem Sprung Händler von 104-106 den selben Preis 1,0M", confirmed via
-- screenshot to run points 100-113, 14 purchases in a row at the identical
-- price). Every one of the 9 tier boundaries has some version of this dip,
-- just usually a much shorter one.
--
-- This version instead bridges each such dip with a smooth GEOMETRIC ramp
-- from the previous peak up to wherever the raw curve naturally exceeds it
-- again, so every point still costs strictly more than the last (still
-- monotonic) but no two consecutive purchases ever show the exact same
-- price. Total cost across the whole curve barely moves versus the old
-- freeze (~+1.7% in a spot check) — this only smooths OUT a flat plateau,
-- it doesn't raise prices beyond what the freeze already did.
local MONOTONIC_POINT_COST = {}
do
	local runningMax = 0
	local p = 0
	while p < TOTAL_JUMP_POINTS do
		local raw = rawSinglePointCost(p)
		if raw >= runningMax then
			MONOTONIC_POINT_COST[p] = raw
			runningMax = raw
			p += 1
		else
			-- Dip region: raw cost stays below the previous peak
			-- (startValue) for one or more points. Find `catchUp`, the
			-- next point (if any) whose OWN raw cost has climbed back up
			-- to/past startValue on its own — the ramp bridges evenly from
			-- startValue at `p` to that point's raw cost, geometrically,
			-- so it lands exactly back on the natural curve once it
			-- catches up, instead of ramping forever.
			local regionStart = p
			local startValue = runningMax
			local catchUp = p
			while catchUp < TOTAL_JUMP_POINTS and rawSinglePointCost(catchUp) < startValue do
				catchUp += 1
			end

			if catchUp >= TOTAL_JUMP_POINTS then
				-- Never catches up before the curve ends (shouldn't happen
				-- with this curve's shape, but stay monotonic either way).
				for i = regionStart, TOTAL_JUMP_POINTS - 1 do
					MONOTONIC_POINT_COST[i] = startValue
				end
				p = TOTAL_JUMP_POINTS
			else
				local endValue = rawSinglePointCost(catchUp)
				local steps = catchUp - regionStart + 1
				local stepRatio = (endValue / startValue) ^ (1 / steps)
				for i = 0, steps - 1 do
					MONOTONIC_POINT_COST[regionStart + i] = startValue * (stepRatio ^ i)
				end
				runningMax = MONOTONIC_POINT_COST[catchUp - 1]
				p = catchUp
			end
		end
	end
end

-- Cost of buying the SINGLE point right after `pointsAlready` (i.e. the
-- (pointsAlready+1)-th point overall) — see MONOTONIC_POINT_COST above for
-- why this is a table lookup into a pre-clamped curve rather than the raw
-- formula directly. Returns nil once fully maxed.
local function getSinglePointCost(pointsAlready)
	if pointsAlready >= TOTAL_JUMP_POINTS then
		return nil
	end
	return MONOTONIC_POINT_COST[pointsAlready]
end

-- Total cost (rounded to a whole number, Cash is always whole) to buy
-- `amount` points starting from `startPoints`, capped at TOTAL_JUMP_POINTS —
-- returns the cost AND however many points are actually purchasable (equal
-- to `amount` unless that would overshoot the max, in which case fewer).
local function getBulkCost(startPoints, amount)
	local totalCost = 0
	local pointsBought = 0
	for i = 0, amount - 1 do
		local cost = getSinglePointCost(startPoints + i)
		if not cost then
			break
		end
		totalCost += cost
		pointsBought += 1
	end
	return math.floor(totalCost + 0.5), pointsBought
end

-- Single source of truth for both the client HUD/panel (FireDataUpdated
-- below) and the physical kiosk's BillboardGui (BaseService.
-- UpdateStationLabels) — one player's current Sprung-point standing, plus a
-- cost/feasibility preview for every GameConfig.JumpUpgrade.BulkAmounts
-- option, computed from data already in memory (no extra DataStore/remote
-- round-trip needed to show prices).
function EconomyService.GetJumpUpgradeState(player)
	local data = PlayerDataManager.Get(player)
	if not data then
		return nil
	end

	local points = data.JumpPoints or 0
	local stats = getJumpStatsAtPoint(points)

	local bulkOptions = {}
	for _, amount in ipairs(GameConfig.JumpUpgrade.BulkAmounts) do
		local cost, pointsBought = getBulkCost(points, amount)
		table.insert(bulkOptions, {
			Amount = amount,
			Cost = cost,
			PointsBought = pointsBought, -- < amount only right at the cap
			Affordable = pointsBought > 0 and data.Cash >= cost,
		})
	end

	return {
		JumpPoints = points,
		MaxJumpPoints = TOTAL_JUMP_POINTS,
		JumpPower = stats.JumpPower,
		-- The earned CEILING at full 180/180 points (Sprungkraft-Anzeige
		-- ersetzt auf Wunsch die Sprung-Punkte-Anzeige im Panel/Kiosk — siehe
		-- UIBuilder.PopulateJumpUpgrade/BaseService.UpdateStationLabels — mit
		-- JumpPower/MaxJumpPower statt JumpPoints/MaxJumpPoints).
		MaxJumpPower = ALL_JUMP_TIERS[#ALL_JUMP_TIERS].JumpPower,
		TierName = stats.TierName,
		BulkOptions = bulkOptions,
	}
end

-- Deterministic 0..1 value derived purely from a string (a creature's Name).
-- Same input always produces the same output — no math.random anywhere in
-- here — so a creature's earned rate never changes across respawns, server
-- restarts, or reloads, but different creature NAMES land at different
-- points in their rarity's [MinRate, MaxRate] range. Simple polynomial
-- rolling hash (base 31, a common choice for string hashing) folded into a
-- fixed modulus so it stays a plain Lua number (no overflow/precision worry,
-- Lua numbers are doubles) before being squashed into 0..1.
local function stableFraction(str)
	local hash = 0
	for i = 1, #str do
		hash = (hash * 31 + string.byte(str, i)) % 1000000007
	end
	return (hash % 10000) / 10000 -- 0.0000 - 0.9999
end

-- The Cash/sec a single copy of `creatureName` is worth BEFORE Rebirth/
-- gamepass multipliers — a fixed point inside its rarity's [MinRate,
-- MaxRate] range (GameConfig.CreatureRarities), picked by stableFraction so
-- it's the same every time but differs between creatures sharing a rarity.
local function creatureBaseRate(creatureName, rarityDef)
	local fraction = stableFraction(creatureName)
	return rarityDef.MinRate + (rarityDef.MaxRate - rarityDef.MinRate) * fraction
end

local function findRarityDef(creatureName)
	local rarityName
	for _, def in ipairs(GameConfig.Creatures) do
		if def.Name == creatureName then
			rarityName = def.Rarity
			break
		end
	end
	return rarityName, rarityName and GameConfig.CreatureRarities[rarityName]
end

-- Exposed for the Brainrot-Dex UI (see UIBuilder's Dex panel) — the RAW
-- rarity range plus this specific creature's exact base point within it, with
-- NO Rebirth/gamepass multipliers applied, so the Dex can show "what this
-- creature is worth on its own" independent of any one player's progress.
-- Returns nil if the name isn't a known creature.
function EconomyService.GetCreatureBaseRate(creatureName)
	local rarityName, rarityDef = findRarityDef(creatureName)
	if not rarityDef then
		return nil
	end
	return {
		Rarity = rarityName,
		Min = rarityDef.MinRate,
		Max = rarityDef.MaxRate,
		Base = creatureBaseRate(creatureName, rarityDef),
	}
end

-- Combined Rebirth + gamepass + Brainrot-Dex-completion + temporary-
-- Glücksrad-buff multiplier for `player`'s Cash income RIGHT NOW — factored
-- out of GetCreatureCashRates so
-- GetCreatureRateForPlayer below (the Brainrot-Dex's per-creature preview,
-- added on request: "im Brainrot Dex ... immer der richtige Wert angezeigt
-- wird") uses the EXACT same math and can never silently drift from what a
-- creature would actually pay out if the player owned one. `data` is passed
-- in (rather than re-fetched) since every caller already has it.
local function getCashMultiplierFactor(player, data)
	local rebirthFactor = 1 + (data.Rebirths * GameConfig.Rebirth.MultiplierPerRebirth)

	local gamepassFactor = 1
	if MonetizationService then
		-- "4x Cash" (QuadCash) REPLACES "2x Cash" (DoubleCash) rather than
		-- stacking with it — someone who owns both still only gets 4x, not
		-- 8x (see GameConfig.Gamepasses.QuadCash's own comment for why).
		-- Checked first so owning QuadCash always wins regardless of
		-- whether DoubleCash is also owned.
		if MonetizationService.OwnsQuadCash(player) then
			gamepassFactor *= GameConfig.Gamepasses.QuadCash.Multiplier
		elseif MonetizationService.OwnsDoubleCash(player) then
			gamepassFactor *= GameConfig.Gamepasses.DoubleCash.Multiplier
		end
	end

	-- Brainrot-Dex completion bonus (on request, "wenn man alle rarity Normal
	-- gesammelt hat 10% Cash bekommen, genau so wie alle anderen Rarity
	-- Klassen ... als Geschenk ohne es zu bauen") — +10% (GameConfig.Dex.
	-- CompletionCashBoostPerRarity) per rarity class this player has FULLY
	-- discovered (see CreatureService.GetCompletedRarityCount / data.
	-- DiscoveredCreatures), permanent even after selling/trading every copy
	-- away. Additive, stacks cleanly with everything else here — completing
	-- all 9 rarities eventually adds up to +90%.
	if CreatureService then
		local completedRarities = CreatureService.GetCompletedRarityCount(player)
		if completedRarities > 0 then
			gamepassFactor += completedRarities * GameConfig.Dex.CompletionCashBoostPerRarity
		end
	end

	-- Glücksrad "2x Cash" prize — stacks MULTIPLICATIVELY on top of whatever
	-- gamepassFactor already is at this point (2x with DoubleCash, 4x with
	-- QuadCash, or 1x with neither — so someone with QuadCash gets 8x while
	-- the prize is active), same spot in the math as the gamepass check
	-- above. On request, the Brainrot-Dex deliberately includes this too
	-- (rather than only the permanent boosts) so its number always matches
	-- the real payout to the Cash-per-second decimal, even while a
	-- temporary buff is running.
	if EconomyService.HasTemporaryCashMultiplier(player) then
		gamepassFactor *= 2
	end

	-- Freundschafts-Boost (on request, "10% Cash Boost solange der Freund
	-- oder die Freunde da sind") — additive, same bucket as the Dex-
	-- completion bonus above, so it stacks cleanly with everything else here.
	-- See friendBoostFraction/RecalculateFriendBoosts' own comments for how
	-- this value gets computed and kept up to date.
	local friendBoost = friendBoostFraction[player]
	if friendBoost then
		gamepassFactor += friendBoost
	end

	return rebirthFactor * gamepassFactor
end

-- Exposed for the Brainrot-Dex UI (see UIBuilder's Dex panel / init.server.
-- lua's GetDiscoveredCreatures remote) — on request ("kann man das im
-- Brainrot Dex berücksichtigen, das immer der richtige Wert angezeigt
-- wird"), this is the EXACT Cash/sec ONE copy of `creatureName` would be
-- worth for `player` right now — same base point (creatureBaseRate) as
-- GetCreatureBaseRate above, but with this player's REAL current Rebirth/
-- gamepass/temporary-buff multiplier applied via the shared
-- getCashMultiplierFactor helper, so it's identical to what
-- GetCreatureCashRates would compute for this creature if it were already in
-- the player's CreatureLog. Shown for EVERY creature regardless of whether
-- this player has discovered it yet (not gated behind Discovered) — on
-- request, an unfound creature's row should already show its real number
-- instead of a generic rarity range. Returns nil if `creatureName` isn't a
-- known creature or this player has no data loaded yet.
function EconomyService.GetCreatureRateForPlayer(player, creatureName)
	local data = PlayerDataManager.Get(player)
	if not data then
		return nil
	end
	local _, rarityDef = findRarityDef(creatureName)
	if not rarityDef then
		return nil
	end
	local factor = getCashMultiplierFactor(player, data)
	local raw = creatureBaseRate(creatureName, rarityDef) * factor
	return math.max(1, math.floor(raw + 0.5))
end

function EconomyService.ApplyJumpPower(player)
	local data = PlayerDataManager.Get(player)
	if not data then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	-- The player's own earned ceiling (everything BuyJumpUpgrade/
	-- GrantJumpPoints have already paid for) stays exactly as before —
	-- `jumpHeightFraction` (see its declaration above) only ever picks a
	-- point BETWEEN the very first tier's floor and this ceiling, never
	-- above it. A fraction of 1 (the default, nothing changed) reproduces
	-- the old behaviour exactly: jumpPower == maxJumpPower.
	local maxJumpPower = getJumpStatsAtPoint(data.JumpPoints or 0).JumpPower
	local minJumpPower = GameConfig.JumpTiers[1].JumpPower
	local fraction = jumpHeightFraction[player] or 1
	local jumpPower = minJumpPower + (maxJumpPower - minJumpPower) * fraction

	humanoid.UseJumpPower = true
	humanoid.JumpPower = jumpPower
end

-- Sets this player's own "Sprunghöhe" comfort preference (see
-- jumpHeightFraction's declaration above for the full reasoning) and
-- applies it immediately. `fraction` is whatever the client's stepper sent
-- — ALWAYS clamped here server-side to [0, 1] before use, never trusted
-- as-is (a client could send anything, including a value that would make
-- someone jump HIGHER than their earned ceiling if this clamp weren't
-- here). Returns the actual fraction that ended up being used, so the
-- caller (init.server.lua's remote handler) can hand it straight back to
-- the requesting client without a second round-trip.
function EconomyService.SetJumpHeightFraction(player, fraction)
	local data = PlayerDataManager.Get(player)
	if not data then
		return nil
	end
	fraction = math.clamp(tonumber(fraction) or 1, 0, 1)
	jumpHeightFraction[player] = fraction
	EconomyService.ApplyJumpPower(player)
	EconomyService.FireDataUpdated(player)
	return fraction
end

function EconomyService.GetJumpHeightFraction(player)
	return jumpHeightFraction[player] or 1
end

-- Called from Players.PlayerRemoving (see init.server.lua) — same "each
-- service cleans its own per-player runtime state" pattern as
-- MonetizationService.Release/BaseService.ReleasePlayer/TradeService.
-- ReleasePlayer. Without this, jumpHeightFraction would keep one stale
-- entry per player who's ever joined, for the rest of the server's life.
function EconomyService.ReleaseJumpHeightPreference(player)
	jumpHeightFraction[player] = nil
end

-- Same per-player-runtime-state cleanup as ReleaseJumpHeightPreference right
-- above, for the anti-cheat tracking tables (see their own comments).
function EconomyService.ReleaseFloorProgressTracking(player)
	lastFloorProgress[player] = nil
	floorSkipFlagCount[player] = nil
end

-- Called from any LEGITIMATE, server-initiated jump straight to a floor that
-- didn't come from the player actually jumping there themselves — currently
-- only FastTravelService.Teleport (the paid Fast-Travel kiosk). Tells the
-- plausibility check below "this floor touch is trusted, reset the clock
-- here" so a real, paid teleport is never flagged as an impossible skip.
-- Ordinary climbing (including landing back on an already-touched
-- checkpoint after a death-respawn) doesn't need this — it naturally
-- re-establishes the baseline the moment the player's character touches
-- that floor's own Detector again, same as any other floor.
function EconomyService.ResetFloorProgressBaseline(player, floorIndex)
	lastFloorProgress[player] = { Floor = floorIndex, Time = os.clock() }
end

-- See GameConfig.AntiCheat's long comment for the full design reasoning.
-- Returns true (permissive) if there's no baseline yet at all — that's an
-- expected, harmless gap right after a fresh join, before this player's
-- character has touched even Floor 1's own Detector once; being permissive
-- here can never grant more than an ordinary climb already would.
local function isFloorSkipPlausible(player, floorIndex)
	local anticheat = GameConfig.AntiCheat
	local last = lastFloorProgress[player]
	if not last then
		return true
	end

	local floorsSkipped = floorIndex - last.Floor
	if floorsSkipped <= 0 then
		return true -- not actually a forward skip (re-touching old ground)
	end

	if floorsSkipped > anticheat.HardMaxFloorsSkip then
		return false
	end

	local elapsed = math.min(os.clock() - last.Time, anticheat.MaxBankedSeconds)
	local minPlausibleTime = floorsSkipped * anticheat.MinSecondsPerFloorSkip
	return elapsed >= minPlausibleTime
end

-- Computes every owned creature's actual Cash/sec contribution as a WHOLE
-- number (never a fraction — Cash itself only ever moves in whole numbers,
-- so a pedestal showing "+0.2/s" never visibly matched how fast Cash
-- actually grew). Rebirth and gamepass bonuses are folded in here too, so
-- the number shown on a pedestal is exactly what that creature is worth
-- right now — not just its base rarity boost.
--
-- Deliberately NOT scaled by HighestFloor (removed on request) — a
-- creature's Cash/sec depends only on its own rarity plus your Rebirth
-- count, never on how high you've currently climbed. It used to scale with
-- HighestFloor, which meant every pedestal's rate kept silently increasing
-- as you climbed (and RefreshBase rebuilt the whole base on every new floor
-- just to show the bigger number) — that's gone now, so climbing higher no
-- longer inflates creatures you already own (it still matters for BETTER
-- odds at rarer creatures near the top floors, and for reaching the
-- Floor-60 weekly event).
--
-- Every COPY of a creature counts fully — duplicates are not worth less
-- than the first one — so `rates[creatureName]` is "what ONE copy of this
-- creature is worth" (the same for every pedestal showing that name), and
-- `total` (the second return value) sums that rate once for EVERY entry in
-- CreatureLog, duplicates included. StartPassiveIncomeLoop below pays out
-- EXACTLY that total every tick — nothing else feeds Cash — so what you see
-- across all your pedestals always adds up to how fast your Cash bar
-- actually moves.
function EconomyService.GetCreatureCashRates(player)
	local data = PlayerDataManager.Get(player)
	if not data or not data.CreatureLog then
		return {}, 0
	end

	local factor = getCashMultiplierFactor(player, data)

	local rates = {} -- [creatureName] = Cash/sec worth of ONE copy of that creature
	local total = 0

	for _, creatureName in ipairs(data.CreatureLog) do
		local rate = rates[creatureName]
		if rate == nil then
			local _, rarityDef = findRarityDef(creatureName)

			if rarityDef then
				local raw = creatureBaseRate(creatureName, rarityDef) * factor
				-- Every creature you own is worth AT LEAST 1 Cash/sec once
				-- it contributes at all — no more invisible fractions.
				rate = math.max(1, math.floor(raw + 0.5))
			else
				rate = 0
			end
			rates[creatureName] = rate
		end

		-- Counted once per COPY (not once per unique name) — duplicates
		-- stack the full amount.
		total += rate
	end

	return rates, total
end

function EconomyService.FireDataUpdated(player)
	local data = PlayerDataManager.Get(player)
	if not data or not remotesFolder then
		return
	end

	-- nil once data.Rebirths reaches GameConfig.Rebirth.MaxRebirths — Costs
	-- only has that many entries, so indexing past it is just nil, not an
	-- error, and doubles as "you've hit the cap" for the client.
	local nextRebirthCost = GameConfig.Rebirth.Costs[data.Rebirths + 1]
	local jumpState = EconomyService.GetJumpUpgradeState(player)

	remotesFolder.DataUpdated:FireClient(player, {
		Cash = data.Cash,
		JumpPoints = jumpState.JumpPoints,
		MaxJumpPoints = jumpState.MaxJumpPoints,
		JumpPower = jumpState.JumpPower,
		MaxJumpPower = jumpState.MaxJumpPower,
		JumpTierName = jumpState.TierName,
		JumpBulkOptions = jumpState.BulkOptions,
		Rebirths = data.Rebirths,
		HighestFloor = data.HighestFloor,
		Creatures = data.Creatures,
		MaxRebirths = GameConfig.Rebirth.MaxRebirths,
		NextRebirthCost = nextRebirthCost,
		CanRebirth = nextRebirthCost ~= nil and data.Cash >= nextRebirthCost,
		-- Drives the HUD's event banner (see UIBuilder/init.client) so
		-- players actually know the Floor-60 Hacker / Lava window
		-- (GameConfig.Event) is open right now, instead of having to guess.
		EventActive = EventService and EventService.IsActive() or false,
		-- Drives the red "2x Cash (Xs)" HUD countdown badge (UIBuilder.
		-- UpdateDoubleCashBadge) — on request, since there was previously no
		-- way to tell the Glücksrad's 2x Cash prize was even active, let
		-- alone how much longer it lasts. An absolute os.time() timestamp
		-- (same clock doubleCashBuffUntil itself uses), or nil once the buff
		-- has actually expired — never a stale/expired timestamp — so the
		-- client can just show/hide the badge based on whether this is nil.
		DoubleCashUntil = EconomyService.HasTemporaryCashMultiplier(player) and doubleCashBuffUntil[player] or nil,
		-- Drives the new "Sprunghöhe"-Regler (UIBuilder's JumpHeightOverlay,
		-- opened from a HUD button reachable from anywhere, not just at a
		-- kiosk). JumpHeightFraction is this player's own 0..1 comfort
		-- preference (see jumpHeightFraction's declaration above);
		-- MinJumpPower is the absolute floor the slider can go down to
		-- (Tier 1's power); the EXISTING `JumpPower` field above is already
		-- this player's earned CEILING (getJumpStatsAtPoint's result) — no
		-- separate "MaxJumpPower" field needed, it's the same number the
		-- "Bouncy Boots (N)" tier row already shows. Since the Prestige-Turm
		-- rework, this same regler/panel now transparently covers Tier
		-- 11-20 (Floor 101-120) too, since JumpPoints/JumpPower are computed
		-- from the combined ALL_JUMP_TIERS curve above — no separate
		-- Prestige-specific field needed here anymore.
		JumpHeightFraction = EconomyService.GetJumpHeightFraction(player),
		MinJumpPower = GameConfig.JumpTiers[1].JumpPower,
		-- On request ("eine Anzeige wo man sieht wieviel cash/s man
		-- bekommt") — the exact same whole-number total
		-- GetCreatureCashRates already hands StartPassiveIncomeLoop to pay
		-- out every tick, just also sent to the client so the HUD can show
		-- it directly next to the Cash number (see UIBuilder/init.client's
		-- CashLabel). Never computed separately/differently from the real
		-- payout, so this can never drift from what Cash is actually doing.
		CashPerSecond = select(2, EconomyService.GetCreatureCashRates(player)),
		-- Drives the new "🤝 Freunde-Boost" HUD badge (UIBuilder's
		-- FriendBoostRow, on request "eine ui Anzeige oberhalb der Konto
		-- Anzeige") — the SAME fraction getCashMultiplierFactor already
		-- applies to this player's real Cash income (see
		-- friendBoostFraction/RecalculateFriendBoosts above), never a
		-- separately-computed number, so it can't drift from reality. 0
		-- (not nil) when no friend is present, so the client can just check
		-- `> 0` to show/hide.
		FriendBoostPercent = friendBoostFraction[player] or 0,
	})

	-- Keeps the 5 physical base-station kiosks (Jump Upgrade, Rebirth,
	-- Auto-Sammeln, 2x Cash, 1x Wiedergeburt — see BaseService.lua) showing
	-- up-to-date cost/tier
	-- text. FireDataUpdated is already the single funnel-point every
	-- Cash/Tier/Rebirth-affecting action calls, so this one hook covers all
	-- of them with no extra plumbing at each call site.
	if BaseService then
		BaseService.UpdateStationLabels(player)
	end
end

function EconomyService.OnFloorReached(player, floorIndex)
	local data = PlayerDataManager.Get(player)
	if not data then
		return
	end

	if floorIndex > data.HighestFloor then
		-- Prestige-Turm-Gate (see GameConfig.Prestige's own long comment):
		-- floors past the normal tower (Floor 101+) only count once this
		-- player has Wiedergeburt UnlockRebirths, AND only while
		-- GameConfig.Prestige.Enabled is true. This is a BACKUP check, not
		-- the primary gate — while disabled, TowerGenerator never even
		-- builds Floor 101+ in the first place (nothing to touch at all),
		-- and once enabled the Prestige floors themselves are already both
		-- physically wider (see TowerGenerator's getHorizontalOffsetForFloor's
		-- ExtraHorizontalOffset) AND require the new, deliberately expensive
		-- Tier 11-20 Sprung-Upgrades (see GameConfig.PrestigeJumpTiers) to
		-- even reach in the first place — but same "hide client-side AND
		-- re-check server-side" convention as every other gated feature in
		-- this file, in case a skilled/lucky jump gets there anyway. No kick
		-- or teleport: the touch just silently doesn't count (same "doesn't
		-- count, no punishment" shape as a rejected anti-cheat skip right
		-- below), and lastFloorProgress still updates normally further down,
		-- so nothing breaks once this player DOES reach Rebirth
		-- UnlockRebirths later and comes back.
		local prestigeLocked = floorIndex > GameConfig.Floors.Count
			and (not GameConfig.Prestige.Enabled or data.Rebirths < GameConfig.Prestige.UnlockRebirths)

		if not prestigeLocked then
			-- Anti-cheat: see GameConfig.AntiCheat's long comment for the full
			-- design. Deliberately does NOT require every floor touched in
			-- order (a strong Jump-Upgrade tier legitimately clears several at
			-- once) — only FLAGS a skip that's implausible given how much real
			-- time actually passed since the last floor touch.
			--
			-- Used to `return` here instead of granting the floor at all — on
			-- report ("der Floor Zähler zählt nicht richtig, da er glaubt man
			-- cheatet mit dem Max Jump Upgrade"), a fully-upgraded player
			-- (Ultra Sigma Boots, 370 JumpPower) can legitimately clear big
			-- gaps fast enough, or in one continuous jump-chain skip past
			-- enough Detectors, to trip this heuristic honestly — and silently
			-- refusing to update HighestFloor left their own progress counter
			-- permanently stuck below where they actually were, with no way to
			-- ever recover it (every subsequent touch from the same real
			-- position looks like the exact same "skip" again).
			--
			-- Same "never block a real player, just record it for the owner to
			-- review" shape AntiCheatReportService already uses for the
			-- claim-spot/Mega-Truhe checks (see its own header comment) — the
			-- floor still counts immediately, no more permanently-stuck
			-- counter, and every flagged case is still fully visible via the
			-- "/reports" admin command AND the server output for real-time
			-- visibility either way.
			if not isFloorSkipPlausible(player, floorIndex) then
				floorSkipFlagCount[player] = (floorSkipFlagCount[player] or 0) + 1
				local lastKnownFloor = lastFloorProgress[player] and lastFloorProgress[player].Floor or data.HighestFloor
				warn(string.format(
					"[AntiCheat] %s (UserId %d): implausible floor skip %d -> %d (flag #%d this session, floor still granted)",
					player.Name, player.UserId, lastKnownFloor, floorIndex, floorSkipFlagCount[player]
				))
				if AntiCheatReportService then
					AntiCheatReportService.RecordViolation(player, "FloorSkip", {
						FromFloor = lastKnownFloor,
						ToFloor = floorIndex,
					})
				end
			end

			data.HighestFloor = floorIndex
			-- NOTE: no BaseService.RefreshBase(player) here anymore — Cash/sec no
			-- longer scales with HighestFloor (see GetCreatureCashRates), so
			-- there's nothing about the base display that needs to change just
			-- because you climbed. This used to rebuild the whole base on every
			-- single new floor purely to show a bigger number — that's what was
			-- causing the "+X/s" rate to visibly change while climbing.
			EconomyService.FireDataUpdated(player)
		end
	end

	-- Keeps the anti-cheat baseline fresh on EVERY touch, not just ones that
	-- grant a new HighestFloor — re-touching already-reached ground (e.g.
	-- walking back down, or landing back on a checkpoint after a death-
	-- respawn) is exactly what re-establishes "the last place/time this
	-- player was legitimately seen" for the next check above.
	lastFloorProgress[player] = { Floor = floorIndex, Time = os.clock() }

	-- Hall of Fame: the very FIRST time (ever, across all this player's
	-- sessions — ReachedFloor100 is a persisted field, see
	-- PlayerDataManager) their Detector touch reaches the last floor,
	-- record them permanently in the global cross-server roster. Checked
	-- against `floorIndex` itself, not `data.HighestFloor` above, so this
	-- still fires correctly even if HighestFloor was already at Count from
	-- an earlier session (e.g. after a server restart) and they climb all
	-- the way up again — the `not data.ReachedFloor100` guard is what
	-- actually prevents a duplicate roster entry, not this comparison.
	if floorIndex >= GameConfig.Floors.Count and not data.ReachedFloor100 then
		data.ReachedFloor100 = true
		if LeaderboardService then
			LeaderboardService.RecordFloor100(player)
		end
	end
end

-- `amount` = how many Sprung-points to buy at once (see GameConfig.
-- JumpUpgrade.BulkAmounts / the Jump Upgrade panel's buttons). Buys as many
-- of the requested `amount` as fit under the max (see getBulkCost) — only
-- ever fewer, never more, and fails outright if even the very next point is
-- unaffordable or the player is already fully maxed out.
function EconomyService.BuyJumpUpgrade(player, amount)
	local data = PlayerDataManager.Get(player)
	if not data then
		return false, "No data"
	end
	amount = math.max(1, math.floor(tonumber(amount) or 1))

	local startPoints = data.JumpPoints or 0
	if startPoints >= TOTAL_JUMP_POINTS then
		return false, "Maximaler Sprung bereits erreicht"
	end

	local cost, pointsBought = getBulkCost(startPoints, amount)
	if pointsBought == 0 then
		return false, "Maximaler Sprung bereits erreicht"
	end
	if data.Cash < cost then
		return false, "Nicht genug Cash"
	end

	data.Cash -= cost
	data.JumpPoints = startPoints + pointsBought
	EconomyService.ApplyJumpPower(player)
	EconomyService.FireDataUpdated(player)
	return true, { PointsBought = pointsBought, Cost = cost, NewPoints = data.JumpPoints }
end

-- Grants `amount` Sprung-points for FREE — no Cash charged, capped at
-- TOTAL_JUMP_POINTS same as BuyJumpUpgrade. Used exclusively by
-- MonetizationService's ProcessReceipt once a Robux Developer Product
-- purchase has actually been confirmed by Roblox (the player already paid
-- with real money at that point, so this only ever ADDS points, never
-- touches Cash). Returns how many points were actually granted (may be
-- fewer than `amount` right at the cap).
function EconomyService.GrantJumpPoints(player, amount)
	local data = PlayerDataManager.Get(player)
	if not data then
		return 0
	end
	amount = math.max(0, math.floor(tonumber(amount) or 0))

	local startPoints = data.JumpPoints or 0
	local newPoints = math.min(TOTAL_JUMP_POINTS, startPoints + amount)
	data.JumpPoints = newPoints

	EconomyService.ApplyJumpPower(player)
	EconomyService.FireDataUpdated(player)
	return newPoints - startPoints
end

-- Grants `seconds` worth of the player's CURRENT total passive Cash/sec
-- income as an instant one-time Cash bonus — used by WheelService's "Cash"
-- Glücksrad prizes. Deliberately RELATIVE to the player's own current
-- income (not a flat GameConfig number) so the reward always feels
-- meaningful whether they're Floor 5 or Floor 300, without a flat number
-- ever being trivial late-game or a jackpot early-game. Counts toward
-- LifetimeCashEarned too, same as every other real Cash gain (selling a
-- creature, collecting a pedestal) — see PlayerDataManager's comment on
-- that field.
function EconomyService.GrantCashBonusSeconds(player, seconds)
	local data = PlayerDataManager.Get(player)
	if not data then
		return 0
	end
	local _, totalRate = EconomyService.GetCreatureCashRates(player)
	local bonus = math.floor(totalRate * seconds)
	data.Cash += bonus
	data.LifetimeCashEarned += bonus
	EconomyService.FireDataUpdated(player)
	return bonus
end

-- Activates (or refreshes, if one is already running) a temporary 2x
-- multiplier on ALL passive Cash income for `seconds` — used by
-- WheelService's "DoubleCash" Glücksrad prize. See doubleCashBuffUntil /
-- HasTemporaryCashMultiplier / GetCreatureCashRates above for how it's
-- actually applied. Spinning a second one before the first expires just
-- replaces the expiry time with the new one (does not stack to 4x with
-- itself — only with an owned DoubleCash gamepass).
function EconomyService.GrantTemporaryCashMultiplier(player, seconds)
	doubleCashBuffUntil[player] = os.time() + seconds
end

-- True while `player` has an active Glücksrad "2x Cash" prize running.
function EconomyService.HasTemporaryCashMultiplier(player)
	local expiresAt = doubleCashBuffUntil[player]
	return expiresAt ~= nil and os.time() < expiresAt
end

-- Shared core for both the normal (Cash-cost) Rebirth and the "1x
-- Wiedergeburt" Robux button below — `skipCostCheck` lets the Robux path
-- grant a Rebirth without ALSO requiring the in-game Cash cost (they
-- already paid with real Robux instead). MaxRebirths still caps either
-- path identically — Robux can never push a player past the intended cap.
local function performRebirth(player, skipCostCheck)
	local data = PlayerDataManager.Get(player)
	if not data then
		return false, "No data"
	end

	local cost = GameConfig.Rebirth.Costs[data.Rebirths + 1]
	if not cost then
		return false, "Max Rebirth-Stufe erreicht (" .. GameConfig.Rebirth.MaxRebirths .. ")"
	end
	if not skipCostCheck and data.Cash < cost then
		return false, "Nicht genug Cash (" .. cost .. " nötig)"
	end

	-- Paying resets Cash/JumpPoints/HighestFloor back to the start — same
	-- "real restart" a Rebirth always was, just unlocked by saving up Cash
	-- now instead of reaching Floor 60. Claimed Brainrots (CreatureLog /
	-- Creatures) are untouched, same as before. Since the Prestige-Turm
	-- rework, JumpPoints=0 also wipes any Tier 11-20 (Floor 101-120)
	-- progress along with the normal Tier 1-10 — consistent with how a
	-- Rebirth already resets everything else about the climb, and Rebirth
	-- itself stays available below GameConfig.Prestige.UnlockRebirths
	-- anyway (Rebirth 12 < MaxRebirths 15), so this can actually happen to
	-- a real player, unlike the old Tempo-Schuhe design.
	data.Cash = 0
	data.JumpPoints = 0
	data.HighestFloor = 1
	data.Rebirths += 1

	-- Same "this jump is server-driven, trust it" reset FastTravelService.
	-- Teleport already does after a paid teleport (see ResetFloorProgressBaseline's
	-- comment) — the CFrame reset a few lines below teleports the player
	-- straight back to Floor 1 too, and without this the anti-cheat's
	-- lastFloorProgress baseline would still be sitting wherever they were
	-- BEFORE the Rebirth (e.g. Floor 80+), so their very next real floor
	-- touch after a fresh Jump-Upgrade purchase (routinely clearing several
	-- floors at once right after a Rebirth) would look like an impossible
	-- Floor-1-to-many skip and get falsely rejected.
	EconomyService.ResetFloorProgressBaseline(player, 1)

	-- Back to full height (see jumpHeightFraction's declaration above, and
	-- the "immer zurück auf Maximum" decision) — an old fraction from before
	-- this Rebirth was tuned against a JumpPoints curve that no longer
	-- exists, so carrying it over would be meaningless (and, worse, could
	-- read as "my jump got weaker for no reason" right after a Rebirth).
	jumpHeightFraction[player] = nil

	EconomyService.ApplyJumpPower(player)

	if RebirthCosmeticsService then
		RebirthCosmeticsService.Apply(player)
	end

	-- Rebirths grant +1 base slot (GameConfig.Base.SlotsPerRebirth) — rebuild
	-- the player's pedestals so the newly-affordable slot appears immediately
	-- (and becomes claimable again if the base was full before).
	if BaseService then
		BaseService.RefreshBase(player)
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local floor1 = workspace:FindFirstChild("Tower") and workspace.Tower:FindFirstChild("Floor_1")
	if root and floor1 then
		root.CFrame = floor1.CFrame + Vector3.new(0, 6, 0)
	end

	-- MOVED here (used to fire right after ApplyJumpPower, BEFORE
	-- RebirthCosmeticsService/RefreshBase/the teleport above) — on request
	-- ("die Base-Kiosk-Anzeigen (Sprung-Punkte, Wiedergeburt-Preis) zeigen
	-- nach einem Rebirth manchmal noch den alten Stand, erst ein Kauf oder
	-- Cash einsammeln bringt sie zurück"). RefreshBase alone rebuilds only
	-- the Pedestals folder, never the Stations/kiosk billboards
	-- (BaseService.UpdateStationLabels, called from inside FireDataUpdated
	-- below, mutates those in place and was already correct on paper) — but
	-- firing FireDataUpdated BEFORE that Instance-heavy rebuild and the
	-- character teleport meant the kiosk billboard's freshly-set text was
	-- immediately followed by a burst of further server work in the very
	-- same tick, which could occasionally cost that particular property
	-- update its spot in what actually reaches the client before the player
	-- is already elsewhere. Firing it LAST — after every other Rebirth
	-- side-effect has fully settled — makes it the final word on this
	-- player's state for this tick instead of one update lost in the
	-- middle of several.
	EconomyService.FireDataUpdated(player)

	-- "der Stand der Rebirth stimmt aktuell nicht überein" — the Hall of
	-- Fame board otherwise only picks up a new Rebirth count on its next
	-- periodic sync (up to GameConfig.Leaderboard.SyncIntervalSeconds
	-- later, see LeaderboardService.StartPeriodicSync). A Rebirth is
	-- exactly the kind of deliberate, infrequent milestone worth pushing
	-- immediately instead of waiting.
	if LeaderboardService then
		LeaderboardService.RequestImmediateRefresh(player)
	end

	return true
end

function EconomyService.Rebirth(player)
	return performRebirth(player, false)
end

-- "1x Wiedergeburt" Robux button (GameConfig.Rebirth.RobuxProduct) — on
-- request, REPLACES the removed VIP kiosk in BaseService.buildStations.
-- Grants exactly one Rebirth, skipping the Cash-cost check (see
-- performRebirth above) since real Robux was paid instead — everything
-- else (Cash/JumpPoints/HighestFloor reset, +1 Rebirth, cosmetics, base
-- refresh, leaderboard push) is identical to a normal Cash-paid Rebirth.
-- Called from MonetizationService.ProcessReceipt once the Developer
-- Product purchase is confirmed — same "granted from ProcessReceipt, not
-- directly from a client request" pattern as GrantJumpPoints above.
function EconomyService.BuyRebirthWithRobux(player)
	return performRebirth(player, true)
end

-- NOTE: this used to pay Cash straight into data.Cash every tick. Now it
-- only accumulates each creature's earnings into ITS OWN pedestal slot
-- (data.PedestalCash[i], a parallel array to CreatureLog) — like "Steal a
-- Brainrot", nothing reaches your actual Cash total until you physically
-- walk over that Brainrot and collect it (see BaseService's Touched handler
-- on each pedestal's Display part). Cash itself no longer changes on its
-- own, so this loop doesn't call FireDataUpdated anymore either — only the
-- (much cheaper) pedestal money-label text gets updated every tick.
--
-- EXCEPTION: a player who owns the "Auto-Sammeln" gamepass (GameConfig.
-- Gamepasses.AutoCollect — bought at the kiosk that replaced Slap Hand in
-- BaseService.buildStations) skips PedestalCash/manual-collect entirely —
-- every tick's payout goes straight into Cash for them instead, and
-- FireDataUpdated IS called for them every tick so their HUD stays live.
function EconomyService.StartPassiveIncomeLoop()
	task.spawn(function()
		while true do
			-- Ticks every PayoutTickSeconds (1s by default). GetCreatureCashRates'
			-- per-creature rate is a true per-second rate, so accumulating it
			-- every 1s instead of every 3s doesn't change the total earned
			-- over time at all — it just makes the pedestal amounts grow
			-- smoothly, one visible second at a time.
			task.wait(GameConfig.Economy.PayoutTickSeconds)
			for _, player in ipairs(Players:GetPlayers()) do
				local data = PlayerDataManager.Get(player)
				if data and #data.CreatureLog > 0 then
					local rates = EconomyService.GetCreatureCashRates(player)
					data.PedestalCash = data.PedestalCash or {}

					-- "Auto-Sammeln" gamepass (on request, replacing the removed
					-- Slap Hand kiosk — "automatisch immer das Geld von den
					-- Brainrots einsammelt"): an owner skips the manual
					-- walk-over-every-pedestal step entirely. Checked ONCE per
					-- player per tick (not per creature) — MonetizationService
					-- caches ownership anyway, but there's no reason to ask
					-- twice for the same answer.
					local autoCollect = MonetizationService and MonetizationService.OwnsAutoCollect(player)
					local anyChanged = false
					local autoCollectedThisTick = 0

					for i, creatureName in ipairs(data.CreatureLog) do
						local rate = rates[creatureName]
						if rate and rate > 0 then
							local earned = rate * GameConfig.Economy.PayoutTickSeconds
							if autoCollect then
								-- Straight into Cash, never touches
								-- PedestalCash[i] at all — same end result as
								-- BaseService's Display.Touched collect handler
								-- (Cash + LifetimeCashEarned, same leaderboard
								-- notify), just automatic instead of manual.
								autoCollectedThisTick += earned
							else
								data.PedestalCash[i] = (data.PedestalCash[i] or 0) + earned
								anyChanged = true
							end
						end
					end

					if autoCollect and autoCollectedThisTick > 0 then
						data.Cash += autoCollectedThisTick
						data.LifetimeCashEarned = (data.LifetimeCashEarned or 0) + autoCollectedThisTick
						EconomyService.FireDataUpdated(player)
						if LeaderboardService then
							LeaderboardService.NotifyCashCollected(player)
						end
					elseif anyChanged and BaseService then
						BaseService.UpdateMoneyDisplay(player)
					end
				end
			end
		end
	end)
end

return EconomyService
