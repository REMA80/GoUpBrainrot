--[[
	FastTravelService.lua
	Paid Robux teleport straight to any of GameConfig.FastTravel.Checkpoints
	(Floor 25/50/75/100 by default) — on request: "Fast Travel für jeden 25
	Floor bis 100, mit Robux zu zahlen, nur wenn man diesen Floor schon
	erreicht hat, Kosten abhängig von der Floor Höhe".

	Reached from the shared Fast-Travel kiosk (BaseService.lua's
	buildFastTravelKiosk, same "no ownership gate, fake plotCFrame on its own
	small platform" pattern as the Jump-Upgrade trader/Glücksrad) — walking
	up to it opens a panel (UIBuilder.lua's Fast Travel panel /
	init.client.lua's RequestFastTravelPanel listener) listing all 4
	checkpoints, each showing its live Robux price (MarketplaceService.
	GetProductInfo, same as every other Robux button in this game) and
	whether THIS player has already reached that floor (lastData.
	HighestFloor, already pushed on every DataUpdated — no extra remote
	fetch needed) — a floor's Buy button only appears once it's been reached,
	same "hide, don't reject" convention as every other Robux purchase in
	this game.

	FastTravelService.Teleport (this file) is called from Monetization
	Service.ProcessReceipt once Roblox confirms the purchase. The panel's
	hidden-button gate above is just the UI convenience — since a security
	review, THIS function also re-checks data.HighestFloor itself before
	teleporting (on request: "jeder soll die Floor schon erreicht haben
	bevor es freigeschaltet wird"), so a modified client can no longer buy a
	teleport to a floor it never actually reached. Roblox still requires the
	already-charged Robux purchase to be marked Granted regardless (see
	MonetizationService.ProcessReceipt's own comment) — this check can only
	withhold the teleport itself, never refund/block the real charge.
]]

local GameConfig = require(game:GetService("ReplicatedStorage").Modules.GameConfig)

local FastTravelService = {}

local TowerGenerator
local PlayerDataManager
local EconomyService
local remotesFolder

function FastTravelService.Init(deps)
	TowerGenerator = deps.TowerGenerator
	PlayerDataManager = deps.PlayerDataManager
	EconomyService = deps.EconomyService
	remotesFolder = deps.Remotes
end

-- Called from MonetizationService.ProcessReceipt once Roblox confirms a real
-- purchase of one of GameConfig.FastTravel.Checkpoints' Developer Products.
-- Moves the player's OWN character to that floor's checkpoint (see
-- TowerGenerator.GetCheckpointCFrame — every one of the 4 configured floors
-- is already a real checkpoint floor, i % 5 == 0) and updates their
-- player.RespawnLocation to match, so a death shortly after the teleport
-- doesn't send them all the way back down to Floor 1.
function FastTravelService.Teleport(player, floorNumber)
	-- FIX (anti-cheat review, on request: "jeder soll die Floor schon
	-- erreicht haben bevor es freigeschaltet wird") — see this file's own
	-- header comment. Roblox still requires the ALREADY-CHARGED Robux
	-- purchase to be marked Granted regardless of what happens here (see
	-- MonetizationService.ProcessReceipt's own comment on that rule) — this
	-- can never un-charge the Robux, it only withholds the teleport itself.
	local data = PlayerDataManager and PlayerDataManager.Get(player)
	if not data or data.HighestFloor < floorNumber then
		if remotesFolder then
			remotesFolder.Notice:FireClient(
				player,
				"Diesen Floor musst du erst selbst erreichen, bevor Fast-Travel dorthin freigeschaltet ist."
			)
		end
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		-- No character loaded right now (mid-respawn, or the purchase
		-- somehow completed between sessions) — nothing sane to teleport.
		-- The Robux purchase itself is still granted either way (Roblox
		-- requires that regardless), just with no visible effect this
		-- instant; there's no queued/pending-teleport mechanism here since
		-- this should be exceedingly rare in practice (the panel that
		-- starts the purchase only exists while a character is loaded and
		-- standing at the kiosk).
		return
	end

	if not TowerGenerator then
		return
	end

	local checkpointCFrame, checkpointPart = TowerGenerator.GetCheckpointCFrame(floorNumber)
	if not checkpointCFrame then
		return
	end

	root.CFrame = checkpointCFrame
	if checkpointPart then
		player.RespawnLocation = checkpointPart
	end

	-- Tells the anti-cheat floor-skip check (EconomyService.OnFloorReached)
	-- that this jump straight to `floorNumber` was a trusted, server-driven
	-- teleport, not the player somehow covering that whole distance
	-- themselves — otherwise the very next real floor this player touches
	-- could get flagged as an implausible skip from wherever they were
	-- standing before the teleport.
	if EconomyService then
		EconomyService.ResetFloorProgressBaseline(player, floorNumber)
	end

	if remotesFolder then
		remotesFolder.Notice:FireClient(player, "🚀 Fast-Travel: Floor " .. tostring(floorNumber) .. "!")
	end
end

return FastTravelService
