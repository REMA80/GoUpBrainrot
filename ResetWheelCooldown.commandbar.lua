--[[
	ResetWheelCooldown.commandbar.lua
	NICHT Teil des Rojo-Projekts — ein EINMALIGES Skript zum Einfügen in
	Studios Command Bar (View -> Command Bar), WÄHREND EINES LAUFENDEN
	PLAY-TESTS (Play/Play Here/Server-Test) — NICHT im Edit-Modus wie
	WheelFaceSwap.commandbar.lua, weil hier ein echter, gerade online
	befindlicher Spieler gebraucht wird. In Studios Command-Bar-Dropdown
	(falls vorhanden) den SERVER-Kontext wählen, nicht Client.

	Was es macht: setzt data.LastWheelSpinAt (siehe WheelService.lua /
	PlayerDataManager.lua) für EINEN benannten, aktuell online befindlichen
	Spieler auf 0 zurück — macht dessen kostenlosen Glücksrad-Spin sofort
	wieder verfügbar, ganz ohne den echten Cooldown
	(GameConfig.WheelOfFortune.CooldownSeconds) abzuwarten. Rührt NICHTS
	anderes an (Robux-Käufe/x2-Glück laufen ohnehin unabhängig vom
	Cooldown, siehe WheelService.SpinWheelPaid).

	require() auf ein bereits laufendes ModuleScript gibt in Studio
	dieselbe Instanz zurück, die der echte Server gerade benutzt (Lua
	cached require() pro ModuleScript-Instanz) — die Änderung hier landet
	also in genau demselben Cache, den WheelService.lua/init.server.lua
	live verwenden, nicht in einer separaten Kopie.

	Spielername unten anpassen, dann in die Command Bar einfügen und
	ausführen, während der Play-Test läuft.
]]

local TARGET_PLAYER_NAME = "SpielerName" -- <-- HIER den echten Namen eintragen

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local serverFolder = ServerScriptService:FindFirstChild("Server")
if not serverFolder then
	warn("[ResetWheelCooldown] Konnte ServerScriptService.Server nicht finden — läuft das hier während eines Play-Tests?")
	return
end

local playerDataManagerModule = serverFolder:FindFirstChild("PlayerDataManager")
if not playerDataManagerModule then
	warn("[ResetWheelCooldown] Konnte ServerScriptService.Server.PlayerDataManager nicht finden.")
	return
end

local PlayerDataManager = require(playerDataManagerModule)

-- Case-insensitive Suche unter den aktuell online befindlichen Spielern —
-- toleranter als ein exakter String-Vergleich, falls sich Groß-/
-- Kleinschreibung unterscheidet.
local targetPlayer
for _, player in ipairs(Players:GetPlayers()) do
	if player.Name:lower() == TARGET_PLAYER_NAME:lower() then
		targetPlayer = player
		break
	end
end

if not targetPlayer then
	warn("[ResetWheelCooldown] Kein online Spieler namens '" .. TARGET_PLAYER_NAME .. "' gefunden. Aktuell online: "
		.. table.concat((function()
			local names = {}
			for _, p in ipairs(Players:GetPlayers()) do
				table.insert(names, p.Name)
			end
			return names
		end)(), ", "))
	return
end

local data = PlayerDataManager.Get(targetPlayer)
if not data then
	warn("[ResetWheelCooldown] '" .. targetPlayer.Name .. "' hat noch keine geladenen Daten (PlayerDataManager.Get gab nil zurück) — kurz warten und nochmal versuchen.")
	return
end

data.LastWheelSpinAt = 0
PlayerDataManager.Save(targetPlayer)

print("[ResetWheelCooldown] Glücksrad-Cooldown für '" .. targetPlayer.Name .. "' zurückgesetzt — der kostenlose Spin ist sofort wieder verfügbar.")
