--[[
	MonetizationService.lua
	Checks & caches Game Pass ownership, and handles Robux Developer Product
	purchases — the Jump Upgrade panel's Sprung-point packs (GameConfig.
	JumpUpgrade.RobuxProducts), the Glücksrad's two paid extra-spin bundles
	(GameConfig.WheelOfFortune.RobuxProducts — "Kaufe 1"/"Kaufe 3"), the Fast-Travel kiosk's 4 paid
	checkpoint teleports (GameConfig.FastTravel.Checkpoints), AND — despite
	still living in GameConfig.Gamepasses — 2x Cash/4x Cash/Auto-Sammeln,
	which turned out to be Developer Products too (see that table's own big
	comment on how "Fehler, egal welche Id" purchase failures traced back to
	this) — via ONE shared ProcessReceipt. Gamepass/Product IDs are
	placeholders (0) in GameConfig until you publish the game once and
	create the real Game Passes / Developer Products in Studio's
	Monetization tab — see README.md and GameConfig.JumpUpgrade's comment.

	Two different "does this player own it" strategies live side by side
	here: checkOwnership below asks Roblox live (UserOwnsGamePassAsync,
	cached) — correct ONLY for a real Game Pass, since Roblox remembers
	those forever on its own. OwnsDoubleCash/OwnsQuadCash/OwnsAutoCollect
	do NOT use checkOwnership — they read a plain PlayerData flag this game
	persists itself the moment ProcessReceipt grants that Developer Product,
	since Roblox has no equivalent "did they ever buy this" memory for
	Developer Products at all.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local MonetizationService = {}
local ownershipCache = {} -- [userId] = { [gamepassId] = bool }

local PlayerDataManager
local EconomyService
local WheelService
local FastTravelService

function MonetizationService.Init(deps)
	PlayerDataManager = deps.PlayerDataManager
	EconomyService = deps.EconomyService
	WheelService = deps.WheelService
	FastTravelService = deps.FastTravelService
end

local function checkOwnership(player, gamepassId)
	if not gamepassId or gamepassId == 0 then
		return false -- not configured yet
	end

	ownershipCache[player.UserId] = ownershipCache[player.UserId] or {}
	local cached = ownershipCache[player.UserId][gamepassId]
	if cached ~= nil then
		return cached
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
	end)

	local result = ok and owns or false
	ownershipCache[player.UserId][gamepassId] = result
	return result
end

-- DoubleCash/QuadCash/AutoCollect are Developer Products, not real Game
-- Passes (see GameConfig.Gamepasses' own big comment on how that was
-- diagnosed — "Fehler, egal welche Id" purchase failures traced back to a
-- Creator Dashboard screenshot showing all three under Developer Products).
-- Roblox has no "does this player own this Developer Product" API at all
-- (UserOwnsGamePassAsync only works for real Game Passes) — a Developer
-- Product purchase is a one-off event, not a standing ownership fact Roblox
-- tracks. So instead of asking Roblox (like checkOwnership below does for a
-- real Game Pass), these three just read the persisted flag this game sets
-- itself the moment ProcessReceipt sees the matching purchase (see its own
-- comment further down, and PlayerDataManager's DEFAULT_DATA for the
-- OwnsDoubleCash/OwnsQuadCash/OwnsAutoCollect fields) — a plain in-memory
-- table read, so no async call or cache is even needed here anymore.
function MonetizationService.OwnsDoubleCash(player)
	local data = PlayerDataManager and PlayerDataManager.Get(player)
	return data ~= nil and data.OwnsDoubleCash == true
end

-- "4x Cash" upgrade tier, see GameConfig.Gamepasses.QuadCash's own comment
-- for the full design (a separate purchase, replaces rather than stacks
-- with DoubleCash).
function MonetizationService.OwnsQuadCash(player)
	local data = PlayerDataManager and PlayerDataManager.Get(player)
	return data ~= nil and data.OwnsQuadCash == true
end

function MonetizationService.OwnsAutoClimb(player)
	return checkOwnership(player, GameConfig.Gamepasses.AutoClimb.Id)
end

function MonetizationService.OwnsVIP(player)
	return checkOwnership(player, GameConfig.Gamepasses.VIP.Id)
