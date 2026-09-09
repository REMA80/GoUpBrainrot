--[[
	TradeService.lua
	The player-to-player trading feature: a dedicated physical "Trade Zone"
	(built by BuildZone below, see GameConfig.Trade for its position/size)
	where any two players standing inside can request a trade, each offer
	exactly ONE of their own Brainrots, and — once both confirm — swap them
	atomically via CreatureService.ExecuteTrade.

	Flow: RequestTrade -> RespondTrade(accept) -> SetOffer (either side, any
	number of times) -> Confirm (both sides) -> executes automatically the
	moment both are confirmed. Cancel (or leaving the zone, or disconnecting)
	tears the session down at any point before that.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local TradeService = {}

local CreatureService
local remotesFolder

-- [player] = true while standing inside the Trade Zone.
local inZone = {}

-- [targetPlayer] = requesterPlayer — at most ONE pending incoming request
-- per player at a time; a new request from someone else just overwrites it.
local pendingRequests = {}

-- [player] = sessionTable — both players in an active trade point to the
-- SAME table. sessionTable = {
--   players = {playerA, playerB},
--   offers = {[player] = creatureName or nil},
--   confirmed = {[player] = true/false},
-- }
local sessions = {}

function TradeService.Init(deps)
	CreatureService = deps.CreatureService
	remotesFolder = deps.Remotes
end

-- === Small helpers ==============================================================

local function otherPlayerIn(session, player)
	if session.players[1] == player then
		return session.players[2]
	end
	return session.players[1]
end

local function fireTo(player, eventName, ...)
	if remotesFolder and player and player.Parent then
		remotesFolder[eventName]:FireClient(player, ...)
	end
end

-- Sends both players their own view of the current offers/confirm state —
-- each gets "My..." fields about themselves and "Opponent..." fields about
-- the other side, so the client never has to figure out which is which.
local function broadcastTradeUpdate(session)
	for _, player in ipairs(session.players) do
		local opponent = otherPlayerIn(session, player)
		fireTo(player, "TradeUpdate", {
			MyOffer = session.offers[player],
			OpponentOffer = session.offers[opponent],
			MyConfirmed = session.confirmed[player] == true,
			OpponentConfirmed = session.confirmed[opponent] == true,
		})
	end
end

-- Tears a session down without executing a trade — used by Cancel, by a
-- player leaving the zone mid-negotiation, and by PlayerRemoving. `reason`
-- is shown to BOTH players (whichever one didn't initiate the cancel needs
-- to know just as much as the one who did).
local function closeSession(session, reason)
	sessions[session.players[1]] = nil
	sessions[session.players[2]] = nil
	for _, player in ipairs(session.players) do
		fireTo(player, "TradeClosed", { Success = false, Reason = reason })
	end
end

local function clearPendingRequestsInvolving(player)
	pendingRequests[player] = nil
	for target, requester in pairs(pendingRequests) do
		if requester == player then
			pendingRequests[target] = nil
		end
	end
end

-- === Zone roster (who's currently standing in the Trade Zone) ==================

-- Sends `player` the current list of OTHER players in the zone (possibly
-- empty — you can be alone in there). Passing `nil` instead tells the
-- client to hide the whole panel because `player` just left the zone.
local function sendRosterTo(player)
	if not inZone[player] then
		fireTo(player, "TradeZoneRoster", nil)
		return
	end

	local others = {}
	for otherPlayer in pairs(inZone) do
		if otherPlayer ~= player then
			table.insert(others, { UserId = otherPlayer.UserId, Name = otherPlayer.Name })
		end
	end
	fireTo(player, "TradeZoneRoster", others)
end

-- Whenever the zone's membership changes, everyone currently inside needs a
-- fresh roster (a newly-arrived player wasn't in anyone else's list yet).
local function broadcastRosterToEveryoneInZone()
	for player in pairs(inZone) do
		sendRosterTo(player)
	end
end

local function handlePlayerLeftZone(player)
	inZone[player] = nil
	sendRosterTo(player) -- tells THIS player's client to hide the panel

	clearPendingRequestsInvolving(player)

	local session = sessions[player]
	if session then
		closeSession(session, "Tausch abgebrochen — einer von euch hat die Tausch-Zone verlassen")
	end

	broadcastRosterToEveryoneInZone()
end

local function handlePlayerEnteredZone(player)
	inZone[player] = true
	broadcastRosterToEveryoneInZone()
end

-- Polls every player's distance to the zone center once per Heartbeat —
-- same lightweight pattern as ShopService.isInTowerZone, just a small fixed
-- circle instead of "everything inside the tower". Horizontal distance only
-- (ignores height) so standing on anything at ground level around the zone
-- marker counts.
local function startZoneLoop()
	RunService.Heartbeat:Connect(function()
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local nowInZone = false
			if root then
				local zonePos = GameConfig.Trade.ZonePosition
				local flatOffset = Vector2.new(root.Position.X - zonePos.X, root.Position.Z - zonePos.Z)
				nowInZone = flatOffset.Magnitude <= GameConfig.Trade.ZoneRadius
			end

			if nowInZone and not inZone[player] then
				handlePlayerEnteredZone(player)
			elseif not nowInZone and inZone[player] then
				handlePlayerLeftZone(player)
			end
		end
	end)
end

-- === Physical zone marker ========================================================

-- A flat, clearly-colored circular platform plus a floating sign — purely
-- cosmetic/orientation, the actual "am I in the zone" check above is a pure
-- distance calculation and doesn't care whether anything is actually built
-- here. Called once from init.server.lua at startup.
function TradeService.BuildZone()
	local zonePos = GameConfig.Trade.ZonePosition
	local radius = GameConfig.Trade.ZoneRadius

	local zoneFolder = Instance.new("Folder")
	zoneFolder.Name = "TradeZone"
	zoneFolder.Parent = workspace

	local platform = Instance.new("Part")
	platform.Name = "TradeZonePlatform"
	platform.Shape = Enum.PartType.Cylinder
	platform.Anchored = true
	platform.CanCollide = true
	platform.Material = Enum.Material.Neon
	-- On request ("grelle Lichter sind immer noch zu stark") — softened the
	-- same way as every other Neon surface in the game (see
	-- BaseService.buildStationPart's own comment); this platform is large
	-- (radius*2 studs across), so at full saturation it was one of the
	-- more noticeable glare sources.
	platform.Color = Color3.fromRGB(80, 200, 255):Lerp(Color3.new(1, 1, 1), 0.45)
	platform.Transparency = 0.35
	platform.Size = Vector3.new(1, radius * 2, radius * 2)
	-- Sits flush with the meadow's top surface (TowerGenerator.buildGround's
	-- ground Part is centered at Y=-3 with a 4-stud height, so its top face
	-- is at Y=-1) instead of using zonePos.Y directly — the zone-membership
	-- check above only ever looks at horizontal (X/Z) distance, so the
	-- platform's own Y is purely cosmetic and free to set independently.
	platform.CFrame = CFrame.new(zonePos.X, -0.5, zonePos.Z) * CFrame.Angles(0, 0, math.rad(90))
	platform.Parent = zoneFolder

	local sign = Instance.new("BillboardGui")
	sign.Size = UDim2.new(0, 220, 0, 60)
	sign.StudsOffset = Vector3.new(0, 8, 0)
	sign.AlwaysOnTop = true
	sign.Parent = platform

	local signLabel = Instance.new("TextLabel")
	signLabel.Size = UDim2.new(1, 0, 1, 0)
	signLabel.BackgroundTransparency = 1
	signLabel.Text = "🤝 Tausch-Zone"
	signLabel.TextColor3 = Color3.new(1, 1, 1)
	signLabel.TextStrokeTransparency = 0.2
	signLabel.Font = Enum.Font.GothamBold
	signLabel.TextScaled = true
	signLabel.Parent = sign

	startZoneLoop()
end

-- === Trade flow ==================================================================

-- `requester` asks to trade with whoever owns `targetUserId`. Both must
-- currently be standing in the zone and neither can already be mid-trade.
function TradeService.RequestTrade(requester, targetUserId)
	if not inZone[requester] then
		return false, "Du musst in der Tausch-Zone stehen"
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == requester then
		return false, "Spieler nicht gefunden"
	end
	if not inZone[target] then
		return false, "Der Spieler ist nicht mehr in der Tausch-Zone"
	end
	if sessions[requester] or sessions[target] then
		return false, "Einer von euch handelt schon mit jemand anderem"
	end

	pendingRequests[target] = requester
	fireTo(target, "TradeRequestReceived", { FromUserId = requester.UserId, FromName = requester.Name })

	task.delay(GameConfig.Trade.RequestTimeoutSeconds, function()
		if pendingRequests[target] == requester then
			pendingRequests[target] = nil
		end
	end)

	return true
end

-- `responder` accepts or declines whatever pending request is currently
-- addressed to them (there can only be one at a time, see RequestTrade).
function TradeService.RespondTrade(responder, accept)
	local requester = pendingRequests[responder]
	if not requester then
		return false, "Diese Anfrage ist nicht mehr gültig"
	end
	pendingRequests[responder] = nil

	if not accept then
		fireTo(requester, "TradeClosed", { Success = false, Reason = responder.Name .. " hat die Anfrage abgelehnt" })
		return true
	end

	if not inZone[requester] or not inZone[responder] then
		return false, "Einer von euch ist nicht mehr in der Tausch-Zone"
	end
	if sessions[requester] or sessions[responder] then
		return false, "Einer von euch handelt schon mit jemand anderem"
	end

	local session = {
		players = { requester, responder },
		offers = {},
		confirmed = {},
	}
	sessions[requester] = session
	sessions[responder] = session

	for _, player in ipairs(session.players) do
		local opponent = otherPlayerIn(session, player)
		fireTo(player, "TradeOpened", {
			OpponentName = opponent.Name,
			MyItems = CreatureService.GetOwnedSummary(player),
		})
	end

	return true
end

-- Sets (or changes) `player`'s own offered creature for their active trade.
-- Changing an offer un-confirms BOTH sides — the deal just changed, so any
-- previous confirmation from either player no longer means what it did.
function TradeService.SetOffer(player, creatureName)
	local session = sessions[player]
	if not session then
		return false, "Kein aktiver Tausch"
	end

	session.offers[player] = creatureName
	session.confirmed[player] = false
	session.confirmed[otherPlayerIn(session, player)] = false

	broadcastTradeUpdate(session)
	return true
end

-- Confirms `player`'s current offer. Once BOTH sides are confirmed, the
-- trade executes immediately and the session closes either way (success or
-- failure — a stale offer from a mid-negotiation sale is the only realistic
-- failure case, see CreatureService.ExecuteTrade).
function TradeService.Confirm(player)
	local session = sessions[player]
	if not session then
		return false, "Kein aktiver Tausch"
	end
	if not session.offers[player] then
		return false, "Wähle zuerst ein Brainrot aus"
	end

	session.confirmed[player] = true
	local opponent = otherPlayerIn(session, player)

	if session.confirmed[opponent] then
		local success, err = CreatureService.ExecuteTrade(
			session.players[1],
			session.offers[session.players[1]],
			session.players[2],
			session.offers[session.players[2]]
		)

		sessions[session.players[1]] = nil
		sessions[session.players[2]] = nil

		for _, p in ipairs(session.players) do
			fireTo(p, "TradeClosed", {
				Success = success,
				Reason = success and "Tausch erfolgreich!" or (err or "Tausch fehlgeschlagen"),
			})
		end
	else
		broadcastTradeUpdate(session)
	end

	return true
end

-- Either side can cancel an open trade at any point before both have
-- confirmed (and, in principle, this is also the escape hatch if something
-- ever gets stuck — canceling always works, it just discards the session).
function TradeService.Cancel(player)
	local session = sessions[player]
	if not session then
		return false, "Kein aktiver Tausch"
	end
	closeSession(session, player.Name .. " hat den Tausch abgebrochen")
	return true
end

-- Called from Players.PlayerRemoving (see init.server.lua) — cleans up
-- every bit of state this player could be holding onto so a disconnect
-- never leaves a phantom pending request or a stuck session behind for
-- whoever they were talking to.
function TradeService.ReleasePlayer(player)
	if inZone[player] then
		handlePlayerLeftZone(player)
	end
	clearPendingRequestsInvolving(player)

	local session = sessions[player]
	if session then
		closeSession(session, "Tausch abgebrochen — einer von euch hat das Spiel verlassen")
	end
end

return TradeService
