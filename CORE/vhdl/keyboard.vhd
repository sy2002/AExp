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
-- one per release edge), the key is looked up in the MEGA65-to-Amiga translation table below and -
-- if it maps to an Amiga key - an event is pushed into a small FIFO. A pacing timer drains the
-- FIFO at most once per millisecond: it puts the keycode on kbd_mouse_data_o (bit 7 = release
-- flag) and toggles kms_level_o. The pacing is necessary because Kickstart's keyboard.device
-- needs time to read the SDR and to perform the (virtual) handshake after every single keycode
-- (on real hardware a code takes >500 us on the wire plus handshake; MiSTer relies on the HPS
-- naturally pacing the events). Two different MEGA65 keys can change state as little as ~14 us
-- apart within one scan sweep, so without FIFO+pacing, events could be lost. After reset, the
-- first event is additionally held back for 100 ms, because minimig_syscontrol.v stretches the
-- internal reset by 4 frames (~80 ms PAL) - events sent earlier would be swallowed by CIA-A's
-- reset and keys held down during a core reset would get lost.
--
-- MEGA65 -> Amiga keycode mapping (raw Amiga keycodes as per the Amiga Hardware Reference Manual,
-- Appendix on keyboard; confirmed against the codes used in Minimig.sv and ciaa.v):
--
--   #  MEGA65 key      Amiga key (code)     rationale / notes
--   -- --------------- -------------------- -----------------------------------------------------
--    0 INS/DEL         Backspace   ($41)    C64 DEL deletes to the left = Amiga Backspace
--    1 RETURN          Return      ($44)
--    2 CURSOR RIGHT    Crsr Right  ($4E)
--    3 F7              F7          ($56)    Shift+F7 = F8 ($57), see "shifted F-keys" below
--    4 F1              F1          ($50)    Shift+F1 = F2 ($51)
--    5 F3              F3          ($52)    Shift+F3 = F4 ($53)
--    6 F5              F5          ($54)    Shift+F5 = F6 ($55)
--    7 CURSOR DOWN     Crsr Down   ($4D)
--    8..39, 41, 42     3 W A 4 Z S E LSHIFT 5 R D 6 C F T X 7 Y G 8 B H U V 9 I J 0 M K O N P L:
--                      direct 1:1 mapping, see table below
--                      (digits $01..$0A, letters: Q-row $10.., A-row $20.., Z-row $31..)
--   40 + (plus)        Keypad +    ($5E)    Amiga has no unshifted '+' on the main block
--   43 - (minus)       -           ($0B)
--   44 . (period)      .           ($39)
--   45 : [             ; :         ($29)    positional (right of L); Shift+key gives ':'
--                                           which matches the MEGA65 key cap
--   46 @               [ {         ($1A)    positional (right of P); Amiga '@' is Shift+2
--   47 , (comma)       ,           ($38)
--   48 GBP (pound)     \ |         ($0D)    positional (top row, right); supplies the otherwise
--                                           missing backslash; pound not on US Amiga keymap
--   49 * (asterisk)    Keypad *    ($5D)    keeps '*' directly typable (AmigaDOS console "*");
--                                           Amiga main-block '*' would be Shift+8
--   50 ; ]             ' "         ($2A)    positional (2nd right of L); supplies the otherwise
--                                           missing apostrophe/quote key
--   51 CLR/HOME        Del         ($46)    positional: top-right cluster, like Amiga Del
--   52 RIGHT SHIFT     Right Shift ($61)
--   53 = (equal)       =           ($0C)
--   54 ARROW UP (sym)  ] }         ($1B)    positional; '^' itself is Shift+6 on the Amiga
--   55 / (slash)       /           ($3A)
--   56 1               1           ($01)
--   57 ARROW LEFT(sym) ` ~         ($00)    positional: top-left corner key on both machines
--   58 CTRL            Control     ($63)
--   59 2               2           ($02)
--   60 SPACE           Space       ($40)
--   61 MEGA            Left Amiga  ($66)    Workbench/Intuition shortcuts (LAmiga+N/M etc.)
--   62 Q               Q           ($10)
--   63 RUN/STOP        RIGHT MOUSE BUTTON   no Amiga keycode (ESC has its own key); the held
--                                           state is exported on mouse_rmb_o, see below
--   64 NO SCRL         - unmapped -         no Amiga counterpart
--   65 TAB             Tab         ($42)
--   66 ALT             Left Alt    ($64)
--   67 HELP            Help        ($5F)
--   68 F9              F9          ($58)    Shift+F9 = F10 ($59)
--   69 F11             - unmapped -         does nothing on the Amiga (F10 = Shift+F9); free
--                                           for other uses
--   70 F13             - unmapped -         Amiga only has F1..F10
--   71 ESC             Esc         ($45)
--   72 CAPS LOCK       Caps Lock   ($62)    special, see comment below
--   73 CURSOR UP       Crsr Up     ($4C)
--   74 CURSOR LEFT     Crsr Left   ($4F)
--   75 RESTORE         Right Amiga ($67)    no Amiga analog of the C64 NMI key; gives access to
--                                           the right-Amiga menu shortcuts of Workbench & apps
--   76..79             - unused -           not populated on the MEGA65 keyboard
--
-- SHIFTED F-KEYS (July 2026): the MEGA65 keycaps promise F2/F4/F6/F8/F10 as the shifted variants
-- of the physical F1/F3/F5/F7/F9 keys, but the scanner reports the PHYSICAL key plus the shift
-- key - forwarding that 1:1 would make the Amiga see Shift+F1, which Amiga software does not
-- treat as F2 (and worse: in apps like ProTracker the shift qualifier changes the meaning).
-- Therefore this module translates: when a shift key is physically held while F1/F3/F5/F7/F9 is
-- pressed, the Amiga receives the NEXT F-keycode (all Amiga F-codes are $50..$59 with even base
-- codes, so "shifted variant" = base+1) - and the shift keys are HIDDEN from the Amiga for the
-- whole duration ("phantom shift" suppression, like PS/2-to-Amiga converters):
-- * The Amiga-side shift state is tracked separately (shift_l_sent/shift_r_sent) and converges
--   to "physical AND NOT suppressed". The shift BREAK codes are queued BEFORE the F2 make (the
--   press edge is held back until the Amiga-side shifts read released), and once a shift has
--   been consumed this way it stays hidden (shift_hold_hidden) for as long as it is physically
--   held - it is retracted once and NOT re-toggled around each F-key, so the Amiga never sees a
--   shift qualifier together with a substituted F-key and the substituted F-keys reach a raw
--   keyboard reader (e.g. VATestprogram's CIA-serial keyboard test) as clean isolated
--   make/break pairs instead of being wrapped in machine-paced shift churn.
-- * That single early retract break can itself be lost by a SLOW raw reader: it is queued ~1 ms
--   before the F2 make, and a single-byte CIA SDR is overwritten if the reader has not consumed
--   it yet. So the retracted shift's break is RE-EMITTED on the physical shift release
--   (shift_l_consumed/shift_r_consumed). In the normal gesture (tap the F-key, THEN release the
--   shift as a separate edge) the re-emit is alone on the wire, so the reader reliably clears the
--   shift key. keyboard.device just sees a harmless redundant shift break; a raw tester needs it.
--   KNOWN RESIDUAL (raw readers only): if the F-key and the shift are released within the SAME
--   ~1 ms scan sweep, the F-key break and this re-emit land one pace apart and the slow reader
--   still drops one - a stuck F-key for F1/F3/F5/F7 (scanned before the shifts) or an uncleared
--   shift for F9 (after). Fully closing that needs real keyboard-handshake pacing (see
--   doc/temp_keyboard.md); the 1 ms pace is the floor, so a gate can only relocate the loss.
-- * The substituted code is latched per key (fkey_shifted), so releasing shift before the F-key
--   still sends the matching F2 break - no stuck keys.
-- * Consequences, by design: Shift+F2 (etc.) cannot be typed (the shift is consumed by the
--   substitution - same as on any C64-style keyboard); pressing shift WHILE an unshifted
--   F1 is already held simply types Shift+F1 (no substitution after the fact); while a
--   substituted F-key has been used, the shift qualifier stays hidden for ALL keys until the
--   physical shift is released (inherent to phantom-shift suppression - shifted characters
--   resume after the physical shift is released and pressed again);
--   and the shift must lead the F-key by at least one scan sweep (~1 ms) - a faster chord
--   (or holding Shift+F1 across a reset, which rebuilds the key mirror in scan order)
--   delivers plain F1 plus shift for that press.
--
-- WARM BOOT (July 2026): Ctrl+LAmiga+RAmiga = CTRL+MEGA+RESTORE is detected here and pulses
-- core_reset_o (one shot; re-armed only after the combo has been released for several scan
-- sweeps, because the reset itself clears the key mirror). main.vhd ORs this into amiga_rst,
-- which resets CPU+chipset via rst_ext while all memories keep their content - exactly the
-- reset-line semantics of the real keyboard MCU. Note the FSM deliberately survives reset_i.
-- Detection is by mirror STATE, so the combo also fires when it BECOMES visible: e.g. when
-- the OSM closes (the OSM blanks the scan) or right after an M2M reset while the keys are
-- still held - consistent with the user's intent of holding a reset combo. Keys still held
-- after the boot are re-delivered as plain make codes once the 100 ms holdoff expires
-- (real Amiga keyboards resend held keys after reset, too); Kickstart ignores them.
--
-- RIGHT MOUSE BUTTON substitute (July 2026): holding RUN/STOP (key 63, which has no Amiga
-- keycode) is exported as a level on mouse_rmb_o; main.vhd ORs it into Minimig's mouse_btn(1).
-- Hold RUN/STOP while moving/clicking the mouse = Amiga right mouse button (Workbench menus).
-- Background: on a real Amiga the mouse right button shorts DB9 pin 9 (POTX) to GND while
-- PAULA actively drives the pot lines high (input.device writes POTGO $FF00 and reads the pin
-- level back via POTINP). The MEGA65's C64-style paddle circuit can only drain the line and
-- passively time its recharge - it cannot drive it high - so a GND-shorting button is
-- electrically invisible to it (verified with two Amiga tank mice on real R3 hardware,
-- 2026-07-03). RUN/STOP events never reach the Amiga (C_NO_KEY, mirror-only), so the
-- substitute cannot interfere with the keycode stream.
--
-- Known limitations (by design, documented for future milestones):
-- * Amiga keys with no MEGA65 counterpart cannot be typed: Right Alt, the numeric pad
--   (except '+' and '*' which we borrow, see above) and the international keys $2B/$30.
--
-- CAPS LOCK: A real Amiga keyboard handles Caps Lock autonomously: it sends a single make code
-- $62 when the lock (and LED) turns ON and a single break code $E2 when the lock turns OFF -
-- nothing in between, no codes while the key is held. The MEGA65 keyboard microcontroller also
-- latches the Caps Lock state and reports the LOCK STATE (not the momentary key state) on a
-- dedicated line, which the M2M framework feeds into the scan as key number 72 (see
-- M2M/vhdl/controllers/M65/mega65kbd_to_matrix.vhdl, phase 72). Therefore the generic
-- edge-to-make/break translation of this module reproduces the standard Amiga behavior exactly:
-- lock engages -> press edge -> $62, lock disengages -> release edge -> $E2. No special casing
-- needed. (Should the lock ever be reported momentarily instead, the worst case is that Caps Lock
-- acts like a shift key only while held - a graceful degradation.)
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

      -- Interface to Minimig (rtl/minimig.v, consumed by rtl/ciaa.v):
      -- raw Amiga keycode events, see protocol description in the header of this file
      kbd_mouse_data_o     : out std_logic_vector(7 downto 0); -- bits 6:0 keycode, bit 7 = 1: release
      kbd_mouse_type_o     : out std_logic_vector(1 downto 0); -- constant 2 = keyboard event
      kms_level_o          : out std_logic;                    -- toggles once per event

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

-- Marker for MEGA65 keys that have no Amiga counterpart. All valid raw Amiga keycodes are
-- <= $67, i.e. bit 7 of a valid table entry is always 0 and bits 6:0 carry the keycode.
constant C_NO_KEY : std_logic_vector(7 downto 0) := x"FF";

-- MEGA65 key number -> raw Amiga keycode (see the big mapping table in the header)
type t_keymap is array(0 to 79) of std_logic_vector(7 downto 0);
constant C_KEYMAP : t_keymap := (
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
   m65_dot           => x"39",   -- .
   m65_colon         => x"29",   -- ; :  (positional, Shift+key = ':')
   m65_at            => x"1A",   -- [ {  (positional)
   m65_comma         => x"38",   -- ,
   m65_gbp           => x"0D",   -- \ |  (positional)
   m65_asterisk      => x"5D",   -- Keypad *
   m65_semicolon     => x"2A",   -- ' "  (positional)
   m65_clr_home      => x"46",   -- Del  (positional)
   m65_right_shift   => x"61",   -- Right Shift
   m65_equal         => x"0C",   -- =
   m65_arrow_up      => x"1B",   -- ] }  (positional)
   m65_slash         => x"3A",   -- /
   m65_1             => x"01",   -- 1
   m65_arrow_left    => x"00",   -- ` ~  (positional, top-left corner)
   m65_ctrl          => x"63",   -- Control
   m65_2             => x"02",   -- 2
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
   others            => C_NO_KEY -- RUN/STOP, NO SCRL, F13 and keys 76..79: unmapped
);

