----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- M2M-UPSTREAM screen-center (AExp 2026-07-13): analog positioner
--
-- Moves the complete analog picture (core content and OSM together) by changing
-- the phase of HSYNC/VSYNC relative to the final RGB stream, i.e. it
-- redistributes front and back porch. On a sync-locked analog display (CRT,
-- SCART, most fixed-frequency monitors) this is a true picture position
-- control. An analog-input LCD that auto-positions on the incoming timing may
-- partially or fully cancel the shift; that is a property of such displays,
-- not of this block.
--
-- Insertion point: AFTER OSM compositing, BEFORE composite-sync generation, so
-- that one instance covers scandoubled and raw 15 kHz modes and CSYNC is
-- derived from the positioned syncs.
--
-- Contract
-- ========
-- * Syncs are ACTIVE-HIGH (M2M framework convention). The block never touches
--   RGB, DE or blanking; it re-times hs_i/vs_i onto hs_o/vs_o only.
-- * pan_x_i: signed, positive = picture moves RIGHT. One unit is two clocks of
--   SOURCE-raster time: with doubled_i = '0' that is 2 clk_i cycles, with
--   doubled_i = '1' (a line-doubling scandoubler upstream) it is 1 clk_i
--   cycle. Hence one unit produces the same visible displacement (the same
--   fraction of a line) in both cases.
-- * pan_y_i: signed, positive = picture moves DOWN. One unit is one
--   SOURCE-raster line (doubled_i = '1': two input lines).
-- * doubled_i: '1' when the input raster is a line-doubled version of the
--   source raster. Wire it to the scandoubler-active setting.
-- * Zero pan is a genuine bypass: hs_o/vs_o are combinationally identical to
--   hs_i/vs_i (no added latency, no permanent baseline shift). Cores that
--   leave the pan inputs at their default '0' are bit-identical to a build
--   without this block.
--
-- Implementation: edge rescheduler
-- ================================
-- Every input sync edge is re-emitted after a delay of one measured PERIOD
-- minus the requested shift ("advance by S" = "delay by period - S", so a
-- positive-only scheduler implements both signs):
--
--   hs_o edge k = hs_i edge k+1 - s_h        (s_h = pan_x in input clocks)
--   vs_o edge k = vs_i edge k+1 - s_v - s_h  (s_v = pan_y in input clocks)
--
-- * The VSYNC channel uses a one-period-back-per-parity ("two-back")
--   predictor, so cores whose interlaced VSYNC placement alternates between
--   fields (mid-line vs. line-start, or 312/313-line fields) are re-emitted
--   with the alternation intact: the field-dependent sub-line phase and the
--   field parity are preserved exactly.
-- * s_v is a whole number of source lines and s_h is also applied to VSYNC,
--   so the VSYNC-to-HSYNC phase of the output equals that of the input.
-- * Pulse widths are preserved exactly: a falling edge always uses the delay
--   sampled at its own rising edge.
-- * Acquisition: the block measures line and field periods and engages only
--   after they are stable (and while hs_i/vs_i are idle). The first
--   scheduled edges coincide with the input train (delay = period), so the
--   bypass-to-scheduler switchover is seamless; the shift is then committed
--   at a VSYNC edge (inside vertical blanking). Pan changes commit the same
--   way: at most one line/field period deviates once per change, hidden in
--   the blanking interval, and no sync pulse is ever malformed (structural
--   clamps keep every delta below the reorder limit by construction).
-- * Loss of lock (video mode change) or rst_i forces an immediate return to
--   bypass and a fresh acquisition; the one-time discontinuity coincides
--   with the video mode change itself.
--
-- Clamps (all applied in hardware, requests degrade to the nearest safe value)
-- * Horizontal, structural: |shift| <= line/2**G_HDIV_LOG2.
-- * Horizontal, porch-derived: the sync pulse must keep G_GUARD clocks of
--   black between itself and the measured DE window (protects per-line
--   black-level clamping on CRTs). Trimming the analog overscan/crop first
--   widens the porch and therefore the available pan range.
-- * Vertical, structural: |pan_y| <= G_VMAX_LINES source lines. Moving VSYNC
--   into formerly active lines merely cuts content at that edge (as any
--   vertical position control does), so no porch clamp is applied.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity analog_positioner is
   generic (
      G_CNT_BITS   : natural := 22;   -- scheduler timestamp width; must satisfy
                                      -- 2*max field period (in clocks) < 2**G_CNT_BITS
      G_GUARD      : natural := 8;    -- min clocks between a sync edge and DE
      G_HDIV_LOG2  : natural := 3;    -- structural H clamp: |shift| <= line/2**N
      G_VMAX_LINES : natural := 64    -- structural V clamp in source lines
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;

      -- input timing (post-OSM, full clock rate, active-high syncs)
      hs_i      : in  std_logic;
      vs_i      : in  std_logic;
      de_i      : in  std_logic;                     -- for the porch-derived H clamp
      doubled_i : in  std_logic;                     -- input raster is line-doubled

      -- pan request; latched once per frame internally (CDC de-tear)
      pan_x_i   : in  std_logic_vector(11 downto 0); -- signed, + = right
      pan_y_i   : in  std_logic_vector(11 downto 0); -- signed, + = down

      hs_o      : out std_logic;
      vs_o      : out std_logic
   );
