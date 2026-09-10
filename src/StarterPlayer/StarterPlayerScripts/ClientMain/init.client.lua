--[[
	ClientMain/init.client.lua
	Builds the HUD, listens for server data updates, and wires button clicks
	to the RemoteEvents/Functions created by Server/init.server.lua. Also
	drives SoundPlayer.lua for UI/action sound effects (see GameConfig.Sounds
	for the actual SoundId list, and its own comment for how to fill one in).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

-- Fixes "Maus bleibt stehen, Kamera dreht sich nicht mehr, wenn ich mit der
-- Maus über ein Verkaufen-/Einsammeln-Symbol (ProximityPrompt in seinem
-- eingebauten Standard-Look) fahre". Das ist kein Bug in unserem eigenen
-- Code, sondern ein bekanntes Roblox-Engine-Verhalten: ein Standard-Style
-- ProximityPrompt markiert seine eigene (von Roblox intern erzeugte) GUI
-- als "Selectable", damit Gamepad-Spieler per Steuerkreuz dorthin
-- navigieren können. Auf PC reicht dafür aber schon reines Maus-Hovern,
-- um GuiService.SelectedObject zu setzen — und Robloxs eigenes
-- Standard-Kamera-Skript pausiert die Rechtsklick-Kamera-Drehung
-- IMMER, solange irgendein GUI-Element "selected" ist (normalerweise
-- damit man mit Gamepad/Tastatur durch Menüs statt die Kamera zu drehen
-- navigieren kann). Unsere eigenen Kiosk-Billboards (Truhe, Glücksrad,
-- Fast-Travel, siehe BaseService.lua's buildStationPart) haben dieses
-- Problem nie gezeigt, weil sie eigene, nicht-selektierbare BillboardGuis
-- sind statt Robloxs eingebauter Prompt-Optik — nur die Ernte-/Verkaufs-
-- ProximityPrompts an den Pedestalen nutzen bisher den Default-Style.
-- GuiNavigationEnabled = false schaltet genau dieses automatische
-- Gamepad-Navigations-System global ab (wir haben ohnehin keine eigene
-- GUI, die Gamepad-Steuerkreuz-Navigation braucht), wodurch nie wieder
-- ein SelectedObject durch bloßes Drüberfahren mit der Maus gesetzt wird.
GuiService.GuiNavigationEnabled = false

-- Shows the raw error text directly ON SCREEN, not just in Studio's Output
-- window — added after a report that the ENTIRE custom UI (stats HUD, Dex
-- button, Jump Upgrade panel, everything) was silently missing with no
-- error anyone could find. If that happens again, this makes it impossible
-- to miss, and gives an exact error message to go on instead of guessing.
-- Deliberately built from raw Instance.new calls only — no dependency on
-- UIBuilder/GameConfig, since those are exactly what might be failing.
local function showFatalError(message)
	local ok = pcall(function()
		local playerGui = player:WaitForChild("PlayerGui")
		local gui = Instance.new("ScreenGui")
		gui.Name = "ClientMainFatalError"
		gui.ResetOnSpawn = false
		gui.Parent = playerGui

		local box = Instance.new("Frame")
		box.Size = UDim2.new(0, 560, 0, 240)
		box.Position = UDim2.new(0.5, -280, 0, 20)
		box.BackgroundColor3 = Color3.fromRGB(120, 20, 20)
		box.BackgroundTransparency = 0.05
		box.Parent = gui

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -16, 1, -16)
		label.Position = UDim2.new(0, 8, 0, 8)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.Code
		label.TextSize = 14
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.Text = "ClientMain-Fehler (bitte Screenshot senden):\n\n" .. tostring(message)
		label.Parent = box
	end)
	if not ok then
		warn("[ClientMain] showFatalError itself failed — see the warn() above this for the real error.")
	end
end

-- Everything that used to run directly at the top level now runs inside
-- main(), wrapped in a pcall below — so ANY error anywhere in this script
-- (a bad require, a nil remote, anything) gets caught, printed via warn(),
-- AND shown on screen via showFatalError above, instead of failing silently
-- partway through with nothing left on screen to show for it.
local function main()
	local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
	local UIBuilder = require(script.UIBuilder)
	local SoundPlayer = require(script.SoundPlayer)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")

	local ui = UIBuilder.Build(player)
	SoundPlayer.Init()
	-- Ticks the red "2x Cash (Xs)" badge's countdown text every second on
	-- its own, since DataUpdated payloads don't arrive every second (see
	-- UIBuilder.StartDoubleCashCountdownLoop's comment).
	UIBuilder.StartDoubleCashCountdownLoop(ui)

-- Keeps the latest DataUpdated payload around so the Rebirth confirmation
-- dialog (built when the button is clicked) can describe exactly what the
-- player is about to gain/lose without a extra round-trip to the server.
local lastData = nil

local function refreshStats(data)
	local previous = lastData
	lastData = data

	-- No "Cash: " / "Jump: " prefix anymore — the big bottom-left display's
	-- own icon (💰 / 👟, see UIBuilder.Build's BigStatsFrame) already says
	-- what each number is, same as the reference screenshot this style was
	-- matched to.
	-- On request ("eine Anzeige wo man sieht wieviel cash/s man bekommt") —
	-- appended right onto the existing big Cash number instead of a whole
	-- separate HUD element, e.g. "$1.234 (+56/s)".
	ui.CashLabel.Text = "$" .. UIBuilder.FormatNumber(data.Cash) .. " (+" .. UIBuilder.FormatNumber(data.CashPerSecond or 0) .. "/s)"
	-- Denominator includes the Prestige-Turm's 20 extra floors (see
	-- GameConfig.Prestige) on top of the normal Floors.Count, so a player
	-- who's climbed past Floor 100 doesn't see a nonsensical "105 / 100" —
	-- but ONLY while GameConfig.Prestige.Enabled is true; while disabled the
	-- tower physically only has Floors.Count floors (see TowerGenerator), so
	-- showing "100" here matches reality with no trace of the unreleased
	-- content in the HUD.
	local floorDenominator = GameConfig.Floors.Count
	if GameConfig.Prestige.Enabled then
		floorDenominator += GameConfig.Prestige.FloorCount
	end
	ui.FloorLabel.Text = "Floor: " .. data.HighestFloor .. " / " .. floorDenominator
	ui.RebirthLabel.Text = "Wiedergeburten: " .. data.Rebirths .. " / " .. data.MaxRebirths
	ui.TierLabel.Text = data.JumpTierName .. " (" .. math.floor(data.JumpPower + 0.5) .. ")"

	UIBuilder.UpdateEventBanner(ui, data)
	UIBuilder.UpdateDoubleCashBadge(ui, data)
	UIBuilder.UpdateFriendBoostBadge(ui, data)
	UIBuilder.UpdateJumpHeightPanel(ui, data)

	-- Keeps the Jump Upgrade panel's prices/affordability live while it's
	-- open (e.g. right after a purchase, or if Cash changes from a pedestal
	-- pickup while the panel is up) — same idea as UpdateTradeWindow for the
	-- Trade window. Since the Prestige-Turm rework, this same panel already
	-- covers Tier 11-20 (Floor 101-120) too, via the combined ALL_JUMP_TIERS
	-- curve in EconomyService — no separate Speed-Upgrade panel needed
	-- anymore.
	if ui.JumpUpgradeOverlay.Visible then
		UIBuilder.PopulateJumpUpgrade(ui, data)
	end

	-- NOTE: the Upgrade/Rebirth button text-and-color updates and the Slap
	-- Hand shop-button refresh that used to live here are gone along with
	-- those buttons — Jump Upgrade, Rebirth, Slap Hand, 2x Cash, and VIP are
	-- now fixed physical kiosks in the player's base (see BaseService.lua),
	-- with their own BillboardGui status labels kept fresh server-side by
	-- BaseService.UpdateStationLabels — no client-side text to update here
	-- anymore.

	-- DataUpdated has no "why did this change" flag attached, so the right
	-- sound is picked by DIFFING against the previous payload instead — the
	-- economy only ever changes Cash/JumpPoints/Rebirths/HighestFloor
	-- through a small, known set of actions (see EconomyService), so which
	-- field(s) moved is enough to tell them apart. `previous` is nil on the
	-- very first DataUpdated after joining, which correctly plays nothing.
	if previous then
		if data.Rebirths > previous.Rebirths then
			-- Checked FIRST: a Rebirth also resets Cash/JumpPoints/
			-- HighestFloor in the same payload, and would otherwise
			-- wrongly also match the JumpPoints/Cash checks below.
			SoundPlayer.Play("Rebirth")
		elseif data.JumpPoints > previous.JumpPoints then
			-- Since the Prestige-Turm rework, this already fires correctly
			-- for Tier 11-20 (Floor 101-120) purchases too, since those are
			-- now part of the same combined JumpPoints curve — no separate
			-- SpeedPoints check needed anymore.
			SoundPlayer.Play("UpgradeBought")
		elseif data.Cash > previous.Cash then
			-- The only other way Cash goes UP is walking over a pedestal to
			-- collect its accumulated earnings (see EconomyService.
			-- StartPassiveIncomeLoop's comment — selling has its own
			-- CreatureSold sound below instead, and buying/rebirthing both
			-- only ever DECREASE Cash).
			SoundPlayer.Play("CashCollected")
		end

		if data.HighestFloor > previous.HighestFloor then
			SoundPlayer.Play("FloorReached")
		end

		if data.EventActive and not previous.EventActive then
			SoundPlayer.Play("EventStarted")
		end
	end
end

remotes.DataUpdated.OnClientEvent:Connect(refreshStats)

remotes.CreatureObtained.OnClientEvent:Connect(function(info)
	UIBuilder.ShowCreatureToast(ui, info)
	SoundPlayer.Play("CreatureClaimed")
end)

-- The old "pick 1 of 3 on your own screen" system (CreatureChoice /
-- ClaimCreatureChoice remotes) is gone — creature claims are now a shared
-- physical pickup on the tower floor itself (see TowerGenerator's
-- buildClaimSpot and CreatureService.ClaimPhysicalCreature), so there is no
-- client-side choice dialog to wire up anymore.

remotes.CreatureSold.OnClientEvent:Connect(function(info)
	UIBuilder.ShowSellToast(ui, info)
	SoundPlayer.Play("CreatureSold")
end)

-- On request ("eine Information das man das bekommt wäre toll") — fired
-- once, the exact moment a rarity's Brainrot-Dex completion bonus turns on
-- (see CreatureService.markDiscoveredAndNotifyCompletion / init.server.lua's
-- "DexRarityCompleted" event). info = { Rarity, BonusPercent }.
remotes.DexRarityCompleted.OnClientEvent:Connect(function(info)
	UIBuilder.ShowDexCompletionToast(ui, info)
	SoundPlayer.Play("TradeSuccess")
end)

-- Server-initiated notices (e.g. "Base voll!" when a Brainrot orb is touched
-- with no free pedestal left) — reuses the same red message banner as the
-- Upgrade/Rebirth error messages below.
remotes.Notice.OnClientEvent:Connect(function(text)
	UIBuilder.ShowMessage(ui, tostring(text))
	SoundPlayer.Play("Error")
end)

-- === Trading (see TradeService.lua) ============================================
-- The Trade Zone roster is a FIXED pool of GameConfig.Base.MaxPlayers - 1
-- buttons, built once by UIBuilder.Build (see its comment on tradeZonePanel)
-- and only ever mutated afterward — same pre-build/wire-once pattern as the
-- Jump Upgrade buttons above, so each row is wired directly, right here, a
-- single time, instead of a ChildAdded listener (which would never fire —
-- the rows already exist as children by the time this script runs). Reads
-- the target back off the Attribute UIBuilder keeps up to date on each row
-- (see UpdateTradeZoneRoster).
for _, row in ipairs(ui.TradeZoneRows) do
	row.Activated:Connect(function()
		SoundPlayer.Play("ButtonClick")
		local targetUserId = row:GetAttribute("TargetUserId")
		local success, err = remotes.RequestTrade:InvokeServer(targetUserId)
		if not success then
			UIBuilder.ShowMessage(ui, tostring(err))
			SoundPlayer.Play("Error")
		end
	end)
end

-- The trade window's "my Brainrots" item picker is a fixed pool too (one row
-- per GameConfig.Creatures entry), but built LAZILY on the first
-- ShowTradeWindow call rather than up front in UIBuilder.Build (see
-- ensureTradeItemRowsBuilt's comment in UIBuilder.lua for why) — so, unlike
-- the roster above, these rows genuinely don't exist yet when this script
-- runs, and a ChildAdded listener correctly catches each one exactly once,
-- the first time the trade window is ever opened.
ui.TradeItemsContent.ChildAdded:Connect(function(child)
	if not child:IsA("TextButton") then
		return
	end
	child.Activated:Connect(function()
		SoundPlayer.Play("ButtonClick")
		local creatureName = child:GetAttribute("CreatureName")
		local success, err = remotes.SetTradeOffer:InvokeServer(creatureName)
		if not success then
			UIBuilder.ShowMessage(ui, tostring(err))
			SoundPlayer.Play("Error")
		end
	end)
end)

remotes.TradeZoneRoster.OnClientEvent:Connect(function(players)
	UIBuilder.UpdateTradeZoneRoster(ui, players)
end)

remotes.TradeRequestReceived.OnClientEvent:Connect(function(info)
	UIBuilder.ShowTradeRequest(ui, info.FromName)
end)

remotes.TradeOpened.OnClientEvent:Connect(function(info)
	UIBuilder.ShowTradeWindow(ui, info.OpponentName, info.MyItems)
end)

remotes.TradeUpdate.OnClientEvent:Connect(function(state)
	UIBuilder.UpdateTradeWindow(ui, state)
end)

remotes.TradeClosed.OnClientEvent:Connect(function(info)
	UIBuilder.HideTradeWindow(ui)
	UIBuilder.ShowTradeResult(ui, info)
	SoundPlayer.Play(info.Success and "TradeSuccess" or "Error")
end)

ui.TradeAcceptButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideTradeRequest(ui)
	local success, err = remotes.RespondTrade:InvokeServer(true)
	if not success then
		UIBuilder.ShowMessage(ui, tostring(err))
		SoundPlayer.Play("Error")
	end
end)

ui.TradeDeclineButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideTradeRequest(ui)
	remotes.RespondTrade:InvokeServer(false)
end)