end

-- On request, replacing the removed Slap Hand kiosk — see
-- EconomyService.StartPassiveIncomeLoop for what owning this actually does
-- (auto-collects every pedestal's payout straight into Cash every tick).
function MonetizationService.OwnsAutoCollect(player)
	local data = PlayerDataManager and PlayerDataManager.Get(player)
	return data ~= nil and data.OwnsAutoCollect == true
end

function MonetizationService.Release(player)
	ownershipCache[player.UserId] = nil
end

-- Refresh the cache immediately after a successful purchase so the effect
-- applies without waiting for the next UserOwnsGamePassAsync call.
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamepassId, wasPurchased)
	if wasPurchased then
		ownershipCache[player.UserId] = ownershipCache[player.UserId] or {}
		ownershipCache[player.UserId][gamepassId] = true
	end
end)

-- === Developer Product purchases (Jump Upgrade's Robux Sprung-point packs, ===
-- === and the Glücksrad's paid extra spin) =====================================

-- Reverse lookup: ProductId -> how many Sprung-points it grants. Built once
-- from GameConfig.JumpUpgrade's two PARALLEL arrays (BulkAmounts /
-- RobuxProducts — same order, same count). Placeholder ProductId = 0 entries
-- are skipped on purpose — real Roblox product IDs are always > 0, so 0 can
-- never accidentally match a real receipt.
local jumpProductAmounts = {}
for i, amount in ipairs(GameConfig.JumpUpgrade.BulkAmounts) do
	local product = GameConfig.JumpUpgrade.RobuxProducts[i]
	if product and product.ProductId and product.ProductId > 0 then
		jumpProductAmounts[product.ProductId] = amount
	end
end