-- Pacing of the keycode events towards CIA-A: at most one event per millisecond, so that
-- Kickstart's keyboard.device has finished reading the SDR and performing the handshake
-- (~200 us) long before the next keycode overwrites the SDR. A real keyboard needs >500 us
-- per code on the wire, so 1 ms is still faster than real hardware while being 100% safe.
constant C_EVENT_PACE    : natural := 28_375;     -- 1 ms @ 28.375 MHz

-- Hold back the first event after reset: minimig_syscontrol.v stretches the core-internal
-- reset by another 4 frames (~80 ms PAL); events sent during that time would be lost in
-- CIA-A's reset. 100 ms is safely beyond that, yet unnoticeable for the user.
constant C_RESET_HOLDOFF : natural := 2_837_500;  -- 100 ms @ 28.375 MHz

-- Warm-boot combo: reset pulse width and the re-arm guard time. The guard must exceed
-- several 1 kHz scan sweeps, because the reset clears the key mirror and the still-held
-- combo keys get re-mirrored within one sweep - without the guard that would re-trigger.
constant C_RESET_PULSE   : natural := 63;         -- pulse = C_RESET_PULSE+1 cycles; minimig_
                                                  -- syscontrol stretches it to ~80 ms anyway
constant C_COMBO_REARM   : natural := 227_000;    -- ~8 ms of continuous release