ui.TradeConfirmButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	local success, err = remotes.ConfirmTrade:InvokeServer()
	if not success then
		UIBuilder.ShowMessage(ui, tostring(err))
		SoundPlayer.Play("Error")
	end
end)

ui.TradeCancelButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideTradeWindow(ui)
	remotes.CancelTrade:InvokeServer()
end)

-- === Base-station actions (see BaseService.lua's buildStations) ===============
-- The Slap Hand kiosk (which used to buy entirely server-side, straight
-- from its own ProximityPrompt.Triggered handler — ShopService.
-- BuySlapHand) was REMOVED on request and replaced by the "Auto-Sammeln"
-- (Auto-Collect) gamepass kiosk at that same spot — like the 2x Cash
-- gamepass below, it just needs a MarketplaceService prompt opened
-- client-side, so it goes through the same RequestGamepassPrompt path, no
-- separate wiring needed here either. (ShopService.BuySlapHand itself, and
-- anyone who already owns the Tool, are untouched — only this kiosk's
-- purchase path is gone.) The VIP kiosk was likewise REMOVED and replaced
-- by "1x Wiedergeburt" — a Developer Product this time, not a Gamepass, so
-- it goes through its own RequestRebirthProductPrompt listener instead (see
-- below). Jump Upgrade, Rebirth, and every kiosk purchase now need a
-- client-side step (the bulk-buy panel / a confirm dialog / a
-- MarketplaceService prompt), so the kiosk relays those through
-- RequestJumpUpgradePanel / RequestRebirthConfirm / RequestGamepassPrompt /
-- RequestRebirthProductPrompt events instead.

-- Rebirth altar: walking up to it only asks the server to relay this event
-- back — the confirmation text is built here from the same lastData the HUD
-- already keeps up to date, exactly like the old RebirthButton click did.
remotes.RequestRebirthConfirm.OnClientEvent:Connect(function()
	if not lastData then
		return
	end

	if not lastData.NextRebirthCost then
		UIBuilder.ShowMessage(ui, "Maximale Wiedergeburt-Stufe erreicht (" .. lastData.MaxRebirths .. ")")
		return
	end

	if not lastData.CanRebirth then
		UIBuilder.ShowMessage(ui, "Nicht genug Cash (" .. UIBuilder.FormatNumber(lastData.NextRebirthCost) .. " nötig)")
		return
	end

	local currentBonusPct = math.floor(lastData.Rebirths * GameConfig.Rebirth.MultiplierPerRebirth * 100)
	local nextBonusPct = math.floor((lastData.Rebirths + 1) * GameConfig.Rebirth.MultiplierPerRebirth * 100)

	local message = "Wiedergeburt #" .. (lastData.Rebirths + 1) .. " für " .. UIBuilder.FormatNumber(lastData.NextRebirthCost) .. " Cash\n\n"
		.. "Du VERLIERST: dein Cash, deinen Sprung-Fortschritt (" .. lastData.JumpTierName .. "), und deinen Floor-Fortschritt (zurück auf Floor 1). Deine Brainrots bleiben erhalten.\n\n"
		.. "Du BEKOMMST: dauerhaft +" .. nextBonusPct .. "% Cash-Bonus (statt +" .. currentBonusPct .. "%), und +1 Stellplatz in deiner Base."

	UIBuilder.ShowRebirthConfirm(ui, message)
end)

ui.RebirthConfirmYes.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideRebirthConfirm(ui)
	local success, err = remotes.Rebirth:InvokeServer()
	if not success then
		UIBuilder.ShowMessage(ui, tostring(err))
		SoundPlayer.Play("Error")
	end
	-- On success, the Rebirth SFX itself plays from refreshStats' diff logic
	-- above (data.Rebirths increasing) once the resulting DataUpdated
	-- arrives, not here — this only needs to handle the failure case.
end)

