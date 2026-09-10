--[[
	Server/init.server.lua
	Entry point. Creates the RemoteEvents/Functions, wires the services
	together, builds the tower, and handles player join/leave.

	Because of the init.server.lua + sibling-files pattern, this becomes a
	Script named "Server" directly under ServerScriptService, and every other
	.lua file in this folder becomes a ModuleScript child of it (script.Foo).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local TowerGenerator = require(script.TowerGenerator)
local PlayerDataManager = require(script.PlayerDataManager)
local EconomyService = require(script.EconomyService)
local CreatureService = require(script.CreatureService)
local MonetizationService = require(script.MonetizationService)
local RebirthCosmeticsService = require(script.RebirthCosmeticsService)
local BaseService = require(script.BaseService)
local EventService = require(script.EventService)
local TradeService = require(script.TradeService)
local CreatureModelDisplay = require(script.CreatureModelDisplay)
local LeaderboardService = require(script.LeaderboardService)
local WheelService = require(script.WheelService)
local SummitChestService = require(script.SummitChestService)
local FastTravelService = require(script.FastTravelService)
local AdminAbuseService = require(script.AdminAbuseService)

-- NOTE: Players.MaxPlayers is READ-ONLY at runtime — it can't be set from a
-- script (assigning it throws and stops this whole script from running,
-- which is what just happened). The server player cap has to be set by hand
-- in Studio: Game Settings > Basic Info > Max Player Count. Set it to
-- GameConfig.Base.MaxPlayers (4) there.

-- Characters are loaded manually (player:LoadCharacter() below) instead of
-- automatically, so we can assign the player's base plot FIRST and then
-- spawn them there — otherwise Roblox would spawn them at Floor 1 (the only
-- SpawnLocation) before we ever get a chance to reposition them.
Players.CharacterAutoLoads = false

-- === Remotes ===================================================================
local remotesFolder = Instance.new("Folder")
remotesFolder.Name = "Remotes"
remotesFolder.Parent = ReplicatedStorage

local function newRemoteEvent(name)
	local re = Instance.new("RemoteEvent")
	re.Name = name
	re.Parent = remotesFolder
	return re
end

local function newRemoteFunction(name)
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = remotesFolder
	return rf
end

newRemoteEvent("DataUpdated")
newRemoteEvent("CreatureObtained")
newRemoteEvent("CreatureSold")
-- One-way "show this message" event for server-initiated notices that don't
-- come from a RemoteFunction call (e.g. CreatureService telling a player
-- their base is full when they touch a claim spot — there's no client
-- request to return a result to, so it fires straight to the client instead).
newRemoteEvent("Notice")
-- On request ("eine Information das man das bekommt wäre toll") — fired
-- the EXACT moment a rarity's Brainrot-Dex completion bonus first turns on
-- (see CreatureService.markDiscoveredAndNotifyCompletion), never again for
-- that rarity afterwards. Payload: { Rarity = "Normal", BonusPercent = 10 }.
newRemoteEvent("DexRarityCompleted")
local buyJumpUpgradeFn = newRemoteFunction("BuyJumpUpgrade")
local rebirthFn = newRemoteFunction("Rebirth")

-- Personal "Sprunghöhe"-Regler (see EconomyService.SetJumpHeightFraction's
-- own comment), on request: reachable from anywhere via its own always-
-- visible HUD button (UIBuilder's JumpHeightButton/-Overlay), not tied to a
-- kiosk like the Jump Upgrade panel is. Client sends the desired 0..1
-- fraction, server clamps it (never trusts the client's number as-is) and
-- returns the fraction that actually got applied. Since the Prestige-Turm
-- rework, this same regler also covers Tier 11-20 (Floor 101-120) — no
-- separate control needed there.
local setJumpHeightFractionFn = newRemoteFunction("SetJumpHeightFraction")

-- On-demand (NOT part of the frequent DataUpdated push, see EconomyService.
-- FireDataUpdated's comment) — the full Brainrot roster plus which ones this
-- player has ever discovered, for the Dex panel (see UIBuilder.lua). Called
-- once when the player opens the panel, not continuously.
local getDiscoveredCreaturesFn = newRemoteFunction("GetDiscoveredCreatures")

-- === Base-station remotes (see BaseService.lua's buildStations) ===============
-- One-way "do your client-only thing now" events for the two base-station
-- actions that can't just run straight through server-side code: opening
-- the Rebirth confirmation dialog (needs to show a message BEFORE the
-- player commits, same as the old RebirthButton did) and opening a Robux
-- gamepass purchase prompt (MarketplaceService:PromptGamePassPurchase only
-- works from the client).
newRemoteEvent("RequestRebirthConfirm") -- -> client: (no payload — client already has lastData from DataUpdated)
newRemoteEvent("RequestGamepassPrompt") -- -> client: "DoubleCash" | "QuadCash" | "AutoCollect"
newRemoteEvent("RequestJumpUpgradePanel") -- -> client: (no payload — client already has JumpPoints/JumpBulkOptions from DataUpdated, see EconomyService.GetJumpUpgradeState)
-- "1x Wiedergeburt" kiosk (replaced the old VIP kiosk, on request) — a
-- Developer Product, not a Gamepass, so it needs its own event rather than
-- reusing RequestGamepassPrompt above (PromptProductPurchase vs
-- PromptGamePassPurchase are two different MarketplaceService calls).
newRemoteEvent("RequestRebirthProductPrompt") -- -> client: (no payload — client already has GameConfig.Rebirth.RobuxProduct.ProductId)

-- On request ("ich möchte bei dem verkaufen von Brainroth, das nachgefragt
-- wird ob du es verkaufen willst") — a pedestal's Sell prompt no longer
-- sells instantly; BaseService.lua fires this instead of calling
-- CreatureService.SellCreature directly, so the client can show a Yes/No
-- dialog first (see UIBuilder.ShowSellConfirm / init.client.lua's
-- RequestSellConfirm listener), same "ask first, commit later" split as the
-- Rebirth altar above. The actual sale only happens once the player clicks
-- "Yes", via the RemoteFunction right below.
newRemoteEvent("RequestSellConfirm") -- -> client: {SlotIndex, Name, Value} — Value is only an ESTIMATE for the dialog text, see BaseService.lua's comment on it
local confirmSellCreatureFn = newRemoteFunction("ConfirmSellCreature") -- player, slotIndex -> (success, sellValueOrError) — re-validates and performs the real sale server-side; never trusts the estimate the dialog displayed

-- === Glücksrad remotes (see BaseService.lua's buildWheelKiosk / WheelService.lua) ===
newRemoteEvent("RequestWheelPanel") -- -> client: (no payload — client calls GetWheelState below right away, same "fetch fresh on open" pattern as GetDiscoveredCreatures). Fired when a player interacts with the shared wheel kiosk.
local getWheelStateFn = newRemoteFunction("GetWheelState") -- player -> {Ready, RemainingSeconds, RobuxProductId} — called right when the panel opens
local spinWheelFreeFn = newRemoteFunction("SpinWheelFree") -- player -> {Success, SegmentIndex, Message} | {Success=false, RemainingSeconds} — the panel's "Täglicher Spin" button
newRemoteEvent("WheelSpinResult") -- -> client: {SegmentIndex, Message} — fired by WheelService.SpinWheelPaid once a Robux-paid spin resolves (can't return synchronously to the button click, since ProcessReceipt runs later, out of band)

-- === Fast-Travel remote (see BaseService.lua's buildFastTravelKiosk / FastTravelService.lua) ===
newRemoteEvent("RequestFastTravelPanel") -- -> client: (no payload — the panel reads lastData.HighestFloor, already pushed on every DataUpdated, same "no extra fetch needed" pattern as RequestJumpUpgradePanel). Fired when a player interacts with the shared Fast-Travel kiosk.

-- === Leaderboard panel remotes (see LeaderboardService.lua's BuildBoard/
-- GetPanelData) ==================================================================
-- On request ("die Bestenliste hat Bilder der Spieler und man kann von Top1
-- bis Top 200 runter scrollen") — same "kiosk opens a panel, panel fetches
-- its own fresh data" pattern as RequestWheelPanel/GetWheelState above.
newRemoteEvent("RequestLeaderboardPanel") -- -> client: (no payload — the panel calls GetLeaderboardPanelData below right away). Fired by the board's ProximityPrompt.
local getLeaderboardPanelDataFn = newRemoteFunction("GetLeaderboardPanelData") -- player -> { Rebirths = {Entries, Self}, Cash = {...}, CashPerSecond = {...} } — see LeaderboardService.GetPanelData

-- === Trade Zone remotes (see TradeService.lua) =================================
newRemoteEvent("TradeZoneRoster")      -- -> client: array of {UserId, Name} in the zone, or nil to hide the panel
newRemoteEvent("TradeRequestReceived") -- -> client: {FromUserId, FromName}
newRemoteEvent("TradeOpened")          -- -> client: {OpponentName, MyItems}
newRemoteEvent("TradeUpdate")          -- -> client: {MyOffer, OpponentOffer, MyConfirmed, OpponentConfirmed}
newRemoteEvent("TradeClosed")          -- -> client: {Success, Reason}
local requestTradeFn = newRemoteFunction("RequestTrade")
local respondTradeFn = newRemoteFunction("RespondTrade")
local setTradeOfferFn = newRemoteFunction("SetTradeOffer")
local confirmTradeFn = newRemoteFunction("ConfirmTrade")
local cancelTradeFn = newRemoteFunction("CancelTrade")

-- === Wire services together ====================================================
-- MonetizationService is passed in here (for the "2x Cash" kiosk's
-- QuadCash-upgrade ownership check, see BaseService's own comments on that)
-- even though MonetizationService.Init hasn't run yet at this point — same
-- "store the module reference now, only actually call into it once real
-- gameplay data exists" timing as LeaderboardService/EconomyService above.
BaseService.Init({
	PlayerDataManager = PlayerDataManager,
	EconomyService = EconomyService,
	CreatureService = CreatureService,
	LeaderboardService = LeaderboardService,
	MonetizationService = MonetizationService,
	Remotes = remotesFolder,
})

-- Needed before EconomyService.Init since EconomyService.OnFloorReached
-- calls LeaderboardService.RecordFloor100 the moment a player first reaches
-- the top floor (see EconomyService.lua's comment on that hook). EconomyService
-- itself is passed in here too (for the "Top Cash/s" ranking's
-- GetCreatureCashRates call, see LeaderboardService.SyncPlayer) even though
-- EconomyService.Init hasn't run yet at this point — same "store the module
-- reference now, only actually call into it once real gameplay data
-- exists" timing MonetizationService.Init below relies on.
LeaderboardService.Init({
	PlayerDataManager = PlayerDataManager,
	EconomyService = EconomyService,
	Remotes = remotesFolder,
})

EconomyService.Init({
	PlayerDataManager = PlayerDataManager,
	CreatureService = CreatureService,
	MonetizationService = MonetizationService,
	RebirthCosmeticsService = RebirthCosmeticsService,
	BaseService = BaseService,
	EventService = EventService,
	LeaderboardService = LeaderboardService,
	Remotes = remotesFolder,
})

-- Needed for ProcessReceipt (Robux Developer Product purchases — the Jump
-- Upgrade panel's Sprung-point packs, the Glücksrad's paid extra spin, AND
-- the Fast-Travel kiosk's 4 paid checkpoint teleports, see
-- MonetizationService's own comment on that section). WheelService/
-- FastTravelService are both required above but not Init'd until further
-- below — fine, MonetizationService only stores the references here and
-- doesn't call into either until a real Robux receipt comes in, long after
-- every Init below has run.
MonetizationService.Init({
	PlayerDataManager = PlayerDataManager,
	EconomyService = EconomyService,
	WheelService = WheelService,
	FastTravelService = FastTravelService,
})

CreatureService.Init({
	PlayerDataManager = PlayerDataManager,
	BaseService = BaseService,
	EventService = EventService,
	EconomyService = EconomyService,
	LeaderboardService = LeaderboardService,
	Remotes = remotesFolder,
	OnDataChanged = EconomyService.FireDataUpdated,
	OnCreatureClaimed = BaseService.RefreshBase,
})

RebirthCosmeticsService.Init({
	PlayerDataManager = PlayerDataManager,
})

-- Glücksrad (wheel of fortune) — see WheelService.lua / GameConfig.
-- WheelOfFortune. Needs PlayerDataManager/EconomyService/CreatureService
-- already required above (their own .Init calls don't need to have run yet
-- — WheelService only stores the references here, doesn't call into them
-- until a player actually spins).
WheelService.Init({
	PlayerDataManager = PlayerDataManager,
	EconomyService = EconomyService,
	CreatureService = CreatureService,
	Remotes = remotesFolder,
})

-- Mega-Truhe (Floor 100's daily chest) — see SummitChestService.lua /
-- GameConfig.Summit. Same "only stores references, doesn't call into them
-- until a player actually opens the chest" timing as WheelService.Init above.
SummitChestService.Init({
	PlayerDataManager = PlayerDataManager,
	EconomyService = EconomyService,
	CreatureService = CreatureService,
	Remotes = remotesFolder,
})

-- Admin Abuse (manuelles "/adminabuse <Minuten>"-Event, siehe die Chatted-
-- Handler weiter unten und AdminAbuseService.lua's eigenen Kommentar).
-- Braucht TowerGenerator für GetRandomFloorPlatform, aus demselben Grund wie
-- FastTravelService direkt unten: die eigentlichen Lookups passieren erst,
-- wenn der Chat-Befehl tatsächlich getippt wird, lange nachdem TowerGenerator
-- .Build weiter unten die Etagen gebaut hat.
AdminAbuseService.Init({
	EconomyService = EconomyService,
	CreatureService = CreatureService,
	EventService = EventService,
	TowerGenerator = TowerGenerator,
	Remotes = remotesFolder,
})

-- Fast-Travel kiosk — see FastTravelService.lua / GameConfig.FastTravel.
-- Needs TowerGenerator for GetCheckpointCFrame, which only works correctly
-- AFTER TowerGenerator.Build has actually run further below — fine, this
-- Init call only stores the module reference, the real lookup happens much
-- later (a Robux purchase completing, which can't happen before the tower
-- and its checkpoints exist anyway).
FastTravelService.Init({
	TowerGenerator = TowerGenerator,
	PlayerDataManager = PlayerDataManager,
	EconomyService = EconomyService,
	Remotes = remotesFolder,
})

TradeService.Init({
	CreatureService = CreatureService,
	Remotes = remotesFolder,
})

-- `amount` = how many Sprung-points to buy at once (see the Jump Upgrade
-- panel's bulk buttons, UIBuilder.lua). On success `result` is a table
-- {PointsBought, Cost, NewPoints} — the panel already has fresh totals from
-- the DataUpdated that BuyJumpUpgrade fires itself, so this return value is
-- only used for an immediate "bought +N!" confirmation, not as the source
-- of truth.
buyJumpUpgradeFn.OnServerInvoke = function(player, amount)
	return EconomyService.BuyJumpUpgrade(player, amount)
end

rebirthFn.OnServerInvoke = function(player)
	return EconomyService.Rebirth(player)
end

-- Only ever called after the player clicks "Yes" on the client-side sell
-- confirmation dialog (see RequestSellConfirm above) — CreatureService.
-- SellCreature itself already re-validates the slot still holds a sellable
-- creature and recomputes the real payout, so this is a plain pass-through,
-- same shape as rebirthFn's own handler above.
confirmSellCreatureFn.OnServerInvoke = function(player, slotIndex)
	return CreatureService.SellCreature(player, slotIndex)
end

setJumpHeightFractionFn.OnServerInvoke = function(player, fraction)
	return EconomyService.SetJumpHeightFraction(player, fraction)
end

getWheelStateFn.OnServerInvoke = function(player)
	return WheelService.GetState(player)
end

spinWheelFreeFn.OnServerInvoke = function(player)
	return WheelService.SpinWheel(player)
end

getDiscoveredCreaturesFn.OnServerInvoke = function(player)
	local data = PlayerDataManager.Get(player)
	local discovered = (data and data.DiscoveredCreatures) or {}

	local list = {}
	for _, def in ipairs(GameConfig.Creatures) do
		local rarityDef = GameConfig.CreatureRarities[def.Rarity]
		table.insert(list, {
			Name = def.Name,
			Rarity = def.Rarity,
			Color = rarityDef and rarityDef.Color,
			MinRate = rarityDef and rarityDef.MinRate,
			MaxRate = rarityDef and rarityDef.MaxRate,
			-- On request ("kann man das im Brainrot Dex berücksichtigen, das
			-- immer der richtige Wert angezeigt wird") — THIS player's exact,
			-- real Cash/sec for this specific creature right now (this
			-- player's Rebirth count, owned gamepasses, and any running
			-- temporary Glücksrad buff all included — see EconomyService.
			-- GetCreatureRateForPlayer), replacing the old generic rarity-wide
			-- "$Min - $Max/s" range the Dex used to show for every creature.
			-- Sent for every creature regardless of Discovered, on request.
			Rate = EconomyService.GetCreatureRateForPlayer(player, def.Name),
			Discovered = discovered[def.Name] == true,
		})
	end
	return list
end

getLeaderboardPanelDataFn.OnServerInvoke = function(player)
	return LeaderboardService.GetPanelData(player)
end

requestTradeFn.OnServerInvoke = function(player, targetUserId)
	return TradeService.RequestTrade(player, targetUserId)
end

respondTradeFn.OnServerInvoke = function(player, accept)
	return TradeService.RespondTrade(player, accept)
end

setTradeOfferFn.OnServerInvoke = function(player, creatureName)
	return TradeService.SetOffer(player, creatureName)
end

confirmTradeFn.OnServerInvoke = function(player)
	return TradeService.Confirm(player)
end

cancelTradeFn.OnServerInvoke = function(player)
	return TradeService.Cancel(player)
end

-- === Build the tower and the player bases =======================================
BaseService.BuildPlots()
TradeService.BuildZone()

TowerGenerator.Build(
	function(player, floorIndex)
		EconomyService.OnFloorReached(player, floorIndex)
	end,
	function(floorIndex, count)
		return CreatureService.RollChoices(floorIndex, count)
	end,
	function(player, def, floorIndex)
		-- Anti-cheat (on request, part of the same floor-skip review as
		-- EconomyService.OnFloorReached): a claim spot only lives on a
		-- floor the player must have PHYSICALLY reached to stand on, but a
		-- speed/fly hack could reach one without ever legitimately earning
		-- the floors below it. Require data.HighestFloor to already cover
		-- this spot's own floor before honoring the claim — same "must have
		-- really reached it" principle as the Fast-Travel fix
		-- (FastTravelService.Teleport), just enforced here instead since
		-- claim spots aren't gated through OnFloorReached at all.
		local data = PlayerDataManager.Get(player)
		if not data or (floorIndex and data.HighestFloor < floorIndex) then
			if remotesFolder then
				remotesFolder.Notice:FireClient(player, "Du musst diesen Floor erst selbst erreichen, bevor du hier etwas beanspruchen kannst.")
			end
			return false
		end
		return CreatureService.ClaimPhysicalCreature(player, def)
	end,
	function(player)
		SummitChestService.Open(player)
	end
)

-- Permanent Glücks-Truhen (AdminAbuseService.lua) — auf Wunsch jetzt eine
-- eigene, dauerhafte Beschäftigung statt nur während eines manuell
-- getriggerten "/adminabuse"-Fensters (siehe GameConfig.AdminAbuse's und
-- AdminAbuseService.lua's eigenen Kommentar). Muss NACH TowerGenerator.Build
-- oben stehen — die Truhen brauchen TowerGenerator.GetRandomFloorPlatform,
-- das erst ab jetzt echte Etagen zurückgibt.
AdminAbuseService.StartPermanentChests()

-- Global Hall of Fame board — physically at the tower's base, see
-- LeaderboardService.BuildBoard's own comment for the exact placement
-- reasoning. Built after the tower itself so its "clear of every low
-- floor" radius math has an actual built tower to be right about (though
-- in practice it only reads GameConfig, not the built Parts).
LeaderboardService.BuildBoard()

-- === Player lifecycle ===========================================================
local hasSpawnedOnce = {} -- [player] = true once their FIRST character has been placed at their base

Players.PlayerAdded:Connect(function(player)
	local data = PlayerDataManager.Load(player)

	-- Freundschafts-Boost: whoever just joined might be Roblox-friends with
	-- someone already here (or vice versa) — recompute for everyone now
	-- connected (see EconomyService.RecalculateFriendBoosts' own comment),
	-- then push a fresh DataUpdated to everyone ELSE already in the server
	-- so their HUD badge (UIBuilder's FriendBoostRow) updates immediately
	-- instead of waiting for their next unrelated action. The new player
	-- themselves gets their own first DataUpdated a bit further down (once
	-- their base/character are set up), already reflecting the recomputed
	-- boost by then, so they're skipped here to avoid firing before their
	-- UI even exists client-side.
	EconomyService.RecalculateFriendBoosts()
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player then
			EconomyService.FireDataUpdated(otherPlayer)
		end
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local cashStat = Instance.new("IntValue")
	cashStat.Name = "Cash"
	cashStat.Value = data.Cash
	cashStat.Parent = leaderstats

	local floorStat = Instance.new("IntValue")
	floorStat.Name = "Floor"
	floorStat.Value = data.HighestFloor
	floorStat.Parent = leaderstats

	local rebirthStat = Instance.new("IntValue")
	rebirthStat.Name = "Wiedergeburten" -- on request ("ändere Rebirth auch in Wiedergeburt") — shown as-is in Roblox's default top-right leaderstats panel
	rebirthStat.Value = data.Rebirths
	rebirthStat.Parent = leaderstats

	-- cheap polling to keep the classic leaderboard in sync; fine at prototype scale
	task.spawn(function()
		while player.Parent do
			cashStat.Value = math.floor(data.Cash)
			floorStat.Value = data.HighestFloor
			rebirthStat.Value = data.Rebirths
			task.wait(1)
		end
	end)

	player.CharacterAdded:Connect(function(character)
		task.wait(0.5) -- let Humanoid finish loading
		EconomyService.ApplyJumpPower(player)
		-- Fixed global WalkSpeed (the removed Prestige-Turm Tempo-Schuhe
		-- system used to apply a per-player value here instead — see
		-- EconomyService's history — but that was replaced by the extended
		-- jump-height system, so this is back to the original simple line).
		local humanoidForSpeed = character:FindFirstChildOfClass("Humanoid")
		if humanoidForSpeed then
			humanoidForSpeed.WalkSpeed = GameConfig.Movement.WalkSpeed
		end
		RebirthCosmeticsService.Apply(player)

		-- Only reposition to the base on the player's VERY FIRST spawn. Later
		-- respawns (falling, a Hazard trap) should still use the normal
		-- checkpoint/SpawnLocation system, not reset all the way to the base.
		if not hasSpawnedOnce[player] then
			hasSpawnedOnce[player] = true
			local root = character:FindFirstChild("HumanoidRootPart")
			local spawnCFrame = BaseService.GetSpawnCFrame(player)
			if root and spawnCFrame then
				root.CFrame = spawnCFrame
			end
		end

		-- Players.CharacterAutoLoads = false (see above) means Roblox no
		-- longer respawns a character automatically after death — normally
		-- that's built in, but disabling auto-load to control the FIRST
		-- spawn turned it off entirely. So death-respawn has to be done by
		-- hand here: wait a short beat, then load a fresh character. Roblox
		-- then places them at player.RespawnLocation (the last checkpoint
		-- they touched) or Floor 1's SpawnLocation if they haven't reached
		-- one yet — exactly the normal checkpoint behavior, untouched.
		local humanoid = character:WaitForChild("Humanoid")
		humanoid.Died:Connect(function()
			task.wait(2)
			if player.Parent then
				player:LoadCharacter()
			end
		end)
	end)

	-- Debug: type "/event on" or "/event off" in chat to manually force the
	-- weekly Hacker/Lava event (GameConfig.Event) on or off, instead
	-- of waiting for Sunday 18:00-19:00 — makes it actually testable. Only
	-- works in Studio, or for the published game's creator, so random
	-- players on a live server can't grant themselves the event drop.
	player.Chatted:Connect(function(message)
		local isAllowed = RunService:IsStudio() or player.UserId == game.CreatorId
		if not isAllowed then
			return
		end

		local lower = message:lower()
		if lower == "/event on" or lower == "/event off" then
			EventService.SetForceActive(lower == "/event on")
			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				EconomyService.FireDataUpdated(otherPlayer)
			end
		elseif lower:match("^/adminabuse") then
			-- "/adminabuse" (Standarddauer), "/adminabuse <Minuten>", oder
			-- "/adminabuse off" — siehe AdminAbuseService.lua für was das
			-- eigentlich alles anschaltet (Drop-Boost + Optik + höhere
			-- Kreatur-Chance bei den ohnehin permanent laufenden
			-- Glücks-Truhen).
			if lower == "/adminabuse off" then
				AdminAbuseService.Stop()
			else
				local minutesStr = lower:match("^/adminabuse%s+(%d+)")
				local minutes = minutesStr and tonumber(minutesStr) or GameConfig.AdminAbuse.DefaultDurationMinutes
				AdminAbuseService.Start(player, minutes)
			end
		elseif lower == "/resetdata" then
			-- Debug: wipes THIS player's save (Cash, Rebirths, JumpPoints, and
			-- crucially CreatureLog) back to a clean slate and rebuilds their
			-- base. Exists for exactly the "old save from before a content
			-- rename" situation — e.g. a save made before the Italian
			-- Brainrot roster rename still has old creature names in
			-- CreatureLog that no longer exist in GameConfig.Creatures, so
			-- those pedestals show "+$0/s" and no model forever (nothing else
			-- can fix that — there's no old-name-to-new-name mapping). See
			-- PlayerDataManager.Reset for the actual wipe.
			PlayerDataManager.Reset(player)
			EconomyService.ApplyJumpPower(player)
			BaseService.RefreshBase(player)
			EconomyService.FireDataUpdated(player)
			remotesFolder.Notice:FireClient(
				player,
				"Spielstand zurückgesetzt! Alte Brainrots sind weg — klettere erneut für die neuen."
			)
		elseif lower == "/resetdata all" then
			-- Same wipe as "/resetdata" above, just looped over EVERY player
			-- currently in the server instead of just the one who typed it —
			-- for a shared Studio/test-server session with your whole test
			-- group in it at once, instead of everyone having to type the
			-- single-player command themselves. Only wipes players who are
			-- actually connected RIGHT NOW — someone who joins later, or an
			-- old DataStore save from a player who isn't in this server, is
			-- untouched (there's no "list every save that ever existed"
			-- lookup here, on purpose — DataStore key enumeration is slow/
			-- rate-limited and not worth it for a debug command).
			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				PlayerDataManager.Reset(otherPlayer)
				EconomyService.ApplyJumpPower(otherPlayer)
				BaseService.RefreshBase(otherPlayer)
				EconomyService.FireDataUpdated(otherPlayer)
				remotesFolder.Notice:FireClient(
					otherPlayer,
					"Spielstand zurückgesetzt (von " .. player.Name .. " für den ganzen Server)! Alte Brainrots sind weg — klettere erneut für die neuen."
				)
			end
		elseif lower:match("^/rebirth") then
			-- Debug: "/rebirth <N>" force-sets THIS player's own Wiedergeburt-
			-- Zahl direkt auf N (geklemmt auf [0, GameConfig.Rebirth.
			-- MaxRebirths]) — anders als eine echte Wiedergeburt (EconomyService.
			-- Rebirth) werden dabei Cash/JumpPoints/HighestFloor NICHT
			-- zurückgesetzt, rein ein Debug-Shortcut zum Testen von allem,
			-- was an eine bestimmte Wiedergeburts-Zahl gekoppelt ist (z.B. der
			-- Prestige-Turm, siehe GameConfig.Prestige.UnlockRebirths), ohne
			-- dafür wirklich 15x durchzuspielen. Gleiches IsStudio-oder-
			-- Ersteller-Gate wie jeder andere Debug-Befehl hier oben.
			local rebirthsStr = lower:match("^/rebirth%s+(%d+)")
			local newRebirths = rebirthsStr and tonumber(rebirthsStr)
			if newRebirths then
				local data = PlayerDataManager.Get(player)
				if data then
					data.Rebirths = math.clamp(math.floor(newRebirths), 0, GameConfig.Rebirth.MaxRebirths)
					RebirthCosmeticsService.Apply(player)
					BaseService.RefreshBase(player)
					EconomyService.FireDataUpdated(player)
					remotesFolder.Notice:FireClient(player, "Debug: Wiedergeburt auf " .. data.Rebirths .. " gesetzt.")
				end
			end
		elseif lower:match("^/pitch") then
			-- Debug: "/pitch <PitchGrad> <RollGrad>" instantly rebuilds YOUR
			-- OWN base with every pedestal's model temporarily forced to
			-- these pitch/roll values (overriding whatever GameConfig would
			-- normally use), so you can try values live and see the result
			-- in under a second instead of editing GameConfig + Stop+Play
			-- for every single try. "/pitch off" (or "/pitch clear") removes
			-- the override again so every creature goes back to its normal
			-- (GameConfig-defined) pitch/roll.
			--
			-- This affects EVERY pedestal at once, not just one creature —
			-- useful for quickly narrowing down a value while looking at
			-- one specific pedestal, but since the pack's models are NOT
			-- all misoriented the same way (confirmed via the raw-size
			-- debug prints), the value that looks right here still needs to
			-- be copied into THAT creature's own ModelPitchDegrees /
			-- ModelRollDegrees in GameConfig.Creatures afterwards — this
			-- command never saves anything by itself, it only previews.
			if lower == "/pitch off" or lower == "/pitch clear" then
				CreatureModelDisplay.ClearDebugOverride()
				BaseService.RefreshBase(player)
				remotesFolder.Notice:FireClient(player, "Pitch/Roll-Vorschau aus — zurück zu den normalen Werten.")
			elseif lower == "/pitch cycle" then
				-- Gives pedestal #1 Pitch=0, #2 Pitch=90, #3 Pitch=180, #4
				-- Pitch=270 (wrapping if you have more than 4 pedestals) —
				-- Roll stays 0 for all of them. Each pedestal's name label
				-- now shows exactly which value it's using (see
				-- BaseService's nameLabel), so ONE screenshot of your base
				-- shows all 4 candidates at once instead of testing them
				-- one at a time.
				CreatureModelDisplay.SetDebugCycle({
					{ Pitch = 0, Roll = 0 },
					{ Pitch = 90, Roll = 0 },
					{ Pitch = 180, Roll = 0 },
					{ Pitch = 270, Roll = 0 },
				})
				BaseService.RefreshBase(player)
				remotesFolder.Notice:FireClient(
					player,
					"Pitch-Vergleich an: Pedestal 1=0°, 2=90°, 3=180°, 4=270° (Roll=0) — auf den Namen schauen!"
				)
			elseif lower == "/pitch cycleroll" then
				-- Same idea, but cycling Roll instead (Pitch stays 0) — use
				-- this if the pitch cycle above didn't find a good value,
				-- since that means the model needs to tip sideways instead
				-- of forward/backward.
				CreatureModelDisplay.SetDebugCycle({
					{ Pitch = 0, Roll = 0 },
					{ Pitch = 0, Roll = 90 },
					{ Pitch = 0, Roll = 180 },
					{ Pitch = 0, Roll = 270 },
				})
				BaseService.RefreshBase(player)
				remotesFolder.Notice:FireClient(
					player,
					"Roll-Vergleich an: Pedestal 1=0°, 2=90°, 3=180°, 4=270° (Pitch=0) — auf den Namen schauen!"
				)
			else
				local pitchStr, rollStr = lower:match("^/pitch%s+(-?%d+%.?%d*)%s+(-?%d+%.?%d*)")
				local pitch = pitchStr and tonumber(pitchStr)
				local roll = rollStr and tonumber(rollStr)
				if pitch and roll then
					CreatureModelDisplay.SetDebugOverride(pitch, roll)
					BaseService.RefreshBase(player)
					remotesFolder.Notice:FireClient(
						player,
						"Vorschau: Pitch=" .. pitch .. " Roll=" .. roll .. " (nur Vorschau, noch nicht gespeichert)"
					)
				else
					remotesFolder.Notice:FireClient(
						player,
						"Benutzung: /pitch <Pitch> <Roll>  |  /pitch cycle  |  /pitch cycleroll  |  /pitch off"
					)
				end
			end
		elseif lower:match("^/yaw") then
			-- Debug: same idea as "/pitch" above, but for the FACING
			-- direction (ModelYRotation) instead of "stand it upright".
			-- Kept separate from /pitch on purpose, so you can test facing
			-- and upright-ness independently. "/yaw <Grad>" forces every
			-- pedestal to that facing; "/yaw cycle" gives pedestal #1 0°,
			-- #2 90°, #3 180°, #4 270° so you can compare 4 facings in one
			-- screenshot; "/yaw off" clears it. As with /pitch, this only
			-- PREVIEWS — once you find a good value for a creature, it
			-- still needs to be copied into that creature's own
			-- ModelYRotation in GameConfig.Creatures to stick permanently.
			if lower == "/yaw off" or lower == "/yaw clear" then
				CreatureModelDisplay.ClearDebugYawOverride()
				BaseService.RefreshBase(player)
				remotesFolder.Notice:FireClient(player, "Yaw-Vorschau aus — zurück zu den normalen Werten.")
			elseif lower == "/yaw cycle" then
				CreatureModelDisplay.SetDebugYawCycle({ 0, 90, 180, 270 })
				BaseService.RefreshBase(player)
				remotesFolder.Notice:FireClient(
					player,
					"Yaw-Vergleich an: Pedestal 1=0°, 2=90°, 3=180°, 4=270° — auf den Namen schauen!"
				)
			else
				local yawStr = lower:match("^/yaw%s+(-?%d+%.?%d*)")
				local yaw = yawStr and tonumber(yawStr)
				if yaw then
					CreatureModelDisplay.SetDebugYawOverride(yaw)
					BaseService.RefreshBase(player)
					remotesFolder.Notice:FireClient(
						player,
						"Vorschau: Yaw=" .. yaw .. " (nur Vorschau, noch nicht gespeichert)"
					)
				else
					remotesFolder.Notice:FireClient(player, "Benutzung: /yaw <Grad>  |  /yaw cycle  |  /yaw off")
				end
			end
		elseif lower:match("^/faceoffset") then
			-- Debug: tunes the "always face the owner" calibration
			-- (CreatureModelDisplay.CaptureRigidPose) LIVE, separately for
			-- the left and right pedestal columns — turned out the two
			-- columns need DIFFERENT correction values (see that function's
			-- own comment), so unlike /pitch and /yaw above this always
			-- takes two numbers. "/faceoffset <links> <rechts>" previews
			-- both at once (RefreshBase re-captures every pedestal's pose
			-- with the new values); "/faceoffset off" goes back to the
			-- DEFAULT_FACE_CORRECTION_DEG default for both. Once a value
			-- looks right for a side, it still needs to be copied into
			-- DEFAULT_FACE_CORRECTION_DEG (or a real per-side constant) in
			-- CreatureModelDisplay.lua to stick permanently — this command
			-- only previews, same as /pitch and /yaw.
			if lower == "/faceoffset off" or lower == "/faceoffset clear" then
				CreatureModelDisplay.ClearDebugFaceOffset()
				BaseService.RefreshBase(player)
				remotesFolder.Notice:FireClient(player, "Face-Offset-Vorschau aus — zurück zum Standardwert.")
			else
				local leftStr, rightStr = lower:match("^/faceoffset%s+(-?%d+%.?%d*)%s+(-?%d+%.?%d*)")
				local left = leftStr and tonumber(leftStr)
				local right = rightStr and tonumber(rightStr)
				if left and right then
					CreatureModelDisplay.SetDebugFaceOffset(left, right)
					BaseService.RefreshBase(player)
					remotesFolder.Notice:FireClient(
						player,
						"Vorschau: Links=" .. left .. " Rechts=" .. right .. " (nur Vorschau, noch nicht gespeichert)"
					)
				else
					remotesFolder.Notice:FireClient(player, "Benutzung: /faceoffset <Links> <Rechts>  |  /faceoffset off")
				end
			end
		elseif lower:match("^/kick") then
			-- On request ("wie kann ich leute vom server kicken") — same
			-- Studio-or-Creator-only gate as every other command in this
			-- handler (see isAllowed above), so random players on a live
			-- server can never kick anyone. Matched against the ORIGINAL
			-- `message`, not the already-lowercased `lower`, so the target
			-- name keeps its real casing for the Kick() reason text below —
			-- the actual player search is still fully case-insensitive
			-- (both sides go through :lower()).
			local nameArg = message:match("^/[Kk][Ii][Cc][Kk]%s+(.+)$")
			-- Trims trailing/leading whitespace the %s+ above can't fully
			-- absorb by itself (e.g. "/kick Bob   " would otherwise capture
			-- "Bob   " with trailing spaces still attached, or "/kick   "
			-- with nothing but spaces would capture a single lone space
			-- instead of being recognized as "no name given").
			nameArg = nameArg and nameArg:match("^%s*(.-)%s*$")
			if not nameArg or nameArg == "" then
				remotesFolder.Notice:FireClient(player, "Benutzung: /kick <Spielername>")
			else
				-- Partial, case-insensitive match (first hit wins) — same
				-- "type roughly the name, don't need the exact spelling/
				-- case" ergonomics as most in-game admin kick commands, so
				-- you don't have to pause the action to go copy the exact
				-- username first.
				local needle = nameArg:lower()
				local target = nil
				for _, otherPlayer in ipairs(Players:GetPlayers()) do
					if otherPlayer.Name:lower():find(needle, 1, true) then
						target = otherPlayer
						break
					end
				end

				if not target then
					remotesFolder.Notice:FireClient(player, "Kein Spieler gefunden mit \"" .. nameArg .. "\" im Namen.")
				elseif target == player then
					remotesFolder.Notice:FireClient(player, "Du kannst dich nicht selbst kicken.")
				else
					target:Kick("Vom Server entfernt (von " .. player.Name .. ").")
				end
			end
		end
	end)

	-- Assign the base plot BEFORE spawning the character, so GetSpawnCFrame
	-- above already has a plot to place them on for this very first spawn.
	--
	-- FIX: this also has to happen BEFORE FireDataUpdated right below, not
	-- after — FireDataUpdated calls BaseService.UpdateStationLabels
	-- (EconomyService.lua's comment on that), which just returns early with
	-- nothing done if playerPlot[player] isn't set yet. With AssignPlayer
	-- called afterward (the old order), a fresh join's "Nur [price]" kiosk
	-- text never got its first paint — it silently stayed on whatever the
	-- kiosk already displayed (its initial "—" placeholder, or a leftover
	-- reset from the previous occupant) until the NEXT FireDataUpdated call,
	-- which only happens on some later Cash/Tier/Rebirth-affecting action
	-- (e.g. collecting a pedestal's Cash) — exactly matching "die Schrift
	-- 'NUR' ... kommt erst wenn man das Geld eingesammelt hast".
	BaseService.AssignPlayer(player)
	BaseService.RefreshBase(player)

	EconomyService.FireDataUpdated(player)

	-- Push this player's current Rebirths/LifetimeCashEarned into the
	-- global leaderboard right away instead of waiting up to
	-- GameConfig.Leaderboard.SyncIntervalSeconds for the next periodic
	-- sync — cheap (2 SetAsync calls), and means a returning player's
	-- numbers show up on the board promptly.
	LeaderboardService.SyncPlayer(player)

	player:LoadCharacter()
end)

Players.PlayerRemoving:Connect(function(player)
	-- Capture this player's final Rebirths/LifetimeCashEarned for the
	-- global leaderboard BEFORE their data is released — same reasoning as
	-- the join-time sync above, just at the other end of the session.
	LeaderboardService.SyncPlayer(player)
	PlayerDataManager.Save(player)
	PlayerDataManager.Release(player)
	BaseService.ReleasePlayer(player)
	TradeService.ReleasePlayer(player)
	EconomyService.ReleaseJumpHeightPreference(player)
	EconomyService.ReleaseFloorProgressTracking(player)
	EconomyService.ReleaseFriendBoost(player)
	-- Recompute everyone ELSE still connected — this player leaving might
	-- have been someone else's only present friend (see
	-- RecalculateFriendBoosts' own comment on the excludePlayer param) —
	-- then push a fresh DataUpdated to all of them so their HUD badge
	-- drops/shrinks immediately instead of looking stale until their next
	-- unrelated action.
	EconomyService.RecalculateFriendBoosts(player)
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player then
			EconomyService.FireDataUpdated(otherPlayer)
		end
	end
	hasSpawnedOnce[player] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		PlayerDataManager.Save(player)
	end
end)

EconomyService.StartPassiveIncomeLoop()
BaseService.StartFacingLoop()
LeaderboardService.StartPeriodicSync()

-- On request ("ein Spieler hat sich vom PC auf dem Handy eingeloggt und den
-- aktuellen Speicherstand verloren") — see PlayerDataManager.
-- StartPeriodicAutoSave's own comment for the full diagnosis; this just
-- starts that loop once, same convention as the 3 loops right above.
PlayerDataManager.StartPeriodicAutoSave()
