-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_writer: the WRITE front end for the MEGA65 internal floppy
-- drive (WIP-V2-A9). Runs on the 50 MHz front-end clock, like the read
-- chain; all magnetic constants are hardware-proven at exactly this
-- frequency on this mechanism.
--
--   engine tap -> write CDC FIFO (4 deep) -> [this block] -> f_wdata/f_wgate
--
-- A dumb, format-agnostic bit pipe: we never parse what we write, so
-- AmigaDOS tracks, X-Copy images and trackloader formats pass through
-- identically. What this block DOES own is the magnetic and safety
-- discipline the emulated Paula has no concept of:
--
--   * SERIALIZER: one channel bit per 2.000 us cell (C_CELL cycles),
--     MSB-first per word - the mirror of the read aligner's and Paula's
--     shift order. The shift register reloads from the FIFO head in the
--     cycle its last bit leaves (first-word-fall-through: the pop IS the
--     reload), because the <= 3-word-time tail bound of the shallow pipe
--     depends on there being no holding register.
--
--   * WDATA: idle high, one active-LOW pulse of C_WR_PULSE cycles per '1'
--     channel bit, launched at C_WR_LAUNCH within the cell. Registered
--     output, single driver, no combinational path to the pin - the
--     mega65-core lesson (a runt low from any producer becomes a written
--     flux transition; see RESEARCH-write-mega65-core.md section 5.1).
--
--   * WRITE PRECOMPENSATION (ROM-faithful): a 7-channel-bit window whose
--     middle bit is the one being written. A '1' whose gap-BEFORE is
--     shorter than its gap-AFTER launches EARLY, the mirror case LATE,
--     symmetric and invalid-MFM neighborhoods unshifted - textbook peak-
--     shift compensation, the mega65-core f_write_buf table
--     (mfm_bits_to_gaps.vhdl:123-189). ONE uniform magnitude of
--     C_WR_PRECOMP cycles = 140 ns = Paula's PRECOMP0. KS1.3 trackdisk
--     programs exactly this for every track >= 81 (FEA2DA..FEA306); the
--     decision is made ENGINE-side at the episode bind and arrives here as
--     one level. A bit whose window reaches before the episode's first bit
--     or beyond its last one gets NO shift (the explicit boundary rule -
--     zero-filling alone would classify the missing side as a long gap and
--     shift the very first and last pulses).
--
--   * WGATE is defined at the OUTPUT stage: it opens in the cell in which
--     the episode's first bit reaches the pulse generator and closes at the
--     boundary of the cell in which the last bit left it. The window is
--     therefore words x 16 cells EXACTLY, pin to pin, with zero lead-in and
--     zero lead-out cells (a real Paula ends mid-stream; trailing erased
--     cells would put a 4-6 us drought at the end splice).
--
--   * THE TAB QUALIFIER (wr_ok): the PC mechanism drives its outputs only
--     while selected, so /WPROT is meaningful ONLY while sel_i is high, and
--     the first C_SEL_SETTLE after a select edge are ignored. wr_ok is set
--     once wprot_n has read writable for C_WPROT_QUAL of CUMULATIVE
--     SELECTED time; it is cleared by a 4-sample-qualified protected level,
--     by the 4-sample-qualified disk-change ASSERT EDGE (an event, never a
--     level - the mechanism holds /DSKCHG until the next step, and a level
--     would block X-Copy single-drive writes of the same track after a
--     swap) and by reset. Deselect merely PAUSES the accumulator.
--
--   * THE ABORT LATCH: on any gate term lost while streaming, on the
--     engine's abort level or on an underrun, WGATE closes in the SAME
--     cycle and the episode is DEAD - the gate never re-opens until the
--     session has fallen and a new episode arms. A returning gate term, a
--     re-opened engine drain or a re-select cannot resurrect it.
--
--   * DISCARD and ABORTED both keep CONSUMING at cell pace into the bit
--     bucket, so the FIFO keeps draining, the engine's ready keeps cycling,
--     Paula's DMA completes and DSKBLK fires. An aborted episode is a track
--     the Amiga believes written and the disk does not hold - exactly what
--     a real Amiga leaves after a mid-write fault.
--
-- Full design rationale and the verification contract:
-- .research/INTEGRATION-SPEC-hardware-floppy-write.md revision 3.5.
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
    wr_session_i  : in  std_logic;                     -- the trackwr EPISODE
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

    -- diag map 0x000D taps (0x70..0x7C; 0x7D is counted in the core domain)
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
  -- magnetic constants (spec 3.2; mechanism spec 0.2-1.1 us WDATA pulse)
  -----------------------------------------------------------------------------
  constant C_CELL       : natural := C_HALF_CELL_CYC;  -- 100 = 2.000 us
  -- The falling edge IS the flux reversal, so C_WR_LAUNCH places the written
  -- transition inside the cell and C_WR_PULSE only has to be a width the
  -- mechanism reliably registers (spec window 0.2-1.1 us).
  --   LAUNCH at the cell MIDPOINT, like the reference encoder: it gives the
  --   write amplifier a full microsecond to come up after WGATE opens before
  --   the track's first reversal, and leaves 860 ns of headroom to either cell
  --   boundary once precomp has shifted the edge - against 60 ns when the
  --   launch sat at cycle 10.
  --   WIDTH stays 500 ns, i.e. the MIDDLE of the mechanism's window, rather
  --   than the reference's half-cell 988 ns which grazes its upper limit. A
  --   MEGA65 carries a salvaged drive of unknown provenance, so the pulse
  --   sits mid-window by choice; the trailing edge is a don't-care as long as
  --   WDATA is back high before the next launch, and 1500 -> 2000 ns is ample.
  constant C_WR_LAUNCH  : natural := 50;               -- 1000 ns: cell midpoint
  constant C_WR_PULSE   : natural := 25;               -- 500 ns low
  constant C_WR_PRECOMP : natural := 7;                -- 140 ns = PRECOMP0

  -- the tab qualifier (spec 3.3; sy2002-confirmed constants)
  constant C_WPROT_QUAL : natural := 500_000;          -- 10 ms selected time
  constant C_SEL_SETTLE : natural := 2_500;            -- 50 us output settle
  constant C_FILT       : natural := 4;                -- 80 ns revoke filter

  -- the window: index 0 = OLDEST bit, index 6 = NEWEST, written bit = 3.
  -- Gap BEFORE the written bit is read from indices 2/1/0, gap AFTER from
  -- 4/5/6 - the same orientation as the mega65-core f_write_buf table.
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
  signal gate_r    : std_logic := '0';               -- WGATE, active HIGH here

  -- the tab qualifier
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
  -- 0x79 bit 10 must describe the LAST EPISODE, so it is latched like its
  -- four sibling flags. Decoding it from the live FSM state would make it
  -- read 0 in every field dump, because by the time QNICE reads the bank
  -- the writer is long back in IDLE.
  signal discarded : std_logic := '0';

  signal fl_discard : std_logic;
  signal fl_tailcut : std_logic;

