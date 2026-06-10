---------------------------------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- amiga_config: One-time hardware configuration of the Minimig core via its userio IO protocol
--
-- On MiSTer, the ARM HPS configures Minimig at boot time through an SPI-like bus that ends up at
-- minimig.v's host port (IO_UIO, IO_STROBE, IO_DIN, IO_WAIT). The MEGA65 has no HPS, so this small
-- FSM replays the configuration sequence after every M2M reset, leaving rtl/userio.v completely
-- UNTOUCHED. It configures: A500 OCS PAL chipset, 68000 CPU, 512KB Chip + 512KB Slow + 0 Fast RAM,
-- bootloader video defaults, 1 floppy drive, no IDE, default joysticks, default audio mix - and
-- finally releases the CPU so that the 68000 boots from the (M2M-preloaded) Kickstart ROM.
--
-- This module runs entirely in the clk_main (28.375 MHz) domain, the same clock that drives
-- minimig.v's "clk" input.
--
-- =======================================================================================================
-- The userio.v IO protocol (all references to CORE/Minimig_MiSTerMEGA65 sources)
-- =======================================================================================================
--
-- Receiver clocking (rtl/userio.v:431-500): the command/config receiver is a plain
-- "always @(posedge clk)" block running at the FULL 28 MHz bus clock. It is NOT paced by clk7_en;
-- the only clk7_en-gated part is the host-RAM write handshake of command 0xF0 (userio.v:493-497),
-- which we never use. Therefore this FSM needs NO clk7_en/clk7n_en inputs.
--
-- Framing (userio.v:445-451): whenever IO_ENA (= minimig port IO_UIO, minimig.v:547) is low at a
-- posedge clk, the protocol state (has_cmd, bcnt, btoggle, IO_WAIT) is cleared. One single clock of
-- IO_ENA low is sufficient as a framing gap between transfers; we are far more generous.
--
-- Word transfer (userio.v:452-468): EVERY posedge clk at which IO_STROBE is high consumes one
-- 16-bit word from IO_DIN. Consequences for this FSM:
--   * io_strobe_o must be high for EXACTLY ONE clk_main cycle per word (a longer pulse would be
--     consumed as multiple words),
--   * io_din_o must be stable at the very clock edge at which io_strobe_o is high.
--   * Word 0 of a transfer (has_cmd=0) latches the command from IO_DIN[7:0]; the upper byte is
--     ignored (userio.v:454).
--   * Payload words are only evaluated when cmd[7:4]==4'hF (userio.v:455), i.e. for commands
--     0xF0..0xF9. For the config commands 0xF1..0xF9 only the FIRST payload word (bcnt==0) is used
--     (userio.v:456-468); any further payload words are ignored. We send exactly one payload word.
--   * IO_WAIT is only ever raised by the 0xF0 host-memory-write path (userio.v:483-487); for our
--     config commands it stays 0. We nevertheless honor io_wait_i before each strobe for
--     robustness (minimig.v:363-367 ORs userio's and paula's IO_WAIT; paula's IO_ENA = IO_FPGA is
--     tied to 0 in our port, so paula never raises it either).
--
-- Command set (userio.v:418-430, comments verbatim from the source):
--   0xF1  reset_ctrl_sel  : {cpuhlt, cpurst, usrrst} <= IO_DIN[2:0]        (userio.v:459)
--   0xF2  aud_sel         : aud_mix <= IO_DIN[1:0]                         (userio.v:467)
--   0xF3  chip_cfg_sel    : t_chipset_config <= IO_DIN[4:0]  "XXXGEANT"    (userio.v:460)
--   0xF4  cpu_cfg_sel     : t_cpu_config <= IO_DIN[4:0]      "XXXXKCTT"    (userio.v:461)
--   0xF5  memory_cfg_sel  : t_memory_config <= IO_DIN[7:0]   "XHFFSSCC"    (userio.v:462)
--   0xF6  video_cfg_sel   : {blver,ar,scanline} <= {IO_DIN[11:8],IO_DIN[2:0]} (userio.v:463)
--   0xF7  floppy_cfg_sel  : floppy_config <= IO_DIN[3:0]                   (userio.v:464)
--   0xF8  harddisk_cfg_sel: t_ide_config <= IO_DIN[5:0]                    (userio.v:465)
--   0xF9  joystick_cfg_sel: {joy_swap,cd32pad,joy_ana_en}                  (userio.v:466)
--
-- Memory config 0xF5, encoding "XHFFSSCC" (userio.v:426), VERIFIED against the consumers:
--   CC = chip RAM size, memory_config[1:0]: minimig_bankmapper.v:33-37 -> 00 = 0.5M CHIP,
--        01 = 1.0M, 10 = 1.5M, 11 = 2.0M. We need CC=00 (512KB chip).
--   SS = slow RAM size, memory_config[3:2]: gary.v:166-168 -> SS=01 enables only sel_slow[0]
--        ($C00000-$C7FFFF = 512KB); bit3 would add $C80000-$CFFFFF etc. We need SS=01.
--   FF = fast RAM size, memory_config[5:4]: 00 = none.
--   H  = HRTmon enable, memory_config[6]: 0.
--   => payload 0x0004. This is MANDATORY: the power-on default t_memory_config is
--   8'b0_0_00_01_01 (userio.v:391) which means 1MB chip + 512KB slow - NOT our hardware layout.
--
-- =======================================================================================================
-- The reset/latching window - why the sequence below is guaranteed to take effect
-- =======================================================================================================
--
-- The t_* shadow registers written by commands 0xF3/0xF4/0xF5/0xF8 are copied into the live config
-- registers (chipset_config, cpu_config, memory_config[5:0]+[7], ide_config) ONLY while userio's
-- "reset" input is active (userio.v:396-411; cache_config and memory_config[6] are copied
-- unconditionally, userio.v:413-416). That reset input is wired to (minimig.v:408,529):
--
--      reset = sys_reset | ~_cpu_reset_in
--
-- CAUTION - a subtle trap: _cpu_reset_in is NOT minimig's CPU reset output (_cpu_reset). It is the
-- 68000's own "reset out" (Minimig.sv:533-534 wires it to cpu_wrapper's reset_out; for the fx68k
-- path that is oRESETn, cpu_wrapper.v:161-180/233-243). fx68k asserts oRESETn ONLY while the CPU
-- executes a RESET instruction (fx68k.sv:383-397) - NEVER during external reset. So driving
-- cpurst=1 via command 0xF1 does NOT keep userio's reset active (it only holds the CPU itself in
-- reset via _cpu_reset, minimig.v:911-918).
--
-- The only reset source the FSM can rely on is sys_reset from minimig_syscontrol.v:29-35:
--   * sys_reset is 1 while mrst = usrrst | rst_ext is asserted (minimig.v:841), and stays 1 for
--     4 more "sof" frame pulses (~80 ms PAL) after mrst is released (3-bit rst_cnt, counting on
--     clk7_en & sof).
--   * sof keeps pulsing even while reset is asserted, because Agnus' beam counters have no reset
--     term and free-run (hpos: agnus_beamcounter.v:255-264, vpos: agnus_beamcounter.v:300-314,
--     eof: agnus_beamcounter.v:351-354, wired to sof at agnus.v:472). So the 4-frame countdown
--     reliably elapses and the system comes out of reset on its own.
--
-- Strategy of this FSM (deviating deliberately from MiSTer's plain "cpuhlt+cpurst" first command):
--   1. First command is 0xF1 with payload 3'b111 = cpuhlt=1, cpurst=1 AND usrrst=1. usrrst forces
--      mrst=1 -> rst_cnt=0 -> sys_reset=1 (minimig_syscontrol.v:31), i.e. WE hold the latching
--      window open ourselves, independent of how long ago rst_ext (driven from the M2M reset in
--      main.vhd) was released and independent of how long this FSM takes. usrrst has no other
--      effect in this core (only consumer: minimig.v:841). cpuhlt+cpurst additionally keep the
--      CPU halted exactly like MiSTer's HPS does during configuration.
--   2. All config commands are sent while usrrst=1, so every t_* value is continuously copied
--      into the live registers.
--   3. The final command 0xF1 payload 3'b000 releases usrrst/cpurst/cpuhlt. minimig_syscontrol
--      then still holds sys_reset for 4 more frames (~80 ms) - during which the already-written
--      t_* values keep latching - and only then releases the system: _cpu_reset goes high
--      (minimig.v:911-918), OVL is set (minimig.v:845-849), and the 68000 fetches its reset
--      vectors from the Kickstart overlay. (Without usrrst the sequence would still work, since
--      the FSM finishes in ~200 us, far inside the ~80 ms window that starts when rst_ext falls -
--      but with usrrst the guarantee is unconditional.)
--
-- cpu_reset_done_o goes high once the complete sequence including the CPU release command has been
-- sent (note: the CPU actually starts ~4 frames later, after minimig_syscontrol's countdown).
--
-- Integration notes for main.vhd:
--   * io_uio_o    -> minimig IO_UIO,    io_strobe_o -> minimig IO_STROBE,
--     io_din_o    -> minimig IO_DIN,    io_wait_i   <- minimig IO_WAIT.
--   * minimig IO_FPGA must be tied to '0' (no floppy/HDD host transfers in milestone 1).
--   * reset_i must be the same M2M core reset that drives minimig's rst_ext, so that the
--     sequence reruns after every core reset.
--
-- MiSTer2MEGA65 (AExp Amiga 500 port) done in June 2026 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amiga_config is
   generic (
      -- clk_main cycles to wait after reset_i releases before starting the sequence
      -- (gives minimig's internal clocking/reset network time to settle; not strictly required
      -- by userio.v, whose receiver is reset-independent - purely defensive)
      G_START_DELAY : natural := 1023;

      -- clk_main cycles between protocol steps (framing gap, ENA-to-strobe setup, word spacing).
      -- userio.v would accept 1 cycle for each of them; boot time is irrelevant, so be generous.
      G_STEP_DELAY  : natural := 63
   );
   port (
      clk_main_i       : in  std_logic;                     -- 28.375 MHz core clock (= minimig clk)
      reset_i          : in  std_logic;                     -- M2M core reset, active high, synchronous

      -- Minimig host/userio port (minimig.v:214-218)
      io_uio_o         : out std_logic;                     -- minimig IO_UIO  (userio IO_ENA)
      io_strobe_o      : out std_logic;                     -- minimig IO_STROBE, 1 clk per word
      io_din_o         : out std_logic_vector(15 downto 0); -- minimig IO_DIN
      io_wait_i        : in  std_logic;                     -- minimig IO_WAIT (always 0 for our cmds)

      -- Status: complete sequence (incl. CPU release cmd 0xF1/0x0000) has been sent. For LED/debug.
      cpu_reset_done_o : out std_logic
   );
end entity amiga_config;

architecture synthesis of amiga_config is

   -- One configuration transfer = command word + one payload word
   type t_cfg_entry is record
      cmd     : std_logic_vector(7 downto 0);
      payload : std_logic_vector(15 downto 0);
   end record t_cfg_entry;

   type t_cfg_seq is array (natural range <>) of t_cfg_entry;

   -- The configuration sequence: see the header comment for the why of each value
   constant C_SEQ : t_cfg_seq := (
      0 => (cmd => x"F1", payload => x"0007"),  -- cpuhlt=1 cpurst=1 usrrst=1: halt CPU, hold sys_reset
      1 => (cmd => x"F3", payload => x"0000"),  -- chipset "XXXGEANT" = 0: OCS, A500 (not A1000), PAL
      2 => (cmd => x"F4", payload => x"0000"),  -- cpu "XXXXKCTT" = 0: 68000, no cache, no fast-kick
      3 => (cmd => x"F5", payload => x"0004"),  -- memory "XHFFSSCC" = 0x04: 512K chip, 512K slow,
                                                --   0 fast, no HRTmon (default 0x05 = 1M chip!)
      4 => (cmd => x"F6", payload => x"0000"),  -- video: blver=0 (Agnus hbl), ar=0, scanline=0
      5 => (cmd => x"F7", payload => x"0000"),  -- floppy: 1 drive (floppy_config[3:2]=00), normal speed
      6 => (cmd => x"F8", payload => x"0000"),  -- harddisk: no IDE controller, no master/slave HDD
      7 => (cmd => x"F9", payload => x"0000"),  -- joystick: no swap, no CD32 pads, no analog
      8 => (cmd => x"F2", payload => x"0000"),  -- audio mix = 00 (full stereo separation)
      9 => (cmd => x"F1", payload => x"0000")   -- release usrrst/cpurst/cpuhlt: 4 frames later the
                                                --   68000 boots from Kickstart via the OVL overlay
   );

   type t_state is (
      ST_RESET,        -- reset_i active: everything idle
      ST_START_WAIT,   -- settle delay after reset release
      ST_GAP,          -- IO_ENA low: framing gap, userio protocol state cleared (userio.v:445-451)
      ST_CMD,          -- IO_ENA high, IO_DIN = command word, wait, then strobe (1 clk pulse)
      ST_PAYLOAD,      -- IO_DIN = payload word, wait, then strobe (1 clk pulse)
      ST_TAIL,         -- keep IO_ENA high briefly after the last strobe, then drop it
      ST_DONE          -- sequence complete, wait for next reset_i
   );

   -- pure function instead of VHDL-2008 "maximum" for broadest tool compatibility
   pure function f_max(a : natural; b : natural) return natural is
   begin
      if a > b then
         return a;
      else
         return b;
      end if;
   end function f_max;

   signal state : t_state := ST_RESET;
   signal idx   : natural range 0 to C_SEQ'high := 0;                         -- current transfer
   signal cnt   : natural range 0 to f_max(G_START_DELAY, G_STEP_DELAY) := 0; -- pacing down-counter

begin

   fsm_proc : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         -- default: io_strobe_o is a registered one-clock pulse; it is set in exactly one
         -- delta below and cleared here on the very next clock edge
         io_strobe_o <= '0';

         case state is

            -- M2M core reset active: keep the bus idle. userio sees IO_ENA=0 and clears its
            -- protocol state every clock (userio.v:445-451).
            when ST_RESET =>
               io_uio_o         <= '0';
               io_din_o         <= (others => '0');
               cpu_reset_done_o <= '0';
               idx              <= 0;
               cnt              <= G_START_DELAY;
               if reset_i = '0' then
                  state <= ST_START_WAIT;
               end if;

            -- settle delay after reset release
            when ST_START_WAIT =>
               if cnt /= 0 then
                  cnt <= cnt - 1;
               else
                  cnt   <= G_STEP_DELAY;
                  state <= ST_GAP;
               end if;

            -- framing gap with IO_ENA low before each transfer; on exit raise IO_ENA together
            -- with the command word on IO_DIN (strobed >= G_STEP_DELAY clocks later)
            when ST_GAP =>
               io_uio_o <= '0';
               if cnt /= 0 then
                  cnt <= cnt - 1;
               else
                  io_uio_o <= '1';
                  io_din_o <= x"00" & C_SEQ(idx).cmd;   -- command byte in IO_DIN[7:0] (userio.v:454)
                  cnt      <= G_STEP_DELAY;
                  state    <= ST_CMD;
               end if;

            -- command word phase: IO_DIN holds the command; after the pacing delay issue a
            -- single-clock strobe (userio latches cmd <= IO_DIN[7:0] at that edge, userio.v:452-454)
            when ST_CMD =>
               if cnt /= 0 then
                  cnt <= cnt - 1;
               elsif io_wait_i = '0' then
                  io_strobe_o <= '1';                    -- 1-clk pulse; IO_DIN still = command word
                  cnt         <= G_STEP_DELAY;
                  state       <= ST_PAYLOAD;
               end if;

            -- payload word phase: switch IO_DIN to the payload (this happens on the same edge
            -- that ends the command strobe, i.e. only AFTER userio has sampled the command);
            -- after the pacing delay issue the payload strobe (latched at bcnt=0, userio.v:456-468)
            when ST_PAYLOAD =>
               io_din_o <= C_SEQ(idx).payload;
               if cnt /= 0 then
                  cnt <= cnt - 1;
               elsif io_wait_i = '0' then
                  io_strobe_o <= '1';                    -- 1-clk pulse; IO_DIN = payload word
                  cnt         <= G_STEP_DELAY;
                  state       <= ST_TAIL;
               end if;

            -- keep IO_ENA high for a moment after the payload strobe, then drop it to close
            -- the transfer; advance to the next entry or finish
            when ST_TAIL =>
               if cnt /= 0 then
                  cnt <= cnt - 1;
               else
                  io_uio_o <= '0';
                  if idx = C_SEQ'high then
                     state <= ST_DONE;
                  else
                     idx   <= idx + 1;
                     cnt   <= G_STEP_DELAY;
                     state <= ST_GAP;
                  end if;
               end if;

            -- all transfers sent, CPU release command included; minimig_syscontrol now counts
            -- down 4 sof frames (~80 ms PAL) before the 68000 starts (minimig_syscontrol.v:29-35)
            when ST_DONE =>
               cpu_reset_done_o <= '1';

         end case;

         -- synchronous reset dominates everything: rerun the sequence after every M2M reset
         if reset_i = '1' then
            state <= ST_RESET;
         end if;
      end if;
   end process fsm_proc;

end architecture synthesis;
