--[[
	SummitChestService.lua
	The "Mega-Truhe" — a single physical chest at Floor 100 (the very last
	floor, see GameConfig.Floors.Count), built in TowerGenerator.lua's floor
	loop alongside Floor 100's own distinct look (GameConfig.Summit.
	PlatformColor/Material/TitleText). Openable once per REAL day per player
	(data.LastSummitChestAt, a persisted os.time() Unix timestamp — same
	"has to actually hold across a rejoin" reasoning as WheelService's
	LastWheelSpinAt), via its own ProximityPrompt, no panel needed: unlike
	the Glücksrad (which needed a visible wheel + two separate buttons), this
	is a single "walk up, interact, see what you got" action, so the whole
	thing runs through one Triggered handler straight into SummitChestService
	.Open below.

	On request: give players who've reached Floor 100 (and, once Fast Travel
	is configured, can return there without a full re-climb — see
	FastTravelService.lua) a genuine reason to keep coming back, instead of
	the silent one-time Hall of Fame entry EconomyService.OnFloorReached
	already grants.

	Each opening rolls GameConfig.Summit.EventCreatureChancePercent (30% by
	default) for ONE of the two creatures in EventCreatureWeights (Hacker/
	Lava — deliberately NOT Glitchrot/Singularity, which stay PURE
	event-exclusives, see GameConfig.CreatureRarities' own comment on them),
	weighted the same "each step up is a real drop" way the Glücksrad's own
	Prizes table is. The other (100 - this)% grants
	GameConfig.Summit.ConsolationCashBonusSeconds worth of Cash instead (via
	EconomyService.GrantCashBonusSeconds — relative to the player's OWN
	current income, same as every other Cash bonus in this game), so a
	"miss" still feels like something after the climb, never a wasted trip.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local SummitChestService = {}

local PlayerDataManager
local EconomyService
local CreatureService
local AntiCheatReportService
local remotesFolder

function SummitChestService.Init(deps)
	PlayerDataManager = deps.PlayerDataManager
	EconomyService = deps.EconomyService
	CreatureService = deps.CreatureService
	AntiCheatReportService = deps.AntiCheatReportService
	remotesFolder = deps.Remotes
end

-- Same "%dh %02dm" / "%dm %02ds" / "%ds" shape as UIBuilder.lua's client-side
-- formatWheelRemaining — kept as a separate, plain-server-side copy here
-- rather than shared, since this only ever feeds a single Notice string, not
-- a live-updating UI countdown.
local function formatRemaining(seconds)
	seconds = math.max(0, math.ceil(seconds))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, secs)
	end
	return string.format("%ds", secs)
end