end entity analog_positioner;

architecture synthesis of analog_positioner is

   -- sanity windows for the period measurements (in clk_i cycles)
   constant C_HPER_MIN  : natural := 100;
   constant C_HPER_MAX  : natural := 4000;
   constant C_VPER_MIN  : natural := 10000;
   constant C_VPER_MAX  : natural := 2**(G_CNT_BITS-2);
   constant C_HLOCK_CNT : natural := 4;    -- stable line periods to lock
   constant C_VLOCK_CNT : natural := 2;    -- stable frame (2-field) sums to lock

   subtype t_time is unsigned(G_CNT_BITS-1 downto 0);
   type    t_timeq is array (0 to 7) of t_time;

   -- free-running time base and input edge detection
   signal now_cnt      : t_time := (others => '0');
   signal hs_d         : std_logic := '0';
   signal vs_d         : std_logic := '0';
   signal de_d         : std_logic := '0';

   -- horizontal measurement
   signal h_last_rise  : t_time := (others => '0');
   signal h_per_a      : unsigned(12 downto 0) := (others => '0'); -- latest period
   signal h_width      : unsigned(12 downto 0) := (others => '0');
   signal h_stable     : unsigned(2 downto 0)  := (others => '0');
   signal h_locked     : std_logic := '0';
   signal h_lockloss   : std_logic := '0';   -- one-clock: period deviated

   -- vertical measurement (two-back predictor for alternating VS placement)
   signal v_last_rise  : t_time := (others => '0');
   signal v_per_a      : t_time := (others => '0'); -- latest period
   signal v2_prev      : unsigned(G_CNT_BITS downto 0) := (others => '0');
   signal v_stable     : unsigned(1 downto 0) := (others => '0');
   signal v_locked     : std_logic := '0';
   signal v_lockloss   : std_logic := '0';

   -- porch measurement against the (post-crop) DE window
   signal de_fall_t    : t_time := (others => '0');
   signal hs_fall_t    : t_time := (others => '0');
   signal de_fell      : std_logic := '0';
   signal fp_min       : unsigned(12 downto 0) := (others => '1'); -- per-frame minima
   signal bp_min       : unsigned(12 downto 0) := (others => '1');
   signal fp_seen      : std_logic := '0';
   signal bp_seen      : std_logic := '0';
   signal fp_meas      : unsigned(12 downto 0) := (others => '0'); -- frame-latched
   signal bp_meas      : unsigned(12 downto 0) := (others => '0');
   signal fp_valid     : std_logic := '0';
   signal bp_valid     : std_logic := '0';

   -- frame-latched pan request and clamped effective shifts
   signal pan_x_l      : signed(11 downto 0) := (others => '0');
   signal pan_y_l      : signed(11 downto 0) := (others => '0');
   signal req_nonzero  : std_logic := '0';
   signal s_h_eff      : signed(13 downto 0) := (others => '0'); -- input clocks
   signal s_v_clk      : signed(21 downto 0) := (others => '0'); -- input clocks

   -- edge schedulers: small in-order queues of (fire time, level)
   signal hq_time      : t_timeq := (others => (others => '0'));
   signal hq_lvl       : std_logic_vector(7 downto 0) := (others => '0');
   signal hq_rd        : unsigned(2 downto 0) := (others => '0');
   signal hq_wr        : unsigned(2 downto 0) := (others => '0');
   signal hq_cnt       : unsigned(3 downto 0) := (others => '0');
   signal vq_time      : t_timeq := (others => (others => '0'));
   signal vq_lvl       : std_logic_vector(7 downto 0) := (others => '0');
   signal vq_rd        : unsigned(2 downto 0) := (others => '0');
   signal vq_wr        : unsigned(2 downto 0) := (others => '0');
   signal vq_cnt       : unsigned(3 downto 0) := (others => '0');

   signal d_h          : t_time := (others => '0'); -- current HS delay
   signal d_h_pulse    : t_time := (others => '0'); -- sampled at HS rise
   signal d_v_pulse    : t_time := (others => '0'); -- sampled at VS rise
   signal hs_sched     : std_logic := '0';
   signal vs_sched     : std_logic := '0';
   signal h_live       : std_logic := '0';          -- scheduler took over the mux
   signal v_live       : std_logic := '0';
   signal dis_cnt      : unsigned(1 downto 0) := (others => '0'); -- settled-zero fields

   type t_state is (ST_BYPASS, ST_RUN);
   signal state        : t_state := ST_BYPASS;

