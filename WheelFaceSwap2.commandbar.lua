--[[
	WheelFaceSwap2.commandbar.lua
	NICHT Teil des Rojo-Projekts — Command-Bar-Skript für Studio (View ->
	Command Bar), im EDIT-Modus (nicht während Play), damit es dauerhaft im
	gespeicherten Place landet.

	Ersetzt WheelFaceSwap.commandbar.lua — der Screenshot zeigt, dass "Wheel"
	im Spinwheel-Modell bereits eine einzelne flache Scheibe ist (der
	schwarze Kreis im Viewport), keine Ansammlung der Keil-Parts. Deshalb
	muss hier keine neue Scheibe gebaut oder ein Schweißpunkt geraten werden
	— das Bild kommt direkt auf "Wheel" drauf, das schon exakt die richtige
	Form hat und schon vom vorhandenen SpinScript gedreht wird.

	Macht zwei Dinge:
	1. Versteckt die 8 Keil-Parts ("Wedge"/"CornerWedge") — nur Transparency
	   = 1 + CanCollide = false, nicht gelöscht, also jederzeit rückgängig
	   zu machen.
	2. Packt ein Decal mit dem Glücksrad-Bild (Asset Id 115532395828245 —
	   dasselbe PNG, das schon in GameConfig.WheelOfFortune.
	   WheelImageAssetId für die 2D-UI verwendet wird) auf ALLE 6 Seiten von
	   "Wheel" — sicherheitshalber auf allen, damit garantiert eine davon
	   die tatsächlich sichtbare Fläche trifft, ohne raten zu müssen welche
	   Seite zur Kamera zeigt. Unsichtbare Seiten mit Decal sind harmlos.
]]

local WHEEL_IMAGE_ASSET_ID = 115532395828245

local spinwheel = workspace:FindFirstChild("Spinwheel", true)
if not spinwheel then
	warn("[WheelFaceSwap2] Kein 'Spinwheel'-Objekt irgendwo in Workspace gefunden — nichts geändert.")
	return
end

local wheelPart = spinwheel:FindFirstChild("Wheel")
if not wheelPart or not wheelPart:IsA("BasePart") then
	warn("[WheelFaceSwap2] 'Wheel' wurde unter Spinwheel nicht gefunden oder ist kein Part — nichts geändert.")
	return
end

-- Keile verstecken (siehe oben — reversibel, nicht gelöscht).
local hiddenCount = 0
for _, child in ipairs(spinwheel:GetChildren()) do
	if (child.Name == "Wedge" or child.Name == "CornerWedge") and child:IsA("BasePart") then
		child.Transparency = 1
		child.CanCollide = false
		hiddenCount += 1
	end
end

-- Falls das Skript schon mal lief (z. B. WheelFaceSwap.commandbar.lua
-- davor), alte Decals auf "Wheel" zuerst entfernen, damit sich nichts
-- doppelt oder mit einer alten Textur überlagert.
for _, existing in ipairs(wheelPart:GetChildren()) do
	if existing:IsA("Decal") then
		existing:Destroy()
	end
end

local faceNames = { "Front", "Back", "Top", "Bottom", "Left", "Right" }
for _, faceName in ipairs(faceNames) do
	local decal = Instance.new("Decal")
	decal.Name = "WheelArtwork_" .. faceName
	decal.Texture = "rbxassetid://" .. WHEEL_IMAGE_ASSET_ID
	decal.Face = Enum.NormalId[faceName]
	decal.Parent = wheelPart
end

print(
	"[WheelFaceSwap2] Fertig — "
		.. hiddenCount
		.. " Keil-Part(s) versteckt, Bild auf allen 6 Seiten von 'Wheel' angebracht."
)