-- Jump Upgrade kiosk: walking up to it only asks the server to relay this
-- event back — the panel is built straight from the same lastData the HUD
-- already keeps up to date (see EconomyService.GetJumpUpgradeState), no
-- extra round-trip needed, exactly like the Rebirth confirm dialog above.
remotes.RequestJumpUpgradePanel.OnClientEvent:Connect(function()
	if not lastData then
		return
	end
	UIBuilder.ShowJumpUpgrade(ui, lastData)
end)

ui.JumpUpgradeCloseButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideJumpUpgrade(ui)
end)

-- Unlike the Trade Zone roster / Trade item picker (which rebuild their
-- rows from scratch every time, so a ChildAdded listener is needed to catch
-- new ones), the Jump Upgrade buttons are built ONCE up front by UIBuilder.
-- Build and never recreated (see its comment) — so each one is wired
-- directly, right here, a single time. Reads the amount back off the
-- Attribute UIBuilder keeps up to date on each button (see
-- PopulateJumpUpgrade).
for _, button in ipairs(ui.JumpUpgradeBulkButtons) do
	button.Activated:Connect(function()
		SoundPlayer.Play("ButtonClick")
		local amount = button:GetAttribute("BulkAmount")
		local success, err = remotes.BuyJumpUpgrade:InvokeServer(amount)
		if not success then
			UIBuilder.ShowMessage(ui, tostring(err))
			SoundPlayer.Play("Error")
		end
		-- On success, the UpgradeBought SFX plays from refreshStats' diff
		-- logic above (data.JumpPoints increasing), and the panel refreshes
		-- itself via the same DataUpdated too — nothing else needed here.
	end)
