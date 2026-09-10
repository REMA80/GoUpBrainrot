--[[
	PlayerDataManager.lua
	Loads/saves each player's persistent data via DataStoreService and keeps an
	in-memory cache other services read/write during play. Note: DataStore calls
	only work in Studio if "Enable Studio Access to API Services" is turned on
	(Game Settings > Security) — otherwise Load() safely falls back to defaults.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

-- GetDataStore() itself can throw (e.g. "You must publish this place to the
-- web to access DataStore") when the place has never been published, or when
-- "Studio Access to API Services" is off. Guard it so the whole server script
-- doesn't crash on load — the game just runs without persistence until then.
local store
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.DataStore.Name)
	end)
	if ok then
		store = result
	else
		warn("[PlayerDataManager] DataStore unavailable, data will not persist this session: " .. tostring(result))
	end
end

local DEFAULT_DATA = {
	Cash = 0,
	JumpPoints = 0, -- replaces the old JumpTier (1-10) — see GameConfig.
	                -- JumpUpgrade / EconomyService's interpolated bulk-buy
	                -- system. 0 = GameConfig.JumpTiers[1]'s baseline. Since
	                -- the Prestige-Turm rework, this same points-curve now
	                -- also extends through GameConfig.PrestigeJumpTiers
	                -- (Tier 11-20, Floor 101-120) — no separate field needed.
	Rebirths = 0,
	HighestFloor = 1,
	Creatures = {},    -- [creatureName] = count (used for the cash-boost calc)
	CreatureLog = {},  -- ordered list of creature names in the order claimed;
	                   -- drives which pedestal in the player's base each one fills
	PedestalCash = {}, -- PARALLEL array to CreatureLog (same index = same
	                   -- pedestal): Cash a creature has earned but the player
	                   -- hasn't walked over/collected yet — see BaseService's
	                   -- Touched handler and EconomyService.StartPassiveIncomeLoop.
	-- Same "own it forever, granted once, never re-asked" IDEA as a real
	-- Game Pass — but these three (2x Cash, 4x Cash, Auto-Sammeln) turned
	-- out to be Developer Products in Roblox's system, not actual Game
	-- Passes (see GameConfig.Gamepasses' own big comment on how that was
	-- diagnosed) — a Developer Product purchase can be repeated and Roblox
	-- itself never remembers it, so unlike a real Game Pass this game has to
	-- persist "did they already buy it" itself. Set to true (and never back
	-- to false) by MonetizationService.ProcessReceipt the moment it sees a
	-- matching ProductId — see that file's own comment for the full
	-- purchase flow.
	OwnsDoubleCash = false,
	OwnsQuadCash = false,
	OwnsAutoCollect = false,
	DiscoveredCreatures = {}, -- [creatureName] = true, set once and NEVER
	                          -- cleared again (unlike Creatures/CreatureLog,
	                          -- which only reflect what you currently hold) —
	                          -- powers the Brainrot-Dex panel (see
	                          -- CreatureService's finalizeClaim/addCreature,
	                          -- init.server.lua's GetDiscoveredCreatures
	                          -- remote, and UIBuilder's Dex panel).
	ProcessedPurchaseIds = {}, -- [receiptInfo.PurchaseId] = true — every Robux
	                           -- Developer Product purchase ever granted to
	                           -- this player (see MonetizationService's
	                           -- ProcessReceipt). Persisted here (not just an
	                           -- in-memory session Set) so a retried receipt
	                           -- is still correctly recognized as "already
	                           -- handled" even after a server restart or the
	                           -- player reconnecting — Roblox requires
	                           -- ProcessReceipt to be safely re-callable for
	                           -- the SAME purchase without granting it twice.

	LifetimeCashEarned = 0, -- NEVER decreases. Every Cash gain from selling a
	                        -- creature (CreatureService.SellCreature) or
	                        -- collecting a pedestal (BaseService's Display
	                        -- Touched handler) adds here too, ON TOP OF the
	                        -- normal (spendable, fluctuating) Cash field
	                        -- above. Spending — Jump Upgrade, Rebirth, Slap
	                        -- Hand — never touches this: it's a pure "how
	                        -- much have I ever earned" lifetime total, used
	                        -- for the Hall of Fame's global "Top Gesamt-Cash"
	                        -- ranking (see LeaderboardService.lua).
	ReachedFloor100 = false, -- set once, permanently true, in EconomyService.
	                         -- OnFloorReached the first time a player's
	                         -- Detector touch reaches GameConfig.Floors.Count
	                         -- — guarantees a player is only ever added to
	                         -- the global Hall of Fame roster once, even
	                         -- across many later sessions/server restarts
	                         -- (see LeaderboardService.RecordFloor100).

	LastWheelSpinAt = 0, -- os.time() of this player's last Glücksrad spin
	                     -- (see WheelService.lua / GameConfig.WheelOfFortune.
	                     -- CooldownSeconds). PERSISTED (unlike e.g.
	                     -- ShopService's Slap Hand cooldown, which is
	                     -- in-memory only) so a free-reward cooldown can't be
	                     -- reset just by rejoining. 0 = never spun yet, so a
	                     -- brand-new player can always spin immediately.

	LastSummitChestAt = 0, -- os.time() of this player's last "Mega-Truhe"
	                       -- opening (see SummitChestService.lua / GameConfig.
	                       -- Summit.ChestCooldownSeconds) — same persisted,
	                       -- once-per-real-day pattern as LastWheelSpinAt right
	                       -- above, just for the Floor 100 chest instead of the
	                       -- Glücksrad. 0 = never opened yet.

	LastSeenAt = 0, -- os.time() this player was last saved (set by Save()
	                -- below, every time — PlayerRemoving, BindToClose, and
	                -- the periodic auto-save loop all go through it). Read by
	                -- EconomyService.ComputeOfflineEarnings on the NEXT join
	                -- to work out how long they were away (see GameConfig.
	                -- OfflineEarnings). 0 = never saved yet (a brand-new
	                -- player), which ComputeOfflineEarnings treats as "nothing
	                -- to show" rather than a multi-decade offline bonus.
}

local PlayerDataManager = {}
local cache = {} -- [userId] = data

local function deepCopy(t)
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = (type(v) == "table") and deepCopy(v) or v
	end
	return copy
end

function PlayerDataManager.Load(player)
	local key = "Player_" .. player.UserId
	local data

	if not store then
		data = deepCopy(DEFAULT_DATA)
		cache[player.UserId] = data
		return data
	end

	local ok, result = pcall(function()
		return store:GetAsync(key)
	end)

	if ok and result then
		data = result

		-- ONE-TIME migration from the old JumpTier (1-10, discrete) system
		-- to the new JumpPoints (continuous, bulk-buyable) one — see
		-- GameConfig.JumpUpgrade / EconomyService. Runs only when this save
		-- predates JumpPoints entirely (data.JumpPoints == nil); once it
		-- runs, JumpPoints becomes a real saved field and this branch never
		-- fires again for this player. Converts the player's old tier
		-- straight onto the equivalent point on the new curve (Tier N =
		-- point (N-1)*PointsPerTier), so nobody's progress is reset or
		-- lost by this change — they land at the exact same JumpPower/Gap
		-- they already had.
		if data.JumpPoints == nil then
			local oldTier = data.JumpTier or 1
			data.JumpPoints = math.max(0, (oldTier - 1) * GameConfig.JumpUpgrade.PointsPerTier)
		end

		-- backfill any fields missing from an older save (schema migration safety)
		for k, v in pairs(DEFAULT_DATA) do
			if data[k] == nil then
				data[k] = (type(v) == "table") and deepCopy(v) or v
			end
		end
		-- PedestalCash is a PARALLEL array to CreatureLog — a save from
		-- before this field existed (or any other length mismatch) gets
		-- padded with 0s so every claimed slot has a matching entry.
		while #data.PedestalCash < #data.CreatureLog do
			table.insert(data.PedestalCash, 0)
		end
	else
		if not ok then
			warn("[PlayerDataManager] GetAsync failed for " .. player.Name .. ", using defaults: " .. tostring(result))
		end
		data = deepCopy(DEFAULT_DATA)
	end

	cache[player.UserId] = data
	return data
end

function PlayerDataManager.Get(player)
	return cache[player.UserId]
end

function PlayerDataManager.Save(player)
	local data = cache[player.UserId]
	if not data then
		return
	end

	-- Marks "we know this player was here as of right now" — read back on
	-- their NEXT join by EconomyService.ComputeOfflineEarnings to work out
	-- how long they were away. Set unconditionally (even if `store` is nil
	-- and nothing actually persists this session) so a Studio playtest
	-- without DataStore access still behaves consistently, just never
	-- remembers it across a real restart.
	data.LastSeenAt = os.time()

	if not store then
		return
	end
	local key = "Player_" .. player.UserId
	local ok, err = pcall(function()
		store:SetAsync(key, data)
	end)
	if not ok then
		warn("[PlayerDataManager] Failed to save data for " .. player.Name .. ": " .. tostring(err))
	end
end

function PlayerDataManager.Release(player)
	cache[player.UserId] = nil
end

-- On request ("ein Spieler hat sich vom PC auf dem Handy eingeloggt und den
-- aktuellen Speicherstand verloren") — Save() used to only ever run on
-- PlayerRemoving/BindToClose (see init.server.lua's Player lifecycle
-- section), so an ENTIRE play session's progress rode on one of those two
-- firing cleanly. A crash, a force-quit, a lost connection, or a second
-- session on another device saving its own (older) copy first could all
-- wipe out everything since the last clean save. This periodic loop saves
-- every online player every GameConfig.DataStore.AutoSaveIntervalSeconds,
-- so the most that's ever at risk again is a few minutes of progress
-- instead of the whole session.
--
-- Deliberately NOT a fix for two simultaneous sessions overwriting each
-- other (see GameConfig.DataStore.AutoSaveIntervalSeconds' own comment) —
-- that needs an actual session lock, which is a bigger change than what
-- was asked for here. This only shrinks how much a single session can lose
-- if IT alone never gets to save cleanly.
--
-- Called once from init.server.lua, same "spawn a forever loop" shape as
-- EconomyService.StartPassiveIncomeLoop / LeaderboardService.
-- StartPeriodicSync.
function PlayerDataManager.StartPeriodicAutoSave()
	task.spawn(function()
		while true do
			task.wait(GameConfig.DataStore.AutoSaveIntervalSeconds)
			for _, player in ipairs(Players:GetPlayers()) do
				PlayerDataManager.Save(player)
			end
		end
	end)
end

-- Wipes a player's save back to a clean DEFAULT_DATA and immediately
-- persists that wipe to the DataStore (best-effort — if it fails, the old
-- save would otherwise come back on the next real Load, e.g. after a
-- server restart/republish). Used by the "/resetdata" debug chat command
-- (see init.server.lua) for exactly the situation that motivated it: a
-- save made BEFORE a creature-roster content change (like the Italian
-- Brainrot rename) keeps old CreatureLog name strings that no longer exist
-- in GameConfig.Creatures, so every one of those old creatures silently
-- shows "+$0/s" and no model (EconomyService.GetCreatureCashRates and
-- CreatureModelDisplay.GetTemplate both do an exact-name lookup that just
-- fails to match). Wiping is the simplest fix for a test/dev save — there's
-- no way to "migrate" an old name to a new one since they don't correspond
-- to anything 1:1.
function PlayerDataManager.Reset(player)
	local data = deepCopy(DEFAULT_DATA)
	cache[player.UserId] = data

	if store then
		local key = "Player_" .. player.UserId
		local ok, err = pcall(function()
			store:SetAsync(key, data)
		end)
		if not ok then
			warn("[PlayerDataManager] Failed to persist reset for " .. player.Name .. ": " .. tostring(err))
		end
	end

	return data
end

return PlayerDataManager
