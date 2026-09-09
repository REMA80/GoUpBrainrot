--[[
	AdminAbuseService.lua
	Zwei GETRENNTE Dinge, die früher beide an ein und denselben "/adminabuse"-
	Schalter gekoppelt waren, auf Wunsch jetzt entkoppelt ("die Glücks Truhen
	immer spawnen als Beschäftigung auch ohne Event"):

	1. Die "Glücks-Truhen" — PERMANENT, ab Serverstart (siehe
	   StartPermanentChests, aufgerufen einmal aus init.server.lua). Laufen
	   IMMER, unabhängig davon, ob gerade ein Admin-Abuse-Fenster aktiv ist.
	   GameConfig.AdminAbuse.ChestCount Stück, zufällig verteilt auf schon
	   gebauten Turm-Etagen (TowerGenerator.GetRandomFloorPlatform), die beim
	   Einsammeln entweder eine seltene Kreatur oder einen Cash-Bonus geben
	   (gleiches "relativ zum eigenen Einkommen"-Prinzip wie
	   SummitChestService/WheelService) und nach ChestLifetimeSeconds von
	   selbst verschwinden, wenn niemand sie holt — verschwundene/
	   eingesammelte Truhen werden nach ChestRespawnDelaySeconds an einer
	   neuen zufälligen Etage ersetzt, für immer.

	2. Das eigentliche "Admin Abuse"-EVENT — weiterhin nur manuell per
	   "/adminabuse <Minuten>" (siehe init.server.lua), nachgebaut nach dem
	   "Admin Abuse"-Event aus Steal a Brainrot. Schaltet für eine begrenzte
	   Zeit zwei Dinge auf einmal ein, beide an EventService.
	   SetAdminAbuseActive gekoppelt, sodass sie garantiert gemeinsam an- und
	   ausgehen:
	     a. EventService.SetAdminAbuseActive(seconds) — schaltet denselben
	        EventOnly-Drop-Boost frei, den das wöchentliche GameConfig.Event
	        nutzt (CreatureService.rollEventCreature prüft nur EventService.
	        IsActive(), nicht WARUM es gerade aktiv ist).
	     b. Eine rötliche Lighting-Änderung fürs ganze Spiel (GameConfig.
	        AdminAbuse.SkyColor/AmbientColor), die beim Ende exakt auf die
	        Werte zurückgesetzt wird, die beim Start herrschten.
	   Zusätzlich beeinflusst dieses Event ganz nebenbei auch die PERMANENTEN
	   Glücks-Truhen von oben: grantChestReward unten fragt EventService.
	   IsAdminAbuseActive() ab und benutzt währenddessen die höhere
	   GameConfig.AdminAbuse.EventChestCreatureChancePercent statt der
	   normalen (bewusst schlechteren, auf Wunsch: "die Spawnrate der
	   Brainrots soll schlechter sein") BaseChestCreatureChancePercent — so
	   bleibt das manuelle Event trotzdem etwas Besonderes, ohne dass die
	   Truhen selbst daran gekoppelt sein müssen.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local AdminAbuseService = {}

local EconomyService
local CreatureService
local EventService
local TowerGenerator
local remotesFolder

function AdminAbuseService.Init(deps)
	EconomyService = deps.EconomyService
	CreatureService = deps.CreatureService
	EventService = deps.EventService
	TowerGenerator = deps.TowerGenerator
	remotesFolder = deps.Remotes
end

-- Runtime state.
--
-- `running` is this module's OWN "is an Admin-Abuse EVENT window active"
-- flag (drives Lighting + the Notice text) — kept separate from
-- EventService.IsAdminAbuseActive() so nothing here has to guess whether a
-- true from that function came from THIS event or a coincidental overlap
-- with the unrelated weekly GameConfig.Event window. Reset by Stop().
--
-- `chestsRunning` is a SEPARATE, permanent flag for the Glücks-Truhen loop
-- (see StartPermanentChests below) — on request, the chests no longer stop
-- just because the Admin-Abuse event ends, so this is set once at server
-- start and never cleared again. Kept as its own flag (rather than reusing
-- `running`) purely so spawnChest/scheduleNextChest's existing "only keep
-- the respawn chain going while still wanted" guard still reads naturally,
-- without implying the chests are somehow tied to the event.
local running = false
local chestsRunning = false
local originalLighting = nil -- captured right before Start() changes anything, restored by Stop()

local function broadcastNotice(message)
	if not remotesFolder then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		remotesFolder.Notice:FireClient(player, message)
	end
end

-- Same shape as SummitChestService/WheelService's own local copy — picks a
-- random named creature (GameConfig.Creatures) matching the given Rarity.
-- Deliberately its own local copy rather than a shared helper, matching how
-- every other service here already keeps its own (see SummitChestService
-- .lua's comment on why).
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
-- those two already follow. On request: the chest's own Cash-bonus Notice
-- below used to print one long unreadable raw digit string at high
-- Rebirth ("+107717538200 Cash!") — this abbreviates it to "+107,7B Cash!"
-- instead, below 1000 it's still a plain integer.
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

-- Rolls ONE reward and grants it to `player` — either a random creature from
-- GameConfig.AdminAbuse.ChestCreatureRarities, or (more often, and always as
-- the fallback if no matching creature exists) a relative Cash bonus, same
-- "consolation" pattern as SummitChestService.Open.
--
-- Which of the two creature-chance configs applies depends on whether an
-- actual "/adminabuse" window is running right now (EventService.
-- IsAdminAbuseActive(), NOT this module's own `running` — same distinction
-- as everywhere else in this file) — the permanent baseline chests (see
-- StartPermanentChests) use the lower BaseChestCreatureChancePercent, an
-- active Admin-Abuse event temporarily bumps it up to
-- EventChestCreatureChancePercent. See GameConfig.AdminAbuse's own comment
-- for why there are two values now instead of one.
local function grantChestReward(player)
	local creatureChance = EventService.IsAdminAbuseActive()
		and GameConfig.AdminAbuse.EventChestCreatureChancePercent
		or GameConfig.AdminAbuse.BaseChestCreatureChancePercent

	local roll = math.random() * 100
	if roll <= creatureChance then
		local rarities = GameConfig.AdminAbuse.ChestCreatureRarities
		local rarity = rarities[math.random(1, #rarities)]
		local def = pickRandomCreatureOfRarity(rarity)
		if def then
			local granted = CreatureService.ClaimPhysicalCreature(player, def)
			if granted and remotesFolder then
				remotesFolder.Notice:FireClient(
					player,
					"🎁 Glücks-Truhe: " .. def.Name .. " (" .. rarity .. ") gewonnen!"
				)
			end
			-- Base voll: ClaimPhysicalCreature hat schon selbst eine Notice
			-- geschickt — hier keine zweite, widersprüchliche hinterher.
			return
		end
		-- Falsch konfigurierte Rarity (kein passender GameConfig.Creatures-
		-- Eintrag) — fällt durch zum Cash-Trostpreis unten statt gar nichts
		-- zu geben.
	end

	local bonus = EconomyService.GrantCashBonusSeconds(player, GameConfig.AdminAbuse.ChestCashBonusSeconds)
	if remotesFolder then
		remotesFolder.Notice:FireClient(player, "🎁 Glücks-Truhe: +" .. formatCashShort(bonus) .. " Cash!")
	end
end

-- spawnChest und scheduleNextChest rufen sich gegenseitig auf (eine Truhe
-- weg -> nach Verzögerung eine neue -> die wieder weg -> ...), daher hier
-- vorab deklariert.
local scheduleNextChest
local spawnChest

-- Baut EINE physische Truhe auf einer zufälligen Etagen-Plattform, verdrahtet
-- ihren ProximityPrompt (Custom-Style — siehe CustomPromptUI.client.lua, das
-- für JEDEN Custom-Style-Prompt automatisch die Kreis+Text-GUI baut, hier
-- also ganz ohne eigenen Aufwand) und plant sowohl ihr Verschwinden nach
-- Ablauf der Lebenszeit als auch (über removeChest -> scheduleNextChest)
-- ihren Ersatz anderswo — aber nur solange `chestsRunning` noch true ist.
-- Seit die Truhen permanent laufen, wird das in der Praxis nie mehr false
-- (nichts ruft das je zurück), der Guard bleibt aber als Sicherheitsnetz
-- stehen, genau wie er es schon vor der Umstellung war.
spawnChest = function()
	if not chestsRunning then
		return
	end

	local platform = TowerGenerator.GetRandomFloorPlatform()
	if not platform then
		return
	end

	local chest = Instance.new("Part")
	chest.Name = "AdminAbuseChest"
	chest.Shape = Enum.PartType.Block
	chest.Size = Vector3.new(3, 2.2, 2)
	chest.Anchored = true
	chest.CanCollide = false
	chest.Material = Enum.Material.Neon
	-- On request ("grelle Lichter sind immer noch zu stark", dann konkret
	-- die Glücks-Truhe selbst als Beispiel genannt) — softened the same way
	-- as every other Neon surface in the game (see BaseService.
	-- buildStationPart's own comment). Was bisher völlig ungedimmtes
	-- Vollgelb + eine der stärksten PointLights im ganzen Spiel.
	chest.Color = Color3.fromRGB(255, 200, 40):Lerp(Color3.new(1, 1, 1), 0.45)
	chest.Transparency = 0.2
	chest.CFrame = platform.CFrame * CFrame.new(0, GameConfig.Floors.Size.Y / 2 + 1.6, 0)
	chest.Parent = platform

	local light = Instance.new("PointLight")
	light.Color = chest.Color
	light.Range = 8
	light.Brightness = 1.5
	light.Parent = chest

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ChestLabel"
	billboard.Size = UDim2.new(0, 150, 0, 36)
	billboard.StudsOffset = Vector3.new(0, 2.2, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = chest

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "🎁 Glücks-Truhe"
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = billboard

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Öffnen"
	prompt.ObjectText = "Glücks-Truhe"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = GameConfig.AdminAbuse.ChestPickupRadius
	prompt.RequiresLineOfSight = false
	-- Custom statt Default: kein rechteckiges Prompt-Kästchen, siehe
	-- CustomPromptUI.client.lua, das das automatisch für jeden Custom-Style-
	-- Prompt im Spiel übernimmt.
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = chest

	-- chest.Parent selbst ist die "schon entfernt?"-Prüfung (Destroy setzt
	-- es automatisch auf nil) — kein zentrales activeChests-Tracking mehr
	-- nötig, seit Stop() die Truhen nicht mehr einsammelt/zerstört (siehe
	-- StartPermanentChests' Kommentar): jede Truhe verwaltet ihren eigenen
	-- Lebenszyklus jetzt komplett für sich.
	local function removeChest()
		if not chest.Parent then
			return
		end
		chest:Destroy()
		scheduleNextChest()
	end

	-- Zusätzliche Wächter-Variable gegen zwei Spieler, die (theoretisch)
	-- praktisch gleichzeitig triggern — gleiches Prinzip wie der "busy"-Guard
	-- bei den Turm-Claim-Spots (TowerGenerator.lua).
	local claimed = false
	prompt.Triggered:Connect(function(triggeringPlayer)
		if claimed then
			return
		end
		claimed = true
		grantChestReward(triggeringPlayer)
		removeChest()
	end)

	task.delay(GameConfig.AdminAbuse.ChestLifetimeSeconds, function()
		if not claimed then
			removeChest()
		end
	end)
end

scheduleNextChest = function()
	if not chestsRunning then
		return
	end
	task.delay(GameConfig.AdminAbuse.ChestRespawnDelaySeconds, spawnChest)
end

local function applyLighting()
	originalLighting = {
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		ColorShiftTop = Lighting.ColorShift_Top,
		ColorShiftBottom = Lighting.ColorShift_Bottom,
	}

	Lighting.Ambient = GameConfig.AdminAbuse.AmbientColor
	Lighting.OutdoorAmbient = GameConfig.AdminAbuse.OutdoorAmbientColor
	Lighting.ColorShift_Top = GameConfig.AdminAbuse.SkyColor
	Lighting.ColorShift_Bottom = GameConfig.AdminAbuse.SkyColor
end

local function revertLighting()
	if not originalLighting then
		return
	end
	Lighting.Ambient = originalLighting.Ambient
	Lighting.OutdoorAmbient = originalLighting.OutdoorAmbient
	Lighting.ColorShift_Top = originalLighting.ColorShiftTop
	Lighting.ColorShift_Bottom = originalLighting.ColorShiftBottom
	originalLighting = nil
end

function AdminAbuseService.IsRunning()
	return running
end

-- Kicks off the PERMANENT Glücks-Truhen loop — call exactly ONCE, from
-- init.server.lua, right after TowerGenerator.Build has actually run (chests
-- need TowerGenerator.GetRandomFloorPlatform to return a real platform, so
-- calling this any earlier would just silently spawn nothing — spawnChest
-- already guards against a nil platform, but there'd be no floors to pick
-- from yet at all). On request ("die Glücks Truhen immer spawnen als
-- Beschäftigung auch ohne Event"): this has NOTHING to do with Start/Stop
-- below anymore — the chests run for the rest of the server's life,
-- completely independent of whether an Admin-Abuse event is ever triggered.
function AdminAbuseService.StartPermanentChests()
	if chestsRunning then
		return -- already running — e.g. called twice by mistake
	end
	chestsRunning = true
	for _ = 1, GameConfig.AdminAbuse.ChestCount do
		spawnChest()
	end
end

-- Called from init.server.lua's "/adminabuse <Minuten>" chat command.
-- `triggeringPlayer` is only used for the broadcast Notice ("von X
-- aktiviert"), not for any permission check — init.server.lua already did
-- that (same "/event on"-Muster: nur Studio oder game.CreatorId) BEVOR es
-- hierher überhaupt aufruft.
--
-- No longer touches the Glücks-Truhen at all (see StartPermanentChests
-- above) — just the seltene-Drops-Boost + Lighting + Notice. A currently
-- active Admin-Abuse window DOES still raise the chests' own creature
-- chance (see grantChestReward's comment), just as a side effect of
-- EventService.IsAdminAbuseActive() becoming true, not because this
-- function reaches into the chest system directly.
function AdminAbuseService.Start(triggeringPlayer, durationMinutes)
	durationMinutes = math.clamp(
		durationMinutes or GameConfig.AdminAbuse.DefaultDurationMinutes,
		1,
		GameConfig.AdminAbuse.MaxDurationMinutes
	)
	local durationSeconds = durationMinutes * 60

	-- Erneuter Aufruf, während schon eins läuft: nur den Timer verlängern/
	-- neu setzen und die Ansage wiederholen, Lighting bleibt unverändert
	-- (sonst würde ein Re-Trigger mitten im Fenster kurz zur ursprünglichen
	-- Farbe zurückspringen und dann wieder hinspringen).
	local alreadyRunning = running
	running = true

	EventService.SetAdminAbuseActive(durationSeconds)

	if not alreadyRunning then
		applyLighting()
	end

	broadcastNotice(
		"🚨 ADMIN ABUSE aktiviert von "
			.. triggeringPlayer.Name
			.. " — "
			.. durationMinutes
			.. " Minuten lang erhöhte seltene Drops + bessere Glücks-Truhen-Chancen!"
	)

	-- Nur wirklich stoppen, wenn in der Zwischenzeit kein NEUER "/adminabuse"
	-- die Zeit schon verlängert hat (sonst würde dieser alte Timer ein
	-- gerade erst verlängertes Event vorzeitig abwürgen).
	task.delay(durationSeconds, function()
		if EventService.GetAdminAbuseRemainingSeconds() <= 0 then
			AdminAbuseService.Stop()
		end
	end)
end

-- Called both by "/adminabuse off" and automatically once the duration from
-- Start() runs out. No longer touches the Glücks-Truhen at all (see
-- StartPermanentChests' comment) — they keep running exactly as before,
-- just back to their normal (lower) creature chance once EventService.
-- IsAdminAbuseActive() goes back to false.
function AdminAbuseService.Stop()
	if not running then
		return
	end
	running = false

	EventService.StopAdminAbuse()
	revertLighting()

	broadcastNotice("Admin Abuse vorbei — zurück zum Normalbetrieb.")
end

return AdminAbuseService
