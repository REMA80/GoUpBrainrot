--[[
	WheelFaceSwap.commandbar.lua
	NICHT Teil des Rojo-Projekts — ein EINMALIGES Skript zum Einfügen in
	Studios Command Bar (View -> Command Bar), im EDIT-Modus (nicht während
	Play), damit die Änderung dauerhaft im gespeicherten Place landet statt
	beim Stop wieder zu verschwinden.

	Was es macht: ersetzt die 8 einzelnen farbigen Keil-Parts ("Wedge" /
	"CornerWedge") im eingefügten Toolbox-"Spinwheel"-Modell durch eine
	einzige flache Scheibe, texturiert mit dem schon hochgeladenen
	Glücksrad-Bild (Asset Id 115532395828245 — dasselbe PNG, das schon in
	GameConfig.WheelOfFortune.WheelImageAssetId für die 2D-UI verwendet
	wird). Rein dekorativ am Kiosk-Standort — das eigentliche Drehen/
	Gewinnen läuft weiterhin über die 2D-UI (UIBuilder.lua), nicht über
	dieses 3D-Modell oder sein eigenes SpinScript.

	Die alten Keile werden nur UNSICHTBAR gemacht (Transparency = 1), nicht
	gelöscht — falls die neue Scheibe nicht richtig aussieht, kannst du die
	Keile jederzeit wieder sichtbar machen und es nochmal versuchen, ohne
	etwas neu einfügen zu müssen.

	Wichtiger Hinweis: dieses Skript rät die Ausrichtung der Scheibe rein
	geometrisch (kürzeste Weltachsen-Ausdehnung der 8 Keile = Dreh-/
	Sichtachse) — ich kann das Ergebnis nicht selbst in Studio ansehen, du
	solltest also kurz prüfen, ob die Scheibe richtig herum steht und ob das
	Bild auf der richtigen Seite sitzt (ein Decal liegt sicherheitshalber
	auf BEIDEN Rundflächen, damit es garantiert von einer Seite sichtbar
	ist, egal wie rum die Scheibe tatsächlich zur Kamera zeigt).
]]

local WHEEL_IMAGE_ASSET_ID = 115532395828245

local spinwheel = workspace:FindFirstChild("Spinwheel", true)
if not spinwheel then
	warn("[WheelFaceSwap] Kein 'Spinwheel'-Objekt irgendwo in Workspace gefunden — nichts geändert.")
	return
end

-- Alle Keil-Parts direkt unter Spinwheel einsammeln (passend zu den 4
-- CornerWedge + 4 Wedge aus dem Explorer-Screenshot). IsA("BasePart")
-- schützt davor, versehentlich ein gleichnamiges Nicht-Part zu erwischen.
local wedges = {}
for _, child in ipairs(spinwheel:GetChildren()) do
	if (child.Name == "Wedge" or child.Name == "CornerWedge") and child:IsA("BasePart") then
		table.insert(wedges, child)
	end
end

if #wedges == 0 then
	warn("[WheelFaceSwap] Keine 'Wedge'/'CornerWedge'-Parts direkt unter Spinwheel gefunden — nichts geändert.")
	return
end

-- Echte WELT-Bounding-Box über alle 8 tatsächlichen Eckpunkte jedes Keils
-- (rotationsbewusst — NICHT Model:GetBoundingBox(), das sich unbemerkt an
-- einem PrimaryPart/eigenen Pivot statt an den Weltachsen ausrichten kann,
-- derselbe Stolperstein, den CreatureModelDisplay's eigener Kommentar für
-- Kreatur-Modelle beschreibt).
local minX, minY, minZ = math.huge, math.huge, math.huge
local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

for _, part in ipairs(wedges) do
	local cframe, size = part.CFrame, part.Size
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local signCombos = {
		{ 1, 1, 1 }, { 1, 1, -1 }, { 1, -1, 1 }, { 1, -1, -1 },
		{ -1, 1, 1 }, { -1, 1, -1 }, { -1, -1, 1 }, { -1, -1, -1 },
	}
	for _, signs in ipairs(signCombos) do
		local corner = cframe * Vector3.new(hx * signs[1], hy * signs[2], hz * signs[3])
		minX, maxX = math.min(minX, corner.X), math.max(maxX, corner.X)
		minY, maxY = math.min(minY, corner.Y), math.max(maxY, corner.Y)
		minZ, maxZ = math.min(minZ, corner.Z), math.max(maxZ, corner.Z)
	end
end

local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
local extentX, extentY, extentZ = maxX - minX, maxY - minY, maxZ - minZ

