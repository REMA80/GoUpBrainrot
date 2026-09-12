--[[
	CustomPromptUI.client.lua
	Ersetzt Robloxs eingebaute Standard-Optik für JEDEN ProximityPrompt mit
	Style = Enum.ProximityPromptStyle.Custom im ganzen Spiel (Pedestal-
	Verkaufen, Floor-100-Truhe, alle Kiosk-Stationen aus BaseService.lua's
	buildStationPart, Kreatur-Claim-Spots aus TowerGenerator.lua) durch eine
	eigene, schlanke BillboardGui: nur ein Kreis um die Tasten-Taste (z. B.
	"E") plus Objekt-/Aktionstext, OHNE das rechteckige Hintergrund-Kästchen,
	das Robloxs Default-Style zeigt — auf Wunsch entfernt. Inklusive einer
	eigenen "Halten zum Aktivieren"-Füllanimation im Kreis (siehe
	HoldFill weiter unten) — die verschwand zunächst mit dem Umstieg auf
	Custom-Style, weil Roblox die bei Default-Style eingebaut mitliefert,
	bei Custom-Style aber NICHTS mehr automatisch zeichnet.

	Zweiter, wichtigerer Grund für Custom statt Default: Default-Style-
	Prompts zeigten ein bekanntes Roblox-Verhalten, bei dem die eingebaute
	Prompt-GUI schon beim bloßen Drüberfahren mit der Maus
	GuiService.SelectedObject setzt, wodurch die Standard-Kamera die
	Rechtsklick-Drehung pausiert ("Maus bleibt stehen, Kamera dreht sich
	nicht mehr"). GuiNavigationEnabled = false (siehe ClientMain/
	init.client.lua) hat das allein NICHT behoben — Custom-Style-Prompts
	erzeugen dagegen gar keine eigene interaktive Roblox-GUI mehr, das
	Problem kann hier also grundsätzlich nicht mehr auftreten.

	Läuft über ProximityPromptService (nicht über die einzelne
	ProximityPrompt-Instanz) — dieser eine Service meldet global JEDEN
	Prompt im Spiel, sobald er für den lokalen Spieler in Reichweite kommt,
	daher reicht dieses eine Skript für jeden aktuellen UND jeden künftigen
	Custom-Style-Prompt, ohne dass jede Kiosk-/Pedestal-Baufunktion ihre
	eigene GUI bauen müsste.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")

-- Für die paar KeyCodes, deren .Name nicht 1:1 das ist, was man auf der
-- Tastatur lesen will (die meisten Buchstaben/Zahlen passen schon 1:1,
-- z. B. Enum.KeyCode.E.Name == "E").
local KEY_NAME_OVERRIDES = {
	[Enum.KeyCode.LeftControl] = "Strg",
	[Enum.KeyCode.RightControl] = "Strg",
	[Enum.KeyCode.Space] = "Leertaste",
	[Enum.KeyCode.Return] = "Enter",
}

-- [ProximityPrompt] = { Gui, Connections = {...}, HoldTween } — damit
-- PromptHidden/Destroying immer genau das aufräumen kann, was PromptShown
-- für diesen Prompt aufgebaut hat (GUI UND die Hold-Events/den laufenden
-- Tween, nicht nur die GUI).
local activeEntries = {}

local function getKeyText(prompt)
	local keyCode = prompt.KeyboardKeyCode
	if keyCode and keyCode ~= Enum.KeyCode.Unknown then
		return KEY_NAME_OVERRIDES[keyCode] or keyCode.Name
	end
	return "E" -- ProximityPrompt-Default, falls KeyboardKeyCode nie gesetzt wurde
end

local function cleanupEntry(prompt)
	local entry = activeEntries[prompt]
	if not entry then
		return
	end
	activeEntries[prompt] = nil

	if entry.HoldTween then
		entry.HoldTween:Cancel()
	end
	for _, connection in ipairs(entry.Connections) do
		connection:Disconnect()
	end
	entry.Gui:Destroy()
end

local function buildGui(prompt)
	-- ProximityPrompts hängen an einem BasePart, einem Attachment oder
	-- (seltener) direkt an einem Model — alle drei sind gültige
	-- BillboardGui-Adornees.
	local adornee = prompt.Parent
	if not adornee then
		return nil
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "CustomPromptGui"
	gui.Adornee = adornee
	gui.Size = UDim2.new(0, 170, 0, 80)
	gui.StudsOffset = Vector3.new(0, 1, 0)
	gui.AlwaysOnTop = true
	-- Etwas großzügiger als die eigentliche Aktivierungsdistanz, damit die
	-- GUI nicht schon knapp VOR dem eigentlichen Trigger-Radius verschwindet.
	gui.MaxDistance = math.max(prompt.MaxActivationDistance + 10, 20)

	-- Der Kreis ums Tasten-Symbol: ein unsichtbar gefülltes Frame (nur
	-- Umriss über UIStroke), rund über UICorner mit halber Breite als Radius.
	local keyRing = Instance.new("Frame")
	keyRing.Name = "KeyRing"
	keyRing.AnchorPoint = Vector2.new(0.5, 0)
	keyRing.Position = UDim2.new(0.5, 0, 0, 0)
	keyRing.Size = UDim2.new(0, 34, 0, 34)
	keyRing.BackgroundTransparency = 1
	keyRing.ClipsDescendants = true -- hält die Füllung sauber innerhalb des runden Kreises
	keyRing.Parent = gui

	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = keyRing

	local ringStroke = Instance.new("UIStroke")
	ringStroke.Thickness = 2
	ringStroke.Color = Color3.new(1, 1, 1)
	ringStroke.Parent = keyRing

	-- Die "Halten zum Aktivieren"-Füllung: startet bei Size 0 in der Mitte
	-- des Kreises und wird beim Halten der Taste über HoldDuration Sekunden
	-- auf die volle Kreisgröße hochgetweent (siehe PromptButtonHoldBegan
	-- unten) — dasselbe Prinzip wie Robloxs eigene Default-Style-Animation,
	-- nur selbst gebaut, weil Custom-Style nichts davon automatisch zeigt.
	local holdFill = Instance.new("Frame")
	holdFill.Name = "HoldFill"
	holdFill.AnchorPoint = Vector2.new(0.5, 0.5)
	holdFill.Position = UDim2.new(0.5, 0, 0.5, 0)
	holdFill.Size = UDim2.new(0, 0, 0, 0)
	holdFill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	holdFill.BackgroundTransparency = 0.35
	holdFill.BorderSizePixel = 0
	holdFill.ZIndex = 1
	holdFill.Parent = keyRing

	local holdFillCorner = Instance.new("UICorner")
	holdFillCorner.CornerRadius = UDim.new(1, 0)
	holdFillCorner.Parent = holdFill

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "KeyText"
	keyLabel.Size = UDim2.new(1, 0, 1, 0)
	keyLabel.BackgroundTransparency = 1
	keyLabel.ZIndex = 2 -- über der HoldFill, damit die Taste beim Füllen lesbar bleibt
	keyLabel.Text = getKeyText(prompt)
	keyLabel.TextColor3 = Color3.new(1, 1, 1)
	keyLabel.TextStrokeTransparency = 0.3
	keyLabel.Font = Enum.Font.GothamBold
	keyLabel.TextScaled = true
	keyLabel.Parent = keyRing

	local objectLabel = Instance.new("TextLabel")
	objectLabel.Name = "ObjectText"
	objectLabel.Size = UDim2.new(1, 0, 0, 20)
	objectLabel.Position = UDim2.new(0, 0, 0, 40)
	objectLabel.BackgroundTransparency = 1
	objectLabel.Text = prompt.ObjectText
	objectLabel.TextColor3 = Color3.new(1, 1, 1)
	objectLabel.TextStrokeTransparency = 0.1
	objectLabel.Font = Enum.Font.GothamBold
	objectLabel.TextScaled = true
	objectLabel.Parent = gui

	local actionLabel = Instance.new("TextLabel")
	actionLabel.Name = "ActionText"
	actionLabel.Size = UDim2.new(1, 0, 0, 20)
	actionLabel.Position = UDim2.new(0, 0, 0, 60)
	actionLabel.BackgroundTransparency = 1
	actionLabel.Text = prompt.ActionText
	actionLabel.TextColor3 = Color3.fromRGB(255, 225, 130)
	actionLabel.TextStrokeTransparency = 0.1
	actionLabel.Font = Enum.Font.Gotham
	actionLabel.TextScaled = true
	actionLabel.Parent = gui

	gui.Parent = adornee

	local entry = { Gui = gui, Connections = {} }
	activeEntries[prompt] = entry

	-- Custom-Style zeichnet KEINE eigene UI mehr — auch nicht den Touch-
	-- Button, den Roblox bei Default-Style automatisch fürs Handy anzeigt.
	-- Tastatur (KeyboardKeyCode) und Gamepad (GamepadKeyCode) lösen den
	-- Prompt weiterhin von selbst aus, weil das echte physische Eingaben
	-- sind — für Touch gibt es aber ohne eigene UI buchstäblich nichts zum
	-- Antippen mehr, seit dem Umstieg von Default auf Custom (siehe
	-- Kommentar oben zum "Maus bleibt stehen"-Fix). Diese unsichtbare
	-- Fläche über dem gesamten Billboard holt das nach: sie meldet Antippen/
	-- Halten manuell über ProximityPrompt:InputHoldBegin()/InputHoldEnd()
	-- an den Prompt — genau der von Roblox für selbstgebaute Custom-UIs
	-- vorgesehene Weg. Funktioniert nebenbei auch für Maus-Klick-und-Halten,
	-- was aber keinen Unterschied macht, weil PC-Spieler ohnehin die Taste
	-- benutzen.
	local touchButton = Instance.new("TextButton")
	touchButton.Name = "TouchButton"
	touchButton.Size = UDim2.new(1, 0, 1, 0)
	touchButton.BackgroundTransparency = 1
	touchButton.AutoButtonColor = false
	touchButton.Text = ""
	touchButton.ZIndex = 3
	touchButton.Parent = gui

	table.insert(
		entry.Connections,
		touchButton.MouseButton1Down:Connect(function()
			prompt:InputHoldBegin()
		end)
	)
	table.insert(
		entry.Connections,
		touchButton.MouseButton1Up:Connect(function()
			prompt:InputHoldEnd()
		end)
	)
	-- Sicherheitsnetz: Finger rutscht beim Halten vom Button runter, ohne
	-- dass MouseButton1Up dort noch feuert — sonst bliebe der Hold ewig aktiv.
	table.insert(
		entry.Connections,
		touchButton.MouseLeave:Connect(function()
			prompt:InputHoldEnd()
		end)
	)

	-- HoldDuration kann 0 sein (Sofort-Trigger ohne Halten) — dann macht
	-- eine Füllanimation keinen Sinn, also nur verbinden, wenn tatsächlich
	-- gehalten werden muss.
	if prompt.HoldDuration > 0 then
		table.insert(
			entry.Connections,
			prompt.PromptButtonHoldBegan:Connect(function()
				if entry.HoldTween then
					entry.HoldTween:Cancel()
				end
				holdFill.Size = UDim2.new(0, 0, 0, 0)
				entry.HoldTween = TweenService:Create(
					holdFill,
					TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear),
					{ Size = UDim2.new(1, 0, 1, 0) }
				)
				entry.HoldTween:Play()
			end)
		)

		table.insert(
			entry.Connections,
			prompt.PromptButtonHoldEnded:Connect(function()
				if entry.HoldTween then
					entry.HoldTween:Cancel()
					entry.HoldTween = nil
				end
				holdFill.Size = UDim2.new(0, 0, 0, 0)
			end)
		)
	end

	-- Sicherheitsnetz: falls der Prompt (bzw. sein Adornee-Part) verschwindet
	-- während er gerade angezeigt wird — z. B. RefreshBase baut die
	-- Pedestals neu, während ein Spieler noch daneben steht — kommt
	-- PromptHidden dafür nicht zwangsläufig, also räumt das hier zusätzlich auf.
	table.insert(
		entry.Connections,
		prompt.Destroying:Connect(function()
			cleanupEntry(prompt)
		end)
	)

	return gui
end

ProximityPromptService.PromptShown:Connect(function(prompt, _inputType)
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		return -- nicht von uns umgestellt — Roblox zeigt hier weiter seine eigene GUI
	end
	if activeEntries[prompt] then
		return -- schon sichtbar (z. B. zwei schnelle PromptShown ohne PromptHidden dazwischen)
	end

	buildGui(prompt)
end)

ProximityPromptService.PromptHidden:Connect(function(prompt)
	cleanupEntry(prompt)
end)