begin

   -- genuine bypass: zero-latency combinational pass-through until the
   -- scheduler train has seamlessly taken over (h_live/v_live)
   hs_o <= hs_sched when h_live = '1' else hs_i;
   vs_o <= vs_sched when v_live = '1' else vs_i;

   ---------------------------------------------------------------------------
   -- time base, edge detection, period/porch measurement, lock tracking
   ---------------------------------------------------------------------------
   p_measure : process (clk_i)
      variable v_per_new : t_time;
      variable v_sum_new : unsigned(G_CNT_BITS downto 0);
      variable v_gap     : t_time;
   begin
      if rising_edge(clk_i) then
         now_cnt    <= now_cnt + 1;
         hs_d       <= hs_i;
         vs_d       <= vs_i;
         de_d       <= de_i;
         h_lockloss <= '0';
         v_lockloss <= '0';

         -- horizontal: period on each rising edge, width on the falling edge
         if hs_i = '1' and hs_d = '0' then
            v_per_new   := now_cnt - h_last_rise;
            h_last_rise <= now_cnt;
            if v_per_new >= C_HPER_MIN and v_per_new <= C_HPER_MAX then
               if v_per_new = resize(h_per_a, G_CNT_BITS) then
                  if h_stable /= C_HLOCK_CNT then
                     h_stable <= h_stable + 1;
                  end if;
               else
                  h_stable   <= (others => '0');
                  h_lockloss <= h_locked;
               end if;
               h_per_a <= v_per_new(12 downto 0);
            else
               h_stable   <= (others => '0');
               h_lockloss <= h_locked;
            end if;
         end if;
         if hs_i = '0' and hs_d = '1' then
            h_width   <= resize(now_cnt - h_last_rise, 13);
            hs_fall_t <= now_cnt;
         end if;
         -- lock: stable period and a plausible pulse width (< period/2)
         if h_stable = C_HLOCK_CNT and h_width < ('0' & h_per_a(12 downto 1)) then
            h_locked <= '1';
         else
            h_locked <= '0';
         end if;

         -- vertical: the sum of two consecutive periods (one full frame) is
         -- constant even when interlace alternates the VS placement
         if vs_i = '1' and vs_d = '0' then
            v_per_new   := now_cnt - v_last_rise;
            v_last_rise <= now_cnt;
            if v_per_new >= C_VPER_MIN and v_per_new <= C_VPER_MAX then
               v_sum_new := resize(v_per_new, G_CNT_BITS+1)
                          + resize(v_per_a,   G_CNT_BITS+1);
               if v_sum_new = v2_prev then
                  if v_stable /= C_VLOCK_CNT then
                     v_stable <= v_stable + 1;
                  end if;
               else
                  v_stable   <= (others => '0');
                  v_lockloss <= v_locked;
               end if;
               v2_prev <= v_sum_new;
               v_per_a <= v_per_new;
            else
               v_stable   <= (others => '0');
               v_lockloss <= v_locked;
            end if;
         end if;
         if v_stable = C_VLOCK_CNT then
            v_locked <= '1';
         else
            v_locked <= '0';
         end if;

         -- watchdogs: a stopped sync (core reset/freeze) delivers no edges, so
         -- period tracking alone cannot drop the lock; force re-acquisition
         if now_cnt - h_last_rise = C_HPER_MAX then
            h_stable   <= (others => '0');
            h_lockloss <= h_locked;
         end if;
         if now_cnt - v_last_rise = C_VPER_MAX then
            v_stable   <= (others => '0');
            v_lockloss <= v_locked;
         end if;

         -- porch against DE: front porch = DE fall -> HS rise, back porch =
         -- HS fall -> DE rise; per-frame minima, frame-latched at VS rise
         if de_i = '0' and de_d = '1' then
            de_fall_t <= now_cnt;
            de_fell   <= '1';
         end if;
         if hs_i = '1' and hs_d = '0' and de_fell = '1' then
            v_gap := now_cnt - de_fall_t;
            if v_gap <= C_HPER_MAX and v_gap(12 downto 0) < fp_min then
               fp_min <= v_gap(12 downto 0);
            end if;
            fp_seen <= '1';
            de_fell <= '0';
         end if;
         if de_i = '1' and de_d = '0' then
            v_gap := now_cnt - hs_fall_t;
            if v_gap <= C_HPER_MAX and v_gap(12 downto 0) < bp_min then
               bp_min <= v_gap(12 downto 0);
            end if;
            bp_seen <= '1';
         end if;
         if vs_i = '1' and vs_d = '0' then
            fp_meas  <= fp_min;
            bp_meas  <= bp_min;
            fp_valid <= fp_seen;
            bp_valid <= bp_seen;
            fp_min   <= (others => '1');
            bp_min   <= (others => '1');
            fp_seen  <= '0';
            bp_seen  <= '0';
         end if;

         if rst_i = '1' then
            hs_d     <= hs_i;
            vs_d     <= vs_i;
            de_d     <= de_i;
            h_stable <= (others => '0');
            v_stable <= (others => '0');
            h_locked <= '0';
            v_locked <= '0';
            de_fell  <= '0';
            fp_seen  <= '0';
            bp_seen  <= '0';
            fp_valid <= '0';
            bp_valid <= '0';
            fp_min   <= (others => '1');
            bp_min   <= (others => '1');
         end if;
      end if;
   end process p_measure;

   ---------------------------------------------------------------------------
   -- pan latching (once per frame, de-tears the incoherent CDC) and the
   -- clamped effective shifts; recomputed continuously, consumed at VS edges
   ---------------------------------------------------------------------------
   p_request : process (clk_i)
      variable v_sh   : signed(13 downto 0);
      variable v_lim  : unsigned(12 downto 0);
      variable v_plim : unsigned(12 downto 0);
      variable v_nlim : unsigned(12 downto 0);
      variable v_sv   : signed(11 downto 0);
      variable v_prod : signed(26 downto 0);
      variable v_psrc : unsigned(13 downto 0);
   begin
      if rising_edge(clk_i) then
         if vs_i = '1' and vs_d = '0' then
            pan_x_l <= signed(pan_x_i);
            pan_y_l <= signed(pan_y_i);
            if signed(pan_x_i) /= 0 or signed(pan_y_i) /= 0 then
               req_nonzero <= '1';
            else
               req_nonzero <= '0';
            end if;
         end if;

         -- horizontal: one unit = 2 source clocks (1 clock when doubled)
         if doubled_i = '1' then
            v_sh := resize(pan_x_l, 14);
         else
            v_sh := resize(pan_x_l, 14) + resize(pan_x_l, 14);
         end if;
         -- structural limit: line / 2**G_HDIV_LOG2
         v_lim  := shift_right(h_per_a, G_HDIV_LOG2);
         -- porch-derived limits: advance eats front porch, delay eats back porch
         v_plim := v_lim;
         v_nlim := v_lim;
         if fp_valid = '1' then
            if fp_meas > G_GUARD then
               if fp_meas - G_GUARD < v_plim then
                  v_plim := fp_meas - G_GUARD;
               end if;
            else
               v_plim := (others => '0');
            end if;
         end if;
         if bp_valid = '1' then
            if bp_meas > G_GUARD then
               if bp_meas - G_GUARD < v_nlim then
                  v_nlim := bp_meas - G_GUARD;
               end if;
            else
               v_nlim := (others => '0');
            end if;
         end if;
         if v_sh > signed('0' & v_plim) then
            v_sh := signed('0' & v_plim);
         elsif v_sh < -signed('0' & v_nlim) then
            v_sh := -signed('0' & v_nlim);
         end if;
         s_h_eff <= v_sh;

         -- vertical: one unit = 1 source line = h_per_a*(1 or 2) clocks
         v_sv := pan_y_l;
         if v_sv > to_signed(G_VMAX_LINES, 12) then
            v_sv := to_signed(G_VMAX_LINES, 12);
         elsif v_sv < to_signed(-G_VMAX_LINES, 12) then
            v_sv := to_signed(-G_VMAX_LINES, 12);
         end if;
         if doubled_i = '1' then
            v_psrc := h_per_a & '0';
         else
            v_psrc := '0' & h_per_a;
         end if;
         -- full-width product (12 x 15 bits), checked BEFORE truncation so
         -- that no generic choice of G_VMAX_LINES can wrap the arithmetic
         v_prod := v_sv * signed('0' & v_psrc);
         -- structural safety vs. the field period: if the requested shift
         -- exceeds a quarter field the raster is too exotic for a vertical
         -- pan; degrade to zero (never clamp in clocks -- that would place
         -- VSYNC at a fractional line and corrupt the sub-line phase)
         if v_prod > resize(signed('0' & shift_right(v_per_a, 2)), 27) or
            v_prod < -resize(signed('0' & shift_right(v_per_a, 2)), 27) then
            v_prod := (others => '0');
         end if;
         s_v_clk <= resize(v_prod, 22);

         if rst_i = '1' then
            pan_x_l     <= (others => '0');
            pan_y_l     <= (others => '0');
            req_nonzero <= '0';
            s_h_eff     <= (others => '0');
            s_v_clk     <= (others => '0');
         end if;
      end if;
   end process p_request;

   ---------------------------------------------------------------------------
   -- engage/disengage and the two edge schedulers
   ---------------------------------------------------------------------------
   p_sched : process (clk_i)
      variable v_dh_tgt : t_time;
      variable v_dv_tgt : t_time;
      variable v_hpop   : boolean;
      variable v_hpush  : boolean;
      variable v_vpop   : boolean;
      variable v_vpush  : boolean;
      variable v_d      : t_time;
   begin
      if rising_edge(clk_i) then
         -- committed targets; deltas are bounded by the clamps, so consecutive
         -- pulses can never reorder (|delta_h| <= 2*line/8 < line - width)
         v_dh_tgt := resize(h_per_a, G_CNT_BITS)
                     - unsigned(resize(s_h_eff, G_CNT_BITS));
         v_dv_tgt := v_per_a
                     - unsigned(resize(s_v_clk, G_CNT_BITS))
                     - unsigned(resize(s_h_eff, G_CNT_BITS));

         case state is

            when ST_BYPASS =>
               -- engage only from a fully idle, locked input, so the first
               -- captured edges are rising edges and the first fires coincide
               -- with the input train
               if h_locked = '1' and v_locked = '1' and req_nonzero = '1' and
                  hs_i = '0' and hs_d = '0' and vs_i = '0' and vs_d = '0' then
                  state     <= ST_RUN;
                  d_h       <= resize(h_per_a, G_CNT_BITS);
                  d_h_pulse <= resize(h_per_a, G_CNT_BITS);
                  d_v_pulse <= v_per_a;
                  hs_sched  <= '0';
                  vs_sched  <= '0';
                  dis_cnt   <= (others => '0');
               end if;

            when ST_RUN =>
               v_hpop  := false;
               v_hpush := false;
               v_vpop  := false;
               v_vpush := false;

               -- fire pending edges
               if hq_cnt /= 0 and now_cnt = hq_time(to_integer(hq_rd)) then
                  hs_sched <= hq_lvl(to_integer(hq_rd));
                  hq_rd    <= hq_rd + 1;
                  h_live   <= '1';
                  v_hpop   := true;
               end if;
               if vq_cnt /= 0 and now_cnt = vq_time(to_integer(vq_rd)) then
                  vs_sched <= vq_lvl(to_integer(vq_rd));
                  vq_rd    <= vq_rd + 1;
                  v_live   <= '1';
                  v_vpop   := true;
               end if;

               -- capture HSYNC edges (falls reuse the delay of their rise);
               -- the "- 1" compensates the capture+output-register latency, so
               -- the input-transition-to-output-transition delay is exactly v_d
               if hs_i /= hs_d and hq_cnt /= 8 then
                  if hs_i = '1' then
                     v_d       := d_h;
                     d_h_pulse <= d_h;
                  else
                     v_d := d_h_pulse;
                  end if;
                  hq_time(to_integer(hq_wr)) <= now_cnt + v_d - 1;
                  hq_lvl(to_integer(hq_wr))  <= hs_i;
                  hq_wr                      <= hq_wr + 1;
                  v_hpush                    := true;
               end if;

               -- capture VSYNC edges; commit new deltas at the VS rise, after
               -- both channels run live (before that: delay = period = inert)
               if vs_i /= vs_d and vq_cnt /= 8 then
                  if vs_i = '1' then
                     if h_live = '1' and v_live = '1' then
                        v_d := v_dv_tgt;
                        d_h <= v_dh_tgt;
                     else
                        v_d := v_per_a;
                     end if;
                     d_v_pulse <= v_d;
                  else
                     v_d := d_v_pulse;
                  end if;
                  vq_time(to_integer(vq_wr)) <= now_cnt + v_d - 1;
                  vq_lvl(to_integer(vq_wr))  <= vs_i;
                  vq_wr                      <= vq_wr + 1;
                  v_vpush                    := true;
               end if;

               if v_hpush and not v_hpop then
                  hq_cnt <= hq_cnt + 1;
               elsif v_hpop and not v_hpush then
                  hq_cnt <= hq_cnt - 1;
               end if;
               if v_vpush and not v_vpop then
                  vq_cnt <= vq_cnt + 1;
               elsif v_vpop and not v_vpush then
                  vq_cnt <= vq_cnt - 1;
               end if;

               -- graceful disengage: once the shift is committed back to zero,
               -- the scheduler re-emits the input train exactly one period
               -- late, which on the locked raster is waveform-identical to the
               -- input. After three settled fields the mux returns to the true
               -- combinational bypass glitch-free (hs_sched/vs_sched equal
               -- hs_i/vs_i at every clock by then); the dropped queue entries
               -- only duplicate edges the bypass provides anyway. (Waiting for
               -- empty queues would never terminate: with delay = one period
               -- the queues never drain while syncs run.)
               if vs_i = '1' and vs_d = '0' then
                  if req_nonzero = '0' and d_h = resize(h_per_a, G_CNT_BITS) then
                     if dis_cnt = 3 then
                        state  <= ST_BYPASS;
                        h_live <= '0';
                        v_live <= '0';
                        hq_cnt <= (others => '0');
                        hq_rd  <= (others => '0');
                        hq_wr  <= (others => '0');
                        vq_cnt <= (others => '0');
                        vq_rd  <= (others => '0');
                        vq_wr  <= (others => '0');
                     else
                        dis_cnt <= dis_cnt + 1;
                     end if;
                  else
                     dis_cnt <= (others => '0');
                  end if;
               end if;

               -- emergency disengage on loss of lock (video mode change): the
               -- discontinuity coincides with the mode change itself
               if h_lockloss = '1' or v_lockloss = '1' or
                  h_locked = '0' or v_locked = '0' then
                  state    <= ST_BYPASS;
                  h_live   <= '0';
                  v_live   <= '0';
                  dis_cnt  <= (others => '0');
                  hq_cnt   <= (others => '0');
                  hq_rd    <= (others => '0');
                  hq_wr    <= (others => '0');
                  vq_cnt   <= (others => '0');
                  vq_rd    <= (others => '0');
                  vq_wr    <= (others => '0');
               end if;

         end case;

         if rst_i = '1' then
            state    <= ST_BYPASS;
            h_live   <= '0';
            v_live   <= '0';
            dis_cnt  <= (others => '0');
            hs_sched <= '0';
            vs_sched <= '0';
            hq_cnt   <= (others => '0');
            hq_rd    <= (others => '0');
            hq_wr    <= (others => '0');
            vq_cnt   <= (others => '0');
            vq_rd    <= (others => '0');
            vq_wr    <= (others => '0');
         end if;
      end if;
   end process p_sched;

end architecture synthesis;
