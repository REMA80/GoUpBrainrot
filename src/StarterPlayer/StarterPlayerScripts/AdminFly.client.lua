--[[
	AdminFly.client.lua
	Reines Test-Werkzeug für dich als Entwickler — kein Teil des eigentlichen
	Spiels. Lässt admin-gelistete Spieler per Tastendruck fliegen, damit man
	z. B. Floor 100 (Optik/Chest) oder die Fast-Travel-Kiosks ansehen kann,
	ohne jedes Mal den ganzen Turm hochzuklettern.

	Bedienung: Taste F an/aus schalten. WASD bewegt relativ zur Kamera,
	Space = hoch, LeftControl = runter.

	WICHTIG — Sicherheitshinweis: Der Admin-Check unten (ADMIN_USER_IDS) ist
	rein CLIENT-seitig und würde für sich allein KEINEN Exploiter mit eigenen
	Tools aufhalten (die können lokale Scripts umgehen/patchen). Deshalb läuft
	dieses Script jetzt zusätzlich NUR NOCH IN STUDIO (RunService:IsStudio()-
	Prüfung unten) — auf einem echten, veröffentlichten Server (mit fremden
	Spielern) tut es dadurch grundsätzlich nichts mehr, ganz unabhängig vom
	Admin-Check. Diese Änderung kam aus einem Sicherheits-Review: ein exakt
	so gebautes Flug-Script wäre sonst eine fertige Anleitung für genau den
	Speed-/Fly-Exploit, den die neue Anti-Cheat-Prüfung (siehe
	GameConfig.AntiCheat / EconomyService.OnFloorReached) verhindern soll.
	Zum Testen in Studio funktioniert es wie gehabt.

	Trag deine eigene Roblox-UserId unten bei ADMIN_USER_IDS ein (zu finden
	z. B. über deine Profil-URL roblox.com/users/<ID>/profile), sonst tut
	dieses Script bei niemandem etwas.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

-- Studio-only (see the WICHTIG note above) — never runs on a live published
-- server, regardless of ADMIN_USER_IDS below.
if not RunService:IsStudio() then
	return
end

-- TODO: hier deine echte Roblox-UserId eintragen (Platzhalter-Wert unten
-- ist absichtlich ungültig, damit das Script standardmäßig für NIEMANDEN
-- etwas tut, bis du das ausfüllst).
local ADMIN_USER_IDS = {
	1683184880, -- Exarcun80
}

local function isAdmin(userId)
	for _, id in ipairs(ADMIN_USER_IDS) do
		if id == userId then
			return true
		end
	end
	return false
end

if not isAdmin(player.UserId) then
	return
end

local FLY_SPEED = 80

local flying = false
local bodyVelocity, bodyGyro
local heartbeatConnection

local function getHumanoidAndRoot()
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return nil, nil
	end
	return humanoid, root
end

local function stopFlying()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	if bodyVelocity then
		bodyVelocity:Destroy()
		bodyVelocity = nil
	end
	if bodyGyro then
		bodyGyro:Destroy()
		bodyGyro = nil
	end

	local humanoid = getHumanoidAndRoot()
	if humanoid then
		humanoid.PlatformStand = false
	end

	flying = false
end

local function startFlying()
	local humanoid, root = getHumanoidAndRoot()
	if not humanoid or not root then
		return
	end

	humanoid.PlatformStand = true

	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(1, 1, 1) * math.huge
	bodyVelocity.Velocity = Vector3.new(0, 0, 0)
	bodyVelocity.Parent = root

	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.MaxTorque = Vector3.new(1, 1, 1) * math.huge
	bodyGyro.CFrame = root.CFrame
	bodyGyro.Parent = root

	heartbeatConnection = RunService.Heartbeat:Connect(function()
		local camera = workspace.CurrentCamera
		if not camera or not bodyVelocity or not bodyGyro then
			return
		end

		local moveVector = Vector3.new(0, 0, 0)
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then
			moveVector += camera.CFrame.LookVector
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then
			moveVector -= camera.CFrame.LookVector
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			moveVector -= camera.CFrame.RightVector
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then
			moveVector += camera.CFrame.RightVector
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			moveVector += Vector3.new(0, 1, 0)
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			moveVector -= Vector3.new(0, 1, 0)
		end

		if moveVector.Magnitude > 0 then
			moveVector = moveVector.Unit * FLY_SPEED
		end

		bodyVelocity.Velocity = moveVector
		bodyGyro.CFrame = camera.CFrame
	end)

	flying = true
end

UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then
		return
	end
	if input.KeyCode == Enum.KeyCode.F then
		if flying then
			stopFlying()
		else
			startFlying()
		end
	end
end)

-- Character stirbt/respawnt während des Fliegens -> alte
-- BodyVelocity/BodyGyro-Instanzen hängen sonst an einem toten Character,
-- und der neue Character würde ohne sie einfach normal laufen statt
-- weiterzufliegen (verwirrend). Sauberer Reset bei jedem neuen Character.
player.CharacterAdded:Connect(function()
	stopFlying()
end)