end

-- Robux buttons, same pre-built/wire-once pattern as the Cash buttons right
-- above. A Developer Product purchase prompt can only be opened from the
-- CLIENT (MarketplaceService:PromptProductPurchase — same idea as
-- PromptGamePassPurchase below for gamepasses), so this just reads the
-- ProductId UIBuilder.Build attached to the button and prompts with it.
-- Buttons for a not-yet-configured product (ProductId = 0, placeholder)
-- were never given the Attribute and stay Visible = false, so they never
-- receive clicks in the first place.
for _, button in ipairs(ui.JumpUpgradeRobuxButtons) do
	button.Activated:Connect(function()
		SoundPlayer.Play("ButtonClick")
		local productId = button:GetAttribute("ProductId")
		if productId then
			MarketplaceService:PromptProductPurchase(player, productId)
		end
		-- On success, MarketplaceService.ProcessReceipt (server-side, see
		-- MonetizationService) grants the points and the panel refreshes
		-- itself via the usual DataUpdated push — nothing else needed here.
	end)
end

ui.RebirthConfirmNo.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideRebirthConfirm(ui)
end)

-- === Pedestal sell confirmation (see BaseService.lua's sellPrompt) ============
-- On request ("ich möchte bei dem verkaufen von Brainroth, das nachgefragt
-- wird ob du es verkaufen willst") — a filled pedestal's Sell prompt no
-- longer sells instantly; the server only relays which pedestal + creature
-- + an estimated payout (RequestSellConfirm), and this builds the actual
-- Yes/No dialog client-side, same "ask first, commit later" split as the
-- Rebirth confirm above.
remotes.RequestSellConfirm.OnClientEvent:Connect(function(info)
	if not info then
		return
	end
	ui.SellConfirmSlotIndex = info.SlotIndex
	local message = "\"" .. tostring(info.Name) .. "\" für +$" .. UIBuilder.FormatNumber(info.Value) .. " verkaufen?"
	UIBuilder.ShowSellConfirm(ui, message)
end)

ui.SellConfirmYes.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideSellConfirm(ui)
	local slotIndex = ui.SellConfirmSlotIndex
	if not slotIndex then
		return
	end
	local success, err = remotes.ConfirmSellCreature:InvokeServer(slotIndex)
	if not success then
		UIBuilder.ShowMessage(ui, tostring(err))
		SoundPlayer.Play("Error")
	end
	-- On success, CreatureService.SellCreature already fires CreatureSold
	-- itself — that's what plays the sale SFX/toast (see the existing
	-- remotes.CreatureSold listener above), exactly as it did before this
	-- confirmation step existed. Nothing else needed here.
end)

