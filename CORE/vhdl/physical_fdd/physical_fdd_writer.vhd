-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_writer: the write front end for the MEGA65 internal floppy
-- drive. Runs on the 50 MHz front-end clock, like the read chain; the
-- constants below are verified on this mechanism at this frequency.
--
--   engine tap -> write CDC FIFO (4 deep) -> [this block] -> f_wdata/f_wgate
--
-- A format-agnostic bit pipe: nothing parses what is written, so AmigaDOS
-- tracks, X-Copy images and trackloader formats pass through identically.
-- The block owns the magnetic and safety discipline that the simulated
-- Paula has no concept of:
--
--   * Serializer: one channel bit per 2.000 us cell (C_CELL cycles),
--     MSB-first per word, the mirror of the shift order of the read aligner
--     and of Paula. The shift register reloads from the FIFO head in the
--     cycle its last bit leaves (first-word-fall-through: the pop is the
--     reload). A holding register would add one more word to the flux that
--     is still unwritten when Paula signals DSKBLK, which the shallow pipe
--     bounds to 3 word times.
--
--   * WDATA: idle high, one active-low pulse of C_WR_PULSE cycles per '1'
--     channel bit, launched at C_WR_LAUNCH within the cell. The output is
--     registered, with a single driver and no combinational path to the
--     pin, because a runt low from any source is written as a flux
--     transition.
--
--   * Write precompensation (magnitude and track threshold as Kickstart
--     programs them): a 7-channel-bit window whose middle bit is the one
--     being written. A '1' whose gap before is shorter than its gap after
--     launches early, the mirror case late; symmetric and invalid-MFM
--     neighbourhoods are not shifted. This is textbook peak-shift
--     compensation, the f_write_buf table of mega65-core
--     mfm_bits_to_gaps.vhdl, with one magnitude: C_WR_PRECOMP cycles =
--     140 ns = Paula's PRECOMP0. KS1.3 trackdisk programs it for
--     every track >= 81 (ROM $FEA2DA..$FEA306); the engine decides at the
--     episode bind and the decision arrives here as one level. A bit whose
--     window reaches before the first bit of the episode or beyond its last
--     one is not shifted: zero-filling alone would classify the missing
--     side as a long gap and shift the very first and last pulses.
--
--   * WGATE is defined at the output stage: it opens in the cell in which
--     the first bit of the episode reaches the pulse generator and closes
--     at the boundary of the cell in which the last bit left it. The window
--     is therefore words x 16 cells, pin to pin, with no lead-in and no
--     lead-out cells: a real Paula ends mid-stream, and trailing erased
--     cells would leave a 4-6 us drought at the end splice.
--
--   * Write-protect qualifier (wr_ok): the PC mechanism drives its outputs
--     only while selected, so /WPROT is read only while sel_i is high, and
--     not during the first C_SEL_SETTLE after a select edge. wr_ok is set
--     once wprot_n has read writable for C_WPROT_QUAL of cumulative
--     selected time. It is cleared by a protected level that persists for
--     C_FILT samples, by the assert edge of /DSKCHG through the same
--     filter, and by reset. The disk change counts as an event, not a
--     level: the mechanism holds /DSKCHG until the next step, and a level
--     would block X-Copy single-drive writes, which swap disks and rewrite
--     the same track. Deselect only pauses the accumulator.
--
--   * Abort latch: a gate term lost while streaming, the abort level of the
--     engine or an underrun closes WGATE within one clock and ends the
--     episode as aborted. The gate stays shut until the session has fallen
--     and a new episode arms; a returning gate term, a re-opened engine
--     drain or a re-select cannot reopen it.
--
--   * Discarded and aborted episodes keep consuming words at cell pace with
--     the gate shut, so the FIFO drains, the engine keeps popping, Paula's
--     DMA completes and DSKBLK fires. The Amiga then believes the track
--     written while the disk does not hold it, which is also what a real
--     Amiga leaves after a mid-write fault.
--
-- Design and safety rationale: doc/developers/hardware-floppy.md, section 6
-- (The write datapath).
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity physical_fdd_writer is
  port (
    clk_i         : in  std_logic;                     -- 50 MHz front end
    rst_i         : in  std_logic;                     -- QNICE reset

    -- drive context, already synchronized into this domain by the top
    en_i          : in  std_logic;                     -- physical unit exists
    sel_i         : in  std_logic;                     -- our /SEL asserted
    mot_i         : in  std_logic;                     -- motor latch on
    side_i        : in  std_logic;                     -- SIDE line
    step_n_i      : in  std_logic;                     -- /STEP pin mirror
    wprot_n_i     : in  std_logic;                     -- conditioned /WPROT
    change_n_i    : in  std_logic;                     -- conditioned /DSKCHG

    -- engine levels (core clock domain; 2-FF synchronized here)
    wr_session_i  : in  std_logic;                     -- trackwr episode level
    wr_abort_i    : in  std_logic;                     -- episode abort level
    wr_precomp_i  : in  std_logic;                     -- precomp active
    wr_track_i    : in  std_logic_vector(7 downto 0);  -- episode track (diag)
    wr_precmode_i : in  std_logic_vector(1 downto 0);  -- 0x7C mode readback

    -- write CDC FIFO, read side
    fifo_empty_i  : in  std_logic;
    fifo_data_i   : in  std_logic_vector(15 downto 0);
    fifo_level_i  : in  unsigned(2 downto 0);          -- rd_level_o
    fifo_rd_o     : out std_logic := '0';

    -- connector pins (registered; both idle high)
    f_wdata_o     : out std_logic := '1';
    f_wgate_o     : out std_logic := '1';

    -- status towards the top / engine
    busy_o        : out std_logic := '0';              -- writer not IDLE
    wr_ok_o       : out std_logic := '0';              -- tab qualified
    sess_s_o      : out std_logic := '0';              -- synced episode level

    -- diagnostics taps, registers 0x70..0x7C (0x7D is counted in the core
    -- domain)
    d_epi_cnt_o    : out unsigned(15 downto 0) := (others => '0');
    d_words_last_o : out unsigned(15 downto 0) := (others => '0');
    d_words_tot_o  : out unsigned(15 downto 0) := (others => '0');
    d_wgate_lo_o   : out unsigned(15 downto 0) := (others => '0');
    d_wgate_hi_o   : out unsigned(15 downto 0) := (others => '0');
    d_underrun_o   : out unsigned(15 downto 0) := (others => '0');
    d_discard_o    : out unsigned(15 downto 0) := (others => '0');
    d_tail_o       : out unsigned(15 downto 0) := (others => '0');
    d_precnt_o     : out unsigned(15 downto 0) := (others => '0');
    d_flags79_o    : out std_logic_vector(15 downto 0) := (others => '0');
    d_gateopen_o   : out unsigned(15 downto 0) := (others => '0');
    d_reason_o     : out std_logic_vector(7 downto 0) := (others => '0');
    d_ctrl7c_o     : out std_logic_vector(4 downto 0) := (others => '0')
  );
