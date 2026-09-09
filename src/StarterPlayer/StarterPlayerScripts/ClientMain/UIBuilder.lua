--[[
	UIBuilder.lua
	Builds the entire HUD purely from code (Instance.new) — no manual GUI
	layout needed in Studio. Simple, functional placeholder styling; swap in
	your own art/branding whenever you like.

	Layout (top-left, top to bottom): stats HUD (Cash/Floor/Rebirths/Tier,
	each with a small colored icon) — that's it for the persistent HUD now.
	The Jump Upgrade / Rebirth / Slap Hand / 2x Cash / VIP buttons that used
	to live here have all been REMOVED — those actions are now fixed
	physical kiosks inside each player's own base (see BaseService.lua's
	buildStations), not screen buttons. Auto Climb has been removed
	entirely (no button, no base kiosk — see init.client.lua). A separate
	full-screen overlay (hidden until needed) still holds the Rebirth
	confirmation dialog — it's just triggered by walking up to the Rebirth
	kiosk now instead of clicking a button. The old "Brainrot Collection"
	side panel (a live inventory list) has been removed — claimed creatures
	are shown at the player's base instead (see BaseService.lua). A DIFFERENT
	panel, the Brainrot-Dex (toggled via a button under the stats HUD), was
	added later — a discovery/completion log of every creature that ever
	existed (GameConfig.Creatures), including ones you HAVEN'T found yet
	(shown as "???"), which the old removed panel never was.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players") -- needed for the Leaderboard panel's avatar thumbnails (Players:GetUserThumbnailAsync)
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local UIBuilder = {}

-- === Gamepad/Controller navigation ==============================================
-- On request ("kann man die Steuerung für Konsole anpassen, man kann zb. bei
-- dem Sprung-Händler nichts auswählen wenn man keine Maus hat") — every
-- popup in this file is now navigable with a gamepad D-Pad/stick + A button
-- (and, for free, arrow keys + Enter on keyboard — Roblox's built-in
-- GuiService navigation drives both the same way), not just mouse/touch.
-- Every button that was only ever wired via `.MouseButton1Click` (in this
-- file and init.client.lua) has also been switched to `.Activated` — the
-- only one of the two that actually fires for a gamepad A-press/keyboard
-- Enter on the Selected object; MouseButton1Click never fires for those,
-- only for a real mouse click or a touch tap.
--
-- GuiService.GuiNavigationEnabled is turned OFF globally in init.client.lua
-- (see its own long comment there) to work around a real prior bug: the
-- game's default ProximityPrompts (still used by the pedestal Harvest/Sell
-- prompts) mark their own built-in GUI as "selected" on plain MOUSE HOVER,
-- and Roblox's stock camera script always pauses right-click camera
-- rotation while ANYTHING is "selected" — leaving navigation on permanently
-- froze the camera for mouse players just walking past a pedestal. Flipping
-- it back on globally would bring that bug straight back.
--
-- The fix here is scoped instead: navigation is switched ON only for as
-- long as one of OUR OWN popups below is open (pushGamepadFocus/
-- popGamepadFocus, called from every Show*/Hide* pair in this file), and
-- back OFF the moment the last one closes — exactly the "camera shouldn't
-- spin while a menu is open" case GuiNavigationEnabled exists for in the
-- first place, without ever touching the ProximityPrompt/mouse-hover case
-- that caused the original bug.
--
-- Stack of SelectedObject buttons, one per currently-open popup — supports
-- one popup opening ON TOP of another (e.g. an incoming Trade Request while
-- the Trade Zone panel is already up): the newest push always owns
-- GuiService.SelectedObject; popping restores whichever popup (if any) was
-- open underneath it, and only turns navigation back off once the stack is
-- completely empty. Popups in this game are always closed in the reverse
-- order they were opened (you can't open a second one without the first
-- already being gone, except the Trade Request/Trade Zone pair, which still
-- closes LIFO in practice), so a plain table.remove is enough — no need to
-- search the stack for a specific entry.
--
-- IMPORTANT: GuiService.SelectedObject is only ever set while a real gamepad
-- is connected (UserInputService.GamepadEnabled). Setting it unconditionally
-- turned out to also hijack WASD itself (not just arrow keys) into UI
-- navigation for keyboard/mouse players the moment ANY popup was open,
-- breaking normal character movement — a regression discovered right after
-- this feature first shipped. Keyboard/mouse players never needed
-- SelectedObject anyway, since .Activated already fires directly from their
-- real clicks; only gamepad players — who have no mouse to click with —
-- actually need Roblox's built-in navigation turned on. The stack itself is
-- still always maintained regardless of GamepadEnabled, so push/pop stay
-- correctly paired no matter when a gamepad connects or disconnects.
local gamepadFocusStack = {}

local function pushGamepadFocus(firstButton)
	if not firstButton then
		return
	end
	table.insert(gamepadFocusStack, firstButton)
	if UserInputService.GamepadEnabled then
		GuiService.GuiNavigationEnabled = true
		GuiService.SelectedObject = firstButton
	end
end

local function popGamepadFocus()
	table.remove(gamepadFocusStack)
	local previous = gamepadFocusStack[#gamepadFocusStack]
	if not UserInputService.GamepadEnabled then
		return
	end
	if previous then
		GuiService.SelectedObject = previous
	else
		GuiService.SelectedObject = nil
		GuiService.GuiNavigationEnabled = false
	end
end

-- Links an ORDERED list of GuiButtons into a vertical Up/Down chain (wraps
-- around at both ends) so a D-Pad/stick+A gamepad player (and arrow keys +
-- Enter on keyboard) can move through every button in a popup, top to
-- bottom. Call again whenever which buttons are visible/reachable changes
-- (e.g. a Robux button that only appears once GetProductInfo confirms a
-- price, or a pooled row list whose visible COUNT changes) — pass only the
-- buttons that should currently be reachable; a link pointing at a hidden
-- button would strand navigation there.
local function wireVerticalChain(buttons)
	local count = #buttons
	for i, button in ipairs(buttons) do
		button.Selectable = true
		button.NextSelectionUp = buttons[i - 1] or buttons[count]
		button.NextSelectionDown = buttons[i + 1] or buttons[1]
	end
end

-- Same idea, horizontally (Left/Right) — used for side-by-side button pairs
-- within a single row (Cash/Robux, Yes/No, Accept/Decline, Confirm/Cancel).
local function wireHorizontalChain(buttons)
	local count = #buttons
	for i, button in ipairs(buttons) do
		button.Selectable = true
		button.NextSelectionLeft = buttons[i - 1] or buttons[count]
		button.NextSelectionRight = buttons[i + 1] or buttons[1]
	end
end

-- Formats a Cash-scale number the same way BaseService.lua's pedestal
-- Cash/sec labels do on the server: a plain integer under 1000, K/M/B
-- abbreviated above that — keeps the HUD readable now that Rebirth costs
-- reach into the hundreds of millions. THIS is the actual top-left HUD
-- Cash/Cash-per-second display (ui.CashLabel, see init.client.lua) — on
-- request ("hier passt der Wert nicht, sollte 2T stehen") extended past B
-- with the same standard short-scale names AND comma-decimal as
-- BaseService.formatCashRate: Trillion (1e12), Quadrillion (1e15, "Qa"),
-- Quintillion (1e18, "Qi"), Sextillion (1e21, "Sx"), Septillion (1e24,
-- "Sp"), Octillion (1e27, "Oc"). Nothing named above Octillion — a bigger
-- value just keeps growing as an ever-larger "Oc" instead of erroring.
local function toCommaDecimal(str)
	return (str:gsub("%.", ","))
end

function UIBuilder.FormatNumber(value)
	value = math.floor(value)
	if value >= 1e27 then
		return toCommaDecimal(string.format("%.1f", value / 1e27)) .. "Oc"
	elseif value >= 1e24 then
		return toCommaDecimal(string.format("%.1f", value / 1e24)) .. "Sp"
	elseif value >= 1e21 then
		return toCommaDecimal(string.format("%.1f", value / 1e21)) .. "Sx"
	elseif value >= 1e18 then
		return toCommaDecimal(string.format("%.1f", value / 1e18)) .. "Qi"
	elseif value >= 1e15 then
		return toCommaDecimal(string.format("%.1f", value / 1e15)) .. "Qa"
	elseif value >= 1e12 then
		return toCommaDecimal(string.format("%.1f", value / 1e12)) .. "T"
	elseif value >= 1e9 then
		return toCommaDecimal(string.format("%.1f", value / 1e9)) .. "B"
	elseif value >= 1e6 then
		return toCommaDecimal(string.format("%.1f", value / 1e6)) .. "M"
	elseif value >= 1e3 then
		return toCommaDecimal(string.format("%.1f", value / 1e3)) .. "K"
	else
		return tostring(value)
	end
end

-- Normalizes a value from GameConfig.HUD.Icons into a usable
-- ImageLabel.Image string, or nil if that icon has no asset ID configured
-- (the "" default) — accepts either a bare asset number ("123456789") or
-- the full "rbxassetid://123456789" form. Same helper BaseService.lua's
-- buildStationPart has (kept as its own local copy here, not shared —
-- client and server modules in this project don't share private locals).
local function toAssetIdString(value)
	if not value or value == "" then
		return nil
	end
	local str = tostring(value)
	if str:match("^rbxassetid://") then
		return str
	end
	return "rbxassetid://" .. str
end

-- One "big stat" row for the bottom-left HUD (Cash / Jump) — a bold,
-- black-outlined number with a small round icon badge to its left, on
-- request ("Cash-Anzeige links unten, grün mit schwarzem Rand, leuchtend —
-- die Jumps auch wie im Referenzbild", the Jump one in pink/magenta).
--
-- FIX: this used to also fake a soft "glow" with a second, larger,
-- invisible-fill copy of the text behind the real one, showing only its
-- thick colored UIStroke. Roblox's UIStroke has NO blur/feather though —
-- it's a crisp, hard-edged outline — so at a thickness big enough to read
-- as a "halo" it instead drew as an ugly, uneven colored blob bleeding
-- past the letters ("der Hintergrund überschlägt sich"). Removed
-- entirely: a bright saturated fill color plus a clean black outline
-- already reads as "glowing" against the game world without it, and
-- that's actually closer to the reference screenshot too — that text has
-- a crisp black border, not a soft blur, either.
-- `assetIdIcon` is an already-resolved GameConfig.HUD.Icons value (run
-- through toAssetIdString by the caller), or nil to just use `iconChar`
-- (a plain emoji string) as a TextLabel fallback — same "real image if
-- configured, otherwise emoji" convention as BaseService.buildStationPart.
local function makeBigStatRow(parent, name, order, iconChar, accentColor, assetIdIcon)
	local row = Instance.new("Frame")
	row.Name = name .. "Row"
	row.Size = UDim2.new(1, 0, 0, 40)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local icon = Instance.new("Frame")
	icon.Name = "Icon"
	icon.Size = UDim2.new(0, 36, 0, 36)
	icon.Position = UDim2.new(0, 0, 0.5, -18)
	icon.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	icon.BackgroundTransparency = 0.15
	icon.Parent = row
	Instance.new("UICorner", icon).CornerRadius = UDim.new(1, 0)
	local iconStroke = Instance.new("UIStroke")
	iconStroke.Color = Color3.new(0, 0, 0)
	iconStroke.Thickness = 2
	iconStroke.Parent = icon

	if assetIdIcon then
		local iconImage = Instance.new("ImageLabel")
		iconImage.Name = "IconImage"
		iconImage.Size = UDim2.new(1, -6, 1, -6)
		iconImage.Position = UDim2.new(0, 3, 0, 3)
		iconImage.BackgroundTransparency = 1
		iconImage.Image = assetIdIcon
		iconImage.ScaleType = Enum.ScaleType.Fit
		iconImage.Parent = icon
	else
		local iconLabel = Instance.new("TextLabel")
		iconLabel.Name = "IconLabel"
		iconLabel.Size = UDim2.new(1, -6, 1, -6)
		iconLabel.Position = UDim2.new(0, 3, 0, 3)
		iconLabel.BackgroundTransparency = 1
		iconLabel.Text = iconChar
		iconLabel.Font = Enum.Font.GothamBold
		iconLabel.TextScaled = true
		iconLabel.Parent = icon
	end

	local textHolder = Instance.new("Frame")
	textHolder.Name = "TextHolder"
	textHolder.Size = UDim2.new(1, -46, 1, 0)
	textHolder.Position = UDim2.new(0, 46, 0, 0)
	textHolder.BackgroundTransparency = 1
	textHolder.Parent = row

	-- Solid accent-color fill, crisp black outline (both the native
	-- TextStroke AND a UIStroke on top, stacked, for a thicker
	-- cartoon-style border than TextStroke alone gives) — no separate glow
	-- layer anymore, see the comment above.
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = accentColor
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = textHolder
	local labelStroke = Instance.new("UIStroke")
	labelStroke.Color = Color3.new(0, 0, 0)
	labelStroke.Thickness = 3
	labelStroke.Parent = label

	return label, row
end

-- One HUD row: a small colored round icon with a letter, plus a text label
-- to its right. Returns the label (the icon is purely decorative).
local function makeIconRow(parent, name, order, iconChar, iconColor)
	local row = Instance.new("Frame")
	row.Name = name .. "Row"
	row.Size = UDim2.new(1, 0, 0, 30)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local icon = Instance.new("Frame")
	icon.Name = "Icon"
	icon.Size = UDim2.new(0, 26, 0, 26)
	icon.Position = UDim2.new(0, 0, 0.5, -13)
	icon.BackgroundColor3 = iconColor
	icon.Parent = row
	Instance.new("UICorner", icon).CornerRadius = UDim.new(1, 0)

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "IconLabel"
	iconLabel.Size = UDim2.new(1, 0, 1, 0)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = iconChar
	iconLabel.TextColor3 = Color3.new(1, 1, 1)
	iconLabel.Font = Enum.Font.GothamBold
	iconLabel.TextScaled = true
	iconLabel.Parent = icon

	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = UDim2.new(1, -36, 1, 0)
	label.Position = UDim2.new(0, 36, 0, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = row

	return label
end

-- Builds one Dex row's "picture" — a small round ViewportFrame showing the
-- creature's REAL 3D model live-rendered (same model BaseService would show
-- on a pedestal, see ReplicatedStorage.CreatureModels), if one has been
-- dropped in for it. Falls back to a plain rarity-colored circle swatch when
-- no model exists yet (most creatures, since that folder starts empty), and
-- to a dark "?" swatch for a creature you haven't discovered at all — never
-- shows a model for an undiscovered creature, even if one exists, so the Dex
-- doesn't spoil what it looks like before you've actually found it.
local function buildDexThumbnail(parent, creatureName, color, discovered)
	local size = UDim2.new(0, 48, 0, 48)
	local position = UDim2.new(0, 4, 0.5, -24)

	if discovered then
		local folder = ReplicatedStorage:FindFirstChild("CreatureModels")
		local template = folder and folder:FindFirstChild(creatureName)
		if template and template:IsA("Model") then
			local viewport = Instance.new("ViewportFrame")
			viewport.Name = "Thumbnail"
			viewport.Size = size
			viewport.Position = position
			viewport.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
			viewport.ZIndex = 12
			viewport.Parent = parent
			Instance.new("UICorner", viewport).CornerRadius = UDim.new(1, 0)

			-- GetBoundingBox is a safe, read-only MEASUREMENT (unlike
			-- Model:ScaleTo, which proved unreliable on these Bone-based
			-- skinned meshes elsewhere in this project — see
			-- CreatureModelDisplay.lua) — it's only used here to frame a
			-- camera around the clone, never to resize anything.
			local ok = pcall(function()
				local clone = template:Clone()
				for _, inst in ipairs(clone:GetDescendants()) do
					if inst:IsA("BasePart") then
						inst.Anchored = true
						inst.CanCollide = false
						inst.CanQuery = false
					elseif inst:IsA("Script") or inst:IsA("LocalScript") then
						inst:Destroy()
					end
				end
				clone.Parent = viewport

				local boundsCFrame, boundsSize = clone:GetBoundingBox()
				local radius = math.max(boundsSize.Magnitude / 2, 1)
				local camera = Instance.new("Camera")
				camera.FieldOfView = 40
				local distance = radius / math.tan(math.rad(camera.FieldOfView / 2)) + radius
				camera.CFrame = CFrame.lookAt(
					boundsCFrame.Position + Vector3.new(0, radius * 0.15, distance),
					boundsCFrame.Position
				)
				camera.Parent = viewport
				viewport.CurrentCamera = camera
			end)

			if ok then
				return
			end
			viewport:Destroy()
		end
	end

	local swatch = Instance.new("Frame")
	swatch.Name = "Thumbnail"
	swatch.Size = size
	swatch.Position = position
	swatch.BackgroundColor3 = discovered and (color or Color3.new(1, 1, 1)) or Color3.fromRGB(40, 40, 46)
	swatch.ZIndex = 12
	swatch.Parent = parent
	Instance.new("UICorner", swatch).CornerRadius = UDim.new(1, 0)

	if not discovered then
		local mark = Instance.new("TextLabel")
		mark.Size = UDim2.new(1, 0, 1, 0)
		mark.BackgroundTransparency = 1
		mark.Text = "?"
		mark.TextColor3 = Color3.fromRGB(120, 120, 130)
		mark.Font = Enum.Font.GothamBold
		mark.TextScaled = true
		mark.ZIndex = 13
		mark.Parent = swatch
	end
end

function UIBuilder.Build(player)
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GoUpBrainrotUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	-- === Stats HUD (top-left) ===================================================
	-- Cash and the Jump/Tier stat moved OUT of this box, down to their own
	-- big glowing bottom-left display (see BigStatsFrame below, built on
	-- request to match a reference screenshot) — only Floor and Rebirths
	-- stay here now, so the box is shorter than before (2 rows, not 4).
	local statsFrame = Instance.new("Frame")
	statsFrame.Name = "StatsFrame"
	statsFrame.Size = UDim2.new(0, 260, 0, 80)
	statsFrame.Position = UDim2.new(0, 10, 0, 10)
	statsFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	statsFrame.BackgroundTransparency = 0.15
	statsFrame.Parent = screenGui
	Instance.new("UICorner", statsFrame).CornerRadius = UDim.new(0, 10)

	local statsLayout = Instance.new("UIListLayout")
	statsLayout.Padding = UDim.new(0, 4)
	statsLayout.Parent = statsFrame

	local statsPadding = Instance.new("UIPadding")
	statsPadding.PaddingTop = UDim.new(0, 8)
	statsPadding.PaddingLeft = UDim.new(0, 8)
	statsPadding.PaddingRight = UDim.new(0, 8)
	statsPadding.Parent = statsFrame

	local floorLabel = makeIconRow(statsFrame, "FloorLabel", 1, "F", Color3.fromRGB(70, 150, 230))
	local rebirthLabel = makeIconRow(statsFrame, "RebirthLabel", 2, "R", Color3.fromRGB(190, 90, 230))

	-- === Big Cash / Jump display (bottom-left) ===================================
	-- "Cash Anzeige so wie hier haben, links unten, grün mit schwarzem Rand,
	-- leuchtend — die Jumps auch wie am Bild" (Jump in pink/magenta, per the
	-- reference screenshot). Anchored to the bottom-left corner instead of
	-- the top — see makeBigStatRow's own comment for how the glow is faked.
	-- Order top-to-bottom is Jump, then Freunde-Boost, then Cash, then the
	-- optional 2x-Cash badge (see each row below).
	--
	-- Size.Y used to be a fixed 88 (just enough for the original 2 rows,
	-- Jump+Cash). Switched to AutomaticSize.Y (on request, "eine ui Anzeige
	-- oberhalb der Konto Anzeige" — the Freunde-Boost row below is now
	-- ALWAYS visible, a 3rd permanent row that a fixed 88 no longer has
	-- room for, and the 2x-Cash badge can still make it a 4th) — the frame
	-- now grows to fit exactly however many rows are actually visible.
	-- AnchorPoint stays (0,1) with Position's Y anchored to the bottom, so
	-- it grows UPWARD from that fixed bottom edge as rows are added,
	-- instead of pushing the bottom edge down off-screen.
	local bigStatsFrame = Instance.new("Frame")
	bigStatsFrame.Name = "BigStatsFrame"
	bigStatsFrame.AnchorPoint = Vector2.new(0, 1)
	bigStatsFrame.AutomaticSize = Enum.AutomaticSize.Y
	bigStatsFrame.Size = UDim2.new(0, 260, 0, 0)
	bigStatsFrame.Position = UDim2.new(0, 10, 1, -10)
	bigStatsFrame.BackgroundTransparency = 1
	bigStatsFrame.Parent = screenGui

	local bigStatsLayout = Instance.new("UIListLayout")
	bigStatsLayout.Padding = UDim.new(0, 6)
	bigStatsLayout.Parent = bigStatsFrame

	local tierLabel = makeBigStatRow(
		bigStatsFrame, "TierLabel", 1, "👟", Color3.fromRGB(255, 60, 190),
		toAssetIdString(GameConfig.HUD.Icons.Jump)
	)

	-- "🤝 Freunde-Boost" badge — on request ("mache eine ui Anzeige oberhalb
	-- der Konto Anzeige"), placed directly ABOVE the Cash row below (order 2,
	-- Cash pushed down to order 3) since "Konto-Anzeige" = the big Cash
	-- display. ALWAYS visible (on request, "sie soll auch da sein wenn ein
	-- Freund da ist dann steht aber kein Freund Online 0%") — unlike the
	-- DoubleCash badge below, this one does NOT hide itself at 0%; instead
	-- UIBuilder.UpdateFriendBoostBadge switches its text between "Kein
	-- Freund online (+0%)" and "+X% Freunde-Boost" so it reads as a
	-- permanent status row, not a temporary buff popup.
	local friendBoostLabel, friendBoostRow = makeBigStatRow(
		bigStatsFrame, "FriendBoostLabel", 2, "🤝", Color3.fromRGB(255, 170, 50)
	)

	local cashLabel = makeBigStatRow(
		bigStatsFrame, "CashLabel", 3, "💰", Color3.fromRGB(70, 255, 90),
		toAssetIdString(GameConfig.HUD.Icons.Cash)
	)

	-- Red "2x Cash (Xs)" countdown badge — shows only while the Glücksrad's
	-- 2x Cash prize is active (on request: previously there was no visual
	-- sign at all that this buff was running, or how long was left). Same
	-- styling helper as the Jump/Cash rows above, just hidden by default;
	-- UIBuilder.RefreshDoubleCashBadge below flips Visible + updates the
	-- text. UIListLayout skips invisible children, so hiding this row
	-- collapses it with no gap left behind.
	local doubleCashLabel, doubleCashRow = makeBigStatRow(
		bigStatsFrame, "DoubleCashLabel", 4, "🚀", Color3.fromRGB(255, 45, 45)
	)
	doubleCashRow.Visible = false

	-- === Brainrot-Dex toggle button (just under the stats HUD) ==================
	-- Opens the Dex panel below — a discovery log of every creature in
	-- GameConfig.Creatures, showing "???" for ones you haven't found yet.
	-- ClientMain/init.client.lua wires the click (fetches the current list
	-- from the server via the GetDiscoveredCreatures remote, then calls
	-- UIBuilder.PopulateDex + ShowDex) — same separation as everywhere else.
	local dexButton = Instance.new("TextButton")
	dexButton.Name = "DexButton"
	dexButton.Size = UDim2.new(0, 130, 0, 32)
	dexButton.Position = UDim2.new(0, 10, 0, 96)
	dexButton.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
	dexButton.TextColor3 = Color3.new(1, 1, 1)
	dexButton.Font = Enum.Font.GothamBold
	dexButton.TextScaled = true
	dexButton.Text = "📖 Brainrot-Dex"
	dexButton.Parent = screenGui
	Instance.new("UICorner", dexButton).CornerRadius = UDim.new(0, 8)

	-- === Brainrot-Dex panel (hidden full-screen overlay) ==========================
	local dexOverlay = Instance.new("Frame")
	dexOverlay.Name = "DexOverlay"
	dexOverlay.Size = UDim2.new(1, 0, 1, 0)
	dexOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	dexOverlay.BackgroundTransparency = 0.5
	dexOverlay.Visible = false
	dexOverlay.ZIndex = 10
	dexOverlay.Parent = screenGui

	local dexDialog = Instance.new("Frame")
	dexDialog.Name = "DexDialog"
	dexDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	dexDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	dexDialog.Size = UDim2.new(0, 640, 0, 520)
	dexDialog.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	dexDialog.ZIndex = 11
	dexDialog.Parent = dexOverlay
	Instance.new("UICorner", dexDialog).CornerRadius = UDim.new(0, 14)

	local dexTitle = Instance.new("TextLabel")
	dexTitle.Name = "Title"
	dexTitle.Size = UDim2.new(1, -70, 0, 36)
	dexTitle.Position = UDim2.new(0, 10, 0, 10)
	dexTitle.BackgroundTransparency = 1
	dexTitle.Text = "📖 Brainrot-Dex"
	dexTitle.TextColor3 = Color3.fromRGB(120, 160, 255)
	dexTitle.Font = Enum.Font.GothamBold
	dexTitle.TextScaled = true
	dexTitle.TextXAlignment = Enum.TextXAlignment.Left
	dexTitle.ZIndex = 12
	dexTitle.Parent = dexDialog

	local dexCloseButton = Instance.new("TextButton")
	dexCloseButton.Name = "CloseButton"
	dexCloseButton.Size = UDim2.new(0, 40, 0, 36)
	dexCloseButton.Position = UDim2.new(1, -50, 0, 10)
	dexCloseButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	dexCloseButton.TextColor3 = Color3.new(1, 1, 1)
	dexCloseButton.Font = Enum.Font.GothamBold
	dexCloseButton.TextScaled = true
	dexCloseButton.Text = "X" -- "✕" (U+2715) doesn't actually render in Roblox's default UI fonts (same class of issue as the "🔶" emoji noted elsewhere in this file) — showed as a blank/tofu box instead of an X. Plain ASCII "X" always renders.
	dexCloseButton.ZIndex = 12
	dexCloseButton.Parent = dexDialog
	Instance.new("UICorner", dexCloseButton).CornerRadius = UDim.new(0, 8)

	local dexProgressLabel = Instance.new("TextLabel")
	dexProgressLabel.Name = "ProgressLabel"
	dexProgressLabel.Size = UDim2.new(1, -20, 0, 22)
	dexProgressLabel.Position = UDim2.new(0, 10, 0, 48)
	dexProgressLabel.BackgroundTransparency = 1
	dexProgressLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	dexProgressLabel.TextXAlignment = Enum.TextXAlignment.Left
	dexProgressLabel.Font = Enum.Font.Gotham
	dexProgressLabel.TextScaled = true
	dexProgressLabel.Text = ""
	dexProgressLabel.ZIndex = 12
	dexProgressLabel.Parent = dexDialog

	-- IMPORTANT — the full story of the "Dex panel renders solid black" bug,
	-- for whoever touches this next, because it took a LOT of dead ends to
	-- actually nail down:
	--
	-- 1st attempt: ScrollingFrame.AutomaticCanvasSize, which has a known
	--    engine bug where it doesn't recompute while the frame/an ancestor
	--    is Visible = false (devforum.com/t/1310579). Didn't fix it.
	-- 2nd attempt: manual CanvasSize computed by hand instead of trusting
	--    Automatic* properties at all. Still rendered solid black — but an
	--    Explorer check while the (still black) panel was open confirmed all
	--    ~91 Row_/Header_ instances DID exist as children, correctly sized —
	--    so sizing was never the real problem.
	-- 3rd attempt: a separate non-scrolling backing Frame carrying the
	--    UICorner/background (ScrollingFrame + UICorner is a known separate
	--    Roblox bug), plus reordering so ShowDex sets Visible = true BEFORE
	--    any row is ever built or shown. Still rendered solid black in the
	--    live, published game.
	-- 4th attempt: build the ~91 rows ONCE (lazily, the first time ShowDex
	--    actually runs, always after Visible = true) instead of destroying/
	--    rebuilding them every open. STILL rendered solid black.
	-- 5th attempt: replaced ScrollingFrame with a hand-rolled scroll system —
	--    a plain Frame with ClipsDescendants = true, a manual scrollbar
	--    thumb, and mouse-wheel handling instead of any ScrollingFrame
	--    Canvas* property. STILL reported empty/black by a player.
	--
	-- Every one of those assumed the CONTENT (rows/timing/sizing) was the
	-- problem, or that ScrollingFrame specifically was the problem. But
	-- attempt 5 removed ScrollingFrame entirely and STILL hit it — so the
	-- real common factor across every failure is a ClipsDescendants = true
	-- Frame nested a couple of levels deep. Meanwhile the ONE panel in this
	-- UI that has NEVER had this bug, not once (Jump Upgrade), has no
	-- ClipsDescendants Frame anywhere in it at all — it just never needed to
	-- clip/scroll because it only ever shows 4 fixed buttons at once.
	--
	-- ACTUAL FIX: give the Dex the same property Jump Upgrade has — zero
	-- ClipsDescendants Frames — by replacing SCROLLING with PAGINATION.
	-- dexContent below is a perfectly plain Frame (no clipping at all).
	-- Every header/row for all ~91 creatures is still pre-built ONCE (see
	-- ensureDexRowsBuilt), positioned by hand and split across pages sized
	-- to always fit inside dexContent with margin to spare — so nothing
	-- ever needs to be clipped in the first place. Turning a page (Prev/
	-- Next below) only ever flips .Visible on already-built instances,
	-- never creates/destroys/moves anything — the same "pre-build once,
	-- mutate forever" pattern Jump Upgrade already uses successfully.
	local dexContent = Instance.new("Frame")
	dexContent.Name = "Content"
	dexContent.Size = UDim2.new(1, -20, 1, -138)
	dexContent.Position = UDim2.new(0, 10, 0, 76)
	dexContent.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	dexContent.BorderSizePixel = 0
	dexContent.ZIndex = 12
	dexContent.Parent = dexDialog
	Instance.new("UICorner", dexContent).CornerRadius = UDim.new(0, 8)

	local dexPrevButton = Instance.new("TextButton")
	dexPrevButton.Name = "PrevButton"
	dexPrevButton.Size = UDim2.new(0, 90, 0, 40)
	dexPrevButton.Position = UDim2.new(0, 10, 1, -50)
	dexPrevButton.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
	dexPrevButton.TextColor3 = Color3.new(1, 1, 1)
	dexPrevButton.Font = Enum.Font.GothamBold
	dexPrevButton.TextScaled = true
	dexPrevButton.Text = "◀ Zurück"
	dexPrevButton.ZIndex = 12
	dexPrevButton.Parent = dexDialog
	Instance.new("UICorner", dexPrevButton).CornerRadius = UDim.new(0, 8)

	local dexPageLabel = Instance.new("TextLabel")
	dexPageLabel.Name = "PageLabel"
	dexPageLabel.Size = UDim2.new(1, -220, 0, 40)
	dexPageLabel.Position = UDim2.new(0, 110, 1, -50)
	dexPageLabel.BackgroundTransparency = 1
	dexPageLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	dexPageLabel.Font = Enum.Font.GothamBold
	dexPageLabel.TextScaled = true
	dexPageLabel.Text = ""
	dexPageLabel.ZIndex = 12
	dexPageLabel.Parent = dexDialog

	local dexNextButton = Instance.new("TextButton")
	dexNextButton.Name = "NextButton"
	dexNextButton.Size = UDim2.new(0, 90, 0, 40)
	dexNextButton.Position = UDim2.new(1, -100, 1, -50)
	dexNextButton.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
	dexNextButton.TextColor3 = Color3.new(1, 1, 1)
	dexNextButton.Font = Enum.Font.GothamBold
	dexNextButton.TextScaled = true
	dexNextButton.Text = "Weiter ▶"
	dexNextButton.ZIndex = 12
	dexNextButton.Parent = dexDialog
	Instance.new("UICorner", dexNextButton).CornerRadius = UDim.new(0, 8)

	-- === Leaderboard panel (hidden full-screen overlay) ============================
	-- On request ("die Bestenliste hat Bilder der Spieler und man kann von
	-- Top1 bis Top 200 runter scrollen ... für alle 3 Ranglisten, begrenze es
	-- auf top 100 ... seine Position einblenden") — opened by walking up to
	-- the physical board near the tower and holding its ProximityPrompt (see
	-- LeaderboardService.BuildBoard / init.client.lua's RequestLeaderboardPanel
	-- listener), same "kiosk opens a panel" convention as the Glücksrad/Jump-
	-- Upgrade/Fast-Travel kiosks. PAGED, not scrolled, for the exact same
	-- reason as the Brainrot-Dex right above (see the long comment on
	-- dexContent): a ClipsDescendants/ScrollingFrame has repeatedly rendered
	-- solid black in this exact project, so this reuses that same proven
	-- "pre-build once, flip Visible by page" approach, just shared across 3
	-- tab-switchable categories instead of one.
	local leaderboardOverlay = Instance.new("Frame")
	leaderboardOverlay.Name = "LeaderboardOverlay"
	leaderboardOverlay.Size = UDim2.new(1, 0, 1, 0)
	leaderboardOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	leaderboardOverlay.BackgroundTransparency = 0.5
	leaderboardOverlay.Visible = false
	leaderboardOverlay.ZIndex = 10
	leaderboardOverlay.Parent = screenGui

	local leaderboardDialog = Instance.new("Frame")
	leaderboardDialog.Name = "LeaderboardDialog"
	leaderboardDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	leaderboardDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	leaderboardDialog.Size = UDim2.new(0, 700, 0, 700)
	leaderboardDialog.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	leaderboardDialog.ZIndex = 11
	leaderboardDialog.Parent = leaderboardOverlay
	Instance.new("UICorner", leaderboardDialog).CornerRadius = UDim.new(0, 14)

	local leaderboardTitle = Instance.new("TextLabel")
	leaderboardTitle.Name = "Title"
	leaderboardTitle.Size = UDim2.new(1, -70, 0, 36)
	leaderboardTitle.Position = UDim2.new(0, 10, 0, 10)
	leaderboardTitle.BackgroundTransparency = 1
	leaderboardTitle.Text = "🏆 Bestenliste"
	leaderboardTitle.TextColor3 = Color3.fromRGB(255, 215, 0)
	leaderboardTitle.Font = Enum.Font.GothamBold
	leaderboardTitle.TextScaled = true
	leaderboardTitle.TextXAlignment = Enum.TextXAlignment.Left
	leaderboardTitle.ZIndex = 12
	leaderboardTitle.Parent = leaderboardDialog

	local leaderboardCloseButton = Instance.new("TextButton")
	leaderboardCloseButton.Name = "CloseButton"
	leaderboardCloseButton.Size = UDim2.new(0, 40, 0, 36)
	leaderboardCloseButton.Position = UDim2.new(1, -50, 0, 10)
	leaderboardCloseButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	leaderboardCloseButton.TextColor3 = Color3.new(1, 1, 1)
	leaderboardCloseButton.Font = Enum.Font.GothamBold
	leaderboardCloseButton.TextScaled = true
	leaderboardCloseButton.Text = "X" -- "✕" doesn't render in Roblox's default UI fonts — see dexCloseButton's comment above
	leaderboardCloseButton.ZIndex = 12
	leaderboardCloseButton.Parent = leaderboardDialog
	Instance.new("UICorner", leaderboardCloseButton).CornerRadius = UDim.new(0, 8)

	-- Three tabs (Cash/s | Rebirths | Gesamt-Cash) — switching between them
	-- is purely client-side (init.client.lua fetches ALL 3 categories in one
	-- round trip when the panel opens, see GetLeaderboardPanelData), so a tab
	-- click never needs to ask the server again.
	local leaderboardTabCashPerSecond = Instance.new("TextButton")
	leaderboardTabCashPerSecond.Name = "TabCashPerSecond"
	leaderboardTabCashPerSecond.Size = UDim2.new(0, 220, 0, 34)
	leaderboardTabCashPerSecond.Position = UDim2.new(0, 10, 0, 54)
	leaderboardTabCashPerSecond.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
	leaderboardTabCashPerSecond.TextColor3 = Color3.new(1, 1, 1)
	leaderboardTabCashPerSecond.Font = Enum.Font.GothamBold
	leaderboardTabCashPerSecond.TextScaled = true
	leaderboardTabCashPerSecond.Text = "💰 Cash/s"
	leaderboardTabCashPerSecond.ZIndex = 12
	leaderboardTabCashPerSecond.Parent = leaderboardDialog
	Instance.new("UICorner", leaderboardTabCashPerSecond).CornerRadius = UDim.new(0, 8)

	local leaderboardTabRebirths = Instance.new("TextButton")
	leaderboardTabRebirths.Name = "TabRebirths"
	leaderboardTabRebirths.Size = UDim2.new(0, 220, 0, 34)
	leaderboardTabRebirths.Position = UDim2.new(0, 238, 0, 54)
	leaderboardTabRebirths.BackgroundColor3 = Color3.fromRGB(50, 60, 70)
	leaderboardTabRebirths.TextColor3 = Color3.new(1, 1, 1)
	leaderboardTabRebirths.Font = Enum.Font.GothamBold
	leaderboardTabRebirths.TextScaled = true
	leaderboardTabRebirths.Text = "🔁 Wiedergeburten"
	leaderboardTabRebirths.ZIndex = 12
	leaderboardTabRebirths.Parent = leaderboardDialog
	Instance.new("UICorner", leaderboardTabRebirths).CornerRadius = UDim.new(0, 8)

	local leaderboardTabCash = Instance.new("TextButton")
	leaderboardTabCash.Name = "TabCash"
	leaderboardTabCash.Size = UDim2.new(0, 220, 0, 34)
	leaderboardTabCash.Position = UDim2.new(0, 466, 0, 54)
	leaderboardTabCash.BackgroundColor3 = Color3.fromRGB(50, 60, 70)
	leaderboardTabCash.TextColor3 = Color3.new(1, 1, 1)
	leaderboardTabCash.Font = Enum.Font.GothamBold
	leaderboardTabCash.TextScaled = true
	leaderboardTabCash.Text = "💵 Gesamt-Cash"
	leaderboardTabCash.ZIndex = 12
	leaderboardTabCash.Parent = leaderboardDialog
	Instance.new("UICorner", leaderboardTabCash).CornerRadius = UDim.new(0, 8)

	local leaderboardContent = Instance.new("Frame")
	leaderboardContent.Name = "Content"
	leaderboardContent.Size = UDim2.new(1, -20, 0, 460)
	leaderboardContent.Position = UDim2.new(0, 10, 0, 98)
	leaderboardContent.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	leaderboardContent.BorderSizePixel = 0
	leaderboardContent.ZIndex = 12
	leaderboardContent.Parent = leaderboardDialog
	Instance.new("UICorner", leaderboardContent).CornerRadius = UDim.new(0, 8)

	-- Pinned "Du"-row — ALWAYS visible regardless of which page is currently
	-- showing, on request ("man kann ja den jeweiligen Spieler unten
	-- einblenden der gerade schaut und seine Position einblenden"). Sits
	-- between the paged list and the Prev/Next bar, styled distinctly (gold
	-- outline) so it visually reads as "this one's you", not just another row.
	local leaderboardSelfRow = Instance.new("Frame")
	leaderboardSelfRow.Name = "SelfRow"
	leaderboardSelfRow.Size = UDim2.new(1, -20, 0, 54)
	leaderboardSelfRow.Position = UDim2.new(0, 10, 1, -112)
	leaderboardSelfRow.BackgroundColor3 = Color3.fromRGB(50, 45, 20)
	leaderboardSelfRow.ZIndex = 12
	leaderboardSelfRow.Parent = leaderboardDialog
	Instance.new("UICorner", leaderboardSelfRow).CornerRadius = UDim.new(0, 8)
	local leaderboardSelfStroke = Instance.new("UIStroke")
	leaderboardSelfStroke.Color = Color3.fromRGB(255, 215, 0)
	leaderboardSelfStroke.Thickness = 2
	leaderboardSelfStroke.Parent = leaderboardSelfRow

	local leaderboardSelfRankLabel = Instance.new("TextLabel")
	leaderboardSelfRankLabel.Name = "RankText"
	leaderboardSelfRankLabel.Size = UDim2.new(0, 130, 1, -10)
	leaderboardSelfRankLabel.Position = UDim2.new(0, 6, 0, 5)
	leaderboardSelfRankLabel.BackgroundTransparency = 1
	leaderboardSelfRankLabel.Font = Enum.Font.GothamBold
	leaderboardSelfRankLabel.TextScaled = true
	leaderboardSelfRankLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	leaderboardSelfRankLabel.Text = "?"
	leaderboardSelfRankLabel.ZIndex = 13
	leaderboardSelfRankLabel.Parent = leaderboardSelfRow

	local leaderboardSelfAvatarImage = Instance.new("ImageLabel")
	leaderboardSelfAvatarImage.Name = "Avatar"
	leaderboardSelfAvatarImage.Size = UDim2.new(0, 44, 0, 44)
	leaderboardSelfAvatarImage.Position = UDim2.new(0, 140, 0, 5)
	leaderboardSelfAvatarImage.BackgroundColor3 = Color3.fromRGB(55, 55, 62)
	leaderboardSelfAvatarImage.ScaleType = Enum.ScaleType.Fit
	leaderboardSelfAvatarImage.ZIndex = 13
	leaderboardSelfAvatarImage.Parent = leaderboardSelfRow
	Instance.new("UICorner", leaderboardSelfAvatarImage).CornerRadius = UDim.new(0, 6)

	local leaderboardSelfNameLabel = Instance.new("TextLabel")
	leaderboardSelfNameLabel.Name = "NameText"
	leaderboardSelfNameLabel.Size = UDim2.new(0, 150, 1, -10)
	leaderboardSelfNameLabel.Position = UDim2.new(0, 192, 0, 5)
	leaderboardSelfNameLabel.BackgroundTransparency = 1
	leaderboardSelfNameLabel.TextXAlignment = Enum.TextXAlignment.Left
	leaderboardSelfNameLabel.Font = Enum.Font.GothamBold
	leaderboardSelfNameLabel.TextScaled = true
	leaderboardSelfNameLabel.TextColor3 = Color3.new(1, 1, 1)
	leaderboardSelfNameLabel.Text = "Du"
	leaderboardSelfNameLabel.ZIndex = 13
	leaderboardSelfNameLabel.Parent = leaderboardSelfRow

	local leaderboardSelfValueLabel = Instance.new("TextLabel")
	leaderboardSelfValueLabel.Name = "ValueText"
	leaderboardSelfValueLabel.Size = UDim2.new(1, -358, 1, -10)
	leaderboardSelfValueLabel.Position = UDim2.new(0, 352, 0, 5)
	leaderboardSelfValueLabel.BackgroundTransparency = 1
	leaderboardSelfValueLabel.TextXAlignment = Enum.TextXAlignment.Right
	leaderboardSelfValueLabel.Font = Enum.Font.GothamBold
	leaderboardSelfValueLabel.TextScaled = true
	leaderboardSelfValueLabel.TextColor3 = Color3.fromRGB(170, 220, 170)
	leaderboardSelfValueLabel.Text = ""
	leaderboardSelfValueLabel.ZIndex = 13
	leaderboardSelfValueLabel.Parent = leaderboardSelfRow

	local leaderboardPrevButton = Instance.new("TextButton")
	leaderboardPrevButton.Name = "PrevButton"
	leaderboardPrevButton.Size = UDim2.new(0, 90, 0, 40)
	leaderboardPrevButton.Position = UDim2.new(0, 10, 1, -50)
	leaderboardPrevButton.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
	leaderboardPrevButton.TextColor3 = Color3.new(1, 1, 1)
	leaderboardPrevButton.Font = Enum.Font.GothamBold
	leaderboardPrevButton.TextScaled = true
	leaderboardPrevButton.Text = "◀ Zurück"
	leaderboardPrevButton.ZIndex = 12
	leaderboardPrevButton.Parent = leaderboardDialog
	Instance.new("UICorner", leaderboardPrevButton).CornerRadius = UDim.new(0, 8)

	local leaderboardPageLabel = Instance.new("TextLabel")
	leaderboardPageLabel.Name = "PageLabel"
	leaderboardPageLabel.Size = UDim2.new(1, -220, 0, 40)
	leaderboardPageLabel.Position = UDim2.new(0, 110, 1, -50)
	leaderboardPageLabel.BackgroundTransparency = 1
	leaderboardPageLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	leaderboardPageLabel.Font = Enum.Font.GothamBold
	leaderboardPageLabel.TextScaled = true
	leaderboardPageLabel.Text = ""
	leaderboardPageLabel.ZIndex = 12
	leaderboardPageLabel.Parent = leaderboardDialog

	local leaderboardNextButton = Instance.new("TextButton")
	leaderboardNextButton.Name = "NextButton"
	leaderboardNextButton.Size = UDim2.new(0, 90, 0, 40)
	leaderboardNextButton.Position = UDim2.new(1, -100, 1, -50)
	leaderboardNextButton.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
	leaderboardNextButton.TextColor3 = Color3.new(1, 1, 1)
	leaderboardNextButton.Font = Enum.Font.GothamBold
	leaderboardNextButton.TextScaled = true
	leaderboardNextButton.Text = "Weiter ▶"
	leaderboardNextButton.ZIndex = 12
	leaderboardNextButton.Parent = leaderboardDialog
	Instance.new("UICorner", leaderboardNextButton).CornerRadius = UDim.new(0, 8)

	-- === "Sprunghöhe"-Regler (fest im HUD, kein Button/Panel zum Öffnen) =========
	-- Auf Wunsch: "die Tasten +10% / Max / -10% direkt am Bildschirm
	-- anbringen" — eine erste Version hinter einem Button + Popup-Panel
	-- versteckt war umständlicher als nötig; jetzt stehen die drei Buttons
	-- + eine Live-Anzeige permanent im HUD, direkt unter dem Dex-Button,
	-- ohne irgendetwas erst öffnen zu müssen.
	-- Lässt jeden Spieler seine EIGENE Sprunghöhe innerhalb dessen
	-- einstellen, was er bereits erspielt/gekauft hat (siehe EconomyService.
	-- SetJumpHeightFraction's Kommentar) — nie höher als der eigene
	-- verdiente Wert (data.JumpPower, derselbe Wert, den auch die
	-- "Bouncy Boots (N)"-Zeile unten links zeigt), nur niedriger, falls
	-- einem die volle Sprunghöhe zu unhandlich zum präzisen Landen ist.
	-- Stufenweise (+/- Buttons) statt ein echter Zieh-Regler — bewusst:
	-- zuverlässiger zu bauen und zu testen als ein Drag-Slider mit Maus-
	-- UND Touch-Unterstützung, bei praktisch demselben Ergebnis.
	local jumpHeightPanel = Instance.new("Frame")
	jumpHeightPanel.Name = "JumpHeightPanel"
	jumpHeightPanel.Size = UDim2.new(0, 220, 0, 76)
	jumpHeightPanel.Position = UDim2.new(0, 10, 0, 134)
	jumpHeightPanel.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
	jumpHeightPanel.BackgroundTransparency = 0.1
	jumpHeightPanel.Parent = screenGui
	Instance.new("UICorner", jumpHeightPanel).CornerRadius = UDim.new(0, 10)
	local jumpHeightPanelStroke = Instance.new("UIStroke")
	jumpHeightPanelStroke.Color = Color3.fromRGB(60, 170, 90)
	jumpHeightPanelStroke.Thickness = 2
	jumpHeightPanelStroke.Parent = jumpHeightPanel

	local jumpHeightValueLabel = Instance.new("TextLabel")
	jumpHeightValueLabel.Name = "ValueLabel"
	jumpHeightValueLabel.Size = UDim2.new(1, -12, 0, 28)
	jumpHeightValueLabel.Position = UDim2.new(0, 6, 0, 4)
	jumpHeightValueLabel.BackgroundTransparency = 1
	jumpHeightValueLabel.Text = "🦘 100%"
	jumpHeightValueLabel.TextColor3 = Color3.new(1, 1, 1)
	jumpHeightValueLabel.Font = Enum.Font.FredokaOne
	jumpHeightValueLabel.TextScaled = true
	jumpHeightValueLabel.TextXAlignment = Enum.TextXAlignment.Left
	jumpHeightValueLabel.Parent = jumpHeightPanel

	local jumpHeightButtonRow = Instance.new("Frame")
	jumpHeightButtonRow.Name = "ButtonRow"
	jumpHeightButtonRow.Size = UDim2.new(1, -12, 0, 34)
	jumpHeightButtonRow.Position = UDim2.new(0, 6, 0, 36)
	jumpHeightButtonRow.BackgroundTransparency = 1
	jumpHeightButtonRow.Parent = jumpHeightPanel

	local jumpHeightRowLayout = Instance.new("UIListLayout")
	jumpHeightRowLayout.FillDirection = Enum.FillDirection.Horizontal
	jumpHeightRowLayout.Padding = UDim.new(0, 6)
	jumpHeightRowLayout.Parent = jumpHeightButtonRow

	local function makeJumpHeightStepButton(name, text, color, order)
		local button = Instance.new("TextButton")
		button.Name = name
		button.Size = UDim2.new(0, 65, 1, 0)
		button.LayoutOrder = order
		button.BackgroundColor3 = color
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Font = Enum.Font.GothamBold
		button.TextScaled = true
		button.Text = text
		button.Parent = jumpHeightButtonRow
		Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
		return button
	end

	local jumpHeightDownButton = makeJumpHeightStepButton("DownButton", "-10%", Color3.fromRGB(90, 90, 100), 1)
	local jumpHeightMaxButton = makeJumpHeightStepButton("MaxButton", "Max", Color3.fromRGB(60, 170, 90), 2)
	local jumpHeightUpButton = makeJumpHeightStepButton("UpButton", "+10%", Color3.fromRGB(90, 90, 100), 3)

	-- NOTE: the Jump-upgrade progress bar, Upgrade button, Rebirth button,
	-- Gamepass shop panel (2x Cash / Auto Climb / VIP), and Cash shop panel
	-- (Slap Hand) that used to be built here are GONE — Jump Upgrade,
	-- Rebirth, Slap Hand, 2x Cash, and VIP are now fixed physical kiosks
	-- inside each player's own base (see BaseService.lua's buildStations),
	-- and Auto Climb has been removed entirely (no button, no base kiosk).

	-- === Weekly event banner (top-right) ==========================================
	-- Only visible while GameConfig.Event's window is open (see
	-- EconomyService.FireDataUpdated -> data.EventActive / UpdateEventBanner
	-- below), so players actually know right now is the time to grind Floor
	-- 60 for a Hacker / Lava creature instead of having to guess.
	local eventBanner = Instance.new("Frame")
	eventBanner.Name = "EventBanner"
	eventBanner.Size = UDim2.new(0, 280, 0, 40)
	eventBanner.Position = UDim2.new(1, -290, 0, 10)
	eventBanner.BackgroundColor3 = Color3.fromRGB(120, 20, 150)
	eventBanner.BackgroundTransparency = 0.05
	eventBanner.Visible = false
	eventBanner.Parent = screenGui
	Instance.new("UICorner", eventBanner).CornerRadius = UDim.new(0, 10)

	local eventBannerText = Instance.new("TextLabel")
	eventBannerText.Name = "Text"
	eventBannerText.Size = UDim2.new(1, -16, 1, 0)
	eventBannerText.Position = UDim2.new(0, 8, 0, 0)
	eventBannerText.BackgroundTransparency = 1
	eventBannerText.TextColor3 = Color3.new(1, 1, 1)
	eventBannerText.Font = Enum.Font.GothamBold
	eventBannerText.TextScaled = true
	eventBannerText.Text = "🎉 Event: Floor 60 Bonus-Chance!"
	eventBannerText.Parent = eventBanner

	-- === Toast/message labels (top center) ========================================
	local messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "MessageLabel"
	messageLabel.Size = UDim2.new(0, 400, 0, 40)
	messageLabel.Position = UDim2.new(0.5, -200, 0, 10)
	messageLabel.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
	messageLabel.BackgroundTransparency = 1
	messageLabel.TextTransparency = 1
	messageLabel.TextColor3 = Color3.new(1, 1, 1)
	messageLabel.Font = Enum.Font.GothamBold
	messageLabel.TextScaled = true
	messageLabel.Text = ""
	messageLabel.Parent = screenGui
	Instance.new("UICorner", messageLabel).CornerRadius = UDim.new(0, 8)

	local toastLabel = Instance.new("TextLabel")
	toastLabel.Name = "ToastLabel"
	toastLabel.Size = UDim2.new(0, 400, 0, 40)
	toastLabel.Position = UDim2.new(0.5, -200, 0, 60)
	toastLabel.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
	toastLabel.BackgroundTransparency = 1
	toastLabel.TextTransparency = 1
	toastLabel.TextColor3 = Color3.new(1, 1, 1)
	toastLabel.Font = Enum.Font.GothamBold
	toastLabel.TextScaled = true
	toastLabel.Text = ""
	toastLabel.Parent = screenGui
	Instance.new("UICorner", toastLabel).CornerRadius = UDim.new(0, 8)

	local sellToastLabel = Instance.new("TextLabel")
	sellToastLabel.Name = "SellToastLabel"
	sellToastLabel.Size = UDim2.new(0, 400, 0, 40)
	sellToastLabel.Position = UDim2.new(0.5, -200, 0, 110)
	sellToastLabel.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
	sellToastLabel.BackgroundTransparency = 1
	sellToastLabel.TextTransparency = 1
	sellToastLabel.TextColor3 = Color3.new(1, 1, 1)
	sellToastLabel.Font = Enum.Font.GothamBold
	sellToastLabel.TextScaled = true
	sellToastLabel.Text = ""
	sellToastLabel.Parent = screenGui
	Instance.new("UICorner", sellToastLabel).CornerRadius = UDim.new(0, 8)

	-- === Trade Zone panel (centered popup, matches the Sprung-Händler dialog) =====
	-- Visible only while standing inside GameConfig.Trade's physical zone (see
	-- TradeService.lua) — lists every OTHER player currently in the zone,
	-- each with a button to send them a trade request. Same pre-build-once/
	-- mutate-after pattern as the Jump Upgrade panel (see the long comment
	-- above its buttons below) instead of Instance.new()-ing fresh rows on
	-- every roster change: GameConfig.Base.MaxPlayers is a hard server-wide
	-- player cap (also sets Players.MaxPlayers, see init.server.lua), so
	-- "everyone else in the zone" can never exceed MaxPlayers - 1 — a fixed,
	-- small, known bound, exactly the situation pre-building suits. Each row
	-- carries its target's UserId as an Attribute for ClientMain/init.
	-- client.lua's click handler to read, same separation UIBuilder keeps
	-- everywhere else.
	--
	-- STYLING (on request — "die Ui der Tausch-Zone genau so aufgebaut wie
	-- bei dem Sprung-Händler, damit man die Namen besser sieht", then
	-- confirmed as "Echtes Popup ... verdeckt dann kurz einen Teil des
	-- Bildschirms, solange man in der Zone steht"): rebuilt from the old
	-- small always-on bottom-left panel into the SAME dimmed-backdrop +
	-- rounded/thick-outlined "candy" dialog chrome the Jump Upgrade (Sprung-
	-- Händler) dialog uses below, with bold GothamBold + text-stroke names
	-- instead of the old thin flat Gotham text. There's still no manual
	-- open/close button, unlike the Jump Upgrade dialog — this stays purely
	-- driven by UpdateTradeZoneRoster toggling ui.TradeZonePanel.Visible as
	-- the player enters/leaves the physical zone; that's the accepted
	-- trade-off of the popup look (it now covers part of the screen while
	-- standing in the zone, where the old corner widget never did).
	--
	-- Kept at a lower ZIndex band (5/6/7) than the Incoming Trade Request
	-- popup and Trade window below (10/11/12) — both of those can still pop
	-- up while this is visible (e.g. someone sends a request while you're
	-- standing in the zone), and should always render on top when they do.
	local tradeZonePanel = Instance.new("Frame")
	tradeZonePanel.Name = "TradeZonePanel"
	tradeZonePanel.Size = UDim2.new(1, 0, 1, 0)
	tradeZonePanel.BackgroundColor3 = Color3.new(0, 0, 0)
	tradeZonePanel.BackgroundTransparency = 0.5
	tradeZonePanel.Visible = false
	tradeZonePanel.ZIndex = 5
	tradeZonePanel.Parent = screenGui

	local tradeZoneDialog = Instance.new("Frame")
	tradeZoneDialog.Name = "TradeZoneDialog"
	tradeZoneDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	tradeZoneDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	tradeZoneDialog.Size = UDim2.new(0, 320, 0, 280)
	tradeZoneDialog.BackgroundColor3 = Color3.fromRGB(40, 110, 190)
	tradeZoneDialog.ZIndex = 6
	tradeZoneDialog.Parent = tradeZonePanel
	Instance.new("UICorner", tradeZoneDialog).CornerRadius = UDim.new(0, 24)
	local tradeZoneDialogStroke = Instance.new("UIStroke")
	tradeZoneDialogStroke.Color = Color3.fromRGB(15, 50, 90)
	tradeZoneDialogStroke.Thickness = 4
	tradeZoneDialogStroke.Parent = tradeZoneDialog

	local tradeZoneTitle = Instance.new("TextLabel")
	tradeZoneTitle.Name = "Title"
	tradeZoneTitle.Size = UDim2.new(1, -32, 0, 40)
	tradeZoneTitle.Position = UDim2.new(0, 16, 0, 16)
	tradeZoneTitle.BackgroundTransparency = 1
	tradeZoneTitle.Text = "🤝 Tausch-Zone"
	tradeZoneTitle.TextColor3 = Color3.new(1, 1, 1)
	tradeZoneTitle.TextStrokeTransparency = 0.3
	tradeZoneTitle.Font = Enum.Font.GothamBold
	tradeZoneTitle.TextScaled = true
	tradeZoneTitle.TextXAlignment = Enum.TextXAlignment.Left
	tradeZoneTitle.ZIndex = 7
	tradeZoneTitle.Parent = tradeZoneDialog

	local tradeZoneList = Instance.new("Frame")
	tradeZoneList.Name = "List"
	tradeZoneList.Size = UDim2.new(1, -32, 1, -80)
	tradeZoneList.Position = UDim2.new(0, 16, 0, 64)
	tradeZoneList.BackgroundTransparency = 1
	tradeZoneList.ZIndex = 7
	tradeZoneList.Parent = tradeZoneDialog

	local tradeZoneListLayout = Instance.new("UIListLayout")
	tradeZoneListLayout.Padding = UDim.new(0, 8)
	tradeZoneListLayout.Parent = tradeZoneList

	-- Built ONCE, right here — a fixed pool of GameConfig.Base.MaxPlayers - 1
	-- rows (the max anyone else in the zone could ever be), all Visible =
	-- false to start. UpdateTradeZoneRoster below only ever mutates an
	-- EXISTING row's Text/Attribute/Visible now, never creates or destroys
	-- one — a Visible = false row is skipped by UIListLayout automatically,
	-- so hidden rows don't leave gaps.
	local tradeZoneRows = {}
	for i = 1, math.max(0, GameConfig.Base.MaxPlayers - 1) do
		local row = Instance.new("TextButton")
		row.Name = "Row_" .. i
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, 46)
		row.BackgroundColor3 = Color3.fromRGB(70, 160, 240)
		row.AutoButtonColor = false
		row.TextColor3 = Color3.new(1, 1, 1)
		row.TextStrokeTransparency = 0.3
		row.TextWrapped = true
		row.Font = Enum.Font.GothamBold
		row.TextScaled = true
		row.Text = ""
		row.Visible = false
		row.ZIndex = 7
		row.Parent = tradeZoneList
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 14)
		local rowStroke = Instance.new("UIStroke")
		rowStroke.Color = Color3.fromRGB(15, 50, 90)
		rowStroke.Thickness = 2
		rowStroke.Parent = row
		table.insert(tradeZoneRows, row)
	end

	local tradeZoneEmptyLabel = Instance.new("TextLabel")
	tradeZoneEmptyLabel.Name = "EmptyLabel"
	tradeZoneEmptyLabel.LayoutOrder = 0
	tradeZoneEmptyLabel.Size = UDim2.new(1, 0, 0, 40)
	tradeZoneEmptyLabel.BackgroundTransparency = 1
	tradeZoneEmptyLabel.TextColor3 = Color3.new(1, 1, 1)
	tradeZoneEmptyLabel.TextStrokeTransparency = 0.3
	tradeZoneEmptyLabel.TextWrapped = true
	tradeZoneEmptyLabel.Font = Enum.Font.GothamBold
	tradeZoneEmptyLabel.TextScaled = true
	tradeZoneEmptyLabel.Text = "Niemand sonst hier gerade."
	tradeZoneEmptyLabel.Visible = false
	tradeZoneEmptyLabel.ZIndex = 7
	tradeZoneEmptyLabel.Parent = tradeZoneList

	-- === Incoming trade request popup (hidden full-screen overlay) ================
	-- Static Accept/Decline buttons — unlike the roster rows above, this
	-- doesn't need per-show target data (the server already knows exactly
	-- who's asking, see TradeService.RespondTrade), so ClientMain/init.
	-- client.lua can wire these ONCE, same as the Rebirth confirm buttons.
	local tradeRequestOverlay = Instance.new("Frame")
	tradeRequestOverlay.Name = "TradeRequestOverlay"
	tradeRequestOverlay.Size = UDim2.new(1, 0, 1, 0)
	tradeRequestOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	tradeRequestOverlay.BackgroundTransparency = 0.5
	tradeRequestOverlay.Visible = false
	tradeRequestOverlay.ZIndex = 10
	tradeRequestOverlay.Parent = screenGui

	local tradeRequestDialog = Instance.new("Frame")
	tradeRequestDialog.Name = "TradeRequestDialog"
	tradeRequestDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	tradeRequestDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	tradeRequestDialog.Size = UDim2.new(0, 380, 0, 170)
	tradeRequestDialog.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	tradeRequestDialog.ZIndex = 11
	tradeRequestDialog.Parent = tradeRequestOverlay
	Instance.new("UICorner", tradeRequestDialog).CornerRadius = UDim.new(0, 14)

	local tradeRequestText = Instance.new("TextLabel")
	tradeRequestText.Name = "Text"
	tradeRequestText.Size = UDim2.new(1, -20, 0, 70)
	tradeRequestText.Position = UDim2.new(0, 10, 0, 10)
	tradeRequestText.BackgroundTransparency = 1
	tradeRequestText.TextColor3 = Color3.new(1, 1, 1)
	tradeRequestText.TextWrapped = true
	tradeRequestText.Font = Enum.Font.GothamBold
	tradeRequestText.TextScaled = true
	tradeRequestText.ZIndex = 12
	tradeRequestText.Text = ""
	tradeRequestText.Parent = tradeRequestDialog

	local tradeAcceptButton = Instance.new("TextButton")
	tradeAcceptButton.Name = "AcceptButton"
	tradeAcceptButton.Size = UDim2.new(0, 170, 0, 44)
	tradeAcceptButton.Position = UDim2.new(0, 10, 1, -54)
	tradeAcceptButton.BackgroundColor3 = Color3.fromRGB(40, 170, 90)
	tradeAcceptButton.TextColor3 = Color3.new(1, 1, 1)
	tradeAcceptButton.Font = Enum.Font.GothamBold
	tradeAcceptButton.TextScaled = true
	tradeAcceptButton.Text = "Annehmen"
	tradeAcceptButton.ZIndex = 12
	tradeAcceptButton.Parent = tradeRequestDialog
	Instance.new("UICorner", tradeAcceptButton).CornerRadius = UDim.new(0, 8)

	local tradeDeclineButton = Instance.new("TextButton")
	tradeDeclineButton.Name = "DeclineButton"
	tradeDeclineButton.Size = UDim2.new(0, 170, 0, 44)
	tradeDeclineButton.Position = UDim2.new(1, -180, 1, -54)
	tradeDeclineButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	tradeDeclineButton.TextColor3 = Color3.new(1, 1, 1)
	tradeDeclineButton.Font = Enum.Font.GothamBold
	tradeDeclineButton.TextScaled = true
	tradeDeclineButton.Text = "Ablehnen"
	tradeDeclineButton.ZIndex = 12
	tradeDeclineButton.Parent = tradeRequestDialog
	Instance.new("UICorner", tradeDeclineButton).CornerRadius = UDim.new(0, 8)

	-- Gamepad/keyboard: Left/Right between Accept/Decline. Default focus
	-- (set in ShowTradeRequest below) is Decline — same "irreversible-ish
	-- action shouldn't be one accidental A-press away" reasoning as the
	-- Rebirth/Sell confirm dialogs above.
	wireHorizontalChain({ tradeAcceptButton, tradeDeclineButton })

	-- === Trade window (hidden full-screen overlay) =================================
	-- Shown once a trade request is accepted (TradeService.RespondTrade ->
	-- "TradeOpened"). Left side: the picker of YOUR OWN Brainrots (built
	-- fresh per open, same Attribute+ChildAdded pattern as the Trade Zone
	-- roster above). Right side: a live readout of both offers plus
	-- Confirm/Cancel — those two are static, wired once in init.client.lua.
	local tradeWindowOverlay = Instance.new("Frame")
	tradeWindowOverlay.Name = "TradeWindowOverlay"
	tradeWindowOverlay.Size = UDim2.new(1, 0, 1, 0)
	tradeWindowOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	tradeWindowOverlay.BackgroundTransparency = 0.5
	tradeWindowOverlay.Visible = false
	tradeWindowOverlay.ZIndex = 10
	tradeWindowOverlay.Parent = screenGui

	local tradeWindowDialog = Instance.new("Frame")
	tradeWindowDialog.Name = "TradeWindowDialog"
	tradeWindowDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	tradeWindowDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	tradeWindowDialog.Size = UDim2.new(0, 560, 0, 420)
	tradeWindowDialog.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	tradeWindowDialog.ZIndex = 11
	tradeWindowDialog.Parent = tradeWindowOverlay
	Instance.new("UICorner", tradeWindowDialog).CornerRadius = UDim.new(0, 14)

	local tradeWindowTitle = Instance.new("TextLabel")
	tradeWindowTitle.Name = "Title"
	tradeWindowTitle.Size = UDim2.new(1, -20, 0, 34)
	tradeWindowTitle.Position = UDim2.new(0, 10, 0, 10)
	tradeWindowTitle.BackgroundTransparency = 1
	tradeWindowTitle.Text = "Tausch"
	tradeWindowTitle.TextColor3 = Color3.fromRGB(80, 200, 255)
	tradeWindowTitle.Font = Enum.Font.GothamBold
	tradeWindowTitle.TextScaled = true
	tradeWindowTitle.ZIndex = 12
	tradeWindowTitle.Parent = tradeWindowDialog

	-- PAGINATED, zero-ClipsDescendants item picker — this used to be a
	-- ClipsDescendants manual-scroll "Viewport" Frame (the same idea as the
	-- Dex/Leaderboard panels' old scroll systems), and it hit the EXACT same
	-- "renders solid black in the live game" bug those two already hit and
	-- fixed (see the long war-story comment above dexContent in this same
	-- function) — a player reported this exact box showing completely empty/
	-- black with no item names visible at all. Fixed the same proven way:
	-- zero ClipsDescendants Frames anywhere, PAGES of plain non-clipping
	-- Frames instead of a scrolling list. ensureTradeItemRowsBuilt below
	-- pre-builds every row ONCE; unlike Dex (whose full ~91-row set is always
	-- the same, so its pages are packed once and never repacked), which
	-- creatures are actually OWNED changes every time the trade window opens,
	-- so the pages themselves are (re)packed fresh in ShowTradeWindow every
	-- open — see packTradeItemsPages/showTradeItemsPage below.
	local tradeItemsContent = Instance.new("Frame")
	tradeItemsContent.Name = "ItemsContent"
	tradeItemsContent.Size = UDim2.new(0, 260, 0, 260)
	tradeItemsContent.Position = UDim2.new(0, 10, 0, 52)
	tradeItemsContent.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	tradeItemsContent.BorderSizePixel = 0
	tradeItemsContent.ZIndex = 12
	tradeItemsContent.Parent = tradeWindowDialog
	Instance.new("UICorner", tradeItemsContent).CornerRadius = UDim.new(0, 8)

	local tradeItemsPrevButton = Instance.new("TextButton")
	tradeItemsPrevButton.Name = "ItemsPrevButton"
	tradeItemsPrevButton.Size = UDim2.new(0, 80, 0, 30)
	tradeItemsPrevButton.Position = UDim2.new(0, 10, 0, 318)
	tradeItemsPrevButton.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
	tradeItemsPrevButton.AutoButtonColor = false
	tradeItemsPrevButton.TextColor3 = Color3.new(1, 1, 1)
	tradeItemsPrevButton.Font = Enum.Font.GothamBold
	tradeItemsPrevButton.TextScaled = true
	tradeItemsPrevButton.Text = "◀"
	tradeItemsPrevButton.ZIndex = 12
	tradeItemsPrevButton.Parent = tradeWindowDialog
	Instance.new("UICorner", tradeItemsPrevButton).CornerRadius = UDim.new(0, 8)

	local tradeItemsPageLabel = Instance.new("TextLabel")
	tradeItemsPageLabel.Name = "ItemsPageLabel"
	tradeItemsPageLabel.Size = UDim2.new(0, 90, 0, 30)
	tradeItemsPageLabel.Position = UDim2.new(0, 95, 0, 318)
	tradeItemsPageLabel.BackgroundTransparency = 1
	tradeItemsPageLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	tradeItemsPageLabel.Font = Enum.Font.GothamBold
	tradeItemsPageLabel.TextScaled = true
	tradeItemsPageLabel.Text = ""
	tradeItemsPageLabel.ZIndex = 12
	tradeItemsPageLabel.Parent = tradeWindowDialog

	local tradeItemsNextButton = Instance.new("TextButton")
	tradeItemsNextButton.Name = "ItemsNextButton"
	tradeItemsNextButton.Size = UDim2.new(0, 80, 0, 30)
	tradeItemsNextButton.Position = UDim2.new(0, 190, 0, 318)
	tradeItemsNextButton.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
	tradeItemsNextButton.AutoButtonColor = false
	tradeItemsNextButton.TextColor3 = Color3.new(1, 1, 1)
	tradeItemsNextButton.Font = Enum.Font.GothamBold
	tradeItemsNextButton.TextScaled = true
	tradeItemsNextButton.Text = "▶"
	tradeItemsNextButton.ZIndex = 12
	tradeItemsNextButton.Parent = tradeWindowDialog
	Instance.new("UICorner", tradeItemsNextButton).CornerRadius = UDim.new(0, 8)

	-- The ~91 item rows themselves are NOT built here — see
	-- ensureTradeItemRowsBuilt below (right above ShowTradeWindow) and the
	-- comment there for why they're built lazily, the first time the trade
	-- window actually opens, instead of right here at spawn.

	local tradeOpponentNameLabel = Instance.new("TextLabel")
	tradeOpponentNameLabel.Name = "OpponentNameLabel"
	tradeOpponentNameLabel.Size = UDim2.new(0, 270, 0, 24)
	tradeOpponentNameLabel.Position = UDim2.new(0, 280, 0, 52)
	tradeOpponentNameLabel.BackgroundTransparency = 1
	tradeOpponentNameLabel.TextColor3 = Color3.new(1, 1, 1)
	tradeOpponentNameLabel.TextXAlignment = Enum.TextXAlignment.Left
	tradeOpponentNameLabel.Font = Enum.Font.Gotham
	tradeOpponentNameLabel.TextScaled = true
	tradeOpponentNameLabel.Text = ""
	tradeOpponentNameLabel.ZIndex = 12
	tradeOpponentNameLabel.Parent = tradeWindowDialog

	local tradeMyOfferLabel = Instance.new("TextLabel")
	tradeMyOfferLabel.Name = "MyOfferLabel"
	tradeMyOfferLabel.Size = UDim2.new(0, 270, 0, 60)
	tradeMyOfferLabel.Position = UDim2.new(0, 280, 0, 90)
	tradeMyOfferLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	tradeMyOfferLabel.TextColor3 = Color3.new(1, 1, 1)
	tradeMyOfferLabel.TextWrapped = true
	tradeMyOfferLabel.Font = Enum.Font.GothamBold
	tradeMyOfferLabel.TextScaled = true
	tradeMyOfferLabel.Text = "Dein Angebot: (nichts ausgewählt)"
	tradeMyOfferLabel.ZIndex = 12
	tradeMyOfferLabel.Parent = tradeWindowDialog
	Instance.new("UICorner", tradeMyOfferLabel).CornerRadius = UDim.new(0, 8)

	local tradeOpponentOfferLabel = Instance.new("TextLabel")
	tradeOpponentOfferLabel.Name = "OpponentOfferLabel"
	tradeOpponentOfferLabel.Size = UDim2.new(0, 270, 0, 60)
	tradeOpponentOfferLabel.Position = UDim2.new(0, 280, 0, 156)
	tradeOpponentOfferLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	tradeOpponentOfferLabel.TextColor3 = Color3.new(1, 1, 1)
	tradeOpponentOfferLabel.TextWrapped = true
	tradeOpponentOfferLabel.Font = Enum.Font.GothamBold
	tradeOpponentOfferLabel.TextScaled = true
	tradeOpponentOfferLabel.Text = "Angebot: wählt noch..."
	tradeOpponentOfferLabel.ZIndex = 12
	tradeOpponentOfferLabel.Parent = tradeWindowDialog
	Instance.new("UICorner", tradeOpponentOfferLabel).CornerRadius = UDim.new(0, 8)

	local tradeConfirmButton = Instance.new("TextButton")
	tradeConfirmButton.Name = "ConfirmButton"
	tradeConfirmButton.Size = UDim2.new(0, 270, 0, 44)
	tradeConfirmButton.Position = UDim2.new(0, 280, 1, -100)
	tradeConfirmButton.BackgroundColor3 = Color3.fromRGB(40, 170, 90)
	tradeConfirmButton.TextColor3 = Color3.new(1, 1, 1)
	tradeConfirmButton.Font = Enum.Font.GothamBold
	tradeConfirmButton.TextScaled = true
	tradeConfirmButton.Text = "Bestätigen"
	tradeConfirmButton.ZIndex = 12
	tradeConfirmButton.Parent = tradeWindowDialog
	Instance.new("UICorner", tradeConfirmButton).CornerRadius = UDim.new(0, 8)

	local tradeCancelButton = Instance.new("TextButton")
	tradeCancelButton.Name = "CancelButton"
	tradeCancelButton.Size = UDim2.new(0, 270, 0, 44)
	tradeCancelButton.Position = UDim2.new(0, 280, 1, -50)
	tradeCancelButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	tradeCancelButton.TextColor3 = Color3.new(1, 1, 1)
	tradeCancelButton.Font = Enum.Font.GothamBold
	tradeCancelButton.TextScaled = true
	tradeCancelButton.Text = "Abbrechen"
	tradeCancelButton.ZIndex = 12
	tradeCancelButton.Parent = tradeWindowDialog
	Instance.new("UICorner", tradeCancelButton).CornerRadius = UDim.new(0, 8)

	-- === Rebirth confirmation dialog (hidden full-screen overlay) ================
	local rebirthOverlay = Instance.new("Frame")
	rebirthOverlay.Name = "RebirthOverlay"
	rebirthOverlay.Size = UDim2.new(1, 0, 1, 0)
	rebirthOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	rebirthOverlay.BackgroundTransparency = 0.5
	rebirthOverlay.Visible = false
	rebirthOverlay.ZIndex = 10
	rebirthOverlay.Parent = screenGui

	local rebirthDialog = Instance.new("Frame")
	rebirthDialog.Name = "RebirthDialog"
	rebirthDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	rebirthDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	rebirthDialog.Size = UDim2.new(0, 420, 0, 240)
	rebirthDialog.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	rebirthDialog.ZIndex = 11
	rebirthDialog.Parent = rebirthOverlay
	Instance.new("UICorner", rebirthDialog).CornerRadius = UDim.new(0, 14)

	local rebirthTitle = Instance.new("TextLabel")
	rebirthTitle.Name = "Title"
	rebirthTitle.Size = UDim2.new(1, -20, 0, 36)
	rebirthTitle.Position = UDim2.new(0, 10, 0, 10)
	rebirthTitle.BackgroundTransparency = 1
	rebirthTitle.Text = "Wiedergeburt bestätigen"
	rebirthTitle.TextColor3 = Color3.fromRGB(255, 200, 0)
	rebirthTitle.Font = Enum.Font.GothamBold
	rebirthTitle.TextScaled = true
	rebirthTitle.ZIndex = 12
	rebirthTitle.Parent = rebirthDialog

	local rebirthText = Instance.new("TextLabel")
	rebirthText.Name = "Text"
	rebirthText.Size = UDim2.new(1, -20, 0, 130)
	rebirthText.Position = UDim2.new(0, 10, 0, 50)
	rebirthText.BackgroundTransparency = 1
	rebirthText.TextColor3 = Color3.new(1, 1, 1)
	rebirthText.TextWrapped = true
	rebirthText.TextXAlignment = Enum.TextXAlignment.Left
	rebirthText.TextYAlignment = Enum.TextYAlignment.Top
	rebirthText.Font = Enum.Font.Gotham
	rebirthText.TextSize = 16
	rebirthText.ZIndex = 12
	rebirthText.Text = ""
	rebirthText.Parent = rebirthDialog

	local yesButton = Instance.new("TextButton")
	yesButton.Name = "YesButton"
	yesButton.Size = UDim2.new(0, 190, 0, 44)
	yesButton.Position = UDim2.new(0, 10, 1, -54)
	yesButton.BackgroundColor3 = Color3.fromRGB(40, 170, 90)
	yesButton.TextColor3 = Color3.new(1, 1, 1)
	yesButton.Font = Enum.Font.GothamBold
	yesButton.TextScaled = true
	yesButton.Text = "Bestätigen"
	yesButton.ZIndex = 12
	yesButton.Parent = rebirthDialog
	Instance.new("UICorner", yesButton).CornerRadius = UDim.new(0, 8)

	local noButton = Instance.new("TextButton")
	noButton.Name = "NoButton"
	noButton.Size = UDim2.new(0, 190, 0, 44)
	noButton.Position = UDim2.new(1, -200, 1, -54)
	noButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	noButton.TextColor3 = Color3.new(1, 1, 1)
	noButton.Font = Enum.Font.GothamBold
	noButton.TextScaled = true
	noButton.Text = "Abbrechen"
	noButton.ZIndex = 12
	noButton.Parent = rebirthDialog
	Instance.new("UICorner", noButton).CornerRadius = UDim.new(0, 8)

	-- Gamepad/keyboard: Left/Right between Yes/No. Rebirth wipes Cash/Sprung/
	-- Floor progress, so — unlike most other dialogs here — the SAFER
	-- default focus (set in ShowRebirthConfirm below) is Cancel, not Confirm.
	wireHorizontalChain({ yesButton, noButton })

	-- === Sell confirmation dialog (hidden full-screen overlay) ===================
	-- On request ("ich möchte bei dem verkaufen von Brainroth, das
	-- nachgefragt wird ob du es verkaufen willst") — a pedestal's Sell
	-- prompt no longer sells instantly; it opens this Yes/No dialog first
	-- (see BaseService.lua's sellPrompt.Triggered + init.client.lua's
	-- RequestSellConfirm listener). Exact same structure as the Rebirth
	-- confirmation dialog just above, just its own overlay/dialog instances
	-- (so both can never fight over the same Visible flag) and a distinct
	-- teal accent instead of Rebirth's gold.
	local sellOverlay = Instance.new("Frame")
	sellOverlay.Name = "SellOverlay"
	sellOverlay.Size = UDim2.new(1, 0, 1, 0)
	sellOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	sellOverlay.BackgroundTransparency = 0.5
	sellOverlay.Visible = false
	sellOverlay.ZIndex = 10
	sellOverlay.Parent = screenGui

	local sellDialog = Instance.new("Frame")
	sellDialog.Name = "SellDialog"
	sellDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	sellDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	sellDialog.Size = UDim2.new(0, 380, 0, 200)
	sellDialog.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	sellDialog.ZIndex = 11
	sellDialog.Parent = sellOverlay
	Instance.new("UICorner", sellDialog).CornerRadius = UDim.new(0, 14)

	local sellTitle = Instance.new("TextLabel")
	sellTitle.Name = "Title"
	sellTitle.Size = UDim2.new(1, -20, 0, 36)
	sellTitle.Position = UDim2.new(0, 10, 0, 10)
	sellTitle.BackgroundTransparency = 1
	sellTitle.Text = "Verkaufen bestätigen"
	sellTitle.TextColor3 = Color3.fromRGB(60, 200, 140)
	sellTitle.Font = Enum.Font.GothamBold
	sellTitle.TextScaled = true
	sellTitle.ZIndex = 12
	sellTitle.Parent = sellDialog

	local sellText = Instance.new("TextLabel")
	sellText.Name = "Text"
	sellText.Size = UDim2.new(1, -20, 0, 90)
	sellText.Position = UDim2.new(0, 10, 0, 50)
	sellText.BackgroundTransparency = 1
	sellText.TextColor3 = Color3.new(1, 1, 1)
	sellText.TextWrapped = true
	sellText.TextXAlignment = Enum.TextXAlignment.Left
	sellText.TextYAlignment = Enum.TextYAlignment.Top
	sellText.Font = Enum.Font.Gotham
	sellText.TextSize = 16
	sellText.ZIndex = 12
	sellText.Text = ""
	sellText.Parent = sellDialog

	local sellYesButton = Instance.new("TextButton")
	sellYesButton.Name = "YesButton"
	sellYesButton.Size = UDim2.new(0, 170, 0, 44)
	sellYesButton.Position = UDim2.new(0, 10, 1, -54)
	sellYesButton.BackgroundColor3 = Color3.fromRGB(40, 170, 90)
	sellYesButton.TextColor3 = Color3.new(1, 1, 1)
	sellYesButton.Font = Enum.Font.GothamBold
	sellYesButton.TextScaled = true
	sellYesButton.Text = "Verkaufen"
	sellYesButton.ZIndex = 12
	sellYesButton.Parent = sellDialog
	Instance.new("UICorner", sellYesButton).CornerRadius = UDim.new(0, 8)

	local sellNoButton = Instance.new("TextButton")
	sellNoButton.Name = "NoButton"
	sellNoButton.Size = UDim2.new(0, 170, 0, 44)
	sellNoButton.Position = UDim2.new(1, -180, 1, -54)
	sellNoButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	sellNoButton.TextColor3 = Color3.new(1, 1, 1)
	sellNoButton.Font = Enum.Font.GothamBold
	sellNoButton.TextScaled = true
	sellNoButton.Text = "Abbrechen"
	sellNoButton.ZIndex = 12
	sellNoButton.Parent = sellDialog
	Instance.new("UICorner", sellNoButton).CornerRadius = UDim.new(0, 8)

	-- Gamepad/keyboard: same Left/Right Yes/No chain as the Rebirth dialog
	-- above, same "default focus is Cancel" safety reasoning (selling the
	-- wrong creature by accident is exactly the mistake this whole confirm
	-- dialog was added to prevent).
	wireHorizontalChain({ sellYesButton, sellNoButton })

	-- === Jump Upgrade panel (hidden full-screen overlay) ==========================
	-- Opened by walking up to the Jump Upgrade kiosk (see BaseService.lua's
	-- buildStations + the RequestJumpUpgradePanel remote, wired in
	-- init.client.lua) — bulk-buys Sprung-points (GameConfig.JumpUpgrade /
	-- EconomyService.BuyJumpUpgrade) instead of the old single-tier-at-a-time
	-- purchase. Deliberately built from a plain Frame (JumpOptionsList)
	-- rather than a ScrollingFrame — only ever 4 fixed-height buttons, no
	-- scrolling needed at all, which also means none of the ScrollingFrame+
	-- UICorner rendering issues the Dex/Trade panels hit can apply here.
	-- Bright rounded/thick-outlined "candy" styling (approximated with
	-- UICorner + UIStroke, no custom art) in orange — distinct from every
	-- other panel's accent color (Rebirth=gold, Trade=blue, Dex=blue-ish).
	local jumpOverlay = Instance.new("Frame")
	jumpOverlay.Name = "JumpUpgradeOverlay"
	jumpOverlay.Size = UDim2.new(1, 0, 1, 0)
	jumpOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	jumpOverlay.BackgroundTransparency = 0.5
	jumpOverlay.Visible = false
	jumpOverlay.ZIndex = 10
	jumpOverlay.Parent = screenGui

	local jumpDialog = Instance.new("Frame")
	jumpDialog.Name = "JumpUpgradeDialog"
	jumpDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	jumpDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	jumpDialog.Size = UDim2.new(0, 380, 0, 480)
	jumpDialog.BackgroundColor3 = Color3.fromRGB(255, 140, 40)
	jumpDialog.ZIndex = 11
	jumpDialog.Parent = jumpOverlay
	Instance.new("UICorner", jumpDialog).CornerRadius = UDim.new(0, 24)
	local jumpDialogStroke = Instance.new("UIStroke")
	jumpDialogStroke.Color = Color3.fromRGB(140, 70, 10)
	jumpDialogStroke.Thickness = 4
	jumpDialogStroke.Parent = jumpDialog

	local jumpTitle = Instance.new("TextLabel")
	jumpTitle.Name = "Title"
	jumpTitle.Size = UDim2.new(1, -70, 0, 40)
	jumpTitle.Position = UDim2.new(0, 16, 0, 16)
	jumpTitle.BackgroundTransparency = 1
	jumpTitle.Text = "⬆️ Sprung-Upgrade"
	jumpTitle.TextColor3 = Color3.new(1, 1, 1)
	jumpTitle.TextStrokeTransparency = 0.3
	jumpTitle.Font = Enum.Font.GothamBold
	jumpTitle.TextScaled = true
	jumpTitle.TextXAlignment = Enum.TextXAlignment.Left
	jumpTitle.ZIndex = 12
	jumpTitle.Parent = jumpDialog

	local jumpCloseButton = Instance.new("TextButton")
	jumpCloseButton.Name = "CloseButton"
	jumpCloseButton.Size = UDim2.new(0, 40, 0, 40)
	jumpCloseButton.Position = UDim2.new(1, -56, 0, 16)
	jumpCloseButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	jumpCloseButton.TextColor3 = Color3.new(1, 1, 1)
	jumpCloseButton.Font = Enum.Font.GothamBold
	jumpCloseButton.TextScaled = true
	jumpCloseButton.Text = "X" -- "✕" doesn't render in Roblox's default UI fonts — see dexCloseButton's comment above
	jumpCloseButton.ZIndex = 12
	jumpCloseButton.Parent = jumpDialog
	Instance.new("UICorner", jumpCloseButton).CornerRadius = UDim.new(0, 10)

	local jumpStatusLabel = Instance.new("TextLabel")
	jumpStatusLabel.Name = "StatusLabel"
	jumpStatusLabel.Size = UDim2.new(1, -32, 0, 56)
	jumpStatusLabel.Position = UDim2.new(0, 16, 0, 64)
	jumpStatusLabel.BackgroundTransparency = 1
	jumpStatusLabel.TextColor3 = Color3.new(1, 1, 1)
	jumpStatusLabel.TextStrokeTransparency = 0.4
	jumpStatusLabel.TextWrapped = true
	jumpStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	jumpStatusLabel.TextYAlignment = Enum.TextYAlignment.Top
	jumpStatusLabel.Font = Enum.Font.GothamBold
	jumpStatusLabel.TextScaled = true
	jumpStatusLabel.Text = ""
	jumpStatusLabel.ZIndex = 12
	jumpStatusLabel.Parent = jumpDialog

	local jumpMaxLabel = Instance.new("TextLabel")
	jumpMaxLabel.Name = "MaxLabel"
	jumpMaxLabel.Size = UDim2.new(1, -32, 1, -148)
	jumpMaxLabel.Position = UDim2.new(0, 16, 0, 132)
	jumpMaxLabel.BackgroundTransparency = 1
	jumpMaxLabel.TextColor3 = Color3.new(1, 1, 1)
	jumpMaxLabel.TextStrokeTransparency = 0.3
	jumpMaxLabel.TextWrapped = true
	jumpMaxLabel.Font = Enum.Font.GothamBold
	jumpMaxLabel.TextScaled = true
	jumpMaxLabel.Text = "🎉 Maximaler Sprung erreicht!"
	jumpMaxLabel.Visible = false
	jumpMaxLabel.ZIndex = 12
	jumpMaxLabel.Parent = jumpDialog

	local jumpOptionsList = Instance.new("Frame")
	jumpOptionsList.Name = "OptionsList"
	jumpOptionsList.Size = UDim2.new(1, -32, 1, -148)
	jumpOptionsList.Position = UDim2.new(0, 16, 0, 132)
	jumpOptionsList.BackgroundTransparency = 1
	jumpOptionsList.ZIndex = 12
	jumpOptionsList.Parent = jumpDialog

	local jumpOptionsListLayout = Instance.new("UIListLayout")
	-- Explicit, rather than trusting the default: without this, rows were
	-- sorting by NAME ("Row_1" < "Row_10" < "Row_25" < "Row_5", alphabetical)
	-- instead of by GameConfig.JumpUpgrade.BulkAmounts' actual order — each
	-- row's LayoutOrder below is already set correctly (1, 2, 3, 4 matching
	-- amount order), this just makes UIListLayout actually use it.
	jumpOptionsListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	jumpOptionsListLayout.Padding = UDim.new(0, 6)
	jumpOptionsListLayout.Parent = jumpOptionsList

	-- Built ONCE, right here, up front — one button per GameConfig.
	-- JumpUpgrade.BulkAmounts entry — and NEVER destroyed/recreated
	-- afterward. PopulateJumpUpgrade below only ever changes an EXISTING
	-- button's Text/Color/Visible/Attribute. This is deliberately different
	-- from how the Dex/Trade panels build their rows (fresh Instance.new()
	-- every time they're populated) — that approach is where every single
	-- rendering headache this project has hit came from. Every OTHER UI
	-- element that has never had a rendering problem (stats HUD, kiosk
	-- billboards, toasts) is built once and only ever mutated afterward —
	-- same idea here, since this panel's button COUNT is small and fixed
	-- (unlike Dex's ~90 rows or Trade's variable inventory), so pre-building
	-- costs nothing and sidesteps the whole bug class entirely.
	-- Each bulk amount gets a ROW with a title ("+N Sprung") and TWO payment
	-- buttons side by side — Cash (left, price kept live by
	-- PopulateJumpUpgrade) and Robux (right, a Developer Product purchase —
	-- see GameConfig.JumpUpgrade.RobuxProducts). The Robux button is only
	-- shown once a real Product ID is configured there (still built here,
	-- just left Visible = false, so filling in an ID later needs no code
	-- change — PopulateJumpUpgrade / the price-fetch below already handle
	-- it). Everything here is built ONCE, same reasoning as the Cash-only
	-- version this replaced (see the long comment above this block).
	local jumpBulkButtons = {} -- Cash buttons, parallel to BulkAmounts
	local jumpRobuxButtons = {} -- Robux buttons, parallel to BulkAmounts (some may stay hidden)
	for i, amount in ipairs(GameConfig.JumpUpgrade.BulkAmounts) do
		local row = Instance.new("Frame")
		row.Name = "Row_" .. amount
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, 72)
		row.BackgroundTransparency = 1
		row.ZIndex = 12
		row.Parent = jumpOptionsList

		local titleLabel = Instance.new("TextLabel")
		titleLabel.Name = "Title"
		titleLabel.Size = UDim2.new(1, 0, 0, 18)
		titleLabel.BackgroundTransparency = 1
		titleLabel.TextColor3 = Color3.new(1, 1, 1)
		titleLabel.TextStrokeTransparency = 0.3
		titleLabel.Font = Enum.Font.GothamBold
		titleLabel.TextScaled = true
		titleLabel.Text = "+" .. amount .. " Sprung"
		titleLabel.ZIndex = 12
		titleLabel.Parent = row

		local cashButton = Instance.new("TextButton")
		cashButton.Name = "CashButton"
		cashButton.Size = UDim2.new(0.6, -4, 0, 46)
		cashButton.Position = UDim2.new(0, 0, 0, 22)
		cashButton.BackgroundColor3 = Color3.fromRGB(255, 175, 60)
		cashButton.AutoButtonColor = false
		cashButton.TextColor3 = Color3.new(1, 1, 1)
		cashButton.TextStrokeTransparency = 0.3
		cashButton.TextWrapped = true
		cashButton.Font = Enum.Font.GothamBold
		cashButton.TextScaled = true
		cashButton.Text = "$?"
		cashButton:SetAttribute("BulkAmount", amount)
		cashButton.ZIndex = 12
		cashButton.Parent = row
		Instance.new("UICorner", cashButton).CornerRadius = UDim.new(0, 14)
		local cashStroke = Instance.new("UIStroke")
		cashStroke.Color = Color3.fromRGB(140, 70, 10)
		cashStroke.Thickness = 3
		cashStroke.Parent = cashButton

		local robuxButton = Instance.new("TextButton")
		robuxButton.Name = "RobuxButton"
		robuxButton.Size = UDim2.new(0.4, -4, 0, 46)
		robuxButton.Position = UDim2.new(0.6, 4, 0, 22)
		robuxButton.BackgroundColor3 = Color3.fromRGB(40, 160, 90)
		robuxButton.AutoButtonColor = false
		robuxButton.TextColor3 = Color3.new(1, 1, 1)
		robuxButton.TextStrokeTransparency = 0.3
		robuxButton.TextWrapped = true
		robuxButton.Font = Enum.Font.GothamBold
		robuxButton.TextScaled = true
		robuxButton.Text = "? Robux"
		robuxButton.Visible = false -- shown once GetProductInfo confirms a real product below
		robuxButton.ZIndex = 12
		robuxButton.Parent = row
		Instance.new("UICorner", robuxButton).CornerRadius = UDim.new(0, 14)
		local robuxStroke = Instance.new("UIStroke")
		robuxStroke.Color = Color3.fromRGB(15, 90, 45)
		robuxStroke.Thickness = 3
		robuxStroke.Parent = robuxButton

		local product = GameConfig.JumpUpgrade.RobuxProducts[i]
		local productId = product and product.ProductId
		if productId and productId > 0 then
			robuxButton:SetAttribute("ProductId", productId)
			-- GetProductInfo is a network call — fetched once here, off the
			-- main thread, rather than blocking the whole HUD build on it.
			-- If it fails (bad ID, offline, etc.) the button just stays
			-- hidden instead of showing a purchase prompt for something
			-- that turned out not to exist.
			task.spawn(function()
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
				end)
				if ok and info and info.PriceInRobux then
					-- Spelled out ("59 Robux"), not the "🔶" diamond emoji + bare
					-- number this used to be — on request, since that emoji
					-- doesn't actually render in Roblox's default UI fonts, so
					-- the button just showed a naked, unexplained number
					-- ("kann man das ändern das klar ersichtlich ist das man
					-- Robux zahlen muss").
					robuxButton.Text = tostring(info.PriceInRobux) .. " Robux"
					robuxButton.Visible = true
					-- Gamepad/keyboard: only link Left/Right into the Robux
					-- button once it's actually visible (this fetch can fail
					-- or never resolve — see the comment above) — a link
					-- pointing at a still-hidden button would strand
					-- navigation on a button nobody can see.
					wireHorizontalChain({ cashButton, robuxButton })
				end
			end)
		end

		table.insert(jumpBulkButtons, cashButton)
		table.insert(jumpRobuxButtons, robuxButton)
	end

	-- Gamepad/keyboard: Up/Down through Close + every Cash button (the
	-- always-visible "spine" of this panel — Robux buttons hang off it
	-- Left/Right per-row instead, wired above once each one actually shows).
	do
		local jumpChain = { jumpCloseButton }
		for _, button in ipairs(jumpBulkButtons) do
			table.insert(jumpChain, button)
		end
		wireVerticalChain(jumpChain)
	end

	-- === Glücksrad (wheel of fortune) panel (hidden full-screen overlay) =========
	-- Opened by walking up to the shared wheel kiosk (see BaseService.lua's
	-- buildWheelKiosk + the RequestWheelPanel remote, wired in
	-- init.client.lua). Shows GameConfig.WheelOfFortune.Segments (3 fixed
	-- slices, always visible — Cash / Brainrot-Geheimnis / 2x Cash, reduced
	-- from an earlier 8-segment layout on request, "auf 3 Segmente
	-- umbauen" — NOT the exact Prizes rows, see that table's comment for
	-- why) arranged in a circle, plus two buttons: a free once-a-day spin
	-- and a Robux spin (on request: "einmal am Tag Gratis oder mit Robux
	-- immer"). Purple "candy" styling, distinct from Jump Upgrade's orange
	-- and every other panel's own accent color.
	--
	-- MECHANIC: back to the ORIGINAL "static wheel + rotating needle"
	-- design (switched back on request, after the 3-segment redesign made
	-- the alternative "whole wheel spins" design impractical to combine
	-- with the user's own detailed wheel artwork — pre-rotating that
	-- artwork's text/icons by the large 120°/240° amounts 3 equal segments
	-- require badly distorted and overlapped it; a needle only ever needs
	-- to rotate BY the small amount the player already sees, no per-segment
	-- pre-rotation of the artwork itself is needed). The wheel face
	-- (wheelSpinner below) now NEVER rotates — it can be the user's own
	-- artwork completely unmodified, at full quality. Instead, a needle
	-- (wheelNeedle below, pivoting from the circle's center) spins and
	-- points at whichever segment the server actually rolled (see
	-- UIBuilder.PlayWheelSpin below).
	--
	-- The wheel face itself is built from plain Frames/UICorner/text as a
	-- fallback — see hasWheelImage below — whenever no real WheelImageAssetId
	-- artwork is configured. Segments sit at FIXED positions around the
	-- circle and never move at all now (neither the face nor its labels) —
	-- simpler and safer than any rotation-based approach, and avoids any
	-- risk of segment text becoming unreadable mid-spin.
	--
	-- Because the Brainrot-Geheimnis slice's own odds (Diamond/Galaxy/
	-- Hacker/Lava, GameConfig.WheelOfFortune.MysteryRarities) aren't
	-- something a single wedge can show on its own, the dialog is widened
	-- and a static info panel sits to the RIGHT of the circle listing that
	-- breakdown — modeled on a reference screenshot the user provided of
	-- another game's "Kristallrad"/"Kristallgeheimnis" mystery-slice UI.
	local wheelOverlay = Instance.new("Frame")
	wheelOverlay.Name = "WheelOverlay"
	wheelOverlay.Size = UDim2.new(1, 0, 1, 0)
	wheelOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	wheelOverlay.BackgroundTransparency = 0.5
	wheelOverlay.Visible = false
	wheelOverlay.ZIndex = 10
	wheelOverlay.Parent = screenGui

	local wheelDialog = Instance.new("Frame")
	wheelDialog.Name = "WheelDialog"
	wheelDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	wheelDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	-- Widened 420 -> 640 (on request, rebuilding the wheel to 3 segments
	-- alongside the new Brainrot-Geheimnis side panel) — the extra width
	-- makes room for that panel to the right of the circle without
	-- shrinking the circle itself. Height 560 -> 580 (on request, redoing
	-- the bottom buttons into a 3-across "Kaufe 1 | Drehen (1) | Kaufe 3"
	-- row) for the extra "x2 Glück" ribbon + explanatory caption below it.
	wheelDialog.Size = UDim2.new(0, 640, 0, 580)
	wheelDialog.BackgroundColor3 = Color3.fromRGB(90, 30, 120)
	wheelDialog.ZIndex = 11
	wheelDialog.Parent = wheelOverlay
	Instance.new("UICorner", wheelDialog).CornerRadius = UDim.new(0, 24)
	local wheelDialogStroke = Instance.new("UIStroke")
	wheelDialogStroke.Color = Color3.fromRGB(40, 10, 60)
	wheelDialogStroke.Thickness = 4
	wheelDialogStroke.Parent = wheelDialog

	local wheelTitle = Instance.new("TextLabel")
	wheelTitle.Name = "Title"
	wheelTitle.Size = UDim2.new(1, -70, 0, 40)
	wheelTitle.Position = UDim2.new(0, 16, 0, 16)
	wheelTitle.BackgroundTransparency = 1
	wheelTitle.Text = "🎡 Glücksrad"
	wheelTitle.TextColor3 = Color3.new(1, 1, 1)
	wheelTitle.TextStrokeTransparency = 0.3
	wheelTitle.Font = Enum.Font.GothamBold
	wheelTitle.TextScaled = true
	wheelTitle.TextXAlignment = Enum.TextXAlignment.Left
	wheelTitle.ZIndex = 12
	wheelTitle.Parent = wheelDialog

	local wheelCloseButton = Instance.new("TextButton")
	wheelCloseButton.Name = "CloseButton"
	wheelCloseButton.Size = UDim2.new(0, 40, 0, 40)
	wheelCloseButton.Position = UDim2.new(1, -56, 0, 16)
	wheelCloseButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	wheelCloseButton.TextColor3 = Color3.new(1, 1, 1)
	wheelCloseButton.Font = Enum.Font.GothamBold
	wheelCloseButton.TextScaled = true
	wheelCloseButton.Text = "X" -- "✕" doesn't render in Roblox's default UI fonts — see dexCloseButton's comment above
	wheelCloseButton.ZIndex = 12
	wheelCloseButton.Parent = wheelDialog
	Instance.new("UICorner", wheelCloseButton).CornerRadius = UDim.new(0, 10)

	-- The circle itself — a square Frame with a 50%-scale UICorner (the
	-- standard Roblox "make a Frame round" trick). Segment tiles and the
	-- needle are both children of THIS Frame so their Position math can
	-- stay relative to one shared center (0.5, 0, 0.5, 0) instead of
	-- re-deriving the dialog's own layout offsets.
	-- Re-anchored to the LEFT side (was centered) now that the wheel is
	-- only one of two things side-by-side in the widened dialog — the
	-- Brainrot-Geheimnis info panel takes the freed-up right side.
	local wheelCircle = Instance.new("Frame")
	wheelCircle.Name = "Circle"
	wheelCircle.AnchorPoint = Vector2.new(0, 0)
	wheelCircle.Position = UDim2.new(0, 30, 0, 68)
	wheelCircle.Size = UDim2.new(0, 300, 0, 300)
	wheelCircle.BackgroundColor3 = Color3.fromRGB(35, 15, 50)
	wheelCircle.ZIndex = 12
	wheelCircle.Parent = wheelDialog
	Instance.new("UICorner", wheelCircle).CornerRadius = UDim.new(0.5, 0)
	local wheelCircleStroke = Instance.new("UIStroke")
	wheelCircleStroke.Color = Color3.fromRGB(220, 180, 255)
	wheelCircleStroke.Thickness = 3
	wheelCircleStroke.Parent = wheelCircle

	-- angleDeg (used both below and in PlayWheelSpin) uses the same
	-- clockwise-from-top convention as a GuiObject's own .Rotation property
	-- — index 1 = straight up / 12 o'clock, then clockwise every 360/N
	-- degrees. This is each segment's FIXED position on the never-moving
	-- wheel face — PlayWheelSpin below rotates wheelNeedle (not the face)
	-- BY exactly this angle to point at whichever segment matches
	-- angleDeg(i), so no separate angle table is needed on the client, it's
	-- re-derived identically wherever needed.
	local wheelTileRadius = 108
	local wheelSegmentCount = #GameConfig.WheelOfFortune.Segments

	-- wheelSpinner — everything that visually represents GameConfig.
	-- WheelOfFortune.Segments (the artwork OR the fallback tiles below,
	-- however many segments that table has) lives inside this ONE
	-- sub-Frame, sized/centered to exactly fill wheelCircle. UNLIKE its
	-- name suggests (kept from an earlier design, see this panel's top
	-- comment), this Frame is never rotated any more — the wheel face is
	-- completely static now; wheelNeedle below is the only thing that
	-- spins.
	local wheelSpinner = Instance.new("Frame")
	wheelSpinner.Name = "Spinner"
	wheelSpinner.AnchorPoint = Vector2.new(0.5, 0.5)
	wheelSpinner.Position = UDim2.new(0.5, 0, 0.5, 0)
	wheelSpinner.Size = UDim2.new(1, 0, 1, 0)
	wheelSpinner.BackgroundTransparency = 1
	wheelSpinner.ZIndex = 13
	wheelSpinner.Parent = wheelCircle

	-- GameConfig.WheelOfFortune.WheelImageAssetId: a real pie-chart artwork
	-- (6 equal wedges, SAME order/angle convention as above — index 1 = top,
	-- clockwise) uploaded via Studio's Asset Manager. When it's configured,
	-- use it as a single ImageLabel instead of building 6 individual
	-- code-drawn tiles — much closer to a "real" wheel-of-fortune look.
	-- Falls back to the original code-drawn tiles (unchanged from this
	-- panel's first version) whenever no artwork id is set, so the panel
	-- stays fully functional either way, same "0/'' = not configured yet"
	-- convention as every other asset id in this file.
	local wheelImageAssetId = GameConfig.WheelOfFortune.WheelImageAssetId
	local hasWheelImage = wheelImageAssetId and tostring(wheelImageAssetId) ~= "" and tostring(wheelImageAssetId) ~= "0"

	if hasWheelImage then
		local wheelImage = Instance.new("ImageLabel")
		wheelImage.Name = "Artwork"
		wheelImage.BackgroundTransparency = 1
		wheelImage.Size = UDim2.new(1, 0, 1, 0)
		wheelImage.Position = UDim2.new(0, 0, 0, 0)
		local assetIdStr = tostring(wheelImageAssetId)
		wheelImage.Image = assetIdStr:match("^rbxassetid://") and assetIdStr or ("rbxassetid://" .. assetIdStr)
		wheelImage.ScaleType = Enum.ScaleType.Fit
		wheelImage.ZIndex = 13
		wheelImage.Parent = wheelSpinner
	else
		-- One tile per GameConfig.WheelOfFortune.Segments entry, placed at a
		-- fixed point around the spinner — computed once, here, with plain
		-- trigonometry; never moves again (nothing about the wheel face
		-- ever rotates now, see this panel's top comment — only wheelNeedle
		-- does).
		for i, segment in ipairs(GameConfig.WheelOfFortune.Segments) do
			local angleDeg = (i - 1) * (360 / wheelSegmentCount)
			local angleRad = math.rad(angleDeg)
			local offsetX = wheelTileRadius * math.sin(angleRad)
			local offsetY = -wheelTileRadius * math.cos(angleRad)

			local tile = Instance.new("Frame")
			tile.Name = "Segment_" .. segment.Key
			tile.AnchorPoint = Vector2.new(0.5, 0.5)
			tile.Position = UDim2.new(0.5, offsetX, 0.5, offsetY)
			tile.Size = UDim2.new(0, 72, 0, 72)
			tile.BackgroundColor3 = segment.Color
			tile.ZIndex = 13
			tile.Parent = wheelSpinner
			Instance.new("UICorner", tile).CornerRadius = UDim.new(0, 14)

			local tileIcon = Instance.new("TextLabel")
			tileIcon.Name = "Icon"
			tileIcon.Size = UDim2.new(1, 0, 0.55, 0)
			tileIcon.BackgroundTransparency = 1
			tileIcon.Text = segment.EmojiIcon
			tileIcon.TextScaled = true
			tileIcon.Font = Enum.Font.GothamBold
			tileIcon.ZIndex = 13
			tileIcon.Parent = tile

			local tileLabel = Instance.new("TextLabel")
			tileLabel.Name = "Label"
			tileLabel.Size = UDim2.new(1, 0, 0.35, 0)
			tileLabel.Position = UDim2.new(0, 0, 0.6, 0)
			tileLabel.BackgroundTransparency = 1
			tileLabel.Text = segment.Label
			tileLabel.TextColor3 = Color3.new(1, 1, 1)
			tileLabel.TextStrokeTransparency = 0.2
			tileLabel.Font = Enum.Font.GothamBold
			tileLabel.TextScaled = true
			tileLabel.ZIndex = 13
			tileLabel.Parent = tile
		end
	end

	-- The needle — THE thing PlayWheelSpin actually rotates now (see this
	-- panel's top comment for why this switched back from "whole wheel
	-- spins"). wheelNeedle is a plain invisible container centered exactly
	-- on the circle (so PlayWheelSpin can just set its .Rotation — pivoting
	-- correctly around the circle's true center) holding two purely
	-- decorative children that rotate WITH it: a slim shaft running from
	-- the center out toward the rim, and a small diamond-shaped tip at its
	-- outer end so the pointing direction is unambiguous. Restyled (on
	-- request, "die Nadel etwas dezenter mit einem Pfeil") from an earlier,
	-- much chunkier red-bar-plus-circle needle into this slimmer gold
	-- arrow, matching the wheel's own gold ring instead of standing out
	-- against it. At Rotation = 0 it points straight up (angleDeg = 0,
	-- matching segment 1 / index 1's own fixed position above), same
	-- clockwise-from-top convention as every other angle in this panel.
	local wheelNeedle = Instance.new("Frame")
	wheelNeedle.Name = "Needle"
	wheelNeedle.AnchorPoint = Vector2.new(0.5, 0.5)
	wheelNeedle.Position = UDim2.new(0.5, 0, 0.5, 0)
	wheelNeedle.Size = UDim2.new(1, 0, 1, 0)
	wheelNeedle.BackgroundTransparency = 1
	wheelNeedle.ZIndex = 14
	wheelNeedle.Parent = wheelCircle

	local wheelNeedleShaft = Instance.new("Frame")
	wheelNeedleShaft.Name = "Shaft"
	wheelNeedleShaft.AnchorPoint = Vector2.new(0.5, 1)
	wheelNeedleShaft.Position = UDim2.new(0.5, 0, 0.5, 0)
	wheelNeedleShaft.Size = UDim2.new(0, 7, 0, 108)
	wheelNeedleShaft.BackgroundColor3 = Color3.fromRGB(235, 185, 60)
	wheelNeedleShaft.ZIndex = 14
	wheelNeedleShaft.Parent = wheelNeedle
	Instance.new("UICorner", wheelNeedleShaft).CornerRadius = UDim.new(0.5, 0)
	local wheelNeedleShaftStroke = Instance.new("UIStroke")
	wheelNeedleShaftStroke.Color = Color3.fromRGB(95, 60, 10)
	wheelNeedleShaftStroke.Thickness = 1.5
	wheelNeedleShaftStroke.Parent = wheelNeedleShaft

	-- The tip is a small square rotated 45° (a diamond) rather than the
	-- previous circle — its upper corner reads as a clean, tapered
	-- arrowhead pointing outward, much less visually heavy than a round
	-- blob. Its own Rotation is a FIXED 45°, independent of wheelNeedle's
	-- animated Rotation — the two compose visually (this child renders
	-- rotated by its parent's current spin angle PLUS its own 45°), so the
	-- diamond shape stays a diamond throughout the whole spin instead of
	-- un-rotating itself.
	local wheelNeedleTip = Instance.new("Frame")
	wheelNeedleTip.Name = "Tip"
	wheelNeedleTip.AnchorPoint = Vector2.new(0.5, 0.5)
	wheelNeedleTip.Position = UDim2.new(0.5, 0, 0.5, -104)
	wheelNeedleTip.Size = UDim2.new(0, 16, 0, 16)
	wheelNeedleTip.Rotation = 45
	wheelNeedleTip.BackgroundColor3 = Color3.fromRGB(255, 245, 205)
	wheelNeedleTip.ZIndex = 14
	wheelNeedleTip.Parent = wheelNeedle
	Instance.new("UICorner", wheelNeedleTip).CornerRadius = UDim.new(0, 2)
	local wheelNeedleTipStroke = Instance.new("UIStroke")
	wheelNeedleTipStroke.Color = Color3.fromRGB(95, 60, 10)
	wheelNeedleTipStroke.Thickness = 1.5
	wheelNeedleTipStroke.Parent = wheelNeedleTip

	-- Decorative center cap — purely cosmetic (covers the needle's own
	-- pivot point at the circle's center, like the pin on a real spinner),
	-- parented to wheelCircle (NOT wheelNeedle), so it stays fixed while
	-- the needle spins underneath it.
	local wheelNeedleHub = Instance.new("Frame")
	wheelNeedleHub.Name = "Hub"
	wheelNeedleHub.AnchorPoint = Vector2.new(0.5, 0.5)
	wheelNeedleHub.Position = UDim2.new(0.5, 0, 0.5, 0)
	wheelNeedleHub.Size = UDim2.new(0, 26, 0, 26)
	wheelNeedleHub.BackgroundColor3 = Color3.fromRGB(255, 220, 80)
	wheelNeedleHub.ZIndex = 15
	wheelNeedleHub.Parent = wheelCircle
	Instance.new("UICorner", wheelNeedleHub).CornerRadius = UDim.new(0.5, 0)

	-- Brainrot-Geheimnis info panel — static, sits to the RIGHT of the
	-- circle (the freed-up space from widening wheelDialog above), showing
	-- the Brainrot-Geheimnis slice's OWN internal odds (GameConfig.
	-- WheelOfFortune.MysteryRarities), since a single wedge on the wheel
	-- itself can't show a 4-way breakdown. Percentages are computed here
	-- from the raw Weights (same "relative weight" mechanic as every other
	-- weighted table in this game) rather than hardcoded, so this panel
	-- can never drift out of sync with GameConfig if those Weights are
	-- ever re-tuned later.
	local wheelMysteryPanel = Instance.new("Frame")
	wheelMysteryPanel.Name = "MysteryPanel"
	wheelMysteryPanel.AnchorPoint = Vector2.new(0, 0)
	wheelMysteryPanel.Position = UDim2.new(0, 360, 0, 68)
	wheelMysteryPanel.Size = UDim2.new(0, 250, 0, 300)
	wheelMysteryPanel.BackgroundColor3 = Color3.fromRGB(55, 20, 75)
	wheelMysteryPanel.ZIndex = 12
	wheelMysteryPanel.Parent = wheelDialog
	Instance.new("UICorner", wheelMysteryPanel).CornerRadius = UDim.new(0, 16)
	local wheelMysteryStroke = Instance.new("UIStroke")
	wheelMysteryStroke.Color = Color3.fromRGB(220, 180, 255)
	wheelMysteryStroke.Thickness = 2
	wheelMysteryStroke.Parent = wheelMysteryPanel

	local wheelMysteryTitle = Instance.new("TextLabel")
	wheelMysteryTitle.Name = "Title"
	wheelMysteryTitle.Size = UDim2.new(1, -16, 0, 46)
	wheelMysteryTitle.Position = UDim2.new(0, 8, 0, 8)
	wheelMysteryTitle.BackgroundTransparency = 1
	wheelMysteryTitle.Text = "❓ Mystery-\nBrainrot"
	wheelMysteryTitle.TextColor3 = Color3.new(1, 1, 1)
	wheelMysteryTitle.TextStrokeTransparency = 0.3
	wheelMysteryTitle.TextWrapped = true
	wheelMysteryTitle.Font = Enum.Font.GothamBold
	wheelMysteryTitle.TextScaled = true
	wheelMysteryTitle.ZIndex = 13
	wheelMysteryTitle.Parent = wheelMysteryPanel

	local wheelMysterySubtitle = Instance.new("TextLabel")
	wheelMysterySubtitle.Name = "Subtitle"
	wheelMysterySubtitle.Size = UDim2.new(1, -16, 0, 22)
	wheelMysterySubtitle.Position = UDim2.new(0, 8, 0, 56)
	wheelMysterySubtitle.BackgroundTransparency = 1
	wheelMysterySubtitle.Text = "Bei 0,5% Treffer:"
	wheelMysterySubtitle.TextColor3 = Color3.fromRGB(230, 210, 255)
	wheelMysterySubtitle.Font = Enum.Font.Gotham
	wheelMysterySubtitle.TextScaled = true
	wheelMysterySubtitle.TextXAlignment = Enum.TextXAlignment.Left
	wheelMysterySubtitle.ZIndex = 13
	wheelMysterySubtitle.Parent = wheelMysteryPanel

	local wheelMysteryEntries = GameConfig.WheelOfFortune.MysteryRarities or {}
	local wheelMysteryTotalWeight = 0
	for _, entry in ipairs(wheelMysteryEntries) do
		wheelMysteryTotalWeight += entry.Weight
	end

	local wheelMysteryRowHeight = 44
	for i, entry in ipairs(wheelMysteryEntries) do
		local pct = wheelMysteryTotalWeight > 0 and (entry.Weight / wheelMysteryTotalWeight * 100) or 0
		local rarityDef = GameConfig.CreatureRarities[entry.Rarity]
		local rarityColor = (rarityDef and rarityDef.Color) or Color3.new(1, 1, 1)

		local row = Instance.new("Frame")
		row.Name = "Row_" .. entry.Rarity
		row.Size = UDim2.new(1, -16, 0, wheelMysteryRowHeight - 6)
		row.Position = UDim2.new(0, 8, 0, 84 + (i - 1) * wheelMysteryRowHeight)
		row.BackgroundColor3 = Color3.fromRGB(40, 12, 55)
		row.ZIndex = 13
		row.Parent = wheelMysteryPanel
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.AnchorPoint = Vector2.new(0, 0.5)
		swatch.Position = UDim2.new(0, 6, 0.5, 0)
		swatch.Size = UDim2.new(0, 14, 0, 14)
		swatch.BackgroundColor3 = rarityColor
		swatch.ZIndex = 14
		swatch.Parent = row
		Instance.new("UICorner", swatch).CornerRadius = UDim.new(0.5, 0)

		local rowLabel = Instance.new("TextLabel")
		rowLabel.Name = "Label"
		rowLabel.AnchorPoint = Vector2.new(0, 0.5)
		rowLabel.Position = UDim2.new(0, 28, 0.5, 0)
		rowLabel.Size = UDim2.new(1, -90, 1, 0)
		rowLabel.BackgroundTransparency = 1
		rowLabel.Text = entry.Rarity .. " Brainrot"
		rowLabel.TextColor3 = Color3.new(1, 1, 1)
		rowLabel.Font = Enum.Font.Gotham
		rowLabel.TextScaled = true
		rowLabel.TextXAlignment = Enum.TextXAlignment.Left
		rowLabel.ZIndex = 14
		rowLabel.Parent = row

		local rowPct = Instance.new("TextLabel")
		rowPct.Name = "Percent"
		rowPct.AnchorPoint = Vector2.new(1, 0.5)
		rowPct.Position = UDim2.new(1, -6, 0.5, 0)
		rowPct.Size = UDim2.new(0, 55, 1, 0)
		rowPct.BackgroundTransparency = 1
		rowPct.Text = string.format("%.0f%%", pct)
		rowPct.TextColor3 = Color3.fromRGB(255, 235, 120)
		rowPct.Font = Enum.Font.GothamBold
		rowPct.TextScaled = true
		rowPct.TextXAlignment = Enum.TextXAlignment.Right
		rowPct.ZIndex = 14
		rowPct.Parent = row
	end

	local wheelResultLabel = Instance.new("TextLabel")
	wheelResultLabel.Name = "ResultLabel"
	wheelResultLabel.Size = UDim2.new(1, -32, 0, 40)
	wheelResultLabel.Position = UDim2.new(0, 16, 0, 378)
	wheelResultLabel.BackgroundTransparency = 1
	wheelResultLabel.TextColor3 = Color3.new(1, 1, 1)
	wheelResultLabel.TextStrokeTransparency = 0.3
	wheelResultLabel.TextWrapped = true
	wheelResultLabel.Font = Enum.Font.GothamBold
	wheelResultLabel.TextScaled = true
	wheelResultLabel.Text = "Einmal am Tag gratis, oder jederzeit für Robux!"
	wheelResultLabel.ZIndex = 12
	wheelResultLabel.Parent = wheelDialog

	-- Three-across button row (redesigned on request, from the earlier
	-- stacked "Täglicher Spin" + "Spin kaufen (Robux)" full-width buttons,
	-- to match a reference screenshot: "Kaufe 1 | Drehen (1) | Kaufe 3").
	-- 640-wide dialog, 16px side margins, 8px gaps between the three ->
	-- each button is (640 - 32 - 16) / 3 ≈ 197px wide.
	local WHEEL_BUTTON_WIDTH = 197
	local WHEEL_BUTTON_Y = 440
	local WHEEL_BUY_ONE_X = 16
	local WHEEL_FREE_X = WHEEL_BUY_ONE_X + WHEEL_BUTTON_WIDTH + 8
	local WHEEL_BUY_THREE_X = WHEEL_FREE_X + WHEEL_BUTTON_WIDTH + 8

	-- "x2 Glück" ribbon — a small badge sitting just above EACH buy button
	-- (never above the middle free button, which never gets the buff) —
	-- purely cosmetic, hidden/shown together with its own button (see
	-- PopulateWheelState) since a not-yet-created Robux product has
	-- nothing to advertise a buff for.
	local function makeLuckRibbon(x)
		local ribbon = Instance.new("TextLabel")
		ribbon.Name = "LuckRibbon"
		ribbon.Size = UDim2.new(0, WHEEL_BUTTON_WIDTH, 0, 18)
		ribbon.Position = UDim2.new(0, x, 0, WHEEL_BUTTON_Y - 20)
		ribbon.BackgroundColor3 = Color3.fromRGB(255, 210, 60)
		ribbon.TextColor3 = Color3.fromRGB(70, 40, 0)
		ribbon.Font = Enum.Font.GothamBold
		ribbon.TextScaled = true
		ribbon.Text = "🍀 x2 Glück"
		ribbon.Visible = false -- shown together with its button once GetProductInfo confirms a real product
		ribbon.ZIndex = 12
		ribbon.Parent = wheelDialog
		Instance.new("UICorner", ribbon).CornerRadius = UDim.new(0, 8)
		return ribbon
	end
	local wheelBuyOneRibbon = makeLuckRibbon(WHEEL_BUY_ONE_X)
	local wheelBuyThreeRibbon = makeLuckRibbon(WHEEL_BUY_THREE_X)

	local wheelBuyOneButton = Instance.new("TextButton")
	wheelBuyOneButton.Name = "BuyOneButton"
	wheelBuyOneButton.Size = UDim2.new(0, WHEEL_BUTTON_WIDTH, 0, 56)
	wheelBuyOneButton.Position = UDim2.new(0, WHEEL_BUY_ONE_X, 0, WHEEL_BUTTON_Y)
	wheelBuyOneButton.BackgroundColor3 = Color3.fromRGB(255, 175, 60)
	wheelBuyOneButton.AutoButtonColor = false
	wheelBuyOneButton.TextColor3 = Color3.new(1, 1, 1)
	wheelBuyOneButton.TextStrokeTransparency = 0.3
	wheelBuyOneButton.TextWrapped = true
	wheelBuyOneButton.Font = Enum.Font.GothamBold
	wheelBuyOneButton.TextScaled = true
	wheelBuyOneButton.Text = "Kaufe 1"
	wheelBuyOneButton.Visible = false -- shown once GetProductInfo confirms a real product (see PopulateWheelState)
	wheelBuyOneButton.ZIndex = 12
	wheelBuyOneButton.Parent = wheelDialog
	Instance.new("UICorner", wheelBuyOneButton).CornerRadius = UDim.new(0, 14)
	local wheelBuyOneStroke = Instance.new("UIStroke")
	wheelBuyOneStroke.Color = Color3.fromRGB(140, 70, 10)
	wheelBuyOneStroke.Thickness = 3
	wheelBuyOneStroke.Parent = wheelBuyOneButton

	-- The middle button — STILL the free daily spin, mechanically
	-- unchanged, just restyled/relabeled ("🎁 Täglicher Spin" ->
	-- "🎁 Drehen (1)") and squeezed into the middle third of this new row
	-- instead of a standalone full-width button. Name kept as
	-- "FreeButton" (not renamed) since nothing about what it DOES changed,
	-- only where it sits and what it's called.
	local wheelFreeButton = Instance.new("TextButton")
	wheelFreeButton.Name = "FreeButton"
	wheelFreeButton.Size = UDim2.new(0, WHEEL_BUTTON_WIDTH, 0, 56)
	wheelFreeButton.Position = UDim2.new(0, WHEEL_FREE_X, 0, WHEEL_BUTTON_Y)
	wheelFreeButton.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
	wheelFreeButton.AutoButtonColor = false
	wheelFreeButton.TextColor3 = Color3.new(1, 1, 1)
	wheelFreeButton.TextStrokeTransparency = 0.3
	wheelFreeButton.TextWrapped = true
	wheelFreeButton.Font = Enum.Font.GothamBold
	wheelFreeButton.TextScaled = true
	wheelFreeButton.Text = "🎁 Drehen (1)"
	wheelFreeButton.ZIndex = 12
	wheelFreeButton.Parent = wheelDialog
	Instance.new("UICorner", wheelFreeButton).CornerRadius = UDim.new(0, 14)
	local wheelFreeStroke = Instance.new("UIStroke")
	wheelFreeStroke.Color = Color3.fromRGB(20, 100, 55)
	wheelFreeStroke.Thickness = 3
	wheelFreeStroke.Parent = wheelFreeButton

	local wheelBuyThreeButton = Instance.new("TextButton")
	wheelBuyThreeButton.Name = "BuyThreeButton"
	wheelBuyThreeButton.Size = UDim2.new(0, WHEEL_BUTTON_WIDTH, 0, 56)
	wheelBuyThreeButton.Position = UDim2.new(0, WHEEL_BUY_THREE_X, 0, WHEEL_BUTTON_Y)
	wheelBuyThreeButton.BackgroundColor3 = Color3.fromRGB(255, 175, 60)
	wheelBuyThreeButton.AutoButtonColor = false
	wheelBuyThreeButton.TextColor3 = Color3.new(1, 1, 1)
	wheelBuyThreeButton.TextStrokeTransparency = 0.3
	wheelBuyThreeButton.TextWrapped = true
	wheelBuyThreeButton.Font = Enum.Font.GothamBold
	wheelBuyThreeButton.TextScaled = true
	wheelBuyThreeButton.Text = "Kaufe 3"
	wheelBuyThreeButton.Visible = false -- shown once GetProductInfo confirms a real product (see PopulateWheelState)
	wheelBuyThreeButton.ZIndex = 12
	wheelBuyThreeButton.Parent = wheelDialog
	Instance.new("UICorner", wheelBuyThreeButton).CornerRadius = UDim.new(0, 14)
	local wheelBuyThreeStroke = Instance.new("UIStroke")
	wheelBuyThreeStroke.Color = Color3.fromRGB(140, 70, 10)
	wheelBuyThreeStroke.Thickness = 3
	wheelBuyThreeStroke.Parent = wheelBuyThreeButton

	-- Explanatory caption below the button row (on request, "eine kleine
	-- Info das das x2 Glück auf die Mystery-Brainrot Chance bezogen ist") —
	-- always present (not tied to whether a Robux product is configured)
	-- so the text stays informative even in Studio/testing before the
	-- products exist.
	local wheelLuckInfoLabel = Instance.new("TextLabel")
	wheelLuckInfoLabel.Name = "LuckInfoLabel"
	wheelLuckInfoLabel.Size = UDim2.new(1, -32, 0, 48)
	wheelLuckInfoLabel.Position = UDim2.new(0, 16, 0, WHEEL_BUTTON_Y + 56 + 8)
	wheelLuckInfoLabel.BackgroundTransparency = 1
	wheelLuckInfoLabel.TextColor3 = Color3.fromRGB(230, 210, 255)
	wheelLuckInfoLabel.TextStrokeTransparency = 0.5
	wheelLuckInfoLabel.TextWrapped = true
	wheelLuckInfoLabel.Font = Enum.Font.Gotham
	wheelLuckInfoLabel.TextScaled = true
	wheelLuckInfoLabel.Text = "🍀 x2 Glück gilt nur für die Mystery-Brainrot-Chance (0,5% → 1%) der gekauften Spins."
	wheelLuckInfoLabel.ZIndex = 12
	wheelLuckInfoLabel.Parent = wheelDialog

	-- Gamepad/keyboard: Up/Down through Close + Free (the two buy buttons
	-- only join once PopulateWheelState confirms they're actually visible —
	-- see that function's own rebuild of this same chain).
	wireVerticalChain({ wheelCloseButton, wheelFreeButton })

	-- === Fast-Travel panel (hidden full-screen overlay) ==========================
	-- Opened by walking up to the shared Fast-Travel kiosk (see BaseService.
	-- lua's buildFastTravelKiosk + the RequestFastTravelPanel remote, wired in
	-- init.client.lua). Lists every GameConfig.FastTravel.Checkpoints entry as
	-- its own row — same "built ONCE, only ever mutated afterward" convention
	-- as the Jump Upgrade panel's bulk-amount rows right above, since the
	-- checkpoint COUNT is small and fixed. Each row shows either a live-price
	-- Robux Buy button (once that floor has actually been reached — see
	-- PopulateFastTravel, driven by lastData.HighestFloor, already pushed on
	-- every DataUpdated so no extra remote fetch is needed here) or a locked
	-- label explaining why not yet.
	local fastTravelOverlay = Instance.new("Frame")
	fastTravelOverlay.Name = "FastTravelOverlay"
	fastTravelOverlay.Size = UDim2.new(1, 0, 1, 0)
	fastTravelOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	fastTravelOverlay.BackgroundTransparency = 0.5
	fastTravelOverlay.Visible = false
	fastTravelOverlay.ZIndex = 10
	fastTravelOverlay.Parent = screenGui

	local fastTravelCheckpointCount = #GameConfig.FastTravel.Checkpoints
	local fastTravelDialog = Instance.new("Frame")
	fastTravelDialog.Name = "FastTravelDialog"
	fastTravelDialog.AnchorPoint = Vector2.new(0.5, 0.5)
	fastTravelDialog.Position = UDim2.new(0.5, 0, 0.5, 0)
	fastTravelDialog.Size = UDim2.new(0, 380, 0, 132 + fastTravelCheckpointCount * 78)
	fastTravelDialog.BackgroundColor3 = Color3.fromRGB(60, 130, 220)
	fastTravelDialog.ZIndex = 11
	fastTravelDialog.Parent = fastTravelOverlay
	Instance.new("UICorner", fastTravelDialog).CornerRadius = UDim.new(0, 24)
	local fastTravelDialogStroke = Instance.new("UIStroke")
	fastTravelDialogStroke.Color = Color3.fromRGB(20, 60, 120)
	fastTravelDialogStroke.Thickness = 4
	fastTravelDialogStroke.Parent = fastTravelDialog

	local fastTravelTitle = Instance.new("TextLabel")
	fastTravelTitle.Name = "Title"
	fastTravelTitle.Size = UDim2.new(1, -70, 0, 40)
	fastTravelTitle.Position = UDim2.new(0, 16, 0, 16)
	fastTravelTitle.BackgroundTransparency = 1
	fastTravelTitle.Text = "🚀 Fast-Travel"
	fastTravelTitle.TextColor3 = Color3.new(1, 1, 1)
	fastTravelTitle.TextStrokeTransparency = 0.3
	fastTravelTitle.Font = Enum.Font.GothamBold
	fastTravelTitle.TextScaled = true
	fastTravelTitle.TextXAlignment = Enum.TextXAlignment.Left
	fastTravelTitle.ZIndex = 12
	fastTravelTitle.Parent = fastTravelDialog

	local fastTravelCloseButton = Instance.new("TextButton")
	fastTravelCloseButton.Name = "CloseButton"
	fastTravelCloseButton.Size = UDim2.new(0, 40, 0, 40)
	fastTravelCloseButton.Position = UDim2.new(1, -56, 0, 16)
	fastTravelCloseButton.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
	fastTravelCloseButton.TextColor3 = Color3.new(1, 1, 1)
	fastTravelCloseButton.Font = Enum.Font.GothamBold
	fastTravelCloseButton.TextScaled = true
	fastTravelCloseButton.Text = "X" -- "✕" doesn't render in Roblox's default UI fonts — see dexCloseButton's comment above
	fastTravelCloseButton.ZIndex = 12
	fastTravelCloseButton.Parent = fastTravelDialog
	Instance.new("UICorner", fastTravelCloseButton).CornerRadius = UDim.new(0, 10)

	local fastTravelStatusLabel = Instance.new("TextLabel")
	fastTravelStatusLabel.Name = "StatusLabel"
	fastTravelStatusLabel.Size = UDim2.new(1, -32, 0, 40)
	fastTravelStatusLabel.Position = UDim2.new(0, 16, 0, 64)
	fastTravelStatusLabel.BackgroundTransparency = 1
	fastTravelStatusLabel.TextColor3 = Color3.new(1, 1, 1)
	fastTravelStatusLabel.TextStrokeTransparency = 0.4
	fastTravelStatusLabel.TextWrapped = true
	fastTravelStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	fastTravelStatusLabel.Font = Enum.Font.Gotham
	fastTravelStatusLabel.TextScaled = true
	fastTravelStatusLabel.Text = "Teleportiere dich zu jedem Floor, den du schon erreicht hast."
	fastTravelStatusLabel.ZIndex = 12
	fastTravelStatusLabel.Parent = fastTravelDialog

	local fastTravelRowsList = Instance.new("Frame")
	fastTravelRowsList.Name = "RowsList"
	fastTravelRowsList.Size = UDim2.new(1, -32, 1, -108)
	fastTravelRowsList.Position = UDim2.new(0, 16, 0, 104)
	fastTravelRowsList.BackgroundTransparency = 1
	fastTravelRowsList.ZIndex = 12
	fastTravelRowsList.Parent = fastTravelDialog

	local fastTravelRowsListLayout = Instance.new("UIListLayout")
	fastTravelRowsListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	fastTravelRowsListLayout.Padding = UDim.new(0, 6)
	fastTravelRowsListLayout.Parent = fastTravelRowsList

	-- One row per GameConfig.FastTravel.Checkpoints entry, built ONCE here —
	-- same "built once, only ever mutated" reasoning as the Jump Upgrade
	-- panel's rows above. Each row keeps BOTH its Buy button and its locked
	-- label around permanently; PopulateFastTravel just toggles which one is
	-- Visible depending on lastData.HighestFloor.
	local fastTravelRows = {}
	for i, checkpoint in ipairs(GameConfig.FastTravel.Checkpoints) do
		local row = Instance.new("Frame")
		row.Name = "Row_Floor" .. checkpoint.Floor
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, 72)
		row.BackgroundTransparency = 1
		row.ZIndex = 12
		row.Parent = fastTravelRowsList

		local rowTitle = Instance.new("TextLabel")
		rowTitle.Name = "Title"
		rowTitle.Size = UDim2.new(1, 0, 0, 18)
		rowTitle.BackgroundTransparency = 1
		rowTitle.TextColor3 = Color3.new(1, 1, 1)
		rowTitle.TextStrokeTransparency = 0.3
		rowTitle.Font = Enum.Font.GothamBold
		rowTitle.TextScaled = true
		rowTitle.Text = "Floor " .. checkpoint.Floor
		rowTitle.TextXAlignment = Enum.TextXAlignment.Left
		rowTitle.ZIndex = 12
		rowTitle.Parent = row

		local buyButton = Instance.new("TextButton")
		buyButton.Name = "BuyButton"
		buyButton.Size = UDim2.new(1, 0, 0, 46)
		buyButton.Position = UDim2.new(0, 0, 0, 22)
		buyButton.BackgroundColor3 = Color3.fromRGB(40, 160, 90)
		buyButton.AutoButtonColor = false
		buyButton.TextColor3 = Color3.new(1, 1, 1)
		buyButton.TextStrokeTransparency = 0.3
		buyButton.TextWrapped = true
		buyButton.Font = Enum.Font.GothamBold
		buyButton.TextScaled = true
		buyButton.Text = "? Robux"
		buyButton.Visible = false -- shown once reached AND GetProductInfo confirms a real product (see PopulateFastTravel)
		buyButton.ZIndex = 12
		buyButton.Parent = row
		Instance.new("UICorner", buyButton).CornerRadius = UDim.new(0, 14)
		local buyStroke = Instance.new("UIStroke")
		buyStroke.Color = Color3.fromRGB(15, 90, 45)
		buyStroke.Thickness = 3
		buyStroke.Parent = buyButton

		local lockedLabel = Instance.new("TextLabel")
		lockedLabel.Name = "LockedLabel"
		lockedLabel.Size = UDim2.new(1, 0, 0, 46)
		lockedLabel.Position = UDim2.new(0, 0, 0, 22)
		lockedLabel.BackgroundColor3 = Color3.fromRGB(70, 70, 78)
		lockedLabel.TextColor3 = Color3.new(1, 1, 1)
		lockedLabel.TextStrokeTransparency = 0.3
		lockedLabel.TextWrapped = true
		lockedLabel.Font = Enum.Font.GothamBold
		lockedLabel.TextScaled = true
		lockedLabel.Text = "🔒 Noch nicht erreicht"
		lockedLabel.Visible = true
		lockedLabel.ZIndex = 12
		lockedLabel.Parent = row
		Instance.new("UICorner", lockedLabel).CornerRadius = UDim.new(0, 14)

		local productId = checkpoint.ProductId
		if productId and productId > 0 then
			buyButton:SetAttribute("ProductId", productId)
			buyButton:SetAttribute("Floor", checkpoint.Floor)
			-- Same "fetch once, off the main thread, stay hidden on failure"
			-- pattern as the Jump Upgrade panel's Robux buttons — the actual
			-- Visible toggle also needs lastData.HighestFloor though, so the
			-- real decision happens in PopulateFastTravel, not here; this
			-- just remembers the fetched price on the button itself.
			task.spawn(function()
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
				end)
				if ok and info and info.PriceInRobux then
					buyButton:SetAttribute("PriceInRobux", info.PriceInRobux)
					-- Spelled out ("59 Robux"), not the invisible "🔶" emoji + bare
					-- number — see the matching comment on the Jump Upgrade
					-- Robux button above.
					buyButton.Text = tostring(info.PriceInRobux) .. " Robux"
				end
			end)
		end

		table.insert(fastTravelRows, { Row = row, Floor = checkpoint.Floor, BuyButton = buyButton, LockedLabel = lockedLabel })
	end

	-- Gamepad/keyboard: just Close for now — every row starts locked (no
	-- BuyButton reachable yet), so PopulateFastTravel rebuilds this chain
	-- every time to include whichever rows are actually unlocked+priced.
	wireVerticalChain({ fastTravelCloseButton })

	local ui = {
		ScreenGui = screenGui,
		CashLabel = cashLabel,
		FriendBoostLabel = friendBoostLabel,
		FriendBoostRow = friendBoostRow,
		DoubleCashLabel = doubleCashLabel,
		DoubleCashRow = doubleCashRow,
		DoubleCashUntil = nil,
		FloorLabel = floorLabel,
		RebirthLabel = rebirthLabel,
		TierLabel = tierLabel,
		MessageLabel = messageLabel,
		ToastLabel = toastLabel,
		SellToastLabel = sellToastLabel,
		EventBanner = eventBanner,
		RebirthOverlay = rebirthOverlay,
		RebirthConfirmText = rebirthText,
		RebirthConfirmYes = yesButton,
		RebirthConfirmNo = noButton,
		SellOverlay = sellOverlay,
		SellConfirmText = sellText,
		SellConfirmYes = sellYesButton,
		SellConfirmNo = sellNoButton,
		-- Which pedestal the currently-shown sell dialog is actually about —
		-- stashed here by init.client.lua's RequestSellConfirm listener right
		-- before ShowSellConfirm, and read back by the Yes button's own
		-- handler. A fresh RequestSellConfirm always overwrites this before
		-- showing the dialog, so no stale slot index can ever leak into a
		-- later click.
		SellConfirmSlotIndex = nil,
		JumpUpgradeOverlay = jumpOverlay,
		JumpUpgradeCloseButton = jumpCloseButton,
		JumpUpgradeStatusLabel = jumpStatusLabel,
		JumpUpgradeMaxLabel = jumpMaxLabel,
		JumpUpgradeOptionsList = jumpOptionsList,
		JumpUpgradeBulkButtons = jumpBulkButtons,
		JumpUpgradeRobuxButtons = jumpRobuxButtons,
		WheelOverlay = wheelOverlay,
		WheelCloseButton = wheelCloseButton,
		WheelSpinner = wheelSpinner,
		WheelNeedle = wheelNeedle,
		WheelResultLabel = wheelResultLabel,
		WheelFreeButton = wheelFreeButton,
		WheelBuyOneButton = wheelBuyOneButton,
		WheelBuyThreeButton = wheelBuyThreeButton,
		WheelBuyOneRibbon = wheelBuyOneRibbon,
		WheelBuyThreeRibbon = wheelBuyThreeRibbon,
		WheelLuckInfoLabel = wheelLuckInfoLabel,
		WheelSpinning = false,
		TradeZonePanel = tradeZonePanel,
		TradeZoneList = tradeZoneList,
		TradeZoneRows = tradeZoneRows,
		TradeZoneEmptyLabel = tradeZoneEmptyLabel,
		TradeRequestOverlay = tradeRequestOverlay,
		TradeRequestText = tradeRequestText,
		TradeAcceptButton = tradeAcceptButton,
		TradeDeclineButton = tradeDeclineButton,
		TradeWindowOverlay = tradeWindowOverlay,
		TradeWindowDialog = tradeWindowDialog,
		TradeItemsContent = tradeItemsContent,
		TradeItemsPrevButton = tradeItemsPrevButton,
		TradeItemsNextButton = tradeItemsNextButton,
		TradeItemsPageLabel = tradeItemsPageLabel,
		TradeOpponentNameLabel = tradeOpponentNameLabel,
		TradeMyOfferLabel = tradeMyOfferLabel,
		TradeOpponentOfferLabel = tradeOpponentOfferLabel,
		TradeConfirmButton = tradeConfirmButton,
		TradeCancelButton = tradeCancelButton,
		DexButton = dexButton,
		JumpHeightValueLabel = jumpHeightValueLabel,
		JumpHeightDownButton = jumpHeightDownButton,
		JumpHeightMaxButton = jumpHeightMaxButton,
		JumpHeightUpButton = jumpHeightUpButton,
		-- Zuletzt vom Server bestätigte Werte — gecacht hier, damit die
		-- +/- Buttons (init.client.lua) den nächsten Schritt ausrechnen
		-- können, ohne jedes Mal extra beim Server nachfragen zu müssen.
		-- Defaults nur fürs allererste Rendern, bevor die erste DataUpdated
		-- ankommt; UpdateJumpHeightPanel unten überschreibt sie sofort mit
		-- echten Werten.
		JumpHeightFraction = 1,
		JumpHeightMax = 0,
		JumpHeightMin = 0,
		DexOverlay = dexOverlay,
		DexDialog = dexDialog,
		DexCloseButton = dexCloseButton,
		DexProgressLabel = dexProgressLabel,
		DexContent = dexContent,
		DexPrevButton = dexPrevButton,
		DexNextButton = dexNextButton,
		DexPageLabel = dexPageLabel,
		FastTravelOverlay = fastTravelOverlay,
		FastTravelCloseButton = fastTravelCloseButton,
		FastTravelStatusLabel = fastTravelStatusLabel,
		FastTravelRows = fastTravelRows,
		LeaderboardOverlay = leaderboardOverlay,
		LeaderboardDialog = leaderboardDialog,
		LeaderboardCloseButton = leaderboardCloseButton,
		LeaderboardTabButtons = {
			CashPerSecond = leaderboardTabCashPerSecond,
			Rebirths = leaderboardTabRebirths,
			Cash = leaderboardTabCash,
		},
		LeaderboardContent = leaderboardContent,
		LeaderboardPrevButton = leaderboardPrevButton,
		LeaderboardNextButton = leaderboardNextButton,
		LeaderboardPageLabel = leaderboardPageLabel,
		LeaderboardSelfRowInfo = { Avatar = leaderboardSelfAvatarImage, LoadedUserId = nil },
		LeaderboardSelfRankLabel = leaderboardSelfRankLabel,
		LeaderboardSelfValueLabel = leaderboardSelfValueLabel,
	}

	return ui
end

-- Shows/hides the weekly event banner based on the latest DataUpdated
-- payload's EventActive flag (see EconomyService.FireDataUpdated).
function UIBuilder.UpdateEventBanner(ui, data)
	ui.EventBanner.Visible = data.EventActive == true
end

-- "🤝 Freunde-Boost" badge, on request ("mache eine ui Anzeige oberhalb der
-- Konto Anzeige ... sie soll auch da sein wenn ein Freund da ist dann steht
-- aber kein Freund Online 0%") — ALWAYS visible, text switches based on
-- `data.FriendBoostPercent` (0 when no Roblox friend is present in this
-- server, otherwise the same additive fraction
-- EconomyService.getCashMultiplierFactor already applies to real Cash
-- income, see FireDataUpdated's own comment on that field). No separate
-- countdown loop needed like the DoubleCash badge — this only ever changes
-- on a player join/leave, and init.server.lua already pushes a fresh
-- DataUpdated to everyone right when that happens.
function UIBuilder.UpdateFriendBoostBadge(ui, data)
	local percent = data.FriendBoostPercent or 0
	if percent <= 0 then
		ui.FriendBoostLabel.Text = "Kein Freund online (+0%)"
	else
		ui.FriendBoostLabel.Text = "+" .. math.floor(percent * 100 + 0.5) .. "% Freunde-Boost"
	end
end

-- Red "2x Cash (Xs)" countdown badge, on request ("wenn beim Glücksrad 2x
-- Cash kommt sieht man nicht das man es hat und ein Countdown wäre toll").
-- `data.DoubleCashUntil` is an absolute os.time() timestamp from
-- EconomyService.FireDataUpdated's payload (nil once the buff has actually
-- expired) — stash it and let RefreshDoubleCashBadge do the actual
-- show/hide + text update, since it also needs to re-run every second on
-- its own between payload refreshes (see StartDoubleCashCountdownLoop).
function UIBuilder.UpdateDoubleCashBadge(ui, data)
	ui.DoubleCashUntil = data.DoubleCashUntil
	UIBuilder.RefreshDoubleCashBadge(ui)
end

function UIBuilder.RefreshDoubleCashBadge(ui)
	local until_ = ui.DoubleCashUntil
	if not until_ then
		ui.DoubleCashRow.Visible = false
		return
	end

	local remaining = until_ - os.time()
	if remaining <= 0 then
		ui.DoubleCashRow.Visible = false
		return
	end

	ui.DoubleCashRow.Visible = true
	ui.DoubleCashLabel.Text = "2x Cash (" .. remaining .. "s)"
end

-- Ticks the badge's text down every second even between DataUpdated
-- payloads (StartPassiveIncomeLoop doesn't fire DataUpdated every second,
-- so without this the countdown would only visibly change whenever some
-- other action happened to refresh the HUD). Call once, right after
-- UIBuilder.Build.
function UIBuilder.StartDoubleCashCountdownLoop(ui)
	task.spawn(function()
		while true do
			task.wait(1)
			UIBuilder.RefreshDoubleCashBadge(ui)
		end
	end)
end

-- === "Sprunghöhe"-Regler =========================================================

-- Caches the latest server-confirmed values (data.JumpHeightFraction, data.
-- MinJumpPower, and the EXISTING data.JumpPower — this player's own earned
-- ceiling) on `ui`, then repaints the panel's live label. init.client.lua
-- calls this from refreshStats, same as every other HUD piece.
function UIBuilder.UpdateJumpHeightPanel(ui, data)
	ui.JumpHeightFraction = data.JumpHeightFraction or 1
	ui.JumpHeightMin = data.MinJumpPower or 0
	ui.JumpHeightMax = data.JumpPower or 0
	UIBuilder.RefreshJumpHeightPanel(ui)
end

-- Repaints the value label from ui's cached numbers alone (no `data` needed)
-- — called both right after a fresh server value arrives (above) and
-- straight after the player clicks +/-/Max, so the label updates instantly
-- instead of waiting on a round-trip.
function UIBuilder.RefreshJumpHeightPanel(ui)
	local fraction = ui.JumpHeightFraction or 1
	local minPower = ui.JumpHeightMin or 0
	local maxPower = ui.JumpHeightMax or 0
	local currentPower = minPower + (maxPower - minPower) * fraction

	ui.JumpHeightValueLabel.Text = string.format(
		"🦘 %d%% (%d/%d)",
		math.floor(fraction * 100 + 0.5),
		math.floor(currentPower + 0.5),
		math.floor(maxPower + 0.5)
	)
end

-- Shows the Rebirth confirmation dialog with the given description text.
-- Wire ui.RebirthConfirmYes / ui.RebirthConfirmNo click events yourself
-- (see ClientMain/init.client.lua) — this just handles visibility/content.
function UIBuilder.ShowRebirthConfirm(ui, message)
	ui.RebirthConfirmText.Text = message
	ui.RebirthOverlay.Visible = true
	-- Gamepad/keyboard: default focus on Cancel, not Confirm — see the
	-- wireHorizontalChain call on these two buttons in Build for why.
	pushGamepadFocus(ui.RebirthConfirmNo)
end

function UIBuilder.HideRebirthConfirm(ui)
	ui.RebirthOverlay.Visible = false
	popGamepadFocus()
end

-- Shows the sell confirmation dialog with the given description text. Wire
-- ui.SellConfirmYes / ui.SellConfirmNo click events yourself (see
-- ClientMain/init.client.lua) — this just handles visibility/content, same
-- split as ShowRebirthConfirm/HideRebirthConfirm above.
function UIBuilder.ShowSellConfirm(ui, message)
	ui.SellConfirmText.Text = message
	ui.SellOverlay.Visible = true
	-- Gamepad/keyboard: default focus on Cancel — same reasoning as
	-- ShowRebirthConfirm above.
	pushGamepadFocus(ui.SellConfirmNo)
end

function UIBuilder.HideSellConfirm(ui)
	ui.SellOverlay.Visible = false
	popGamepadFocus()
end

-- === Jump Upgrade panel =========================================================

-- `data` is the latest DataUpdated payload (see EconomyService.
-- GetJumpUpgradeState) — JumpPoints, MaxJumpPoints, JumpPower, JumpTierName,
-- JumpBulkOptions (array of {Amount, Cost, PointsBought, Affordable}, one
-- per GameConfig.JumpUpgrade.BulkAmounts entry). The Cash/Robux buttons
-- already exist (built once in UIBuilder.Build, see the long comment
-- there) — this only ever updates an EXISTING button's Text/Color/
-- Attribute/Visible, never creates or destroys one. The Robux button's
-- price text is set once, from a live GetProductInfo call, right where
-- it's built in UIBuilder.Build — it never depends on `data`, so it's
-- left alone here.
function UIBuilder.PopulateJumpUpgrade(ui, data)
	local points = data.JumpPoints or 0
	local maxPoints = data.MaxJumpPoints or 0
	local atMax = points >= maxPoints

	-- Nur noch die Sprung-Punkte anzeigen (auf Wunsch) — die Sprungkraft-Zahl
	-- und der Tier-Name ("99 (Bouncy Boots)") sind rein kosmetisch entfernt;
	-- JumpPower/JumpTierName kommen aus `data` weiterhin unverändert (siehe
	-- EconomyService.GetJumpUpgradeState), werden hier nur nicht mehr
	-- angezeigt. Die Physik (tatsächliche Sprunghöhe im Spiel) und die
	-- Kosten-Stufen sind davon NICHT betroffen, siehe Chat.
	ui.JumpUpgradeStatusLabel.Text = points .. " / " .. maxPoints .. " Sprung-Punkte"

	ui.JumpUpgradeMaxLabel.Visible = atMax
	ui.JumpUpgradeOptionsList.Visible = not atMax

	local options = data.JumpBulkOptions or {}
	for i, button in ipairs(ui.JumpUpgradeBulkButtons) do
		local option = options[i]
		local robuxButton = ui.JumpUpgradeRobuxButtons[i]
		if option then
			-- The row's title label ("+N Sprung") already shows the amount,
			-- so the Cash button itself only needs to show the price.
			button.Text = "$" .. UIBuilder.FormatNumber(option.Cost)
			button.BackgroundColor3 = option.Affordable and Color3.fromRGB(255, 175, 60) or Color3.fromRGB(130, 95, 60)
			button:SetAttribute("BulkAmount", option.Amount)
			button.Visible = true
		else
			button.Visible = false
			if robuxButton then
				robuxButton.Visible = false
			end
		end
	end

	-- Gamepad/keyboard: rebuild the Up/Down spine over Close + whichever
	-- Cash buttons ended up Visible above (normally all of them). Guarded
	-- on `not atMax` too, not just each button's own Visible — at the
	-- "Maximaler Sprung erreicht" state, JumpUpgradeOptionsList (their
	-- shared PARENT frame) is hidden instead, which a button's own Visible
	-- flag doesn't reflect; without this check the chain could still link
	-- to buttons sitting inside that hidden frame, stranding navigation on
	-- something nobody can see. Each row's own Robux button stays linked
	-- Left/Right off its Cash button — that link was made once, when the
	-- Robux button first became visible (see Build), and doesn't need
	-- redoing here.
	local jumpChain = { ui.JumpUpgradeCloseButton }
	if not atMax then
		for _, button in ipairs(ui.JumpUpgradeBulkButtons) do
			if button.Visible then
				table.insert(jumpChain, button)
			end
		end
	end
	wireVerticalChain(jumpChain)
end

function UIBuilder.ShowJumpUpgrade(ui, data)
	ui.JumpUpgradeOverlay.Visible = true
	UIBuilder.PopulateJumpUpgrade(ui, data)
	pushGamepadFocus(ui.JumpUpgradeCloseButton)
end

function UIBuilder.HideJumpUpgrade(ui)
	ui.JumpUpgradeOverlay.Visible = false
	popGamepadFocus()
end

-- Formats a cooldown remaining-seconds count as a short German string for
-- the wheel panel's free-spin button ("2h 05m" / "3m 07s" / "42s") — mirrors
-- how other cooldown displays in this file are formatted, kept local to
-- this function since nothing else needs an hours-aware countdown string.
local function formatWheelRemaining(seconds)
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

-- Refreshes the wheel panel's three buttons from a WheelService.GetState
-- snapshot (see init.client.lua's RequestWheelPanel listener). The middle
-- free button shows either "spin now" or a live countdown, unchanged. The
-- two Robux buy buttons (Kaufe 1 / Kaufe 3) are matched to their own
-- state.RobuxProducts entry by SpinCount (not array order — a bundle
-- whose ProductId is still 0, "not yet created in Studio", is simply left
-- hidden), each fetches its own live price via
-- MarketplaceService:GetProductInfo (same pattern as every other Robux
-- button in this file) and only shows itself — button + its own
-- "🍀 x2 Glück" ribbon together — once that price is known, so nothing
-- ever flashes an empty/wrong price.
function UIBuilder.PopulateWheelState(ui, state)
	if state.Ready then
		ui.WheelFreeButton.Text = "🎁 Drehen (1)"
		ui.WheelFreeButton.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
		ui.WheelFreeButton.Active = true
	else
		ui.WheelFreeButton.Text = "🎁 " .. formatWheelRemaining(state.RemainingSeconds)
		ui.WheelFreeButton.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
		ui.WheelFreeButton.Active = false
	end

	-- Gamepad/keyboard: rebuilds the Up/Down chain from whichever of the
	-- two buy buttons are actually visible right now — called again from
	-- each buy button's own price-fetch callback below, since the two
	-- fetches resolve independently and either, both, or neither may end
	-- up visible (mirrors the static Close/Free baseline chain set once at
	-- build time, right after these buttons are created).
	local function refreshWheelChain()
		local chain = { ui.WheelCloseButton }
		if ui.WheelBuyOneButton.Visible then
			table.insert(chain, ui.WheelBuyOneButton)
		end
		table.insert(chain, ui.WheelFreeButton)
		if ui.WheelBuyThreeButton.Visible then
			table.insert(chain, ui.WheelBuyThreeButton)
		end
		wireVerticalChain(chain)
	end

	local function populateBuyButton(button, ribbon, label, spinCount)
		button.Visible = false
		ribbon.Visible = false
		local product
		for _, entry in ipairs(state.RobuxProducts or {}) do
			if entry.SpinCount == spinCount then
				product = entry
				break
			end
		end
		local productId = product and product.ProductId
		if not (productId and productId > 0) then
			return
		end
		button:SetAttribute("ProductId", productId)
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
			end)
			if ok and info and info.PriceInRobux then
				button.Text = label .. "\n" .. tostring(info.PriceInRobux) .. " Robux"
				button.Visible = true
				ribbon.Visible = true
				refreshWheelChain()
			end
		end)
	end

	populateBuyButton(ui.WheelBuyOneButton, ui.WheelBuyOneRibbon, "Kaufe 1", 1)
	populateBuyButton(ui.WheelBuyThreeButton, ui.WheelBuyThreeRibbon, "Kaufe 3", 3)
end

-- Opens the Glücksrad panel (see init.client.lua's RequestWheelPanel
-- listener, fired when a player interacts with the shared kiosk) and
-- populates its three buttons from a freshly-fetched WheelService.GetState
-- snapshot, so the cooldown/price shown is never stale from a previous
-- panel open.
function UIBuilder.ShowWheelPanel(ui, state)
	ui.WheelResultLabel.Text = "Einmal am Tag gratis, oder jederzeit für Robux!"
	ui.WheelOverlay.Visible = true
	UIBuilder.PopulateWheelState(ui, state)
	pushGamepadFocus(ui.WheelCloseButton)
end

function UIBuilder.HideWheelPanel(ui)
	ui.WheelOverlay.Visible = false
	popGamepadFocus()
end

local WHEEL_SPIN_SECONDS = 10
local WHEEL_SPIN_EXTRA_TURNS = 5

-- Plays the wheel-spin animation and lands it on the segment that matches
-- what was actually won (segmentIndex, 1-based into GameConfig.WheelOfFortune
-- .Segments — computed server-side by WheelService.segmentIndexForPrize, so
-- the client never has to re-derive which segment a prize maps to). Called
-- from BOTH the free-spin RemoteFunction's return value and the paid-spin
-- WheelSpinResult event, so it's the single place the actual spin visual
-- happens regardless of which button started it.
--
-- Rotates ui.WheelNeedle — NOT the wheel's face (wheelSpinner never moves
-- any more, see this panel's top comment for why this switched back to a
-- "static wheel + rotating needle" design). segmentAngle below is each
-- segment's own FIXED position on the never-moving wheel (index 1 = 0°/top,
-- clockwise, exactly the layout angle used when placing the fallback tiles
-- / matching the artwork). Because the wheel face itself never rotates,
-- the needle simply has to turn TO that same angle — no "360 minus" inverse
-- needed here (that inversion was only ever needed for the old "wheel
-- spins, pointer fixed" design, where the WHEEL had to travel the opposite
-- distance to bring a segment up to a fixed pointer; a needle pointing AT
-- a fixed segment has no such inversion). Getting this backwards (turning
-- by the "360 minus" amount instead of straight to segmentAngle) would
-- silently point at the segment's mirror image across the 12-o'clock/
-- 6-o'clock axis instead — the needle LOOKS like it's spinning correctly
-- every time, so this is easy to ship wrong and only notice when someone
-- compares the announced prize text against which segment the needle
-- actually ends up pointing at.
--
-- The needle's current .Rotation may already be hundreds of degrees from
-- earlier spins (intentionally never reset, so each spin keeps turning
-- further rather than snapping back) — delta is the shortest turn from the
-- needle's current facing to the required angle, then
-- WHEEL_SPIN_EXTRA_TURNS full extra rotations are added on top purely for
-- visual flourish before the tween settles on the true target.
-- How far off-center (as a fraction of each segment's own HALF-width) the
-- needle is allowed to land — purely cosmetic, decided AFTER
-- WheelService.segmentIndexForPrize has already picked which segment,
-- so it never changes the actual odds/result, only where inside that
-- segment the needle visually stops. On request ("die Nadel ... nicht
-- immer genau in der Mitte landen ... öfters am Rand vom Feld, spannender")
-- — previously always landed exactly dead-center. 0.55 leaves a solid ~45%
-- safety margin from each segment's own boundary line, so the needle
-- always stays clearly, unambiguously inside the segment it actually won
-- (chose the "dezent" of 3 offered spread options — 1.0 would let it touch
-- the boundary line exactly, which was explicitly NOT wanted).
local WHEEL_NEEDLE_LANDING_SPREAD = 0.55

-- Picks a random offset (degrees) from a segment's exact center, biased
-- toward small offsets rather than spread flat across the whole allowed
-- range — the DIFFERENCE of two uniform draws forms a triangular
-- distribution peaking at 0, so the needle lands near-center most spins
-- and only occasionally swings out toward the max allowed offset ("meist
-- mittig, gelegentlich Richtung Rand", not "irgendwo völlig zufällig").
local function randomNeedleOffsetDeg(segmentCount)
	local halfWidth = 180 / segmentCount
	local maxOffset = halfWidth * WHEEL_NEEDLE_LANDING_SPREAD
	return (math.random() - math.random()) * maxOffset
end

-- Core needle tween for a SINGLE result — shared by the free-spin path
-- (PlayWheelSpin, right below) and the multi-spin Robux-bundle path
-- (PlayWheelSpinSequence, further below). Deliberately does NOT touch
-- ui.WheelSpinning or any button's Active state itself — the caller owns
-- that for the whole run (one spin for PlayWheelSpin, the entire bundle
-- for PlayWheelSpinSequence), so a 3-spin bundle doesn't re-enable the
-- buttons in between its own spins.
local function tweenWheelNeedleTo(ui, segmentIndex, onComplete)
	local segmentCount = #GameConfig.WheelOfFortune.Segments
	local segmentAngle = ((segmentIndex - 1) * (360 / segmentCount)) % 360
	local requiredMod = (segmentAngle + randomNeedleOffsetDeg(segmentCount)) % 360

	local currentRotation = ui.WheelNeedle.Rotation
	local currentMod = currentRotation % 360
	local delta = (requiredMod - currentMod) % 360
	local finalRotation = currentRotation + delta + 360 * WHEEL_SPIN_EXTRA_TURNS

	local tween = TweenService:Create(
		ui.WheelNeedle,
		TweenInfo.new(WHEEL_SPIN_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Rotation = finalRotation }
	)
	tween.Completed:Connect(onComplete)
	tween:Play()
end

-- onFreeButtonRefresh (optional): called once the animation finishes,
-- INSTEAD of blindly re-enabling WheelFreeButton — on request ("nach dem
-- gratis Glücksrad dreh ist der dreh Button immer noch aktiv, erst nach
-- nochmaligen drücken kommt der Timer"): a successful free spin just used
-- up today's cooldown server-side, so unconditionally setting
-- `.Active = true` here made the button clickable again immediately,
-- showing the real cooldown/timer only after a SECOND press (whose
-- failure reply happens to re-fetch GetWheelState, see init.client.lua).
-- The caller now passes a callback that re-fetches GetWheelState and
-- calls PopulateWheelState right away instead, so the button's
-- text/color/Active state reflect the real cooldown immediately, without
-- needing that extra click. The two buy buttons don't depend on the
-- cooldown at all, so they're still just re-enabled directly here.
function UIBuilder.PlayWheelSpin(ui, segmentIndex, message, onFreeButtonRefresh)
	if ui.WheelSpinning then
		return
	end
	ui.WheelSpinning = true
	ui.WheelFreeButton.Active = false
	ui.WheelBuyOneButton.Active = false
	ui.WheelBuyThreeButton.Active = false
	ui.WheelResultLabel.Text = "..."

	tweenWheelNeedleTo(ui, segmentIndex, function()
		ui.WheelResultLabel.Text = message or "Kein Bonus diesmal — Base voll?"
		ui.WheelSpinning = false
		ui.WheelBuyOneButton.Active = true
		ui.WheelBuyThreeButton.Active = true
		if onFreeButtonRefresh then
			onFreeButtonRefresh()
		else
			ui.WheelFreeButton.Active = true
		end
	end)
end

local WHEEL_SPIN_SEQUENCE_PAUSE_SECONDS = 0.6

-- Plays a Robux-bundle purchase's results (results = an ARRAY of
-- {SegmentIndex, Message}, one entry per spin bought — see
-- WheelService.SpinWheelPaid and init.client.lua's WheelSpinResult
-- listener, which now carries this array instead of a single result) as
-- that many needle spins IN SEQUENCE, each followed by a short pause
-- before the next one starts — on request: "die Nadel dafür 3x
-- hintereinander animiert drehen (mit kurzer Pause dazwischen)". Used for
-- EVERY Robux purchase, including a single "Kaufe 1" (a 1-entry array —
-- one spin, no pause, functionally identical to PlayWheelSpin for that
-- case).
--
-- Buttons stay disabled for the WHOLE sequence, not just each individual
-- spin, so a player can't queue a second purchase mid-animation. Also
-- briefly recolors the existing x2-Glück caption (see UIBuilder.Build —
-- always visible once either buy button is configured, explaining what
-- the buff applies to) purely to draw a little extra attention to it
-- during a purchased sequence, per the user's own request for "eine
-- kleine Info das das 2x Glück auf die Mystery-Brainrot Chance bezogen
-- ist" alongside the animation.
-- onFreeButtonRefresh (optional): same fix/reasoning as PlayWheelSpin's own
-- parameter above — a Robux purchase never touches the free spin's
-- cooldown (see WheelService.SpinWheelPaid's own comment), so blindly
-- re-enabling WheelFreeButton here could make an ALREADY on-cooldown free
-- button clickable again right after a purchased sequence finishes, even
-- though its text still shows the countdown. Lets the caller re-fetch the
-- real state instead, same as the free path.
function UIBuilder.PlayWheelSpinSequence(ui, results, onFreeButtonRefresh)
	if ui.WheelSpinning or not results or #results == 0 then
		return
	end
	ui.WheelSpinning = true
	ui.WheelFreeButton.Active = false
	ui.WheelBuyOneButton.Active = false
	ui.WheelBuyThreeButton.Active = false

	local originalInfoColor = ui.WheelLuckInfoLabel.TextColor3
	ui.WheelLuckInfoLabel.TextColor3 = Color3.fromRGB(255, 225, 90)

	task.spawn(function()
		for i, result in ipairs(results) do
			ui.WheelResultLabel.Text = string.format("Spin %d/%d ...", i, #results)

			local spinDone = false
			tweenWheelNeedleTo(ui, result.SegmentIndex, function()
				spinDone = true
			end)
			while not spinDone do
				task.wait()
			end

			ui.WheelResultLabel.Text = result.Message or "Kein Bonus diesmal — Base voll?"
			if i < #results then
				task.wait(WHEEL_SPIN_SEQUENCE_PAUSE_SECONDS)
			end
		end

		ui.WheelLuckInfoLabel.TextColor3 = originalInfoColor
		ui.WheelSpinning = false
		ui.WheelBuyOneButton.Active = true
		ui.WheelBuyThreeButton.Active = true
		if onFreeButtonRefresh then
			onFreeButtonRefresh()
		else
			ui.WheelFreeButton.Active = true
		end
	end)
end

-- === Fast-Travel panel ==========================================================

-- Refreshes every pre-built Fast-Travel row (see UIBuilder.Build's
-- `fastTravelRows` loop) from the latest DataUpdated payload's HighestFloor —
-- same "toggle Visible on existing buttons, never rebuild" pattern as
-- PopulateJumpUpgrade above. A row's Buy button only ever shows once BOTH
-- conditions hold: the player has already reached that checkpoint's Floor,
-- AND a real price came back from GetProductInfo (button.Text still says
-- "? Robux" — i.e. no PriceInRobux Attribute yet — until that happens); a
-- checkpoint whose ProductId is still the GameConfig placeholder 0 never
-- gets the Attribute at all (see UIBuilder.Build), so it can never show a
-- Buy button here, and simply stays a permanent "🔒 Noch nicht erreicht"
-- label instead — matching the wheel/jump-upgrade Robux buttons' "hide,
-- don't reject" convention for anything not configured yet.
function UIBuilder.PopulateFastTravel(ui, data)
	local highestFloor = (data and data.HighestFloor) or 0
	for _, row in ipairs(ui.FastTravelRows) do
		local reached = highestFloor >= row.Floor
		local hasPrice = row.BuyButton:GetAttribute("PriceInRobux") ~= nil
		row.BuyButton.Visible = reached and hasPrice
		row.LockedLabel.Visible = not (reached and hasPrice)
	end

	-- Gamepad/keyboard: rebuild the Up/Down chain over Close + whichever
	-- checkpoint rows actually have a reachable Buy button right now — a
	-- locked row's non-interactive "🔒 Noch nicht erreicht" label is never
	-- included.
	local fastTravelChain = { ui.FastTravelCloseButton }
	for _, row in ipairs(ui.FastTravelRows) do
		if row.BuyButton.Visible then
			table.insert(fastTravelChain, row.BuyButton)
		end
	end
	wireVerticalChain(fastTravelChain)
end

-- Opens the Fast-Travel panel (see init.client.lua's RequestFastTravelPanel
-- listener, fired when a player interacts with BaseService.buildFastTravel
-- Kiosk's shared kiosk) — no server round-trip needed, the panel is built
-- straight from the same lastData the HUD already keeps up to date, exactly
-- like the Jump Upgrade panel above.
function UIBuilder.ShowFastTravelPanel(ui, data)
	ui.FastTravelOverlay.Visible = true
	UIBuilder.PopulateFastTravel(ui, data)
	pushGamepadFocus(ui.FastTravelCloseButton)
end

function UIBuilder.HideFastTravelPanel(ui)
	ui.FastTravelOverlay.Visible = false
	popGamepadFocus()
end

local function fadeMessage(label, text, bgColor)
	label.Text = text
	label.BackgroundColor3 = bgColor
	label.BackgroundTransparency = 0.1
	label.TextTransparency = 0
	task.delay(2.5, function()
		TweenService:Create(label, TweenInfo.new(0.6), {
			BackgroundTransparency = 1,
			TextTransparency = 1,
		}):Play()
	end)
end

function UIBuilder.ShowMessage(ui, text)
	fadeMessage(ui.MessageLabel, text, Color3.fromRGB(180, 40, 40))
end

function UIBuilder.ShowCreatureToast(ui, info)
	fadeMessage(ui.ToastLabel, "Got " .. info.Name .. " (" .. info.Rarity .. ")!", info.Color)
end

-- info = { Name = creatureName, Value = sellValue } from CreatureService.
-- SellCreature via the CreatureSold RemoteEvent.
function UIBuilder.ShowSellToast(ui, info)
	fadeMessage(ui.SellToastLabel, "Verkauft: " .. info.Name .. " für " .. UIBuilder.FormatNumber(info.Value) .. " Cash", Color3.fromRGB(40, 150, 80))
end

-- info = { Rarity = rarityName, BonusPercent = 10 } from CreatureService's
-- "DexRarityCompleted" RemoteEvent (init.client.lua) — on request ("eine
-- Information das man das bekommt wäre toll"), fired the exact moment a
-- rarity's Brainrot-Dex completion bonus first turns on. Reuses the same
-- green success banner as ShowSellToast above rather than a new UI element,
-- same "no new GUI needed" reasoning as the red ShowMessage banner.
function UIBuilder.ShowDexCompletionToast(ui, info)
	fadeMessage(
		ui.SellToastLabel,
		"🎉 " .. info.Rarity .. "-Dex komplett! +" .. info.BonusPercent .. "% Cash für immer",
		Color3.fromRGB(40, 150, 80)
	)
end

-- === Trade Zone / Trade window =================================================

-- `players` is nil (we just left the zone — hide the whole panel) or an
-- array of {UserId, Name} for everyone ELSE currently in the zone (see
-- TradeService's "TradeZoneRoster" event). ui.TradeZoneRows is a FIXED pool
-- of GameConfig.Base.MaxPlayers - 1 buttons, built once in UIBuilder.Build
-- (see the comment there) — this only ever mutates an existing row's Text/
-- Attribute/Visible now, never creates or destroys one. Each row carries its
-- target's UserId as an Attribute for ClientMain/init.client.lua's click
-- handler to read — see the comment on tradeZonePanel in Build for why.
function UIBuilder.UpdateTradeZoneRoster(ui, players)
	if not players then
		ui.TradeZonePanel.Visible = false
		if ui.TradeZoneFocusPushed then
			ui.TradeZoneFocusPushed = false
			popGamepadFocus()
		end
		return
	end
	ui.TradeZonePanel.Visible = true

	ui.TradeZoneEmptyLabel.Visible = #players == 0

	local visibleRows = {}
	for i, row in ipairs(ui.TradeZoneRows) do
		local entry = players[i]
		if entry then
			row.Text = entry.Name .. " – Anfragen"
			row:SetAttribute("TargetUserId", entry.UserId)
			row.Visible = true
			table.insert(visibleRows, row)
		else
			row.Visible = false
		end
	end

	-- Gamepad/keyboard: rebuild the chain over whichever rows are actually
	-- in the zone right now — the roster (and so this whole chain) can
	-- change every few seconds as players walk in/out. Focus is only ever
	-- PUSHED the first time someone else is in the zone with you
	-- (ui.TradeZoneFocusPushed tracks that, since — unlike every other
	-- popup — this function has no separate Show/Hide pair to hook a
	-- push/pop into); later roster updates just repoint SelectedObject at
	-- whatever's now first, without stacking a second push.
	if #visibleRows > 0 then
		wireVerticalChain(visibleRows)
		if ui.TradeZoneFocusPushed then
			if UserInputService.GamepadEnabled then
				GuiService.SelectedObject = visibleRows[1]
			end
		else
			ui.TradeZoneFocusPushed = true
			pushGamepadFocus(visibleRows[1])
		end
	elseif ui.TradeZoneFocusPushed then
		-- Panel's still open (someone WAS here) but the zone is empty again
		-- now — nothing left to select.
		ui.TradeZoneFocusPushed = false
		popGamepadFocus()
	end
end

-- Shows the "X möchte mit dir tauschen" popup. Accept/Decline are static
-- buttons wired once in ClientMain/init.client.lua (see the comment on
-- tradeRequestOverlay above) — this just sets the text and shows it.
function UIBuilder.ShowTradeRequest(ui, fromName)
	ui.TradeRequestText.Text = fromName .. " möchte mit dir tauschen!"
	ui.TradeRequestOverlay.Visible = true
	-- Gamepad/keyboard: default focus on Decline — same "don't let one
	-- accidental A-press commit you to something" reasoning as the Rebirth/
	-- Sell confirm dialogs above. This can push on TOP of the Trade Zone
	-- panel's own focus (a request can arrive while you're standing in the
	-- zone) — popped back to whatever was open underneath by HideTradeRequest.
	pushGamepadFocus(ui.TradeDeclineButton)
end

function UIBuilder.HideTradeRequest(ui)
	ui.TradeRequestOverlay.Visible = false
	popGamepadFocus()
end

local TRADE_ITEM_ROW_HEIGHT = 34
local TRADE_ITEM_LIST_PADDING = 4

-- How many pixels of content each page of the item picker may hold before
-- starting a new page — same reasoning as DEX_PAGE_HEIGHT_BUDGET (see the
-- long "black panel" comment above dexContent in UIBuilder.Build).
-- ui.TradeItemsContent is 260px tall; 240 leaves a small margin so the last
-- row on a page never sits flush against its bottom edge.
local TRADE_ITEMS_PAGE_HEIGHT_BUDGET = 240

-- Forward-declared (assigned below, after packTradeItemsPages) so
-- ensureTradeItemRowsBuilt's Prev/Next wiring — which only ever fires later,
-- long after this whole file has finished loading — can already close over
-- it here.
local showTradeItemsPage

-- Builds the ~91 item-picker rows (one per GameConfig.Creatures entry) plus
-- the "you own nothing" empty-state label, ONCE — the first time
-- ShowTradeWindow below actually runs, never again after. This is the same
-- pre-build/mutate-after idea as the Jump Upgrade/Dex panels, but
-- deliberately NOT done inside UIBuilder.Build (see the long "black panel"
-- comment above dexContent for the full story): building it there would
-- create these rows while TradeWindowOverlay is still hidden, which is
-- exactly what caused the original black-panel bug. Calling this from
-- ShowTradeWindow instead guarantees it only ever runs AFTER
-- TradeWindowOverlay.Visible has already been set true. A creature you don't
-- currently own simply isn't in `myItems` (see CreatureService.
-- GetOwnedSummary) — every row that COULD ever be needed already exists
-- after this, so every later open just toggles Visible/Text/Position on
-- existing rows instead of destroying/rebuilding anything. Rows are NOT
-- paged/positioned here — unlike the Dex's fixed ~91-row set (packed into
-- pages once and never repacked), which creatures are actually OWNED
-- changes every time the trade window opens, so packTradeItemsPages below
-- repacks pages fresh on every single ShowTradeWindow call instead.
local function ensureTradeItemRowsBuilt(ui)
	if ui.TradeItemRowsBuilt then
		return
	end
	ui.TradeItemRowsBuilt = true

	local rows = {} -- [creatureName] = row
	local rowList = {} -- ordered, same order as GameConfig.Creatures
	for i, def in ipairs(GameConfig.Creatures) do
		local rarityDef = GameConfig.CreatureRarities[def.Rarity]
		local row = Instance.new("TextButton")
		row.Name = "Item_" .. def.Name
		row.LayoutOrder = i
		row.Size = UDim2.new(1, -8, 0, TRADE_ITEM_ROW_HEIGHT)
		-- A FIXED dark background + fixed white text, same as every other
		-- panel in this UI, instead of using the rarity color as the fill —
		-- some rarities (Normal's light gray, Singularity's near-black) are
		-- too close to white to give readable contrast against fixed white
		-- text. The rarity color still shows, just as a colored border
		-- (UIStroke below) instead of the fill.
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
		row.BackgroundTransparency = 0
		row.AutoButtonColor = false
		row.TextColor3 = Color3.new(1, 1, 1)
		row.TextStrokeTransparency = 0.4
		row.Font = Enum.Font.GothamBold
		row.TextScaled = true
		row.Text = def.Name
		row:SetAttribute("CreatureName", def.Name)
		-- Every other themed element in this whole file explicitly sets
		-- ZIndex = 12 to match its ancestor chain (tradeItemsContent itself
		-- included) — these rows were the one thing that didn't, left at
		-- Roblox's own default of 1. Matching Dex's own rows (which do set
		-- this) here too, defensively, in case that mismatch was ever part
		-- of why this picker rendered solid black.
		row.ZIndex = 12
		row.Visible = false
		row.Parent = ui.TradeItemsContent
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

		local stroke = Instance.new("UIStroke")
		stroke.Color = (rarityDef and rarityDef.Color) or Color3.new(1, 1, 1)
		stroke.Thickness = 2
		stroke.Parent = row

		rows[def.Name] = row
		table.insert(rowList, row)
	end

	local emptyLabel = Instance.new("TextLabel")
	emptyLabel.Name = "EmptyLabel"
	emptyLabel.Size = UDim2.new(1, -8, 0, 32)
	emptyLabel.Position = UDim2.new(0, 4, 0, 4)
	emptyLabel.BackgroundTransparency = 1
	emptyLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	emptyLabel.TextWrapped = true
	emptyLabel.Font = Enum.Font.Gotham
	emptyLabel.TextScaled = true
	emptyLabel.Text = "Du besitzt noch keine Brainrots zum Tauschen."
	emptyLabel.ZIndex = 12
	emptyLabel.Visible = false
	emptyLabel.Parent = ui.TradeItemsContent

	ui.TradeItemRows = rows
	ui.TradeItemRowList = rowList
	ui.TradeItemsEmptyLabel = emptyLabel

	-- Wired here, once, right after the rows exist — Prev/Next only ever
	-- flip .Visible on whichever page packTradeItemsPages/showTradeItemsPage
	-- below most recently packed, same "pre-build once, mutate forever" idea
	-- as the Dex's Prev/Next (ensureDexRowsBuilt), just repacked fresh every
	-- trade-window open instead of packed once ever.
	ui.TradeItemsPrevButton.Activated:Connect(function()
		showTradeItemsPage(ui, (ui.TradeItemsCurrentPage or 1) - 1)
	end)
	ui.TradeItemsNextButton.Activated:Connect(function()
		showTradeItemsPage(ui, (ui.TradeItemsCurrentPage or 1) + 1)
	end)
end

-- Rebuilds the gamepad/keyboard Up/Down chain over only THIS page's rows
-- (a link into a hidden other-page row would strand navigation there) plus
-- Prev/Next (only when there's more than one page) and the always-present
-- Confirm/Cancel pair at the end. Returns the chain so callers can grab
-- chain[1] as the thing to focus.
local function buildTradeItemsChain(ui, pageNumber)
	local chain = {}
	for _, row in ipairs(ui.TradeItemsPages[pageNumber] or {}) do
		table.insert(chain, row)
	end
	if (ui.TradeItemsPageCount or 1) > 1 then
		table.insert(chain, ui.TradeItemsPrevButton)
		table.insert(chain, ui.TradeItemsNextButton)
	end
	table.insert(chain, ui.TradeConfirmButton)
	table.insert(chain, ui.TradeCancelButton)
	wireVerticalChain(chain)
	return chain
end

-- Shows page `newPage` of the item picker and hides whichever page was
-- showing before — the only thing that ever changes an already-built row's
-- Visible property after ensureTradeItemRowsBuilt runs, same "pre-build
-- once, mutate forever" pattern as showDexPage. Every row starts each
-- ShowTradeWindow call already forced back to Visible = false (see below),
-- so hiding the old page here is just a normal same-session page turn, never
-- a leftover from a differently-packed previous trade.
showTradeItemsPage = function(ui, newPage)
	local pageCount = ui.TradeItemsPageCount or 1
	newPage = math.clamp(newPage, 1, pageCount)

	local oldPage = ui.TradeItemsCurrentPage
	if oldPage and ui.TradeItemsPages[oldPage] then
		for _, row in ipairs(ui.TradeItemsPages[oldPage]) do
			row.Visible = false
		end
	end

	ui.TradeItemsCurrentPage = newPage
	for _, row in ipairs(ui.TradeItemsPages[newPage] or {}) do
		row.Visible = true
	end

	ui.TradeItemsPageLabel.Text = pageCount > 1 and ("Seite " .. newPage .. " / " .. pageCount) or ""
	ui.TradeItemsPrevButton.Visible = pageCount > 1
	ui.TradeItemsNextButton.Visible = pageCount > 1

	return buildTradeItemsChain(ui, newPage)
end

-- Packs `visibleRows` (already Text-updated by ShowTradeWindow, in
-- GameConfig.Creatures order) into pages by a running pixel-height total —
-- same by-hand packing as ensureDexRowsBuilt's placeItem/beginPage, just
-- recomputed fresh every open instead of once ever, since which creatures
-- are owned changes between trades. Positions each row by hand within its
-- page; nothing here is ever clipped. Always leaves the picker on page 1.
local function packTradeItemsPages(ui, visibleRows)
	local pages = { {} }
	local pageIndex = 1
	local pageY = 0

	for _, row in ipairs(visibleRows) do
		if pageY > 0 and pageY + TRADE_ITEM_ROW_HEIGHT > TRADE_ITEMS_PAGE_HEIGHT_BUDGET then
			pageIndex += 1
			pages[pageIndex] = {}
			pageY = 0
		end
		row.Position = UDim2.new(0, 4, 0, pageY)
		table.insert(pages[pageIndex], row)
		pageY += TRADE_ITEM_ROW_HEIGHT + TRADE_ITEM_LIST_PADDING
	end

	ui.TradeItemsPages = pages
	ui.TradeItemsPageCount = #pages
	ui.TradeItemsCurrentPage = nil -- forces showTradeItemsPage(ui, 1) below to treat this as a fresh pack, not a same-session page turn
end

-- Opens the trade window against `opponentName`, with `myItems` (see
-- CreatureService.GetOwnedSummary) as the picker list on the left — a row
-- per creature you currently own at least one of, laid out in
-- GameConfig.Creatures' fixed order (grouped by rarity, same as the Dex)
-- rather than "order claimed" like before, a small side-effect of switching
-- to fixed pre-built rows: the list no longer reshuffles every time you
-- claim something new. Resets both offer labels back to their empty state,
-- since this is always the start of a brand new negotiation.
function UIBuilder.ShowTradeWindow(ui, opponentName, myItems)
	-- Made visible FIRST, before ensureTradeItemRowsBuilt/any row mutation
	-- below — same fix as the Dex panel (see UIBuilder.Build's comment above
	-- dexContent): rows created/shown while TradeWindowOverlay was still
	-- Visible = false never actually rendered, a Roblox render-cache issue
	-- that goes deeper than just CanvasSize. Showing first means nothing is
	-- ever built while hidden, so there's nothing stale to fail to redraw
	-- later.
	ui.TradeWindowOverlay.Visible = true
	ensureTradeItemRowsBuilt(ui)

	ui.TradeOpponentNameLabel.Text = "Gegner: " .. opponentName
	ui.TradeMyOfferLabel.Text = "Dein Angebot: (nichts ausgewählt)"
	ui.TradeMyOfferLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	ui.TradeOpponentOfferLabel.Text = "Angebot: wählt noch..."
	ui.TradeOpponentOfferLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 24)

	local ownedByName = {}
	for _, item in ipairs(myItems) do
		ownedByName[item.Name] = item
	end

	-- Every row is always forced back to Visible = false here, regardless of
	-- whether it's about to be re-shown — this trade's pagination can pack
	-- differently from last trade's (owning more/fewer creatures shifts
	-- which page each row lands on), so nothing may rely on a row's leftover
	-- Visible state from a previous open.
	local visibleRows = {}
	for _, row in ipairs(ui.TradeItemRowList) do
		row.Visible = false
		local item = ownedByName[row:GetAttribute("CreatureName")]
		if item then
			row.Text = item.Name .. " (" .. item.Rarity .. ")" .. (item.Count > 1 and (" x" .. item.Count) or "")
			table.insert(visibleRows, row)
		end
	end

	ui.TradeItemsEmptyLabel.Visible = #visibleRows == 0

	packTradeItemsPages(ui, visibleRows)
	local chain = showTradeItemsPage(ui, 1)

	-- Gamepad/keyboard: initial focus is the first reachable thing — a
	-- Brainrot to offer if you have any, otherwise straight to Cancel
	-- (there's nothing else to do with an empty inventory).
	pushGamepadFocus(chain[1])
end

-- `state` = {MyOffer, OpponentOffer, MyConfirmed, OpponentConfirmed} from
-- TradeService's "TradeUpdate" event — refreshes just the two offer labels,
-- with a green tint once that side has confirmed.
function UIBuilder.UpdateTradeWindow(ui, state)
	ui.TradeMyOfferLabel.Text = "Dein Angebot: " .. (state.MyOffer or "(nichts ausgewählt)") .. (state.MyConfirmed and " ✓" or "")
	ui.TradeMyOfferLabel.BackgroundColor3 = state.MyConfirmed and Color3.fromRGB(30, 90, 50) or Color3.fromRGB(20, 20, 24)

	ui.TradeOpponentOfferLabel.Text = "Angebot: " .. (state.OpponentOffer or "wählt noch...") .. (state.OpponentConfirmed and " ✓" or "")
	ui.TradeOpponentOfferLabel.BackgroundColor3 = state.OpponentConfirmed and Color3.fromRGB(30, 90, 50) or Color3.fromRGB(20, 20, 24)
end

function UIBuilder.HideTradeWindow(ui)
	ui.TradeWindowOverlay.Visible = false
	popGamepadFocus()
end

-- info = {Success, Reason} from TradeService's "TradeClosed" event — fired
-- whether the trade actually went through, was declined/cancelled, or
-- failed a last-second re-check, so both outcomes get shown, just in
-- different colors (reusing the existing sell/error toasts rather than
-- adding a third one purely for this).
function UIBuilder.ShowTradeResult(ui, info)
	if info.Success then
		fadeMessage(ui.SellToastLabel, tostring(info.Reason), Color3.fromRGB(40, 150, 80))
	else
		fadeMessage(ui.MessageLabel, tostring(info.Reason), Color3.fromRGB(180, 40, 40))
	end
end

-- === Brainrot-Dex ==============================================================

-- Fixed pixel heights of everything the Dex content can ever contain — kept
-- as named constants because pages are packed BY HAND from these instead of
-- trusting any Roblox automatic layout/scrolling system (see the long
-- comment above dexContent in UIBuilder.Build for why: every ClipsDescendants
-- Frame this project has ever tried for the Dex has rendered solid black in
-- the live game, so this panel now uses PAGES of plain, non-clipping Frames
-- instead of a scrolling list).
local DEX_HEADER_HEIGHT = 26
local DEX_ROW_HEIGHT = 56
local DEX_LIST_PADDING = 4
-- How many pixels of content each page may hold before starting a new page.
-- dexContent is 382px tall (dexDialog's 520px minus the 138px reserved above
-- it for the title/close/progress bar); 360 leaves a small margin so the
-- last row on a page never gets flush against dexContent's bottom edge.
local DEX_PAGE_HEIGHT_BUDGET = 360

-- Rarity header text color: normally just the rarity's own accent color
-- (Gold/Diamond/Hacker/Lava/... are all bright enough as-is), but on
-- request ("Die Farbe ist auch kaum Lesbar") — Singularity's Color
-- (Color3.fromRGB(25, 10, 45), a near-black purple picked for its
-- thumbnail/glow elsewhere, see GameConfig.CreatureRarities) is nearly
-- invisible as HEADER TEXT on the Dex's own dark background. Rather than
-- touching GameConfig.CreatureRarities.Singularity.Color itself (used all
-- over the game for thumbnails/particles/etc., where the near-black look
-- IS the intended theming), this blends only the header's OWN text color
-- toward white whenever a rarity's color falls below a minimum perceived
-- brightness — same "Lerp toward white" technique already used elsewhere
-- in this file, just brightening instead of dimming. Already-bright
-- rarities are returned completely untouched; only genuinely dark ones
-- (currently just Singularity, and a little bit Galaxy) actually move.
local MIN_HEADER_LUMINANCE = 130 -- 0-255 scale (perceived brightness, standard 0.299R+0.587G+0.114B weights)
local function legibleHeaderColor(color)
	if not color then
		return Color3.new(1, 1, 1)
	end
	local luminance = (0.299 * color.R + 0.587 * color.G + 0.114 * color.B) * 255
	if luminance >= MIN_HEADER_LUMINANCE then
		return color
	end
	-- Fraction chosen so the RESULT's luminance lands at MIN_HEADER_LUMINANCE,
	-- not just "a little brighter" — a fixed small Lerp fraction wouldn't be
	-- nearly enough to rescue something as dark as Singularity's (25,10,45).
	local fraction = math.clamp((MIN_HEADER_LUMINANCE - luminance) / (255 - luminance), 0, 1)
	return color:Lerp(Color3.new(1, 1, 1), fraction)
end

-- Shows page `newPage` of the Dex and hides whichever page was showing
-- before — the ONLY thing that ever changes an already-built Dex item's
-- Visible property after ensureDexRowsBuilt runs. Nothing is created,
-- destroyed, or moved by turning a page, the same "pre-build once, mutate
-- forever" pattern the Jump Upgrade panel already uses successfully.
local function showDexPage(ui, newPage)
	local pageCount = ui.DexPageCount or 1
	newPage = math.clamp(newPage, 1, pageCount)

	local oldPage = ui.DexCurrentPage
	if oldPage and ui.DexPages[oldPage] then
		for _, inst in ipairs(ui.DexPages[oldPage]) do
			inst.Visible = false
		end
	end

	ui.DexCurrentPage = newPage
	if ui.DexPages[newPage] then
		for _, inst in ipairs(ui.DexPages[newPage]) do
			inst.Visible = true
		end
	end

	ui.DexPageLabel.Text = "Seite " .. newPage .. " / " .. pageCount
end

-- Builds every header + all ~91 creature rows into ui.DexContent, ONCE — the
-- first time UIBuilder.ShowDex below actually runs, never again after (see
-- the long comment above dexContent in UIBuilder.Build for why this has to
-- be lazy rather than living in Build directly). GameConfig.Creatures +
-- GameConfig.CreatureRarities already hold every static field a row needs
-- (Name/Rarity/Color/MinRate/MaxRate) — the ONLY thing that differs per
-- player, and that can change while the game is running, is which ones are
-- Discovered, which is why every row starts in its undiscovered ("???" +
-- dark swatch) state here regardless of this player's actual progress;
-- PopulateDex below reveals already-discovered ones on the very first call
-- right after this.
-- Every header/row is packed into pages by a running pixel-height total
-- (reset whenever the next item would overflow DEX_PAGE_HEIGHT_BUDGET) and
-- positioned by hand within its page — nothing here is ever clipped, and
-- nothing here is ever re-packed after this first build, since the full set
-- of creatures/rarities is static.
local function ensureDexRowsBuilt(ui)
	if ui.DexRowsBuilt then
		return
	end
	ui.DexRowsBuilt = true

	local rows = {} -- ordered, parallel to GameConfig.Creatures
	local pages = {} -- pages[pageIndex] = { instance, instance, ... }
	local headers = {} -- [rarityName] = header TextLabel, on request (see PopulateDex's "(n/m)" + "+10% Cash" completion hint below)
	local lastRarity = nil
	local pageIndex = 1
	local pageY = 0

	local function beginPage()
		pageIndex += 1
		pageY = 0
		pages[pageIndex] = {}
	end

	local function placeItem(inst, height)
		if pageY > 0 and pageY + height > DEX_PAGE_HEIGHT_BUDGET then
			beginPage()
		end
		inst.Position = UDim2.new(0, 4, 0, pageY)
		inst.Parent = ui.DexContent
		table.insert(pages[pageIndex], inst)
		pageY += height + DEX_LIST_PADDING
	end

	pages[1] = {}

	for _, def in ipairs(GameConfig.Creatures) do
		local rarityDef = GameConfig.CreatureRarities[def.Rarity]
		local color = rarityDef and rarityDef.Color

		if def.Rarity ~= lastRarity then
			lastRarity = def.Rarity

			-- Don't let a rarity header end up ORPHANED alone at the bottom
			-- of a page with none of its own rows following it (on request
			-- — a screenshot showed exactly this: the "Singularity" header
			-- sitting alone as the very last item on one page while all 3
			-- Singularity rows started the NEXT page instead, reading like
			-- the header was "auf der falschen Seite"). placeItem below
			-- only ever checks whether THIS ONE item fits on the current
			-- page — it has no idea a header is about to be followed by
			-- rows that need to stay together with it. So: before placing
			-- the header, check whether the header PLUS at least its first
			-- row would still fit in the remaining budget; if not, force a
			-- fresh page now so the header lands together with that first
			-- row instead of dangling alone at the end of the old one.
			local headerPlusFirstRow = DEX_HEADER_HEIGHT + DEX_LIST_PADDING + DEX_ROW_HEIGHT
			if pageY > 0 and pageY + headerPlusFirstRow > DEX_PAGE_HEIGHT_BUDGET then
				beginPage()
			end

			local header = Instance.new("TextLabel")
			header.Name = "Header_" .. def.Rarity
			header.Size = UDim2.new(1, -8, 0, DEX_HEADER_HEIGHT)
			header.BackgroundTransparency = 1
			header.Text = "— " .. def.Rarity .. " —"
			header.TextColor3 = legibleHeaderColor(color)
			header.TextStrokeTransparency = 0.4
			header.Font = Enum.Font.GothamBold
			header.TextScaled = true
			header.ZIndex = 12
			placeItem(header, DEX_HEADER_HEIGHT)
			headers[def.Rarity] = header
		end

		local row = Instance.new("Frame")
		row.Name = "Row_" .. def.Name
		row.Size = UDim2.new(1, -8, 0, DEX_ROW_HEIGHT)
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
		row.ZIndex = 12
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
		placeItem(row, DEX_ROW_HEIGHT)

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(55, 55, 60) -- undiscovered — PopulateDex recolors on reveal
		stroke.Thickness = 2
		stroke.Parent = row

		buildDexThumbnail(row, def.Name, color, false)

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "NameText"
		nameLabel.Size = UDim2.new(1, -68, 0, 26)
		nameLabel.Position = UDim2.new(0, 60, 0, 4)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextScaled = true
		nameLabel.TextStrokeTransparency = 0.5
		nameLabel.TextColor3 = Color3.fromRGB(120, 120, 130)
		nameLabel.Text = "???"
		nameLabel.ZIndex = 12
		nameLabel.Parent = row

		-- On request ("kann man das im Brainrot Dex berücksichtigen, das
		-- immer der richtige Wert angezeigt wird"), this no longer shows a
		-- static rarity-wide "$Min - $Max/s" range set once here — it's this
		-- player's own exact, real Cash/sec for THIS creature (Rebirth/
		-- gamepass/temp-buff included), sent fresh by the server on every Dex
		-- open (see init.server.lua's GetDiscoveredCreatures remote /
		-- EconomyService.GetCreatureRateForPlayer) and written by PopulateDex
		-- below. Shown for every creature regardless of Discovered, on
		-- request, so it starts with a placeholder here and PopulateDex fills
		-- in the real number on the very first call right after this.
		local rateLabel = Instance.new("TextLabel")
		rateLabel.Name = "RateText"
		rateLabel.Size = UDim2.new(1, -68, 0, 20)
		rateLabel.Position = UDim2.new(0, 60, 0, 30)
		rateLabel.BackgroundTransparency = 1
		rateLabel.TextXAlignment = Enum.TextXAlignment.Left
		rateLabel.Font = Enum.Font.Gotham
		rateLabel.TextScaled = true
		rateLabel.TextColor3 = Color3.fromRGB(170, 220, 170)
		rateLabel.Text = "..."
		rateLabel.ZIndex = 12
		rateLabel.Parent = row

		table.insert(rows, {
			Row = row,
			Stroke = stroke,
			NameLabel = nameLabel,
			RateLabel = rateLabel,
			Name = def.Name,
			Color = color,
			Discovered = false, -- flips true (and stays true) the first time PopulateDex sees it discovered
		})
	end

	ui.DexRows = rows
	ui.DexPages = pages
	ui.DexHeaders = headers
	ui.DexPageCount = #pages
	ui.DexCurrentPage = 1

	-- Every item starts parented and positioned, but only page 1 should
	-- actually be visible until the player pages forward.
	for index, items in ipairs(pages) do
		local visible = (index == 1)
		for _, inst in ipairs(items) do
			inst.Visible = visible
		end
	end
	ui.DexPageLabel.Text = "Seite 1 / " .. #pages

	-- Wired here, once, right after the pages exist — Prev/Next only ever
	-- flip .Visible on already-built instances via showDexPage above, never
	-- create/destroy/move anything.
	ui.DexPrevButton.Activated:Connect(function()
		showDexPage(ui, (ui.DexCurrentPage or 1) - 1)
	end)
	ui.DexNextButton.Activated:Connect(function()
		showDexPage(ui, (ui.DexCurrentPage or 1) + 1)
	end)

	-- Gamepad/keyboard: the Dex's rows are pure display (no per-row button),
	-- so the only reachable controls are these 3 — Close/Prev/Next — same
	-- fixed trio regardless of which page is showing, wired once here.
	wireVerticalChain({ ui.DexCloseButton, ui.DexPrevButton })
	wireHorizontalChain({ ui.DexPrevButton, ui.DexNextButton })
end

-- `entries` is the array returned by the "GetDiscoveredCreatures" remote
-- (see init.server.lua): one row per GameConfig.Creatures entry, in that
-- table's existing order — same order ui.DexRows was built in (see
-- ensureDexRowsBuilt above), so this can walk both in lockstep by index
-- instead of matching by name. Only ever MUTATES an existing row now — a
-- creature's row is "revealed" (stroke/name/thumbnail upgraded from "???")
-- exactly once, the very first time it shows up Discovered, and left alone
-- on every call after that, since discovery can only ever go from false to
-- true, never back.
function UIBuilder.PopulateDex(ui, entries)
	local discoveredCount, total = 0, #entries

	-- On request ("wenn man alle rarity Normal gesammelt hat 10% Cash
	-- bekommen, genau so wie alle anderen Rarity Klassen") — per-rarity
	-- discovered/total counts, walked fresh every call (same reasoning as
	-- discoveredCount above: this can change between Dex opens). Recomputed
	-- from `entries` rather than a separate remote field, since entries
	-- already carries both Rarity and Discovered for every creature.
	local rarityDiscovered, rarityTotal = {}, {}
	for _, entry in ipairs(entries) do
		rarityTotal[entry.Rarity] = (rarityTotal[entry.Rarity] or 0) + 1
		if entry.Discovered then
			rarityDiscovered[entry.Rarity] = (rarityDiscovered[entry.Rarity] or 0) + 1
		end
	end

	for i, rowInfo in ipairs(ui.DexRows) do
		local entry = entries[i]
		if entry then
			-- On request ("immer der richtige Wert angezeigt wird") — unlike
			-- the discovery reveal below, this runs on EVERY call (not just
			-- once), since a player's Rebirth/gamepass/temp-buff standing can
			-- change between Dex opens (or even while a temporary Glücksrad
			-- buff is actively running) and the shown number should always
			-- match what the server would actually pay out right now. entry.
			-- Rate is nil only if the server ever sent an unknown creature
			-- name (shouldn't happen — same GameConfig.Creatures on both
			-- sides), guarded here rather than trusting the remote blindly.
			rowInfo.RateLabel.Text = "$" .. UIBuilder.FormatNumber(entry.Rate or 0) .. "/s"

			if entry.Discovered then
				discoveredCount += 1

				if not rowInfo.Discovered then
					rowInfo.Discovered = true
					rowInfo.Stroke.Color = rowInfo.Color or Color3.new(1, 1, 1)
					rowInfo.NameLabel.TextColor3 = Color3.new(1, 1, 1)
					rowInfo.NameLabel.Text = rowInfo.Name

					local oldThumbnail = rowInfo.Row:FindFirstChild("Thumbnail")
					if oldThumbnail then
						oldThumbnail:Destroy()
					end
					buildDexThumbnail(rowInfo.Row, rowInfo.Name, rowInfo.Color, true)
				end
			end
		end
	end

	ui.DexProgressLabel.Text = discoveredCount .. " / " .. total .. " Brainrots entdeckt"

	-- Rewrites every rarity header with its own "(discovered/total)" count,
	-- plus a "+10% Cash" hint either way — on request ("kann man schon
	-- bevor man alles gesammelt hat anzeigen dass es einen Bonus gibt, damit
	-- die Spieler wissen dass es sich lohnt alles zu sammeln") this now shows
	-- a TEASER (🔒, still locked) while incomplete, not just the green ✓
	-- once it's actually earned — same GameConfig.Dex.CompletionCashBoostPerRarity
	-- number either way, the real bonus itself is applied server-side (see
	-- EconomyService's getCashMultiplierFactor / CreatureService.
	-- GetCompletedRarityCount). Deliberately kept the SAME short length as
	-- the ✓ version (just swapping the one icon) rather than spelling out
	-- "bei Vollständigkeit" — this header is a single TextScaled line at a
	-- fixed pixel width (see DEX_HEADER_HEIGHT/ensureDexRowsBuilt), so extra
	-- words would shrink the font a lot just to fit, for both states, not
	-- just this one. Headers are keyed by rarity name (see ensureDexRowsBuilt
	-- above), so this can just walk them directly instead of the row list.
	local completionBoostPercent = math.floor(GameConfig.Dex.CompletionCashBoostPerRarity * 100 + 0.5)
	for rarityName, header in pairs(ui.DexHeaders or {}) do
		local discoveredInRarity = rarityDiscovered[rarityName] or 0
		local totalInRarity = rarityTotal[rarityName] or 0
		local completed = totalInRarity > 0 and discoveredInRarity >= totalInRarity
		local bonusIcon = completed and "✓" or "🔒"
		local bonusText = " " .. bonusIcon .. " +" .. completionBoostPercent .. "% Cash"
		header.Text = "— " .. rarityName .. " (" .. discoveredInRarity .. "/" .. totalInRarity .. ")" .. bonusText .. " —"
	end
end

function UIBuilder.ShowDex(ui)
	ui.DexOverlay.Visible = true
	ensureDexRowsBuilt(ui)
	showDexPage(ui, 1)
	pushGamepadFocus(ui.DexCloseButton)
end

function UIBuilder.HideDex(ui)
	ui.DexOverlay.Visible = false
	popGamepadFocus()
end

-- === Leaderboard panel ==========================================================
-- On request ("die Bestenliste hat Bilder der Spieler und man kann von Top1
-- bis Top 200 runter scrollen" -> "für alle 3 Ranglisten, begrenze es auf
-- top 100 ... seine Position einblenden") — data comes from init.server.
-- lua's GetLeaderboardPanelData remote / LeaderboardService.GetPanelData.
-- PAGED, not scrolled, deliberately — see the long comment above dexContent
-- in UIBuilder.Build for why this project avoids ClipsDescendants/
-- ScrollingFrame entirely: it has repeatedly rendered solid black in the
-- live game. This reuses the exact same proven "pre-build once, flip
-- Visible by page" approach the Dex panel already uses, just with 3 tab-
-- switchable categories sharing one Content frame instead of one.

local LEADERBOARD_CATEGORIES = { "CashPerSecond", "Rebirths", "Cash" }
local LEADERBOARD_RANK_MEDALS = { [1] = "🥇", [2] = "🥈", [3] = "🥉" }

local LB_ROW_HEIGHT = 40
local LB_LIST_PADDING = 4
-- LeaderboardContent is a fixed 460px tall (see UIBuilder.Build) — this
-- leaves a small margin so the last row on a page never sits flush against
-- its bottom edge, same idea as DEX_PAGE_HEIGHT_BUDGET above.
local LB_PAGE_HEIGHT_BUDGET = 440

-- Formats one category's raw number for display — Rebirths is a plain
-- count, Cash/CashPerSecond are Cash amounts (see LeaderboardService.
-- GetOwnStanding/GetPanelData for where these numbers actually come from).
local function formatLeaderboardValue(category, value)
	value = value or 0
	if category == "CashPerSecond" then
		return "$" .. UIBuilder.FormatNumber(value) .. "/s"
	elseif category == "Cash" then
		return "$" .. UIBuilder.FormatNumber(value)
	else
		return tostring(math.floor(value))
	end
end

-- Loads (and caches) a player's headshot into `holder.Avatar` (an ImageLabel).
-- Players:GetUserThumbnailAsync YIELDS (a real web request), so this always
-- runs in its own task.spawn rather than blocking whatever's populating the
-- row/self-row. Row slots get REUSED for whichever player currently holds
-- that rank as the ranking changes over time (see buildLeaderboardRow/
-- UIBuilder.PopulateLeaderboard below), so by the time this resolves,
-- `holder.LoadedUserId` might already have moved on to a DIFFERENT player —
-- the fetched image is only applied if it's still the one this fetch was
-- actually for. The `holder.LoadedUserId == userId` check up front also
-- skips a pointless re-fetch when a slot already shows this exact player
-- (e.g. the panel gets reopened before the ranking has actually changed, or
-- the viewer's OWN avatar in the pinned self-row, which never changes
-- mid-session).
local function loadAvatarThumbnail(holder, userId)
	if not userId or holder.LoadedUserId == userId then
		return
	end
	holder.LoadedUserId = userId
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(
				userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100
			)
		end)
		if ok and content and holder.LoadedUserId == userId then
			holder.Avatar.Image = content
		end
	end)
end

-- Reported live ("die Zahlen überschneiden sich") on the pinned "Du"-row —
-- unlike every list row above (always hidden, THEN text-changed, THEN
-- revealed — see PopulateLeaderboard), the self-row is, BY DESIGN, ALWAYS
-- visible on screen (it has to be, to stay pinned while paging) — so its
-- Rank/Value labels are the one place in this panel where Text genuinely
-- has to change while already on screen. That's the same family of
-- TextScaled rendering quirk already fought at length for the Dex (see
-- dexContent's long comment) — Roblox can leave the OLD text's glyph layout
-- ghosted/overlapping the new one for a label that never goes through a
-- hidden state in between. Clearing the label THIS frame and setting the
-- real text on the NEXT one (task.defer) forces a full, clean TextBounds
-- recompute from empty instead of an in-place update over stale glyphs —
-- the standard, low-cost fix for exactly this symptom.
local function setTextScaledSafely(label, text)
	label.Text = ""
	task.defer(function()
		label.Text = text
	end)
end

-- Highlights whichever tab button matches ui.LeaderboardCurrentCategory,
-- dims the other two — purely visual, changes no data.
local function updateLeaderboardTabButtons(ui)
	for category, button in pairs(ui.LeaderboardTabButtons) do
		if category == ui.LeaderboardCurrentCategory then
			button.BackgroundColor3 = Color3.fromRGB(60, 90, 200)
		else
			button.BackgroundColor3 = Color3.fromRGB(50, 60, 70)
		end
	end
end

-- Refreshes the pinned "Du"-row for whichever category is currently shown —
-- on request ("man kann ja den jeweiligen Spieler unten einblenden der
-- gerade schaut und seine Position einblenden"), this is ALWAYS visible
-- (never paged away), reading the Self standing the server already computed
-- for exactly this category (see LeaderboardService.GetOwnStanding). A nil
-- Rank means the viewer is outside the window the server actually searched
-- (see GameConfig.Leaderboard.RankSearchExtraPages' own comment) — shown as
-- "außerhalb Top N" with their real live Value still displayed, rather than
-- nothing at all.
local function updateLeaderboardSelfRow(ui)
	local category = ui.LeaderboardCurrentCategory
	local categoryData = ui.LeaderboardData and ui.LeaderboardData[category]
	local selfInfo = categoryData and categoryData.Self

	if not selfInfo then
		setTextScaledSafely(ui.LeaderboardSelfRankLabel, "?")
		setTextScaledSafely(ui.LeaderboardSelfValueLabel, "")
		return
	end

	if selfInfo.Rank then
		setTextScaledSafely(ui.LeaderboardSelfRankLabel, LEADERBOARD_RANK_MEDALS[selfInfo.Rank] or ("#" .. selfInfo.Rank))
	else
		local searchedUpTo = GameConfig.Leaderboard.TopCount
			+ GameConfig.Leaderboard.RankSearchExtraPages * GameConfig.Leaderboard.TopCount
		setTextScaledSafely(ui.LeaderboardSelfRankLabel, "außerhalb Top " .. searchedUpTo)
	end
	setTextScaledSafely(ui.LeaderboardSelfValueLabel, formatLeaderboardValue(category, selfInfo.Value))

	-- The viewer's own avatar never changes mid-session — loadAvatarThumbnail's
	-- own LoadedUserId check means this only actually fetches once, on the
	-- very first call.
	loadAvatarThumbnail(ui.LeaderboardSelfRowInfo, Players.LocalPlayer.UserId)
end

-- Shows page `newPage` of `category` and hides whichever page (of that same
-- category) was showing before — the ONLY thing that ever changes an
-- already-built Leaderboard row's Visible property after
-- ensureLeaderboardRowsBuilt runs, same "pre-build once, mutate forever"
-- pattern as the Dex's showDexPage above. A row only actually becomes
-- Visible if it also HasData (see UIBuilder.PopulateLeaderboard) — a
-- category with fewer than a full page of entries never shows empty
-- trailing rows.
local function showLeaderboardPage(ui, category, newPage)
	-- Reported live ("wenn ich zwischen den Anzeigen switche vermischen sich
	-- die Werte" — values mix together when switching tabs): all 3
	-- categories' rows are pre-built into the SAME shared ui.LeaderboardContent
	-- frame at IDENTICAL on-screen positions (see buildCategoryRows /
	-- ensureLeaderboardRowsBuilt above), differentiated only by which set is
	-- Visible = true. This function used to only manage the ONE category
	-- passed in, so switching tabs left the PREVIOUSLY active category's page
	-- still Visible = true while the new category's page also became
	-- Visible = true — two categories' names/values rendering on top of each
	-- other at the same spot. Defensively hiding every OTHER category's
	-- currently-shown page first, on every call, fixes this no matter which
	-- caller (tab buttons, Prev/Next buttons, PopulateLeaderboard) triggered it.
	for otherCategory, otherState in pairs(ui.LeaderboardCategories) do
		if otherCategory ~= category and otherState.CurrentPage and otherState.Pages[otherState.CurrentPage] then
			for _, rowInfo in ipairs(otherState.Pages[otherState.CurrentPage]) do
				rowInfo.Row.Visible = false
			end
		end
	end

	local state = ui.LeaderboardCategories[category]
	local pageCount = state.PageCount or 1
	newPage = math.clamp(newPage, 1, pageCount)

	local oldPage = state.CurrentPage
	if oldPage and state.Pages[oldPage] then
		for _, rowInfo in ipairs(state.Pages[oldPage]) do
			rowInfo.Row.Visible = false
		end
	end

	state.CurrentPage = newPage
	if state.Pages[newPage] then
		for _, rowInfo in ipairs(state.Pages[newPage]) do
			rowInfo.Row.Visible = rowInfo.HasData
		end
	end

	ui.LeaderboardPageLabel.Text = "Seite " .. newPage .. " / " .. pageCount
end

-- Builds one row slot (rank + avatar + name + value) — `index` is its FIXED
-- rank position within this category's row pool (1..TopCount), used only for
-- the top-3 medal emoji and as the plain rank number fallback; the row's
-- actual CONTENT (name/value/avatar) gets rewritten every time fresh data
-- arrives (see UIBuilder.PopulateLeaderboard), the rank number itself never
-- needs to change since a row's POSITION in the list already fixes its rank.
local function buildLeaderboardRow(parent, index)
	local row = Instance.new("Frame")
	row.Name = "Row_" .. index
	row.Size = UDim2.new(1, -8, 0, LB_ROW_HEIGHT)
	row.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
	row.Visible = false
	row.ZIndex = 12
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
	row.Parent = parent

	local rankLabel = Instance.new("TextLabel")
	rankLabel.Name = "RankText"
	rankLabel.Size = UDim2.new(0, 40, 1, -6)
	rankLabel.Position = UDim2.new(0, 4, 0, 3)
	rankLabel.BackgroundTransparency = 1
	rankLabel.Font = Enum.Font.GothamBold
	rankLabel.TextScaled = true
	rankLabel.TextColor3 = Color3.new(1, 1, 1)
	rankLabel.Text = LEADERBOARD_RANK_MEDALS[index] or tostring(index)
	rankLabel.ZIndex = 13
	rankLabel.Parent = row

	local avatarImage = Instance.new("ImageLabel")
	avatarImage.Name = "Avatar"
	avatarImage.Size = UDim2.new(0, 34, 0, 34)
	avatarImage.Position = UDim2.new(0, 48, 0, 3)
	avatarImage.BackgroundColor3 = Color3.fromRGB(55, 55, 62)
	avatarImage.ScaleType = Enum.ScaleType.Fit
	avatarImage.ZIndex = 13
	avatarImage.Parent = row
	Instance.new("UICorner", avatarImage).CornerRadius = UDim.new(0, 6)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameText"
	nameLabel.Size = UDim2.new(1, -260, 1, -6)
	nameLabel.Position = UDim2.new(0, 90, 0, 3)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.Text = ""
	nameLabel.ZIndex = 13
	nameLabel.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "ValueText"
	valueLabel.Size = UDim2.new(0, 150, 1, -6)
	valueLabel.Position = UDim2.new(1, -158, 0, 3)
	valueLabel.BackgroundTransparency = 1
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextScaled = true
	valueLabel.TextColor3 = Color3.fromRGB(170, 220, 170)
	valueLabel.Text = ""
	valueLabel.ZIndex = 13
	valueLabel.Parent = row

	return {
		Row = row,
		NameLabel = nameLabel,
		ValueLabel = valueLabel,
		Avatar = avatarImage,
		HasData = false,
		LoadedUserId = nil,
	}
end

-- Builds all GameConfig.Leaderboard.TopCount (100) row slots for ONE
-- category, packed into pages by a running pixel-height total — exactly the
-- same by-hand packing ensureDexRowsBuilt's placeItem does above, just as a
-- standalone function here since 3 separate categories each need their own
-- independent page set sharing the one Content frame.
local function buildCategoryRows(parent)
	local rows = {}
	local pages = { {} }
	local pageIndex = 1
	local pageY = 0

	for i = 1, GameConfig.Leaderboard.TopCount do
		local rowInfo = buildLeaderboardRow(parent, i)
		if pageY > 0 and pageY + LB_ROW_HEIGHT > LB_PAGE_HEIGHT_BUDGET then
			pageIndex += 1
			pages[pageIndex] = {}
			pageY = 0
		end
		rowInfo.Row.Position = UDim2.new(0, 4, 0, pageY)
		pageY += LB_ROW_HEIGHT + LB_LIST_PADDING
		table.insert(pages[pageIndex], rowInfo)
		table.insert(rows, rowInfo)
	end

	return rows, pages
end

-- Builds all 3 categories' row pools and wires the Prev/Next/tab buttons —
-- ONCE, the first time the panel is actually shown (see
-- UIBuilder.ShowLeaderboardPanel below), same lazy-build timing (and for the
-- same "nothing built while Visible = false ever renders correctly here"
-- reason) as ensureDexRowsBuilt above.
local function ensureLeaderboardRowsBuilt(ui)
	if ui.LeaderboardRowsBuilt then
		return
	end
	ui.LeaderboardRowsBuilt = true

	ui.LeaderboardCurrentCategory = ui.LeaderboardCurrentCategory or LEADERBOARD_CATEGORIES[1]
	ui.LeaderboardCategories = {}
	for _, category in ipairs(LEADERBOARD_CATEGORIES) do
		local rows, pages = buildCategoryRows(ui.LeaderboardContent)
		ui.LeaderboardCategories[category] = {
			Rows = rows,
			Pages = pages,
			PageCount = #pages,
			CurrentPage = nil,
		}
	end

	ui.LeaderboardPrevButton.Activated:Connect(function()
		local state = ui.LeaderboardCategories[ui.LeaderboardCurrentCategory]
		showLeaderboardPage(ui, ui.LeaderboardCurrentCategory, (state.CurrentPage or 1) - 1)
	end)
	ui.LeaderboardNextButton.Activated:Connect(function()
		local state = ui.LeaderboardCategories[ui.LeaderboardCurrentCategory]
		showLeaderboardPage(ui, ui.LeaderboardCurrentCategory, (state.CurrentPage or 1) + 1)
	end)

	for category, button in pairs(ui.LeaderboardTabButtons) do
		button.Activated:Connect(function()
			ui.LeaderboardCurrentCategory = category
			updateLeaderboardTabButtons(ui)
			showLeaderboardPage(ui, category, 1)
			updateLeaderboardSelfRow(ui)
		end)
	end

	-- Gamepad/keyboard: Close on top, the 3 category tabs as a Left/Right
	-- row underneath, Prev/Next as another Left/Right row below that — same
	-- fixed layout regardless of which page/category is showing, so this is
	-- wired once, here, rather than rebuilt per Populate/page-change like
	-- the other panels' row lists (the individual leaderboard entries are
	-- pure display, not buttons, same as the Dex's rows).
	local leaderboardTabOrder = {}
	for _, category in ipairs(LEADERBOARD_CATEGORIES) do
		table.insert(leaderboardTabOrder, ui.LeaderboardTabButtons[category])
	end
	wireHorizontalChain(leaderboardTabOrder)
	wireHorizontalChain({ ui.LeaderboardPrevButton, ui.LeaderboardNextButton })

	ui.LeaderboardCloseButton.Selectable = true
	ui.LeaderboardCloseButton.NextSelectionDown = leaderboardTabOrder[1]
	for _, tabButton in ipairs(leaderboardTabOrder) do
		tabButton.NextSelectionUp = ui.LeaderboardCloseButton
		tabButton.NextSelectionDown = ui.LeaderboardPrevButton
	end
	ui.LeaderboardPrevButton.NextSelectionUp = leaderboardTabOrder[1]
	ui.LeaderboardNextButton.NextSelectionUp = leaderboardTabOrder[1]
end

-- `data` is the object returned by the "GetLeaderboardPanelData" remote (see
-- init.server.lua / LeaderboardService.GetPanelData): { Rebirths =
-- {Entries, Self}, Cash = {...}, CashPerSecond = {...} }. Rewrites every
-- already-built row's text/avatar for ALL 3 categories (not just whichever
-- one is currently shown), so switching tabs afterwards never shows stale
-- data, then shows page 1 of whichever category is currently selected.
function UIBuilder.PopulateLeaderboard(ui, data)
	ui.LeaderboardData = data

	for _, category in ipairs(LEADERBOARD_CATEGORIES) do
		local state = ui.LeaderboardCategories[category]
		local entries = (data[category] and data[category].Entries) or {}

		for i, rowInfo in ipairs(state.Rows) do
			-- Reported live ("die Zahlen überschneiden sich") — on the SECOND
			-- (and every later) time the panel opens, a row that was left
			-- Visible = true from the previous open gets its Name/Value text
			-- rewritten WHILE still visible on screen, which is exactly the
			-- same family of TextScaled/Visible-timing rendering bug already
			-- documented at length above the Dex's dexContent (there it showed
			-- as solid black; here it shows as ghosted/overlapping glyphs from
			-- the old and new text). Unconditionally hiding every row FIRST —
			-- before ANY text gets rewritten below — guarantees text is always
			-- changed while hidden, then revealed cleanly afterwards by
			-- showLeaderboardPage, on every open, not just the first.
			rowInfo.Row.Visible = false

			local entry = entries[i]
			if entry then
				rowInfo.HasData = true
				rowInfo.NameLabel.Text = entry.Name or "?"
				rowInfo.ValueLabel.Text = formatLeaderboardValue(category, entry.Value)
				loadAvatarThumbnail(rowInfo, entry.UserId)
			else
				rowInfo.HasData = false
				rowInfo.NameLabel.Text = ""
				rowInfo.ValueLabel.Text = ""
			end
		end
	end

	local category = ui.LeaderboardCurrentCategory or LEADERBOARD_CATEGORIES[1]
	ui.LeaderboardCurrentCategory = category
	updateLeaderboardTabButtons(ui)
	showLeaderboardPage(ui, category, 1)
	updateLeaderboardSelfRow(ui)
end

-- ShowLeaderboardPanel BEFORE PopulateLeaderboard, deliberately — same
-- ordering (and the same underlying "nothing built/updated while an
-- ancestor is still Visible = false ever renders" reason, see the Dex's own
-- long comment on it) as UIBuilder.ShowDex/PopulateDex above.
function UIBuilder.ShowLeaderboardPanel(ui)
	ui.LeaderboardOverlay.Visible = true
	ensureLeaderboardRowsBuilt(ui)
	pushGamepadFocus(ui.LeaderboardCloseButton)
end

function UIBuilder.HideLeaderboardPanel(ui)
	ui.LeaderboardOverlay.Visible = false
	popGamepadFocus()
end

return UIBuilder