ui.SellConfirmNo.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideSellConfirm(ui)
	ui.SellConfirmSlotIndex = nil
end)

-- === Offline-earnings popup ("Willkommen zurück", see GameConfig.OfflineEarnings) ===
-- Fired once right after join if EconomyService.ComputeOfflineEarnings found
-- enough Cash to be worth showing — info = {Amount, OfflineSeconds,
-- RatePerSecond, RateFraction, DoubleProductId}.
remotes.ShowOfflineEarnings.OnClientEvent:Connect(function(info)
	if not info then
		return
	end
	UIBuilder.ShowOfflineEarnings(ui, info)
end)

-- "Abholen" — pays out the plain (non-doubled) amount via a direct
-- RemoteFunction call, same "ask and get the real result back" shape as
-- ConfirmSellCreature above (not fire-and-forget — the popup needs to know
-- exactly how much actually got granted for the toast, in case it was
-- already 0 from a stale double-click).
ui.OfflineEarningsClaimButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideOfflineEarnings(ui)
	local amount = remotes.ClaimOfflineEarnings:InvokeServer()
	if amount and amount > 0 then
		UIBuilder.ShowOfflineEarningsToast(ui, amount)
	end
end)

-- "Verdoppeln (X Robux)" — same "read the ProductId Attribute UIBuilder.
-- Build already attached, prompt directly" pattern as the Jump Upgrade Robux
-- buttons. Deliberately does NOT hide the popup or invoke ClaimOfflineEarnings
-- here — the purchase resolves asynchronously via MarketplaceService.
-- ProcessReceipt (server-side), which then fires OfflineEarningsDoubled below
-- once it's actually done; if the player cancels the purchase prompt instead,
-- the popup just stays open exactly as it was, "Abholen" still works normally.
ui.OfflineEarningsDoubleButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	local productId = ui.OfflineEarningsDoubleButton:GetAttribute("ProductId")
	if productId then
		MarketplaceService:PromptProductPurchase(player, productId)
	end
end)

remotes.OfflineEarningsDoubled.OnClientEvent:Connect(function(payload)
	UIBuilder.HideOfflineEarnings(ui)
	if payload and payload.Amount and payload.Amount > 0 then
		UIBuilder.ShowOfflineEarningsToast(ui, payload.Amount)
	end
end)