end entity physical_fdd_writer;

architecture rtl of physical_fdd_writer is

  -----------------------------------------------------------------------------
  -- Magnetic constants. The mechanism accepts WDATA pulses of 0.2 to 1.1 us.
  -----------------------------------------------------------------------------
  constant C_CELL       : natural := C_HALF_CELL_CYC;  -- 100 = 2.000 us
  -- The falling edge is the flux reversal, so C_WR_LAUNCH places the written
  -- transition inside the cell and C_WR_PULSE only has to be a width the
  -- mechanism reliably registers.
  --   Launch at the cell midpoint, like the mega65-core encoder: the write
  --   amplifier gets a full microsecond after WGATE opens before the first
  --   reversal of the track, and an edge moved by precomp still keeps 860 ns
  --   to either cell boundary.
  --   The 500 ns width sits in the middle of the mechanism window. The
  --   half-cell pulse of mega65-core (988 ns) is close to its upper limit,
  --   and a MEGA65 may carry a salvaged drive of unknown provenance. The
  --   trailing edge does not matter as long as WDATA is high again before
  --   the next launch, and the pulse ends at most 1640 ns into the 2000 ns
  --   cell.
  constant C_WR_LAUNCH  : natural := 50;               -- 1000 ns: cell midpoint
  constant C_WR_PULSE   : natural := 25;               -- 500 ns low
  constant C_WR_PRECOMP : natural := 7;                -- 140 ns = PRECOMP0

  -- write-protect qualifier
  constant C_WPROT_QUAL : natural := 500_000;          -- 10 ms selected time
  constant C_SEL_SETTLE : natural := 2_500;            -- 50 us output settle
  constant C_FILT       : natural := 4;                -- 80 ns revoke filter

  -- the precomp window: index 0 = oldest bit, index 6 = newest, written
  -- bit = 3. The gap before the written bit is read from indices 2/1/0, the
  -- gap after from 4/5/6, the same orientation as the mega65-core
  -- f_write_buf table.
  constant C_WIN : natural := 7;
  constant C_MID : natural := 3;

  type t_state is (ST_IDLE, ST_ARM, ST_STREAM, ST_DISCARD, ST_ABORTED);
  signal state : t_state := ST_IDLE;

  -- synchronizers for the engine levels (core -> 50 MHz)
  signal sess_m, sess_s   : std_logic := '0';
  signal sess_p           : std_logic := '0';
  signal abrt_m, abrt_s   : std_logic := '0';
  signal prec_m, prec_s   : std_logic := '0';
  attribute async_reg             : string;
  attribute async_reg of sess_m   : signal is "true";
  attribute async_reg of abrt_m   : signal is "true";
  attribute async_reg of prec_m   : signal is "true";

  -- serializer
  signal cell_cnt : natural range 0 to C_CELL - 1 := 0;
  signal sh_reg   : std_logic_vector(15 downto 0) := (others => '0');
  signal sh_cnt   : natural range 0 to 16 := 0;      -- bits left in sh_reg
  signal win      : std_logic_vector(C_WIN - 1 downto 0) := (others => '0');
  signal vwin     : std_logic_vector(C_WIN - 1 downto 0) := (others => '0');
  signal pulse_cnt : natural range 0 to C_WR_PULSE := 0;
  signal gate_r    : std_logic := '0';               -- WGATE, active high here

  -- write-protect qualifier
  signal qual_cnt  : natural range 0 to C_WPROT_QUAL := 0;
  signal settle    : natural range 0 to C_SEL_SETTLE := 0;
  signal sel_p     : std_logic := '0';
  signal wp_lo     : natural range 0 to C_FILT := 0;
  signal chg_lo    : natural range 0 to C_FILT := 0;
  signal chg_armed : std_logic := '1';               -- change edge detector
  signal wr_ok_r   : std_logic := '0';

  -- gate terms and episode bookkeeping
  signal step_p    : std_logic := '1';
  signal side_lat  : std_logic := '0';
  signal abort_lat : std_logic := '0';
  signal reason    : std_logic_vector(7 downto 0) := (others => '0');
  signal words_ep  : unsigned(15 downto 0) := (others => '0');
  signal wg_cyc    : unsigned(31 downto 0) := (others => '0');
  signal tail_cut  : unsigned(7 downto 0) := (others => '0');
  signal tail_max  : unsigned(7 downto 0) := (others => '0');
  signal completed : std_logic := '0';
  signal did_gate  : std_logic := '0';
  -- 0x79 bit 10 describes the last episode, so it is latched like its four
  -- sibling flags. Decoded from the live FSM state it would read 0 in every
  -- dump, because the writer is back in IDLE long before QNICE reads the
  -- bank.
  signal discarded : std_logic := '0';

  signal fl_discard : std_logic;
  signal fl_tailcut : std_logic;

