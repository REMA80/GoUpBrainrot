# TO-DO Liste

## Event

- [ ] **Buff-Regen**: Während des wöchentlichen Events (`GameConfig.Event`-Fenster) fallen Effekte vom Himmel über die Basen, die auf zufälligen Brainrots "hängen bleiben".
  - Sichtbar: kleines Buff-Symbol schwebt oberhalb des betroffenen Brainrots (ähnlich der bestehenden Rarity-Glow-Anzeige in `CreatureModelDisplay.lua`).
  - Effekt: das betroffene Brainrot macht temporär mehr Geld/Sek. (Umsetzung als Seltenheits-Upgrade — Brainrot wird für die Buff-Dauer wie eine höhere Rarity behandelt und bekommt deren höhere Cash-Rate).
  - Buff läuft nach einer festen Dauer automatisch wieder ab.

## Basen

- [ ] **Erweiterung auf 6 Basen** (statt aktuell 4, `GameConfig.Base.MaxPlayers`).
  - Code liest `MaxPlayers` bereits überall dynamisch aus (Basen-Kreis, Trade-Zone-Liste, Leaderboard, Kapazitätsprüfungen) — keine feste "4" irgendwo verdrahtet.
  - Nötig: `GameConfig.Base.MaxPlayers` auf 6 setzen, `Players.MaxPlayers` in Studio manuell mitziehen (Game Settings → Basic Info), `PlotRadius` (aktuell 130 Studs) wahrscheinlich etwas erhöhen, damit die vorderen Kiosk-Stationen benachbarter Basen nicht zu eng aneinanderrücken — in Studio kurz gegenprüfen.

## Minigame-Anbindung (RobloxVampireSurvivors) — vorerst zurückgestellt

Code-Seite (Portal, Cooldown-Timer, Cross-Game-DataStore-Belohnung) wurde einmal gebaut und dann wieder entfernt: Roblox lässt eine bereits bestehende, eigenständige Experience nicht per "Ort hinzufügen" in eine andere Experience einhängen ("Startorte können nicht ausgewählt werden"). Der eigentliche Weg wäre, ein NEUES leeres Place innerhalb dieser Experience anzulegen und den RobloxVampireSurvivors-Code dort per Rojo reinzusynchronisieren — das war einstweilen nicht gewünscht. Bei Bedarf später erneut aufgreifen.
