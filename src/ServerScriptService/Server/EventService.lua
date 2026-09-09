--[[
	EventService.lua
	Tells the rest of the game whether the weekly Hacker/Lava event
	window (GameConfig.Event) is active right now. Mostly stateless (just
	reads the server's clock), except for the manual test override below —
	so nothing needs to call Init() on this one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local EventService = {}

-- Manual override for testing (see init.server.lua's "/event on"/"/event
-- off" chat command) — when true, IsActive() always returns true regardless
-- of the real schedule below. Lives only in server memory, so it resets
-- back to "follow the schedule" every time the server restarts.
local forceActive = false

-- os.time() (real Unix seconds) timestamp at which the current Admin-Abuse
-- window ends, or nil when none is running — set by AdminAbuseService.lua's
-- "/adminabuse <Minuten>" chat command (see init.server.lua). Deliberately
-- os.time(), NOT os.clock(): os.clock() measures CPU time actually spent
-- executing, not real wall-clock time — during the long idle stretches a
-- 20-minute event mostly consists of (waiting on task.delay between
-- Heartbeats), barely any CPU time accumulates at all, so an os.clock()-based
-- timer would take far longer than 20 REAL minutes to expire (caught by
-- /tmp/admin_abuse_event_service_test.lua's mock test: a real sleep() didn't
-- advance it). os.time() is the same real-wall-clock, resets-on-restart-only-
-- because-it's-in-memory approach SummitChestService.lua already uses for
-- its own cooldown (LastSummitChestAt) — proven safe for exactly this job.
local adminAbuseUntil = nil

function EventService.SetForceActive(active)
	forceActive = active
end

-- Starts (or restarts/extends, if one is already running) a timed
-- Admin-Abuse window lasting `seconds` from right now. While active, this
-- makes IsActive() below return true — WITHOUT touching forceActive — so
-- Admin Abuse rides the exact same EventOnly creature-drop pipeline
-- (CreatureService.rollEventCreature / GameConfig.Event.DropChancePercent)
-- the weekly scheduled window already uses, instead of a second parallel
-- rarity system.
function EventService.SetAdminAbuseActive(seconds)
	adminAbuseUntil = os.time() + seconds
end

-- Ends the Admin-Abuse window immediately (used by AdminAbuseService.Stop,
-- both for "/adminabuse off" and for the automatic end-of-duration timeout).
function EventService.StopAdminAbuse()
	adminAbuseUntil = nil
end

function EventService.IsAdminAbuseActive()
	return adminAbuseUntil ~= nil and os.time() < adminAbuseUntil
end

-- Used by AdminAbuseService to show a live "X Minuten verbleibend" Notice
-- without duplicating its own separate timer — 0 once expired or if no
-- window is running at all.
function EventService.GetAdminAbuseRemainingSeconds()
	if not adminAbuseUntil then
		return 0
	end
	return math.max(0, adminAbuseUntil - os.time())
end

-- Roblox server clocks run in UTC. GameConfig.Event.UtcOffsetHours shifts
-- that to the "local" time the event is scheduled against, INCLUDING
-- rolling the day-of-week forward/back if the offset crosses midnight (e.g.
-- 23:30 UTC + 2h = 01:30 the next local day).
function EventService.IsActive()
	if forceActive or EventService.IsAdminAbuseActive() then
		return true
	end

	local cfg = GameConfig.Event

	-- Temporärer Kill-Switch (GameConfig.Event.Enabled) — auf request aus,
	-- damit das wöchentliche Fenster nicht automatisch startet. Nur der
	-- SCHEDULE-Teil ist betroffen; forceActive/AdminAbuse oben laufen
	-- weiterhin unabhängig davon, falls gezielt getestet werden soll.
	if cfg.Enabled == false then
		return false
	end

	local utcNow = os.date("!*t")

	local shiftedHour = utcNow.hour + cfg.UtcOffsetHours
	local dayShift = math.floor(shiftedHour / 24)
	local localHour = shiftedHour % 24

	-- os.date's wday is 1 = Sunday ... 7 = Saturday, matching GameConfig.
	local localWday = ((utcNow.wday - 1 + dayShift) % 7) + 1

	if localWday ~= cfg.DayOfWeek then
		return false
	end

	return localHour >= cfg.StartHour and localHour < cfg.EndHour
end

return EventService
