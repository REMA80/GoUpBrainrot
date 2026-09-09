--[[
	WheelService.lua
	The "Glücksrad" (wheel of fortune) — a single SHARED kiosk (see
	BaseService.lua's buildWheelKiosk / GameConfig.WheelOfFortune), reachable
	by every player from any base. Walking up to it OPENS A PANEL (see
	UIBuilder.lua's Wheel panel / init.client.lua's RequestWheelPanel
	listener) showing the 3 visible prize segments (Cash / 2x Cash /
	Brainrot-Geheimnis — reduced from an earlier 8-segment layout on
	request, "gleich mit auf 3 Segmente umbauen") and THREE buttons
	("Kaufe 1 | Drehen (1) | Kaufe 3", redesigned on request from an earlier
	2-button "Täglicher Spin" + "Spin kaufen (Robux)" layout to match a
	reference screenshot), rather than spinning immediately — built on
	request, to give players something to actively do while their passive
	Cash income slowly builds up between climbs, instead of just standing
	around waiting.

	Two independent ways to spin, both available as buttons in the SAME
	panel:
	  SpinWheel(player)             — the FREE path (middle "Drehen (1)"
	                          button), one per real day, mechanically
	                          UNCHANGED from before this 3-button redesign.
	                          The cooldown is PERSISTED (PlayerDataManager's
	                          data.LastWheelSpinAt, a real os.time() Unix
	                          timestamp) — unlike ShopService's Slap Hand
	                          combat cooldown (fine to reset on rejoin), a
	                          free-reward cooldown has to actually hold or a
	                          player could just rejoin to spin again
	                          immediately. Returns a structured result table
	                          directly to its RemoteFunction caller (see
	                          init.server.lua's SpinWheelFree) — the panel
	                          shows the result the instant the call returns.
	                          Never gets the LuckBuff below.
	  SpinWheelPaid(player, spinCount) — the ROBUX path (left "Kaufe 1" /
	                          right "Kaufe 3" buttons, each its own real
	                          Developer Product in GameConfig.WheelOfFortune.
	                          RobuxProducts), called from MonetizationService.
	                          ProcessReceipt once Roblox confirms a real
	                          purchase. Spins spinCount times IN A ROW (1 or
	                          3), each one WITH GameConfig.WheelOfFortune.
	                          LuckBuff.MysteryWeightMultiplier applied ("x2
	                          Glück", on request — doubles just that spin's
	                          own Brainrot-Geheimnis odds, see performSpin's
	                          own comment). Never touches data.
	                          LastWheelSpinAt in either direction — a fully
	                          independent extra on top of the daily free
	                          spin, no cooldown check at all. A Robux
	                          purchase can't return a result synchronously
	                          to the button that started it (ProcessReceipt
	                          runs later, out of band), so this instead FIRES
	                          the WheelSpinResult remote with the FULL ARRAY
	                          of spinCount results once every spin in the
	                          batch is resolved — UIBuilder.
	                          PlayWheelSpinSequence then animates the needle
	                          through all of them, one after another.
	  GetState(player)       — read-only snapshot for when the panel opens
	                          (free-spin ready?/remaining seconds, the
	                          RobuxProducts array, and LuckBuff) — fetched on
	                          demand via the GetWheelState RemoteFunction,
	                          same "ask fresh when the panel opens" pattern
	                          as the Brainrot-Dex's GetDiscoveredCreatures.
	Both spin paths funnel into the same performSpin(player, mysteryWeightMultiplier)
	below, so there is only ONE prize table and ONE grant path regardless of
	how the spin was paid for — SpinWheelPaid just calls it spinCount times
	with the buff multiplier, SpinWheel calls it once with no multiplier.

	Reward is picked by a weighted roll over GameConfig.WheelOfFortune.Prizes
	(see that table's own comment for the exact odds/tuning). Three prize
	Types, each handled below in applyPrize:
	  "Cash"            — EconomyService.GrantCashBonusSeconds (relative to
	                      the player's own current income, never trivial or
	                      game-breaking regardless of progress).
	  "DoubleCash"      — EconomyService.GrantTemporaryCashMultiplier (a
	                      temporary 2x on ALL passive income).
	  "BrainrotMystery" — a SECOND, independent weighted roll over
	                      GameConfig.WheelOfFortune.MysteryRarities
	                      (rollMysteryRarity below) decides the Rarity,
	                      then CreatureService.ClaimPhysicalCreature grants
	                      a randomly picked GameConfig.Creatures entry of
	                      that Rarity — EXACTLY the same grant path a tower
	                      pickup uses (same capacity check, same
	                      CreatureObtained popup, same pedestal placement),
	                      so there's no second "give a creature" code path
	                      to keep in sync.

	Every prize also maps onto exactly one of GameConfig.WheelOfFortune.
	Segments — the WHEEL'S 3 visible slices (Cash / DoubleCash /
	BrainrotMystery, see segmentIndexForPrize's own comment) — so the
	client's spin animation always lands on the segment that matches what
	was actually won.

	A short German confirmation still goes out over the existing Notice text
	popup too (+ the automatic CreatureObtained popup for Creature prizes),
	same as before this panel existed — the panel's own in-line result text
	is the primary feedback now, but Notice stays as a redundant, always-
	visible confirmation even if the panel is somehow closed already.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local WheelService = {}

local PlayerDataManager
local EconomyService
local CreatureService
local remotesFolder

function WheelService.Init(deps)
	PlayerDataManager = deps.PlayerDataManager
	EconomyService = deps.EconomyService
	CreatureService = deps.CreatureService
	remotesFolder = deps.Remotes
end

-- [segmentKey] = list of 1-based indices into GameConfig.WheelOfFortune.
-- Segments matching that key — built once from the shipped table so
-- segmentIndexForPrize below is a cheap lookup, not a linear scan on every
-- single spin. Kept as a list (not a single index) even though the current
-- 3-segment artwork has exactly one segment per Key, so a future artwork
-- with duplicate wedges (like the old 8-segment layout) would still work
-- without touching this code.
local segmentIndexByKey = {}
for i, segment in ipairs(GameConfig.WheelOfFortune.Segments) do
	segmentIndexByKey[segment.Key] = segmentIndexByKey[segment.Key] or {}
	table.insert(segmentIndexByKey[segment.Key], i)
end

-- Maps a rolled Prize (from GameConfig.WheelOfFortune.Prizes) onto the
-- Segments index the wheel's spin animation should land on — "Cash" and
-- "DoubleCash" map onto a segment of the same Key, "BrainrotMystery" maps
-- onto the single "BrainrotMystery" segment regardless of which Rarity the
-- internal MysteryRarities sub-roll ends up granting (the wheel itself only
-- ever shows ONE mystery wedge — the actual won Rarity is revealed via the
-- result text / CreatureObtained popup, not by which slice lights up).
-- When a key matches MORE than one segment, one of the matches is picked at
-- RANDOM each time — otherwise the spin would always visually land on the
-- same one of several identical wedges, which would look broken/rigged even
-- though it has zero effect on the actual prize granted (that's already
-- decided by rollPrize before this ever runs). Falls back to segment 1 for
-- anything unrecognized (should never happen with the shipped tables, but a
-- spin animation landing SOMEWHERE beats erroring out over a cosmetic
-- mismatch).
local function segmentIndexForPrize(prize)
	local key = prize.Type
	local matches = segmentIndexByKey[key]
	if not matches or #matches == 0 then
		return 1
	end
	return matches[math.random(1, #matches)]
end

-- Picks one entry from GameConfig.WheelOfFortune.Prizes, weighted by each
-- entry's Weight (a plain relative weight — the shipped table happens to
-- sum to 100 for readability, but doesn't have to).
--
-- mysteryWeightMultiplier (optional, defaults to 1) is the "x2 Glück" hook —
-- ONLY the "BrainrotMystery" row's own Weight is multiplied, every other
-- Prize's Weight is used as-is. Applied by scaling a LOCAL COPY of that one
-- Weight for this roll only — GameConfig.WheelOfFortune.Prizes itself is
-- never mutated, so a buffed roll can never leak into a later unbuffed one
-- (or vice versa) even under concurrent spins from different players.
local function rollPrize(mysteryWeightMultiplier)
	local multiplier = mysteryWeightMultiplier or 1
	local prizes = GameConfig.WheelOfFortune.Prizes
	local total = 0
	for _, prize in ipairs(prizes) do
		local weight = prize.Weight
		if prize.Type == "BrainrotMystery" then
			weight = weight * multiplier
		end
		total += weight
	end
	local roll = math.random() * total
	local cumulative = 0
	for _, prize in ipairs(prizes) do
		local weight = prize.Weight
		if prize.Type == "BrainrotMystery" then
			weight = weight * multiplier
		end
		cumulative += weight
		if roll <= cumulative then
			return prize
		end
	end
	return prizes[#prizes]
end

-- Same weighted-roll pattern as rollPrize, but over GameConfig.
-- WheelOfFortune.MysteryRarities — only called when the "BrainrotMystery"
-- Prize above is actually rolled. Returns the winning Rarity string (e.g.
-- "Diamond"), or nil if MysteryRarities is somehow empty (guards against a
-- future GameConfig edit, same defensive style as pickRandomCreatureOfRarity
-- below).
local function rollMysteryRarity()
	local entries = GameConfig.WheelOfFortune.MysteryRarities
	if not entries or #entries == 0 then
		return nil
	end
	local total = 0
	for _, entry in ipairs(entries) do
		total += entry.Weight
	end
	local roll = math.random() * total
	local cumulative = 0
	for _, entry in ipairs(entries) do
		cumulative += entry.Weight
		if roll <= cumulative then
			return entry.Rarity
		end
	end
	return entries[#entries].Rarity
end

-- Picks a random named creature (GameConfig.Creatures) matching the given
-- Rarity — same pool a "Creature" prize draws from. Returns nil if no
-- creature of that rarity is configured (shouldn't happen with the shipped
-- roster, but guards against a future GameConfig edit removing the last one
-- of a rarity used in Prizes).
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

-- Formats a Cash amount the way the pedestal/leaderboard displays already
-- do (BaseService.formatCashRate / LeaderboardService.formatCashShort) — a
-- local copy, not shared, same "keep each module independent" convention
-- those two already follow. On request: the raw bonus Cash number in this
-- panel's own result message ("🎉 Glücksrad: +107717538200 Cash!") was one
-- long unreadable digit string at high Rebirth — this abbreviates it to
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

-- Turns a rolled prize into the actual grant, and returns a short German
-- confirmation string (or nil to show no extra message — used when
-- CreatureService already sent its own Notice, e.g. a full base). Kept
-- separate from rollPrize/performSpin so each prize Type's handling is easy
-- to find and extend on its own.
local function applyPrize(player, prize)
	if prize.Type == "Cash" then
		local bonus = EconomyService.GrantCashBonusSeconds(player, prize.CashBonusSeconds)
		return "🎉 Glücksrad: +" .. formatCashShort(bonus) .. " Cash!"
	elseif prize.Type == "DoubleCash" then
		EconomyService.GrantTemporaryCashMultiplier(player, prize.DurationSeconds)
		local minutes = math.floor(prize.DurationSeconds / 60)
		return "🎉 Glücksrad: 2x Cash für " .. tostring(minutes) .. " Minuten!"
	elseif prize.Type == "BrainrotMystery" then
		-- The mystery slice itself carries no Rarity — that's decided HERE,
		-- by a second independent weighted roll over MysteryRarities, only
		-- once this slice has actually been hit.
		local rarity = rollMysteryRarity()
		local def = rarity and pickRandomCreatureOfRarity(rarity)
		if not def then
			-- Mis-configured table (MysteryRarities empty, or a Rarity in
			-- it with no matching GameConfig.Creatures entry) — fall back
			-- to a modest Cash prize instead of silently granting nothing.
			local bonus = EconomyService.GrantCashBonusSeconds(player, 30)
			return "🎉 Glücksrad: +" .. formatCashShort(bonus) .. " Cash!"
		end
		local granted = CreatureService.ClaimPhysicalCreature(player, def)
		if not granted then
			-- Base full — ClaimPhysicalCreature already sent its own Notice
			-- explaining that. Don't overwrite it with a second, confusing
			-- message. The spin/cooldown was already consumed by the time
			-- this runs (see SpinWheel) — intentional: an already-full base
			-- shouldn't let someone spam-spin hoping for a non-creature
			-- prize instead. The wheel STILL visually lands on the
			-- Brainrot-Geheimnis segment either way — only the extra
			-- confirmation text is skipped.
			return nil
		end
		return "🎉 Glücksrad: " .. def.Name .. " (" .. rarity .. ") gewonnen!"
	end
	return nil
end

-- Shared tail end of BOTH SpinWheel (free) and SpinWheelPaid (Robux) —
-- rolls one prize, grants it, sends the redundant Notice, and returns
-- {SegmentIndex, Message} for whichever caller drives the panel's spin
-- animation. Neither caller's own cooldown/payment bookkeeping lives here,
-- on purpose: this function doesn't know or care HOW the spin was earned.
--
-- mysteryWeightMultiplier (optional) is passed straight through to
-- rollPrize — SpinWheel (free) always calls this with nil (no buff),
-- SpinWheelPaid passes GameConfig.WheelOfFortune.LuckBuff.
-- MysteryWeightMultiplier for every one of its spinCount spins.
local function performSpin(player, mysteryWeightMultiplier)
	local prize = rollPrize(mysteryWeightMultiplier)
	local message = applyPrize(player, prize)
	if message and remotesFolder then
		remotesFolder.Notice:FireClient(player, message)
	end
	return {
		SegmentIndex = segmentIndexForPrize(prize),
		Message = message,
	}
end

-- Read-only snapshot of this player's wheel state, for when the panel
-- opens (see the GetWheelState RemoteFunction in init.server.lua) — never
-- mutates anything. RobuxProducts (the full {ProductId, SpinCount} array)
-- and LuckBuff are handed back here too so the panel's two buy buttons
-- (and init.client.lua's PromptProductPurchase calls) don't need their own
-- separate GameConfig lookup — same reasoning as the old single
-- RobuxProductId, just for two products now instead of one.
function WheelService.GetState(player)
	local data = PlayerDataManager.Get(player)
	local cooldown = GameConfig.WheelOfFortune.CooldownSeconds
	local lastSpin = (data and data.LastWheelSpinAt) or 0
	local elapsed = os.time() - lastSpin
	local ready = elapsed >= cooldown
	return {
		Ready = ready,
		RemainingSeconds = ready and 0 or (cooldown - elapsed),
		RobuxProducts = GameConfig.WheelOfFortune.RobuxProducts,
		LuckBuff = GameConfig.WheelOfFortune.LuckBuff,
	}
end

-- Called from the SpinWheelFree RemoteFunction (see init.server.lua) — the
-- FREE, once-per-day path. Returns {Success=false, RemainingSeconds=n} if
-- still on cooldown or data isn't available, or {Success=true,
-- SegmentIndex=i, Message=text} on a successful spin.
function WheelService.SpinWheel(player)
	local data = PlayerDataManager.Get(player)
	if not data then
		return { Success = false, RemainingSeconds = GameConfig.WheelOfFortune.CooldownSeconds }
	end

	local cooldown = GameConfig.WheelOfFortune.CooldownSeconds
	local lastSpin = data.LastWheelSpinAt or 0
	local elapsed = os.time() - lastSpin
	if elapsed < cooldown then
		return { Success = false, RemainingSeconds = cooldown - elapsed }
	end

	-- Consumed BEFORE the prize is applied, on purpose — see applyPrize's
	-- "Creature, base full" comment above for why a failed grant should
	-- still cost the spin.
	data.LastWheelSpinAt = os.time()

	local result = performSpin(player)
	return { Success = true, SegmentIndex = result.SegmentIndex, Message = result.Message }
end

-- Called from MonetizationService.ProcessReceipt once Roblox has confirmed
-- a real purchase of one of GameConfig.WheelOfFortune.RobuxProducts — the
-- ROBUX, always-available path. spinCount is that product's own SpinCount
-- (1 for "Kaufe 1", 3 for "Kaufe 3") — defaults to 1 if missing/invalid so
-- a mis-configured caller still grants SOMETHING rather than nothing.
-- Deliberately does NOT touch data.LastWheelSpinAt in either direction
-- (see this file's top comment) and never checks the free cooldown — the
-- player already paid real money for these spins, so they always go
-- through. EVERY one of the spinCount spins gets GameConfig.WheelOfFortune.
-- LuckBuff.MysteryWeightMultiplier applied ("x2 Glück", on request — a paid
-- spin is always luckier on the Brainrot-Geheimnis slice than the free
-- one). Reports ALL results at once, asynchronously, via the
-- WheelSpinResult remote (as an array, even for spinCount == 1, so the
-- client only has to handle one shape) — ProcessReceipt has no direct line
-- back to whichever button click originally opened the purchase prompt,
-- and UIBuilder.PlayWheelSpinSequence animates through the whole array,
-- one spin after another.
function WheelService.SpinWheelPaid(player, spinCount)
	local data = PlayerDataManager.Get(player)
	if not data then
		return
	end
	spinCount = (type(spinCount) == "number" and spinCount >= 1) and math.floor(spinCount) or 1
	local mysteryWeightMultiplier = GameConfig.WheelOfFortune.LuckBuff
		and GameConfig.WheelOfFortune.LuckBuff.MysteryWeightMultiplier

	local results = {}
	for i = 1, spinCount do
		local result = performSpin(player, mysteryWeightMultiplier)
		table.insert(results, {
			SegmentIndex = result.SegmentIndex,
			Message = result.Message,
		})
	end

	if remotesFolder then
		remotesFolder.WheelSpinResult:FireClient(player, results)
	end
end

return WheelService