-- Welche Weltachse die KLEINSTE Ausdehnung hat, ist die Dreh-/Sichtachse des
-- Rads (seine Flächennormale) — die anderen beiden sind der Durchmesser.
-- Funktioniert unabhängig davon, entlang welcher LOKALEN Achse das
-- Original-Asset ursprünglich modelliert wurde.
local thinAxis, thinExtent = "Y", extentY
if extentX < thinExtent then
	thinAxis, thinExtent = "X", extentX
end
if extentZ < thinExtent then
	thinAxis, thinExtent = "Z", extentZ
end

local diameter
if thinAxis == "X" then
	diameter = math.max(extentY, extentZ)
elseif thinAxis == "Y" then
	diameter = math.max(extentX, extentZ)
else
	diameter = math.max(extentX, extentY)
end

-- Der Cylinder-PartType hat seine beiden runden Stirnflächen an den LOKALEN
-- X-Enden — die neue Scheibe muss also so gedreht werden, dass ihre lokale
-- X-Achse entlang der oben ermittelten WELT-Achse zeigt.
local faceCFrame
if thinAxis == "X" then
	faceCFrame = CFrame.new(center)
elseif thinAxis == "Y" then
	faceCFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
else
	faceCFrame = CFrame.new(center) * CFrame.Angles(0, math.rad(90), 0)
end

-- Original-Keile nur UNSICHTBAR machen (siehe Kommentar oben) — CanCollide
-- auch aus, damit sie weder die neue Scheibe noch den Spieler blockieren.
for _, part in ipairs(wedges) do
	part.Transparency = 1
	part.CanCollide = false
end

local disc = Instance.new("Part")
disc.Name = "WheelFace"
disc.Shape = Enum.PartType.Cylinder
disc.Anchored = false -- wird unten verweldet, damit es sich mit dem bewegt, woran die Original-Keile hingen
disc.CanCollide = false
disc.Material = Enum.Material.SmoothPlastic
disc.Color = Color3.new(1, 1, 1)
disc.Size = Vector3.new(math.max(thinExtent, 0.2), diameter, diameter)
disc.CFrame = faceCFrame
disc.Parent = spinwheel

-- Decal auf BEIDEN Rundflächen (Left/Right, die zwei Stirnseiten eines
-- Cylinder-Parts) — unschädlich, falls eine Seite von der Kamera weg zeigt,
-- garantiert aber, dass das Bild sichtbar ist, ohne raten zu müssen, welche
-- Seite tatsächlich zum Spieler zeigt.
local facesToTexture = { Enum.NormalId.Left, Enum.NormalId.Right }
for _, face in ipairs(facesToTexture) do
	local decal = Instance.new("Decal")
	decal.Name = "WheelArtwork_" .. face.Name
	decal.Texture = "rbxassetid://" .. WHEEL_IMAGE_ASSET_ID
	decal.Face = face
	decal.Parent = disc
end

-- Neue Scheibe an das schweißen, woran die Original-Keile schon hingen —
-- damit sie sich mit demselben Dreh mitbewegt, den das vorhandene
-- SpinScript ohnehin schon antreibt. Durchsucht jedes WeldConstraint unter
-- Spinwheel nach einem, das einen der Keile referenziert, und nimmt dessen
-- ANDEREN Part als Ziel.
local weldTarget
for _, descendant in ipairs(spinwheel:GetDescendants()) do
	if descendant:IsA("WeldConstraint") then
		for _, wedge in ipairs(wedges) do
			if descendant.Part0 == wedge then
				weldTarget = descendant.Part1
				break
			elseif descendant.Part1 == wedge then
				weldTarget = descendant.Part0
				break
			end
		end
	end
	if weldTarget then
		break
	end
end

if weldTarget then
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = disc
	weld.Part1 = weldTarget
	weld.Parent = disc
	print("[WheelFaceSwap] Fertig — neue Scheibe an '" .. weldTarget.Name .. "' verweldet, sollte sich jetzt mitdrehen.")
else
	disc.Anchored = true
	warn(
		"[WheelFaceSwap] Konnte nicht finden, woran die Original-Keile verweldet waren — die neue Scheibe ist"
			.. " stattdessen ANCHORED (dreht sich NICHT mit SpinScript mit). Verweide sie manuell an den Part,"
			.. " den das Skript tatsächlich dreht, falls sie sich mitdrehen soll."
	)
end

print("[WheelFaceSwap] Original-Keile nur unsichtbar gemacht (Transparency = 1), nicht gelöscht — lösche sie selbst, sobald dir das Ergebnis gefällt.")