-- === Brainrot-Dex (see UIBuilder's DexButton/DexOverlay) =======================
-- Fetches the current discovery list fresh from the server every time the
-- panel is opened (a RemoteFunction call, not part of the frequent
-- DataUpdated push — see init.server.lua's GetDiscoveredCreatures) so it's
-- always accurate, including creatures discovered moments ago.
--
-- Factored into a named function (rather than left inline on DexButton.
-- Activated) so the gamepad shortcut below can call the exact same open
-- logic — DexButton is a persistent HUD icon, not tied to any physical
-- ProximityPrompt in the world, so unlike every OTHER panel in this game
-- (all opened by walking up to a kiosk, which ProximityPrompts already
-- support natively on a gamepad) there was otherwise no way at all for a
-- controller player to even OPEN the Dex — see the gamepad shortcut's own
-- comment further down for the full reasoning.
local function openDex()
	SoundPlayer.Play("ButtonClick")
	local ok, entries = pcall(function()
		return remotes.GetDiscoveredCreatures:InvokeServer()
	end)
	if ok and entries then
		-- ShowDex BEFORE PopulateDex, deliberately — see UIBuilder's comment
		-- above DexList: rows/headers created while DexOverlay was still
		-- Visible = false never rendered (a deeper Roblox render-cache issue
		-- than just the CanvasSize bug, confirmed by an Explorer check that
		-- showed the rows genuinely existed with correct sizing, just never
		-- drawn). Showing first means nothing is ever built while hidden.
		UIBuilder.ShowDex(ui)
		UIBuilder.PopulateDex(ui, entries)
	else
		UIBuilder.ShowMessage(ui, "Brainrot-Dex konnte nicht geladen werden.")
		SoundPlayer.Play("Error")
	end
end

ui.DexButton.Activated:Connect(openDex)

ui.DexCloseButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideDex(ui)
end)

-- Gamepad shortcut for opening the Dex (Xbox "Y" — the common "open
-- codex/inventory" convention). On request ("kann man die Steuerung für
-- Konsole anpassen") — every kiosk-triggered panel already works fine on a
-- gamepad to OPEN (Roblox's own ProximityPrompts natively show/accept a
-- gamepad button prompt, completely independent of GuiNavigationEnabled),
-- but DexButton is a persistent HUD icon with no physical kiosk behind it
-- at all, so a controller player had no way to reach it. Guarded on
-- GuiService.SelectedObject being nil — that's true exactly when no other
-- popup is currently open (see UIBuilder's gamepadFocusStack: it's nil only
-- when the stack is empty), so this can't fire a second Dex open on top of
-- an already-open panel, or steal a Y-press meant for something else.
UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then
		return
	end
	if input.KeyCode == Enum.KeyCode.ButtonY and GuiService.SelectedObject == nil then
		openDex()
	end
end)

-- === Leaderboard panel (see LeaderboardService.BuildBoard's ProximityPrompt /
-- UIBuilder's Leaderboard panel) ================================================
-- On request ("die Bestenliste hat Bilder der Spieler und man kann von Top1
-- bis Top 200 runter scrollen") — same "kiosk fires an event, panel fetches
-- its own fresh data" pattern as RequestWheelPanel/GetWheelState above.
-- Fired when a player interacts with the physical Bestenliste board's
-- ProximityPrompt near the tower.
remotes.RequestLeaderboardPanel.OnClientEvent:Connect(function()
	local ok, data = pcall(function()
		return remotes.GetLeaderboardPanelData:InvokeServer()
	end)
	if ok and data then
		-- ShowLeaderboardPanel BEFORE PopulateLeaderboard, deliberately — same
		-- ordering (and the same underlying rendering-bug reason) as the
		-- Brainrot-Dex above.
		UIBuilder.ShowLeaderboardPanel(ui)
		UIBuilder.PopulateLeaderboard(ui, data)
	else
		UIBuilder.ShowMessage(ui, "Bestenliste konnte nicht geladen werden.")
		SoundPlayer.Play("Error")
	end
end)

ui.LeaderboardCloseButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideLeaderboardPanel(ui)
end)

-- === "Sprunghöhe"-Regler (siehe UIBuilder's JumpHeightPanel) ==================
-- Fest im HUD, kein Button zum Öffnen mehr nötig — auf Wunsch: "die Tasten
-- +10% / Max / -10% direkt am Bildschirm anbringen". Die Anzeige selbst
-- bleibt immer aktuell über UpdateJumpHeightPanel unten in refreshStats
-- (kein Server-Fetch beim Klicken nötig); die +/- Buttons schicken jeweils
-- den NEUEN gewünschten Bruchteil per RemoteFunction; der Server clamped/
-- validiert ihn (nie höher als die eigene verdiente Sprungkraft) und
-- schickt den tatsächlich angewendeten Wert zurück, der hier direkt
-- übernommen wird, statt auf die nächste DataUpdated zu warten.
local JUMP_HEIGHT_STEP = 0.1 -- 10 Prozentpunkte pro Klick

local function requestJumpHeightFraction(newFraction)
	newFraction = math.clamp(newFraction, 0, 1)
	local ok, appliedFraction = pcall(function()
		return remotes.SetJumpHeightFraction:InvokeServer(newFraction)
	end)
	if ok and appliedFraction then
		ui.JumpHeightFraction = appliedFraction
		UIBuilder.RefreshJumpHeightPanel(ui)
	end
end

ui.JumpHeightDownButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	requestJumpHeightFraction((ui.JumpHeightFraction or 1) - JUMP_HEIGHT_STEP)
end)

ui.JumpHeightUpButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	requestJumpHeightFraction((ui.JumpHeightFraction or 1) + JUMP_HEIGHT_STEP)
end)

ui.JumpHeightMaxButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	requestJumpHeightFraction(1)
end)

