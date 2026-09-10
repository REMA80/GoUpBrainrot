# TO-DO Liste

## Event

- [ ] **Buff-Regen**: Während des wöchentlichen Events (`GameConfig.Event`-Fenster) fallen Effekte vom Himmel über die Basen, die auf zufälligen Brainrots "hängen bleiben".
  - Sichtbar: kleines Buff-Symbol schwebt oberhalb des betroffenen Brainrots (ähnlich der bestehenden Rarity-Glow-Anzeige in `CreatureModelDisplay.lua`).
  - Effekt: das betroffene Brainrot macht temporär mehr Geld/Sek. (Umsetzung als Seltenheits-Upgrade — Brainrot wird für die Buff-Dauer wie eine höhere Rarity behandelt und bekommt deren höhere Cash-Rate).
  - Buff läuft nach einer festen Dauer automatisch wieder ab.
