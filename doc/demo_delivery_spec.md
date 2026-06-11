# Demo-Lieferung fuer den Chip-RAM-Loader (Briefing an deft)

Context (English): This is the delivery contract for test round B of
doc/next_tests.md - running a self-contained oldskool demo on the Amiga
core without floppy emulation. The German text below is written to be
pasted 1:1 to the demo author (deft). The "Vertrag" section doubles as
the implementation spec for our launcher ROM + loader (to be coded in
the loader milestone - NOT yet implemented).

---

## Worum es geht

Wir bauen fuer den MEGA65-Amiga-Core einen "Demo-Loader": Er laedt ein
Speicherabbild von der SD-Karte direkt ins Chip-/Slow-RAM (ueber denselben
Upload-Pfad, den auf dem MiSTer der ARM benutzt) und springt dann ueber ein
Mini-"Kickstart" (unser eigenes Launcher-ROM anstelle von Kick 1.3) an einen
definierten Entry. Es gibt also KEIN Kickstart, kein exec, kein dos, kein
trackdisk - die Demo bekommt die nackte, frisch resettete Maschine plus
fertig befuellten Speicher.

Dein Instinkt ist genau richtig: Der Dump muss in dem Moment passieren, wo
dein Packer/Loader den Speicher fertig organisiert hat und BEVOR der
Hauptteil Hardware-Register anfasst. Die Hardware-Register muessen (und
koennen) nicht im Dump sein - unsere Umgebung liefert beim Entry einen
sauberen Reset-Zustand, und der Hauptteil initialisiert ja ohnehin alles
selbst.

## Die eine harte Bedingung

Der Entry muss ein klassischer "Takeover-Entry" sein (= der normale
Demo-Hauptteil-Einstieg):

- setzt seinen eigenen Stack (oder du sagst uns, welchen SP wir setzen
  sollen),
- macht seine komplette Hardware-Init selbst (DMACON/INTENA/Copper/
  Vektoren ... von Null weg),
- kehrt nie zurueck und ruft ab da nie mehr irgendetwas im ROM-Bereich
  auf (auch kein ExecBase ueber $4),
- laedt nichts mehr von Diskette nach - alles muss zum Dump-Zeitpunkt
  im RAM sein.

## Was wir beim Entry garantieren (der Vertrag)

- 68000, PAL, OCS (A500-Chipsatz), Supervisor-Modus, SR = $2700
  (alle Interrupts maskiert)
- Custom-Chips und CIAs im Reset-Zustand: DMACON = 0, INTENA = 0,
  INTREQ = 0, alle DMA aus
- OVL aus: Chip-RAM ab $000000 sichtbar - inklusive der Vektortabelle
  aus deinem Dump
- Speicher: $000000-$07FFFF = exakt dein chip.bin;
  $C00000-$C7FFFF = exakt dein slow.bin
- PC = dein Entry; SP = dein Wunschwert (Default $00080000 - sag
  Bescheid, falls dort Daten liegen; am robustesten: dein Code setzt
  den Stack selbst in den ersten Instruktionen); alle anderen Register
  = 0, ausser du brauchst etwas Bestimmtes
- Kein Floppy-Laufwerk; ROM-Bereich ($F80000+) enthaelt unseren
  Launcher, nicht Kickstart - ein Sprung dorthin ist ein Absturz

## Was du lieferst (3 Dinge)

1. **chip.bin** - exakt 524.288 Bytes = $000000-$07FFFF
2. **slow.bin** - exakt 524.288 Bytes = $C00000-$C7FFFF
   (falls genutzt; sonst einfach "ungenutzt" sagen)
3. **Kurze Notiz:**
   - Entry-Adresse (PC)
   - SP-Wert oder "setze ich selbst"
   - braucht irgendein Register beim Entry einen bestimmten Wert?
   - Bestaetigung: keine Disk-Zugriffe und keine ROM-/Kickstart-Aufrufe
     nach dem Entry; PAL; nur OCS-Register

## Zwei Wege, das zu erzeugen

### Weg A - WinUAE-Dump (dein Vorschlag)

1. WinUAE als A500 konfigurieren: OCS Agnus/Denise, 512K Chip +
   512K "Slow" (Trapdoor), Kickstart 1.3, PAL, 68000 cycle-exact.
2. Demo bis zu deinem "Packer fertig"-Moment laufen lassen. Am
   elegantesten: vor den finalen JMP in den Hauptteil eine
   Endlosschleife (bra.s *) einbauen - oder im Debugger einen
   Breakpoint setzen.
3. Shift+F12 oeffnet den WinUAE-Debugger ("h" zeigt alle Kommandos,
   "f <adresse>" setzt einen Breakpoint).
4. Speicher sichern (Zahlen sind hex):
   ```
   S chip.bin 0 80000
   S slow.bin c00000 80000
   ```
5. Entry-Adresse (das JMP-Ziel) und ggf. SP notieren. Fertig.

### Weg B - direkt aus deinem Build (oft sauberer)

Wenn dein Build-System die Speicherbelegung sowieso kennt
(Packer-/Linker-Map), gib uns einfach die fertigen Segmente +
Ladeadressen + Entry ("Datei X nach $400, Datei Y nach $20000, Teil Z
nach $C00000, Entry $20000"). Dann braucht es gar keinen Dump - wir
setzen das Image selbst zusammen. Das Containerformat definieren wir;
du musst nichts paketieren.

## K.O.-Fragen vorab (eine Minute Nachdenken spart Wochen)

1. Laedt die Demo nach dem Moment noch von Diskette nach
   (Multi-Part-Trackmo)? Dann warten wir besser auf den
   Floppy-Milestone (der kommt auch noch).
2. Ruft sie nach dem Entry noch irgendetwas im Kickstart auf?
3. Reichen wirklich 512K Chip + 512K Slow? (Du sagtest ja.)
4. Nur OCS-Register? (Der Core ist OCS - ECS/AGA-Register gibt es
   nicht.)
5. Reagiert die Demo auf Tastatur/Maus/Joystick? (Funktioniert alles -
   nur gut zu wissen fuer den Test.)

Der erste Wurf muss nicht perfekt sein - Dump + Notiz reicht, wir
iterieren zusammen auf der echten Hardware.

---

## Loader-side notes (English, for the implementation milestone)

The "Vertrag" above is the launcher contract to implement:
entry via our 256KB launcher ROM (replaces kick.rom): disable OVL
(CIA-A PRA bit 0), optionally set SSP, fetch entry/SP from the upload
engine's mailbox, JMP. Upload path: OSM manual-load item -> QNICE
streams chip.bin/slow.bin -> CDC FIFO -> upload engine drives userio
cmd 0xF1 (cpuhlt+cpurst) + 0xF0 (mem_write) onto the chipset bus, then
releases the CPU into the launcher. Custom/CIA reset state comes free
from the system reset that accompanies the upload. See
doc/next_tests.md round B for the full mechanics sketch.
