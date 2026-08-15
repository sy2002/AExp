-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_bits: DD-MFM read pipeline, stage 3 of 3 (Amiga-specific, new):
-- gap class -> raw channel-bit reconstruction -> DSKSYNC bit alignment ->
-- 16-bit word assembly.
--
-- Unlike the C64MEGA65 physical-1581 decoder (which decodes DATA bits, bytes,
-- sector fields and CRCs in hardware), the Amiga needs the RAW channel-bit
-- stream: Minimig's Paula consumes pre-encoded, word-aligned 16-bit MFM words
-- and all decoding happens in Amiga software (trackdisk or the loader). This
-- stage therefore reconstructs exactly what a real data separator delivers:
--
--   * Each accepted gap of n channel cells (n = 2/3/4) is (n-1) '0' channel
--     bits followed by a '1' (the flux transition). The bits are shifted
--     MSB-first into a 16-bit register, exactly like Paula's own serial
--     shifter.
--   * WORD ALIGNMENT: whenever the 16 most recent channel bits equal the
--     live DSKSYNC value (sync_i, captured from Paula by the track engine),
--     the register is emitted as a word and the bit counter restarts - from
--     here on words leave this stage sync-aligned, and they re-align on
--     EVERY subsequent sync match (drift correction at sector boundaries).
--     The sync word itself is emitted too: Paula's WORDSYNC gate drops the
--     first matching word and stores from the next one, so an Amiga MFM
--     sector's double 0x4489 behaves exactly as with the virtual-ADF stream.
--     A 16-bit full compare is structurally stronger than any per-gap
--     qualifier, and a false match merely shifts alignment until the next
--     true sync (self-healing; Paula word-compares the stream again).
--     sync_i = 0x0000 disables alignment (free-running word phase - the
--     "WORDSYNC off" semantic of real hardware, where the phase is
--     undefined anyway).
--   * FRAMING HOLD (frame_hold_i = '1'): word framing FREE-RUNS - a sync
--     match still reports sync_hit_o (and realign_evt_o when it lands
--     mid-word) but neither resets the bit counter nor emits early. This
--     reproduces what a real Paula delivers under WORDSYNC=0, where the
--     capture carries ONE constant framing for its whole length: KS1.3
--     trackdisk clears WORDSYNC and its software decoder absorbs a
--     CONSTANT splice framing shift through its 16-entry rotation tables
--     plus the gap re-hunt's own shift - but it can NOT decode a stream
--     whose framing re-anchors at every sync, because the once-per-rev
--     write-splice slip then becomes a rotation-inconsistent seam
--     ([old-framing gap run][hybrid word][word-aligned sync]) that
--     matches none of its tables: TDERR $1A/$17 on every attempt whose
--     anchor is not the first-written sector (proven RED in BOTH
--     separator modes by tb_fdd_splice, the E2 experiment of the
--     2026-08-15 audit). The top asserts frame_hold_i while the engine
--     serves words past its serve-start sync AND live WORDSYNC is 0;
--     during the pre-serve hunt alignment stays active (that is what
--     makes serve-from-sync work), and under WORDSYNC=1 (X-Copy, most
--     trackloaders) realignment stays active too - matching real Paula,
--     which does re-sync its shifter per matching word in that mode.
--     With frame_hold_i = '0' this stage is bit-identical to the
--     realign-always behavior.
--   * Loss of lock (gap class "11") clears the pending bits and the bit
--     counter: a loud resync, mirroring the C64 pipeline.
--   * FLUX DROUGHT: when no transition arrives for C_DROUGHT_ARM_CYC cycles
--     (beyond the longest legal gap), one '0' channel bit is synthesized per
--     nominal cell time, like a real separator idling over unformatted
--     media - so Paula's DMA keeps seeing a bitstream instead of stalling
--     harder than real hardware would. The next real edge yields an
--     oversized gap = class "11" = resync, so filler bits never corrupt
--     locked data.
--
-- Bit pacing within this stage is NOT real-time (the up-to-4 bits of a gap
-- are shifted in back-to-back cycles); real-time pacing is inherent in the
-- gap ARRIVAL times, which is what defines the word cadence (~32 us/word).
--
-- WIP-V2-A5: the stage carries a SECOND bit source, a counter-based digital
-- PLL data separator (design + field rationale in physical_fdd_pkg.vhd),
-- selected at runtime by dpll_en_i. It consumes the runt-filtered edge
-- events directly (edge_valid_i, from the gaps stage) and emits one channel
-- bit per tracked cell in real time - '1' when an edge fell into the cell.
-- No classification, no loss-of-lock resync, no drought filler needed: a
-- wild interval degrades one bit position locally and the PLL re-centers
-- within a few edges, while the 16-bit DSKSYNC compare downstream keeps
-- doing the structural qualification. With dpll_en_i = '0' this stage is
-- BIT-IDENTICAL to the shipped A4 behavior (the legacy branches are
-- untouched); the quantiser output remains connected in both modes so
-- lol_o keeps reporting what the legacy classifier would reject and the
-- diag margin instrumentation measures identically either way.
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity physical_fdd_bits is
  port (
    clk_i        : in  std_logic;
    rst_i        : in  std_logic;
    gap_valid_i  : in  std_logic;
    gap_class_i  : in  unsigned(1 downto 0);
    sync_i       : in  std_logic_vector(15 downto 0);  -- live DSKSYNC (settled); 0x0000 = free-run
    -- DPLL separator (see header): runtime select + the runt-filtered edge
    -- event stream from the GAPS stage (one pulse per accepted flux edge,
    -- constant pipeline delay - a constant phase offset the PLL absorbs)
    dpll_en_i    : in  std_logic := '0';
    edge_valid_i : in  std_logic := '0';
    dpll_cell_o  : out unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);
    -- '1' = hold the word framing (no realign on sync matches - the real
    -- WORDSYNC=0 Paula behavior; see FRAMING HOLD in the header)
    frame_hold_i : in  std_logic := '0';
    word_valid_o : out std_logic := '0';               -- 1-clk pulse
    word_o       : out std_logic_vector(15 downto 0) := (others => '0');
    sync_hit_o   : out std_logic := '0';               -- diag: 1-clk pulse per sync match
    -- diag: 1-clk pulse per sync match landing mid-word (bit_cnt /= 15) =
    -- a framing seam event: a realignment (taken when frame_hold_i = '0',
    -- suppressed when '1'), with the framing remainder it arrived at
    realign_evt_o : out std_logic := '0';
    realign_rem_o : out unsigned(3 downto 0) := (others => '0');
    lol_o        : out std_logic := '0'                -- diag: 1-clk pulse per loss of lock
  );