-- 2x Cash / 4x Cash / Auto-Sammeln kiosks: a Robux purchase prompt can only
-- be opened from the CLIENT, so the server-side ProximityPrompt handler just
-- tells us which one to open. Auto Climb has been removed entirely — no
-- kiosk, no listener case for it. VIP's kiosk was replaced by "1x
-- Wiedergeburt" (see the RequestRebirthProductPrompt listener right below)
-- — a Developer Product, not a Gamepass, so it doesn't go through this
-- listener at all.
--
-- `IsDeveloperProduct` (see GameConfig.Gamepasses' own big comment) — all 3
-- of DoubleCash/QuadCash/AutoCollect turned out to actually be Developer
-- Products in the Creator Dashboard, not real Game Passes (confirmed via a
-- screenshot after "Fehler, egal welche Id" purchase failures), so calling
-- PromptGamePassPurchase on them was simply always going to fail — that API
-- only works for a real Game Pass ID. PromptProductPurchase is the correct
-- call for a Developer Product, same one the Jump Upgrade/Wheel/Fast-Travel/
-- Rebirth buttons already use elsewhere in this file. Kept as one shared
-- listener (rather than splitting into a second event) since only the one
-- MarketplaceService call differs — everything else about "open a purchase
-- prompt for this ID" stays identical either way.
remotes.RequestGamepassPrompt.OnClientEvent:Connect(function(gamepassKey)
	local gamepassInfo = GameConfig.Gamepasses[gamepassKey]
	if not gamepassInfo then
		return
	end
	if gamepassInfo.IsDeveloperProduct then
		MarketplaceService:PromptProductPurchase(player, gamepassInfo.Id)
	else
		MarketplaceService:PromptGamePassPurchase(player, gamepassInfo.Id)
	end
end)

-- "1x Wiedergeburt" kiosk (GameConfig.Rebirth.RobuxProduct, replaces the old
-- VIP kiosk) — a Developer Product purchase (PromptProductPurchase), not a
-- Gamepass, so it needs PromptProductPurchase instead of the
-- RequestGamepassPrompt listener above. The actual Rebirth is granted
-- server-side from MonetizationService.ProcessReceipt once the purchase is
-- confirmed (see EconomyService.BuyRebirthWithRobux) — same "client only
-- opens the prompt, the receipt does the granting" separation as the Jump
-- Upgrade Robux packs / Glücksrad Robux spin.
remotes.RequestRebirthProductPrompt.OnClientEvent:Connect(function()
	local productId = GameConfig.Rebirth.RobuxProduct.ProductId
	if not productId or productId <= 0 then
		return
	end
	MarketplaceService:PromptProductPurchase(player, productId)
end)

-- Glücksrad kiosk: fired by BaseService.buildWheelKiosk's ProximityPrompt
-- (server) when a player interacts with the shared kiosk — opens the panel
-- and asks the server for a fresh WheelService.GetState snapshot, same
-- "ask fresh when the panel opens" pattern as RequestDex above. No payload
-- needed, same convention as RequestJumpUpgradePanel.
remotes.RequestWheelPanel.OnClientEvent:Connect(function()
	local ok, state = pcall(function()
		return remotes.GetWheelState:InvokeServer()
	end)
	if ok and state then
		UIBuilder.ShowWheelPanel(ui, state)
	end
end)

ui.WheelCloseButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideWheelPanel(ui)
end)

