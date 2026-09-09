--[[
	SoundPlayer.lua
	Tiny client-side audio helper. Builds one unparented "template" Sound per
	entry in GameConfig.Sounds that actually has a SoundId filled in (see that
	table's own comment for how to fill one in via Studio's Toolbox), and
	exposes SoundPlayer.Play(key) to fire it.

	Every effect is CLONE-and-play, not reusing/restarting a single shared
	Sound instance — calling Play(key) twice in quick succession (e.g.
	quickly walking over two pedestals) would otherwise cut the first
	playback off short instead of letting both be heard. Debris cleans each
	clone up a few seconds after it starts, so nothing piles up in
	SoundService over a long play session.

	A blank SoundId (the GameConfig default) just means Play(key) is a silent
	no-op for that key — nothing errors, nothing plays — exactly like
	GameConfig.Creatures' "no model dropped in yet -> shows a colored ball
	instead" fallback elsewhere in this project.
]]

local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local SoundPlayer = {}

-- How long a fired clone is allowed to live before Debris removes it.
-- Deliberately generous (most SFX are well under this) rather than reading
-- Sound.TimeLength — that property isn't reliably populated the instant a
-- freshly-created Sound is made, before its asset has actually loaded.
local CLONE_LIFETIME_SECONDS = 8

local templates = {} -- [key] = unparented template Sound (only for non-blank entries)
local musicSound = nil
local initialized = false

-- Builds every template/starts music. Safe to call more than once (e.g. if
-- ClientMain re-runs for some reason) — later calls are a no-op.
function SoundPlayer.Init()
	if initialized then
		return
	end
	initialized = true

	for key, def in pairs(GameConfig.Sounds) do
		if key ~= "BackgroundMusic" and def.Id and def.Id ~= "" then
			local template = Instance.new("Sound")
			template.Name = key
			template.SoundId = def.Id
			template.Volume = def.Volume or 0.5
			templates[key] = template
		end
	end

	local musicDef = GameConfig.Sounds.BackgroundMusic
	if musicDef and musicDef.Id and musicDef.Id ~= "" then
		musicSound = Instance.new("Sound")
		musicSound.Name = "BackgroundMusic"
		musicSound.SoundId = musicDef.Id
		musicSound.Volume = musicDef.Volume or 0.15
		musicSound.Looped = true
		musicSound.Parent = SoundService
		musicSound:Play()
	end
end

-- Fires the sound effect registered under `key` (see GameConfig.Sounds for
-- the full list of valid keys) — silently does nothing if that key has no
-- SoundId filled in yet, or isn't a recognized key at all.
function SoundPlayer.Play(key)
	local template = templates[key]
	if not template then
		return
	end

	local clone = template:Clone()
	clone.Parent = SoundService
	clone:Play()
	Debris:AddItem(clone, CLONE_LIFETIME_SECONDS)
end

return SoundPlayer
