--[[
	LeaderboardService.lua
	The global (cross-server) "Hall of Fame" board — Top Cash/s, Top-
	Rebirths, and Top-Gesamt-Cash rankings, backed by DataStoreService so
	every server on the game shares the SAME lists (not just whoever
	happens to be online in this one server right now). Also builds and
	refreshes the physical board that displays all three, placed at the
	tower's base — see GameConfig.Leaderboard for the tunable numbers.

	On request ("statt der Anzeige wer Floor 100 erreicht hat eine
	Rangliste für Cash/s, serverübergreifend") — the board's third sign
	used to show a Floor-100-conqueror roster; it now shows Top Cash/s
	instead. The roster ITSELF (RecordFloor100/rosterStore below) is left
	fully intact and still recorded on every first Floor-100 climb — it's
	cheap (one write per player, ever) and the historical data shouldn't
	just be thrown away, it's simply no longer read back or shown on the
	physical board (see RefreshBoardText/BuildBoard).

	On request ("die Bestenliste hat Bilder der Spieler und man kann von
	Top1 bis Top 200 runter scrollen ... für alle 3 Ranglisten, begrenze es
	auf top 100 ... seine Position einblenden") — the 3 physical signs still
	show their short always-visible text, but walking up and interacting
	with the board (see BuildBoard's ProximityPrompt) now also opens a real
	UI panel (see UIBuilder.lua's Leaderboard panel) showing all 3
	categories' full Top 100 with player avatars, paged (not scrolled — see
	UIBuilder's own long comment on why this project uses pagination, not
	ScrollingFrame, for long lists), plus a pinned "Du: Rang X" row for the
	viewing player even when they're outside the Top 100 (see
	GetOwnStanding/GetPanelData below).

	IMPORTANT (same caveat as PlayerDataManager.lua): DataStore calls only
	work in Studio if "Enable Studio Access to API Services" is turned on
	(Game Settings > Security), and only work at all once the place has been
	published at least once. Until then, every store below is nil and this
	whole module quietly does nothing except keep the board showing
	"Noch keine Daten..." — it never errors the server.

	UNLIKE every other system in this project, this one CANNOT be verified
	by actually running it outside Studio — there's no DataStoreService to
	mock. Everything here follows the exact same pcall-guarded patterns
	PlayerDataManager.lua already uses successfully, but real testing (does
	a Floor-100 climb actually add a roster entry, does the board really
	refresh) has to happen in Studio/live play.
]]

local DataStoreService = game:GetService("DataStoreService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local LeaderboardService = {}

local PlayerDataManager
local EconomyService -- needed for GetCreatureCashRates, see SyncPlayer's Cash/s block below
local remotesFolder -- needed to fire RequestLeaderboardPanel from the board's ProximityPrompt, see BuildBoard below

-- Four independent stores (see GameConfig.DataStore's comment on why
-- they're separate from the main per-player save). Each is guarded the
-- same way PlayerDataManager guards its own store: GetDataStore/
-- GetOrderedDataStore can throw outright (unpublished place, Studio API
-- access off), so a failure here just leaves the store nil and every
-- function below already checks for that before using it.
local rebirthsStore
local cashStore
local cashPerSecondStore
local rosterStore

do
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(GameConfig.DataStore.LeaderboardRebirthsName)
	end)
	if ok then
		rebirthsStore = result
	else
		warn("[LeaderboardService] Rebirths OrderedDataStore unavailable: " .. tostring(result))
	end
end

do
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(GameConfig.DataStore.LeaderboardCashName)
	end)
	if ok then
		cashStore = result
	else
		warn("[LeaderboardService] Cash OrderedDataStore unavailable: " .. tostring(result))
	end
end

do
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(GameConfig.DataStore.LeaderboardCashPerSecondName)
	end)
	if ok then
		cashPerSecondStore = result
	else
		warn("[LeaderboardService] Cash/s OrderedDataStore unavailable: " .. tostring(result))
	end
end

do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.DataStore.LeaderboardRosterName)
	end)
	if ok then
		rosterStore = result
	else
		warn("[LeaderboardService] Roster DataStore unavailable: " .. tostring(result))
	end
end