begin

  busy_o   <= '0' when state = ST_IDLE else '1';
  wr_ok_o  <= wr_ok_r;
  sess_s_o <= sess_s;

  -- 0x79 = {15:8 flags, 7:0 the track of the episode}: bit 8 completed,
  -- 9 aborted, 10 discard, 11 underrun, 12 tail cut
  fl_discard <= discarded;
  fl_tailcut <= '0' when tail_cut = 0 else '1';
  d_flags79_o <= "000" & fl_tailcut & reason(6) & fl_discard & abort_lat
                 & completed & wr_track_i;
  d_ctrl7c_o  <= sess_s & wr_ok_r & prec_s & wr_precmode_i;
  d_reason_o  <= reason;
  d_tail_o    <= tail_max & tail_cut;

  main : process (clk_i)
    variable v_gap_b  : natural range 1 to 4;
    variable v_gap_a  : natural range 1 to 4;
    variable v_bit    : std_logic;
    variable v_shift  : integer range -C_WR_PRECOMP to C_WR_PRECOMP;
    variable v_inflt  : natural;
    variable v_term   : std_logic;
    variable v_hold   : std_logic;   -- post-DSKBLK drain hold
    variable v_reload : std_logic;
    variable v_dry    : std_logic;
  begin
    if rising_edge(clk_i) then
      ---------------------------------------------------------------------
      -- synchronizers (always run)
      ---------------------------------------------------------------------
      sess_m <= wr_session_i;  sess_s <= sess_m;  sess_p <= sess_s;
      abrt_m <= wr_abort_i;    abrt_s <= abrt_m;
      prec_m <= wr_precomp_i;  prec_s <= prec_m;

      fifo_rd_o <= '0';
      v_dry     := '0';

      ---------------------------------------------------------------------
      -- write-protect qualifier
      ---------------------------------------------------------------------
      sel_p <= sel_i;
      if sel_i = '0' then
        settle <= 0;                              -- deselected: restart the
      elsif sel_p = '0' then                      -- output-enable settle
        settle <= 0;
      elsif settle /= C_SEL_SETTLE then
        settle <= settle + 1;
      end if;

      -- 4-sample filters, sampled only while selected and settled: the
      -- mechanism does not drive its outputs otherwise
      if sel_i = '1' and settle = C_SEL_SETTLE then
        if wprot_n_i = '0' then
          if wp_lo /= C_FILT then
            wp_lo <= wp_lo + 1;
          end if;
        else
          wp_lo <= 0;
        end if;
        if change_n_i = '0' then
          if chg_lo /= C_FILT then
            chg_lo <= chg_lo + 1;
          end if;
        else
          chg_lo    <= 0;
          chg_armed <= '1';                       -- re-arm the edge detector
        end if;
      end if;

      -- accumulate selected time while the tab reads writable
      if sel_i = '1' and settle = C_SEL_SETTLE and wprot_n_i = '1'
         and wp_lo = 0 then
        if qual_cnt /= C_WPROT_QUAL then
          qual_cnt <= qual_cnt + 1;
        else
          wr_ok_r <= '1';
        end if;
      end if;

      -- revocations
      if wp_lo = C_FILT then                      -- qualified protected level
        wr_ok_r  <= '0';
        qual_cnt <= 0;
      end if;
      if chg_lo = C_FILT and chg_armed = '1' then -- the change assert edge
        chg_armed <= '0';
        wr_ok_r   <= '0';
        qual_cnt  <= 0;
      end if;

      ---------------------------------------------------------------------
      -- gate-term monitoring while streaming
      ---------------------------------------------------------------------
      -- Post-DSKBLK drain hold: once the session has fallen, the Amiga
      -- already believes the track written, and the up to 3 word times
      -- still in the pipe must reach the disk. A select or side change then
      -- no longer aborts (X-Copy toggles SIDE about 30 us after DSKBLK);
      -- mega65.vhd holds f_selecta_o and f_side1_o at their episode values
      -- over a window that contains this one. Every other term stays live,
      -- step included: writing across a seek smears the tail over two
      -- cylinders. While sel_i is low the tab and change filters pause and
      -- the settle counter restarts, for at most the length of the drain. See
      -- doc/developers/hardware-floppy.md, section 6.5 (The post-DSKBLK
      -- drain hold).
      v_hold := '0';
      if state = ST_STREAM and sess_s = '0' then
        v_hold := '1';
      end if;

      step_p  <= step_n_i;
      v_term  := '0';
      if state = ST_STREAM then
        if sel_i = '0' and v_hold = '0' then
          v_term := '1'; reason <= x"01";
        elsif mot_i = '0' or en_i = '0' then
          v_term := '1'; reason <= x"02";
        elsif wp_lo = C_FILT then
          v_term := '1'; reason <= x"04";
        elsif chg_lo = C_FILT and chg_armed = '1' then
          v_term := '1'; reason <= x"08";
        elsif step_n_i = '0' and step_p = '1' then
          v_term := '1'; reason <= x"10";
        elsif side_i /= side_lat and v_hold = '0' then
          v_term := '1'; reason <= x"20";
        elsif abrt_s = '1' then
          v_term := '1'; reason <= x"80";
        end if;
      end if;

      ---------------------------------------------------------------------
      -- cell engine: one channel bit per C_CELL cycles
      ---------------------------------------------------------------------
      if state = ST_STREAM or state = ST_DISCARD or state = ST_ABORTED then
        if cell_cnt = C_CELL - 1 then
          cell_cnt <= 0;

          -- shift the precomp window: the newest bit enters at the top
          v_reload := '0';
          if sh_cnt /= 0 then
            v_bit := sh_reg(15);
            sh_reg <= sh_reg(14 downto 0) & '0';
            sh_cnt <= sh_cnt - 1;
            if sh_cnt = 1 then
              v_reload := '1';                    -- last bit leaves now
            end if;
            win  <= v_bit & win(C_WIN - 1 downto 1);
            vwin <= '1' & vwin(C_WIN - 1 downto 1);
          else
            win  <= '0' & win(C_WIN - 1 downto 1);
            vwin <= '0' & vwin(C_WIN - 1 downto 1);
            v_reload := '1';
          end if;

          -- FWFT reload: the pop is the reload (no holding register)
          if v_reload = '1' and fifo_empty_i = '0' then
            sh_reg    <= fifo_data_i;
            sh_cnt    <= 16;
            fifo_rd_o <= '1';
            words_ep  <= words_ep + 1;
            d_words_tot_o <= d_words_tot_o + 1;
          elsif v_reload = '1' and sess_s = '1' and state = ST_STREAM then
            -- Underrun, detected at the cell boundary where it happens.
            -- Waiting for the whole 7-cell window to empty would let a dry
            -- spell of 1..6 cells close WGATE and open it again mid-track:
            -- an erased hole in a written track, with no abort, no reason
            -- code and no count in 0x75.
            v_dry := '1';
          end if;
        else
          cell_cnt <= cell_cnt + 1;
        end if;
      else
        cell_cnt <= 0;
      end if;

      ---------------------------------------------------------------------
      -- precomp and pulse generation (the output stage, where WGATE is
      -- defined)
      ---------------------------------------------------------------------
      -- gap classes around the written bit, from the window
      if win(2) = '1' then v_gap_b := 1;
      elsif win(1) = '1' then v_gap_b := 2;
      elsif win(0) = '1' then v_gap_b := 3;
      else v_gap_b := 4; end if;
      if win(4) = '1' then v_gap_a := 1;
      elsif win(5) = '1' then v_gap_a := 2;
      elsif win(6) = '1' then v_gap_a := 3;
      else v_gap_a := 4; end if;

      v_shift := 0;
      if prec_s = '1' and vwin = (vwin'range => '1')
         and v_gap_b /= 1 and v_gap_a /= 1 and v_gap_b /= v_gap_a then
        -- short before / long after -> early; the mirror -> late
        if v_gap_b < v_gap_a then
          v_shift := -C_WR_PRECOMP;
        else
          v_shift := C_WR_PRECOMP;
        end if;
      end if;

      -- WGATE follows the output stage: it is open while the middle window
      -- slot carries a real episode bit, so the window is words x 16 cells
      -- with no lead-in and no lead-out cells. The gate is the full
      -- conjunction of its terms, evaluated every cycle, rather than a
      -- streaming flag that the v_term monitor is trusted to revoke. The
      -- monitor latches the abort, so the gate cannot come back, but its
      -- tab and change filters are frozen for C_SEL_SETTLE after a select
      -- edge, and a wr_ok_r left qualified by a previous disk would
      -- otherwise open WGATE on a just-swapped write-protected one. During
      -- the drain hold v_hold stands in for sel_i: mega65.vhd keeps
      -- f_selecta_o asserted, so the mechanism is still selected although
      -- the host has moved on. See doc/developers/hardware-floppy.md,
      -- section 6.4 (Safety: WGATE, the tab qualifier and the read chain).
      if vwin(C_MID) = '1' and abort_lat = '0' and state = ST_STREAM
         and en_i = '1' and (sel_i = '1' or v_hold = '1') and mot_i = '1'
         and wr_ok_r = '1' then
        gate_r    <= '1';
        f_wgate_o <= '0';
        wg_cyc    <= wg_cyc + 1;
        if did_gate = '0' then
          did_gate     <= '1';
          d_gateopen_o <= d_gateopen_o + 1;
        end if;
      else
        gate_r    <= '0';
        f_wgate_o <= '1';
      end if;

      -- one active-low pulse per '1' bit, at the (possibly shifted) launch
      if pulse_cnt /= 0 then
        pulse_cnt <= pulse_cnt - 1;
        if pulse_cnt = 1 then
          f_wdata_o <= '1';
        end if;
      end if;
      if gate_r = '1' and win(C_MID) = '1' and vwin(C_MID) = '1'
         and cell_cnt = (C_WR_LAUNCH + v_shift) then
        f_wdata_o <= '0';
        pulse_cnt <= C_WR_PULSE;
        if v_shift /= 0 then
          d_precnt_o <= d_precnt_o + 1;
        end if;
      end if;

      ---------------------------------------------------------------------
      -- episode FSM
      ---------------------------------------------------------------------
      case state is

        when ST_IDLE =>
          if sess_s = '1' and sess_p = '0' then
            -- a new episode binds: clear the per-episode state
            state       <= ST_ARM;
            abort_lat   <= '0';
            reason      <= (others => '0');
            words_ep    <= (others => '0');
            wg_cyc      <= (others => '0');
            tail_cut    <= (others => '0');
            tail_max    <= (others => '0');
            completed   <= '0';
            discarded   <= '0';
            did_gate    <= '0';
            side_lat    <= side_i;
            win         <= (others => '0');
            vwin        <= (others => '0');
            sh_cnt      <= 0;
            d_precnt_o  <= (others => '0');
            d_epi_cnt_o <= d_epi_cnt_o + 1;
          end if;

        when ST_ARM =>
          -- STREAM needs two buffered words (so the serializer rides out the
          -- 3-words-then-62-us Agnus line burst) and a qualified tab; an
          -- unqualified episode discards for its whole duration
          if sess_s = '0' then
            -- The DMA ended before STREAM was reached (a write of at most
            -- one word, or a reset in the first microseconds). Leave through
            -- ST_DISCARD, not straight to IDLE: words the engine already
            -- pushed are still in the CDC FIFO, and from IDLE they would be
            -- serialized in front of the first word of the next episode,
            -- stale flux on a real disk.
            state <= ST_DISCARD;
          elsif fifo_level_i >= 2 then
            -- wr_ok_r alone is not enough: it survives a deselect (the
            -- accumulator only pauses), so a disk swapped for a
            -- write-protected original while the drive was deselected would
            -- carry the qualification of the previous disk through the
            -- first C_SEL_SETTLE after re-selection, the window in which
            -- the revoke filters are frozen because the mechanism is not
            -- yet driving its outputs. Streaming therefore also requires a
            -- completed settle and a clean live tab reading in this
            -- selection.
            if wr_ok_r = '1' and en_i = '1' and sel_i = '1'
               and mot_i = '1' and settle = C_SEL_SETTLE and wp_lo = 0 then
              state <= ST_STREAM;
            else
              state       <= ST_DISCARD;
              discarded   <= '1';
              d_discard_o <= d_discard_o + 1;
            end if;
          end if;

        when ST_STREAM =>
          if v_term = '1' then
            -- abort_lat keeps WGATE shut from the next clock on (the gate
            -- expression includes it); the episode stays aborted
            abort_lat <= '1';
            state     <= ST_ABORTED;
            if sess_s = '0' then
              tail_cut <= tail_cut + 1;           -- lost during the drain
            end if;
          elsif v_dry = '1' then
            -- the serializer ran dry with the DMA still open: underrun
            abort_lat    <= '1';
            reason       <= x"40";
            d_underrun_o <= d_underrun_o + 1;
            state        <= ST_ABORTED;
          elsif fifo_empty_i = '1' and sh_cnt = 0
                and vwin = (vwin'range => '0') and sess_s = '0' then
            completed <= '1';                     -- the normal tail is done
            state     <= ST_IDLE;
          end if;

        when ST_DISCARD | ST_ABORTED =>
          -- keep consuming at cell pace so the engine keeps draining Paula
          -- and DSKBLK fires; the gate stays shut for the whole episode
          if sess_s = '0' and fifo_empty_i = '1' and sh_cnt = 0 then
            state <= ST_IDLE;
          end if;

      end case;

      ---------------------------------------------------------------------
      -- episode-end bookkeeping, at two different instants:
      --   * the in-flight residue (0x77) is sampled at the session fall,
      --     the DSKBLK moment: it measures the flux the Amiga already
      --     believes written that the pipe still holds;
      --   * words consumed (0x71) and the WGATE window (0x73/0x74) are
      --     latched when the writer returns to IDLE. At the session fall
      --     they would miss the tail: up to 3 words are consumed after
      --     trackwr drops, and 0x71 would under-report the DMA length by
      --     that residue.
      ---------------------------------------------------------------------
      if sess_s = '0' and sess_p = '1' then
        v_inflt := to_integer(fifo_level_i);
        if sh_cnt /= 0 then
          v_inflt := v_inflt + 1;
        end if;
        tail_max <= to_unsigned(v_inflt, 8);
      end if;
      if state /= ST_IDLE and sess_s = '0' and fifo_empty_i = '1'
         and sh_cnt = 0 then
        d_words_last_o <= words_ep;
        d_wgate_lo_o   <= wg_cyc(15 downto 0);
        d_wgate_hi_o   <= wg_cyc(31 downto 16);
      end if;

      ---------------------------------------------------------------------
      if rst_i = '1' then
        state      <= ST_IDLE;
        f_wgate_o  <= '1';
        f_wdata_o  <= '1';
        gate_r     <= '0';
        pulse_cnt  <= 0;
        cell_cnt   <= 0;
        sh_cnt     <= 0;
        win        <= (others => '0');
        vwin       <= (others => '0');
        abort_lat  <= '0';
        wr_ok_r    <= '0';
        qual_cnt   <= 0;
        settle     <= 0;
        wp_lo      <= 0;
        chg_lo     <= 0;
        chg_armed  <= '1';
        reason     <= (others => '0');
        completed  <= '0';
        discarded  <= '0';
        did_gate   <= '0';
        fifo_rd_o  <= '0';
        -- the instruments reset with the QNICE reset, like the read-chain
        -- counters in ctrl_proc of physical_fdd_top: rst_i is a power-on
        -- class event here, not an Amiga reboot
        words_ep      <= (others => '0');
        wg_cyc        <= (others => '0');
        tail_cut      <= (others => '0');
        tail_max      <= (others => '0');
        d_epi_cnt_o    <= (others => '0');
        d_words_last_o <= (others => '0');
        d_words_tot_o  <= (others => '0');
        d_wgate_lo_o   <= (others => '0');
        d_wgate_hi_o   <= (others => '0');
        d_underrun_o   <= (others => '0');
        d_discard_o    <= (others => '0');
        d_precnt_o     <= (others => '0');
        d_gateopen_o   <= (others => '0');
      end if;
    end if;
  end process main;

end architecture rtl;