end entity physical_fdd_bits;

architecture rtl of physical_fdd_bits is

  -- pending channel bits of the current gap, emitted LSB-first:
  -- class c loads 2**(c+1), i.e. (c+1) zeros followed by the '1'
  signal pend_sr     : std_logic_vector(3 downto 0) := (others => '0');
  signal pend_cnt    : unsigned(2 downto 0) := (others => '0');

  -- channel-bit shifter (MSB-first: first-arrived bit ends up in bit 15)
  signal sr          : std_logic_vector(15 downto 0) := (others => '0');
  signal bit_cnt     : unsigned(3 downto 0) := (others => '0');

  -- flux-drought zero synthesis
  signal drought_cnt : natural range 0 to C_DROUGHT_ARM_CYC := 0;

  -- DPLL separator state (Q4 fixed point like the quantiser: 16 units =
  -- one 50 MHz cycle). phase_q advances 16/cycle and wraps at cell_q; an
  -- edge pulls the phase toward the window center and nudges the period.
  signal phase_q     : unsigned(12 downto 0) := (others => '0');
  signal cell_q      : unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);
  signal pend_edge   : std_logic := '0';     -- an edge fell into the current cell

begin

  dpll_cell_o <= cell_q;

  process (clk_i)
    variable v_bit    : std_logic;
    variable v_emit   : std_logic;
    variable v_new_sr : std_logic_vector(15 downto 0);
    variable v_phase  : unsigned(13 downto 0);
    variable v_pend   : std_logic;
    variable v_err    : signed(14 downto 0);
    variable v_cell   : signed(14 downto 0);
  begin
    if rising_edge(clk_i) then
      -- pulses default low
      word_valid_o  <= '0';
      sync_hit_o    <= '0';
      realign_evt_o <= '0';
      lol_o         <= '0';

      if rst_i = '1' then
        pend_sr     <= (others => '0');
        pend_cnt    <= (others => '0');
        sr          <= (others => '0');
        bit_cnt     <= (others => '0');
        drought_cnt <= 0;
        phase_q     <= (others => '0');
        cell_q      <= to_unsigned(C_QUANT_EST_NOM_Q, cell_q'length);
        pend_edge   <= '0';
      else
        v_emit := '0';
        v_bit  := '0';

        if dpll_en_i = '1' then
          ---------------------------------------------------------------
          -- DPLL bit source (see header + pkg). One boundary per cycle
          -- at most (cell >= 90 cycles, tick = 1 cycle); after an edge
          -- correction the phase sits in [cell/4 .. 3*cell/4] + one tick,
          -- always below cell, so an edge never emits in its own cycle -
          -- its '1' leaves at the next boundary.
          ---------------------------------------------------------------
          v_phase := resize(phase_q, v_phase'length) + 16;
          v_pend  := pend_edge;
          if edge_valid_i = '1' then
            v_pend := '1';
            -- err = phase - cell/2, the edge's offset from the window
            -- center; phase -= err/2 lands at phase/2 + cell/4
            v_err   := signed(resize(v_phase, v_err'length))
                       - signed(resize(cell_q(11 downto 1), v_err'length));
            v_phase := resize(unsigned(
                         signed(resize(v_phase, v_err'length))
                         - shift_right(v_err, C_DPLL_PGAIN)), v_phase'length);
            -- period tracking, hard-clamped to the quantiser's +/-10% span
            v_cell := signed(resize(cell_q, v_cell'length))
                      + shift_right(v_err, C_DPLL_FGAIN);
            if v_cell < to_signed(C_QUANT_EST_MIN_Q, v_cell'length) then
              cell_q <= to_unsigned(C_QUANT_EST_MIN_Q, cell_q'length);
            elsif v_cell > to_signed(C_QUANT_EST_MAX_Q, v_cell'length) then
              cell_q <= to_unsigned(C_QUANT_EST_MAX_Q, cell_q'length);
            else
              cell_q <= unsigned(v_cell(cell_q'range));
            end if;
          end if;
          if v_phase >= resize(cell_q, v_phase'length) then
            v_phase := v_phase - resize(cell_q, v_phase'length);
            v_emit  := '1';
            v_bit   := v_pend;
            v_pend  := '0';
          end if;
          phase_q   <= resize(v_phase, phase_q'length);
          pend_edge <= v_pend;

          -- diagnostic only: what the legacy classifier would have
          -- rejected (keeps cnt_lol/scoreboard semantics comparable
          -- across the A/B) - no resync happens in DPLL mode
          if gap_valid_i = '1' and gap_class_i = "11" then
            lol_o <= '1';
          end if;

        -- legacy bit source: BIT-IDENTICAL to the shipped A4 behavior
        -- 1) new gap event dominates (physically >= 16 cycles apart, while
        --    the pending queue drains in at most 4 - see the gaps stage)
        elsif gap_valid_i = '1' then
          drought_cnt <= 0;
          if gap_class_i = "11" then
            -- loss of lock: loud resync
            pend_cnt <= (others => '0');
            bit_cnt  <= (others => '0');
            lol_o    <= '1';
          else
            pend_sr  <= std_logic_vector(
                          shift_left(to_unsigned(1, 4), to_integer(gap_class_i) + 1));
            pend_cnt <= resize(gap_class_i, 3) + 2;    -- (c+1) zeros + one '1'
          end if;

        -- 2) drain one pending channel bit per clock
        elsif pend_cnt /= 0 then
          v_bit    := pend_sr(0);
          v_emit   := '1';
          pend_sr  <= '0' & pend_sr(3 downto 1);
          pend_cnt <= pend_cnt - 1;

        -- 3) flux drought: synthesize '0' cells at the nominal rate
        else
          if drought_cnt = C_DROUGHT_ARM_CYC then
            v_bit       := '0';
            v_emit      := '1';
            drought_cnt <= C_DROUGHT_ARM_CYC - C_DROUGHT_CELL_CYC;
          else
            drought_cnt <= drought_cnt + 1;
          end if;
        end if;

        -- shift the emitted bit in, MSB-first; a sync match dominates the
        -- 16-bit rollover so words re-align on every DSKSYNC occurrence -
        -- unless the framing is held (frame_hold_i: real-Paula WORDSYNC=0
        -- behavior, see the header), in which case the match is only
        -- reported and the free-running rollover keeps the word phase
        if v_emit = '1' then
          v_new_sr := sr(14 downto 0) & v_bit;
          sr <= v_new_sr;
          if sync_i /= x"0000" and v_new_sr = sync_i then
            sync_hit_o <= '1';
            if bit_cnt /= 15 then
              realign_evt_o <= '1';
              realign_rem_o <= bit_cnt;
            end if;
            if frame_hold_i = '0' or bit_cnt = 15 then
              word_o       <= v_new_sr;
              word_valid_o <= '1';
              bit_cnt      <= (others => '0');
            else
              bit_cnt <= bit_cnt + 1;
            end if;
          elsif bit_cnt = 15 then
            word_o       <= v_new_sr;
            word_valid_o <= '1';
            bit_cnt      <= (others => '0');
          else
            bit_cnt <= bit_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