-- Cached results of the last successful refresh — what the physical board
-- actually reads from. Kept as plain module state (not re-fetched from
-- DataStore on every board update) since RefreshTopLists only runs once
-- per SyncIntervalSeconds — see StartPeriodicSync.
-- array of { Name, UserId, Value }, highest first. UserId is kept (not just
-- Name) on request ("den jeweiligen Spieler ... seine Position einblenden")
-- — GetOwnStanding below matches the VIEWING player against these lists by
-- UserId (never by Name — names aren't unique/stable the way UserIds are),
-- and the Leaderboard panel's avatar thumbnails (Players:GetUserThumbnailAsync)
-- need a UserId per row too.
local cachedTopRebirths = {}
local cachedTopCash = {}
local cachedTopCashPerSecond = {}
-- Still populated (see RecordFloor100/RefreshTopLists below), just no
-- longer displayed on the board — see this file's own top comment.
local cachedHallOfFame = {}  -- array of { Name, UserId, Timestamp }

-- Set once by BuildBoard() — the 3 TextLabels RefreshBoardText writes into.
local cashPerSecondListLabel
local rebirthsListLabel
local cashListLabel

function LeaderboardService.Init(deps)
	PlayerDataManager = deps.PlayerDataManager
	EconomyService = deps.EconomyService
	remotesFolder = deps.Remotes
end

-- Same abbreviation style as BaseService's formatCashRate (a local copy,
-- not shared, to keep this module independent of BaseService) — big
-- numbers as "$700M" instead of a long raw digit string.
-- Extended past B with the standard short-scale names (on request, see
-- BaseService.formatCashRate's own comment) — Trillion (1e12), Quadrillion
-- (1e15, "Qa"), Quintillion (1e18, "Qi"), Sextillion (1e21, "Sx"),
-- Septillion (1e24, "Sp"), Octillion (1e27, "Oc"). Nothing named above
-- Octillion — a bigger value just keeps growing as an ever-larger "Oc".
local function formatCashShort(value)
	if value >= 1e27 then
		return string.format("%.1f", value / 1e27) .. "Oc"
	elseif value >= 1e24 then
		return string.format("%.1f", value / 1e24) .. "Sp"
	elseif value >= 1e21 then
		return string.format("%.1f", value / 1e21) .. "Sx"
	elseif value >= 1e18 then
		return string.format("%.1f", value / 1e18) .. "Qi"
	elseif value >= 1e15 then
		return string.format("%.1f", value / 1e15) .. "Qa"
	elseif value >= 1e12 then
		return string.format("%.1f", value / 1e12) .. "T"
	elseif value >= 1e9 then
		return string.format("%.1f", value / 1e9) .. "B"
	elseif value >= 1e6 then
		return string.format("%.1f", value / 1e6) .. "M"
	elseif value >= 1e3 then
		return string.format("%.1f", value / 1e3) .. "K"
	else
		return tostring(math.floor(value))
	end
end

-- OrderedDataStore entries are keyed by UserId (a string), not a name — a
-- name lookup is needed to show something readable on the board.
-- Players:GetNameFromUserIdAsync is the correct Roblox API for this (works
-- for ANY UserId, not just someone currently in this server) but can throw
-- on a network hiccup/rate limit, hence the pcall. Falls back to a
-- currently-connected Player instance with that UserId if the lookup
-- fails, and only as a last resort to a generic placeholder — so a single
-- failed lookup never breaks the whole board, just shows one uglier name
-- until the next refresh.
local function safeGetName(userId)
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and name then
		return name
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.UserId == userId then
			return player.Name
		end
	end
	return "Spieler#" .. tostring(userId)
end

-- Pushes THIS player's current Rebirths/LifetimeCashEarned into the two
-- OrderedDataStores, keyed by their own UserId — each player only ever
-- writes their OWN key, so unlike the roster below there's no read-modify-
-- write race to worry about, a plain SetAsync is safe. OrderedDataStore
-- values must be non-negative integers, hence the math.floor/math.max.
function LeaderboardService.SyncPlayer(player)
	local data = PlayerDataManager and PlayerDataManager.Get(player)
	if not data then
		return
	end

	if rebirthsStore then
		local ok, err = pcall(function()
			rebirthsStore:SetAsync(tostring(player.UserId), math.max(0, math.floor(data.Rebirths or 0)))
		end)
		if not ok then
			warn("[LeaderboardService] SyncPlayer (Rebirths) failed for " .. player.Name .. ": " .. tostring(err))
		end
	end

	if cashStore then
		local ok, err = pcall(function()
			cashStore:SetAsync(tostring(player.UserId), math.max(0, math.floor(data.LifetimeCashEarned or 0)))
		end)
		if not ok then
			warn("[LeaderboardService] SyncPlayer (Cash) failed for " .. player.Name .. ": " .. tostring(err))
		end
	end

	-- On request ("eine Rangliste für Cash/s") — the exact same whole-
	-- number total GetCreatureCashRates already hands EconomyService.
	-- FireDataUpdated for the HUD's own "Cash/s" display, just also pushed
	-- into its own global ranking here.
	if cashPerSecondStore and EconomyService then
		local ok, err = pcall(function()
			local _, totalRate = EconomyService.GetCreatureCashRates(player)
			cashPerSecondStore:SetAsync(tostring(player.UserId), math.max(0, math.floor(totalRate or 0)))
		end)
		if not ok then
			warn("[LeaderboardService] SyncPlayer (Cash/s) failed for " .. player.Name .. ": " .. tostring(err))
		end
	end
end

-- Called once from EconomyService.OnFloorReached, the very first time (per
-- PlayerDataManager's persisted ReachedFloor100 flag) this player's climb
-- reaches the top floor. Uses UpdateAsync (read-modify-write with automatic
-- retry on conflict), NOT a plain GetAsync+SetAsync pair — several servers
-- could have a player finish Floor 100 around the same moment, and a plain
-- Get-then-Set would let one server's write silently overwrite the other's
-- addition. UpdateAsync's callback re-runs on a conflict instead, so both
-- climbs always end up recorded.
function LeaderboardService.RecordFloor100(player)
	if rosterStore then
		local ok, err = pcall(function()
			rosterStore:UpdateAsync("Roster", function(old)
				old = old or {}
				for _, entry in ipairs(old) do
					if entry.UserId == player.UserId then
						return old -- already on the roster (shouldn't normally happen, given the ReachedFloor100 guard, but never add a duplicate either way)
					end
				end
				table.insert(old, {
					Name = player.Name,
					UserId = player.UserId,
					Timestamp = os.time(),
				})
				-- Hard cap so this single DataStore value can never grow
				-- unbounded — drops the OLDEST entries first once over the
				-- limit (see GameConfig.Leaderboard.HallOfFameMaxStored).
				while #old > GameConfig.Leaderboard.HallOfFameMaxStored do
					table.remove(old, 1)
				end
				return old
			end)
		end)
		if not ok then
			warn("[LeaderboardService] RecordFloor100 failed for " .. player.Name .. ": " .. tostring(err))
		end
	end

	-- Keeps this server's own in-memory copy consistent with what was just
	-- written, in case anything ever reads cachedHallOfFame again later
	-- (nothing does right now — the board itself no longer displays this
	-- roster, see this file's own top comment — so unlike the Cash/s
	-- update above there's no RefreshBoardText() call needed here).
	table.insert(cachedHallOfFame, {
		Name = player.Name,
		UserId = player.UserId,
		Timestamp = os.time(),
	})
end

-- Re-fetches the global Top-N Rebirths/Cash lists and the full Hall of Fame
-- roster from DataStore, and refreshes the board's text from the result.
-- Called periodically by StartPeriodicSync — never on a hot path (a claim,
-- a sell, a purchase), since GetSortedAsync/GetAsync both cost real
-- DataStore request budget.
function LeaderboardService.RefreshTopLists()
	if rebirthsStore then
		local ok, pagesOrErr = pcall(function()
			return rebirthsStore:GetSortedAsync(false, GameConfig.Leaderboard.TopCount)
		end)
		if ok then
			local list = {}
			for _, entry in ipairs(pagesOrErr:GetCurrentPage()) do
				local userId = tonumber(entry.key)
				table.insert(list, { Name = safeGetName(userId), UserId = userId, Value = entry.value })
			end
			cachedTopRebirths = list
		else
			warn("[LeaderboardService] RefreshTopLists (Rebirths) failed: " .. tostring(pagesOrErr))
		end
	end

	if cashStore then
		local ok, pagesOrErr = pcall(function()
			return cashStore:GetSortedAsync(false, GameConfig.Leaderboard.TopCount)
		end)
		if ok then
			local list = {}
			for _, entry in ipairs(pagesOrErr:GetCurrentPage()) do
				local userId = tonumber(entry.key)
				table.insert(list, { Name = safeGetName(userId), UserId = userId, Value = entry.value })
			end
			cachedTopCash = list
		else
			warn("[LeaderboardService] RefreshTopLists (Cash) failed: " .. tostring(pagesOrErr))
		end
	end

	if cashPerSecondStore then
		local ok, pagesOrErr = pcall(function()
			return cashPerSecondStore:GetSortedAsync(false, GameConfig.Leaderboard.TopCount)
		end)
		if ok then
			local list = {}
			for _, entry in ipairs(pagesOrErr:GetCurrentPage()) do
				local userId = tonumber(entry.key)
				table.insert(list, { Name = safeGetName(userId), UserId = userId, Value = entry.value })
			end
			cachedTopCashPerSecond = list
		else
			warn("[LeaderboardService] RefreshTopLists (Cash/s) failed: " .. tostring(pagesOrErr))
		end
	end

	if rosterStore then
		local ok, roster = pcall(function()
			return rosterStore:GetAsync("Roster")
		end)
		if ok and roster then
			cachedHallOfFame = roster
		elseif not ok then
			warn("[LeaderboardService] RefreshTopLists (Roster) failed: " .. tostring(roster))
		end
	end

	LeaderboardService.RefreshBoardText()
end

-- Writes the 3 cached lists into the board's TextLabels — pure display, no
-- DataStore calls, safe to call as often as needed (e.g. right after
-- RecordFloor100 above, on top of the periodic RefreshTopLists calls).
-- No-ops harmlessly if BuildBoard() hasn't run yet (labels still nil).
function LeaderboardService.RefreshBoardText()
	if rebirthsListLabel then
		if #cachedTopRebirths == 0 then
			rebirthsListLabel.Text = "Noch keine Daten..."
		else
			local lines = {}
			for i, entry in ipairs(cachedTopRebirths) do
				table.insert(lines, i .. ". " .. entry.Name .. " — " .. entry.Value)
			end
			rebirthsListLabel.Text = table.concat(lines, "\n")
		end
	end

	if cashListLabel then
		if #cachedTopCash == 0 then
			cashListLabel.Text = "Noch keine Daten..."
		else
			local lines = {}
			for i, entry in ipairs(cachedTopCash) do
				table.insert(lines, i .. ". " .. entry.Name .. " — $" .. formatCashShort(entry.Value))
			end
			cashListLabel.Text = table.concat(lines, "\n")
		end
	end

	-- On request ("statt der Anzeige wer Floor 100 erreicht hat eine
	-- Rangliste für Cash/s") — this sign used to list Floor-100 climbers
	-- (see this file's own top comment for where that roster tracking
	-- went, it's still recorded, just not shown here anymore).
	if cashPerSecondListLabel then
		if #cachedTopCashPerSecond == 0 then
			cashPerSecondListLabel.Text = "Noch keine Daten..."
		else
			local lines = {}
			for i, entry in ipairs(cachedTopCashPerSecond) do
				table.insert(lines, i .. ". " .. entry.Name .. " — $" .. formatCashShort(entry.Value) .. "/s")
			end
			cashPerSecondListLabel.Text = table.concat(lines, "\n")
		end
	end
end

-- === Leaderboard panel (scrollable/paged Top-100 view + "where do I rank?") ===
-- On request ("die Bestenliste in diesem Spiel hat Bilder der Spieler und
-- man kann von Top1 bis Top 200 runter scrollen" -> "für alle 3 Ranglisten
-- ... begrenze es auf top 100 ... seine Position einblenden") — this powers
-- the new UI panel (see UIBuilder.lua's Leaderboard panel / init.server.
-- lua's GetLeaderboardPanelData remote), reachable via the board's own
-- ProximityPrompt (see BuildBoard below). Sits ALONGSIDE the physical
-- signs' short always-visible text (unchanged), not replacing them.

-- Maps a panel category to its OrderedDataStore + cached Top-100 list, plus
-- a function that reads THIS player's own CURRENT value straight from live
-- game state (never the DataStore, which can be up to SyncIntervalSeconds
-- stale) — so "Du: Rang X — Wert Y" always matches the truth even between
-- periodic syncs.
local function getCategoryInfo(category)
	if category == "Rebirths" then
		return rebirthsStore, cachedTopRebirths, function(player)
			local data = PlayerDataManager and PlayerDataManager.Get(player)
			return data and math.max(0, math.floor(data.Rebirths or 0)) or 0
		end
	elseif category == "Cash" then
		return cashStore, cachedTopCash, function(player)
			local data = PlayerDataManager and PlayerDataManager.Get(player)
			return data and math.max(0, math.floor(data.LifetimeCashEarned or 0)) or 0
		end
	elseif category == "CashPerSecond" then
		return cashPerSecondStore, cachedTopCashPerSecond, function(player)
			if not EconomyService then
				return 0
			end
			local _, totalRate = EconomyService.GetCreatureCashRates(player)
			return math.max(0, math.floor(totalRate or 0))
		end
	end
	return nil, nil, nil
end

-- [userId .. "_" .. category] = { Rank = number|nil, At = os.clock() } — the
-- last extended-search result for this player+category, reused while
-- RankSearchCooldownSeconds hasn't elapsed (see GetOwnStanding below), so
-- repeatedly opening/closing the panel can't spam GetSortedAsync/
-- AdvanceToNextPageAsync calls.
local rankSearchCache = {}

-- Only called when the viewing player ISN'T already in the cached Top 100
-- (the cheap case, handled directly in GetOwnStanding). Pages through up to
-- GameConfig.Leaderboard.RankSearchExtraPages MORE 100-entry pages looking
-- for `userId`, computing their exact rank if found. Real, bounded DataStore
-- cost (see GameConfig.Leaderboard's own comment on RankSearchExtraPages) —
-- only ever called on-demand (a player actually opening the panel) and
-- throttled by GetOwnStanding's cooldown check, never from the periodic
-- StartPeriodicSync loop.
local function searchExtendedRank(store, userId)
	if not store then
		return nil
	end

	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, GameConfig.Leaderboard.TopCount)
	end)
	if not ok then
		warn("[LeaderboardService] searchExtendedRank failed: " .. tostring(pages))
		return nil
	end

	-- Deliberately RE-SCANS this fresh page 1 too, rather than assuming it's
	-- identical to the already-cached Top 100 the caller just checked — the
	-- two CAN differ (the cache is only refreshed every SyncIntervalSeconds,
	-- but this fresh fetch reflects right now), e.g. right after this exact
	-- player's own value jumped enough to newly enter the real Top 100. That
	-- costs nothing extra in DataStore requests (this page was already
	-- fetched by the GetSortedAsync call above either way) — only a little
	-- more, essentially free, Lua-side scanning.
	local rankOffset = 0

	for _ = 1, 1 + GameConfig.Leaderboard.RankSearchExtraPages do
		local page = pages:GetCurrentPage()
		for index, entry in ipairs(page) do
			if tonumber(entry.key) == userId then
				return rankOffset + index
			end
		end
		rankOffset += #page

		if pages.IsFinished then
			break
		end
		local advanceOk, advanceErr = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanceOk then
			warn("[LeaderboardService] searchExtendedRank page advance failed: " .. tostring(advanceErr))
			break
		end
	end

	return nil -- not found within the searched window
end

-- Returns { Rank = number|nil, Value = number, InTop = bool } for `player`
-- in `category` ("Rebirths" | "Cash" | "CashPerSecond"). Rank is nil only
-- when they're both missing from the cached Top 100 AND not found within
-- the bounded extended search above — the panel then shows their live Value
-- with no exact rank ("außerhalb Top X") instead of nothing at all.
function LeaderboardService.GetOwnStanding(player, category)
	local store, cachedList, getLiveValue = getCategoryInfo(category)
	local liveValue = getLiveValue and getLiveValue(player) or 0

	for index, entry in ipairs(cachedList or {}) do
		if entry.UserId == player.UserId then
			return { Rank = index, Value = liveValue, InTop = true }
		end
	end

	-- Not in the cached Top 100 — try the bounded extended search, throttled
	-- per player+category (see GameConfig.Leaderboard.RankSearchCooldownSeconds)
	-- so re-opening the panel repeatedly can't keep re-triggering it.
	local cacheKey = tostring(player.UserId) .. "_" .. category
	local cached = rankSearchCache[cacheKey]
	local now = os.clock()

	if cached and (now - cached.At) < GameConfig.Leaderboard.RankSearchCooldownSeconds then
		return { Rank = cached.Rank, Value = liveValue, InTop = false }
	end

	local rank = searchExtendedRank(store, player.UserId)
	rankSearchCache[cacheKey] = { Rank = rank, At = now }
	return { Rank = rank, Value = liveValue, InTop = false }
end

-- Called by init.server.lua's GetLeaderboardPanelData remote — the whole
-- Leaderboard panel's data in one round trip (all 3 categories at once, on
-- request "für alle 3 Ranglisten"), so switching tabs client-side never
-- needs a second server call.
function LeaderboardService.GetPanelData(player)
	return {
		Rebirths = { Entries = cachedTopRebirths, Self = LeaderboardService.GetOwnStanding(player, "Rebirths") },
		Cash = { Entries = cachedTopCash, Self = LeaderboardService.GetOwnStanding(player, "Cash") },
		CashPerSecond = { Entries = cachedTopCashPerSecond, Self = LeaderboardService.GetOwnStanding(player, "CashPerSecond") },
	}
end

-- Builds one upright sign (a Part + SurfaceGui, same convention as
-- BaseService's base-entrance Sign) at `localX` studs from the board
-- cluster's own center, with a title bar and a big list area below it.
-- Returns the list TextLabel so the caller can keep a reference to refresh
-- later.
local function buildSign(folder, boardCFrame, localX, title, titleColor)
	local lb = GameConfig.Leaderboard

	local sign = Instance.new("Part")
	sign.Name = title:gsub("%s+", ""):gsub("[^%w]", "") .. "Sign"
	sign.Anchored = true
	sign.CanCollide = true
	sign.Size = Vector3.new(lb.SignWidth, lb.SignHeight, lb.SignThickness)
	sign.Material = Enum.Material.Concrete
	sign.Color = Color3.fromRGB(40, 40, 48)
	sign.CFrame = boardCFrame * CFrame.new(localX, 1 + lb.SignHeight / 2, 0)
	sign.Parent = folder

	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.Parent = sign

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, 0, 0.16, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextColor3 = titleColor
	titleLabel.TextStrokeTransparency = 0.2
	titleLabel.TextScaled = true
	titleLabel.Font = Enum.Font.GothamBlack
	titleLabel.Parent = gui

	local listLabel = Instance.new("TextLabel")
	listLabel.Name = "List"
	listLabel.Size = UDim2.new(0.92, 0, 0.8, 0)
	listLabel.Position = UDim2.new(0.04, 0, 0.18, 0)
	listLabel.BackgroundTransparency = 1
	listLabel.Text = "Lade..."
	listLabel.TextColor3 = Color3.new(1, 1, 1)
	listLabel.TextStrokeTransparency = 0.4
	listLabel.TextScaled = true
	listLabel.TextXAlignment = Enum.TextXAlignment.Left
	listLabel.TextYAlignment = Enum.TextYAlignment.Top
	listLabel.Font = Enum.Font.Gotham
	listLabel.Parent = gui

	return listLabel
end

-- Builds the physical 3-sign board at the tower's base ("in der Mitte bei
-- dem Turm"). Placed BoardRadius studs from the tower's own center (0,0),
-- not dead-center on top of it — the tower's spiral (see TowerGenerator)
-- already occupies the true center at every height, but every LOW floor
-- (the only ones near ground level, where this board sits) has a radius of
-- at most GameConfig.Floors.HorizontalOffset (17 studs, or
-- EarlyHorizontalOffset=11 for the very first few) — floors only reach
-- further out than that once they've also climbed far above ground height
-- (see getHorizontalOffsetForFloor/getGapForFloor in TowerGenerator.lua).
-- BoardRadius=35 is comfortably outside that near-ground footprint at any
-- angle, while still well inside GameConfig.Base.PlotRadius (130), so it
-- never collides with the tower OR any of the 4 base plots.
-- BoardAngleDegrees=135 additionally puts it diagonally BETWEEN two base
-- plots (which sit at 0°/90°/180°/270°, see BaseService.getPlotCFrame) so
-- it's not sitting directly on the straight walking line to any single
-- plot.
function LeaderboardService.BuildBoard()
	local lb = GameConfig.Leaderboard
	local angle = math.rad(lb.BoardAngleDegrees)
	local centerX = math.cos(angle) * lb.BoardRadius
	local centerZ = math.sin(angle) * lb.BoardRadius
	-- Front face points back toward the tower's center, so players
	-- approaching from the tower see the readable side first — same
	-- lookAt-toward-the-tower convention as BaseService.getPlotCFrame.
	local boardCFrame = CFrame.lookAt(Vector3.new(centerX, 0, centerZ), Vector3.new(0, 0, 0))

	local folder = Instance.new("Folder")
	folder.Name = "HallOfFameBoard"
	folder.Parent = Workspace

	local platform = Instance.new("Part")
	platform.Name = "BoardPlatform"
	platform.Anchored = true
	platform.Size = Vector3.new(lb.BoardSpacing * 3, 1, 8)
	platform.Material = Enum.Material.Marble
	platform.Color = Color3.fromRGB(225, 220, 205)
	platform.CFrame = boardCFrame * CFrame.new(0, 0.5, 0)
	platform.Parent = folder

	cashPerSecondListLabel = buildSign(
		folder, boardCFrame, -lb.BoardSpacing,
		"Top Cash/s",
		Color3.fromRGB(255, 215, 0)
	)
	rebirthsListLabel = buildSign(
		folder, boardCFrame, 0,
		"Top Wiedergeburten",
		Color3.fromRGB(0, 200, 255)
	)
	cashListLabel = buildSign(
		folder, boardCFrame, lb.BoardSpacing,
		"Top Gesamt-Cash",
		Color3.fromRGB(80, 255, 120)
	)

	-- On request ("kann man den jeweiligen Spieler unten einblenden ... seine
	-- Position einblenden") — the 3 signs above still show a quick always-
	-- visible Top-10-ish glance, but seeing the full Top 100 (with avatars)
	-- and your own rank needs a real UI panel (see UIBuilder.lua's
	-- Leaderboard panel), not more text crammed onto a stone sign. Same
	-- "walk up, hold E, panel opens" convention as every other kiosk in this
	-- game (Glücksrad/Jump-Upgrade/Fast-Travel — see BaseService.lua's
	-- buildStationPart), just a plain ProximityPrompt directly on the
	-- platform since this board has no station billboard/icon of its own.
	local panelPrompt = Instance.new("ProximityPrompt")
	panelPrompt.Name = "LeaderboardPanelPrompt"
	panelPrompt.ActionText = "Bestenliste ansehen"
	panelPrompt.ObjectText = "Rangliste"
	panelPrompt.HoldDuration = 0.3
	panelPrompt.MaxActivationDistance = 20
	panelPrompt.RequiresLineOfSight = false
	panelPrompt.Style = Enum.ProximityPromptStyle.Custom
	panelPrompt.Parent = platform

	panelPrompt.Triggered:Connect(function(triggeringPlayer)
		if remotesFolder then
			remotesFolder.RequestLeaderboardPanel:FireClient(triggeringPlayer)
		end
	end)

	LeaderboardService.RefreshBoardText()
end

-- The periodic StartPeriodicSync loop below (every SyncIntervalSeconds,
-- default 3 minutes) is deliberately slow to stay DataStore-budget-
-- friendly, but that meant a fresh Rebirth or a creature sale could sit
-- for up to 3 minutes before showing on the board — visibly "wrong" right
-- after the very moment a player would actually go look at it. Called
-- from EconomyService.Rebirth and CreatureService.SellCreature right after
-- a SUCCESSFUL rebirth/sale (deliberate, comparatively infrequent player
-- actions — not from the pedestal passive-income Touched collection,
-- which can fire far more often and would risk exhausting the
-- GetSortedAsync request budget). Always syncs the triggering player's own
-- numbers immediately (cheap — 1-2 SetAsync calls on their own key), but
-- only re-fetches the Top-N lists (the expensive GetSortedAsync/GetAsync
-- part) if at least IMMEDIATE_REFRESH_MIN_GAP seconds have passed since
-- the last one — so even a burst of several rebirths/sales in a row from
-- multiple players can't hammer the DataStore request budget.
local IMMEDIATE_REFRESH_MIN_GAP = 5
local lastImmediateRefresh = 0

-- On request ("Auto-Sammeln zeigt zwischendurch nur ~1 Tick Cash statt
-- mehrerer, obwohl mehrere Sekunden vergangen sind") — found the real cause:
-- SyncPlayer/RefreshTopLists below make genuine, YIELDING SetAsync/
-- GetSortedAsync calls, and this function used to run them INLINE. For an
-- Auto-Sammeln owner, EconomyService.StartPassiveIncomeLoop calls
-- NotifyCashCollected (which calls this) directly from inside its single
-- shared per-tick loop — the SAME coroutine that pays out EVERY player,
-- sequentially, every tick. Running a real DataStore round-trip inline
-- there didn't just delay the triggering player: it blocked the whole
-- loop's `task.wait(1)` from ever starting the next cycle until the
-- DataStore call(s) finished, stretching the effective payout cadence for
-- EVERY player on the server from 1s to however long those calls took
-- (worse under DataStore budget throttling) — exactly matching "several
-- real seconds passed, but only about one tick's worth of Cash was paid
-- out". The same inline call also used to make the Rebirth/Sell
-- RemoteFunction handlers (the other two callers of this function) hang
-- until the DataStore write finished before the player saw their
-- confirmation.
--
-- Fix: run the actual sync work in its own coroutine via task.spawn.
-- task.spawn runs its function body SYNCHRONOUSLY up to its first yield —
-- so the cooldown checks below still gate correctly at the real call
-- instant (no race with concurrent callers) — but the moment SyncPlayer/
-- RefreshTopLists actually yields on a DataStore call, that suspends only
-- THIS background coroutine, never the payout loop (or the Rebirth/Sell
-- handler) that called RequestImmediateRefresh.
function LeaderboardService.RequestImmediateRefresh(player)
	task.spawn(function()
		LeaderboardService.SyncPlayer(player)

		local now = os.clock()
		if now - lastImmediateRefresh < IMMEDIATE_REFRESH_MIN_GAP then
			return
		end
		lastImmediateRefresh = now
		LeaderboardService.RefreshTopLists()
	end)
end

-- Same idea as RequestImmediateRefresh above, but for the passive-income
-- pedestal collection specifically (BaseService's Display Touched handler)
-- — called on EVERY successful collect, which can happen far more often
-- than a Rebirth or a sale (every payout tick, on every pedestal, for up
-- to GameConfig.Base.MaxPlayers players at once). RequestImmediateRefresh
-- itself already throttles the expensive GetSortedAsync refresh, but its
-- SyncPlayer(player) call (a real SetAsync) still runs every single time
-- it's invoked — fine for an occasional Rebirth/sale, not fine for a
-- player standing there collecting from a dozen pedestals in a few
-- seconds. This adds a SEPARATE, PER-PLAYER cooldown in front of that, so
-- even non-stop pedestal collection can push at most one real sync every
-- COLLECT_SYNC_MIN_GAP seconds for that player — close enough to live to
-- fix "beim Sammeln von Geld ist es nicht live" without risking the
-- DataStore write budget.
local lastCollectSync = {} -- [userId] = os.clock() of last allowed sync
local COLLECT_SYNC_MIN_GAP = 5

function LeaderboardService.NotifyCashCollected(player)
	local now = os.clock()
	local last = lastCollectSync[player.UserId]
	if last and now - last < COLLECT_SYNC_MIN_GAP then
		return
	end
	lastCollectSync[player.UserId] = now
	LeaderboardService.RequestImmediateRefresh(player)
end

-- Runs forever: syncs every currently-online player's Rebirths/
-- LifetimeCashEarned into the global rankings, then re-fetches the Top-N
-- lists and the roster, every SyncIntervalSeconds. Runs once immediately
-- (with whoever's already online at that moment) rather than waiting a
-- full interval before the board shows anything for the first time.
function LeaderboardService.StartPeriodicSync()
	task.spawn(function()
		while true do
			for _, player in ipairs(Players:GetPlayers()) do
				LeaderboardService.SyncPlayer(player)
			end
			LeaderboardService.RefreshTopLists()
			task.wait(GameConfig.Leaderboard.SyncIntervalSeconds)
		end
	end)
end

return LeaderboardService