begin

  busy_o   <= '0' when state = ST_IDLE else '1';
  wr_ok_o  <= wr_ok_r;
  sess_s_o <= sess_s;

  -- 0x79 = {15:8 flags, 7:0 the episode's track}: bit 8 completed,
  -- 9 aborted, 10 discard, 11 underrun, 12 tail-cut (spec 5.)
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
      -- THE TAB QUALIFIER (spec 3.3)
      ---------------------------------------------------------------------
      sel_p <= sel_i;
      if sel_i = '0' then
        settle <= 0;                              -- deselected: restart the
      elsif sel_p = '0' then                      -- output-enable settle
        settle <= 0;
      elsif settle /= C_SEL_SETTLE then
        settle <= settle + 1;
      end if;

      -- 4-sample filters, sampled only while selected AND settled: the
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
          chg_armed <= '1';                       -- re-arm the EDGE detector
        end if;
      end if;

      -- accumulate cumulative SELECTED time with the tab readable writable
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
      if chg_lo = C_FILT and chg_armed = '1' then -- the change ASSERT EDGE
        chg_armed <= '0';
        wr_ok_r   <= '0';
        qual_cnt  <= 0;
      end if;

      ---------------------------------------------------------------------
      -- gate-term monitoring while streaming
      ---------------------------------------------------------------------
      step_p  <= step_n_i;
      v_term  := '0';
      if state = ST_STREAM then
        if sel_i = '0' then
          v_term := '1'; reason <= x"01";
        elsif mot_i = '0' or en_i = '0' then
          v_term := '1'; reason <= x"02";
        elsif wp_lo = C_FILT then
          v_term := '1'; reason <= x"04";
        elsif chg_lo = C_FILT and chg_armed = '1' then
          v_term := '1'; reason <= x"08";
        elsif step_n_i = '0' and step_p = '1' then
          v_term := '1'; reason <= x"10";
        elsif side_i /= side_lat then
          v_term := '1'; reason <= x"20";
        elsif abrt_s = '1' then
          v_term := '1'; reason <= x"80";
        end if;
      end if;

      ---------------------------------------------------------------------
      -- THE CELL ENGINE: one channel bit per C_CELL cycles
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

          -- FWFT reload: the pop IS the reload (no holding register)
          if v_reload = '1' and fifo_empty_i = '0' then
            sh_reg    <= fifo_data_i;
            sh_cnt    <= 16;
            fifo_rd_o <= '1';
            words_ep  <= words_ep + 1;
            d_words_tot_o <= d_words_tot_o + 1;
          elsif v_reload = '1' and sess_s = '1' and state = ST_STREAM then
            -- THE UNDERRUN, detected at the cell boundary where it happens.
            -- Waiting for the whole 7-cell window to empty would let a dry
            -- spell of 1..6 cells pass as a WGATE deassert followed by a
            -- RE-ASSERT mid-track: an erased hole in the middle of a
            -- written track, with no abort, no reason code and no 0x75.
            v_dry := '1';
          end if;
        else
          cell_cnt <= cell_cnt + 1;
        end if;
      else
        cell_cnt <= 0;
      end if;

      ---------------------------------------------------------------------
      -- PRECOMP + PULSE GENERATION (the output stage; WGATE defined here)
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
        -- short before / long after -> EARLY; the mirror -> LATE
        if v_gap_b < v_gap_a then
          v_shift := -C_WR_PRECOMP;
        else
          v_shift := C_WR_PRECOMP;
        end if;
      end if;

      -- WGATE follows the OUTPUT stage: it is open exactly while the middle
      -- window slot carries a real episode bit, so the window is
      -- words x 16 cells with zero lead-in and zero lead-out cells
      -- WGATE IS the spec-3.3 conjunction, evaluated every cycle - not a
      -- streaming flag that a separate monitor is trusted to revoke. The
      -- v_term monitor below latches the ABORT (so the gate cannot come
      -- back), but the gate itself must fall out of the terms directly:
      -- v_term is blind for the whole C_SEL_SETTLE window after a select
      -- edge, and a wr_ok_r left qualified by a PREVIOUS disk would
      -- otherwise open WGATE on a just-swapped write-protected one.
      if vwin(C_MID) = '1' and abort_lat = '0' and state = ST_STREAM
         and en_i = '1' and sel_i = '1' and mot_i = '1'
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
      -- THE EPISODE FSM
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
          -- 3-words-then-62-us Agnus line burst) AND a qualified tab; an
          -- unqualified episode DISCARDS for its whole duration
          if sess_s = '0' then
            -- The DMA ended before STREAM was ever reached (a <= 1-word
            -- write, or a reset landing in the first microseconds). Go out
            -- through the DRAIN path, not straight to IDLE: whatever the
            -- engine already pushed is still in the CDC FIFO, and jumping
            -- to IDLE would leave it there to be serialized in FRONT of the
            -- next episode's first word - stale flux on a real disk.
            state <= ST_DISCARD;
          elsif fifo_level_i >= 2 then
            -- wr_ok_r alone is not enough: it survives a deselect by design
            -- (the accumulator only PAUSES), so a disk swapped to a
            -- write-protected original while the drive was deselected would
            -- still carry the PREVIOUS disk's qualification through the
            -- first C_SEL_SETTLE after re-selection - exactly the window in
            -- which the revoke filters are frozen because the mechanism is
            -- not driving its outputs yet. Require the settle to have
            -- completed and the live tab reading to be clean in THIS
            -- selection before streaming.
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
            -- WGATE closes in this same cycle (the gate expression above is
            -- gated on abort_lat) and the episode is DEAD
            abort_lat <= '1';
            state     <= ST_ABORTED;
            if sess_s = '0' then
              tail_cut <= tail_cut + 1;           -- lost during the drain
            end if;
          elsif v_dry = '1' then
            -- the serializer ran dry with the DMA still open: UNDERRUN
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
      -- episode-end bookkeeping. TWO DIFFERENT INSTANTS, deliberately:
      --   * 0x77's in-flight residue is sampled at the DSKBLK moment (the
      --     session fall) - that is exactly the question it asks, "how much
      --     flux does the Amiga already believe written but we still hold";
      --   * 0x71 (words consumed) and 0x73/0x74 (the WGATE window) are
      --     latched when the episode really COMPLETES, i.e. when the writer
      --     returns to IDLE. Latching them at the session fall would miss
      --     the tail: the last <= 3 words are consumed AFTER trackwr drops,
      --     so 0x71 would under-report the DMA length by exactly that
      --     residue (caught by S1's words-consumed assert).
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
        -- the instruments reset with the QNICE reset, exactly like the read
        -- chain's counters in physical_fdd_top's ctrl_proc: rst_i is a
        -- power-on-class event here, not an Amiga reboot
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
