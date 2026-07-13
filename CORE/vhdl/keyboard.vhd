---------------------------------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Amiga 500 (AExp) keyboard controller:
-- Translate MEGA65 keystrokes into raw Amiga keycode events for Minimig's CIA-A
--
-- Runs in the clock domain of the core (clk_main = 28.375 MHz).
--
-- MiSTer2MEGA65 (AExp Amiga 500 port), June 2026: Rewritten from the M2M template keyboard.vhd.
-- On MiSTer, the HPS (Linux side) translates USB keyboards into raw Amiga keycodes and delivers
-- them via hps_ext.v (command UIO_KEYBOARD = 'h05) as:
--    kbd_mouse_data[7:0] : bits 6:0 = raw Amiga keycode, bit 7 = 0:key pressed ("make"),
--                                                                1:key released ("break")
--    kbd_mouse_type[1:0] : 2 = keyboard event (0/1 = mouse deltas, 3 = OSD key - both unused here:
--                          mouse is a later milestone, the M2M framework has its own OSD)
--    kms_level           : toggles once per event (level change = strobe)
-- The only consumer of type-2 events inside rtl/minimig.v is CIA-A (rtl/ciaa.v): whenever it sees
-- kms_level change while kbd_mouse_type = 2 (sampled with clk7n_en, i.e. every 4 clk28 cycles),
-- it latches ~{kbd_mouse_data[6:0], kbd_mouse_data[7]} into its serial data register SDR and
-- raises the SP (serial port) interrupt - the rotate-left-by-one plus inversion mimics exactly
-- the data frame that a real Amiga keyboard shifts out on the KDAT line (keycode bits 6..0 first,
-- up/down flag last, everything active low). rtl/userio.v does NOT snoop keyboard events (it only
-- consumes mouse types 0/1), and kbd_mouse_type = 3 is only used by MiSTer's top level Minimig.sv,
-- which is not compiled in this port. Hence this module replaces the HPS entirely by translating
-- the MEGA65 keyboard scan into the very same kbd_mouse_data/kbd_mouse_type/kms_level protocol.
--
-- This is how MiSTer2MEGA65 provides access to the MEGA65 keyboard:
-- kb_key_num_i is running through the key numbers 0 to 79 with a frequency of 1 kHz, i.e. the whole
-- keyboard is scanned 1000 times per second. kb_key_pressed_n_i is already debounced and signals
-- low active, if a certain key is being pressed right now.
--
-- Behavior of this module: We mirror the state of all 80 MEGA65 keys in a register. As soon as the
-- scanner reports a state that differs from the mirror (i.e. exactly one event per press edge and
-- one per release edge), the key is RESOLVED (see below) into an Amiga keycode plus the Amiga-side
-- modifier state it needs, and - if it maps to an Amiga key - an event is pushed into a small FIFO.
-- The FIFO is drained with send-then-wait-for-acknowledge FLOW CONTROL, exactly as a real Amiga
-- keyboard blocks on the CPU handshake before shifting out the next code: a code goes on
-- kbd_mouse_data_o (bit 7 = release flag) with a kms_level_o toggle, and the NEXT code is held back
-- until a minimum 1 ms gap has elapsed AND the Amiga has consumed the current code - signalled by
-- kbd_ack_i, a CPU read of the keycode SDR ($BFEC01) - or a ~143 ms deadlock timeout fires. This
-- never overwrites the single-byte CIA-A SDR before the reader has taken the previous code, for ANY
-- reader speed: a fast reader (Kickstart's interrupt-driven keyboard.device) still paces at the 1 ms
-- floor, a slow raw-CIA reader (e.g. VATestprogram's keyboard test) is paced at its own read rate,
-- and a non-reading consumer is released by the timeout. See the "Pacing" constants and the pacer
-- process below. After reset the first event is additionally held back for 100 ms, because
-- minimig_syscontrol.v stretches the internal reset by 4 frames (~80 ms PAL).
--
-- =====================================================================================================
-- TWO KEYBOARD MAPPING MODES (issue #6), selected by keyboard_mode_i (an OSM radio, static):
--
--   keyboard_mode_i = '0' : MEGA65 mode (default) - SEMANTIC, "the cap is law". You get exactly the
--                           character printed on the MEGA65 keycap in all THREE positions: unshifted
--                           (primary), Shift+key (upper legend) and MEGA(C=)+key (the front-face
--                           ASCII symbols ~ | \ { } _ ` printed on the caps). The Amiga's own keymap
--                           differs (its Shift+2 is '@' not '"', and it has no MEGA-symbol layer), so
--                           the core redirects keycodes and synthesizes/suppresses the Amiga-side
--                           Shift and Left-Amiga modifiers to land the printed character.
--   keyboard_mode_i = '1' : Amiga mode - PURE POSITIONAL. Each MEGA65 key sends the raw Amiga keycode
--                           of the key in the geometrically-corresponding slot (deft's "custom caps"
--                           layout); Shift passes through 1:1 (so Shift+2 = '@' etc., the Amiga-native
--                           symbols). No semantic remap, no MEGA-symbol layer, MEGA = Left-Amiga.
--
-- Mode-independent behaviour (warm boot, the right-mouse-button substitute, keyboard pacing) stays
-- active in BOTH modes. The Shift+F1..F9 -> F2..F10 substitution is MEGA65-mode-only now: Amiga mode
-- gives every Amiga F-key (F1..F10) its own MEGA65 key via the top-row remap below, so it needs no
-- Shift trick. The right-mouse-button substitute uses a different source key per mode (see its note).
--
-- Amiga-mode positional keymap (C_KEYMAP_AMIGA) - each MEGA65 key sends the raw Amiga keycode of the
-- key in the geometrically-corresponding slot of deft's "custom caps" A600 layout. Two groups differ
-- from the MEGA65-mode base keymap (C_KEYMAP_MEGA65):
--
--   (a) THE TOP FUNCTION-KEY ROW maps positionally onto the Amiga's Esc + F1..F10 row. The MEGA65 row
--       is longer (five extra keys left of F1), so those extras fill in Esc/F1..F4 and the printed
--       F-keys slide right by two:
--         MEGA65 : RUN/STOP  ESC  ALT  CAPSLOCK  NOSCRL | F1  F3  F5  F7  F9  F11 | ... HELP  F13
--         Amiga  : Esc       F1   F2   F3        F4     | F5  F6  F7  F8  F9  F10 | ... Help  L.Alt
--       so RUN/STOP=Esc $45, ESC=F1 $50, ALT=F2 $51, CAPSLOCK=F3 $52, NOSCRL=F4 $53, F1=F5 $54,
--       F3=F6 $55, F5=F7 $56, F7=F8 $57, F9=F9 $58, F11=F10 $59, HELP=Help $5F, F13=Left Alt $64.
--       CAPS LOCK -> F3 is taken from the CPLD's MOMENTARY caps key (matrix 78, m65_capslock_mom) so
--       F3 is a normal momentary key; the latched caps LEVEL (key 72) is left unmapped in this mode.
--
--   (b) THE PUNCTUATION / MODIFIER cells that follow the Amiga's own labelling rather than the MEGA65's:
--         #  MEGA65 key      Amiga key (code)           MEGA65-mode base (for reference)
--          0 INS/DEL         Del          ($46)         Backspace ($41)
--         40 + (plus)        - _  ($0B, Amiga '-' key)  Keypad +  ($5E)
--         43 - (minus)       = +  ($0C, Amiga '=' key)  -         ($0B)
--         49 * (asterisk)    ] }  ($1B, Amiga ']' key)  Keypad *  ($5D)
--         51 CLR/HOME        Backspace    ($41)         Del       ($46)
--         53 = (equal)       Right Amiga  ($67)         =         ($0C)
--         54 ARROW UP (sym)  - unmapped - (right mouse) ] }      ($1B)
--         75 RESTORE         Right Alt    ($65)         Right Amiga ($67)
--
-- All other cells are shared with C_KEYMAP_MEGA65: digits $01..$0A, letters (Q-row $10.., A-row
-- $20.., Z-row $31..), Return $44, Space $40, cursor keys $4C..$4F, TAB $42, CTRL $63, L/R Shift
-- $60/$61, MEGA=Left Amiga $66, the ,./ cluster $38/$39/$3A, the : ; @ cluster $29/$2A/$1A, GBP=\ $0D.
--
-- Two Amiga functions have NO home in Amiga mode, both from MEGA65 keyboard-hardware limits (not a
-- choice - see the deep notes in doc/keyboard.md):
--   * Amiga CAPS LOCK ($62): the top-row CAPS LOCK key is F3 here, and the home-row SHIFT LOCK key -
--     which sits exactly where the Amiga's Caps Lock is - is merged by the keyboard CPLD with the
--     Z-row LEFT SHIFT into ONE matrix key (15); the raw shift-lock is never transmitted, so it cannot
--     drive Caps Lock without also turning LEFT SHIFT into Caps Lock. Engaging SHIFT LOCK therefore
--     just holds Amiga Left Shift (a shift-lock). Amiga Caps Lock stays reachable in MEGA65 mode.
--   * F11/F13 leak an Amiga keycode here (F10 / Left Alt), so - unlike MEGA65 mode - they are no
--     longer "clean" OSM-open keys; opening the menu with one also sends its keycode (accepted).
--
-- MEGA65-mode SEMANTIC resolution (function resolve() below) - the cap character per legend:
--   symbol keys (all three legends):
--     key   unshifted        Shift+key         MEGA(C=)+key
--     ----  ---------------  ----------------  -----------------
--     <-    _  = Sh+$0B      `  = $00          `  = $00
--     ,     ,  = $38         <  = Sh+$38       ~  = Sh+$00
--     .     .  = $39         >  = Sh+$39       |  = Sh+$0D
--     /     /  = $3A         ?  = Sh+$3A       \  = $0D
--     :     :  = Sh+$29      [  = $1A          {  = Sh+$1A
--     ;     ;  = $29         ]  = $1B          }  = Sh+$1B
--     =     =  = $0C         _  = Sh+$0B       _  = Sh+$0B
--     @     @  = Sh+$02      (graphic, none)   (@ is not a MEGA-symbol key -> MEGA = Left-Amiga)
--     *     *  = $5D (kp)    (graphic, none)   (not a MEGA-symbol key)
--     ^     ^  = Sh+$06      (Pi, none)        (not a MEGA-symbol key)
--   number row - unshifted is the digit ($01..$0A); Shift gives the printed cap symbol, which
--   differs from the Amiga's on five keys (2 " , 6 & , 7 ' , 8 ( , 9 ) ):
--     Shift+2 -> " = Sh+$2A     Shift+7 -> ' = $2A (shift DROPPED)
--     Shift+6 -> & = Sh+$07     Shift+8 -> ( = Sh+$09     Shift+9 -> ) = Sh+$0A
--     Shift+1/3/4/5 = ! # $ % already match the Amiga; Shift+0 has no cap symbol -> nothing.
--   Kept creative (both the printed cap and sy2002's choices): <- primary '_', ^ primary '^',
--   GBP -> '\' ($0D), INS/DEL -> Backspace, CLR/HOME -> Del, keypad + and *.
--   The four graphic-only shifted caps (Shift+@ / Shift+* / Shift+^ / Shift+0) have no Amiga
--   character and send nothing.
--
-- MEGA (C=) key - dual role in MEGA65 mode (function of the co-pressed key):
--   * MEGA + a front-face symbol key (<- , . / : ; =) -> the printed front-face symbol above;
--     Left-Amiga is NOT sent for that combo (the symbol key transiently suppresses it).
--   * MEGA + anything else (letters, digits, ...) -> Left-Amiga + that key (so LAmiga+N/M screen
--     depth and Intuition menu shortcuts survive).
--   * MEGA tapped alone -> Left-Amiga (make on release-with-no-cokey, then break = a clean tap).
--   Implementation: MEGA make is DEFERRED (no $66 emitted yet); the first non-symbol co-key engages
--   Left-Amiga ($66 make queued before that key's make); a symbol co-key marks the hold as "used as
--   symbol modifier" so releasing MEGA does not tap. In Amiga mode MEGA is a plain $66 key (immediate
--   make/break, no deferral, no symbol layer).
--
-- THE TRANSLATION ENGINE (per-key, transient - the correction the adversarial review of the spec
-- demanded over a whole-shift-hold latch):
--   resolve(key, shift, mega, mode) yields, at the MAKE edge, an Amiga chord = (keycode, valid,
--   f1, f0, is_sym):
--     * f1 : while this key is held, the Amiga-side Shift must read ASSERTED (target needs Shift but
--            the user is not holding it - e.g. ':' -> ':' = Sh+$29, or ~ = Sh+$00).
--     * f0 : while this key is held, the Amiga-side Shift must read RELEASED (target must have no
--            Shift but the user IS holding it - e.g. Shift+: -> '[' = $1A, Shift+7 -> ''' = $2A, and
--            a substituted Shift+F1 -> F2).
--     * is_sym : a MEGA65-mode front-face symbol key (drives the MEGA/Left-Amiga handling above).
--   The chord is LATCHED per key at the make edge (key_code/key_valid/key_f1/key_f0/key_sla), so the
--   matching break uses the exact same keycode and a later Shift change while the key is held does
--   NOT retro-change the character (matches real hardware "resolve once, at the make edge").
--   The Amiga-side Shift (shift_l_sent/shift_r_sent) and Left-Amiga (la_sent) are each driven by a
--   small CONVERGENCE block towards a desired state computed from the currently-held keys' latched
--   requirements PLUS the one make edge that is still waiting for its modifiers (wait_*). Because
--   these codes are queued into the same FIFO, ordering is exact: the Shift make/break and the
--   Left-Amiga make/break land before the keycode make (the make is held back - mirror not updated,
--   retried on the next 1 kHz sweep - until its required modifier state is reached) and the keycode
--   break lands before the modifiers converge back to the physically-held state. The suppression is
--   thus SCOPED to the override key being held (v_any_f0/f1/sla is an OR over held keys, gated per
--   key), so inline shifted punctuation stays correct: holding Shift to type "[HELLO]" retracts Shift
--   only around the '[' and ']' keycodes and restores it for H E L L O. The keyboard handshake
--   (kbd_ack_i) delivers every one of these codes reliably, so a raw CIA reader sees each of them.
--   (Pathological multi-override gestures - e.g. holding one symbol key that forces Shift up while
--   pressing another that forces it down - are not real typing; they resolve serially and self-heal
--   when the conflicting key is released, delaying only that one key, never freezing the keyboard.)
--
-- SHIFTED F-KEYS (F1/F3/F5/F7/F9 + Shift -> F2/F4/F6/F8/F10, MEGA65 MODE ONLY): unified into the engine
-- above. Shift+F1 resolves to code $51 (base+1) with f0='1' (the Amiga must not see Shift together
-- with the substituted F-key). The Shift is retracted before the F2 make and re-made after the F2
-- break iff still physically held - all reliably delivered by the handshake, so raw CIA readers see
-- clean isolated make/break pairs with no stuck F-key and no hanging Shift. Shift+F2 (etc.) cannot
-- be typed (the Shift is consumed by the substitution); the Shift must lead the F-key by at least one
-- scan sweep (~1 ms); F11/F13 are unmapped in MEGA65 mode (Amiga F10 = Shift+F9). In AMIGA mode this
-- whole substitution is SKIPPED: the top-row remap gives every F-key its own MEGA65 key (F11=F10,
-- F13=Left Alt), so Shift passes straight through the F-keys there.
--
-- WARM BOOT (July 2026): Ctrl+LAmiga+RAmiga = CTRL+MEGA+RESTORE is detected here by MIRROR state and
-- pulses core_reset_o (one shot; re-armed only after the combo has been released for several scan
-- sweeps). It reads the physical mirror, so it fires in BOTH modes even though RESTORE maps
-- differently. main.vhd ORs this into amiga_rst (CPU+chipset reset, memories kept - the real
-- keyboard MCU's reset line). The FSM deliberately survives reset_i (it is the source of that reset).
-- Keys still held after the boot are re-delivered as plain make codes once the 100 ms holdoff
-- expires; Kickstart ignores them.
--
-- RIGHT MOUSE BUTTON substitute (July 2026): a held key is exported as a level on mouse_rmb_o; main.vhd
-- ORs it into Minimig's mouse_btn(1). The SOURCE key is mode-dependent: RUN/STOP (key 63) in MEGA65
-- mode, but the ARROW-UP symbol key (key 54, left of RESTORE) in Amiga mode - where RUN/STOP is
-- repurposed as Esc. In each mode the chosen key has no Amiga keycode (mirror-only), so the substitute
-- cannot interfere with the keycode stream. On a real Amiga the mouse right button shorts DB9 pin 9
-- (POTX) to GND while PAULA drives the pot lines high - the MEGA65's paddle circuit can only drain the
-- line, so a GND-shorting button is electrically invisible to it (verified with two Amiga tank mice on
-- real R3 hardware, 2026-07-03).
--
-- Known limitations (by design): Amiga keys with no MEGA65 counterpart cannot be typed (in MEGA65
-- mode: Right Alt, the numeric pad except the borrowed '+'/'*', the international keys $2B/$30).
--
-- CAPS LOCK: the MEGA65 keyboard CPLD exposes this key TWO ways - a LATCHED lock LEVEL at key 72
-- (m65_capslock) and a RAW MOMENTARY press at key 78 (m65_capslock_mom). In MEGA65 mode key 72 -> Amiga
-- Caps Lock $62: a real Amiga keyboard sends a single make $62 when the lock turns ON and a single break
-- $E2 when it turns OFF - nothing while held, and the CPLD's latched level reproduces that exactly
-- through the generic edge-to-make/break translation (no special casing). In Amiga mode key 72 is
-- unused and key 78 -> F3, so F3 is an ordinary momentary key (press = make, release = break).
-- NOTE: the keycap's lock latch AND its LED are owned by the keyboard CPLD (LED_CAPS <= caps_lock,
-- with no path from the main-FPGA serial stream - it carries only the 4 RGB power/drive LEDs), so
-- pressing CAPS LOCK for F3 still flips the LED on/off. The core cannot suppress it: it is a keyboard-
-- CPLD-firmware limit, unreachable by the core or by any M2M change.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity keyboard is
   port (
      clk_main_i           : in  std_logic;                  -- core clock (28.375 MHz)
      reset_i              : in  std_logic;                  -- active high reset

      -- Interface to the MEGA65 keyboard
      kb_key_num_i         : in  integer range 0 to 79;      -- cycles through all MEGA65 keys
      kb_key_pressed_n_i   : in  std_logic;                  -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- Keyboard mapping mode (issue #6): '1' = Amiga (pure positional), '0' = MEGA65 (semantic,
      -- default). A static OSM radio bit, already in this (core) clock domain - used directly.
      keyboard_mode_i      : in  std_logic;

      -- Interface to Minimig (rtl/minimig.v, consumed by rtl/ciaa.v):
      -- raw Amiga keycode events, see protocol description in the header of this file
      kbd_mouse_data_o     : out std_logic_vector(7 downto 0); -- bits 6:0 keycode, bit 7 = 1: release
      kbd_mouse_type_o     : out std_logic_vector(1 downto 0); -- constant 2 = keyboard event
      kms_level_o          : out std_logic;                    -- toggles once per event

      -- Flow-control back-channel from CIA-A (rtl/ciaa.v via minimig/minimig_m65): HIGH while
      -- the Amiga reads the keycode SDR ($BFEC01) = "this code has been consumed". The pacer
      -- waits for this before sending the next code - the real keyboard-to-CIA handshake. It is
      -- a LEVEL held for the whole multi-cycle read, so it must be rising-edge-detected (see the
      -- flow-control note in the header and the pacer process below).
      kbd_ack_i            : in  std_logic;

      -- CTRL+MEGA+RESTORE = Ctrl+LAmiga+RAmiga warm boot (one-shot pulse, see header)
      core_reset_o         : out std_logic;

      -- RUN/STOP held = Amiga right mouse button substitute (level, active high, see header)
      mouse_rmb_o          : out std_logic
   );
end entity keyboard;

architecture beh of keyboard is

-- MEGA65 key codes that kb_key_num_i is using while
-- kb_key_pressed_n_i is signalling (low active) which key is pressed
constant m65_ins_del       : integer := 0;
constant m65_return        : integer := 1;
constant m65_horz_crsr     : integer := 2;   -- means cursor right in C64 terminology
constant m65_f7            : integer := 3;
constant m65_f1            : integer := 4;
constant m65_f3            : integer := 5;
constant m65_f5            : integer := 6;
constant m65_vert_crsr     : integer := 7;   -- means cursor down in C64 terminology
constant m65_3             : integer := 8;
constant m65_w             : integer := 9;
constant m65_a             : integer := 10;
constant m65_4             : integer := 11;
constant m65_z             : integer := 12;
constant m65_s             : integer := 13;
constant m65_e             : integer := 14;
constant m65_left_shift    : integer := 15;
constant m65_5             : integer := 16;
constant m65_r             : integer := 17;
constant m65_d             : integer := 18;
constant m65_6             : integer := 19;
constant m65_c             : integer := 20;
constant m65_f             : integer := 21;
constant m65_t             : integer := 22;
constant m65_x             : integer := 23;
constant m65_7             : integer := 24;
constant m65_y             : integer := 25;
constant m65_g             : integer := 26;
constant m65_8             : integer := 27;
constant m65_b             : integer := 28;
constant m65_h             : integer := 29;
constant m65_u             : integer := 30;
constant m65_v             : integer := 31;
constant m65_9             : integer := 32;
constant m65_i             : integer := 33;
constant m65_j             : integer := 34;
constant m65_0             : integer := 35;
constant m65_m             : integer := 36;
constant m65_k             : integer := 37;
constant m65_o             : integer := 38;
constant m65_n             : integer := 39;
constant m65_plus          : integer := 40;
constant m65_p             : integer := 41;
constant m65_l             : integer := 42;
constant m65_minus         : integer := 43;
constant m65_dot           : integer := 44;
constant m65_colon         : integer := 45;
constant m65_at            : integer := 46;
constant m65_comma         : integer := 47;
constant m65_gbp           : integer := 48;
constant m65_asterisk      : integer := 49;
constant m65_semicolon     : integer := 50;
constant m65_clr_home      : integer := 51;
constant m65_right_shift   : integer := 52;
constant m65_equal         : integer := 53;
constant m65_arrow_up      : integer := 54;  -- symbol, not cursor
constant m65_slash         : integer := 55;
constant m65_1             : integer := 56;
constant m65_arrow_left    : integer := 57;  -- symbol, not cursor
constant m65_ctrl          : integer := 58;
constant m65_2             : integer := 59;
constant m65_space         : integer := 60;
constant m65_mega          : integer := 61;
constant m65_q             : integer := 62;
constant m65_run_stop      : integer := 63;
constant m65_no_scrl       : integer := 64;
constant m65_tab           : integer := 65;
constant m65_alt           : integer := 66;
constant m65_help          : integer := 67;
constant m65_f9            : integer := 68;
constant m65_f11           : integer := 69;
constant m65_f13           : integer := 70;
constant m65_esc           : integer := 71;
constant m65_capslock      : integer := 72;
constant m65_up_crsr       : integer := 73;  -- cursor up
constant m65_left_crsr     : integer := 74;  -- cursor left
constant m65_restore       : integer := 75;
-- The MEGA65 keyboard CPLD exposes the CAPS LOCK key TWICE in the scan matrix: as the LATCHED
-- lock LEVEL at key 72 (m65_capslock - flips per press and holds; this is what drives the keycap
-- LED, which the keyboard CPLD owns and the core cannot suppress), and as the RAW MOMENTARY press
-- at key 78 (SCAN_IN(0), asserted only while the key is physically down - the CPLD forwards it so
-- the MEGA65 can gate its 40 MHz "turbo" on "caps held"). Amiga mode drives F3 from the MOMENTARY
-- one, so the top-row CAPS LOCK key behaves like an ordinary function key (press = make, release =
-- break) independently of the lock latch. Both matrix bits ride the standard 0..79 scan into m2m_keyb.
constant m65_capslock_mom  : integer := 78;

-- Marker for MEGA65 keys that have no Amiga counterpart. All valid raw Amiga keycodes are
-- <= $67, i.e. bit 7 of a valid table entry is always 0 and bits 6:0 carry the keycode.
constant C_NO_KEY : std_logic_vector(7 downto 0) := x"FF";

-- MEGA65 key number -> raw Amiga keycode. Two tables (see the header):
--   C_KEYMAP_MEGA65 : the base for MEGA65 (semantic) mode. The symbol keys and the five differing
--                     number-row keys are OVERRIDDEN by resolve() below (their entries here are the
--                     positional fallbacks and are only reached for keys resolve() does not special-
--                     case). F1..F9 base codes ($50..$58) are read from here for the MEGA65-mode
--                     Shift+F substitution.
--   C_KEYMAP_AMIGA  : the pure positional (Amiga) mode. It shares most cells with C_KEYMAP_MEGA65 but
--                     remaps the whole top function-key row onto the Amiga's Esc + F1..F10 (plus the
--                     punctuation/modifier cells listed in the header). Used verbatim (Shift passes
--                     through 1:1); the Shift+F substitution does NOT apply in this mode.
type t_keymap is array(0 to 79) of std_logic_vector(7 downto 0);

constant C_KEYMAP_MEGA65 : t_keymap := (
   m65_ins_del       => x"41",   -- Backspace
   m65_return        => x"44",   -- Return
   m65_horz_crsr     => x"4E",   -- Cursor Right
   m65_f7            => x"56",   -- F7
   m65_f1            => x"50",   -- F1
   m65_f3            => x"52",   -- F3
   m65_f5            => x"54",   -- F5
   m65_vert_crsr     => x"4D",   -- Cursor Down
   m65_3             => x"03",   -- 3
   m65_w             => x"11",   -- W
   m65_a             => x"20",   -- A
   m65_4             => x"04",   -- 4
   m65_z             => x"31",   -- Z
   m65_s             => x"21",   -- S
   m65_e             => x"12",   -- E
   m65_left_shift    => x"60",   -- Left Shift
   m65_5             => x"05",   -- 5
   m65_r             => x"13",   -- R
   m65_d             => x"22",   -- D
   m65_6             => x"06",   -- 6
   m65_c             => x"33",   -- C
   m65_f             => x"23",   -- F
   m65_t             => x"14",   -- T
   m65_x             => x"32",   -- X
   m65_7             => x"07",   -- 7
   m65_y             => x"15",   -- Y
   m65_g             => x"24",   -- G
   m65_8             => x"08",   -- 8
   m65_b             => x"35",   -- B
   m65_h             => x"25",   -- H
   m65_u             => x"16",   -- U
   m65_v             => x"34",   -- V
   m65_9             => x"09",   -- 9
   m65_i             => x"17",   -- I
   m65_j             => x"26",   -- J
   m65_0             => x"0A",   -- 0
   m65_m             => x"37",   -- M
   m65_k             => x"27",   -- K
   m65_o             => x"18",   -- O
   m65_n             => x"36",   -- N
   m65_plus          => x"5E",   -- Keypad +
   m65_p             => x"19",   -- P
   m65_l             => x"28",   -- L
   m65_minus         => x"0B",   -- -
   m65_dot           => x"39",   -- .   (resolve(): . / > / |)
   m65_colon         => x"29",   -- (resolve(): : / [ / {)
   m65_at            => x"1A",   -- (resolve(): @ / - / -)
   m65_comma         => x"38",   -- ,   (resolve(): , / < / ~)
   m65_gbp           => x"0D",   -- \ |
   m65_asterisk      => x"5D",   -- Keypad *
   m65_semicolon     => x"2A",   -- (resolve(): ; / ] / })
   m65_clr_home      => x"46",   -- Del
   m65_right_shift   => x"61",   -- Right Shift
   m65_equal         => x"0C",   -- =   (resolve(): = / _ / _)
   m65_arrow_up      => x"1B",   -- (resolve(): ^ / - / -)
   m65_slash         => x"3A",   -- /   (resolve(): / / ? / \)
   m65_1             => x"01",   -- 1
   m65_arrow_left    => x"00",   -- (resolve(): _ / ` / `)
   m65_ctrl          => x"63",   -- Control
   m65_2             => x"02",   -- 2   (resolve(): 2 / ")
   m65_space         => x"40",   -- Space
   m65_mega          => x"66",   -- Left Amiga
   m65_q             => x"10",   -- Q
   m65_tab           => x"42",   -- Tab
   m65_alt           => x"64",   -- Left Alt
   m65_help          => x"5F",   -- Help
   m65_f9            => x"58",   -- F9
   -- F11 and F13 are intentionally unmapped: they fall to C_NO_KEY below and do
   -- nothing on the Amiga. Amiga F10 is reached via Shift+F9 (see header).
   m65_esc           => x"45",   -- Esc
   m65_capslock      => x"62",   -- Caps Lock (lock-state semantics, see header)
   m65_up_crsr       => x"4C",   -- Cursor Up
   m65_left_crsr     => x"4F",   -- Cursor Left
   m65_restore       => x"67",   -- Right Amiga
   others            => C_NO_KEY -- RUN/STOP, NO SCRL, F11, F13 and keys 76..79: unmapped
);

constant C_KEYMAP_AMIGA : t_keymap := (
   -- === the MEGA65 top row maps POSITIONALLY onto the Amiga Esc + F1..F10 row ===
   -- The MEGA65 function row is longer than the Amiga's (five extra keys sit to the left of F1),
   -- so those extras fill in Esc/F1..F4 and the printed F-keys slide right by two:
   --   MEGA65 : RUN/STOP  ESC  ALT  CAPSLOCK  NOSCRL | F1  F3  F5  F7  F9  F11 | ... HELP  F13
   --   Amiga  : Esc       F1   F2   F3        F4     | F5  F6  F7  F8  F9  F10 | ... Help  L.Alt
   m65_run_stop      => x"45",   -- Esc  (the right-mouse-button substitute moves to ARROW-UP, below)
   m65_esc           => x"50",   -- F1
   m65_alt           => x"51",   -- F2
   m65_capslock_mom  => x"52",   -- F3   (the top-row CAPS LOCK key, taken from the CPLD's MOMENTARY
                                 --        caps matrix key 78 so F3 is a normal momentary key; the
                                 --        LATCHED level at key 72 is left unmapped below, see header)
   m65_no_scrl       => x"53",   -- F4
   m65_f1            => x"54",   -- F5
   m65_f3            => x"55",   -- F6
   m65_f5            => x"56",   -- F7
   m65_f7            => x"57",   -- F8
   m65_f9            => x"58",   -- F9
   m65_f11           => x"59",   -- F10
   m65_help          => x"5F",   -- Help
   m65_f13           => x"64",   -- Left Alt

   -- === positional punctuation / modifiers that differ from the MEGA65 base keymap ===
   m65_ins_del       => x"46",   -- Del
   m65_plus          => x"0B",   -- Amiga '-' key (- _)
   m65_minus         => x"0C",   -- Amiga '=' key (= +)
   m65_asterisk      => x"1B",   -- Amiga ']' key (] })
   m65_clr_home      => x"41",   -- Backspace
   m65_equal         => x"67",   -- Right Amiga
   m65_arrow_up      => C_NO_KEY,-- no Amiga keycode; used as the right-mouse-button substitute
   m65_restore       => x"65",   -- Right Alt (image "ALT")
   m65_capslock      => C_NO_KEY,-- the LATCHED caps LEVEL (key 72) is unused in Amiga mode; F3 comes
                                 --   from the momentary caps key (m65_capslock_mom) above. The home-
                                 --   row SHIFT LOCK cannot be Amiga Caps Lock: the CPLD merges it with
                                 --   LEFT SHIFT into key 15, so Amiga Caps Lock is a MEGA65-mode-only
                                 --   function here (via key 72). See the header.

   -- === shared cells (identical to C_KEYMAP_MEGA65) ===
   m65_return        => x"44",
   m65_horz_crsr     => x"4E",
   m65_vert_crsr     => x"4D",
   m65_3             => x"03",
   m65_w             => x"11",
   m65_a             => x"20",
   m65_4             => x"04",
   m65_z             => x"31",
   m65_s             => x"21",
   m65_e             => x"12",
   m65_left_shift    => x"60",
   m65_5             => x"05",
   m65_r             => x"13",
   m65_d             => x"22",
   m65_6             => x"06",
   m65_c             => x"33",
   m65_f             => x"23",
   m65_t             => x"14",
   m65_x             => x"32",
   m65_7             => x"07",
   m65_y             => x"15",
   m65_g             => x"24",
   m65_8             => x"08",
   m65_b             => x"35",
   m65_h             => x"25",
   m65_u             => x"16",
   m65_v             => x"34",
   m65_9             => x"09",
   m65_i             => x"17",
   m65_j             => x"26",
   m65_0             => x"0A",
   m65_m             => x"37",
   m65_k             => x"27",
   m65_o             => x"18",
   m65_n             => x"36",
   m65_p             => x"19",
   m65_l             => x"28",
   m65_dot           => x"39",
   m65_colon         => x"29",   -- ; :  (Amiga ';' key)
   m65_at            => x"1A",   -- [ {  (Amiga '[' key)
   m65_comma         => x"38",
   m65_gbp           => x"0D",
   m65_semicolon     => x"2A",   -- ' "  (Amiga ''' key)
   m65_right_shift   => x"61",
   m65_slash         => x"3A",
   m65_1             => x"01",
   m65_arrow_left    => x"00",   -- ` ~
   m65_ctrl          => x"63",
   m65_2             => x"02",
   m65_space         => x"40",
   m65_mega          => x"66",   -- Left Amiga
   m65_q             => x"10",
   m65_tab           => x"42",
   m65_up_crsr       => x"4C",
   m65_left_crsr     => x"4F",
   others            => C_NO_KEY
);

-- The five MEGA65 F-keys whose SHIFTED variant exists on the Amiga (F2/F4/F6/F8/F10).
-- All Amiga F-key codes are $50..$59 with even base codes: shifted variant = base+1.
pure function f_shiftable_fkey(n : integer) return boolean is
begin
   return n = m65_f1 or n = m65_f3 or n = m65_f5 or n = m65_f7 or n = m65_f9;
end function f_shiftable_fkey;

-- Result of resolving one MEGA65 key edge into an Amiga chord (see the header). code/valid carry the
-- keycode; f1/f0 are the Amiga-side Shift requirement WHILE this key is held (force asserted /
-- force released; both '0' = pass the physical Shift through); is_sym marks a MEGA65-mode front-face
-- symbol key (drives the MEGA/Left-Amiga handling).
type t_resolved is record
   code   : std_logic_vector(6 downto 0);
   valid  : std_logic;
   f1     : std_logic;
   f0     : std_logic;
   is_sym : std_logic;
end record;

pure function resolve(key : integer; sh : std_logic; mg : std_logic; amiga_mode : std_logic)
   return t_resolved is
   variable r    : t_resolved;
   variable base : std_logic_vector(7 downto 0);
begin
   r.code   := (others => '0');
   r.valid  := '0';
   r.f1     := '0';
   r.f0     := '0';
   r.is_sym := '0';

   -- Amiga mode: PURE positional, Shift passes through 1:1. In this mode the whole MEGA65 top row
   -- (RUN/STOP, ESC, ALT, CAPS LOCK, NO SCROLL, F1, F3, F5, F7, F9, F11) maps directly onto the
   -- Amiga's Esc + F1..F10, so EVERY Amiga F-key has its own MEGA65 key. The Shift+F substitution
   -- below is therefore NOT applied here - it is a MEGA65-mode-only trick for reaching the even
   -- F-keys (F2/F4/F6/F8/F10) that MEGA65 mode has no dedicated cap for.
   if amiga_mode = '1' then
      base := C_KEYMAP_AMIGA(key);
      if base /= C_NO_KEY then
         r.valid := '1';
         r.code  := base(6 downto 0);
      end if;
      return r;
   end if;

   -- MEGA65 mode only: Shift+F1/F3/F5/F7/F9 -> F2/F4/F6/F8/F10 = base+1, with the Amiga Shift
   -- dropped (f0). The base codes are read from the MEGA65 keymap.
   if f_shiftable_fkey(key) then
      base    := C_KEYMAP_MEGA65(key);
      r.valid := '1';
      if sh = '1' then
         r.code := base(6 downto 1) & '1';   -- base+1 (F2..F10)
         r.f0   := '1';                       -- the Amiga must not see Shift with the substituted F-key
      else
         r.code := base(6 downto 0);
      end if;
      return r;
   end if;

   -- MEGA65 mode: semantic "the cap is law".
   case key is
      -- the seven front-face symbol keys (MEGA = symbol modifier)
      when m65_arrow_left =>                                   -- _ / ` / `
         r.is_sym := '1'; r.valid := '1';
         if mg = '1' then    r.code := "0000000"; r.f0 := '1'; -- ` = $00
         elsif sh = '1' then r.code := "0000000"; r.f0 := '1'; -- ` = $00 (drop Shift)
         else                r.code := "0001011"; r.f1 := '1'; -- _ = Sh+$0B
         end if;
      when m65_comma =>                                        -- , / < / ~
         r.is_sym := '1'; r.valid := '1';
         if mg = '1' then r.code := "0000000"; r.f1 := '1';    -- ~ = Sh+$00
         else             r.code := "0111000";                 -- , / < = $38 (Shift passes)
         end if;
      when m65_dot =>                                          -- . / > / |
         r.is_sym := '1'; r.valid := '1';
         if mg = '1' then r.code := "0001101"; r.f1 := '1';    -- | = Sh+$0D
         else             r.code := "0111001";                 -- . / > = $39
         end if;
      when m65_slash =>                                        -- / / ? / \
         r.is_sym := '1'; r.valid := '1';
         if mg = '1' then r.code := "0001101"; r.f0 := '1';    -- \ = $0D
         else             r.code := "0111010";                 -- / / ? = $3A
         end if;
      when m65_colon =>                                        -- : / [ / {
         r.is_sym := '1'; r.valid := '1';
         if mg = '1' then    r.code := "0011010"; r.f1 := '1'; -- { = Sh+$1A
         elsif sh = '1' then r.code := "0011010"; r.f0 := '1'; -- [ = $1A (drop Shift)
         else                r.code := "0101001"; r.f1 := '1'; -- : = Sh+$29
         end if;
      when m65_semicolon =>                                    -- ; / ] / }
         r.is_sym := '1'; r.valid := '1';
         if mg = '1' then    r.code := "0011011"; r.f1 := '1'; -- } = Sh+$1B
         elsif sh = '1' then r.code := "0011011"; r.f0 := '1'; -- ] = $1B (drop Shift)
         else                r.code := "0101001";               -- ; = $29
         end if;
      when m65_equal =>                                        -- = / _ / _
         r.is_sym := '1'; r.valid := '1';
         if mg = '1' then    r.code := "0001011"; r.f1 := '1'; -- _ = Sh+$0B
         elsif sh = '1' then r.code := "0001011";               -- _ = Sh+$0B (Shift passes)
         else                r.code := "0001100";               -- = = $0C
         end if;

      -- @ / ^ / * are MEGA65 symbol-modifier keys with a graphic-only Shift legend. @ prints '@'
      -- under MEGA too (suppressing Left-Amiga - the cap shows '@' on its front face); ^ and * have a
      -- graphic MEGA legend and send nothing. This follows spec section 5a's MEGA column and
      -- doc/keyboard.md (the user-facing contract); section 5b's 7-key list omits them, but a real
      -- MEGA65 keycap is the tie-breaker: MEGA+@ = @, MEGA+^ = nothing, MEGA+* = nothing.
      when m65_at =>                                           -- @ / (graphic) / @
         r.is_sym := '1';
         if sh = '1' and mg = '0' then r.valid := '0';          -- Shift+@ = graphic -> nothing
         else r.valid := '1'; r.code := "0000010"; r.f1 := '1'; -- @ (unshifted or MEGA+@) = Sh+$02
         end if;
      when m65_arrow_up =>                                     -- ^ / (Pi) / (graphic)
         r.is_sym := '1';
         if sh = '1' or mg = '1' then r.valid := '0';           -- Shift+^ (Pi) or MEGA+^ -> nothing
         else r.valid := '1'; r.code := "0000110"; r.f1 := '1'; -- ^ = Sh+$06
         end if;
      when m65_asterisk =>                                     -- * / (graphic) / (graphic)
         r.is_sym := '1';
         if sh = '1' or mg = '1' then r.valid := '0';           -- Shift+* or MEGA+* -> nothing
         else r.valid := '1'; r.code := "1011101";              -- * = $5D (keypad)
         end if;

      -- number row: the five keys whose Shift symbol differs from the Amiga's
      when m65_2 =>                                            -- 2 / "
         r.valid := '1';
         if sh = '1' then r.code := "0101010";                  -- " = Sh+$2A (Shift passes)
         else             r.code := "0000010";                  -- 2 = $02
         end if;
      when m65_6 =>                                            -- 6 / &
         r.valid := '1';
         if sh = '1' then r.code := "0000111";                  -- & = Sh+$07 (Shift passes)
         else             r.code := "0000110";                  -- 6 = $06
         end if;
      when m65_7 =>                                            -- 7 / '
         r.valid := '1';
         if sh = '1' then r.code := "0101010"; r.f0 := '1';     -- ' = $2A (drop Shift)
         else             r.code := "0000111";                  -- 7 = $07
         end if;
      when m65_8 =>                                            -- 8 / (
         r.valid := '1';
         if sh = '1' then r.code := "0001001";                  -- ( = Sh+$09 (Shift passes)
         else             r.code := "0001000";                  -- 8 = $08
         end if;
      when m65_9 =>                                            -- 9 / )
         r.valid := '1';
         if sh = '1' then r.code := "0001010";                  -- ) = Sh+$0A (Shift passes)
         else             r.code := "0001001";                  -- 9 = $09
         end if;
      when m65_0 =>                                            -- 0 / (none)
         if sh = '1' then r.valid := '0';                       -- Shift+0 has no MEGA65 cap symbol
         else r.valid := '1'; r.code := "0001010";              -- 0 = $0A
         end if;

      -- everything else: plain MEGA65 keymap, Shift passes straight through
      when others =>
         base := C_KEYMAP_MEGA65(key);
         if base /= C_NO_KEY then
            r.valid := '1';
            r.code  := base(6 downto 0);
         end if;
   end case;
   return r;
end function resolve;

-- Pacing of the keycode events towards CIA-A. Send-then-wait-for-acknowledge flow control (see the
-- header and the pacer process below). Unchanged from the keyboard-handshake milestone.
constant C_EVENT_PACE    : natural := 28_375;     -- 1 ms @ 28.375 MHz (min-gap floor)
constant C_ACK_TIMEOUT   : natural := 4_038_750;  -- ~143 ms @ 28.375 MHz: deadlock fallback only
constant C_ACK_GUARD     : natural := 8;          -- ~2 clk7: blackout the ack right after a send so
                                                  -- a read landing in ciaa's sdr_latch settling
                                                  -- window (still the PREVIOUS code) cannot ack the
                                                  -- current one. Must be >= sdr_latch settle
                                                  -- (~1 clk7) and << the fastest reader response.
constant C_ACK_SETTLE    : natural := 24;         -- kbd_ack_i low-time (cycles) that marks the END of
                                                  -- ONE CIA read. On the bus a read is a cck-gated
                                                  -- level, so kbd_ack_i can appear as SEVERAL clk_main
                                                  -- pulses (~1 clk7 = ~4 cycles apart) within one read
                                                  -- (verified: 3 edges/read against amiga_clk + the
                                                  -- m68k bridge). Coalesce them into ONE ack by
                                                  -- re-arming only after kbd_ack_i idles this long:
                                                  -- >> an intra-read cck notch (~4 cycles), << the
                                                  -- >= 1 ms gap between two reads.

-- Hold back the first event after reset: minimig_syscontrol.v stretches the core-internal
-- reset by another 4 frames (~80 ms PAL); 100 ms is safely beyond that, yet unnoticeable.
constant C_RESET_HOLDOFF : natural := 2_837_500;  -- 100 ms @ 28.375 MHz

-- Warm-boot combo: reset pulse width and the re-arm guard time. The guard must exceed
-- several 1 kHz scan sweeps, because the reset clears the key mirror and the still-held
-- combo keys get re-mirrored within one sweep - without the guard that would re-trigger.
constant C_RESET_PULSE   : natural := 63;         -- pulse = C_RESET_PULSE+1 cycles; minimig_
                                                  -- syscontrol stretches it to ~80 ms anyway
constant C_COMBO_REARM   : natural := 227_000;    -- ~8 ms of continuous release

-- Mirror of the state of all 80 MEGA65 keys (low active, '1' = released), so that the 1 kHz
-- scan generates exactly one event per press edge and one event per release edge
signal key_pressed_n : std_logic_vector(79 downto 0) := (others => '1');

-- Per-key latched Amiga chord (from resolve() at the make edge). key_code is the exact keycode sent
-- (so the matching break uses the same code); key_valid marks that the key produced an Amiga event;
-- key_f1/key_f0 are the Shift requirement and key_sla the Left-Amiga suppression, held WHILE the key
-- is down. Only the currently-held override keys ever carry non-zero f1/f0/sla.
type t_code_arr is array(0 to 79) of std_logic_vector(6 downto 0);
signal key_code      : t_code_arr;
signal key_valid     : std_logic_vector(79 downto 0) := (others => '0');
signal key_f1        : std_logic_vector(79 downto 0) := (others => '0');
signal key_f0        : std_logic_vector(79 downto 0) := (others => '0');
signal key_sla       : std_logic_vector(79 downto 0) := (others => '0');

-- Small event FIFO (15 usable slots): two different keys can change state only ~14 us apart
-- within one scan sweep, while the pacer drains one event per millisecond. Humans cannot
-- overflow 15 slots at a 1 ms drain rate; should it ever happen, the newest event is dropped.
type t_fifo is array(0 to 15) of std_logic_vector(7 downto 0);
signal fifo          : t_fifo;
signal fifo_wr_ptr   : unsigned(3 downto 0) := (others => '0');
signal fifo_rd_ptr   : unsigned(3 downto 0) := (others => '0');

signal pace_cnt      : natural range 0 to C_RESET_HOLDOFF := 0;
signal kms_level     : std_logic := '0';
signal kbd_data      : std_logic_vector(7 downto 0) := (others => '0');

-- Flow-control pacer state (see the pacing note in the header and C_ACK_* above):
signal ack_seen      : std_logic := '1';   -- current code consumed (1 = ready to send the next)
signal to_cnt        : natural range 0 to C_ACK_TIMEOUT := 0;  -- deadlock timeout countdown
signal kbd_ack_d     : std_logic := '0';   -- 1-cycle history of kbd_ack_i for rising-edge detect
signal ack_guard     : natural range 0 to C_ACK_GUARD := 0;    -- post-send ack blackout countdown
signal ack_armed     : std_logic := '0';   -- '1' = ready to accept the next read's ack (one per read)
signal ack_low_cnt   : natural range 0 to C_ACK_SETTLE := 0;   -- kbd_ack_i low-time (read-end debounce)

-- Amiga-side modifier state as the Amiga currently believes it (each converged towards a desired
-- state derived from the held keys' requirements). shift_l/r_sent = Left/Right Shift; la_sent =
-- Left-Amiga.
signal shift_l_sent  : std_logic := '0';
signal shift_r_sent  : std_logic := '0';
signal la_sent       : std_logic := '0';

-- Deferred Left-Amiga engine (MEGA65 mode; see the header). la_engaged = "MEGA is acting as
-- Left-Amiga" (set when the first non-symbol co-key is pressed while MEGA is held). mega_seen_sym =
-- "a front-face symbol key was pressed during this MEGA hold" (so releasing MEGA does not tap).
-- la_tap_stage emits the make+break tap when MEGA is released without ever having been used.
signal la_engaged    : std_logic := '0';
signal mega_seen_sym : std_logic := '0';
type t_la_tap is (LAT_NONE, LAT_MAKE, LAT_BREAK);
signal la_tap_stage  : t_la_tap := LAT_NONE;

-- One make edge waiting for its required modifier state to converge before it can be committed
-- (generalisation of the old shifted-F "fwait"; non-blocking - other keys keep processing, the
-- waiting key's edge is retried on the next 1 kHz sweep). wait_f1/f0/sla feed the desired-modifier
-- computation while the key is not yet in the held-key mirror.
signal wait_active   : std_logic := '0';
signal wait_num      : integer range 0 to 79 := 0;
signal wait_f1       : std_logic := '0';
signal wait_f0       : std_logic := '0';
signal wait_sla      : std_logic := '0';

-- CTRL+MEGA+RESTORE warm-boot one-shot (deliberately NOT cleared by reset_i - it
-- triggers that very reset; see header)
type t_rst_state is (RST_ARMED, RST_PULSE, RST_RELEASE);
signal rst_state     : t_rst_state := RST_ARMED;
signal rst_cnt       : natural range 0 to C_COMBO_REARM := 0;
signal core_reset    : std_logic := '0';

begin

   kbd_mouse_data_o  <= kbd_data;
   kbd_mouse_type_o  <= "10";       -- constant: 2 = keyboard event (raw Amiga keycode)
   kms_level_o       <= kms_level;
   core_reset_o      <= core_reset;

   -- right mouse button substitute: level straight from the key mirror (registered there);
   -- reset_i clears the mirror, so the button reads released during/after reset.
   -- The source key is mode-dependent: RUN/STOP in MEGA65 mode, but the ARROW-UP symbol key (left
   -- of RESTORE) in Amiga mode, where RUN/STOP is repurposed as Esc. Both source keys are mirror-only
   -- (C_NO_KEY = no Amiga keycode) in their own mode, so the button never disturbs the keycode stream.
   mouse_rmb_o       <= (not key_pressed_n(m65_run_stop)) when keyboard_mode_i = '0'
                        else (not key_pressed_n(m65_arrow_up));

   keyboard_events : process(clk_main_i)
      variable v_amiga_mode  : std_logic;
      variable v_shift_phys  : std_logic;
      variable v_mega_held   : std_logic;
      variable v_r           : t_resolved;
      variable v_fifo_free   : boolean;
      variable v_any_f1      : std_logic;
      variable v_any_f0      : std_logic;
      variable v_any_sla     : std_logic;
      variable v_req_f1      : std_logic;
      variable v_req_f0      : std_logic;
      variable v_req_sla     : std_logic;
      variable v_phys_l      : std_logic;
      variable v_phys_r      : std_logic;
      variable v_want_up     : std_logic;
      variable v_want_down   : std_logic;
      variable v_synth_up    : std_logic;
      variable v_shift_des_l : std_logic;
      variable v_shift_des_r : std_logic;
      variable v_lamiga_des  : std_logic;
      variable v_this_sla    : std_logic;
      variable v_need_la     : std_logic;
      variable v_mods_ok     : boolean;
   begin
      if rising_edge(clk_main_i) then

         v_amiga_mode := keyboard_mode_i;
         v_phys_l     := not key_pressed_n(m65_left_shift);
         v_phys_r     := not key_pressed_n(m65_right_shift);
         v_shift_phys := v_phys_l or v_phys_r;
         v_mega_held  := not key_pressed_n(m65_mega);
         v_r          := resolve(kb_key_num_i, v_shift_phys, v_mega_held, v_amiga_mode);
         v_fifo_free  := (fifo_wr_ptr + 1) /= fifo_rd_ptr;

         -- Aggregate the modifier requirements of every currently-held key (the override keys carry
         -- non-zero f1/f0/sla; all others contribute 0). Plus the one make edge still waiting for its
         -- modifiers (not yet in the mirror), via wait_*.
         v_any_f1 := '0'; v_any_f0 := '0'; v_any_sla := '0';
         for k in 0 to 79 loop
            if key_pressed_n(k) = '0' then
               v_any_f1  := v_any_f1  or key_f1(k);
               v_any_f0  := v_any_f0  or key_f0(k);
               v_any_sla := v_any_sla or key_sla(k);
            end if;
         end loop;
         v_req_f1  := v_any_f1  or (wait_active and wait_f1);
         v_req_f0  := v_any_f0  or (wait_active and wait_f0);
         v_req_sla := v_any_sla or (wait_active and wait_sla);

         -- Desired Amiga-side Shift: pass the physical Shift through, but force it asserted (want_up,
         -- synthesising Left Shift only if the user holds none) or released (want_down) when an
         -- override key demands it. A force-up wins a (non-gesture) up/down conflict.
         v_want_up   := v_req_f1;
         v_want_down := v_req_f0 and not v_req_f1;
         v_synth_up  := v_want_up and not (v_phys_l or v_phys_r);
         v_shift_des_l := (v_phys_l and not v_want_down) or v_synth_up;
         v_shift_des_r := (v_phys_r and not v_want_down);

         -- Desired Amiga-side Left-Amiga: asserted while MEGA is held AND engaged AND no symbol key
         -- is currently suppressing it; plus the make phase of a MEGA-tap one-shot.
         v_lamiga_des := v_mega_held and la_engaged and not v_req_sla;
         if la_tap_stage = LAT_MAKE then
            v_lamiga_des := '1';
         end if;

         -- MEGA interaction of the currently-scanned key (MEGA65 mode only): a front-face symbol key
         -- must have Left-Amiga suppressed (this_sla), any other valid key must have it engaged
         -- (need_la) before its make.
         v_this_sla := '0';
         v_need_la  := '0';
         if v_amiga_mode = '0' and v_mega_held = '1' and v_r.valid = '1' then
            if v_r.is_sym = '1' then
               v_this_sla := '1';
            else
               v_need_la := '1';
            end if;
         end if;

         -- Are the Amiga-side modifiers already in the state this key's make needs?
         v_mods_ok := (v_r.f1 = '0' or (shift_l_sent = '1' or shift_r_sent = '1'))
                  and (v_r.f0 = '0' or (shift_l_sent = '0' and shift_r_sent = '0'))
                  and (v_need_la  = '0' or la_sent = '1')
                  and (v_this_sla = '0' or la_sent = '0');

         -- Cancel a stale wait: the waiting key was released before it could be committed (its edge
         -- then vanishes - mirror and physical both "released" - so it would never be retried).
         if wait_active = '1' and kb_key_num_i = wait_num and kb_key_pressed_n_i = '1' then
            wait_active <= '0';
         end if;

         -- One queued event per cycle, in priority order: converge Left-Amiga, then the two Shift
         -- keys (this is what emits the modifier make/break codes in the right order relative to the
         -- keycode), then handle the edge of the key the 1 kHz scanner currently presents. The
         -- scanner dwells ~400 cycles per key, so a few-cycle postponement never loses an edge; the
         -- mirror is only updated when an edge is actually consumed, so postponed edges are retried.
         if la_sent /= v_lamiga_des then
            if v_fifo_free then
               fifo(to_integer(fifo_wr_ptr)) <= (not v_lamiga_des) & "1100110";  -- $66 Left Amiga
               fifo_wr_ptr <= fifo_wr_ptr + 1;
               la_sent     <= v_lamiga_des;
               if la_tap_stage = LAT_MAKE then
                  la_tap_stage <= LAT_BREAK;    -- just queued the tap make
               elsif la_tap_stage = LAT_BREAK then
                  la_tap_stage <= LAT_NONE;     -- just queued the tap break
               end if;
            end if;

         elsif shift_l_sent /= v_shift_des_l then
            if v_fifo_free then
               fifo(to_integer(fifo_wr_ptr)) <= (not v_shift_des_l) & "1100000";  -- $60 Left Shift
               fifo_wr_ptr  <= fifo_wr_ptr + 1;
               shift_l_sent <= v_shift_des_l;
            end if;

         elsif shift_r_sent /= v_shift_des_r then
            if v_fifo_free then
               fifo(to_integer(fifo_wr_ptr)) <= (not v_shift_des_r) & "1100001";  -- $61 Right Shift
               fifo_wr_ptr  <= fifo_wr_ptr + 1;
               shift_r_sent <= v_shift_des_r;
            end if;

         elsif kb_key_pressed_n_i /= key_pressed_n(kb_key_num_i) then

            -- MEGA (Left-Amiga) - MEGA65 mode: deferred. Mirror only; the $66 make/break is driven by
            -- the convergence above (engage on a non-symbol co-key, tap on release-without-use). In
            -- Amiga mode MEGA falls through to the normal path below as a plain $66 key.
            if v_amiga_mode = '0' and kb_key_num_i = m65_mega then
               key_pressed_n(m65_mega) <= kb_key_pressed_n_i;
               if kb_key_pressed_n_i = '0' then       -- MEGA make: start a fresh hold
                  la_engaged    <= '0';
                  mega_seen_sym <= '0';
               else                                   -- MEGA release
                  if la_engaged = '0' and mega_seen_sym = '0' then
                     la_tap_stage <= LAT_MAKE;        -- tapped alone -> Left-Amiga tap
                  end if;
                  la_engaged    <= '0';
                  mega_seen_sym <= '0';
               end if;

            -- Shift keys: mirror only - their Amiga make/break codes are generated by the convergence
            -- above (from the physical state, minus the per-key suppression).
            elsif kb_key_num_i = m65_left_shift or kb_key_num_i = m65_right_shift then
               key_pressed_n(kb_key_num_i) <= kb_key_pressed_n_i;

            -- a MAKE edge
            elsif kb_key_pressed_n_i = '0' then
               -- MEGA housekeeping (MEGA65 mode): a front-face symbol key marks this MEGA hold as
               -- "used as symbol modifier" so releasing MEGA does not tap Left-Amiga - even for the
               -- graphic-only MEGA+*/MEGA+^ that yield no code (checked before the valid gate).
               if v_amiga_mode = '0' and v_mega_held = '1' and v_r.is_sym = '1' then
                  mega_seen_sym <= '1';
               end if;

               if v_r.valid = '0' then
                  -- key with no Amiga event (unmapped, or a graphic-only shifted cap): mirror only
                  key_pressed_n(kb_key_num_i) <= '0';
                  key_valid(kb_key_num_i)     <= '0';
                  if kb_key_num_i = wait_num then
                     wait_active <= '0';
                  end if;
               else
                  -- any non-symbol valid key under MEGA engages Left-Amiga before its make
                  if v_amiga_mode = '0' and v_mega_held = '1'
                     and v_r.is_sym = '0' and la_engaged = '0' then
                     la_engaged <= '1';
                  end if;

                  if v_mods_ok and v_fifo_free then
                     -- commit the make now (modifiers already converged)
                     key_pressed_n(kb_key_num_i)   <= '0';
                     fifo(to_integer(fifo_wr_ptr)) <= '0' & v_r.code;
                     fifo_wr_ptr                   <= fifo_wr_ptr + 1;
                     key_code(kb_key_num_i)        <= v_r.code;
                     key_valid(kb_key_num_i)       <= '1';
                     key_f1(kb_key_num_i)          <= v_r.f1;
                     key_f0(kb_key_num_i)          <= v_r.f0;
                     key_sla(kb_key_num_i)         <= v_this_sla;
                     if kb_key_num_i = wait_num then
                        wait_active <= '0';
                     end if;
                  else
                     -- hold the make back: record its requirement so the convergence retracts/
                     -- synthesises the modifiers, and retry this edge on the next 1 kHz sweep
                     -- (mirror deliberately NOT updated)
                     wait_active <= '1';
                     wait_num    <= kb_key_num_i;
                     wait_f1     <= v_r.f1;
                     wait_f0     <= v_r.f0;
                     wait_sla    <= v_this_sla;
                  end if;
               end if;

            -- a BREAK edge
            else
               if key_valid(kb_key_num_i) = '1' then
                  if v_fifo_free then
                     key_pressed_n(kb_key_num_i)   <= '1';
                     fifo(to_integer(fifo_wr_ptr)) <= '1' & key_code(kb_key_num_i);
                     fifo_wr_ptr                   <= fifo_wr_ptr + 1;
                     key_valid(kb_key_num_i)       <= '0';
                     key_f1(kb_key_num_i)          <= '0';
                     key_f0(kb_key_num_i)          <= '0';
                     key_sla(kb_key_num_i)         <= '0';
                  end if;
                  -- FIFO full (practically unreachable): leave the mirror unchanged so the release
                  -- edge is retried on the next sweep - losing a RELEASE would leave the key stuck.
               else
                  key_pressed_n(kb_key_num_i) <= '1';   -- was mirror-only (unmapped)
               end if;
            end if;
         end if;

         -- Pace the events towards CIA-A with send-then-wait-for-acknowledge flow control (see the
         -- pacing note in the header). Put the keycode on the data output and toggle kms_level (the
         -- level change is the strobe that ciaa.v reacts to); the data output is held stable until
         -- the next event, as required by ciaa.v's clk7n_en sampling.

         -- min-gap floor + timeout/blackout countdowns
         if pace_cnt  /= 0 then pace_cnt  <= pace_cnt  - 1; end if;
         if ack_guard /= 0 then ack_guard <= ack_guard - 1; end if;
         if to_cnt    /= 0 then to_cnt    <= to_cnt    - 1; end if;

         -- Acknowledge the code on the wire = the Amiga read the keycode SDR. A CIA read is presented
         -- on the bus as a cck-gated level over the E-clock-synced access, so kbd_ack_i can appear as
         -- SEVERAL clk_main pulses (~1 clk7 apart) within ONE read - it is NOT a single clean level.
         -- Coalesce them into exactly one acknowledge: accept a RISING EDGE only while ARMED, and
         -- re-arm only after kbd_ack_i has been LOW for C_ACK_SETTLE cycles (past any intra-read cck
         -- notch, well within the >= 1 ms gap between two reads). Without this, a bounce pulse landing
         -- after the send of the next code would falsely acknowledge it (overrun returns for a slow
         -- reader whose read overlaps the send). ack_guard additionally blacks out the sdr_latch
         -- settling window right after a send (a read there still returns the PREVIOUS code).
         kbd_ack_d <= kbd_ack_i;
         if kbd_ack_i = '1' then
            ack_low_cnt <= 0;
         elsif ack_low_cnt /= C_ACK_SETTLE then
            ack_low_cnt <= ack_low_cnt + 1;
         end if;
         if ack_low_cnt = C_ACK_SETTLE then
            ack_armed <= '1';                  -- read line idle => ready for the next read's ack
         end if;
         if kbd_ack_i = '1' and kbd_ack_d = '0' and ack_armed = '1' and ack_guard = 0 then
            ack_seen  <= '1';                  -- one ack per read
            ack_armed <= '0';                  -- ignore the rest of this (possibly bouncing) read
         end if;

         -- Send the next code once the min-gap elapsed AND the previous code was consumed (or the
         -- deadlock timeout fired). This block is textually LAST so its writes (ack_seen<='0',
         -- to_cnt, ack_guard) win over the decrements and the ack latch above in the same cycle.
         if pace_cnt = 0 and (ack_seen = '1' or to_cnt = 0)
            and fifo_rd_ptr /= fifo_wr_ptr then
            kbd_data    <= fifo(to_integer(fifo_rd_ptr));
            kms_level   <= not kms_level;
            fifo_rd_ptr <= fifo_rd_ptr + 1;
            pace_cnt    <= C_EVENT_PACE;   -- min-gap floor
            ack_seen    <= '0';            -- wait for THIS code's fresh ack
            to_cnt      <= C_ACK_TIMEOUT;  -- arm the deadlock fallback
            ack_guard   <= C_ACK_GUARD;    -- blackout the sdr_latch settling window
         end if;

         if reset_i = '1' then
            -- "all keys released": keys (re-)pressed after/during reset generate fresh events
            key_pressed_n <= (others => '1');
            fifo_wr_ptr   <= (others => '0');
            fifo_rd_ptr   <= (others => '0');
            pace_cnt      <= C_RESET_HOLDOFF;
            -- the Amiga side resets too: modifier/substitution bookkeeping restarts clean
            key_valid     <= (others => '0');
            key_f1        <= (others => '0');
            key_f0        <= (others => '0');
            key_sla       <= (others => '0');
            shift_l_sent  <= '0';
            shift_r_sent  <= '0';
            la_sent       <= '0';
            la_engaged    <= '0';
            mega_seen_sym <= '0';
            la_tap_stage  <= LAT_NONE;
            wait_active   <= '0';
            -- flow-control pacer: ack_seen='1' so the first post-reset code isn't blocked waiting
            -- for an ack that cannot exist yet; the 100 ms C_RESET_HOLDOFF (pace_cnt above) still
            -- applies and composes cleanly (first code waits out the hold-off, then goes on ack_seen)
            ack_seen      <= '1';
            to_cnt        <= 0;
            kbd_ack_d     <= '0';
            ack_guard     <= 0;
            ack_armed     <= '0';   -- re-arms after kbd_ack_i idles C_ACK_SETTLE cycles post-reset
            ack_low_cnt   <= 0;
            -- deliberately NOT resetting kms_level/kbd_data: a stable level is a no-op for
            -- ciaa.v, while forcing it could generate a phantom keystrobe
         end if;
      end if;
   end process keyboard_events;

   -- CTRL+MEGA+RESTORE = Ctrl+LAmiga+RAmiga warm boot. One-shot with a re-arm guard:
   -- the reset pulse clears the key mirror (via reset_i in the process above), and the
   -- still-held combo keys get re-mirrored within one 1 kHz sweep - so re-arming
   -- requires the combo to be continuously absent for ~8 ms. This FSM is deliberately
   -- NOT cleared by reset_i (it is the source of that reset).
   reset_combo : process(clk_main_i)
      variable v_combo : boolean;
   begin
      if rising_edge(clk_main_i) then
         v_combo := key_pressed_n(m65_ctrl) = '0' and key_pressed_n(m65_mega) = '0'
                    and key_pressed_n(m65_restore) = '0';
         case rst_state is
            when RST_ARMED =>
               if v_combo then
                  core_reset <= '1';
                  rst_cnt    <= C_RESET_PULSE;
                  rst_state  <= RST_PULSE;
               end if;
            when RST_PULSE =>
               if rst_cnt /= 0 then
                  rst_cnt <= rst_cnt - 1;
               else
                  core_reset <= '0';
                  rst_cnt    <= C_COMBO_REARM;
                  rst_state  <= RST_RELEASE;
               end if;
            when RST_RELEASE =>
               if v_combo then
                  rst_cnt <= C_COMBO_REARM;
               elsif rst_cnt /= 0 then
                  rst_cnt <= rst_cnt - 1;
               else
                  rst_state <= RST_ARMED;
               end if;
         end case;
      end if;
   end process reset_combo;

end architecture beh;
