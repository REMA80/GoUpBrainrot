--[[
	GameConfig.lua
	Single source of truth for all balance numbers and content lists.
	Tune everything here — floor difficulty, upgrade costs, creature odds,
	rebirth requirement, gamepass IDs — without touching any other script.
]]

local GameConfig = {}

-- === TOWER ===================================================================
GameConfig.Floors = {
	-- Was 60 — extended on request ("erweitere die Floors auf 100"). Every
	-- system that reads this (rarity-by-height weighting in
	-- CreatureService, the top-floor-only event creature roll, the funnel
	-- narrowing, the FloorLabel's "X / Count" display) already reads
	-- Floors.Count dynamically, so raising it alone is enough to stretch
	-- all of those over the new, longer climb — nothing else needed
	-- touching for that part. The vertical Gap/JumpPower band mapping
	-- (JumpTiers, in getGapForFloor/getHorizontalOffsetForFloor below) is
	-- DELIBERATELY no longer computed from this number — see the "Fixed at
	-- 6" comment in TowerGenerator.lua for why: so extending this doesn't
	-- retroactively re-tune the difficulty of the already-tuned Floors
	-- 1-60.
	Count = 100,
	Size = Vector3.new(18, 2, 18),
	-- Was 5 — with an 18-stud-wide platform, that left consecutive floors
	-- overlapping by 13 studs (18 - 5), meaning the floor above hung almost
	-- directly over the one below. A high-arc jump (strong Jump Tier) would
	-- reach its peak height while still under that overlap and smack the
	-- underside of the floor above instead of clearing it. 12 studs cuts the
	-- overlap down to 6 (and to nothing at all in higher zones, where the
	-- zone multiplier below scales it further), so floors read as clearly
	-- offset to the side instead of stacked almost straight on top of each
	-- other.
	-- Was 12, then 14 — raised again on request ("die Floor 1-60 noch
	-- weiter auseinander im Kreis aufgefächert"). Still safe to raise
	-- (unlike EarlyHorizontalOffset right below, which needs its own
	-- justification): this only ever makes the floor-to-floor gap WIDER
	-- than the already-comfortable minimum documented below, never
	-- tighter, so it can't reintroduce the overlap problem that first set
	-- this value. Since this is also literally the tower's per-floor
	-- radius from the central axis (see TowerGenerator's floor-placement
	-- loop: radius = HorizontalOffset * funnelFactor), raising it is
	-- exactly what spreads the spiral out into a wider "fan" when viewed
	-- from above or outside, not just a bigger side-to-side jump.
	HorizontalOffset = 17,
	-- Floors 1-6 (the same band JumpTiers[1] covers, see TowerGenerator's
	-- getHorizontalOffsetForFloor) use THIS smaller offset instead of the
	-- normal HorizontalOffset. Floors alternate left/right of center, so the
	-- actual sideways jump distance between two consecutive floors is
	-- roughly 2x the offset.
	-- Was 9, held there because at a WalkSpeed of 16 (the Roblox default,
	-- which is all this project had until WalkSpeed was set explicitly —
	-- see GameConfig.Movement below) even 9 (~18-stud jump) was judged the
	-- tightest safe minimum for a brand new Tier 1 character (JumpPower 50,
	-- the lowest in the game). WalkSpeed is now 22 (+37.5%), which directly
	-- increases how far a running jump carries horizontally, so there's
	-- real margin to raise this too. Raised to 11 (~22-stud jump) — a
	-- moderate step, not the full jump to HorizontalOffset's new 17, since
	-- this is still the single tightest jump in the whole game and the one
	-- that would be most punishing to get wrong for a fresh player.
	--
	-- Raised again, 11 -> 15 (on request: "beim Springen mit dem Kopf gegen
	-- die Platten" on Floor 1-5) — this is the exact same overlap problem
	-- HorizontalOffset's own history above already describes for the general
	-- case ("a high-arc jump would reach its peak height while still under
	-- that overlap and smack the underside of the floor above"): with only
	-- an 11-stud radius, the next floor in the spiral sits close enough that
	-- an ascending jump's head can still clip its underside before clearing
	-- it sideways. 15 stays a clear step below HorizontalOffset's 17 (Floor
	-- 1-6 is still the easiest/tightest band in the game on purpose), but
	-- gives real extra side-to-side room during the climb. Safe to raise
	-- further if head-bumping is still reported — unlike Gap/JumpPower pairs
	-- elsewhere in this file, widening this can only ever help clearance,
	-- never make a jump unreachable on its own (see HorizontalOffset's own
	-- comment on the same point) — please playtest Floor 1-6 again.
	EarlyHorizontalOffset = 15,

	-- SPIRAL/FUNNEL LAYOUT: floors no longer just alternate left/right along
	-- one line — each one sits on a circle around the tower's central
	-- vertical axis, rotated SpiralAngleStep degrees from the previous one.
	-- 150 (not a clean divisor of 360) means the jump direction keeps
	-- changing floor to floor instead of repeating the same back-and-forth
	-- pattern — more visual and physical variety on the climb. See
	-- TowerGenerator's floor-placement loop.
	SpiralAngleStep = 150,

	-- The tower's radius (how far each floor sits from the center) shrinks
	-- from 1.0x at Floor 1 down to THIS fraction at the very top floor,
	-- interpolated in between (see TowerGenerator.getFunnelFactor) — that's
	-- what gives the whole tower a narrowing funnel/spire silhouette from
	-- outside, instead of staying the same width all the way up. Doesn't
	-- need to compensate for difficulty on its own — JumpTiers' Gap already
	-- ramps up the VERTICAL difficulty plenty as you climb.
	FunnelTopRadiusFactor = 0.55,

	ZoneSize = 10,            -- floors per visual "zone" (color/theme changes)

	-- "ab Floor 50 sollen die Floors weiter verstreut liegen, man muss
	-- nicht nur hoch sondern auch weiter springen" — Gap (vertical
	-- difficulty) already plateaus once floors run past JumpTiers' last
	-- band (Tier 10 covers Floor 55+, see getGapForFloor), so without this
	-- the new Floors 61-100 wouldn't get any harder, just longer. This adds
	-- a SEPARATE horizontal-only ramp on top of the normal HorizontalOffset,
	-- starting at LateSpreadStartFloor and growing linearly up to
	-- LateSpreadMaxExtraOffset extra studs by the very last floor (see
	-- getHorizontalOffsetForFloor in TowerGenerator.lua) — so the last
	-- stretch of the climb demands genuinely WIDER jumps, not just a
	-- repeat of the same jump with more floors in between.
	LateSpreadStartFloor = 50,
	-- History: 14, then 20 (Floor 100 "relativ leicht" at max Jump Upgrade),
	-- then 27 (159/180 points could still reach Floor 100 — see
	-- LateHeightBoostMaxExtraGap below for that whole story). 27 turned out
	-- to overshoot the OTHER way — confirmed by playtesting that even a
	-- FULLY maxed 180-point character could no longer reach Floor 100 at
	-- all. Likely cause: raising height AND horizontal distance at the same
	-- time compounds harder than either alone — more required height means
	-- less time left in the air (closer to the jump's apex) to also cover
	-- more sideways distance within that same shrinking window, so the two
	-- increases didn't just add, they multiplied into "impossible even at
	-- max". Backed off to 23 — roughly halfway between the too-easy 20 and
	-- the too-hard 27 — together with backing LateHeightBoostMaxExtraGap
	-- off the same way, on the theory that the real sweet spot sits
	-- somewhere in that gap neither end actually tested.
	-- I can't run Roblox's jump physics here to confirm reachability, so
	-- please playtest AGAIN with both ends: a ~159-point character (should
	-- FAIL Floor 100) and a maxed 180-point character (should SUCCEED,
	-- ideally without being trivial). Whichever end is still wrong, tell me
	-- which one and I'll nudge these two further in that direction instead
	-- of guessing blind again.
	LateSpreadMaxExtraOffset = 23,

	-- "man kommt immer noch sehr leicht nach oben ... als Lösung die Floor
	-- ab 90 höher bauen" — the horizontal spread above alone wasn't enough,
	-- because Gap (vertical difficulty) plateaus at Tier 10's value (102)
	-- from Floor 55 onward and never gets any taller. This is the actual
	-- fix requested: from LateHeightBoostStartFloor onward, Gap climbs on
	-- top of the normal 102, linearly, up to +LateHeightBoostMaxExtraGap
	-- extra studs by the very last floor (see getGapForFloor in
	-- TowerGenerator.lua) — same ramp shape as LateSpread above, just for
	-- height instead of width, and starting later (90, not 50) since this
	-- is meant to be the FINAL, hardest stretch.
	--
	-- This one is actually CALIBRATED (as much as it can be from here), not
	-- just a round number: Roblox sets JumpPower directly as the
	-- character's initial upward velocity (studs/sec) when UseJumpPower is
	-- true (which EconomyService.ApplyJumpPower sets), and Workspace's
	-- default gravity is 196.2 studs/s². That gives a real formula for
	-- Tier 10's (JumpPower 370) absolute maximum jump height: v²/(2·g) =
	-- 370² / (2·196.2) ≈ 349 studs — literally cannot jump higher than
	-- that, no matter how good the timing.
	--
	-- History: was 218 (total gap 320, ~92% of the 349 ceiling above) —
	-- raised to 300 (total gap 402) on request ("mit Jump Upgrade 159
	-- komme ich schon bis Floor 100, das sollte erst mit 175-180 gehen"),
	-- since 218 let a 159-point character (JumpPower ≈307.5, idealized max
	-- height only ~241 studs) clear it anyway — real Roblox jump physics
	-- clearly carries farther than this idealized formula predicts.
	--
	-- 300 overshot in the OTHER direction — confirmed by playtesting that
	-- even a FULLY maxed 180-point character (JumpPower 370, the highest
	-- possible) could no longer reach Floor 100 at all. Combined with
	-- LateSpreadMaxExtraOffset being raised at the same time (see that
	-- field's own comment), the likely cause is the two increases
	-- compounding rather than just adding: needing more height AND more
	-- horizontal distance in the SAME jump is harder than needing either
	-- alone, since more height means spending more of the jump's airtime
	-- near its apex (where you're barely still moving upward), leaving less
	-- time to also cover the extra sideways distance before landing.
	--
	-- Backed off to 260 — roughly halfway between the too-easy 218 and the
	-- too-hard 300 — on the theory that the real threshold sits somewhere
	-- in that untested middle ground, together with backing
	-- LateSpreadMaxExtraOffset off the same way.
	--
	-- I cannot run Roblox's actual physics engine from here, so this is
	-- still an estimate — PLEASE playtest again with BOTH ends: a
	-- ~159-point character (should FAIL Floor 100) and a maxed 180-point
	-- character (should SUCCEED, ideally without it being a total gimme).
	-- Tell me which end (if either) is still wrong rather than just "still
	-- broken" — that's what let this overshoot past the sweet spot last
	-- time instead of landing in it.
	LateHeightBoostStartFloor = 90,
	LateHeightBoostMaxExtraGap = 260,
}

-- === MOVEMENT =================================================================
-- Roblox's engine default WalkSpeed is 16 — nothing in this codebase ever set
-- it explicitly before, so every character was climbing at that default.
-- Requested faster ("kann man die Figur schneller machen?"). 22 is a
-- moderate ~40% bump: noticeably snappier for crossing the wider floor gaps
-- above without being so fast that the horizontal jump distances (tuned
-- around the default-feeling speed) start overshooting platforms. Tune this
-- single number if it should be faster or slower — see init.server.lua's
-- CharacterAdded handler for where it's applied.
GameConfig.Movement = {
	WalkSpeed = 22,
}

-- === OBSTACLES / ROUTE VARIETY ================================================
-- Each floor-to-floor connection is one of two types, chosen by cycling
-- through Pattern (edit the list/order freely — that's the whole "level
-- design" knob). Both types still use the same JumpTiers-based Gap and
-- left/right/zigzag placement as before, so difficulty pacing is untouched:
--   "Jump"    - the normal climb (as it's always been).
--   "Bridge"  - the vertical gap shrinks a lot (BridgeHeightStep instead of
--               the tier Gap), but you cross a wide horizontal reach via a
--               few small stepping-stones instead of climbing.
-- Independently of type, some floors also get a swinging hazard bar that
-- sends you back to your last checkpoint on touch (TrapChance).
-- "JumpPad" (a launch pad that flung you across automatically) and "Ladder"
-- (a climbable TrussPart, no jump power needed) were removed on request —
-- every floor that used to land on one of those pattern slots now just gets
-- a normal "Jump" crossing instead. TowerGenerator.lua's buildJumpPad/
-- buildLadder functions and the obstacleType branches that called them were
-- deleted along with them, since Pattern can never produce those values
-- again.
GameConfig.Obstacles = {
	Pattern = { "Jump", "Jump", "Jump", "Jump", "Jump", "Jump", "Bridge", "Jump", "Jump", "Jump" },

	-- NOTE: the old flat left-right SwayAmplitude (side-to-side Z wander) was
	-- removed — the spiral/funnel layout (GameConfig.Floors.SpiralAngleStep /
	-- FunnelTopRadiusFactor) now provides that variety on its own, in both
	-- X and Z at once, so a separate sway value isn't needed anymore.

	-- UNUSED as of the JumpPad-removal above — kept in case JumpPad-style
	-- launch crossings come back later; nothing reads these anymore.
	PadLaunchVertical = 90,    -- studs/sec upward velocity a JumpPad gave
	PadLaunchHorizontal = 40,  -- studs/sec horizontal velocity toward the next floor

	BridgeHeightStep = 4,      -- how much a Bridge floor rises (vs. a normal tier Gap)
	BridgeHorizontalReach = 46,-- how far out a Bridge floor sits
	BridgeSegments = 4,        -- number of stepping-stones spanning a Bridge gap

	TrapChance = 0.2,          -- probability per floor (2+) of a swinging hazard bar
	TrapSwayDistance = 8,      -- studs the hazard swings side to side
	TrapSwaySpeed = 1.4,       -- how fast it swings

	-- MOVING FLOORS: some plain "Jump"-type floors (never Floor 1, a
	-- checkpoint, or a creature-pickup floor — see TowerGenerator.
	-- maybeMakeFloorMoving) slide back and forth instead of sitting still,
	-- so you have to time your jump instead of just walking up and hopping.
	MovingFloorChance = 0.18,  -- probability a qualifying floor becomes one
	MovingFloorDistance = 8,   -- studs it travels each direction from center
	MovingFloorSpeed = 0.6,    -- oscillation speed (higher = faster swing)

	-- CRUMBLING FLOORS: start shaking the moment you step on them and vanish
	-- ~1s later (just long enough to jump onward), then reappear a few
	-- seconds later so the SHARED tower stays climbable for the other 3
	-- players too — nobody can permanently strand anyone else this way.
	CrumbleChance = 0.16,          -- probability a qualifying floor is one
	CrumbleWarningSeconds = 1,     -- time between first touch and vanishing
	CrumbleHiddenSeconds = 4,      -- time it stays gone before reappearing

	-- ZONE EFFECTS: cycles through this list by visual zone (ZoneSize floors
	-- each, see getZoneColor/applyZoneFloorEffect) — "Ice" = low-friction,
	-- hard to stop/steer precisely; "Normal" = unchanged. Starts on "Normal"
	-- so Floor 1's zone is never a surprise.
	-- "Bouncy" (an automatic upward boost the moment you land) was removed on
	-- request ("der Spieler hüpft manchmal unkontrolliert") — it fired via
	-- AssemblyLinearVelocity on Touched, which felt like an uncontrollable
	-- random launch to players since it only hit some floors, not all of
	-- them. TowerGenerator.lua's applyZoneFloorEffect no longer has a
	-- "Bouncy" branch at all, so this list can never reference it again.
	ZoneEffects = { "Normal", "Ice", "Normal", "Normal", "Normal" },
	-- UNUSED as of the Bouncy-removal above — kept in case a tuned-down
	-- version of the effect comes back later; nothing reads this anymore.
	BouncePower = 75,          -- studs/sec upward velocity a Bouncy floor gave on landing
}

-- === JUMP UPGRADES ===========================================================
-- "Gap" = the vertical distance (in studs) between floors while this tier is
-- the one you're expected to have. This is a DIRECT, hand-tuned number, not a
-- physics formula — the theoretical JumpPower^2/(2*gravity) formula undershot
-- what actually felt reachable in real testing (a running jump reaches
-- further than a standing-jump apex calc suggests). 14 studs at base tier
-- was almost right; 12 gave a bit more margin. Just edit these numbers
-- directly and re-test — that's the whole tuning loop now.
-- Costs are 10x their original values (was 100-110,000) — a straight,
-- deliberate scale-up so the numbers "look like more" alongside the bigger
-- CashBoost values below, while keeping the exact same cost RATIO between
-- tiers (so the pacing/feel of "how many upgrades before the next one" is
-- unchanged — only the digit count grew).
-- Tier 1's Gap was shortened 12 -> 10 -> 8 (floors 1-6 all use this tier,
-- since TowerGenerator bands 60 floors across 10 tiers = 6 floors/tier) —
-- combined with Floors.EarlyHorizontalOffset above (which shortens the
-- SIDEWAYS jump specifically for these same 6 floors), the very first
-- climbs (brand new players, and console players specifically, where
-- precise jump-and-strafe timing is harder than on PC) are now noticeably
-- more forgiving in both directions, not just vertically.
-- BUT that Tier 1 easing left Tier 2's Gap (16) untouched — going from an
-- 8-stud Gap to a 16-stud one is a full DOUBLING in one single upgrade,
-- while every tier after that only steps up ~20-30% (16->20->26->34->...).
-- That's exactly why Tier 2 felt "almost useless" ("man kommt damit nur 2
-- Plattformen weiter") — most of the actual "Jump"-type floor-to-floor
-- crossings in Tier 2's band (some floors in that band are Bridge instead,
-- see GameConfig.Obstacles.Pattern, which doesn't need real jump power at
-- all — this was also true of the since-removed JumpPad/Ladder types when
-- this note was written) needed a jump Tier 2's JumpPower genuinely couldn't
-- clear. FIRST attempt just lowered Gap 16 -> 13 and left JumpPower at 65 —
-- turned out that still wasn't enough ("ich komme mit Jump Upgrade 1-2
-- nicht über Floor 9") — Gap 13 still asked for proportionally MORE jump
-- than Tier 1 gets away with relative to ITS JumpPower (13/65 = a harder
-- ratio than Tier 1's own working 8/50), so a Gap-only nudge could never
-- fully fix it without also raising JumpPower. SECOND pass (this one) moves
-- BOTH levers at once instead of inching one at a time: Gap 13 -> 11 AND
-- JumpPower 65 -> 78 — a noticeably bigger combined jump this time on
-- purpose, since undershooting twice costs more of your test group's time
-- than briefly making Tier 2 feel a little too easy. Also worth knowing:
-- floors 7+ (Tier 2's band) switch from Floors.EarlyHorizontalOffset (9) to
-- the normal, LARGER Floors.HorizontalOffset (12) at the exact same
-- boundary — so the sideways jump got harder at the same spot as the
-- vertical one; if Tier 2 still feels rough after this, EarlyHorizontalOffset
-- could be extended to cover Tier 2's band too, or HorizontalOffset itself
-- lowered a bit. Tiers 3+ still untouched since nothing was reported wrong
-- with those yet — but they follow the exact same Gap-grew-faster-than-
-- JumpPower pattern (worst at Tier 3: 20/85), so the same fix likely applies
-- there once someone reaches that far. Same "hand-tuned, re-test and adjust"
-- caveat as always.
-- Costs below are the ORIGINAL table x15 flat — rescaled on request after the
-- Cash/sec economy below (GameConfig.CreatureRarities) was rebalanced to much
-- higher per-creature rates (see that table's comment for the full reasoning).
-- x15 is a first-pass estimate, not a precisely derived number — the new
-- MinRate/MaxRate ranges aren't a flat multiplier of the old CashBoost values
-- (they're the requester's own hand-picked numbers), so there's no single
-- "correct" multiplier here. Please have your test group verify the pacing
-- (time-to-afford each tier) still feels right and report back if any tier
-- needs individual tuning.
-- IMPORTANT — as of this change, these 10 entries are no longer what a
-- player directly buys one at a time. They're now just the ANCHOR CURVE:
-- TowerGenerator.lua still uses them exactly as before to band the 60
-- floors' Gap difficulty (untouched, still 10 tiers -> 6 floors/tier), and
-- EconomyService now interpolates a player's actual JumpPower smoothly
-- BETWEEN these 10 checkpoints via GameConfig.JumpUpgrade below, instead of
-- jumping straight from one row to the next in one lump purchase. Every
-- number here is still exactly the hand-tuned pacing this session settled
-- on (see the long comment block above this table before the rewrite) —
-- Level 1 = point 0, Level 2 = point JumpUpgrade.PointsPerTier, etc. — so
-- all of that tuning work carries over unchanged, just spread into many
-- smaller purchasable steps instead of one big one per row.
-- Gap values below are ~15% above their original hand-tuned numbers (on
-- request: "die Floors sollen etwas weiter auseinander sein und der
-- Höhenunterschied etwas mehr"). JumpPower was deliberately left untouched —
-- Gap and JumpPower are physics-paired (JumpPower is what actually has to
-- carry a character across a floor's Gap), and this table already has a
-- documented history of Gap growing faster than JumpPower causing floors
-- that were too far to reach (see the comment above this table and
-- Floors.EarlyHorizontalOffset's — Tier 3's 20/85 ratio was flagged there as
-- already the worst case in the table, "nothing reported wrong ... yet").
-- Raising Gap again, even by just 15%, tightens that same margin further,
-- worst at Tier 3. Please re-test climbing through at least Tiers 1-3 in
-- Studio — if any floor now feels unreachable, tell me which tier and I can
-- either dial that tier's Gap back down or bump its JumpPower to compensate
-- (both are one-line changes here).
GameConfig.JumpTiers = {
	{ Level = 1,  Cost = 0,        JumpPower = 50,  Name = "Wobbly Legs",       Gap = 9 },
	{ Level = 2,  Cost = 15000,    JumpPower = 78,  Name = "Springy Sneakers",  Gap = 13 },
	{ Level = 3,  Cost = 52500,    JumpPower = 85,  Name = "Bouncy Boots",      Gap = 23 },
	{ Level = 4,  Cost = 135000,   JumpPower = 110, Name = "Turbo Trainers",    Gap = 30 },
	{ Level = 5,  Cost = 330000,   JumpPower = 140, Name = "Rocket Heels",      Gap = 39 },
	{ Level = 6,  Cost = 750000,   JumpPower = 175, Name = "Jetpack Legs",      Gap = 48 },
	{ Level = 7,  Cost = 1650000,  JumpPower = 215, Name = "Antigrav Boots",    Gap = 60 },
	{ Level = 8,  Cost = 3600000,  JumpPower = 260, Name = "Moon Walkers",      Gap = 71 },
	{ Level = 9,  Cost = 7800000,  JumpPower = 310, Name = "Brainrot Wings",     Gap = 85 },
	{ Level = 10, Cost = 16500000, JumpPower = 370, Name = "Ultra Sigma Boots", Gap = 102 },
}

-- Drives the new incremental "buy N Sprung-points at once" purchase flow
-- (requested to feel like a simulator-style bulk-upgrade shop instead of 10
-- big all-or-nothing purchases) — see EconomyService's getJumpStatsAtPoint /
-- getSinglePointCost / BuyJumpUpgrade for the actual math.
--
-- PointsPerTier subdivides EACH of the 9 gaps between the 10 JumpTiers
-- anchors above into this many purchasable points, so the total range is
-- (10-1) * PointsPerTier points, point 0 = JumpTiers[1] exactly, point
-- (9*PointsPerTier) = JumpTiers[10] exactly, and every checkpoint in
-- between (JumpTiers[2]..[9]) lands on an exact multiple of PointsPerTier
-- too — the hand-tuned Gap/JumpPower pairs at each of those checkpoints are
-- reproduced EXACTLY, never overshot or undershot by the interpolation.
--
-- CostCurveRatio makes each point within one tier-segment cost this many
-- times the previous point (a geometric ramp, not flat/linear) — chosen so
-- that buying an ENTIRE segment's worth of points (PointsPerTier of them)
-- costs exactly that segment's JumpTiers[...].Cost times CostMultiplier
-- below, but buying in bulk (e.g. +25 at once) costs noticeably more per
-- point than a single +1 right next to it, same escalating-bulk-price feel
-- as the reference design.
--
-- BulkAmounts are the purchase-quantity buttons shown on the Sprung-Upgrade
-- panel (see UIBuilder.lua's Jump Upgrade panel / PopulateJumpUpgrade).
GameConfig.JumpUpgrade = {
	PointsPerTier = 20,
	CostCurveRatio = 1.15,

	-- Flat multiplier on EVERY JumpTiers[...].Cost below (applied in
	-- EconomyService's getSinglePointCost) — on request: the full grind used
	-- to cost a flat 30.832.500 Cash total no matter what, which made it
	-- trivial once a player's income had grown from Rebirths/better
	-- Brainrots (e.g. ~19 seconds at Rebirth 15 with Galaxy-tier Brainrots on
	-- every pedestal, vs. the original ~7.9 DAYS at Rebirth 0 with only
	-- Normal ones — a >30.000x swing). Since Floor 100's Mega-Truhe (see
	-- GameConfig.Summit) is only reachable with maxed-out JumpPower, that
	-- made the "buy it all back after every Rebirth" grind feel like a real
	-- decision early on but pure background noise by the late game.
	--
	-- Deliberately a SINGLE flat multiplier, not one that grows per Rebirth
	-- stage (a tiered table was considered and rejected on request) — the
	-- point is that a HIGHER Rebirth still buys you real, meaningful speed
	-- (more pedestal slots + the stacking cash multiplier, see
	-- GameConfig.Rebirth), it's just that the finish line moved further out
	-- too, so Rebirthing (and finding better Brainrots) stays the thing that
	-- actually gets you there faster, at every stage, instead of the late
	-- game outrunning the grind entirely.
	--
	-- 10x is a first-pass number, not a precisely derived one — please
	-- playtest and tell me if any stage (very early especially, since this
	-- also raises the Rebirth-0 total to nearly 80 days' worth of Normal-only
	-- income) needs it dialed up or down.
	CostMultiplier = 10,

	BulkAmounts = { 1, 5, 10, 25 },

	-- PARALLEL to BulkAmounts (same order, same count) — one Robux
	-- Developer Product per bulk amount, letting a player skip the Cash
	-- cost entirely and pay Robux instead (see the panel's second button per
	-- row). ProductId = 0 is a PLACEHOLDER — Developer Products can only be
	-- created by a human in Studio, never from code:
	--   1. Studio -> Monetization tab -> Developer Products -> Create
	--   2. Name it (e.g. "25 Sprung-Punkte") and set your own Robux price —
	--      the suggestions below are just a starting point (Roblox keeps
	--      ~30%), adjust to taste
	--   3. Copy the new Product's ID into the matching ProductId below
	-- Until a real ID is filled in, that row's Robux button stays hidden
	-- client-side (see UIBuilder.Build) instead of prompting a purchase for
	-- a product that doesn't exist. The actual price shown on the button is
	-- fetched live from Roblox (MarketplaceService:GetProductInfo) once a
	-- real ID is set, NOT read from the suggestion comments below — so
	-- there's no risk of the button ever showing a stale/wrong price.
	RobuxProducts = {
		{ ProductId = 3711597752 }, -- +1 Sprung  — real Developer Product, 19 Robux (set live in Studio)
		{ ProductId = 3711597794 }, -- +5 Sprung  — real Developer Product, 49 Robux (set live in Studio)
		{ ProductId = 3711596714 }, -- +10 Sprung — real Developer Product, 99 Robux (set live in Studio)
		{ ProductId = 3711597877 }, -- +25 Sprung — real Developer Product, 199 Robux (set live in Studio)
	},
}

-- === REBIRTH ==================================================================
-- Rebirth is bought with CASH now, not unlocked by reaching a floor. Costs[N]
-- is the price of your Nth rebirth (Costs[1] = Rebirths 0->1, Costs[15] =
-- Rebirths 14->15, the last one — MaxRebirths caps it there, no more after).
-- Paying resets Cash/JumpTier/HighestFloor back to their starting values
-- (see EconomyService.Rebirth) — everything except your claimed Brainrots,
-- which are untouched by Rebirth either way.
-- (The +1 pedestal slot per rebirth lives in GameConfig.Base.SlotsPerRebirth,
-- unchanged by this — it still applies for every rebirth up to MaxRebirths.)
GameConfig.Rebirth = {
	MaxRebirths = 15,
	MultiplierPerRebirth = 0.5,  -- +50% passive cash per rebirth, stacks additively

	-- Costs below are the ORIGINAL table, rescaled tier-group by tier-group
	-- (x25 for Rebirths 1-4, x80 for 5-8, x200 for 9-12, x400 for 13-15) —
	-- same "first pass, please verify pacing" caveat as GameConfig.JumpTiers
	-- above. Steeper multipliers at the higher groups on purpose: by the time
	-- a player is chasing Rebirth 9+ they're expected to already own several
	-- Hacker/Lava-tier creatures (10,000-2,000,000 Cash/sec each, see
	-- CreatureRarities below), whose income grew far more than the early
	-- Normal/Gold tiers did — a flat multiplier across all 15 would have made
	-- the late Rebirths trivially cheap relative to how much richer the
	-- late-game economy actually got.
	Costs = {
		125000,        250000,        -- 1, 2
		1000000,       2500000,       -- 3, 4
		20000000,      48000000,      -- 5, 6
		112000000,     256000000,     -- 7, 8
		1400000000,    3000000000,    -- 9, 10
		6400000000,    13600000000,   -- 11, 12
		56000000000,   116000000000,  -- 13, 14
		240000000000,                 -- 15
	},

	-- "1x Wiedergeburt" Robux button — on request, REPLACES the old VIP
	-- kiosk in BaseService.buildStations. A Developer Product (not a
	-- Gamepass — same distinction as GameConfig.JumpUpgrade.RobuxProducts/
	-- WheelOfFortune.RobuxProduct above), since it grants exactly ONE
	-- Rebirth per purchase and can be bought again for another later,
	-- rather than being owned forever. See EconomyService.
	-- BuyRebirthWithRobux for what a purchase actually does (same Rebirth
	-- effects as the normal in-game Rebirth altar, just skipping the Cash
	-- cost — still blocked once MaxRebirths above is reached, same as the
	-- normal altar). Real Developer Product created in Studio's
	-- Monetization tab (199 Robux, set there — a script can never set a
	-- product's price). RobuxCost is ONLY the kiosk's displayed price
	-- (GameConfig.Base.buildStationPart's Auto-Sammeln/2x Cash kiosks show
	-- a similar static label) — keep it in sync with whatever price is
	-- actually set on the real product in Studio.
	RobuxProduct = { ProductId = 3711560356, RobuxCost = 199 },
}

-- === REBIRTH COSMETICS ==========================================================
-- Purely cosmetic prestige rewards — no gameplay effect. At the given
-- Rebirths count and above, a player's character gets a colored outline
-- glow plus a title above their head. The HIGHEST tier a player qualifies
-- for is the one shown. Visible to every player in the server, not just you.
GameConfig.RebirthCosmetics = {
	{ RequiredRebirths = 1,  Name = "Bronze Brainrot",          Color = Color3.fromRGB(205, 127, 50) },
	{ RequiredRebirths = 3,  Name = "Silver Brainrot",          Color = Color3.fromRGB(210, 210, 210) },
	{ RequiredRebirths = 5,  Name = "Gold Brainrot",            Color = Color3.fromRGB(255, 215, 0) },
	{ RequiredRebirths = 10, Name = "Diamond Brainrot",         Color = Color3.fromRGB(140, 220, 255) },
	-- Was RequiredRebirths = 20 — unreachable now that GameConfig.Rebirth.
	-- MaxRebirths caps at 15, so this is the new top tier at the actual cap.
	{ RequiredRebirths = 15, Name = "Mythic Brainrot Overlord", Color = Color3.fromRGB(255, 60, 60) },
}

-- === ECONOMY ===================================================================
GameConfig.Economy = {
	-- PayoutTickSeconds is how often Cash is ACTUALLY added to the player
	-- and the HUD refreshed. Each creature's Cash/sec rate (see
	-- CreatureRarities' MinRate/MaxRate below, and EconomyService.
	-- GetCreatureCashRates) is already a true per-second number, so paying
	-- rate * PayoutTickSeconds every PayoutTickSeconds nets the exact same
	-- total over time regardless of how often this actually ticks — it just
	-- controls how smoothly the Cash bar visibly grows.
	PayoutTickSeconds = 1,

	-- Selling a Brainrot (see CreatureService.SellCreature) pays out this
	-- many SECONDS worth of that creature's current Cash/sec rate as a lump
	-- sum — so it's always "worth" a chunk of real income, not a flat/made-up
	-- number, and automatically scales up with Rebirths just like the
	-- Cash/sec display does.
	SellValueSeconds = 60,
}

-- === CREATURES (collectibles) ================================================
-- Real "Italian Brainrot" meme character names now (on request) — this used
-- to be a deliberately-invented, meme-*inspired* roster to stay legally
-- safe (see git history); switched to the actual known character names to
-- match the 3D model pack you found in the Toolbox. Heads up: unlike the
-- made-up names, these ARE real, widely-recognized community characters —
-- fine for a personal/prototype project the way countless other Roblox
-- "Brainrot" games already use them, but worth knowing if you ever publish
-- this more broadly, since Roblox's own IP moderation policies could in
-- theory flag any of them. GetTotalCashBoost() only cares about Rarity.
--
-- 85 entries, one per model in your pack (see the pack's "Normal" folder —
-- Gold/Diamond/Toxic/Galaxy/Hacker/Lava look like alternate SKIN/
-- mutation folders for the same creatures, not additional unique ones, so
-- they're not wired in here — could be a fun later feature). Rarity here is
-- a first-pass guess based on how iconic/recognizable each character is
-- (the most famous ones are Lava/Hacker, the long absurd compound
-- names are mostly Normal/Gold filler) — purely a starting point, reshuffle
-- any entry's Rarity freely, nothing else depends on WHICH creature is in
-- which tier. The "1x1x1x1" item in your pack was skipped on purpose — that's
-- Roblox's own urban-legend hacker account, not a Brainrot character.
--
-- Every creature in a rarity shares that rarity's exact CashBoost/Color from
-- CreatureRarities below, and CreatureService.rollCreature splits each
-- rarity's odds EVENLY across however many creatures currently have it (see
-- the comment there) — so moving names between tiers or adding/removing
-- some never shifts the drop odds BETWEEN rarities, only which creature you
-- get within one.
--
-- EarlyWeight = odds on Floor 1. LateWeight = odds on the top floor. Odds are
-- linearly interpolated between the two based on how high up the pickup is,
-- so climbing higher doesn't just mean more Cash — it means better loot too.
--
-- MinRate/MaxRate below are direct Cash/sec RANGES per tier (replacing the
-- old single CashBoost number) — requested after playtesting found the
-- economy paid too little, and because a single flat number per rarity meant
-- every creature of the same rarity was worth EXACTLY the same, with no
-- reason to prefer one over another within a tier. EconomyService.
-- GetCreatureCashRates now picks a STABLE point inside [MinRate, MaxRate] per
-- creature (hashed from its name, see EconomyService.stableFraction) — the
-- same creature always earns the same rate (no randomness on respawn/rejoin),
-- but different creatures sharing a rarity now differ from each other, so
-- e.g. two different Normals aren't identical anymore. Rebirth/gamepass
-- multipliers still apply on top exactly as before.
-- Normal through Lava are the exact ranges requested. Glitchrot/Singularity
-- (event-exclusive, above Lava) were NOT specified, so I extrapolated them by
-- applying the SAME step-up ratio the old CashBoost table used between those
-- two tiers and Lava (Glitchrot was ~8.3x old Lava, Singularity ~8x old
-- Glitchrot) to the new Lava range instead — flagged here as my own estimate,
-- not a value you gave me, so tune it if it feels off.
--
-- "Hacker" and "Lava" are DOUBLY available: a tiny sliver of the
-- normal weighted pool (EarlyWeight 0, LateWeight barely above zero — see
-- CreatureRarities below — so in practice only even possible near the very
-- top floors, on any day) PLUS a much bigger boost during the weekly event
-- window (GameConfig.Event / CreatureService.rollEventCreature). "Glitchrot"
-- and "Singularity" stay pure event-exclusives — see the NormalPoolExcluded
-- flag on their entries further below — they can ONLY be won through the
-- event, never as a normal drop, no matter how high you climb. Those two
-- tiers are our own original invention (not part of the real meme), so
-- they keep their made-up names below, unchanged.
--
-- REAL 3D MODELS: no config field needed — BaseService automatically shows
-- a real model instead of the colored placeholder ball for any creature
-- whose EXACT name (e.g. "Tralalero Tralala") matches a Model you drop into
-- ReplicatedStorage.CreatureModels in Studio (that folder is auto-created
-- empty the first time the server runs — expand ReplicatedStorage in the
-- Explorer to find it). Drag each creature's model from your pack's
-- "Normal" folder in there, EDIT mode (not while Play-testing, or it won't
-- survive Stop) — no asset ID, no permission check, it just works because
-- the model is already part of the place. (We tried loading other
-- creators' Toolbox/Creator Store models by asset ID instead — kept
-- failing with "User is not authorized to access Asset", even for a "Save
-- to Roblox" own copy, so this folder-based approach replaced that
-- entirely.) No creature below has a matching model yet, so all pedestals
-- currently show the ball — add models to as many/few creatures as you
-- like, independently, just by naming them correctly.
--
-- Optionally add `ModelYRotation = <degrees>` to a creature entry to turn
-- its model to face the right way — every asset has its own idea of
-- "forward" baked in, so there's no way to guess this automatically. Try
-- 90/180/270 by eye in Studio until it looks right; 0 (or leaving it out)
-- means no extra turn. BaseService automatically mirrors this angle for
-- pedestals on the right side of the carpet vs. the left, so one value
-- covers both columns.
--
-- Optionally add `ModelPitchDegrees` / `ModelRollDegrees` to a creature
-- entry to override GameConfig.Base.ModelDefaultPitchDegrees/
-- ModelDefaultRollDegrees just for THIS one creature (e.g. if one model in
-- the pack was authored differently from the rest). Leave both out to just
-- use the pack-wide default from GameConfig.Base — that's the normal case.
-- EventWeight (Hacker / Lava / Glitchrot / Singularity only) governs
-- how often EACH of these four ultra-rare rarities gets picked WITHIN the
-- weekly event window relative to the others — same "split evenly across
-- however many named creatures share it" principle CreatureService.
-- rollCreature already uses for the normal floor-pickup pool, just applied
-- to CreatureService.rollEventCreature instead. Without this, all four
-- would be equally likely the moment the event triggers, which would make
-- a 200,000-CashBoost Singularity drop just as common as a 400-CashBoost
-- Hacker one — clearly wrong for something meant to feel THAT much
-- more powerful. Roughly 4-7x rarer each step up mirrors the CashBoost
-- jumps below (in the opposite direction: the bigger the power, the
-- smaller the odds).
GameConfig.CreatureRarities = {
	-- Colors below were rescaled to actually MATCH what each tier is now
	-- named after (they used to just be carried over from the old Common/
	-- Rare/Epic/... names, so e.g. "Gold" was showing blue): Normal = plain
	-- gray, Gold = gold, Diamond = icy diamond cyan, Galaxy = deep cosmic
	-- violet, Hacker = matrix green, Lava = molten orange-red. Toxic (was
	-- named "Rainbow", renamed on request — the Color3 was never actually
	-- rainbow-colored, a single vivid red stood in for the whole spectrum
	-- since Color3 can't hold a gradient) uses a vivid red, chosen over
	-- magenta because that was sitting too close to Glitchrot's color below
	-- and made the two hard to tell apart at a glance.
	-- Tier is a plain 1-up ranking (Normal lowest, Singularity highest) —
	-- separate from EarlyWeight/LateWeight/MinRate, which already imply an
	-- order but aren't safe to compare directly (e.g. Hacker's LateWeight
	-- is smaller than Galaxy's despite Hacker being the better rarity).
	-- Used by CreatureService.rollCreature for GameConfig.CreatureSpawn's
	-- EarlyCap (see its own comment) — a floor-range rarity ceiling.
	Normal       = { Tier = 1, EarlyWeight = 70,  LateWeight = 10, Color = Color3.fromRGB(190, 190, 190), MinRate = 1,     MaxRate = 14 },
	Gold         = { Tier = 2, EarlyWeight = 22,  LateWeight = 25, Color = Color3.fromRGB(255, 215, 0),   MinRate = 15,    MaxRate = 70 },
	Diamond      = { Tier = 3, EarlyWeight = 6,   LateWeight = 30, Color = Color3.fromRGB(150, 235, 255), MinRate = 75,    MaxRate = 300 },
	Toxic        = { Tier = 4, EarlyWeight = 1.5, LateWeight = 25, Color = Color3.fromRGB(230, 30, 40),   MinRate = 200,   MaxRate = 1800 },
	-- EventWeight added (on request, Prestige-Turm) — Galaxy previously never
	-- needed one since it was never part of a "pick ONE of several rarities"
	-- weighted roll (rollEventCreature only ever drew from EventOnly
	-- creatures, which Galaxy's own entries below aren't). Now that
	-- CreatureService.rollPrestigeCreature mixes Galaxy in with Hacker/Lava/
	-- Glitchrot/Singularity for the new Prestige-Turm floors (Floor 101+,
	-- see GameConfig.Prestige), it needs a weight in that same pool too. Set
	-- noticeably above Hacker's 100 (Galaxy is the lower tier of the five,
	-- so should be the most common) — first pass, adjust after playtesting.
	Galaxy       = { Tier = 5, EarlyWeight = 0.5, LateWeight = 10, Color = Color3.fromRGB(90, 40, 200),   MinRate = 1400,  MaxRate = 17000, EventWeight = 300 },
	-- LateWeight here is deliberately just barely above zero, NOT the "0 =
	-- placeholder, never rolled normally" it used to be — see the comment
	-- above this table. At Floor 60 that's roughly a 1-in-2000 shot per
	-- pickup for Hacker and 1-in-10,000 for Lava (compare Galaxy's
	-- LateWeight of 10 — these are still utterly negligible next to a normal
	-- rarity, just no longer a flat impossibility outside the event).
	-- EarlyWeight stays exactly 0 for both, so Floor 1 can never roll one no
	-- matter what — the interpolation only ramps them up near the top.
	Hacker       = { Tier = 6, EarlyWeight = 0, LateWeight = 0.05, Color = Color3.fromRGB(30, 255, 90),   MinRate = 10000,    MaxRate = 295000,   EventWeight = 100 },
	-- Lava's EventWeight was raised 15 -> 100 (on request, "spürbar häufiger")
	-- specifically for the Prestige-Turm pool (rollPrestigeCreature in
	-- CreatureService.lua) — see that function's comment for how EventWeight
	-- turns into a rarity's SHARE of that 5-rarity pool (Galaxy/Hacker/Lava/
	-- Glitchrot/Singularity, weighted purely by EventWeight, independent of
	-- floor). This does NOT touch Lava's normal-floor LateWeight below (still
	-- 0.01, i.e. still essentially never seen outside the Prestige-Turm/event).
	Lava         = { Tier = 7, EarlyWeight = 0,   LateWeight = 0.01,  Color = Color3.fromRGB(255, 80, 20), MinRate = 280000,   MaxRate = 2000000,  EventWeight = 100 },
	-- Two brand-new top tiers, above Lava. "Glitchrot" — a Brainrot so
	-- powerful it corrupts/breaks the game reality around it (classic
	-- "reality-glitch" power fantasy, hence the jarring glitch-magenta
	-- color). "Singularity" — the absolute ceiling: something that
	-- collapses everything around it into itself, void-black with a
	-- barely-visible violet tint. Unlike Hacker/Lava above, these
	-- two stay PURE event-exclusives (NormalPoolExcluded = true on their
	-- creature entries below) — only obtainable during the weekly event
	-- window at the top floor (GameConfig.Event), never from a normal floor
	-- pickup no matter how rare. EarlyWeight/LateWeight below are therefore
	-- unused placeholders for these two specifically.
	--
	-- EventWeight for both was raised on request ("spürbar häufiger" in the
	-- Prestige-Turm pool specifically): Glitchrot 4 -> 25, Singularity 1 -> 7.
	-- With Galaxy=300/Hacker=100/Lava=100 unchanged, the new 5-rarity total is
	-- 532, giving roughly Galaxy 56.4% / Hacker 18.8% / Lava 18.8% /
	-- Glitchrot 4.7% / Singularity 1.3% per Prestige-floor pickup (was
	-- 71.4% / 23.8% / 3.6% / 1.0% / 0.24% before this change) — Singularity
	-- alone is now roughly 5.5x more common than before.
	Glitchrot    = { Tier = 8, EarlyWeight = 0,   LateWeight = 0,  Color = Color3.fromRGB(255, 20, 220),  MinRate = 2240000,  MaxRate = 16000000,  EventWeight = 25 },
	Singularity  = { Tier = 9, EarlyWeight = 0,   LateWeight = 0,  Color = Color3.fromRGB(25, 10, 45),    MinRate = 18000000, MaxRate = 128000000, EventWeight = 7 },
}

GameConfig.Creatures = {
	-- Normal (20) — put a Model named EXACTLY e.g. "Ballerina Cappuccina"
	-- into ReplicatedStorage.CreatureModels (from your pack's "Normal"
	-- folder) and these pedestals pick it up automatically.
	{ Name = "Ballerina Cappuccina",      Rarity = "Normal" },
	{ Name = "Chef Crabracadabra",        Rarity = "Normal" },
	{ Name = "Pipi Kiwi",                 Rarity = "Normal" },
	{ Name = "Pipi Potato",               Rarity = "Normal" },
	{ Name = "Six Seven",                 Rarity = "Normal" },
	{ Name = "Svinina Bombardino",        Rarity = "Normal" },
	{ Name = "Swag Soda",                 Rarity = "Normal" },
	{ Name = "Tigroligre Frutonni",       Rarity = "Normal" },
	{ Name = "Tim Cheese",                Rarity = "Normal" },
	{ Name = "Tirilikalika Tirilikalako", Rarity = "Normal" },
	{ Name = "Torrtuginni Dragonfrutini", Rarity = "Normal" },
	{ Name = "Tralalita Tralala",         Rarity = "Normal" },
	{ Name = "Tric Trac Barabum",         Rarity = "Normal" },
	{ Name = "Trulimero Trulicina",       Rarity = "Normal" },
	{ Name = "W Or L",                    Rarity = "Normal" },
	{ Name = "Yess My Examen",            Rarity = "Normal" },
	{ Name = "Zibra Zubra Zibralini",     Rarity = "Normal" },

	{ Name = "Agarrini La Pallini",             Rarity = "Gold" },
	{ Name = "Avocadini Guffo",                 Rarity = "Gold" },
	{ Name = "Ballerino Lololo",                Rarity = "Gold" },
	{ Name = "Bambini Crostini",                Rarity = "Gold" },
	{ Name = "Banana Dancana",                  Rarity = "Gold" },
	{ Name = "Bananini Kittini",                Rarity = "Gold" },
	{ Name = "Bananita Dolphinita",              Rarity = "Gold" },
	{ Name = "Blueberrinni Octopusini",          Rarity = "Gold" },
	{ Name = "Brri Brri Bicus Dicus",            Rarity = "Gold" },
	{ Name = "Burbaloni Luliloli",               Rarity = "Gold" },
	{ Name = "Cachorrito Melonito",              Rarity = "Gold" },
	{ Name = "Cacto Hipopotamo",                 Rarity = "Gold" },
	{ Name = "Chicleteira Bicicleteira",         Rarity = "Gold" },
	{ Name = "Chicleteirina Bicicleteirina",     Rarity = "Gold" },
	{ Name = "Chillin Chili",                    Rarity = "Gold" },
	{ Name = "Cocofanto Elefante",                Rarity = "Gold" },
	{ Name = "Noo My Examen",                    Rarity = "Gold" },

	{ Name = "Esok Sekolah",              Rarity = "Diamond" },
	{ Name = "Fluri Flura",               Rarity = "Diamond" },
	{ Name = "Job Job Job Sahur",         Rarity = "Diamond" },
	{ Name = "Lerulerulerule",            Rarity = "Diamond" },
	{ Name = "Madudung",                  Rarity = "Diamond" },
	{ Name = "Matteo",                    Rarity = "Diamond" },
	{ Name = "Nyannini Cattinali",        Rarity = "Diamond" },
	{ Name = "Pakrahmatmat",              Rarity = "Diamond" },
	{ Name = "Pakrahmatmatina",           Rarity = "Diamond" },
	{ Name = "Pot Hotspot",               Rarity = "Diamond" },
	{ Name = "Quesadilla Crocodila",      Rarity = "Diamond" },
	{ Name = "Smurfo Gatto",              Rarity = "Diamond" },
	{ Name = "Strawberrelli Flamingelli", Rarity = "Diamond" },
	{ Name = "Ta Ta Ta Ta Sahur",         Rarity = "Diamond" },

	{ Name = "Ganganzelli Trulala",       Rarity = "Toxic" },
	{ Name = "Gangster Footera",          Rarity = "Toxic" },
	{ Name = "Garamararam",               Rarity = "Toxic" },
	{ Name = "Gorillo Watermelondrillo",  Rarity = "Toxic" },
	{ Name = "Illuminato Triangolo",      Rarity = "Toxic" },
	{ Name = "Karkerkar Kurkur",          Rarity = "Toxic" },
	{ Name = "La Grande Combinasion",     Rarity = "Toxic" },
	{ Name = "Lionel Cactuseli",          Rarity = "Toxic" },
	{ Name = "Orangutini Ananassini",     Rarity = "Toxic" },
	{ Name = "Orcalero Orcala",           Rarity = "Toxic" },
	{ Name = "Pandaccini Bananini",       Rarity = "Toxic" },
	{ Name = "Rhino Toasterino",          Rarity = "Toxic" },

	{ Name = "Bobrito Bandito",           Rarity = "Galaxy" },
	{ Name = "Cavallo Virtuoso",          Rarity = "Galaxy" },
	{ Name = "Espresso Signora",          Rarity = "Galaxy" },
	{ Name = "Frigo Camelo",              Rarity = "Galaxy" },
	{ Name = "Girafa Celeste",            Rarity = "Galaxy" },
	{ Name = "Glorbo Fruttodrillo",       Rarity = "Galaxy" },
	{ Name = "Los Tralaleritos",          Rarity = "Galaxy" },
	{ Name = "Odin Din Din Dun",          Rarity = "Galaxy" },
	{ Name = "Trippi Troppi",             Rarity = "Galaxy" },
	{ Name = "Trippi Troppi Troppa Trippa", Rarity = "Galaxy" },

	-- Hacker / Lava (see GameConfig.Event): EventOnly = true makes
	-- these eligible for CreatureService.rollEventCreature's extra roll
	-- during the weekly window, at the top floor — but they're NOT excluded
	-- from the normal weighted pool anymore (see the comment on
	-- CreatureRarities above), so rollCreature can also hand one out on any
	-- day, at an astronomically small chance, near the very top floors.
	-- Which of the 4 event-eligible rarities (this one, the other, and the
	-- two below) you get FROM THE EVENT ROLL specifically is weighted by
	-- EventWeight (see the comment on GameConfig.CreatureRarities) —
	-- Hacker is the most common of the four there, Singularity by far
	-- the rarest. These 14 (Hacker + Lava) are the most iconic/
	-- recognizable characters in the pack, hence the top rarities.
	{ Name = "Bombombini Gusini",         Rarity = "Hacker", EventOnly = true },
	{ Name = "Boneca Ambalabu",           Rarity = "Hacker", EventOnly = true },
	{ Name = "Brr Brr Patapim",           Rarity = "Hacker", EventOnly = true },
	{ Name = "La Vacca Saturno Saturnita", Rarity = "Hacker", EventOnly = true },
	{ Name = "Lirili Larila",             Rarity = "Hacker", EventOnly = true },
	{ Name = "Tung Sahur",                Rarity = "Hacker", EventOnly = true },
	{ Name = "Dragon Cannelloni",         Rarity = "Hacker", EventOnly = true },
	{ Name = "Meowl",                     Rarity = "Hacker", EventOnly = true },

	{ Name = "Bombardiro Crocodilo",      Rarity = "Lava", EventOnly = true },
	{ Name = "Cappuccino Assassino",      Rarity = "Lava", EventOnly = true },
	{ Name = "Chimpanzini Bananini",      Rarity = "Lava", EventOnly = true },
	{ Name = "Tralalero Tralala",         Rarity = "Lava", EventOnly = true },
	{ Name = "Strawberry Elephant",       Rarity = "Lava", EventOnly = true },
	{ Name = "Tralaledon",                Rarity = "Lava", EventOnly = true },
	{ Name = "Esok Sekolah",              Rarity = "Lava", EventOnly = true },

	-- Two brand-new top tiers above Lava (see the comment on
	-- GameConfig.CreatureRarities.Glitchrot/Singularity for the odds/theme).
	-- Unlike Hacker/Lava just above, these ALSO carry
	-- NormalPoolExcluded = true — CreatureService.rollCreature skips any
	-- creature with that flag, so these two stay 100% event-only, with no
	-- normal-day chance at all, however small.
	--
	-- Roster replaced (on request) — the original 3 Italian-named
	-- placeholders per rarity (Glitchetto Lasagnoso/Errore Cannolo/
	-- Pixellino Ravioli, Buconero Tortellini/Infinito Panettone/Vuoto
	-- Cosmico Espresso) are gone, swapped 1-for-1 in COUNT (3->5 each, not a
	-- like-for-like rename) for the 5+5 real models the user actually built.
	-- Same EventOnly + NormalPoolExcluded = true as before — still 100%
	-- event-exclusive, just a bigger roster within that pool.
	{ Name = "Capitano Moby",         Rarity = "Glitchrot", EventOnly = true, NormalPoolExcluded = true },
	{ Name = "Eviledon",              Rarity = "Glitchrot", EventOnly = true, NormalPoolExcluded = true },
	{ Name = "Vulturino Skeletono",   Rarity = "Glitchrot", EventOnly = true, NormalPoolExcluded = true },
	{ Name = "Zombie Tralala",        Rarity = "Glitchrot", EventOnly = true, NormalPoolExcluded = true },
	{ Name = "Centrucci Nuclucci",    Rarity = "Glitchrot", EventOnly = true, NormalPoolExcluded = true },

	{ Name = "La Supreme Combinasion", Rarity = "Singularity", EventOnly = true, NormalPoolExcluded = true },
	{ Name = "Dragon Gingerini",       Rarity = "Singularity", EventOnly = true, NormalPoolExcluded = true },
	{ Name = "Skibidi Toilet",         Rarity = "Singularity", EventOnly = true, NormalPoolExcluded = true },
	{ Name = "Gattito Tacoto",         Rarity = "Singularity", EventOnly = true, NormalPoolExcluded = true },
	{ Name = "Blackhole Goat",         Rarity = "Singularity", EventOnly = true, NormalPoolExcluded = true },
}

GameConfig.CreatureSpawn = {
	FloorInterval = 5, -- a claim spot spawns every N floors (except Floor 100, the Summit floor — see TowerGenerator's hasClaimSpot)

	-- How many real Brainrots stand on a claim-spot floor at once (2-3, see
	-- TowerGenerator.buildClaimSpot) — SHARED between everyone in the tower,
	-- first-come-first-served, same competitive spirit as the Slap Hand.
	-- Each is rolled independently with the exact same floor-based
	-- rarity/value odds as before (rollCreature/getRarityWeight) — higher
	-- floors still mean rarer, more valuable Brainrots on display. The
	-- instant one is claimed, that one spot re-rolls a fresh Brainrot after
	-- a short delay so the spot never runs dry.
	StandCount = 3,
	RestockDelaySeconds = 1.5,

	-- On request ("die Brainrots nach 5-10 min neu spawnen lassen damit
	-- Abwechslung reinkommt") — an UNCLAIMED stand also re-rolls itself on
	-- its own after a random delay in this range, so the same few Brainrots
	-- can't just sit there forever if nobody claims them (see
	-- TowerGenerator.buildClaimSpot's scheduleIdleRefresh). Randomized
	-- (a range, not one fixed number) so the 2-3 stands on one claim spot
	-- naturally drift out of sync with each other instead of all
	-- refreshing in the same visible instant — reads as organic variety,
	-- not a scripted reset. A claim itself still uses the much shorter
	-- RestockDelaySeconds above and re-arms its own fresh idle-refresh
	-- window right after, exactly like every other stand.
	IdleRefreshMinSeconds = 300, -- 5 min
	IdleRefreshMaxSeconds = 600, -- 10 min

	-- An ORDERED list of hard rarity ceilings, each on TOP of the normal
	-- floor-based odds (getRarityWeight), not a replacement for them: for a
	-- given floorIndex, CreatureService.isRarityAllowedOnFloor applies the
	-- FIRST entry below whose EndFloor is still >= floorIndex, excluding
	-- any rarity whose Tier (see GameConfig.CreatureRarities) is above that
	-- entry's MaxTier from the roll entirely — same mechanism
	-- NormalPoolExcluded already uses for Glitchrot/Singularity. Once
	-- floorIndex exceeds every entry's EndFloor, no ceiling applies at all
	-- and the roll works exactly like it did before any of this existed.
	-- MUST stay sorted ascending by EndFloor for that "first matching
	-- entry" lookup to make sense.
	--
	-- Stage 1 ("von Floor 1-20 maximal Brainrots mit Rarity Gold spawnen,
	-- danach wieder alles wie zuvor", unchanged): Normal (1) and Gold (2)
	-- only through Floor 20.
	-- Stage 2 (NEW, on request: "eine Sperre einbauen das Galaxy erst ab
	-- Floor 60 kommen" — after the drop-chance investigation confirmed
	-- Galaxy's odds themselves match the config, just apparently earlier
	-- than felt right): Diamond (3) and Toxic (4) still unlock at Floor 21
	-- exactly as before, but Galaxy (5) and anything rarer now additionally
	-- stays off the table until Floor 60. Hacker (6)/Lava (7) were already
	-- vanishingly close to 0% before Floor 60 anyway (EarlyWeight 0, a tiny
	-- LateWeight that's barely ramped up that early) — this mostly formalizes
	-- what was already true for them, Galaxy is the rarity it actually changes.
	RarityCaps = {
		{ EndFloor = 20, MaxTier = 2 },
		{ EndFloor = 59, MaxTier = 4 },
	},
}

-- === WEEKLY EVENT ==============================================================
-- A recurring one-hour window, every Sunday, during which the top floor
-- (Floors.Count) has a small extra chance to drop a "Hacker" or
-- "Lava" tier creature instead of (or alongside) the normal roll — see
-- CreatureService.rollCreature and EventService.IsActive.
GameConfig.Event = {
	-- TEMPORÄR AUS (on request, "entferne das Event momentan damit es am
	-- Sonntag nicht startet") — solange dies false ist, startet das
	-- wöchentliche Zeitfenster unten NICHT automatisch mehr, egal was
	-- DayOfWeek/StartHour/EndHour sagen (siehe EventService.IsActive's frühen
	-- Enabled-Check). Auf true zurücksetzen, um das automatische Sonntags-
	-- Fenster wieder scharfzustellen — DayOfWeek/StartHour/EndHour/
	-- UtcOffsetHours/DropChancePercent bleiben dabei unverändert erhalten,
	-- nichts muss neu eingetragen werden.
	--
	-- Betrifft NUR das automatische Schedule-Fenster: die manuelle
	-- "/event on"/"/event off"-Testschaltung (EventService.SetForceActive)
	-- und der Admin-Abuse-Modus ("/adminabuse ...") laufen unabhängig davon
	-- weiter, falls du zum Testen trotzdem gezielt ein Event-Fenster
	-- auslösen willst.
	Enabled = false,

	DayOfWeek = 1,          -- os.date's wday: 1 = Sunday, 2 = Monday, ... 7 = Saturday
	StartHour = 18,         -- 18:00 local time (inclusive)
	EndHour = 19,           -- 19:00 local time (exclusive) — a 1-hour window

	-- Server clocks run in UTC — this is added to UTC to get "local" time for
	-- the check. 2 = Central European Summer Time (CEST, UTC+2, what Germany
	-- is on right now in August). Switch to 1 for Central European Time (CET,
	-- winter) when daylight saving ends, or leave at 2 if that's close enough
	-- for a prototype.
	UtcOffsetHours = 2,

	DropChancePercent = 30, -- % chance per Floor-60 pickup, during the window,
	                         -- of getting one of the 4 event-only rarities
	                         -- (Hacker / Lava / Glitchrot / Singularity)
	                         -- (was 2 — raised on request)
}

-- === BRAINROT-DEX COMPLETION BONUS (on request) ================================
-- "wenn man alle rarity Normal gesammelt hat, 10% Cash bekommen, genau so wie
-- alle anderen Rarity Klassen ... als Geschenk ohne es zu bauen" — a NEW,
-- PERMANENT Cash bonus, separate from CreatureService.GetTotalCashBoost
-- (which is per-creature CURRENTLY OWNED and disappears if you sell/trade it
-- away). This one is keyed off data.DiscoveredCreatures (see CreatureService.
-- finalizeClaim) — a creature marks itself "discovered" forever the first
-- time you ever claim it, even if you later sell every copy — so once you've
-- discovered every named creature in a rarity, that rarity's +10% is yours
-- for good, exactly like the request says ("ohne es zu bauen", i.e. you don't
-- need to still own/have a pedestal for it).
--
-- Applies to EVERY rarity class the same way (Normal, Gold, Diamond, Toxic,
-- Galaxy, Hacker, Lava, Glitchrot, Singularity) — the user's own explicit
-- choice over "just Normal for now" — and stacks ADDITIVELY per completed
-- rarity, so completing all 9 rarities eventually adds up to +90% Cash. See
-- EconomyService's getCashMultiplierFactor (the ONE shared place real income
-- AND the Dex's own preview numbers both read from) for where this is
-- actually applied, and CreatureService.GetDexCompletionBonus for how many
-- rarities currently count.
GameConfig.Dex = {
	CompletionCashBoostPerRarity = 0.10,
}

-- === ADMIN ABUSE (manuell ausgelöstes Zeit-Event, "Steal a Brainrot"-Vorbild) ==
-- Ein Admin/der Creator tippt "/adminabuse <Minuten>" im Chat (siehe
-- init.server.lua) und schaltet damit für eine begrenzte Zeit ZWEI Dinge auf
-- einmal ein: (1) denselben EventOnly-Drop-Boost wie das wöchentliche
-- GameConfig.Event-Fenster oben — siehe EventService.SetAdminAbuseActive,
-- KEIN zweites, paralleles Rarity-System, nur ein manuell getimter Schalter
-- für dieselbe Mechanik —, und (2) eine rötliche Himmel/Licht-Änderung
-- (AdminAbuseService.lua).
--
-- Die "Glücks-Truhen" selbst sind NICHT mehr an dieses Event gebunden — auf
-- Wunsch ("die Glücks Truhen immer spawnen als Beschäftigung auch ohne
-- Event") laufen sie jetzt PERMANENT, schon ab Serverstart
-- (AdminAbuseService.StartPermanentChests, aufgerufen einmal aus init.server
-- .lua direkt nach TowerGenerator.Build) — zufällig auf schon gebauten
-- Turm-Etagen verteilt (TowerGenerator.GetRandomFloorPlatform), geben beim
-- Einsammeln entweder Cash oder eine seltene Kreatur, und respawnen sich
-- selbst immer weiter, komplett unabhängig davon, ob gerade ein
-- "/adminabuse"-Fenster läuft. Damit die manuelle Event-Variante trotzdem
-- noch etwas Besonderes bleibt (nicht nur Optik + Drop-Boost, ohne jeden
-- Bezug mehr zu den Truhen): welche der beiden ChestCreatureChancePercent-
-- Werte unten gerade gilt, hängt von EventService.IsAdminAbuseActive() ab
-- (siehe AdminAbuseService.grantChestReward) — im Normalbetrieb die
-- (bewusst schlechtere, auf Wunsch: "die Spawnrate der Brainrots soll
-- schlechter sein") Base-Chance, während eines aktiven "/adminabuse"-
-- Fensters die höhere Event-Chance.
GameConfig.AdminAbuse = {
	DefaultDurationMinutes = 20,
	MaxDurationMinutes = 60, -- Sicherheitsgrenze gegen einen Tippfehler wie "/adminabuse 9999"

	SkyColor = Color3.fromRGB(170, 25, 25),
	AmbientColor = Color3.fromRGB(90, 30, 30),
	OutdoorAmbientColor = Color3.fromRGB(90, 30, 30),

	ChestCount = 6,                -- so viele Glücks-Truhen sind PERMANENT gleichzeitig über den Turm verteilt
	ChestLifetimeSeconds = 45,     -- verschwindet wieder, wenn sie niemand rechtzeitig holt
	ChestRespawnDelaySeconds = 15, -- Wartezeit, nachdem eine weg ist (eingesammelt oder abgelaufen), bevor anderswo eine neue erscheint
	ChestPickupRadius = 6,

	-- Belohnung beim Einsammeln: entweder eine seltene Kreatur (aus dem Pool
	-- unten, via CreatureService.ClaimPhysicalCreature) oder ein Cash-Bonus
	-- — RELATIV zum eigenen aktuellen Einkommen der sammelnden Person
	-- (EconomyService.GrantCashBonusSeconds), exakt dasselbe Prinzip wie
	-- GameConfig.Summit.ConsolationCashBonusSeconds, nicht ein fixer Betrag.
	--
	-- ZWEI verschiedene Chancen auf eine Kreatur statt nur einer, seit die
	-- Truhen permanent laufen (siehe der lange Kommentar oben): die NIEDRIGE
	-- gilt im ganz normalen Alltag (keine laufende Admin-Abuse-Session), die
	-- HOHE nur während eines aktiven "/adminabuse"-Fensters — genau der auf
	-- Wunsch gewollte Unterschied ("Beschäftigung auch ohne Event, aber
	-- Spawnrate der Brainrots soll schlechter sein").
	BaseChestCreatureChancePercent = 10,
	EventChestCreatureChancePercent = 40,
	ChestCreatureRarities = { "Diamond", "Toxic" },
	ChestCashBonusSeconds = 120,
}

-- === ANTI-CHEAT (Floor-Skip-Plausibilitätsprüfung) =============================
-- On request, following a security review that found NOTHING checks HOW FAST
-- (or how) a player reached a given Floor's Detector — a speed/fly hack
-- (trivial to build in Roblox; the project's own old AdminFly.client.lua was
-- a live example of exactly this technique, now Studio-only) could skip
-- straight to Floor 100 and instantly claim the permanent Hall-of-Fame entry,
-- the Mega-Truhe reward, and every Fast-Travel checkpoint, without ever
-- actually climbing.
--
-- The fix (EconomyService.OnFloorReached) is DELIBERATELY not "you must
-- touch every single floor in order" — strong Jump-Upgrade tiers legitimately
-- let a player clear several floors in one jump, so a strict sequential
-- check would punish exactly the players who upgraded the most. Instead it's
-- a TIME-based plausibility check: how many floors were skipped since the
-- last floor touch, versus how much real time actually passed. Skipping
-- many floors is fine as long as enough real time passed to make that
-- believable; skipping many floors in a fraction of a second is not.
--
-- Every constant below is a first-pass, deliberately GENEROUS starting
-- point, not a precisely derived one — same "please playtest and tell me if
-- it needs dialing up or down" situation as GameConfig.Floors' own jump-gap
-- tuning (real Roblox jump/movement feel has repeatedly turned out more
-- forgiving than an idealized formula predicts, see that section's own
-- history). Getting this too strict risks falsely blocking a genuinely
-- excellent player's progress (silently, see OnFloorReached — no kick/ban,
-- just that one floor-touch doesn't count); too loose lets a hack still
-- slip through. When in doubt, err generous.
GameConfig.AntiCheat = {
	-- Minimum real seconds required PER FLOOR skipped, at an assumed
	-- best-case play speed — e.g. skipping 4 floors in one jump-chain needs
	-- at least 4 * this many seconds to have actually passed since the last
	-- floor touch, or it's rejected as implausible. Deliberately low (a
	-- single strong jump clearing several floors in under a second is
	-- realistic) — this is meant to catch "whole tower in an instant", not
	-- "impressively fast climbing".
	MinSecondsPerFloorSkip = 0.5,

	-- Caps how much elapsed time a single check can credit, so idle/AFK
	-- time can't be "banked" and cashed in on an instant hack-jump right
	-- after — a player who stands still for 10 minutes then hack-jumps 80
	-- floors in 1 second would otherwise look perfectly plausible ("10
	-- minutes was more than enough time"). No legitimate single jump-chain
	-- needs anywhere near this long, so genuine players never notice this
	-- cap either way.
	MaxBankedSeconds = 60,

	-- Hard ceiling, independent of elapsed time entirely: no legitimate
	-- single jump (or connected jump-chain touching only its start/end
	-- floor) clears this many floors in one Detector touch, so this always
	-- rejects a skip bigger than this, no matter what the time math above
	-- says — a backstop against the time-based check somehow being fooled
	-- (e.g. a server hiccup inflating the measured elapsed time).
	HardMaxFloorsSkip = 20,

	-- NOTE: this used to also show the player themselves an in-game warning
	-- Notice after enough rejected skips in one session. Removed on request
	-- — a real player doing a Rebirth immediately followed by a Jump-Upgrade
	-- purchase could legitimately clear several floors right after their
	-- progress reset, and kept seeing that ("⚠️ Ungewöhnliche Bewegung
	-- erkannt") warning for entirely honest play. Every rejection is still
	-- logged server-side (warn(), visible in Studio's/the game's own server
	-- output only, never to the player) regardless — see
	-- EconomyService.OnFloorReached — so nothing is silently lost from an
	-- admin's point of view, it just never surfaces to the player anymore.
}

-- === PLAYER BASE (creature display, "Steal a Brainrot" style) ================
-- Each of up to MaxPlayers players gets one fixed base plot, arranged in a
-- circle AROUND the tower (PlotRadius studs from its center, evenly spaced —
-- 4 plots = North/East/South/West) so the tower sits in the middle of the
-- bases. Every claimed creature is appended, in order, to that player's
-- CreatureLog and automatically fills the next free pedestal — no manual
-- placing needed. Total slots = StartSlots + Rebirths * SlotsPerRebirth
-- (grows forever, no cap). Once more than SlotsPerFloor slots are needed, a
-- new story is added above the base automatically (the total slot count in
-- SlotRowColumns below must equal SlotsPerFloor).
GameConfig.Base = {
	MaxPlayers = 4,        -- one base plot per player; also sets Players.MaxPlayers
	StartSlots = 6,        -- pedestals available at 0 rebirths
	SlotsPerRebirth = 1,   -- +1 pedestal per rebirth
	SlotsPerFloor = 10,    -- pedestals per story; slot 11 starts a new story

	PlotSize = Vector3.new(70, 1, 70),
	PlotRadius = 130,      -- distance from the tower's center (0,0) to each plot's center

	-- Vertical gap between base stories (floor-to-floor, i.e. Floor_2's Y
	-- minus Floor_1's Y). War 14, auf Wunsch erhöht ("nur der oberste Stock
	-- wurde geändert, Ebene 1-2 sind immer noch zu niedrig") — jede Etage
	-- AUSSER der obersten bekommt ihre Deckenhöhe aus diesem Wert (siehe
	-- BaseService.RefreshBase's `connectHeight = FloorHeight - PlotSize.Y`,
	-- der offene Abstand zwischen zwei gestapelten Etagen), während NUR die
	-- oberste, gerade offene Etage stattdessen WallHeight (18) bis zum Dach
	-- bekommt — dadurch war jede untere Etage spürbar niedriger als die
	-- oberste. Jetzt auf 19 gesetzt, damit connectHeight (19 - PlotSize.Y=1
	-- = 18) exakt WallHeight entspricht — jede Etage im Turm ist jetzt
	-- gleich hoch, keine Etage mehr "eingequetscht".
	FloorHeight = 19,

	-- Pedestal layout — ONE column either side of the red carpet x 5 rows
	-- deep. Both axes are now centered ON THE PILLARS (on request): the
	-- corner pillars sit at local X/Z = ±33 (PillarThickness/2 inset from
	-- PlotSize/2=35), so SlotColumnsX (±19) sits exactly midway between the
	-- carpet's edge (CarpetWidth/2=5) and a pillar, and SlotRowsZ (5 values,
	-- symmetric around 0) is centered between the front and back corner
	-- pillar instead of clustering toward the back wall like an earlier
	-- revision did.
	--
	-- SlotColumnsX are the 2 fixed X offsets (one per side).
	-- BaseService's existing inward-facing "mirror" rotation logic needs no
	-- changes since it only cares about the SIGN of localX. SlotRowsZ are
	-- the 5 fixed Z offsets. Each entry in SlotRowColumns lists which
	-- SlotColumnsX indices that row uses — 2 x 5 = 10 to match
	-- SlotsPerFloor exactly. See BaseService.slotLocalOffset for how this
	-- table is walked.
	SlotColumnsX = { -19, 19 },
	SlotRowsZ = { 18, 9, 0, -9, -18 },
	SlotRowColumns = {
		{ 1, 2 },
		{ 1, 2 },
		{ 1, 2 },
		{ 1, 2 },
		{ 1, 2 },
	},

	TileSize = Vector3.new(8, 0.6, 8),      -- flat green creature tile ("Steal a Brainrot" style)
	-- The round "stand here to collect/sell" platform in front of each
	-- creature (on request, "die Position des Geld einsammeln ... möchte
	-- das es davor ist auf einer runden Platform" — this used to be a small
	-- floating ball sitting almost on top of the creature itself, hidden
	-- entirely once a real 3D model loaded; now it's the same always-visible
	-- glowing "coin" disc style already used for every other station in the
	-- base, see buildStationPart's own pad). 0.3 thick, 5-stud diameter —
	-- same footprint as every other station pad in this file.
	CollectPadSize = Vector3.new(0.3, 5, 5),
	CreatureModelHeight = 9.5,                 -- studs tall every REAL creature model (GameConfig.Creatures[].ModelId) gets scaled to, see BaseService.spawnCreatureModel
	                                            -- (was 3.2, then 5.5 — 9.5 confirmed as the right size in testing)

	-- Pack-wide orientation fallback, applied to any real model that doesn't
	-- set its own ModelPitchDegrees/ModelRollDegrees (see
	-- CreatureModelDisplay.Spawn). IMPORTANT: this pack turned out to NOT be
	-- uniformly misoriented — the raw bounding-box sizes logged by
	-- CreatureModelDisplay show a real mix (some creatures already have Y as
	-- by far their biggest dimension, i.e. already upright; others have X or
	-- Z biggest). So a single value here can't fix everything at once —
	-- forcing e.g. PitchDegrees=90 on ALL of them would tip the
	-- already-correct ones onto their side. Leave this at 0/0 (no pack-wide
	-- correction) and instead set ModelPitchDegrees/ModelRollDegrees
	-- per-creature in GameConfig.Creatures, ONLY for the specific creatures
	-- that actually look wrong in-game. Use the "/pitch <p> <r>" chat
	-- command (Studio/creator only) to test values live on your whole base
	-- without a Stop+Play each time, then copy the value that looked right
	-- for that one creature into its GameConfig.Creatures entry.
	-- PitchDegrees = rotation around X (tips it forward/backward).
	-- RollDegrees  = rotation around Z (tips it left/right).
	ModelDefaultPitchDegrees = 0,
	ModelDefaultRollDegrees = 0,

	-- "Steal a Brainrot"-style open shelter, built once per plot (ground
	-- floor only — extra stories added via rebirth stay simple platforms,
	-- see BaseService.RefreshBase): 4 corner pillars + a flat roof, an
	-- angled sign hanging over the entrance showing the owner's name, a red
	-- carpet path down the middle, and a decorative "Collect Zone" mat just
	-- outside. The entrance always faces the tower (BaseService.getPlotCFrame
	-- already rotates each plot to look at it).
	WallHeight = 18,         -- pillar height, platform top to roof underside (doubled
	                         -- from 9 on request — gives the sign/roof much more
	                         -- breathing room and a taller, roomier entrance)
	PillarThickness = 4,
	RoofThickness = 1.5,
	RoofOverhang = 4,        -- how far the roof sticks out past the platform edges
	-- UNUSED as of the floating-name-tag change ("Schild entfernen,
	-- stattdessen den Namen über der Base schwebend") — BaseService.
	-- buildStructure no longer builds a physical entrance sign at all, it
	-- builds a BillboardGui name tag instead (see its own comment). Left
	-- here, not deleted, in case a physical sign is ever wanted back.
	SignWidth = 46,
	SignHeight = 4,          -- a banner strip, NOT a full wall — must stay well under
	                         -- WallHeight (9) or it blocks the whole entrance (bug fixed)
	SignThickness = 2,
	SignTiltDegrees = 0,     -- 0 = perfectly flat/vertical sign, flush with the wall
	                         -- (was 25 — looked crooked/warped in-game, so straightened)
	CarpetWidth = 10,

	-- World Y of the grass meadow's TOP SURFACE (see TowerGenerator.lua's
	-- buildGround: the "Meadow" part is CFrame.new(0, -3, 0) with
	-- Size.Y = 4, so its top sits at -3 + 4/2 = -1). A base plot's own
	-- platform sits noticeably higher than this (PlotSize.Y/2 = 0.5, and
	-- plot origins are always at world Y = 0 — see BaseService.getPlotCFrame),
	-- which is fine for anything built ON the platform, but BaseService's
	-- buildStationPart also places some kiosks OUTSIDE a plot's own
	-- footprint, out on this grass (see buildStations' frontZ stations) —
	-- those need to measure against the grass's real height instead of the
	-- platform's, or they float ~1.5 studs above the ground ("die Platten
	-- schweben in der Luft"). Keep this in sync with TowerGenerator.lua's
	-- Meadow part if that part's height/position ever changes.
	GroundTopY = -1,

	-- Optional Roblox Decal/Image asset IDs for the 5 floating base-station
	-- symbols (see BaseService.lua's buildStationPart) — grab one from
	-- Studio's Toolbox (Decals tab) or the Creator Store, right-click it ->
	-- "Copy Asset ID", and paste the number here as either a bare number
	-- ("123456789") or the full "rbxassetid://123456789" form, either works.
	-- Leave a station as "" (the default) to keep its plain emoji fallback —
	-- no code changes needed either way, and each station is independent
	-- (you can set some and leave others as emoji).
	StationIcons = {
		Upgrade = "",
		Rebirth = "",
		AutoCollect = "", -- replaces the removed Slap Hand kiosk, see GameConfig.Gamepasses.AutoCollect
		DoubleCash = "",
		RebirthRobux = "", -- replaces the removed VIP kiosk, see GameConfig.Rebirth.RobuxProduct
	},
}

-- === HUD ICONS ==================================================================
-- Optional Roblox Decal/Image asset IDs for the big bottom-left Cash/Jump
-- HUD icons (see UIBuilder.lua's makeBigStatRow) — same convention as
-- GameConfig.Base.StationIcons above: grab an asset ID from Studio's
-- Toolbox (Decals tab) or the Creator Store, right-click it -> "Copy Asset
-- ID", and paste it here as either a bare number ("123456789") or the full
-- "rbxassetid://123456789" form, either works. Leave an entry as "" (the
-- default) to keep its plain emoji fallback.
GameConfig.HUD = {
	Icons = {
		Cash = "140328458522143", -- money-bag icon (on request, replacing the 💰 emoji —
		                          -- swapped from the first ID, 71562500655686, which
		                          -- showed up blank/empty in-game — likely not a valid
		                          -- Image/Decal asset, or one Roblox wouldn't serve)
		Jump = "",
	},
}

-- === MONETIZATION ==============================================================
-- Every entry below already has its real Studio-created ID filled in. A
-- future new entry starts at Id/ProductId = 0 ("not configured") until you
-- publish the game once and create the real Game Pass / Developer Product in
-- Studio's Monetization tab — see README.md for the steps. (VIP and Auto
-- Climb Boost used to sit here as two such never-finished placeholders —
-- removed entirely on request, since neither had a kiosk left to sell them:
-- VIP's kiosk was replaced by "1x Wiedergeburt", and Auto Climb Boost never
-- got one back after an earlier rework. See EconomyService/
-- MonetizationService git history if either is ever wanted back.)
--
-- IMPORTANT — DoubleCash/QuadCash/AutoCollect below are marked
-- `IsDeveloperProduct = true`. Diagnosed after "Fehler" purchase failures
-- kept happening no matter which ID was set: a Creator Dashboard screenshot
-- confirmed these three were actually created as Developer Products, not
-- real Game Passes (the user's own deliberate choice, not a mistake to
-- "fix" by recreating them) — despite living in this "Gamepasses" table
-- (kept as-is rather than renaming everything that reads it, see below).
-- That distinction matters a lot to Roblox:
--   * A real Game Pass is bought ONCE and Roblox itself remembers forever
--     (UserOwnsGamePassAsync) — no game-side bookkeeping needed.
--   * A Developer Product can be bought repeatedly and Roblox remembers
--     NOTHING — the purchase only ever fires MarketplaceService.
--     ProcessReceipt once, and if the game doesn't persist that itself, the
--     "purchase" has no lasting effect at all.
-- Before this fix, the code called PromptGamePassPurchase/
-- UserOwnsGamePassAsync on these three IDs — which fails immediately for a
-- non-Gamepass ID, matching EXACTLY the "Fehler, egal welche Id" symptom.
-- Fixed by (1) IsDeveloperProduct below telling both the client (init.
-- client.lua's RequestGamepassPrompt listener) to call PromptProductPurchase
-- instead, and (2) MonetizationService now persisting ownership itself in
-- PlayerDataManager (OwnsDoubleCash/OwnsQuadCash/OwnsAutoCollect fields) the
-- moment ProcessReceipt sees one of these ProductIds, instead of ever
-- asking Roblox — see MonetizationService.lua's own comment for the rest.
GameConfig.Gamepasses = {
	-- Real Developer Product created in Studio's Monetization tab ("2x
	-- Geld", 99 Robux, set there — a script can never set its price).
	-- RobuxCost is ONLY the kiosk's displayed price (BaseService's "Nur
	-- [Robux icon][price]" status label, on request) — keep it in sync with
	-- whatever price is actually set on the real product in Studio.
	DoubleCash  = { Id = 3711558308, Name = "2x Cash",           Multiplier = 2, RobuxCost = 99, IsDeveloperProduct = true },
	-- "4x Cash" upgrade tier — on request ("bei 2x Geld, wenn das gekauft
	-- wurde kann es sich dann auf 4x Geld ändern mit einem höheren Kauf
	-- preis"). A SECOND, separate real product (299 Robux, set in Studio —
	-- Roblox has no way to change an existing product's price only for
	-- players who already own a different one), rather than somehow
	-- "upgrading" the DoubleCash one. REPLACES DoubleCash's Multiplier
	-- rather than stacking with it — someone who owns BOTH still only gets
	-- 4x total, not 8x (see EconomyService's getCashMultiplierFactor, which
	-- checks QuadCash first and only falls back to DoubleCash if this one
	-- isn't owned) — simpler for players to reason about, no
	-- "pay-twice-for-8x" pricing trap. BaseService's "2x Cash" kiosk itself
	-- switches its Robux button to offer THIS one instead, automatically,
	-- once a player already owns DoubleCash (see BaseService.buildStations /
	-- UpdateStationLabels).
	QuadCash    = { Id = 3711600500, Name = "4x Cash",           Multiplier = 4, RobuxCost = 299, IsDeveloperProduct = true },
	-- On request ("Slap Hand entfernen und stattdessen ein Kauf Button für
	-- automatisch Geld Sammeln ... der dann automatisch immer das Geld von
	-- den Brainrots einsammelt") — replaces the Slap Hand kiosk in
	-- BaseService.buildStations. Owning this skips the "walk over each
	-- pedestal to collect" step entirely (see EconomyService.
	-- StartPassiveIncomeLoop): every tick's payout goes straight into Cash
	-- instead of sitting in PedestalCash waiting to be collected. Real
	-- Developer Product created in Studio's Monetization tab (59 Robux, set
	-- there — a script can never set its price) — Id filled in from that
	-- listing ("Cash Sammler", 3711750248). RobuxCost: see DoubleCash's
	-- comment above. Was Id 3711601643 / 69 Robux, and 3711558205 / 69 Robux
	-- before that (earlier products, replaced again).
	AutoCollect = { Id = 3711750248, Name = "Auto-Sammeln", RobuxCost = 59, IsDeveloperProduct = true },
}

-- === SOUNDS =====================================================================
-- Every SoundId below starts EMPTY ("") on purpose — same reasoning as
-- ReplicatedStorage.CreatureModels (see GameConfig.Creatures' big comment):
-- this project already learned the hard way that loading someone ELSE's
-- Toolbox/Creator Store asset by ID at runtime (InsertService:LoadAsset)
-- keeps failing with "User is not authorized to access Asset", even for a
-- "Save to Roblox" own copy — sounds use that exact same permission system,
-- so hardcoding some SoundId found online here would very likely just be
-- silent (a Sound with an inaccessible SoundId simply never plays — no
-- error, nothing telling you why). The fix is the same as it was for
-- CreatureModels: pick the sound yourself, IN STUDIO, so it gets inserted
-- into your own place instead.
--
-- How to fill one in: View > Toolbox > Audio tab > search (try the term in
-- each comment below) > click a result to preview it > right-click it >
-- "Copy Asset ID" (or open its details page and copy the number from the
-- URL) > paste it below as "rbxassetid://123456". Once it's set, it plays
-- immediately — no Stop+Play needed, SoundPlayer.lua reads this table fresh
-- every time you rejoin. Leaving one blank just means that specific effect
-- stays silent, same "no model dropped in yet -> falls back to the colored
-- ball" idea as everywhere else in this project — nothing else breaks.
--
-- All of these are played CLIENT-SIDE only (see StarterPlayerScripts/
-- ClientMain/SoundPlayer.lua) — each player only hears their OWN pickups/
-- purchases/etc., not everyone else's on the server, same as the existing
-- toast messages (ShowCreatureToast/ShowSellToast) these are paired with.
GameConfig.Sounds = {
	CreatureClaimed = { Id = "", Volume = 0.6 }, -- try "coin", "collect", "pickup"
	CashCollected   = { Id = "", Volume = 0.5 }, -- try "cash register", "coins", "ka-ching"
	CreatureSold    = { Id = "", Volume = 0.5 }, -- try "cash register", "sell", "coins"
	UpgradeBought   = { Id = "", Volume = 0.6 }, -- try "power up", "upgrade"
	Rebirth         = { Id = "", Volume = 0.8 }, -- try "level up", "magic transformation", "whoosh"
	FloorReached    = { Id = "", Volume = 0.4 }, -- try "checkpoint", "ding", "notification"
	ButtonClick     = { Id = "", Volume = 0.3 }, -- try "ui click", "button click"
	TradeSuccess    = { Id = "", Volume = 0.6 }, -- try "success", "chime"
	EventStarted    = { Id = "", Volume = 0.7 }, -- try "alarm", "fanfare", "siren"
	Error           = { Id = "", Volume = 0.4 }, -- try "error", "buzz", "denied"

	-- Looping background music — OFF by default (a blank Id means "don't
	-- start anything", not "play silence"). Fill in a SoundId to turn it on.
	-- Volume is deliberately low since it's meant to sit under every effect
	-- above, not compete with them.
	BackgroundMusic = { Id = "", Volume = 0.15 },
}

-- === SHOP =======================================================================
-- The Slap Hand PvP tool (Cash-bought) that used to live here has been fully
-- removed from the game on request — see ShopService.lua's own note (that
-- file is now an inert stub) and init.server.lua's Player-lifecycle section
-- for the removed re-grant call. GameConfig.Shop itself is gone since Slap
-- Hand was its only entry; nothing else reads GameConfig.Shop anymore.

-- === TRADING ====================================================================
-- A dedicated physical "Trade Zone" near the tower, in the gap BETWEEN two
-- base plots — walk in, send a trade request to someone else standing
-- there, each side offers exactly ONE Brainrot, both confirm, and the swap
-- happens atomically (TradeService.lua). Deliberately simple — 1-for-1
-- only, no Cash added on either side — to keep the first version of this
-- low-risk to abuse/scam; nobody can lose more than the one Brainrot they
-- themselves chose to offer.
GameConfig.Trade = {
	-- Diagonal offset (45°, not straight out along X or Z) so this sits
	-- exactly BETWEEN two of the 4 base plots, which are at 0°/90°/180°/270°
	-- around the origin (see BaseService's plot angle formula) — radius here
	-- is ~120 studs (85*sqrt(2)), just past the Slap Hand's PvP range
	-- (ShopService.isInTowerZone triggers under PlotRadius-20 = 110 studs)
	-- so a trade in progress can't get interrupted by a knockback, while
	-- still being visibly close to both the tower and the surrounding bases
	-- instead of off in an empty corner of the map.
	ZonePosition = Vector3.new(85, 0, 85),
	ZoneRadius = 16,     -- studs from ZonePosition a player must stand within to count as "in the zone"
	RequestTimeoutSeconds = 20, -- an unanswered trade request auto-expires after this long
}

-- === ROBUX JUMP-UPGRADE TRADER (REMOVED) ========================================
-- Used to be a single SHARED kiosk, reachable by every player, that opened
-- the exact same Jump Upgrade panel every base's own "Jump Upgrade" kiosk
-- already opens — fully redundant with that per-base kiosk, so removed on
-- request ("diesen Separaten Sprung Händler kann man entfernen"). See
-- BaseService.lua's buildStations for the per-base kiosk that still covers
-- this (Cash AND Robux Jump-Upgrade purchases, same as this one did).
-- GameConfig.RobuxTrader itself is gone — the (-85,0,-85) diagonal gap
-- between base plots it used to occupy is simply empty ground now.

-- === GLÜCKSRAD (WHEEL OF FORTUNE) ===============================================
-- A single SHARED kiosk (see BaseService.lua's buildWheelKiosk / WheelService.lua),
-- reachable by every player from any base — walking up and interacting OPENS
-- a panel (see UIBuilder.lua's Wheel panel / init.client.lua's
-- RequestWheelPanel listener) with a visible 3-segment wheel (see Segments
-- below) and three buttons, rather than spinning immediately on interact.
-- Built on request, to give players something to actively do while their
-- passive Cash income slowly builds up between climbs, instead of just
-- standing around waiting.
--
-- Position takes one of the 4 diagonal gaps between base plots — Trade Zone
-- already sits at (85,0,85) (see its own comment above), so this uses
-- (85,0,-85): same 45°-between-plots math, ~120 studs out. (The Robux
-- Jump-Upgrade Trader that used to occupy the (-85,0,-85) gap has since
-- been removed entirely — see that section's own note.)
--
-- THREE buttons in the panel (redesigned from an earlier 2-button "Täglicher
-- Spin" + "Spin kaufen (Robux)" layout, on request, to match a reference
-- screenshot: "Kaufe 1 | Drehen (1) | Kaufe 3"), same Prizes table either
-- way:
--   FREE  (middle "Drehen (1)" button) — mechanically UNCHANGED from
--           before, just restyled into the middle slot of this 3-button
--           row: ONE free spin per real day, CooldownSeconds PERSISTED
--           per-player (data.LastWheelSpinAt, see PlayerDataManager.lua) —
--           unlike a combat cooldown, a free-reward cooldown has to
--           actually survive a rejoin/relog or it's pointless. The button
--           shows a live countdown and is disabled while on cooldown (see
--           WheelService.GetState / the GetWheelState remote, fetched when
--           the panel opens). Never gets the LuckBuff below.
--   ROBUX (left "Kaufe 1" / right "Kaufe 3" buttons) — RobuxProducts below
--           is now TWO separate real Developer Products (split from the
--           earlier single "buy one extra spin" product, on request) —
--           buying either spins that many times in a row (see
--           WheelService.SpinWheelPaid(player, spinCount), called from
--           MonetizationService.ProcessReceipt once Roblox confirms the
--           purchase — the panel learns the result(s) asynchronously via
--           the WheelSpinResult remote, since a Robux purchase can't
--           return synchronously). Paying NEVER touches the free daily
--           cooldown in either direction — it neither costs a free spin
--           nor postpones/advances the next free one, purely an
--           independent extra. Both bought spins ALSO get LuckBuff below
--           automatically ("x2 Glück", on request) — the free spin never
--           does.
--
-- Segments is the WHEEL'S VISUAL layout — REDESIGNED (on request, "3
-- Segmente umbauen") from the original 8 fixed slices down to just 3: Cash,
-- a single rare "Brainrot-Geheimnis" (mystery) slice, and 2x Cash. Index 1 =
-- top of the circle, then clockwise — this exact ORDER (Cash, then
-- BrainrotMystery, then DoubleCash) matches the user's own uploaded wheel
-- artwork (WheelImageAssetId below), which lays Cash out at the top,
-- Brainrot-Geheimnis bottom-right, and 2x Cash bottom-left; it is NOT the
-- order these were originally added in (Cash/DoubleCash/BrainrotMystery)
-- and matters a lot — UIBuilder.PlayWheelSpin points the needle at
-- (index-1)*120°, so this array's order must always match wherever each
-- segment actually sits on whatever artwork is uploaded. The mystery
-- slice's Key is "BrainrotMystery" — see the BrainrotMystery Prize/
-- MysteryRarities below for what it actually grants. Colors are a fallback
-- appearance only used if WheelImageAssetId is ever unset again.
GameConfig.WheelOfFortune = {
	Segments = {
		{ Key = "Cash",            Label = "Cash",                EmojiIcon = "💰", Color = Color3.fromRGB(80, 200, 120) },
		{ Key = "BrainrotMystery", Label = "Mystery-Brainrot",    EmojiIcon = "❓", Color = Color3.fromRGB(160, 90, 220) },
		{ Key = "DoubleCash",      Label = "2x Cash",             EmojiIcon = "🚀", Color = Color3.fromRGB(255, 200, 0) },
	},

	-- Prizes is a weighted table (WheelService.lua's rollPrize) — Weight is a
	-- plain relative weight (doesn't need to sum to 100, just happens to sum
	-- to exactly 100 here since Cash/DoubleCash were specifically pinned to
	-- 60/39.5 and the mystery slice sits on top at 0.5). Three prize Types:
	--   "Cash"            — CashBonusSeconds worth of the player's OWN
	--                       current total passive Cash/sec income, granted
	--                       instantly (see EconomyService.
	--                       GrantCashBonusSeconds). Relative to the player's
	--                       own progress on purpose, so it's never a trivial
	--                       rounding error late-game or a game-breaking
	--                       jackpot early-game. CashBonusSeconds consolidated
	--                       from the old 3-tier 30s/90s/5min split down to a
	--                       single 200s tier (on request, "ein mal Cash ...
	--                       aber so das es ein guter Gewinn ist") — one
	--                       clear "good win" instead of three overlapping
	--                       small/medium/big Cash prizes now that there's
	--                       only one Cash segment on the wheel.
	--   "DoubleCash"      — DurationSeconds of a temporary 2x multiplier on
	--                       ALL passive income (EconomyService.
	--                       GrantTemporaryCashMultiplier), stacks
	--                       multiplicatively with an owned DoubleCash
	--                       gamepass (4x total for whoever has both).
	--   "BrainrotMystery" — a SECOND, independent weighted roll (see
	--                       MysteryRarities below and WheelService.lua's
	--                       rollMysteryRarity) decides which Rarity is
	--                       actually granted, then one free Brainrot of
	--                       that Rarity is picked at random from
	--                       GameConfig.Creatures' matching entries and
	--                       granted exactly like a tower pickup
	--                       (CreatureService.ClaimPhysicalCreature — same
	--                       capacity check, same CreatureObtained popup, no
	--                       separate code path). This replaces the old
	--                       4 separate Gold/Diamond/Hacker/Lava Creature
	--                       Prize entries with a single slice whose own
	--                       odds are shown to the player via a side
	--                       "Brainrot-Geheimnis" info panel (UIBuilder.lua),
	--                       modeled on a reference screenshot the user
	--                       provided of another game's "Kristallrad" /
	--                       "Kristallgeheimnis" mystery-slice pattern.
	-- Cash/DoubleCash Weights are pinned EXACTLY at 60 / 39.5 (on request,
	-- "Genau 60% / 39,5%") with BrainrotMystery adding 0.5 on top, so the
	-- three sum to exactly 100 and Cash/DoubleCash's own per-spin % never
	-- drifts because of the mystery slice. Per-spin odds: Cash 60.00% (1-in-
	-- 1.67), 2x Cash 39.50% (1-in-2.53), Brainrot-Geheimnis 0.50% (1-in-200).
	-- With only 1 free spin/day (CooldownSeconds below), landing the mystery
	-- slice at all is already a ~200-spin (~6.6 months of daily free spins)
	-- grind before the internal Diamond/Galaxy/Hacker/Lava sub-roll even
	-- happens — see MysteryRarities' own comment for those combined odds.
	-- A Robux-paying player reaches it faster, but each attempt still costs
	-- real money, which is its own natural brake against just farming it.
	Position = Vector3.new(85, 0, -85),
	Title = "Glücksrad",
	ActionText = "Drehen",
	EmojiIcon = "🎡",
	AssetIdIcon = "", -- same convention as GameConfig.Base.StationIcons

	-- The wheel PANEL's own artwork (NOT the kiosk's billboard icon above —
	-- that's still AssetIdIcon/EmojiIcon) — a real pie-chart image (6 equal
	-- wedges, one per Segments entry below, same order/angle convention: index
	-- 1 = top/12 o'clock, then clockwise) uploaded via Studio's Asset Manager.
	-- Read by UIBuilder.lua's wheel-panel construction: when this is set
	-- (non-zero), it's used as a single ImageLabel instead of the 6
	-- code-drawn tiles the panel originally shipped with; the tiles remain
	-- as an automatic fallback if this is ever unset again, so the panel
	-- always stays fully functional either way. Same "0/'' = not configured"
	-- convention as every other asset id in this file.
	WheelImageAssetId = 78965395782282,

	CooldownSeconds = 86400, -- 1 free spin per 24h, per player

	-- TWO real Developer Products now (split from the earlier single
	-- "Glücksrad-Dreh" product, on request — "Kaufe 1" / "Kaufe 3") — buying
	-- either fires MonetizationService.ProcessReceipt, which calls
	-- WheelService.SpinWheelPaid(player, SpinCount) that many times in a
	-- row (see that file). Same "0 = not configured yet, button/prompt
	-- stays inert" convention as every other Robux ID in this file. The
	-- first entry reuses the original single-spin product's real, live ID
	-- (it's the direct continuation of that one) — the second (3-pack) is
	-- now also a real Developer Product ("Glücksrad-Dreh" 3x, created in
	-- Studio's Monetization tab, 129 Robux). Both prices are just for
	-- reference here — the actual live price shown on each button is
	-- always fetched fresh via MarketplaceService:GetProductInfo (see
	-- UIBuilder.PopulateWheelState), never read from these comments.
	RobuxProducts = {
		{ ProductId = 3710562407, SpinCount = 1 }, -- "Glücksrad-Dreh" 1x, 49 Robux
		{ ProductId = 3712132789, SpinCount = 3 }, -- "Glücksrad-Dreh" 3x, 129 Robux
	},

	-- "x2 Glück" (on request) — ONLY applies to spins bought through
	-- RobuxProducts above (never the free daily spin, see WheelService.
	-- SpinWheelPaid/performSpin) — doubles JUST the "BrainrotMystery" Prize
	-- row's own Weight for those specific spins (0.5 -> 1.0, i.e. the
	-- Brainrot-Geheimnis chance goes from 0.5% to ~1% for that purchase;
	-- Cash/DoubleCash's own Weights are untouched, so their resulting %
	-- shifts down only slightly as a side effect of the total growing from
	-- 100 to 100.5 — same "relative weights, not fixed percentages"
	-- mechanic as every other weighted table in this file). A plain
	-- multiplier applied ONLY for the duration of that one purchased-spin
	-- roll (not a timed/stored buff) — simplest way to guarantee it can
	-- never accidentally leak into the free spin path or persist stale
	-- across sessions.
	LuckBuff = {
		MysteryWeightMultiplier = 2,
	},

	Prizes = {
		-- Consolidated from the old 30s/90s/5min 3-tier split into a single
		-- "good win" tier (on request) — 200s of the player's own current
		-- Cash/sec, granted instantly.
		{ Type = "Cash", Weight = 60, CashBonusSeconds = 200 },
		-- DurationSeconds stays at 900 (15 min, from the earlier "2x Cash
		-- auf 15 min erhöhen" request) — only the Weight changed here, to
		-- the exact pinned 39.5.
		{ Type = "DoubleCash", Weight = 39.5, DurationSeconds = 900 },
		-- Replaces the old 4 separate Gold/Diamond/Hacker/Lava Creature
		-- prizes — hitting this slice triggers a SECOND, independent
		-- weighted roll over MysteryRarities below to decide which Rarity
		-- is actually granted.
		{ Type = "BrainrotMystery", Weight = 0.5 },
	},

	-- MysteryRarities is the INTERNAL sub-roll used only when the
	-- "BrainrotMystery" Prize above is hit (WheelService.lua's
	-- rollMysteryRarity) — a separate weighted table, same "doesn't need to
	-- sum to 100" mechanic as Prizes, but these particular Weights were
	-- chosen to sum to exactly 100 for easy readability. Combined with the
	-- 0.5% chance of reaching this sub-roll at all (per spin), the resulting
	-- ABSOLUTE per-spin odds are: Diamond 0.385% (1-in-260), Galaxy 0.10%
	-- (1-in-1000), Hacker 0.01% (1-in-10000), Lava 0.005% (1-in-20000).
	-- Shown to the player as a side "Brainrot-Geheimnis" info panel
	-- (UIBuilder.lua) listing each Rarity's OWN internal % (77/20/2/1),
	-- matching the reference "Kristallgeheimnis" pattern the user provided.
	MysteryRarities = {
		{ Rarity = "Diamond", Weight = 77 },
		{ Rarity = "Galaxy",  Weight = 20 },
		{ Rarity = "Hacker",  Weight = 2 },
		{ Rarity = "Lava",    Weight = 1 },
	},
}

-- === SUMMIT (FLOOR 100) ==========================================================
-- Everything specific to the very last floor (GameConfig.Floors.Count) — on
-- request: "Floor 100 möchte ich besonders machen". Two parts, both built in
-- TowerGenerator.lua's floor loop when floorIndex == Floors.Count:
--   1. A distinct look (PlatformColor/Material/TitleText below) — every
--      OTHER floor's appearance just cycles through GameConfig.Obstacles.
--      ZoneEffects by (floor-1)//ZoneSize; Floor 100 overrides that with
--      this fixed golden look instead, so the very top is unmistakable.
--   2. The "Mega-Truhe" — a physical chest, ProximityPrompt-gated like
--      every other kiosk in this game, openable once per REAL day per
--      player (SummitChestService.lua, persisted via PlayerDataManager's
--      LastSummitChestAt — same pattern as the Glücksrad's free daily
--      spin). Gives players who've conquered the tower a genuine reason to
--      keep coming back to Floor 100, instead of just a one-time, silent
--      Hall of Fame entry (see EconomyService.OnFloorReached).
GameConfig.Summit = {
	PlatformColor = Color3.fromRGB(255, 215, 0),
	PlatformMaterial = Enum.Material.Neon,
	TitleText = "Floor 100", -- on request: same plain "Floor N" style every other floor's billboard uses, not a special summit label

	ChestTitle = "Mega-Truhe",
	ChestActionText = "Öffnen",
	ChestCooldownSeconds = 86400, -- 1 opening per 24h, per player — same shape as WheelOfFortune.CooldownSeconds

	-- Each opening has this % chance to grant ONE of the two creatures in
	-- EventCreatureWeights below — deliberately NOT Glitchrot/Singularity,
	-- which stay PURE event-exclusives on purpose (see CreatureRarities'
	-- own comment on them) — this chest is a second, easier-earned path to
	-- Hacker/Lava specifically, not a new way to get the two absolute top
	-- tiers. The other (100 - this)% grants ConsolationCashBonusSeconds
	-- instead, so a "miss" still feels like something after the climb,
	-- never a wasted trip. First pass, please playtest — if a Hacker/Lava a
	-- few times a week feels too easy given how special the Glücksrad and
	-- the weekly Event both treat them, lower this.
	EventCreatureChancePercent = 30,

	-- Within that 30%, which of the two you get is ITSELF weighted (same
	-- "each step up is a real drop, not a coin-flip" principle as the
	-- Glücksrad's Prizes table above) — ~5.7x rarer for Lava than Hacker,
	-- roughly matching their relative LateWeight in the normal drop pool.
	EventCreatureWeights = {
		Hacker = 85,
		Lava = 15,
	},

	-- Noticeably bigger than the Glücksrad's own top Cash prize (300s,
	-- Weight 10 in Prizes above) — this only comes once per REAL day, and
	-- only once Floor 100 has been reached at all.
	ConsolationCashBonusSeconds = 900,

	-- On request: replace the plain gold-Neon Part chest with a real 3D
	-- chest Model (Asset Id 11302807028) — see TowerGenerator.lua's
	-- getSummitChestTemplate for the full "drop it into
	-- ReplicatedStorage.SummitAssets.Chest by hand in Studio" instructions
	-- and why it's not just InsertService:LoadAsset'd by ID at runtime.
	-- These two only affect that real Model (the Part fallback ignores
	-- them entirely, it's always the same fixed Size/CFrame it always was):
	ChestModelScale = 1, -- uniform size multiplier (Model:ScaleTo, or a direct Size multiply if the asset is a lone MeshPart/Part) — 1 = leave the asset at whatever size it was inserted at; raise/lower once you've seen it next to the checkpoint mat in Studio
	ChestModelYOffset = 0, -- extra vertical nudge (studs) on top of the normal placement, in case the asset's own pivot isn't at its base (negative = sink it down, positive = lift it up)
}

-- === PRESTIGE-TURM ================================================================
-- Zweiter Turmabschnitt oberhalb von Floor 100 (Idee aus dem "was kommt in
-- Zukunft"-Brainstorm: "Neue Etagen"). Auf ausdrücklichen Wunsch ("Baue es
-- aber freischaltung erst ab Wiedergeburt 15, damit ich es testen kann,
-- Wiedergeburt 15 wird keiner so schnell bekommen") absichtlich extrem hoch
-- gegated — GameConfig.Rebirth.MaxRebirths ist ebenfalls 15, das ist also
-- praktisch "nur der Ersteller/Tester kommt aktuell rein", nicht "spät im
-- Spiel, aber für jeden erreichbar". Kann später einfach auf einen
-- niedrigeren Wert (z.B. 10, wie ursprünglich besprochen) abgesenkt werden,
-- sobald die 20 neuen Etagen fertig durchgespielt/balanciert sind — nichts
-- anderes hier muss dafür angefasst werden.
--
-- TowerGenerator.Build hängt FloorCount weitere Etagen direkt an
-- GameConfig.Floors.Count an (Floor 101-120) und lässt dafür bewusst
-- JEDE bestehende Floor-Bau-Logik unverändert weiterlaufen (Hindernisse,
-- Fallen, Claim-Spots alle 6 Etagen, Checkpoints alle 5 Etagen, ...). Zwei
-- Dinge sind für floorIndex > Floors.Count bewusst anders: die seitliche
-- Weite (ExtraHorizontalOffset unten) UND jetzt (auf Wunsch, "Tempo-Schuhe
-- entfernen, dafür die Sprunghöhe anpassen") auch wieder die VERTIKALE
-- Sprunghöhe — siehe GameConfig.PrestigeJumpTiers unten und TowerGenerator.
-- getGapForFloor, das für diesen Bereich jetzt eine eigene, höhere
-- Tier-Leiter verwendet statt auf dem Tier-10-Plateau zu bleiben.
GameConfig.Prestige = {
	-- Haupt-Schalter für den gesamten Prestige-Turm (auf Wunsch: "kann ich
	-- die Änderung von Floor 101-120 momentan noch weg lassen, damit kein
	-- Spieler es nutzen kann aber wenn ich will kann ich es aktivieren").
	-- Solange false, baut TowerGenerator.BuildTower NUR die normalen 100
	-- Floors — Floor 101-120 existieren dann als Parts überhaupt nicht, es
	-- gibt also nichts, was ein Spieler erreichen könnte, egal wie stark
	-- seine Sprung-Upgrades schon sind. Das ist eine STÄRKERE Absicherung
	-- als das Wiedergeburts-Gate unten (UnlockRebirths) allein — das Gate
	-- greift zusätzlich, SOBALD dieser Schalter auf true steht. Einfach auf
	-- true setzen und in Studio neu veröffentlichen/den Server neu starten,
	-- sobald es losgehen soll (der Turm wird nur einmal beim Serverstart
	-- gebaut — ein reiner Laufzeit-Toggle ohne Neustart würde die neuen
	-- Floors nicht nachträglich erscheinen lassen).
	Enabled = false,

	-- War 15 (== MaxRebirths, "damit es keiner so schnell bekommt"), auf
	-- Wunsch auf 12 gesenkt — bleibt aber weiterhin ein ZUSÄTZLICHES Gate
	-- neben den jetzt viel teureren PrestigeJumpTiers unten: wer Floor 101
	-- überhaupt betreten darf, MUSS trotzdem noch die neuen, extrem teuren
	-- Sprung-Stufen erklimmen, um wirklich hochzukommen — zwei Hürden statt
	-- einer (siehe EconomyService.OnFloorReached für die Wiedergeburts-
	-- Prüfung, GameConfig.PrestigeJumpTiers für die Kosten-Hürde). Greift
	-- nur, wenn Enabled oben auch true ist.
	UnlockRebirths = 12,
	FloorCount = 20, -- Floor 101 .. 120

	-- Zusätzlich zur normalen (bereits bei Floor 100 plateauenden)
	-- HorizontalOffset/LateSpread-Weite kommt HIER noch mal extra Distanz
	-- oben drauf, NUR für floorIndex > Floors.Count (siehe TowerGenerator.
	-- getHorizontalOffsetForFloor) — auf ausdrücklichen Wunsch beibehalten,
	-- AUCH nachdem die Tempo-Schuhe (die ursprünglich genau dafür gedacht
	-- waren) wieder entfernt wurden: die neuen, höheren PrestigeJumpTiers
	-- unten geben genug JumpPower, um sowohl die größere Höhe als auch diese
	-- zusätzliche Weite abzudecken — beide Schwierigkeiten kombiniert, wie
	-- gewünscht ("Nein, behalten — zusätzlich zur Höhe").
	ExtraHorizontalOffset = 14,

	-- Eigener, dunkler Look ab Floor 101, damit der Übergang vom Hauptturm
	-- sofort sichtbar ist (siehe TowerGenerator's getZoneColor/Build).
	FloorColor = Color3.fromRGB(45, 15, 70),
	FloorMaterial = Enum.Material.Neon,
}

-- === PRESTIGE-TURM SPRUNG-UPGRADE (Tier 11-20) ====================================
-- Ersetzt die entfernten Tempo-Schuhe ("das mit dem Tempo-Schuhe-Händler
-- funktioniert nicht so wie ich das will, können wir das entfernen und
-- dafür die Sprunghöhe anpassen") — 10 weitere, deutlich teurere
-- JumpTiers-Stufen (Level 11-20), die EconomyService an die bestehenden 10
-- (GameConfig.JumpTiers) direkt drangehängt als EINE durchgehende Kurve
-- behandelt (siehe EconomyService's ALL_JUMP_TIERS) — das bestehende
-- Sprung-Upgrade-Panel im Spiel reicht dadurch automatisch bis Tier 20,
-- ganz ohne neues UI/neuen Händler.
--
-- GameConfig.JumpTiers selbst bleibt UNVERÄNDERT (Tier 1-10, Floor 1-60
-- Tuning) — exakt dasselbe Prinzip wie bandSize=6 in TowerGenerator, das
-- absichtlich nicht von der Floor-Anzahl abhängt: eine bestehende, schon
-- durchgespielte Kurve nie rückwirkend verändern, neue Stufen immer nur
-- ANHÄNGEN.
--
-- Gap-Werte setzen NICHT bei Tier 10s rohem Gap (102) fort, sondern beim
-- tatsächlichen Floor-100-Höchstwert (102 + LateHeightBoostMaxExtraGap 260
-- = 362, siehe GameConfig.Floors) — sonst würde Floor 101 mit Tier 11
-- plötzlich LEICHTER werden als Floor 90-100 es mit dem alten Boost-System
-- schon waren, ein Rückschritt in der Schwierigkeit statt einer Steigerung.
-- JumpPower/Gap-Verhältnis bleibt ungefähr im Rahmen der ersten 10 Stufen.
-- Kosten (vor GameConfig.JumpUpgrade.CostMultiplier, der weiterhin auf ALLE
-- Stufen inkl. dieser hier angewendet wird) wachsen deutlich schneller als
-- bei Tier 1-10, in der Größenordnung von GameConfig.Rebirth.Costs' oberen
-- Stufen — genau der Wunsch "teurer machen damit es länger dauert sie zu
-- erklimmen". Erster Entwurf, bitte nach dem ersten Testen (mit "/rebirth
-- 12" + der bestehenden Sprung-Upgrade-Kiosk) feinjustieren — ich kann die
-- tatsächliche Sprungphysik hier nicht selbst testen.
-- Gap-Werte für Tier 14-20 ZUM ZWEITEN MAL angehoben (on request, "ich
-- schaffe Floor 120 mit 557 Jumps" — daraufhin wurden die Gaps unten schon
-- einmal angehoben, aber bewusst NICHT voll quadratisch, siehe die alte
-- Fassung dieses Kommentars weiter unten in der Versionsgeschichte). Echter
-- Playtest danach bestätigte: mit 348 Sprung-Punkten (interpoliertes
-- JumpPower ≈1030, siehe EconomyService.getJumpStatsAtPoint — das liegt
-- zwischen Tier 18 und 19, NICHT bei Tier 20s 1195) kam der Spieler immer
-- noch bis Floor 119/120 (Gap 1550) durch — genau die schon damals als
-- "nicht hundertprozentig perfekt" angekündigte Restlücke, jetzt real
-- reproduziert. Auf Wunsch ("Lücke voll schließen (quadratisch)") jetzt die
-- vollständig quadratische Variante, die damals absichtlich noch
-- zurückgehalten wurde.
--
-- Herleitung: Tier 11-13 bleiben UNVERÄNDERT (wie beim ersten Anheben) —
-- Tier 13 (JumpPower 565, Gap 445) ist der Ankerpunkt, an den Tier 14-20
-- jetzt mit einer echten quadratischen Kurve anschließen: Gap = k ×
-- JumpPower², mit k = 445 / 565² ≈ 0,0013940 (aus Tier 13 selbst
-- errechnet, NICHT aus der rohen Physik-Formel — Letztere hätte laut der
-- Ur-Kommentierung von JumpTiers oben ohnehin schon bei Tier 1-10
-- systematisch daneben gelegen, da echte Sprünge mit Anlauf weiter tragen
-- als die reine Scheitelhöhen-Formel). Das ergibt (gerundet):
--   Tier 14 (640² × k ≈ 571) -> 570
--   Tier 15 (720² × k ≈ 723) -> 725
--   Tier 16 (805² × k ≈ 903) -> 905
--   Tier 17 (895² × k ≈ 1116) -> 1115
--   Tier 18 (990² × k ≈ 1366) -> 1365
--   Tier 19 (1090² × k ≈ 1656) -> 1655
--   Tier 20 (1195² × k ≈ 1991) -> 1990
-- Damit wächst das Gap/JumpPower-Verhältnis DURCHGEHEND linear mit
-- JumpPower selbst (0,89 bei Tier 14 bis 1,67 bei Tier 20, statt vorher
-- 0,86 bis 1,3) — jede Stufe braucht jetzt spürbar mehr als nur knapp die
-- Vorstufe, die alte "Tier 13 reicht rechnerisch bis fast Tier 16"-Lücke
-- ist damit geschlossen: mit Tier 13s eigenem JumpPower (565) reicht die
-- Formel jetzt exakt nur noch bis Tier 13s eigenes Gap (445, also GAR
-- NICHT weiter als die eigene Stufe) — dieselbe Rechnung gilt für jede
-- andere Stufe der neuen Kurve.
--
-- WICHTIG: Die genaue Schwerkraft-Konstante (Workspace.Gravity) steht nicht
-- im synchronisierten Code — das ist reine Studio-Einstellung, wie das
-- Bloom-Licht. Die Rechnung oben nutzt Robloxs Standardwert (196.2) als
-- Näherung; falls euer Workspace davon abweicht, verschieben sich die
-- tatsächlichen Grenzen etwas. Bitte nach dem Sync unbedingt in Studio
-- gegentesten, ob sich Floor 101-120 jetzt wieder wie gedacht anfühlt —
-- reine Sprungphysik/Spielgefühl kann ich von hier aus nicht prüfen. Falls
-- Tier 14-20 jetzt zu hart wirken (die Kurve wurde bewusst so eng wie
-- mathematisch möglich an Tier 13 angeschlossen, ganz ohne Sicherheitsmarge),
-- sag einfach welche Stufe(n) — ein Gap-Wert hier ist immer noch ein
-- One-Line-Fix.
GameConfig.PrestigeJumpTiers = {
	{ Level = 11, Cost = 40000000,     JumpPower = 430,  Gap = 380,  Name = "Void-Stiefel" },
	{ Level = 12, Cost = 95000000,     JumpPower = 495,  Gap = 410,  Name = "Nebel-Läufer" },
	{ Level = 13, Cost = 230000000,    JumpPower = 565,  Gap = 445,  Name = "Kometen-Kicks" },
	{ Level = 14, Cost = 550000000,    JumpPower = 640,  Gap = 570,  Name = "Meteor-Stampfer" },
	{ Level = 15, Cost = 1300000000,   JumpPower = 720,  Gap = 725,  Name = "Quasar-Springer" },
	{ Level = 16, Cost = 3000000000,   JumpPower = 805,  Gap = 905,  Name = "Nova-Stelzen" },
	{ Level = 17, Cost = 7000000000,   JumpPower = 895,  Gap = 1115, Name = "Pulsar-Treter" },
	{ Level = 18, Cost = 16000000000,  JumpPower = 990,  Gap = 1365, Name = "Blackhole-Boots" },
	{ Level = 19, Cost = 37000000000,  JumpPower = 1090, Gap = 1655, Name = "Urknall-Absätze" },
	{ Level = 20, Cost = 85000000000,  JumpPower = 1195, Gap = 1990, Name = "Singularitäts-Sohlen" },
}

-- === FAST TRAVEL ==================================================================
-- A single SHARED kiosk (see BaseService.lua's buildFastTravelKiosk /
-- FastTravelService.lua) that opens a panel offering a paid Robux teleport
-- straight to any of the 4 checkpoint floors below — on request: "Fast
-- Travel für jeden 25 Floor bis 100, mit Robux zu zahlen, nur wenn man
-- diesen Floor schon erreicht hat, Kosten abhängig von der Floor Höhe".
-- Each entry needs its OWN real Developer Product (a fixed Robux price can't
-- be set dynamically per player from a script) — RobuxCost here is a
-- reference/display value, the ACTUAL price charged is whatever that
-- ProductId is configured to cost in Studio, so keep them matching. All 4
-- floors (25/50/75/100) are already real checkpoint floors (i % 5 == 0, see
-- TowerGenerator.lua's isCheckpointFloor) — the teleport lands the player
-- exactly on that floor's own checkpoint Part and updates their
-- player.RespawnLocation to it too, so a death shortly after doesn't send
-- them all the way back to Floor 1.
--
-- The "nur wenn man diesen Floor schon erreicht hat" part is enforced BOTH
-- client-side (see UIBuilder.lua's Fast Travel panel — a row's Buy button
-- only shows once lastData.HighestFloor >= that Floor, same "hide, don't
-- reject" convention as every other Robux button in this file, purely for a
-- clean UI) AND, since a security review, for real server-side too
-- (FastTravelService.Teleport checks data.HighestFloor itself before
-- teleporting — on request: "jeder soll die Floor schon erreicht haben
-- bevor es freigeschaltet wird"). Roblox still requires every COMPLETED
-- purchase to be marked Granted regardless (MonetizationService.
-- ProcessReceipt can't silently eat a real payment) — the server-side check
-- can only withhold the TELEPORT itself if the client's hidden-button gate
-- was somehow bypassed, never refund/block the actual Robux charge.
GameConfig.FastTravel = {
	Position = Vector3.new(-85, 0, 85), -- one of the 4 diagonal gaps between the base plots — Trade Zone (85,85) and the Glücksrad (85,-85) take two others (see their own comments); (-85,-85), the 4th, is empty ground now that the Robux Jump-Upgrade Trader that used to sit there has been removed
	Title = "Fast-Travel",
	ActionText = "Öffnen",
	EmojiIcon = "🚀",
	AssetIdIcon = "",

	Checkpoints = {
		{ Floor = 25,  RobuxCost = 10, ProductId = 3711410009 },
		{ Floor = 50,  RobuxCost = 15, ProductId = 3711410055 },
		{ Floor = 75,  RobuxCost = 25, ProductId = 3711410078 },
		{ Floor = 100, RobuxCost = 99, ProductId = 3711410124 },
	},
}

-- Shared "Gefällt mir"-Stand (on request, "einen Stand ... wo man Gefällt
-- mir/Likes für das Spiel abgeben kann") — sits on the 4th diagonal gap
-- (-85,0,-85), the one spot still empty since the old Robux Jump-Upgrade
-- Trader was removed (see GameConfig.FastTravel's own Position comment
-- above). Same "fake plotCFrame on its own small platform" kiosk as
-- WheelOfFortune/FastTravel (see BaseService.buildLikeKiosk).
--
-- IMPORTANT: Roblox does not expose any API to trigger the REAL Like button
-- on the experience's own game page from inside the game itself (checked —
-- GuiService has no such method, and nothing else does either), so this can
-- only ever be an in-game reminder, never a real functional Like button. On
-- request ("Nur Hinweistext"), it's ALSO not an in-game like-counter —
-- purely a sign plus a short popup when a player walks onto it, nothing
-- gets stored/tracked anywhere.
GameConfig.LikeStation = {
	Position = Vector3.new(-85, 0, -85),
	Title = "Gefällt mir",
	ActionText = "",
	EmojiIcon = "❤️",
	AssetIdIcon = "",
	HintText = "Gefällt dir das Spiel? Gib uns ein Like! ❤️",
	PopupText = "❤️ Danke fürs Spielen! Wenn es dir gefällt, lass uns gerne ein Like auf der Spielseite da.",
}

-- Friendship Cash-Boost (on request, "10% Freundschafts Boost ... wenn man
-- mit Freunden spielt, solange der Freund oder die Freunde da sind") —
-- counts REAL Roblox friends (Player:IsFriendsWith) currently in the SAME
-- server. FirstFriendBonus applies once at least one such friend is
-- present; AdditionalFriendBonus is added ON TOP for each further friend
-- beyond the first (on request, "erster 10% jeder weitere 5%") — so 1
-- friend = +10%, 2 friends = +15%, 3 friends = +20%, and so on. Read by
-- EconomyService's getCashMultiplierFactor, added into the same additive
-- bucket as the VIP gamepass / Brainrot-Dex completion bonuses (stacks with
-- everything else there). The boost is recalculated only on player
-- join/leave (see EconomyService.RecalculateFriendBoosts, called from
-- init.server.lua's PlayerAdded/PlayerRemoving), NOT on every payout tick —
-- Player:IsFriendsWith is a real API call, and with GameConfig.Base.
-- MaxPlayers capped at 4 there's never more than 4x4 = 16 checks per
-- join/leave anyway, so no throttling concerns either way.
GameConfig.FriendBoost = {
	FirstFriendBonus = 0.10,
	AdditionalFriendBonus = 0.05,
}

-- === DATASTORE ==================================================================
-- Bumping the version suffix (v1 -> v2 -> v3 ...) is how you reset EVERY
-- player's saved data at once — it just points the whole game at a brand
-- new, empty DataStore, so PlayerDataManager.Load finds nothing saved and
-- falls back to DEFAULT_DATA for everyone (yourself included). The old data
-- under the previous name isn't deleted, just no longer read by anything —
-- Roblox has no "delete a DataStore" button, but an unused one costs nothing
-- and can't be seen by players either way.
-- IMPORTANT: after changing this, you have to re-publish the game (File >
-- Publish to Roblox) for the live server to pick it up — Studio Play-test
-- picks it up immediately, no publish needed there.
GameConfig.DataStore = {
	-- Bumped v4 -> v5 on request ("Spiel komplett zurücksetzen, neue
	-- Version") — every player starts completely fresh (Floor 1, 0 Cash,
	-- keine Brainrots) the next time they join, since GetAsync on this new
	-- name finds nothing and falls back to DEFAULT_DATA (see
	-- PlayerDataManager.Load). The old v4 data isn't deleted, just no
	-- longer read by anything — same "bump to reset" trick as always.
	Name = "GoUpBrainrot_PlayerData_v5",

	-- On request ("ein Spieler hat sich vom PC auf dem Handy eingeloggt und
	-- den aktuellen Speicherstand verloren") — PlayerDataManager.Save used
	-- to only ever run on PlayerRemoving/BindToClose, so a session that
	-- never closes cleanly (a crash, or a SECOND session on another device
	-- overwriting this one before it ever got to save) could lose an
	-- entire play session's worth of progress. PlayerDataManager.
	-- StartPeriodicAutoSave now also saves every online player on this
	-- interval, shrinking that exposure window down to a few minutes
	-- instead of "the whole session". NOTE: this does NOT by itself
	-- prevent two simultaneous sessions for the same account from
	-- overwriting each other (Save is still a blind SetAsync, not a
	-- session-locked merge) — it only makes losing an unsaved chunk of
	-- progress far less likely and far smaller when it does happen.
	AutoSaveIntervalSeconds = 180,

	-- Separate stores for the GLOBAL (cross-server) Hall of Fame — see
	-- LeaderboardService.lua. Kept apart from the per-player save above on
	-- purpose: these are written on a totally different rhythm (a periodic
	-- all-online-players sync, not each player's own join/leave), and the
	-- ranked lists need an OrderedDataStore (numbers only, sortable) while
	-- the roster is a plain DataStore (a growing list of names). Same
	-- "bump the name to reset" trick as Name (above, GoUpBrainrot_PlayerData_v4)
	-- works here too if the leaderboard data ever needs a clean wipe.
	-- All 4 also bumped alongside Name above, same "komplett zurücksetzen"
	-- request — the global Hall of Fame/leaderboards start completely
	-- empty again too, no old high scores from the previous version
	-- carrying over.
	LeaderboardRebirthsName = "GoUpBrainrot_LB_Rebirths_v3",
	LeaderboardCashName = "GoUpBrainrot_LB_Cash_v3",
	LeaderboardRosterName = "GoUpBrainrot_LB_Roster_v3",
	-- On request ("statt der Anzeige wer Floor 100 erreicht hat eine
	-- Rangliste für Cash/s, serverübergreifend") — same OrderedDataStore
	-- shape as LeaderboardRebirthsName/LeaderboardCashName above, just
	-- storing EconomyService.GetCreatureCashRates' own total (a player's
	-- current income rate) instead of Rebirths or lifetime Cash.
	LeaderboardCashPerSecondName = "GoUpBrainrot_LB_CashPerSecond_v2",
}

-- === GLOBAL HALL OF FAME / LEADERBOARD ========================================
-- "Eine Hall of Fame ... auch ein Ranking wer hat wieviel Floors, Geld
-- insgesamt, alles server-übergreifend, in der Mitte bei dem Turm" — see
-- LeaderboardService.lua for the actual DataStore/board logic; everything
-- here is just the tunable numbers.
GameConfig.Leaderboard = {
	-- On request ("die Bestenliste ... kann von Top1 bis Top 200 runter
	-- scrollen" -> "begrenze es auf top 100") — raised from the original 10
	-- to 100 once the physical board's plain-text signs were replaced by the
	-- scrollable/paged Leaderboard panel (see LeaderboardService.GetPanelData
	-- / UIBuilder's Leaderboard panel). GetSortedAsync's own page size cap is
	-- 100, so this is also the largest value that still fits in a SINGLE
	-- DataStore page per category per periodic refresh — anything higher
	-- would need extra GetSortedAsync/AdvanceToNextPageAsync calls just for
	-- the regular refresh, not only for the "find my own rank" search below.
	TopCount = 100,
	HallOfFameDisplayCount = 15, -- how many Floor-100 names the board shows at once (newest first) — the full roster (see HallOfFameMaxStored) can be bigger than this, the sign just shows the most recent climbers plus a "+X weitere" line
	HallOfFameMaxStored = 500,   -- hard cap on the roster DataStore entry itself (oldest dropped past this) — keeps that one DataStore value comfortably small even after years of play; 500 conquerors is far more than this prototype will ever realistically need

	-- How often each server pushes its online players' current Rebirths/
	-- LifetimeCashEarned and re-fetches the global Top-100 lists. Deliberately
	-- infrequent (a handful of DataStore calls every few minutes, not per
	-- player per second) to stay well inside Roblox's per-minute DataStore
	-- request budget.
	SyncIntervalSeconds = 180,

	-- On request ("man kann ja den jeweiligen Spieler unten einblenden der
	-- gerade schaut und seine Position einblenden") — when the VIEWING
	-- player isn't in the cached Top 100 (the common case), the Leaderboard
	-- panel looks a little further to find their real rank instead of just
	-- shrugging. RankSearchExtraPages is how many ADDITIONAL 100-entry
	-- DataStore pages to page through beyond the already-cached Top 100 (so
	-- 4 here means ranks up to 500 total are searchable) — this is real,
	-- on-demand DataStore cost (GetSortedAsync + AdvanceToNextPageAsync), so
	-- it's deliberately bounded rather than paging all the way down a
	-- potentially huge player base every time someone opens the panel.
	-- Anyone ranked beyond that window just shows their own live value with
	-- no exact rank number ("außerhalb Top 500") instead of nothing at all.
	RankSearchExtraPages = 4,
	-- Per player+category cooldown on that extended search (see
	-- LeaderboardService.GetOwnStanding) — repeatedly opening/closing the
	-- panel can't re-trigger the expensive multi-page search more often than
	-- this; a cached previous result is reused in between.
	RankSearchCooldownSeconds = 60,

	-- Physical board placement, relative to the tower's own center (0,0) —
	-- see LeaderboardService.BuildBoard's comment for why this specific
	-- radius is safe (clear of every low floor's spiral footprint) and
	-- BaseService.getPlotCFrame for why this angle (diagonally between two
	-- base plots, not directly on anyone's walking path to their own base).
	BoardRadius = 35,
	BoardAngleDegrees = 135,
	BoardSpacing = 14, -- studs between the 3 sign centers
	SignWidth = 12,
	SignHeight = 9,
	SignThickness = 1,
}

return GameConfig