-- Weighted pick between the two keys in GameConfig.Summit.EventCreatureWeights
-- (currently just "Hacker"/"Lava") — same plain-relative-weight roll shape as
-- WheelService.lua's rollPrize, just over a tiny fixed 2-entry table instead
-- of a whole Prizes list. Sorted keys first so the roll is deterministic
-- given the same math.random() sequence (Lua's pairs() iteration order isn't
-- guaranteed) — doesn't affect the actual odds, just makes this testable.
local function pickEventRarity()
	local weights = GameConfig.Summit.EventCreatureWeights
	local rarities = {}
	for rarity in pairs(weights) do
		table.insert(rarities, rarity)
	end
	table.sort(rarities)

	local total = 0
	for _, rarity in ipairs(rarities) do
		total += weights[rarity]
	end

	local roll = math.random() * total
	local cumulative = 0
	for _, rarity in ipairs(rarities) do
		cumulative += weights[rarity]
		if roll <= cumulative then
			return rarity
		end
	end
	return rarities[#rarities]
end

-- Formats a Cash amount the way the pedestal/leaderboard displays already
-- do (BaseService.formatCashRate / LeaderboardService.formatCashShort) — a
-- local copy, not shared, same "keep each module independent" convention
-- those two already follow. On request: the Mega-Truhe's own Cash-
-- consolation Notice below used to print one long unreadable raw digit
-- string at high Rebirth ("+107717538200 Cash!") — this abbreviates it to
-- "+107,7B Cash!" instead, below 1000 it's still a plain integer.
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
		return string.format("%d", value)
	end
end

-- Picks a random named creature (GameConfig.Creatures) matching the given
-- Rarity — same pool WheelService.lua's own pickRandomCreatureOfRarity draws
-- from. Returns nil if no creature of that rarity is configured (shouldn't
-- happen with the shipped roster, but guards against a future GameConfig
-- edit removing the last Hacker/Lava entry).
local function pickRandomCreatureOfRarity(rarity)
	local matches = {}
	for _, def in ipairs(GameConfig.Creatures) do
		if def.Rarity == rarity then
			table.insert(matches, def)
		end
	end
	if #matches == 0 then
		return nil
	end
	return matches[math.random(1, #matches)]
end

-- Called from the chest's ProximityPrompt.Triggered (see TowerGenerator.lua)
-- — checks/consumes the once-per-real-day cooldown, then rolls and grants
-- the reward, same "consumed BEFORE the prize is applied" ordering
-- WheelService.SpinWheel uses (so an unlucky "Creature, base full" roll
-- still costs the day's opening rather than letting someone retry
-- immediately for a different prize).
function SummitChestService.Open(player)
	local data = PlayerDataManager.Get(player)
	if not data then
		return
	end

	-- Anti-cheat (on request, following a security review): the chest's
	-- ProximityPrompt only checks PHYSICAL distance, same as every other
	-- kiosk — a speed/fly hack could reach Floor 100 without ever legitimately
	-- climbing it and still open this. data.HighestFloor covering Floor 100
	-- itself is the "really reached it" signal, same principle as the
	-- Fast-Travel fix (FastTravelService.Teleport) and the claim-spot fix
	-- (init.server.lua's onClaimCreature wiring).
	--
	-- On request ("die Meldung soll im richtigen Spiel weg, Spieler sollen
	-- normal weiterspielen können, aber ich will einen Report sehen und
	-- selbst entscheiden"): no longer blocks the chest or shows the player
	-- anything — same "never interrupt, just record it" shape GameConfig.
	-- AntiCheat's own floor-skip check already uses. AntiCheatReportService
	-- persists every suspicious case for you to review with "/reports" and
	-- act on yourself, per player — the opening below still goes ahead
	-- either way, and still costs the real daily cooldown like any other
	-- opening.
	if AntiCheatReportService and data.HighestFloor < GameConfig.Floors.Count then
		AntiCheatReportService.RecordViolation(player, "SummitChest", {
			HighestFloor = data.HighestFloor,
			RequiredFloor = GameConfig.Floors.Count,
		})
	end

	local cooldown = GameConfig.Summit.ChestCooldownSeconds
	local lastOpen = data.LastSummitChestAt or 0
	local elapsed = os.time() - lastOpen
	if elapsed < cooldown then
		if remotesFolder then
			remotesFolder.Notice:FireClient(
				player,
				"🏆 Mega-Truhe ist erst wieder in " .. formatRemaining(cooldown - elapsed) .. " verfügbar."
			)
		end
		return
	end

	data.LastSummitChestAt = os.time()

	local roll = math.random() * 100
	if roll <= GameConfig.Summit.EventCreatureChancePercent then
		local rarity = pickEventRarity()
		local def = pickRandomCreatureOfRarity(rarity)
		if def then
			local granted = CreatureService.ClaimPhysicalCreature(player, def)
			if granted then
				if remotesFolder then
					remotesFolder.Notice:FireClient(
						player,
						"🏆 Mega-Truhe: " .. def.Name .. " (" .. rarity .. ") gewonnen!"
					)
				end
			end
			-- Base full: ClaimPhysicalCreature already sent its own Notice
			-- explaining that — don't overwrite it with a second, confusing
			-- message. The day's opening is still consumed either way (see
			-- this function's own top comment).
			return
		end
		-- Mis-configured rarity (no matching GameConfig.Creatures entry) —
		-- fall through to the Cash consolation instead of granting nothing.
	end

	local bonus = EconomyService.GrantCashBonusSeconds(player, GameConfig.Summit.ConsolationCashBonusSeconds)
	if remotesFolder then
		remotesFolder.Notice:FireClient(player, "🏆 Mega-Truhe: +" .. formatCashShort(bonus) .. " Cash!")
	end
end

return SummitChestService