-- The Glücksrad's TWO extra-spin products (see GameConfig.WheelOfFortune.
-- RobuxProducts — split from an earlier single "buy one extra spin"
-- product into "Kaufe 1" / "Kaufe 3", on request) — same
-- placeholder-0-means-not-configured convention as jumpProductAmounts
-- above (a not-yet-created product's ProductId stays 0 and is skipped
-- here, same as jumpProductAmounts' own skip). Reverse lookup:
-- ProductId -> how many spins that purchase grants (1 or 3). A real Roblox
-- ProductId can never be 0, and Roblox guarantees every Developer Product
-- ID is unique across the whole game, so there's no risk of this colliding
-- with a real jumpProductAmounts entry.
local wheelSpinProductCounts = {}
for _, product in ipairs(GameConfig.WheelOfFortune.RobuxProducts) do
	if product.ProductId and product.ProductId > 0 then
		wheelSpinProductCounts[product.ProductId] = product.SpinCount
	end
end

-- Reverse lookup: ProductId -> which Floor that Fast-Travel checkpoint
-- teleports to (see GameConfig.FastTravel.Checkpoints / FastTravelService.
-- lua) — same placeholder-0-means-not-configured convention as
-- jumpProductAmounts above. There are 4 of these (Floor 25/50/75/100 by
-- default), each its own separate real Developer Product (a fixed Robux
-- price can't be set dynamically per purchase from a script).
local fastTravelProductFloors = {}
for _, checkpoint in ipairs(GameConfig.FastTravel.Checkpoints) do
	if checkpoint.ProductId and checkpoint.ProductId > 0 then
		fastTravelProductFloors[checkpoint.ProductId] = checkpoint.Floor
	end
end

-- The "1x Wiedergeburt" Robux button's single product (see GameConfig.
-- Rebirth.RobuxProduct / BaseService's kiosk that replaced VIP) — same
-- placeholder-0-means-not-configured convention as the others above.
local rebirthProductId = GameConfig.Rebirth.RobuxProduct.ProductId

-- 2x Cash / 4x Cash / Auto-Sammeln (see GameConfig.Gamepasses' own big
-- comment, and MonetizationService.OwnsDoubleCash/OwnsQuadCash/
-- OwnsAutoCollect above) — these three are Developer Products, so unlike a
-- real Game Pass, a successful purchase only ever shows up HERE, in
-- ProcessReceipt, and nowhere else. Each maps straight to which
-- PlayerData field to permanently flip to true.
local doubleCashProductId = GameConfig.Gamepasses.DoubleCash.Id
local quadCashProductId = GameConfig.Gamepasses.QuadCash.Id
local autoCollectProductId = GameConfig.Gamepasses.AutoCollect.Id

-- Roblox calls this for EVERY Developer Product purchase in the whole game
-- (there can only be ONE ProcessReceipt callback total — assigning a second
-- one elsewhere would silently replace this one, so if a future product
-- type is added, extend this same function rather than adding another
-- MarketplaceService.ProcessReceipt assignment anywhere else).
--
-- Roblox requires this to be safe to call MORE THAN ONCE for the exact same
-- purchase (it retries on any non-success return, or if the server was busy/
-- restarted) — data.ProcessedPurchaseIds tracks every PurchaseId this player
-- has ever been granted, persisted via PlayerDataManager.Save right after
-- granting, so a retried receipt is correctly recognized as already-handled
-- even after a reconnect or server restart, and the player is never charged
-- Robux without receiving their points, nor granted points twice for one
-- purchase.
MarketplaceService.ProcessReceipt = function(receiptInfo)
	if not PlayerDataManager or not EconomyService then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = game:GetService("Players"):GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Player isn't in this server (right now, or ever again) — Roblox
		-- will retry this same receipt later (including on their next join)
		-- until it gets a final decision, so it's safe to just wait.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = PlayerDataManager.Get(player)
	if not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	data.ProcessedPurchaseIds = data.ProcessedPurchaseIds or {}
	if data.ProcessedPurchaseIds[receiptInfo.PurchaseId] then
		-- Already granted this exact purchase before — tell Roblox it's
		-- done without granting anything a second time.
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local amount = jumpProductAmounts[receiptInfo.ProductId]
	local wheelSpinCount = wheelSpinProductCounts[receiptInfo.ProductId]
	local fastTravelFloor = fastTravelProductFloors[receiptInfo.ProductId]
	if amount then
		EconomyService.GrantJumpPoints(player, amount)
	elseif wheelSpinCount then
		if WheelService then
			WheelService.SpinWheelPaid(player, wheelSpinCount)
		end
	elseif fastTravelFloor then
		if FastTravelService then
			FastTravelService.Teleport(player, fastTravelFloor)
		end
	elseif rebirthProductId > 0 and receiptInfo.ProductId == rebirthProductId then
		-- Already-charged real Robux — Roblox requires this to be marked
		-- Granted regardless of the result (see the comment below), so the
		-- return value here is deliberately ignored, same as every other
		-- grant call above. In the rare case a player somehow already hit
		-- MaxRebirths by the time this resolves, BuyRebirthWithRobux simply
		-- no-ops (see EconomyService.performRebirth) — there's nothing left
		-- to grant, same reasoning as the "unrecognized ProductId" case
		-- below.
		EconomyService.BuyRebirthWithRobux(player)
	elseif doubleCashProductId > 0 and receiptInfo.ProductId == doubleCashProductId then
		-- See this file's own comment above OwnsDoubleCash — Developer
		-- Product, not a Game Pass, so THIS is the only place ownership is
		-- ever actually granted; nothing to do if it was somehow already
		-- true (re-buying can't happen from the kiosk once owned, but a
		-- retried receipt for the same purchase could reach here again).
		data.OwnsDoubleCash = true
		EconomyService.FireDataUpdated(player)
	elseif quadCashProductId > 0 and receiptInfo.ProductId == quadCashProductId then
		data.OwnsQuadCash = true
		EconomyService.FireDataUpdated(player)
	elseif autoCollectProductId > 0 and receiptInfo.ProductId == autoCollectProductId then
		data.OwnsAutoCollect = true
		EconomyService.FireDataUpdated(player)
	end
	-- An unrecognized ProductId (e.g. a product removed from GameConfig
	-- after being purchased) still gets marked granted below rather than
	-- retried forever — there's nothing meaningful left to grant for it.

	data.ProcessedPurchaseIds[receiptInfo.PurchaseId] = true
	PlayerDataManager.Save(player)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

return MonetizationService
