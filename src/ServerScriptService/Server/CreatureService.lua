--[[
	CreatureService.lua
	Handles weighted-random creature drops from pickups and the passive cash
	bonus that owned creatures grant (one bonus per unique creature owned,
	stacking additively into the player's cash multiplier).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local CreatureService = {}

local PlayerDataManager
local BaseService
local EventService
local EconomyService
local LeaderboardService
local remotesFolder
local onDataChanged -- callback, typically EconomyService.FireDataUpdated
local onCreatureClaimed -- callback, typically BaseService.RefreshBase

function CreatureService.Init(deps)
	PlayerDataManager = deps.PlayerDataManager
	BaseService = deps.BaseService
	EventService = deps.EventService
	EconomyService = deps.EconomyService
	LeaderboardService = deps.LeaderboardService
	remotesFolder = deps.Remotes
	onDataChanged = deps.OnDataChanged
	onCreatureClaimed = deps.OnCreatureClaimed
end

-- Interpolates a rarity's weight between its EarlyWeight (Floor 1) and
-- LateWeight (top floor) based on how high up the pickup is.
local function getRarityWeight(rarityDef, floorIndex)
	local floorCount = GameConfig.Floors.Count
	local t = 0
	if floorCount > 1 then
		t = (floorIndex - 1) / (floorCount - 1)
	end
	t = math.clamp(t, 0, 1)
	return rarityDef.EarlyWeight + (rarityDef.LateWeight - rarityDef.EarlyWeight) * t
end

-- EventOnly creatures (Hacker / Lava / Glitchrot / Singularity) get
-- an EXTRA shot at this separate, much bigger roll, at the very top floor,
-- during the weekly event window (GameConfig.Event) — on top of whatever
-- chance Hacker/Lava already have in the normal pool below
-- (Glitchrot/Singularity have NONE there, see NormalPoolExcluded, so this
-- event roll is their ONLY way to drop at all). WITHIN this pool, which
-- rarity you get is itself weighted by each rarity's EventWeight (see the
-- comment on GameConfig.CreatureRarities) — split evenly across however
-- many named creatures currently share that rarity, same principle
-- rollCreature below uses for the normal pool — so a 200,000-CashBoost
-- Singularity is dramatically rarer than a 400-CashBoost Hacker even
-- though both are "event-eligible", instead of being equally likely.
local function rollEventCreature(floorIndex)
	if floorIndex ~= GameConfig.Floors.Count then
		return nil
	end
	if not (EventService and EventService.IsActive()) then
		return nil
	end
	if math.random() * 100 > GameConfig.Event.DropChancePercent then
		return nil
	end

	local eventCreatures = {}
	local countByRarity = {}
	for _, def in ipairs(GameConfig.Creatures) do
		if def.EventOnly then
			table.insert(eventCreatures, def)
			countByRarity[def.Rarity] = (countByRarity[def.Rarity] or 0) + 1
		end
	end
	if #eventCreatures == 0 then
		return nil
	end

	local weights = {}
	local totalWeight = 0
	for _, def in ipairs(eventCreatures) do
		local rarityDef = GameConfig.CreatureRarities[def.Rarity]
		local w = ((rarityDef and rarityDef.EventWeight) or 1) / countByRarity[def.Rarity]
		weights[def] = w
		totalWeight += w
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, def in ipairs(eventCreatures) do
		cumulative += weights[def]
		if roll <= cumulative then
			return def
		end
	end
	return eventCreatures[#eventCreatures]
end

-- True if `def` is allowed to drop from a normal floor pickup at
-- `floorIndex` at all — NormalPoolExcluded (Glitchrot/Singularity, pure
-- event-exclusives, see the comment on rollCreature below) always
-- disqualifies it; on top of that, GameConfig.CreatureSpawn.RarityCaps (an
-- ORDERED list of {EndFloor, MaxTier} stages — currently "Normal/Gold
-- only through Floor 20", then "+ Diamond/Toxic through Floor 59, Galaxy+
-- still excluded") disqualifies anything above the first still-applicable
-- stage's MaxTier. Once floorIndex is past every stage's EndFloor, no cap
-- applies at all and this just returns true unconditionally, same as
-- before either stage existed.
local function isRarityAllowedOnFloor(def, floorIndex)
	if def.NormalPoolExcluded then
		return false
	end
	local rarityDef = GameConfig.CreatureRarities[def.Rarity]
	if not (rarityDef and rarityDef.Tier) then
		return true
	end
	for _, cap in ipairs(GameConfig.CreatureSpawn.RarityCaps) do
		if (floorIndex or 1) <= cap.EndFloor then
			return rarityDef.Tier <= cap.MaxTier
		end
	end
	return true
end

-- Prestige-Turm drop pool (Floor 101+, see GameConfig.Prestige) — on request
-- ("die Glitchrot/Singularity dort unterbringen gemischt mit Hacker Lava und
-- Galaxy"): mixes the FIVE top rarities (Galaxy/Hacker/Lava/Glitchrot/
-- Singularity) into one weighted pool, using each rarity's EventWeight (same
-- field GameConfig.CreatureRarities already carries for the weekly-event
-- roll — Galaxy got its own EventWeight added specifically for this, see
-- that table's comment). Deliberately does NOT filter out
-- NormalPoolExcluded — that flag only ever meant "never from a NORMAL floor
-- pickup", and Glitchrot/Singularity are exactly the two rarities the
-- Prestige-Turm is meant to make reachable OUTSIDE the weekly event window
-- for the first time (unlike rollEventCreature above, this isn't gated by
-- EventService.IsActive at all — it's a permanent drop pool, always active
-- once a player is actually standing on a Prestige floor). No brand-new
-- creature names needed — reuses every existing Galaxy/Hacker/Lava/
-- Glitchrot/Singularity entry in GameConfig.Creatures as-is.
local PRESTIGE_RARITIES = {
	Galaxy = true,
	Hacker = true,
	Lava = true,
	Glitchrot = true,
	Singularity = true,
}

local function rollPrestigeCreature()
	local eligible = {}
	local countByRarity = {}
	for _, def in ipairs(GameConfig.Creatures) do
		if PRESTIGE_RARITIES[def.Rarity] then
			table.insert(eligible, def)
			countByRarity[def.Rarity] = (countByRarity[def.Rarity] or 0) + 1
		end
	end
	if #eligible == 0 then
		return nil
	end

	local weights = {}
	local totalWeight = 0
	for _, def in ipairs(eligible) do
		local rarityDef = GameConfig.CreatureRarities[def.Rarity]
		local w = ((rarityDef and rarityDef.EventWeight) or 1) / countByRarity[def.Rarity]
		weights[def] = w
		totalWeight += w
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, def in ipairs(eligible) do
		cumulative += weights[def]
		if roll <= cumulative then
			return def
		end
	end
	return eligible[#eligible]
end

local function rollCreature(floorIndex)
	-- Prestige-Turm floors (Floor 101+) use their own separate pool
	-- entirely instead of the normal floor-scaled weighting below — see
	-- rollPrestigeCreature's own comment. Falls through to the normal pool
	-- only in the (should-never-happen) case that pool comes back empty.
	if floorIndex and floorIndex > GameConfig.Floors.Count then
		local prestigeDef = rollPrestigeCreature()
		if prestigeDef then
			return prestigeDef
		end
	end

	local eventDef = rollEventCreature(floorIndex)
	if eventDef then
		return eventDef
	end

	-- How many eligible-on-this-floor creatures currently share each
	-- rarity — used below to split that rarity's EarlyWeight/LateWeight
	-- EVENLY among them. Without this, every individual creature entry got
	-- the rarity's FULL weight on its own, so a rarity with more named
	-- creatures in it would silently drop MORE OFTEN overall just because
	-- it has more entries — not because it was actually made more common.
	-- This way, adding more named creatures to a rarity (see
	-- GameConfig.Creatures) only adds variety within that rarity's
	-- existing odds, never shifts the odds BETWEEN rarities.
	--
	-- isRarityAllowedOnFloor folds in both NormalPoolExcluded (Hacker/Lava
	-- are EventOnly — extra-eligible for the weekly event roll above — but
	-- do NOT carry NormalPoolExcluded, so they're still in THIS pool too,
	-- just at the tiny LateWeight GameConfig.CreatureRarities gives them;
	-- Glitchrot/Singularity carry NormalPoolExcluded = true and never reach
	-- here) and GameConfig.CreatureSpawn.RarityCaps' staged rarity ceiling.
	local countByRarity = {}
	for _, def in ipairs(GameConfig.Creatures) do
		if isRarityAllowedOnFloor(def, floorIndex) then
			countByRarity[def.Rarity] = (countByRarity[def.Rarity] or 0) + 1
		end
	end

	local weights = {}
	local totalWeight = 0
	for _, def in ipairs(GameConfig.Creatures) do
		if isRarityAllowedOnFloor(def, floorIndex) then
			local w = getRarityWeight(GameConfig.CreatureRarities[def.Rarity], floorIndex or 1) / countByRarity[def.Rarity]
			weights[def] = w
			totalWeight += w
		end
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, def in ipairs(GameConfig.Creatures) do
		if isRarityAllowedOnFloor(def, floorIndex) then
			cumulative += weights[def]
			if roll <= cumulative then
				return def
			end
		end
	end
	return GameConfig.Creatures[1]
end

function CreatureService.GetTotalCashBoost(player)
	local data = PlayerDataManager.Get(player)
	if not data then
		return 0
	end
	local boost = 0
	for creatureName, count in pairs(data.Creatures) do
		if count and count > 0 then
			for _, def in ipairs(GameConfig.Creatures) do
				if def.Name == creatureName then
					local rarityDef = GameConfig.CreatureRarities[def.Rarity]
					-- Midpoint of the rarity's [MinRate, MaxRate] range (see
					-- GameConfig.CreatureRarities) — this function doesn't
					-- know a specific creature's exact stable rate (that's
					-- computed in EconomyService), so the average stands in
					-- as a reasonable estimate.
					boost += (rarityDef.MinRate + rarityDef.MaxRate) / 2
					break
				end
			end
		end
	end
	return boost
end

-- === Brainrot-Dex completion bonus (on request) ================================
-- "wenn man alle rarity Normal gesammelt hat, 10% Cash bekommen, genau so wie
-- alle anderen Rarity Klassen ... als Geschenk ohne es zu bauen" — see
-- GameConfig.Dex's own long comment for the full design. This is deliberately
-- SEPARATE from GetTotalCashBoost above (which only counts creatures you
-- CURRENTLY own, via data.Creatures) — the Dex bonus keys off
-- data.DiscoveredCreatures instead (see finalizeClaim below), a permanent
-- "ever claimed at least once" flag that never clears when a creature is
-- later sold/traded away, exactly matching "ohne es zu bauen" (you don't
-- need to still own/display it).

-- Returns { [rarityName] = { Discovered = n, Total = m, Completed = bool } }
-- for every rarity in GameConfig.Creatures — the Brainrot-Dex UI's own
-- per-rarity progress (UIBuilder's Dex header, "14/18 entdeckt" + a "+10%
-- Cash" hint once Completed) reads this same shape, so the UI and the real
-- Cash-multiplier bonus below can never disagree about what counts as
-- "complete".
function CreatureService.GetRarityProgress(player)
	local data = PlayerDataManager.Get(player)
	local discovered = (data and data.DiscoveredCreatures) or {}

	local progress = {}
	for _, def in ipairs(GameConfig.Creatures) do
		local entry = progress[def.Rarity]
		if not entry then
			entry = { Discovered = 0, Total = 0 }
			progress[def.Rarity] = entry
		end
		entry.Total += 1
		if discovered[def.Name] then
			entry.Discovered += 1
		end
	end
	for _, entry in pairs(progress) do
		entry.Completed = entry.Discovered >= entry.Total
	end
	return progress
end

-- How many rarity classes `player` has FULLY discovered right now — used by
-- EconomyService's getCashMultiplierFactor to add
-- GameConfig.Dex.CompletionCashBoostPerRarity per completed rarity (stacks
-- additively, same as the VIP gamepass's own CashBoost).
function CreatureService.GetCompletedRarityCount(player)
	local completedCount = 0
	for _, entry in pairs(CreatureService.GetRarityProgress(player)) do
		if entry.Completed then
			completedCount += 1
		end
	end
	return completedCount
end

local function findRarityForCreature(creatureName)
	for _, def in ipairs(GameConfig.Creatures) do
		if def.Name == creatureName then
			return def.Rarity
		end
	end
	return nil
end

-- Marks `creatureName` as discovered forever for `player` (see
-- PlayerDataManager's DiscoveredCreatures field) and, if this is the exact
-- moment that creature's rarity FIRST becomes fully discovered, fires
-- "DexRarityCompleted" so the client can show a one-time "+10% Cash"
-- callout — on request, "eine Information das man das bekommt wäre toll",
-- since silently adding the bonus in the background (the original
-- implementation) left players with no way to notice it had kicked in.
-- Fires exactly once per rarity (never again once already Completed, never
-- for a rarity that's still incomplete after this) — shared by finalizeClaim
-- (tower pickup) and addCreature (trade received) below, the only two places
-- a creature can newly become discovered. A no-op if `creatureName` was
-- already discovered before this call, since nothing can newly complete in
-- that case.
local function markDiscoveredAndNotifyCompletion(player, data, creatureName)
	data.DiscoveredCreatures = data.DiscoveredCreatures or {}
	if data.DiscoveredCreatures[creatureName] then
		return
	end
	data.DiscoveredCreatures[creatureName] = true

	local rarity = findRarityForCreature(creatureName)
	if not rarity then
		return
	end

	local progress = CreatureService.GetRarityProgress(player)
	local rarityProgress = progress[rarity]
	if rarityProgress and rarityProgress.Completed and remotesFolder then
		remotesFolder.DexRarityCompleted:FireClient(player, {
			Rarity = rarity,
			BonusPercent = math.floor(GameConfig.Dex.CompletionCashBoostPerRarity * 100 + 0.5),
		})
	end
end

-- Only Brainrots that actually get a real pedestal are allowed to exist at
-- all — no more "claimed but invisible, still earning" overflow entries.
local function hasFreeSlot(player, data)
	local capacity = BaseService and BaseService.GetCapacity(player) or math.huge
	return #data.CreatureLog < capacity
end

-- Actually inserts `def` into the player's base — the shared tail end of a
-- claim, once the specific creature (one of the 2-3 standing on the tower
-- floor) is known.
local function finalizeClaim(player, data, def)
	data.Creatures[def.Name] = (data.Creatures[def.Name] or 0) + 1

	-- Marks this creature as "ever seen" for the Brainrot-Dex (see
	-- PlayerDataManager's DiscoveredCreatures field and init.server.lua's
	-- GetDiscoveredCreatures remote) — a permanent set, never cleared by
	-- selling/trading away the creature later, unlike Creatures/CreatureLog
	-- above which only reflect what you currently hold. Also fires the
	-- one-time "DexRarityCompleted" notice if this claim just finished off
	-- def.Rarity (see markDiscoveredAndNotifyCompletion above).
	markDiscoveredAndNotifyCompletion(player, data, def.Name)

	-- Ordered log of every claim ever made. BaseService reads this to fill
	-- pedestals in claim order — the Nth claim always lands on the Nth slot.
	-- The capacity check guarantees this never grows past what
	-- BaseService.GetCapacity allows, so every entry always gets a real,
	-- visible, collectible pedestal.
	table.insert(data.CreatureLog, def.Name)

	-- PedestalCash stays a PARALLEL array to CreatureLog — this new slot
	-- starts with nothing uncollected sitting on it yet.
	data.PedestalCash = data.PedestalCash or {}
	table.insert(data.PedestalCash, 0)

	if remotesFolder then
		remotesFolder.CreatureObtained:FireClient(player, {
			Name = def.Name,
			Rarity = def.Rarity,
			Color = GameConfig.CreatureRarities[def.Rarity].Color,
		})
	end

	if onDataChanged then
		onDataChanged(player)
	end

	if onCreatureClaimed then
		onCreatureClaimed(player)
	end

	-- Send the player back to their OWN BASE after every pickup (progress
	-- like Cash and HighestFloor is untouched, only the character's position
	-- resets). Without this, a player could camp a single low-floor orb and
	-- farm creatures — and their passive cash-multiplier bonus — for free,
	-- forever, without climbing at all. Sending them to their base (instead
	-- of just Floor 1) also means they immediately see the new pedestal fill
	-- in.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local spawnCFrame = BaseService and BaseService.GetSpawnCFrame(player)
	if root and spawnCFrame then
		root.CFrame = spawnCFrame
	elseif root then
		-- Fallback for the rare case a player has no base plot yet (e.g. more
		-- than GameConfig.Base.MaxPlayers joined) — Floor 1, as before.
		local floor1 = workspace:FindFirstChild("Tower") and workspace.Tower:FindFirstChild("Floor_1")
		if floor1 then
			root.CFrame = floor1.CFrame + Vector3.new(0, 6, 0)
		end
	end
end

-- Removes ONE CreatureLog entry matching `creatureName` from `data` (the
-- oldest claim of that name first) and keeps PedestalCash in sync — the same
-- list-shift mechanics SellCreature uses, just without the Cash payout (the
-- creature is going to a trade partner, not sold to nobody). Returns
-- (true, uncollectedCash) on success or (false) if the player doesn't
-- actually have one — TradeService.lua re-checks ownership right before
-- calling this, but a mid-negotiation sale could still make it stale.
local function removeOneByName(data, creatureName)
	local index
	for i, name in ipairs(data.CreatureLog) do
		if name == creatureName then
			index = i
			break
		end
	end
	if not index then
		return false
	end

	local uncollected = (data.PedestalCash and data.PedestalCash[index]) or 0
	table.remove(data.CreatureLog, index)
	if data.PedestalCash then
		table.remove(data.PedestalCash, index)
	end

	data.Creatures[creatureName] = (data.Creatures[creatureName] or 1) - 1
	if data.Creatures[creatureName] <= 0 then
		data.Creatures[creatureName] = nil
	end

	return true, uncollected
end

-- Appends `creatureName` to `data` as a brand new pedestal slot, carrying
-- over `carryOverCash` (the uncollected PedestalCash the SAME creature had
-- sitting on its old owner's pedestal, from removeOneByName above) so
-- trading away a creature nobody had walked over to collect from yet
-- doesn't just erase that Cash — the new owner gets to collect it instead.
local function addCreature(player, data, creatureName, carryOverCash)
	data.Creatures[creatureName] = (data.Creatures[creatureName] or 0) + 1
	table.insert(data.CreatureLog, creatureName)
	data.PedestalCash = data.PedestalCash or {}
	table.insert(data.PedestalCash, carryOverCash or 0)

	-- Same Dex discovery marking (and DexRarityCompleted notice) as
	-- finalizeClaim above — the receiving side of a trade counts as
	-- "discovering" the creature too, even if you never rolled it yourself
	-- on the tower. Needs `player` (new parameter, see ExecuteTrade below)
	-- purely to fire that notice to the right client.
	markDiscoveredAndNotifyCompletion(player, data, creatureName)
end

-- Distinct creatures `player` currently owns (one entry per NAME, not per
-- pedestal — someone with 3x the same Brainrot only sees it once here, with
-- Count = 3), used by TradeService to build the "pick one to offer" list in
-- the trade window. Rarity/Color are looked up from GameConfig.Creatures so
-- the trade UI can show the same rarity-colored styling as everywhere else.
function CreatureService.GetOwnedSummary(player)
	local data = PlayerDataManager.Get(player)
	if not data or not data.CreatureLog then
		return {}
	end

	local summary = {}
	local seen = {}
	for _, creatureName in ipairs(data.CreatureLog) do
		if not seen[creatureName] then
			seen[creatureName] = true

			local def
			for _, d in ipairs(GameConfig.Creatures) do
				if d.Name == creatureName then
					def = d
					break
				end
			end
			local rarity = def and def.Rarity or "Normal"
			local rarityDef = GameConfig.CreatureRarities[rarity]

			table.insert(summary, {
				Name = creatureName,
				Rarity = rarity,
				Color = (rarityDef and rarityDef.Color) or Color3.new(1, 1, 1),
				Count = data.Creatures[creatureName] or 1,
			})
		end
	end
	return summary
end

-- Executes a full 1-for-1 trade between two players, swapping exactly one
-- Brainrot each — the ONLY kind of trade this game supports (see
-- TradeService.lua, which handles the request/accept/offer-picking UI this
-- is just the atomic final step of). Re-validates both players still
-- actually own what they offered (one of them could have sold it or claimed
-- past their capacity while the trade window was open) before touching
-- anything, and rolls back cleanly if only one side's removal succeeds —
-- a Brainrot should never just vanish because of a mid-trade edge case.
-- Capacity is never a concern here: each side loses exactly one pedestal
-- slot and gains exactly one, and BaseService.GetCapacity only ever grows
-- (more Rebirths), never shrinks.
function CreatureService.ExecuteTrade(playerA, nameA, playerB, nameB)
	local dataA = PlayerDataManager.Get(playerA)
	local dataB = PlayerDataManager.Get(playerB)
	if not dataA or not dataB then
		return false, "Spielerdaten nicht gefunden"
	end

	if (dataA.Creatures[nameA] or 0) <= 0 then
		return false, "Du besitzt dieses Brainrot nicht mehr"
	end
	if (dataB.Creatures[nameB] or 0) <= 0 then
		return false, "Der andere Spieler besitzt dieses Brainrot nicht mehr"
	end

	local removedA, cashA = removeOneByName(dataA, nameA)
	local removedB, cashB = removeOneByName(dataB, nameB)
	if not removedA or not removedB then
		if removedA then
			addCreature(playerA, dataA, nameA, cashA)
		end
		if removedB then
			addCreature(playerB, dataB, nameB, cashB)
		end
		return false, "Tausch fehlgeschlagen"
	end

	addCreature(playerA, dataA, nameB, cashB)
	addCreature(playerB, dataB, nameA, cashA)

	if onDataChanged then
		onDataChanged(playerA)
		onDataChanged(playerB)
	end
	if onCreatureClaimed then
		onCreatureClaimed(playerA)
		onCreatureClaimed(playerB)
	end

	return true
end

-- Rolls `count` independent creature options for a physical claim spot on
-- the tower floor at `floorIndex` (see TowerGenerator's buildClaimSpot) —
-- same odds/rarity-by-floor as always (rollCreature/getRarityWeight), just
-- displayed as 2-3 real creatures standing on the platform instead of a
-- single surprise orb. Returns the raw GameConfig.Creatures def tables
-- directly (TowerGenerator already requires GameConfig itself, so it can
-- read Name/Rarity/ModelYRotation straight off them) — these are handed
-- back verbatim to ClaimPhysicalCreature below once someone claims one.
function CreatureService.RollChoices(floorIndex, count)
	local defs = {}
	for i = 1, count do
		defs[i] = rollCreature(floorIndex)
	end
	return defs
end

-- Called when a player interacts with one of the physical Brainrots
-- standing on a tower floor (see TowerGenerator's buildClaimSpot). Unlike
-- the old "pick 1 of 3 on your own screen" system, these stands are SHARED —
-- everyone in the tower sees the same 2-3 Brainrots and it's first-come,
-- first-served (real competition, same spirit as the Slap Hand). The caller
-- (TowerGenerator) is responsible for making sure only ONE claim per stand
-- can ever go through — this just does the capacity check and the actual
-- grant.
function CreatureService.ClaimPhysicalCreature(player, def)
	local data = PlayerDataManager.Get(player)
	if not data or not def then
		return false
	end
	data.CreatureLog = data.CreatureLog or {}

	if not hasFreeSlot(player, data) then
		if remotesFolder then
			remotesFolder.Notice:FireClient(player, "Base voll! Verkaufe ein Brainrot oder mach eine Wiedergeburt für mehr Platz.")
		end
		return false
	end

	finalizeClaim(player, data, def)
	return true
end

-- Sells ONE specific pedestal slot (identified by its position in
-- CreatureLog, i.e. the same globalSlotIndex BaseService uses to place it —
-- see the ProximityPrompt BaseService.RefreshBase attaches to each filled
-- pedestal). Removing that entry shifts every later claim down by one slot,
-- which is exactly what "frees up space" means here: the LAST pedestal on
-- the base becomes empty again, ready for the next climb/claim to fill —
-- capacity itself doesn't change, only how much of it is currently used.
--
-- Pays out SellValueSeconds worth of that creature's CURRENT Cash/sec rate
-- (same rate EconomyService.GetCreatureCashRates computes for the pedestal
-- display), so the payout is always a real, up-to-date chunk of income —
-- never a flat/stale number — and grows right along with HighestFloor and
-- Rebirths like everything else in the economy.
function CreatureService.SellCreature(player, slotIndex)
	local data = PlayerDataManager.Get(player)
	if not data or not data.CreatureLog then
		return false, "No data"
	end

	local creatureName = data.CreatureLog[slotIndex]
	if not creatureName then
		return false, "No creature there"
	end

	local sellValue = 1
	if EconomyService then
		local rates = EconomyService.GetCreatureCashRates(player)
		local ratePerSecond = rates[creatureName] or 1
		sellValue = math.max(1, ratePerSecond * GameConfig.Economy.SellValueSeconds)
	end

	-- Whatever this pedestal had already earned but you hadn't walked over
	-- to collect yet is included in the sale — selling never throws away
	-- Cash that was already sitting there waiting for you.
	local uncollected = (data.PedestalCash and data.PedestalCash[slotIndex]) or 0
	sellValue += uncollected

	table.remove(data.CreatureLog, slotIndex)
	if data.PedestalCash then
		table.remove(data.PedestalCash, slotIndex)
	end

	data.Creatures[creatureName] = (data.Creatures[creatureName] or 1) - 1
	if data.Creatures[creatureName] <= 0 then
		data.Creatures[creatureName] = nil
	end

	data.Cash += sellValue
	-- Lifetime total for the global Hall of Fame's "Top Gesamt-Cash" ranking
	-- (see PlayerDataManager's LifetimeCashEarned comment and
	-- LeaderboardService.lua) — grows by the exact same amount as Cash here,
	-- but is never reduced by anything, unlike Cash itself.
	data.LifetimeCashEarned = (data.LifetimeCashEarned or 0) + sellValue

	if remotesFolder then
		remotesFolder.CreatureSold:FireClient(player, {
			Name = creatureName,
			Value = sellValue,
		})
	end

	if onDataChanged then
		onDataChanged(player)
	end

	-- Pedestals shifted (the sold slot's neighbors all moved down one), so
	-- the base needs a full rebuild — same as after a new claim.
	if BaseService then
		BaseService.RefreshBase(player)
	end

	-- Pushes this sale's LifetimeCashEarned gain toward the Hall of Fame's
	-- "Top Gesamt-Cash" board right away instead of waiting for the next
	-- periodic sync — same reasoning as EconomyService.Rebirth's own hook
	-- (a deliberate sale, not the much more frequent passive-income
	-- pedestal collection in BaseService, which intentionally does NOT
	-- trigger this).
	if LeaderboardService then
		LeaderboardService.RequestImmediateRefresh(player)
	end

	return true, sellValue
end

return CreatureService
