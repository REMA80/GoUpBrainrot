# Checkliste: 3D-Modelle aus deinem Toolbox-Pack einfügen

Diese Liste sagt dir, aus welchem Unterordner deines Packs (`BrainrotPack/Normal`, `BrainrotPack/Oro`, usw.) du jede Kreatur ziehen musst — passend zu der Rarity, die sie in `GameConfig.Creatures` gerade hat. Die Namen stimmen bereits 1:1 mit den Modellnamen in deinem Pack überein, du musst also **nichts umbenennen**.

## So gehst du vor (pro Kreatur)

1. Öffne dein Projekt in **Roblox Studio**, im **EDIT-Modus** (nicht im Playtest — sonst geht alles beim Stoppen wieder verloren).
2. Falls `ReplicatedStorage.CreatureModels` noch nicht existiert: einmal kurz **Play** drücken und wieder **Stop** (der Ordner wird beim ersten Server-Start automatisch angelegt) — oder leg ihn selbst manuell an (Rechtsklick auf ReplicatedStorage → Insert Object → Folder → Name `CreatureModels`).
3. Klapp in deinem Pack (`BrainrotPack`) den Unterordner auf, der unten bei der jeweiligen Kreatur steht (z. B. `Hacker` für "Dragon Cannelloni").
4. Zieh das passende Modell **direkt** nach `ReplicatedStorage.CreatureModels` (nicht in einen Unterordner — das Spiel sucht dort flach, ohne Unterordner).
5. Der Name bleibt wie er ist (schon exakt passend). Fertig für diese Kreatur.

Wiederhole das für so viele/wenige Kreaturen wie du willst — jede, die (noch) kein Modell hat, zeigt einfach weiter die farbige Platzhalter-Kugel. Kein Rebuild nötig, nur beim nächsten **Play** wird der Ordner neu eingelesen (Modelle, die du WÄHREND des Playtests reinziehst, brauchen ein Stop+Play, um erkannt zu werden).

## Optional: Blickrichtung korrigieren

Steht ein Modell falsch rum auf dem Pedestal, füg in `GameConfig.Creatures` bei diesem Eintrag `ModelYRotation = 180` (oder 90/270) hinzu und probier durch, bis es passt — sag mir einfach welchen Wert, ich trag ihn ein.

---

## Normal (18) — aus `BrainrotPack/Normal`
- Ballerina Cappuccina
- Chef Crabracadabra
- Pipi Kiwi
- Pipi Potato
- Six Seven
- Svinina Bombardino
- Swag Soda
- Tigroligre Frutonni
- Tim Cheese
- Tirilikalika Tirilikalako
- Torrtuginni Dragonfrutini
- Tralalita Tralala
- Tric Trac Barabum
- Triplito Tralaleritos
- Trulimero Trulicina
- W Or L
- Yess My Examen
- Zibra Zubra Zibralini

## Oro (17) — aus `BrainrotPack/Oro`
- Agarrini La Pallini
- Avocadini Guffo
- Ballerino Lololo
- Bambini Crostini
- Banana Dancana
- Bananini Kittini
- Bananita Dolphinita
- Blueberrinni Octopusini
- Brri Brri Bicus Dicus
- Burbaloni Luliloli
- Cachorrito Melonito
- Cacto Hipopotamo
- Chicleteira Bicicleteira
- Chicleteirina Bicicleteirina
- Chillin Chili
- Cocofanto Elefanto
- Noo My Examen

## Diamante (14) — aus `BrainrotPack/Diamante`
- Esok Sekolah
- Fluri Flura
- Job Job Job Sahur
- Lerulerulerule
- Madudung
- Matteo
- Nyannini Cattinali
- Pakrahmatmat
- Pakrahmatmatina
- Pot Hotspot
- Quesadilla Crocodila
- Smurfo Gatto
- Strawberrelli Flamingelli
- Ta Ta Ta Ta Sahur

## Arcoiris (12) — aus `BrainrotPack/Arcoiris`
- Gangster Footera
- Ganzanzelli Trulala
- Garamararam
- Gorillo Watermelondrillo
- Illuminato Triangolo
- Karkerkar Kurkur
- La Grande Combinasion
- Lionel Cactuseli
- Orangutini Ananassini
- Orcalero Orcala
- Pandaccini Bananini
- Rhino Toasterino

## Galaxia (10) — aus `BrainrotPack/Galaxia`
- Bobrito Bandito
- Cavallo Virtuoso
- Espresso Signora
- Frigo Camelo
- Girafa Celeste
- Glorbo Fruttodrillo
- Los Tralaleritos
- Odin Din Din Dun
- Trippi Troppi
- Trippi Troppi Troppa Trippa

## Hacker (8) — aus `BrainrotPack/Hacker`
- Bombombini Gusini
- Boneca Ambalabu
- Brr Brr Patapim
- Dragon Cannelloni
- La Vacca Saturno Saturnita
- Lirili Larila
- Meowl
- Tung Sahur

## Lava (6) — aus `BrainrotPack/Lava`
- Bombardiro Crocodilo
- Cappuccino Assassino
- Chimpanzini Bananini
- Strawberry Elephant
- Tralaledon
- Tralalero Tralala

## Glitchrot (3) — NICHT im Pack enthalten
- Glitchetto Lasagnoso
- Errore Cannolo
- Pixellino Ravioli

Diese 3 (und die 3 unten) sind unsere eigenen erfundenen Namen, kein Teil deines Packs — dafür bräuchtest du eigene/andere Modelle, oder sie bleiben einfach bei der Platzhalter-Kugel.

## Singularity (3) — NICHT im Pack enthalten
- Buconero Tortellini
- Infinito Panettone
- Vuoto Cosmico Espresso