-- Free daily spin: SpinWheelFree is a RemoteFunction, so the result (or a
-- still-on-cooldown failure) comes back synchronously to this same click —
-- no separate result event needed for this path, unlike the paid one below.
ui.WheelFreeButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	local ok, result = pcall(function()
		return remotes.SpinWheelFree:InvokeServer()
	end)
	if not ok or not result then
		return
	end
	if result.Success then
		-- On request ("nach dem gratis Glücksrad dreh ist der dreh Button
		-- immer noch aktiv, erst nach nochmaligen drücken kommt der
		-- Timer") — a successful free spin just consumed today's
		-- cooldown server-side, so once the animation finishes, re-fetch
		-- the real GetWheelState and repopulate the panel instead of
		-- letting PlayWheelSpin fall back to its old "just re-enable the
		-- button" default. Same re-fetch pattern the failure branch below
		-- already uses.
		UIBuilder.PlayWheelSpin(ui, result.SegmentIndex, result.Message, function()
			local ok2, state = pcall(function()
				return remotes.GetWheelState:InvokeServer()
			end)
			if ok2 and state then
				UIBuilder.PopulateWheelState(ui, state)
			end
		end)
	else
		-- SpinWheelFree's failure reply only carries RemainingSeconds (see
		-- WheelService.SpinWheel), not RobuxProducts — re-fetching the full
		-- GetWheelState snapshot here (instead of hand-building a partial
		-- one) keeps the two buy buttons showing correctly instead of
		-- PopulateWheelState hiding them for a missing field.
		local ok2, state = pcall(function()
			return remotes.GetWheelState:InvokeServer()
		end)
		if ok2 and state then
			UIBuilder.PopulateWheelState(ui, state)
		end
	end
end)

-- The two Robux buy buttons: each reads the ProductId Attribute
-- UIBuilder.PopulateWheelState set on ITS OWN button, same "Attribute
-- holds the live product id" convention as the Jump Upgrade Robux
-- buttons above. The actual spin result(s) arrive later, out of band, via
-- the WheelSpinResult event below — a Robux purchase can't return
-- synchronously to this click (ProcessReceipt runs later server-side).
ui.WheelBuyOneButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	local productId = ui.WheelBuyOneButton:GetAttribute("ProductId")
	if productId then
		MarketplaceService:PromptProductPurchase(player, productId)
	end
end)

ui.WheelBuyThreeButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	local productId = ui.WheelBuyThreeButton:GetAttribute("ProductId")
	if productId then
		MarketplaceService:PromptProductPurchase(player, productId)
	end
end)

-- Fired by WheelService.SpinWheelPaid once MonetizationService.ProcessReceipt
-- confirms a real Robux purchase of one of GameConfig.WheelOfFortune
-- .RobuxProducts — results is now an ARRAY (one entry per spin in the
-- bundle bought, "Kaufe 1" = 1 entry, "Kaufe 3" = 3), so this plays the
-- whole bundle as an animated sequence instead of a single spin (see
-- UIBuilder.PlayWheelSpinSequence for why that's a separate function from
-- the free path's PlayWheelSpin).
remotes.WheelSpinResult.OnClientEvent:Connect(function(results)
	if results then
		-- Same free-button re-fetch fix as the free-spin path above — a
		-- Robux purchase never touches the free spin's own cooldown, but
		-- if it was already on cooldown before this purchase, the button
		-- should stay showing that real timer/disabled state once the
		-- purchased sequence finishes, not get blindly re-enabled.
		UIBuilder.PlayWheelSpinSequence(ui, results, function()
			local ok, state = pcall(function()
				return remotes.GetWheelState:InvokeServer()
			end)
			if ok and state then
				UIBuilder.PopulateWheelState(ui, state)
			end
		end)
	end
end)

-- Fast-Travel kiosk: fired by BaseService.buildFastTravelKiosk's
-- ProximityPrompt (server) when a player interacts with the shared kiosk —
-- no server round-trip needed, the panel is built straight from the same
-- lastData the HUD already keeps up to date (see EconomyService's
-- HighestFloor push), exactly like RequestJumpUpgradePanel above.
remotes.RequestFastTravelPanel.OnClientEvent:Connect(function()
	if not lastData then
		return
	end
	UIBuilder.ShowFastTravelPanel(ui, lastData)
end)

ui.FastTravelCloseButton.Activated:Connect(function()
	SoundPlayer.Play("ButtonClick")
	UIBuilder.HideFastTravelPanel(ui)
end)

-- One row per GameConfig.FastTravel.Checkpoints entry, built ONCE by
-- UIBuilder.Build and never recreated (see its comment) — same "wire once,
-- read the live ProductId back off the Attribute" pattern as the Jump
-- Upgrade Robux buttons above. A Buy button is only ever Visible once the
-- player has reached that Floor AND a real price came back from
-- GetProductInfo (see UIBuilder.PopulateFastTravel), so it never receives a
-- click for a checkpoint that isn't actually purchasable yet.
for _, row in ipairs(ui.FastTravelRows) do
	row.BuyButton.Activated:Connect(function()
		SoundPlayer.Play("ButtonClick")
		local productId = row.BuyButton:GetAttribute("ProductId")
		if productId then
			MarketplaceService:PromptProductPurchase(player, productId)
		end
		-- On success, MarketplaceService.ProcessReceipt (server-side, see
		-- MonetizationService) calls FastTravelService.Teleport, which moves
		-- the player and fires a Notice — nothing else needed here.
	end)
end
end -- end of main()

local ok, err = pcall(main)
if not ok then
	warn("[ClientMain] FAILED: " .. tostring(err))
	showFatalError(err)
end
