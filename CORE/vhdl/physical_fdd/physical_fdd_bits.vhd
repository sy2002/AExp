-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_bits: DD-MFM read pipeline, stage 3 of 3 (Amiga-specific):
-- channel-bit reconstruction -> DSKSYNC word alignment -> 16-bit word
-- assembly.
--
-- Unlike the C64MEGA65 physical-1581 decoder, which decodes data bits,
-- bytes, sector fields and CRCs in hardware, the Amiga needs the raw
-- channel-bit stream: Minimig's Paula consumes pre-encoded 16-bit MFM words,
-- and all decoding happens in Amiga software (trackdisk or the loader). This
-- stage therefore delivers what a real data separator delivers.
--
-- Two bit sources, selected at run time by dpll_en_i (diagnostics register
-- 0x35 bit 6; see doc/developers/hardware-floppy.md, section 4.3 (Two data
-- separators)):
--   * Digital PLL, the default. It consumes the runt-filtered edge events of
--     the gap stage (edge_valid_i) and emits one channel bit per tracked cell
--     in real time, '1' when an edge fell into the cell. Nothing is
--     classified and nothing resyncs: a wild interval degrades one bit
--     position and the loop re-centres within a few edges. The algorithm and
--     its constants are described in physical_fdd_pkg.vhd.
--   * Legacy. Each accepted gap of n channel cells (class n = 2/3/4) becomes
--     (n-1) '0' bits followed by a '1' (the flux transition), shifted in on
--     back-to-back cycles; real-time pacing comes from the gap arrival times
--     (~32 us per word). A loss of lock (gap class "11") clears the pending
--     bits and the bit counter, a loud resync. In a flux drought (no
--     transition for C_DROUGHT_ARM_CYC cycles) one '0' is synthesized per
--     nominal cell, like a real separator idling over unformatted media, so
--     Paula's DMA keeps receiving words. The next real edge yields an
--     oversized gap, a loss of lock, so filler bits never corrupt locked
--     data.
-- The quantiser stays connected in both modes, so lol_o reports what the
-- legacy classifier rejects and the margin instruments in physical_fdd_top
-- measure the same way in either mode.
--
-- Word alignment: the bits are shifted MSB-first into a 16-bit register,
-- like Paula's own shifter. When the 16 most recent bits equal the live
-- DSKSYNC value (sync_i, captured from Paula by the track engine), the
-- register is emitted as a word and the bit counter restarts, so the words
-- leave this stage sync-aligned and re-align at every later sync match
-- unless the framing hold is engaged. The sync word itself is emitted, as on
-- the ADF path: with WORDSYNC set, Paula drops the first matching word and
-- stores from the next one, so the double 0x4489 of a sector leaves one sync
-- word in the buffer; with WORDSYNC clear (Kickstart 1.3 trackdisk) Paula
-- stores every word. A false match only shifts the framing until the next
-- true sync. sync_i = 0x0000 disables alignment, and the word phase
-- free-runs.
--
-- Framing hold (frame_hold_i = '1'): a sync match is still reported on
-- sync_hit_o (and on realign_evt_o when it lands mid-word) but neither
-- restarts the bit counter nor emits early, so the word framing free-runs
-- like a real Paula under WORDSYNC=0, whose capture carries one constant
-- framing. trackdisk absorbs the constant framing shift at the write splice
-- with its rotation tables, but it cannot decode a stream that re-frames at
-- every sync: the once-per-revolution splice slip then becomes a seam that
-- matches none of its tables, and every attempt whose anchor is not the
-- first-written sector fails with trackdisk error $1A or $17.
-- physical_fdd_top asserts the hold while the engine serves words past its
-- serve-start sync and WORDSYNC is 0. With frame_hold_i = '0' the stage
-- realigns on every match. See doc/developers/hardware-floppy.md, section
-- 4.4 (The aligner and the framing hold).
--
-- Diagnostic word stream (dword_valid_o/dword_o): a second framing counter
-- over the same shift register that always realigns on a sync match,
-- regardless of frame_hold_i. The capture instruments in physical_fdd_top
-- consume it: while the hold is engaged the served stream free-runs across
-- the write splice, and a capture following that framing would read every
-- post-splice sector misframed. Reset, a loss of lock in legacy mode (the
-- DPLL never resyncs; in DPLL mode a loss of lock only pulses lol_o) and
-- every sync match that restarts the served framing clear both counters
-- together, so the two streams are identical until a sync match lands
-- mid-word under the hold, and stay apart until the next common clear.
-- Nothing mixes them: the capture path reads only the diagnostic stream,
-- and only from a sync hit on. The served stream (word_valid_o/word_o into
-- the FIFO) is the same in every mode.
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
    -- event stream from the gap stage (one pulse per accepted flux edge,
    -- constant pipeline delay - a constant phase offset the PLL absorbs)
    dpll_en_i    : in  std_logic := '0';
    edge_valid_i : in  std_logic := '0';
    dpll_cell_o  : out unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);
    -- '1' = hold the word framing (no realign on sync matches, like a real
    -- Paula under WORDSYNC=0; see Framing hold in the header)
    frame_hold_i : in  std_logic := '0';
    word_valid_o : out std_logic := '0';               -- 1-clk pulse
    word_o       : out std_logic_vector(15 downto 0) := (others => '0');
    -- diagnostic word stream: always sync-realigned framing over the same
    -- bits, for the capture instruments (see Diagnostic word stream in the
    -- header); identical to word_valid_o/word_o until a sync match lands
    -- mid-word under the hold
    dword_valid_o : out std_logic := '0';              -- 1-clk pulse
    dword_o       : out std_logic_vector(15 downto 0) := (others => '0');
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

  -- diagnostic framing counter over the same shifter: always realigns on a
  -- sync match (see Diagnostic word stream in the header). Reset, a
  -- legacy-mode LOL and every sync match clear it; bit_cnt is cleared along
  -- with it except by a mid-word sync match under the hold, which is the
  -- only event that makes the two counters diverge (until the next common
  -- clear).
  signal dbit_cnt    : unsigned(3 downto 0) := (others => '0');

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
      dword_valid_o <= '0';
      sync_hit_o    <= '0';
      realign_evt_o <= '0';
      lol_o         <= '0';

      if rst_i = '1' then
        pend_sr     <= (others => '0');
        pend_cnt    <= (others => '0');
        sr          <= (others => '0');
        bit_cnt     <= (others => '0');
        dbit_cnt    <= (others => '0');
        drought_cnt <= 0;
        phase_q     <= (others => '0');
        cell_q      <= to_unsigned(C_QUANT_EST_NOM_Q, cell_q'length);
        pend_edge   <= '0';
      else
        v_emit := '0';
        v_bit  := '0';

        if dpll_en_i = '1' then
          ---------------------------------------------------------------
          -- DPLL bit source (see the header and the pkg). One boundary per
          -- cycle at most (cell >= 90 cycles, tick = 1 cycle); after an edge
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
          -- rejected (keeps the cnt_lol and scoreboard figures comparable
          -- between the two modes); no resync happens in DPLL mode
          if gap_valid_i = '1' and gap_class_i = "11" then
            lol_o <= '1';
          end if;

        -- legacy bit source
        -- 1) new gap event dominates (physically >= 16 cycles apart, while
        --    the pending queue drains in at most 4 - see the gaps stage)
        elsif gap_valid_i = '1' then
          drought_cnt <= 0;
          if gap_class_i = "11" then
            -- loss of lock: loud resync
            pend_cnt <= (others => '0');
            bit_cnt  <= (others => '0');
            dbit_cnt <= (others => '0');
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
        -- 16-bit rollover so words re-align on every DSKSYNC occurrence,
        -- unless the framing is held (frame_hold_i, the behaviour of a real
        -- Paula under WORDSYNC=0, see the header): then the match is only
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

          -- diagnostic framing: always realigns on a sync match, so the
          -- capture instruments read correctly framed words even while the
          -- served framing is held across the write splice. Same shift
          -- register, own counter.
          if sync_i /= x"0000" and v_new_sr = sync_i then
            dword_o       <= v_new_sr;
            dword_valid_o <= '1';
            dbit_cnt      <= (others => '0');
          elsif dbit_cnt = 15 then
            dword_o       <= v_new_sr;
            dword_valid_o <= '1';
            dbit_cnt      <= (others => '0');
          else
            dbit_cnt <= dbit_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
