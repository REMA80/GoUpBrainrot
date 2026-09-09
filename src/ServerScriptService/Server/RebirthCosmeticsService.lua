--[[
	RebirthCosmeticsService.lua
	Purely cosmetic prestige rewards: at certain Rebirths counts, a player's
	character gets a colored outline glow and a title above their head.
	Visible to every player in the server, not just the owner. No gameplay
	effect — see GameConfig.RebirthCosmetics for the tier list.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local RebirthCosmeticsService = {}

local PlayerDataManager

function RebirthCosmeticsService.Init(deps)
	PlayerDataManager = deps.PlayerDataManager
end

-- Returns the highest-tier cosmetic def a player with this many rebirths
-- qualifies for, or nil if they haven't rebirthed yet.
local function getTierForRebirths(rebirths)
	local best = nil
	for _, tier in ipairs(GameConfig.RebirthCosmetics) do
		if rebirths >= tier.RequiredRebirths then
			if not best or tier.RequiredRebirths > best.RequiredRebirths then
				best = tier
			end
		end
	end
	return best
end

function RebirthCosmeticsService.Apply(player)
	local data = PlayerDataManager.Get(player)
	local character = player.Character
	if not data or not character then
		return
	end

	-- Clear any previous cosmetic first, so re-rebirthing or respawning
	-- never stacks duplicate Highlights/titles.
	local existingHighlight = character:FindFirstChild("RebirthHighlight")
	if existingHighlight then
		existingHighlight:Destroy()
	end

	local head = character:FindFirstChild("Head")
	local existingTitle = head and head:FindFirstChild("RebirthTitle")
	if existingTitle then
		existingTitle:Destroy()
	end

	local tier = getTierForRebirths(data.Rebirths)
	if not tier then
		return -- no rebirths yet, no cosmetic
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "RebirthHighlight"
	highlight.FillColor = tier.Color
	highlight.FillTransparency = 0.75
	-- On request ("grelle Lichter sind immer noch zu stark", Screenshot
	-- zeigte einen extrem hell leuchtenden Spieler mit dem "Mythic Brainrot
	-- Overlord"-Titel) — der Outline war bisher komplett ungedämpft
	-- (OutlineTransparency = 0, volle Stärke, unabhängig von jeder
	-- bisherigen Neon-Anpassung, da Highlight kein Neon-Material ist). Jetzt
	-- softened wie jede andere Leuchtfläche im Spiel: Farbe Richtung Weiß
	-- geblendet und etwas Transparenz auf den Outline selbst.
	highlight.OutlineColor = tier.Color:Lerp(Color3.new(1, 1, 1), 0.35)
	highlight.OutlineTransparency = 0.25
	highlight.Parent = character

	if head then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "RebirthTitle"
		billboard.Size = UDim2.new(0, 160, 0, 30)
		billboard.StudsOffset = Vector3.new(0, 2.5, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = head

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = "★ " .. tier.Name .. " ★"
		label.TextColor3 = tier.Color
		label.TextStrokeTransparency = 0.5
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.Parent = billboard
	end
end

return RebirthCosmeticsService