-- The five MEGA65 F-keys whose SHIFTED variant exists on the Amiga (F2/F4/F6/F8/F10).
-- All Amiga F-key codes are $50..$59 with even base codes: shifted variant = base+1.
pure function f_shiftable_fkey(n : integer) return boolean is
begin
   return n = m65_f1 or n = m65_f3 or n = m65_f5 or n = m65_f7 or n = m65_f9;
end function f_shiftable_fkey;

-- Mirror of the state of all 80 MEGA65 keys (low active, '1' = released), so that the 1 kHz
-- scan generates exactly one event per press edge and one event per release edge
signal key_pressed_n : std_logic_vector(79 downto 0) := (others => '1');

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

-- shifted F-key substitution state (see "SHIFTED F-KEYS" in the header):
-- fkey_shifted(k)='1': key k's make was sent as its shifted variant (base+1) - the
-- matching break must use the same code, and the Amiga-side shifts stay suppressed
-- while any such key is down. Only the five F-key positions are ever set.
signal fkey_shifted  : std_logic_vector(79 downto 0) := (others => '0');
signal shift_l_sent  : std_logic := '0';   -- shift state as the Amiga currently believes it
signal shift_r_sent  : std_logic := '0';
signal fwait         : std_logic := '0';   -- shifted-F make pending, waiting for shift breaks
signal fwait_num     : integer range 0 to 79 := 0;
-- '1' once a physically-held shift has been consumed by an F-key substitution: the Amiga-side
-- shift then stays hidden for the whole shift-hold (retracted once, not re-toggled around each
-- F-key; see "SHIFTED F-KEYS" in the header). Cleared as soon as no shift is physically held.
signal shift_hold_hidden : std_logic := '0';
-- '1' while a Left/Right shift is retracted for an F-key substitution. Its clearing break may
-- have been lost by a slow raw CIA reader (SDR overrun of the early retract), so the break is
-- re-emitted on the physical shift release - see "SHIFTED F-KEYS". Only these two are ever set.
signal shift_l_consumed : std_logic := '0';
signal shift_r_consumed : std_logic := '0';

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
   -- reset_i clears the mirror, so the button reads released during/after reset
   mouse_rmb_o       <= not key_pressed_n(m65_run_stop);

   keyboard_events : process(clk_main_i)
      variable v_amiga_code  : std_logic_vector(7 downto 0);
      variable v_shift_phys  : std_logic;
      variable v_suppress    : std_logic;
      variable v_shift_des_l : std_logic;
      variable v_shift_des_r : std_logic;
      variable v_fifo_free   : boolean;
   begin
      if rising_edge(clk_main_i) then

         v_amiga_code := C_KEYMAP(kb_key_num_i);
         v_fifo_free  := (fifo_wr_ptr + 1) /= fifo_rd_ptr;
         v_shift_phys := (not key_pressed_n(m65_left_shift)) or
                         (not key_pressed_n(m65_right_shift));

         -- Amiga-side shift suppression is wanted while a shifted-F make is pending
         -- (fwait) or while any F-key sent as its shifted variant is still down
         v_suppress := fwait or shift_hold_hidden
                       or ((not key_pressed_n(m65_f1)) and fkey_shifted(m65_f1))
                       or ((not key_pressed_n(m65_f3)) and fkey_shifted(m65_f3))
                       or ((not key_pressed_n(m65_f5)) and fkey_shifted(m65_f5))
                       or ((not key_pressed_n(m65_f7)) and fkey_shifted(m65_f7))
                       or ((not key_pressed_n(m65_f9)) and fkey_shifted(m65_f9));

         v_shift_des_l := (not key_pressed_n(m65_left_shift))  and (not v_suppress);
         v_shift_des_r := (not key_pressed_n(m65_right_shift)) and (not v_suppress);

         -- a pending shifted-F make goes stale when its key is released or the shift
         -- is let go before consumption (the scanner revisits the key within 1 ms;
         -- without shift the edge is then consumed as a plain unshifted F-key)
         if fwait = '1' and kb_key_num_i = fwait_num then
            if kb_key_pressed_n_i = '1' or v_shift_phys = '0' then
               fwait <= '0';
            end if;
         end if;

         -- Once a shift has been consumed by an F-key substitution, keep the Amiga-side shift
         -- hidden (v_suppress) for as long as the shift stays physically held - it is retracted
         -- once, before the first substituted F-key, and is NOT re-made around each F-key. This
         -- removes the machine-paced shift break/make right after every F-key break, which a raw
         -- CIA keyboard reader can otherwise lose (the F-key break gets overwritten in the single-
         -- byte SDR by the code that immediately follows it). Cleared when no shift is held.
         if v_shift_phys = '0' then
            shift_hold_hidden <= '0';
         end if;

         -- One queued event per cycle, priority: converge the Amiga-side shift keys
         -- first (this is what emits the phantom shift breaks/makes in the right
         -- order relative to the substituted F-key events), then handle the edge of
         -- the key the 1 kHz scanner currently presents. The scanner dwells ~400
         -- cycles per key, so a one-cycle postponement never loses an edge; the
         -- mirror register is only updated when an edge is actually consumed, so
         -- postponed edges are simply retried (same mechanism as the FIFO-full case).
         if shift_l_sent /= v_shift_des_l then
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

            -- shift keys: normally mirror only - their Amiga make/break events are generated by
            -- the convergence logic above. EXCEPTION (issue #10 shift-hang): a shift that was
            -- retracted for an F-key substitution may have had that retract break lost by a slow
            -- raw CIA reader (single-byte SDR overrun). Re-emit the break on the physical release
            -- so the reader clears the key. Alone on the wire in the normal tap-F-key-then-release-
            -- shift gesture; see the SHIFTED F-KEYS header note for the same-sweep-release residual.
            if kb_key_num_i = m65_left_shift or kb_key_num_i = m65_right_shift then
               if kb_key_pressed_n_i = '1' and
                  ((kb_key_num_i = m65_left_shift  and shift_l_consumed = '1') or
                   (kb_key_num_i = m65_right_shift and shift_r_consumed = '1')) then
                  if v_fifo_free then
                     key_pressed_n(kb_key_num_i) <= '1';
                     if kb_key_num_i = m65_left_shift then
                        fifo(to_integer(fifo_wr_ptr)) <= '1' & "1100000";  -- $60 break (Left Shift)
                        shift_l_consumed <= '0';
                     else
                        fifo(to_integer(fifo_wr_ptr)) <= '1' & "1100001";  -- $61 break (Right Shift)
                        shift_r_consumed <= '0';
                     end if;
                     fifo_wr_ptr <= fifo_wr_ptr + 1;
                  end if;
                  -- FIFO full: leave the mirror unchanged so the release edge is retried next sweep
               else
                  key_pressed_n(kb_key_num_i) <= kb_key_pressed_n_i;
               end if;

            -- keys that do not exist on the Amiga only update the mirror
            elsif v_amiga_code = C_NO_KEY then
               key_pressed_n(kb_key_num_i) <= kb_key_pressed_n_i;

            -- shifted-variant F-key make (Shift+F1 = F2 etc.): the Amiga-side shifts
            -- must read as released BEFORE the substituted make is delivered, so the
            -- edge is held back (fwait raises v_suppress, the convergence above queues
            -- the shift breaks) until both sent-shift states are off
            elsif kb_key_pressed_n_i = '0' and f_shiftable_fkey(kb_key_num_i)
                  and v_shift_phys = '1' then
               if shift_l_sent = '0' and shift_r_sent = '0' and v_fifo_free then
                  key_pressed_n(kb_key_num_i)   <= '0';
                  fifo(to_integer(fifo_wr_ptr)) <= '0' & v_amiga_code(6 downto 1) & '1';
                  fifo_wr_ptr                   <= fifo_wr_ptr + 1;
                  fkey_shifted(kb_key_num_i)    <= '1';
                  shift_hold_hidden             <= '1';   -- keep shift hidden for the rest of the hold
                  -- remember which physically-held shift was retracted, so its clearing break
                  -- can be re-emitted on release (the early retract may be lost to SDR overrun)
                  if key_pressed_n(m65_left_shift)  = '0' then shift_l_consumed <= '1'; end if;
                  if key_pressed_n(m65_right_shift) = '0' then shift_r_consumed <= '1'; end if;
                  fwait                         <= '0';
               else
                  fwait     <= '1';
                  fwait_num <= kb_key_num_i;
               end if;

            -- release of an F-key that was sent as its shifted variant: break the SAME
            -- code (base+1), regardless of where the physical shift is by now; the
            -- suppressed shift makes follow one cycle later via the convergence logic
            elsif kb_key_pressed_n_i = '1' and fkey_shifted(kb_key_num_i) = '1' then
               if v_fifo_free then
                  key_pressed_n(kb_key_num_i)   <= '1';
                  fifo(to_integer(fifo_wr_ptr)) <= '1' & v_amiga_code(6 downto 1) & '1';
                  fifo_wr_ptr                   <= fifo_wr_ptr + 1;
                  fkey_shifted(kb_key_num_i)    <= '0';
               end if;

            -- all other Amiga keys: only consume the edge when the event can actually
            -- be queued. If the FIFO is full (practically unreachable), the mirror is
            -- left untouched, so the edge is retried on the next 1 kHz sweep instead
            -- of being lost - losing a RELEASE would leave the key stuck on the Amiga.
            elsif v_fifo_free then
               key_pressed_n(kb_key_num_i) <= kb_key_pressed_n_i;
               -- bit 7 = release flag: key released (kb_key_pressed_n_i = '1') => bit 7 = '1'
               fifo(to_integer(fifo_wr_ptr)) <= kb_key_pressed_n_i & v_amiga_code(6 downto 0);
               fifo_wr_ptr <= fifo_wr_ptr + 1;
            end if;
         end if;

         -- Pace the events towards CIA-A: put the keycode on the data output and toggle
         -- kms_level (the level change is the strobe that ciaa.v reacts to). The data output
         -- is held stable until the next event, as required by ciaa.v's clk7n_en sampling.
         if pace_cnt /= 0 then
            pace_cnt <= pace_cnt - 1;
         elsif fifo_rd_ptr /= fifo_wr_ptr then
            kbd_data    <= fifo(to_integer(fifo_rd_ptr));
            kms_level   <= not kms_level;
            fifo_rd_ptr <= fifo_rd_ptr + 1;
            pace_cnt    <= C_EVENT_PACE;
         end if;

         if reset_i = '1' then
            -- "all keys released": keys (re-)pressed after/during reset generate fresh events
            key_pressed_n <= (others => '1');
            fifo_wr_ptr   <= (others => '0');
            fifo_rd_ptr   <= (others => '0');
            pace_cnt      <= C_RESET_HOLDOFF;
            -- the Amiga side resets too: shift/substitution bookkeeping restarts clean
            fkey_shifted  <= (others => '0');
            shift_l_sent  <= '0';
            shift_r_sent  <= '0';
            fwait         <= '0';
            shift_hold_hidden <= '0';
            shift_l_consumed  <= '0';
            shift_r_consumed  <= '0';
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
