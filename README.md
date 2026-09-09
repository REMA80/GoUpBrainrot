# Go Up for Brainrot — Roblox Prototype

A Roblox reinterpretation of the Fortnite Creative map **"Go Up for Brainrots"**
(a vertical Simulator/Tycoon climb: jump-power upgrades, a cash economy, a
Rebirth/prestige loop, and collectible "Brainrot" creatures). This is an
**original build with its own code, tuning, and creature names** — not a copy
of Fortnite's assets or scripts.

Everything — the tower, the UI, the Remotes — is generated **in code** when
the server starts. There is nothing to manually place in Studio; you just sync
the scripts in and press Play.

## What's included

- **60-floor climbing tower**, generated procedurally, split into 6 color-coded
  zones, with a checkpoint every 5 floors and a fall-reset if you drop off.
- **Jump-power upgrade shop**: 10 tiers, each costing more Cash and jumping
  higher, so the tower gets easier to climb as you invest.
- **Cash economy**: passive income scaled by your highest floor reached and
  your total multiplier.
- **Rebirth / prestige system**: once you reach floor 60, you can reset Cash
  and your jump tier for a permanent +50%-per-rebirth cash multiplier.
- **Collectible creatures**: a pickup spawns every 3 floors, dropping one of
  15 original "brainrot"-style creatures across 5 rarities (Common → Mythic).
  Each unique creature you own adds a small permanent cash bonus.
- **3 Game Passes** wired up end-to-end: 2x Cash, Auto Climb Boost, VIP —
  ready to go live the moment you fill in real Game Pass IDs.
- **DataStore persistence** (Cash, jump tier, rebirths, highest floor,
  creature inventory), saved on leave and on server shutdown.
- A code-built HUD (stats, upgrade button, rebirth button, creature
  collection panel, gamepass shop) — no manual GUI layout needed.

## On the "Brainrot" characters

You told me the character direction is still undecided, so I gave every
creature an **original**, brainrot-meme-*styled* name (e.g. "Tigrini
Spaghetti", "Vulcano Waffle") rather than copying specific real internet
characters (like the ones the Fortnite map uses). This keeps the prototype
legally clean. If you later want to lean on real "Italian brainrot" memes,
that's a business/legal call worth making deliberately — Roblox's Terms and
general IP law don't treat "it's just a meme" as a blanket pass, especially
for anything monetized. Renaming/reskinning is a five-minute edit in
`GameConfig.lua` either way.

## Setup (Rojo)

This project uses **[Rojo](https://rojo.space)**, the standard tool for
syncing a filesystem of scripts into Roblox Studio. It's free and this is a
normal, widely-used workflow — not a hack.

1. **Install Rojo.**
   - Easiest: install the **"Rojo"** plugin from the Roblox Studio plugin
     marketplace (search "Rojo" by evaera/rojo), *and* the Rojo CLI. The
     simplest way to get the CLI is via
     [Aftman](https://github.com/LPGhatguy/aftman) (`aftman install`, or
     `cargo install rojo` if you have Rust). Full instructions:
     https://rojo.space/docs/v7/getting-started/installation/
2. Open a terminal in this project folder (the one with
   `default.project.json`) and run:
   ```
   rojo serve
   ```
3. In Roblox Studio, open a new/blank place, open the **Rojo** plugin panel,
   and click **Connect**. All the scripts sync in instantly, in the right
   places, under the right names.
4. Press **Play** (or Play Solo) to test.

If you'd rather not install anything and just want to look at the code, every
file is plain, readable Luau — you can also copy/paste each file by hand into
the matching Studio location (see the tree below).

## Instance tree this produces

```
ReplicatedStorage
  Modules/GameConfig            (ModuleScript — all balance numbers & content)
  Remotes/                      (created at runtime by the server)
    DataUpdated, CreatureObtained     (RemoteEvents)
    BuyJumpUpgrade, Rebirth           (RemoteFunctions)
ServerScriptService
  Server                        (Script — init.server.lua)
    TowerGenerator, PlayerDataManager, EconomyService,
    CreatureService, MonetizationService   (ModuleScripts)
StarterPlayer/StarterPlayerScripts
  ClientMain                    (LocalScript — init.client.lua)
    UIBuilder                   (ModuleScript)
```

## Testing DataStore saves in Studio

DataStores are disabled in Studio by default. To test saving/loading:
**Game Settings → Security → "Enable Studio Access to API Services"** → On.
Without this, the game still runs fine — `PlayerDataManager` just falls back
to fresh default data every time, silently (see the `pcall` in
`PlayerDataManager.lua`).

## Publishing & setting up real Game Passes

Roblox won't let you create Game Passes until the game has been published at
least once.

1. **File → Publish to Roblox**, give it a name and icon.
2. Go to the game's page on the Creator Dashboard → **Monetization → Passes**
   and create three passes: *2x Cash*, *Auto Climb Boost*, *VIP* (whatever
   price you like).
3. Copy each pass's numeric ID into
   `src/ReplicatedStorage/Modules/GameConfig.lua`, replacing the `Id = 0`
   placeholders in `GameConfig.Gamepasses`.
4. Publish again. That's it — `MonetizationService.lua` and the shop buttons
   already know what to do with real IDs.

## Tuning

`GameConfig.lua` is the only file you should need to touch for balance work:
floor count/spacing, jump tier costs & power, rebirth requirement, passive
income rate, creature rarity odds & cash boosts, and creature spawn
frequency. Everything else reads from it.

## Known MVP simplifications (worth knowing about)

- **Auto Climb Boost** currently just multiplies jump power by 1.25x rather
  than doing true automated pathing up the tower. True auto-climbing (e.g. a
  scripted path-follow) is a reasonable v2 feature if you want it.
- **Floor gap/jump-power balance is untested in the live engine.** I built it
  from Roblox's jump-height formula on paper; real play always feels
  different once ping, camera angle, and platform edges are involved.
  Playtest floor-by-floor in Studio and adjust `JumpTiers` and
  `Floors.HorizontalOffset`/`Spacing` as needed.
- **No anti-exploit hardening yet.** Cash purchases are already re-validated
  server-side (a modified client can't buy upgrades it can't afford), but a
  player using a fly/teleport exploit could in theory touch floor detectors
  out of order. Fine for a prototype; worth adding basic distance/velocity
  sanity checks before a public launch.
- **Fall-detection** scans all players every frame (`Heartbeat`). Totally
  fine at prototype scale; if you ever have hundreds of concurrent players
  you'd want a per-character connection instead.
- **Placeholder art**: creature pickups are glowing pink balls, floors are
  flat colored blocks, and floor numbers are plain `BillboardGui` text.
  Swap in your own meshes/decals/particles whenever you're ready — none of
  the logic depends on the visuals.

## Ideas for next steps

Sound effects & particles on floor-reach/pickup/rebirth, mobile touch-control
testing, a proper leaderboard GUI, trading, badges, more zones with custom
terrain/art, a "featured creature" equip slot with a bigger bonus, and a
starter Developer Product (e.g. "instant +5000 Cash") alongside the Game
Passes.
