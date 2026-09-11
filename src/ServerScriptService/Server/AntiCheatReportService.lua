--[[
	AntiCheatReportService.lua
	On request ("die Meldung soll im richtigen Spiel weg, Spieler sollen
	normal weiterspielen können, aber ich will einen Report sehen und selbst
	entscheiden was passiert") — a single place for the claim-spot and
	Mega-Truhe "you must have really reached this floor" anti-cheat checks
	(see init.server.lua's onClaimCreature wiring and SummitChestService.Open)
	to record a suspicious case WITHOUT blocking the player or showing them
	anything. The action they were trying to do (claim a creature, open the
	chest) still goes through — same "no automatic punishment, just visibility"
	shape GameConfig.AntiCheat's own floor-skip check already used for
	OnFloorReached, just also persisted here (that one only ever warn()s)
	so you can review the full history on demand with "/reports" and decide
	yourself, per player, what — if anything — to do about it.

	Storage is a single capped JSON list (GameConfig.AntiCheat.ReportMaxStored
	entries, oldest dropped first) under one fixed DataStore key, read-modify-
	written via UpdateAsync — same shape as LeaderboardService's Hall of Fame
	roster (LeaderboardRosterName), chosen for the same reason: this is a
	small, infrequently-written, whole-list-at-once piece of data, not
	something that needs an OrderedDataStore's per-key sorting.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local AntiCheatReportService = {}

-- Same "GetDataStore can throw outright" guard every other store in this
-- game uses (PlayerDataManager.lua, LeaderboardService.lua) — an unpublished
-- place, or Studio API access left off, just means reports don't persist
-- this session instead of crashing server startup.
local reportsStore
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.DataStore.AntiCheatReportsName)
	end)
	if ok then
		reportsStore = result
	else
		warn("[AntiCheatReportService] DataStore unavailable, reports will not persist this session: " .. tostring(result))
	end
end

local REPORTS_KEY = "Reports"

-- Records ONE suspicious case. `kind` is a short machine-readable tag
-- ("ClaimSpot" / "SummitChest" / ...), `details` a small flat table merged
-- into the stored entry (e.g. { FloorIndex = 42, HighestFloor = 30 }) — kept
-- free-form per call site rather than a fixed schema, since each check has
-- its own relevant numbers.
--
-- Always warn()s too (visible in Studio's/the live game's own server output,
-- same as the floor-skip check), so this is still visible in real time even
-- if the DataStore write itself fails or hasn't synced yet.
function AntiCheatReportService.RecordViolation(player, kind, details)
	local entry = {
		Name = player.Name,
		UserId = player.UserId,
		Kind = kind,
		Timestamp = os.time(),
	}
	if details then
		for key, value in pairs(details) do
			entry[key] = value
		end
	end

	local ok, detailsJson = pcall(function()
		return HttpService:JSONEncode(details or {})
	end)
	warn(string.format(
		"[AntiCheatReport] %s (UserId %d): %s — %s",
		player.Name, player.UserId, kind, ok and detailsJson or tostring(details)
	))

	if not reportsStore then
		return
	end

	local ok, err = pcall(function()
		reportsStore:UpdateAsync(REPORTS_KEY, function(old)
			old = old or {}
			table.insert(old, entry)
			-- Hard cap, oldest dropped first — same "never grows unbounded"
			-- shape as LeaderboardService.RecordFloor100's Hall of Fame cap.
			while #old > GameConfig.AntiCheat.ReportMaxStored do
				table.remove(old, 1)
			end
			return old
		end)
	end)
	if not ok then
		warn("[AntiCheatReportService] RecordViolation failed to persist for " .. player.Name .. ": " .. tostring(err))
	end
end

-- Fetches the full stored report list for the "/reports" admin command
-- (init.server.lua). A real, budgeted DataStore read — only called on
-- explicit admin request, never on any hot path.
function AntiCheatReportService.GetReports()
	if not reportsStore then
		return {}
	end

	local ok, result = pcall(function()
		return reportsStore:GetAsync(REPORTS_KEY)
	end)
	if not ok then
		warn("[AntiCheatReportService] GetReports failed: " .. tostring(result))
		return {}
	end
	return result or {}
end

return AntiCheatReportService
