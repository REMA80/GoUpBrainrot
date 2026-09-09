--[[
	ShopService.lua

	REMOVED (on request, "Komplett aus dem Spiel entfernen"). This file used
	to implement the entire Slap Hand PvP tool — a Cash-bought Tool with a
	swing/knockback/cooldown system (ShopService.BuySlapHand, .Init,
	.EnsureToolModelsFolder, .GiveSlapHandIfOwned, plus the internal
	wireSlapHandActivated/buildProceduralSlapHandTool/buildSlapHandTool
	helpers) and its own purchase kiosk in the base.

	Everything that called into this module has been removed too:
	init.server.lua no longer requires this file, never creates the
	"BuySlapHand" RemoteFunction, never calls ShopService.Init/
	EnsureToolModelsFolder, and no longer re-grants the tool on
	CharacterAdded. GameConfig.Shop (which only ever held the SlapHand
	sub-table) is gone. EconomyService no longer sends OwnsSlapHand in the
	DataUpdated payload, and PlayerDataManager no longer initializes an
	OwnsSlapHand field for new players.

	This file is kept only as an inert, empty stub — nothing requires it
	anymore, so it does nothing and costs nothing at runtime. It is safe to
	delete this file entirely (in Studio's Explorer or on disk in the synced
	project) if you'd rather not have it sitting there; nothing references
	"ShopService" anywhere else in the project anymore.

	Note for existing players: anyone who already owns/owned the Slap Hand
	(data.OwnsSlapHand == true in their old save) is unaffected by this file
	being emptied — that old field is just never read again. A copy of the
	Tool that was already sitting in a player's Backpack before this update
	is not retroactively deleted by this change; it disappears the next
	time they die/respawn (equipped Tools are destroyed with the rest of the
	Backpack on death) since GiveSlapHandIfOwned no longer runs to re-grant
	it.
]]

return {}
