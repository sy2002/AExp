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
-- if it maps to an Amiga key - an event is pushed into a small FIFO. The FIFO is drained with
-- send-then-wait-for-acknowledge FLOW CONTROL, exactly as a real Amiga keyboard blocks on the CPU
-- handshake before shifting out the next code: a code goes on kbd_mouse_data_o (bit 7 = release
-- flag) with a kms_level_o toggle, and the NEXT code is held back until a minimum 1 ms gap has
-- elapsed AND the Amiga has consumed the current code - signalled by kbd_ack_i, a CPU read of the
-- keycode SDR ($BFEC01) - or a ~143 ms deadlock timeout fires. This never overwrites the
-- single-byte CIA-A SDR before the reader has taken the previous code, for ANY reader speed: a
-- fast reader (Kickstart's interrupt-driven keyboard.device) still paces at the 1 ms floor, a
-- slow raw-CIA reader (e.g. VATestprogram's keyboard test) is paced at its own read rate, and a
-- non-reading consumer is released by the timeout instead of deadlocking. The 1 ms floor also
-- covers the ~14 us worst-case spacing of two MEGA65 key edges within one scan sweep. See the
-- "Pacing" constants and the pacer process below for the exact mechanism (rising-edge ack detect
-- plus a settling blackout). After reset, the first event is additionally held back for 100 ms,
-- because minimig_syscontrol.v stretches the internal reset by 4 frames (~80 ms PAL) - events sent
-- earlier would be swallowed by CIA-A's reset and keys held down during a core reset would get lost.
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
--   press edge is held back until the Amiga-side shifts read released), and the shift MAKE codes
--   are re-queued only AFTER the F2 break - the Amiga never sees a shift qualifier together with a
--   substituted F-key. The keyboard handshake (kbd_ack_i flow control) delivers this retract/
--   re-make pair reliably, so a raw CIA keyboard reader (e.g. VATestprogram's serial keyboard
--   test) sees every code - the substituted F-keys are never stuck and the shift is never left
--   hanging, on any reader speed.
-- * The substituted code is latched per key (fkey_shifted), so releasing shift before the F-key
--   still sends the matching F2 break - no stuck keys.
-- * Consequences, by design: Shift+F2 (etc.) cannot be typed (the shift is consumed by the
--   substitution - same as on any C64-style keyboard); pressing shift WHILE an unshifted
--   F1 is already held simply types Shift+F1 (no substitution after the fact); while a
--   substituted F-key is held, the shift qualifier is hidden for ALL keys (inherent to
--   phantom-shift suppression - shifted characters resume when the F-key is released);
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

-- Pacing of the keycode events towards CIA-A. Send-then-wait-for-acknowledge flow control,
-- exactly as a real Amiga keyboard blocks on the CPU handshake before shifting the next code:
-- an event is emitted only once a minimum gap has elapsed AND the previous code has been
-- consumed (the Amiga read the keycode SDR, kbd_ack_i) - or a deadlock timeout fires. This never
-- overwrites an unread SDR for any reader speed - it fixes the single-byte-SDR overrun that a raw
-- CIA reader like VATestprogram is subject to - yet stays as fast as a pure 1 ms pace for a fast
-- reader (Kickstart's interrupt-driven keyboard.device):
--   * min-gap = C_EVENT_PACE (1 ms): a conservative floor so a very fast reader can never make us
--     overwhelm keyboard.device; keeps normal-typing latency identical to the old fixed 1 ms pace.
--   * ack     = one CIA read of SDR $BFEC01 (kbd_ack_i). On the bus a read is a cck-gated level, so
--     kbd_ack_i can appear as several clk_main pulses within one read; the pacer coalesces them into
--     a single acknowledge (arm/idle-debounce) and blacks out the sdr_latch settling window after a
--     send (see the pacer process). This makes the pacing ADAPTIVE: a fast reader acks within the
--     floor => 1 ms pacing; a slow reader acks later => we wait for it; no overrun either way.
--   * timeout = C_ACK_TIMEOUT (~143 ms, the real keyboard's resync window): a deadlock ceiling so
--     a consumer that never reads the SDR (interrupts off, between resets) cannot wedge the
--     keyboard. Only ever reached by a genuinely non-reading consumer; the code is dropped, not
--     retransmitted, on expiry (acceptable for a synthetic keyboard).
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

-- Flow-control pacer state (see the pacing note in the header and C_ACK_* above):
signal ack_seen      : std_logic := '1';   -- current code consumed (1 = ready to send the next)
signal to_cnt        : natural range 0 to C_ACK_TIMEOUT := 0;  -- deadlock timeout countdown
signal kbd_ack_d     : std_logic := '0';   -- 1-cycle history of kbd_ack_i for rising-edge detect
signal ack_guard     : natural range 0 to C_ACK_GUARD := 0;    -- post-send ack blackout countdown
signal ack_armed     : std_logic := '0';   -- '1' = ready to accept the next read's ack (one per read)
signal ack_low_cnt   : natural range 0 to C_ACK_SETTLE := 0;   -- kbd_ack_i low-time (read-end debounce)

-- shifted F-key substitution state (see "SHIFTED F-KEYS" in the header):
-- fkey_shifted(k)='1': key k's make was sent as its shifted variant (base+1) - the
-- matching break must use the same code, and the Amiga-side shifts stay suppressed
-- while any such key is down. Only the five F-key positions are ever set.
signal fkey_shifted  : std_logic_vector(79 downto 0) := (others => '0');
signal shift_l_sent  : std_logic := '0';   -- shift state as the Amiga currently believes it
signal shift_r_sent  : std_logic := '0';
signal fwait         : std_logic := '0';   -- shifted-F make pending, waiting for shift breaks
signal fwait_num     : integer range 0 to 79 := 0;

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
         v_suppress := fwait
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

            -- shift keys: mirror only - their Amiga make/break events are generated by the
            -- convergence logic above (from physical state minus suppression). Under the keyboard
            -- handshake the retract-before/re-make-after shift codes around a substituted F-key
            -- are delivered reliably, so no release-time re-emit compensation is needed here.
            if kb_key_num_i = m65_left_shift or kb_key_num_i = m65_right_shift then
               key_pressed_n(kb_key_num_i) <= kb_key_pressed_n_i;

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
            -- the Amiga side resets too: shift/substitution bookkeeping restarts clean
            fkey_shifted  <= (others => '0');
            shift_l_sent  <= '0';
            shift_r_sent  <= '0';
            fwait         <= '0';
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
