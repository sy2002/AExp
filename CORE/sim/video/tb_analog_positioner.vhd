----------------------------------------------------------------------------------
-- Testbench for M2M/vhdl/av_pipeline/analog_positioner.vhd, the analog pan of the
-- M2M-UPSTREAM screen-center change (doc/screen_adjust.md for the user side)
--
-- Drives a synthetic post-mixer raster (HS/VS/DE, active-high, full clock
-- rate) through the positioner and checks the complete contract:
--
--   * bypass equivalence at zero pan (clock-exact, before/after engagement)
--   * pan_x/pan_y move the DE landmark relative to the OUTPUT syncs by the
--     converted amount, both signs, raw and line-doubled rasters
--   * HS/VS pulse widths always equal the input widths (never malformed)
--   * HS periods never deviate beyond the clamp bound; at most a bounded
--     number of one-off period anomalies per pan commit
--   * interlace: the set of VS-to-HS sub-line phases (field parity /
--     half-line alternation) is preserved under pan, including cores that
--     quantize VS to line starts (alternating 62/63-line fields)
--   * clamps: horizontal requests degrade to min(line/8, porch-guard);
--     vertical requests beyond the safe window degrade to zero
--   * live pan changes, return-to-zero (seamless disengage), video mode
--     change (re-acquisition) and reset recovery
--
-- Scenarios are selected via generics. CORE/sim/video/run.sh runs five rasters
-- (about 25 seconds in total): progressive, interlaced (odd half-line count),
-- interlaced with VS quantized to line starts (alternating 62/63-line fields),
-- and the line-doubled progressive and interlaced variants.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_analog_positioner is
   generic (
      G_P        : natural := 200;    -- line period in clocks
      G_WH       : natural := 24;     -- HS width in clocks
      G_WV_LINES : natural := 3;      -- VS width in lines
      G_FIELD_X2 : natural := 120;    -- field length in input HALF-lines
      G_VS_QUANT : boolean := false;  -- quantize VS rises to line starts
      G_DOUBLED  : boolean := false;  -- positioner doubled_i
      G_DE_ON    : natural := 64;     -- DE window inside the line
      G_DE_OFF   : natural := 164;
      G_LINE_A   : natural := 6;      -- active lines (since VS rise)
      G_LINE_B   : natural := 50
   );
end entity tb_analog_positioner;

architecture sim of tb_analog_positioner is

   signal clk        : std_logic := '0';
   signal rst        : std_logic := '1';
   signal hs_in      : std_logic := '0';
   signal vs_in      : std_logic := '0';
   signal de_in      : std_logic := '0';
   signal pan_x      : std_logic_vector(11 downto 0) := (others => '0');
   signal pan_y      : std_logic_vector(11 downto 0) := (others => '0');
   signal hs_out     : std_logic;
   signal vs_out     : std_logic;

   signal g_p_cur    : natural := G_P;  -- current line period (mode change test)

   -- checking control
   signal eq_check   : std_logic := '0';  -- assert clock-exact bypass equality
   signal w_check    : std_logic := '0';  -- assert pulse widths
   signal p_check    : std_logic := '0';  -- assert bounded periods
   signal eq_run     : unsigned(31 downto 0) := (others => '0'); -- consecutive equal clocks

   -- monitors
   signal m_h_phase  : integer := -1;     -- last (DE rise - HS_out rise)
   signal m_v_lines  : integer := -1;     -- lines VS_out rise -> first DE line
   signal m_v_lines_p: integer := -1;     -- same, previous field (parity)
   signal m_svp0     : integer := -1;     -- last two VS_out-to-HS_out phases
   signal m_svp1     : integer := -1;
   signal m_sip0     : integer := -1;     -- last two VS_in-to-HS_in phases
   signal m_sip1     : integer := -1;
   signal h_anom     : integer := 0;      -- HS period anomaly counter
   signal anom_clr   : std_logic := '0';

   signal w_in_h     : integer := -1;     -- measured input widths
   signal w_in_v     : integer := -1;

   constant C_CLK    : time := 35 ns;

   signal sim_done   : boolean := false;

   function b2sl(b : boolean) return std_logic is
   begin
      if b then return '1'; else return '0'; end if;
   end function b2sl;
   constant C_DOUBLED : std_logic := b2sl(G_DOUBLED);

   -- expected effective horizontal clamp of this raster (mirrors the DUT rule)
   impure function h_clamp_limit(pos : boolean) return integer is
      variable v_lim : integer;
      variable v_fp  : integer;
      variable v_bp  : integer;
   begin
      v_lim := g_p_cur / 8;
      v_fp  := g_p_cur - G_DE_OFF - 8;   -- DE fall -> HS rise, minus guard
      v_bp  := G_DE_ON - G_WH - 8;       -- HS fall -> DE rise, minus guard
      if pos then
         if v_fp < v_lim then v_lim := v_fp; end if;
      else
         if v_bp < v_lim then v_lim := v_bp; end if;
      end if;
      return v_lim;
   end function h_clamp_limit;

begin

   clk <= not clk after C_CLK / 2 when not sim_done else '0';

   i_dut : entity work.analog_positioner
      port map (
         clk_i     => clk,
         rst_i     => rst,
         hs_i      => hs_in,
         vs_i      => vs_in,
         de_i      => de_in,
         doubled_i => C_DOUBLED,
         pan_x_i   => pan_x,
         pan_y_i   => pan_y,
         hs_o      => hs_out,
         vs_o      => vs_out
      );

   ---------------------------------------------------------------------------
   -- raster generator (input side)
   ---------------------------------------------------------------------------
   p_gen : process (clk)
      variable v_tl      : natural := 0;              -- position in line
      variable v_vs_next : natural := 3 * G_P;        -- clocks to next VS rise
      variable v_vs_left : natural := 0;              -- VS high time left
      variable v_line_vs : natural := 1000;           -- lines since VS rise
      variable v_alt     : boolean := false;          -- 62/63 alternation
   begin
      if rising_edge(clk) then
         -- horizontal
         if v_tl = g_p_cur - 1 then
            v_tl := 0;
            if v_line_vs < 10000 then
               v_line_vs := v_line_vs + 1;
            end if;
         else
            v_tl := v_tl + 1;
         end if;
         if v_tl < G_WH then
            hs_in <= '1';
         else
            hs_in <= '0';
         end if;

         -- vertical: constant period (FIELD_X2 half-lines) or line-quantized
         -- alternation of floor/ceil(FIELD_X2/2) lines
         if v_vs_next = 0 then
            v_vs_left := G_WV_LINES * g_p_cur;
            v_line_vs := 0;
            -- the "- 1" makes the period exact (this cycle already counts)
            if G_VS_QUANT then
               if v_alt then
                  v_vs_next := (G_FIELD_X2 / 2) * g_p_cur - 1;
               else
                  v_vs_next := ((G_FIELD_X2 + 1) / 2) * g_p_cur - 1;
               end if;
               v_alt := not v_alt;
            else
               v_vs_next := (G_FIELD_X2 * g_p_cur) / 2 - 1;
            end if;
         else
            v_vs_next := v_vs_next - 1;
         end if;
         if v_vs_left > 0 then
            vs_in     <= '1';
            v_vs_left := v_vs_left - 1;
         else
            vs_in <= '0';
         end if;

         -- DE window
         if v_line_vs >= G_LINE_A and v_line_vs < G_LINE_B and
            v_tl >= G_DE_ON and v_tl < G_DE_OFF then
            de_in <= '1';
         else
            de_in <= '0';
         end if;
      end if;
   end process p_gen;

   ---------------------------------------------------------------------------
   -- monitors
   ---------------------------------------------------------------------------
   p_mon : process (clk)
      variable v_hso_d    : std_logic := '0';
      variable v_vso_d    : std_logic := '0';
      variable v_hsi_d    : std_logic := '0';
      variable v_vsi_d    : std_logic := '0';
      variable v_de_d     : std_logic := '0';
      variable v_now      : integer := 0;
      variable v_ho_rise  : integer := -100000;
      variable v_ho_per   : integer := 0;
      variable v_vo_rise  : integer := -100000;
      variable v_hi_rise  : integer := -100000;
      variable v_vi_rise  : integer := -100000;
      variable v_lines_vo : integer := 0;
      variable v_seen_de  : boolean := true;
      variable v_max_dev  : integer;
   begin
      if rising_edge(clk) then
         v_now := v_now + 1;

         -- input widths (reference)
         if hs_in = '1' and v_hsi_d = '0' then
            v_hi_rise := v_now;
         end if;
         if hs_in = '0' and v_hsi_d = '1' then
            w_in_h <= v_now - v_hi_rise;
         end if;
         if vs_in = '1' and v_vsi_d = '0' then
            m_sip1 <= m_sip0;
            m_sip0 <= v_now - v_hi_rise;
         end if;

         -- output HS: width, period anomaly bound, phase base
         if hs_out = '1' and v_hso_d = '0' then
            v_ho_per  := v_now - v_ho_rise;
            v_ho_rise := v_now;
            if p_check = '1' and v_ho_per /= g_p_cur then
               h_anom <= h_anom + 1;
               v_max_dev := g_p_cur / 4 + 4;
               assert abs (v_ho_per - g_p_cur) <= v_max_dev
                  report "HS period grossly malformed: " & integer'image(v_ho_per)
                  severity failure;
            end if;
            v_lines_vo := v_lines_vo + 1;
         end if;
         if hs_out = '0' and v_hso_d = '1' then
            if w_check = '1' and w_in_h > 0 then
               assert (v_now - v_ho_rise) = w_in_h
                  report "HS width changed: " & integer'image(v_now - v_ho_rise) &
                         " expected " & integer'image(w_in_h)
                  severity failure;
            end if;
         end if;

         -- input VS width (reference, tracks mode changes)
         if vs_in = '1' and v_vsi_d = '0' then
            v_vi_rise := v_now;
         end if;
         if vs_in = '0' and v_vsi_d = '1' then
            w_in_v <= v_now - v_vi_rise;
         end if;

         -- output VS: width, sub-line phase history, line counter reset
         if vs_out = '1' and v_vso_d = '0' then
            v_vo_rise  := v_now;
            m_svp1     <= m_svp0;
            m_svp0     <= v_now - v_ho_rise;
            v_lines_vo := 0;
            v_seen_de  := false;
         end if;
         if vs_out = '0' and v_vso_d = '1' then
            if w_check = '1' and w_in_v > 0 then
               assert (v_now - v_vo_rise) = w_in_v
                  report "VS width changed: " & integer'image(v_now - v_vo_rise) &
                         " expected " & integer'image(w_in_v)
                  severity failure;
            end if;
         end if;

         -- DE landmark phases
         if de_in = '1' and v_de_d = '0' then
            m_h_phase <= v_now - v_ho_rise;
            if not v_seen_de then
               m_v_lines_p <= m_v_lines;
               m_v_lines   <= v_lines_vo;
               v_seen_de   := true;
            end if;
         end if;

         if anom_clr = '1' then
            h_anom <= 0;
         end if;

         -- clock-exact bypass equality
         if eq_check = '1' then
            assert hs_out = hs_in and vs_out = vs_in
               report "bypass equality violated" severity failure;
         end if;
         if hs_out = hs_in and vs_out = vs_in then
            eq_run <= eq_run + 1;
         else
            eq_run <= (others => '0');
         end if;

         v_hso_d := hs_out;
         v_vso_d := vs_out;
         v_hsi_d := hs_in;
         v_vsi_d := vs_in;
         v_de_d  := de_in;
      end if;
   end process p_mon;

   ---------------------------------------------------------------------------
   -- test control
   ---------------------------------------------------------------------------
   p_ctrl : process
      variable v_base_h  : integer;
      variable v_base_v0 : integer;
      variable v_base_v1 : integer;
      variable v_sv      : integer;
      variable v_lim     : integer;
      variable v_svp_a   : integer;
      variable v_svp_b   : integer;

      procedure wait_fields(n : natural) is
      begin
         for i in 1 to n loop
            wait until rising_edge(vs_in);
         end loop;
         wait until rising_edge(clk);
      end procedure;

      procedure set_pan(x : integer; y : integer) is
      begin
         pan_x <= std_logic_vector(to_signed(x, 12));
         pan_y <= std_logic_vector(to_signed(y, 12));
      end procedure;

      -- source units -> input clocks / input lines
      function ux(u : integer) return integer is
      begin
         if G_DOUBLED then return u; else return 2 * u; end if;
      end function;
      function uy(u : integer) return integer is
      begin
         if G_DOUBLED then return 2 * u; else return u; end if;
      end function;

      procedure check_h(exp_shift : integer; tol : integer; tag : string) is
      begin
         assert abs (m_h_phase - (v_base_h + exp_shift)) <= tol
            report tag & ": H phase " & integer'image(m_h_phase) &
                   " expected " & integer'image(v_base_h + exp_shift)
            severity failure;
      end procedure;

      procedure check_v(exp_lines : integer; tag : string) is
         variable a : integer;
         variable b : integer;
      begin
         a := m_v_lines;
         b := m_v_lines_p;
         assert (abs (a - (v_base_v0 + exp_lines)) <= 1 and
                 abs (b - (v_base_v1 + exp_lines)) <= 1) or
                (abs (a - (v_base_v1 + exp_lines)) <= 1 and
                 abs (b - (v_base_v0 + exp_lines)) <= 1)
            report tag & ": V lines " & integer'image(a) & "/" & integer'image(b) &
                   " expected base " & integer'image(v_base_v0) & "/" &
                   integer'image(v_base_v1) & " + " & integer'image(exp_lines)
            severity failure;
      end procedure;

      procedure check_svp(tag : string) is
      begin
         assert (abs (m_svp0 - v_svp_a) <= 2 and abs (m_svp1 - v_svp_b) <= 2) or
                (abs (m_svp0 - v_svp_b) <= 2 and abs (m_svp1 - v_svp_a) <= 2)
            report tag & ": VS sub-line phase set changed: got " &
                   integer'image(m_svp0) & "/" & integer'image(m_svp1) &
                   " expected " & integer'image(v_svp_a) & "/" & integer'image(v_svp_b)
            severity failure;
      end procedure;

   begin
      -- Phase A: reset, acquire, verify pure bypass
      set_pan(0, 0);
      rst <= '1';
      wait for 20 * C_CLK;
      wait until rising_edge(clk);
      rst <= '0';
      wait_fields(2);
      eq_check <= '1';
      w_check  <= '1';
      wait_fields(4);
      v_base_h  := m_h_phase;
      v_base_v0 := m_v_lines;
      v_base_v1 := m_v_lines_p;
      v_svp_a   := m_svp0;
      v_svp_b   := m_svp1;
      report "base: h=" & integer'image(v_base_h) & " v=" & integer'image(v_base_v0)
             & "/" & integer'image(v_base_v1) & " svp=" & integer'image(v_svp_a)
             & "/" & integer'image(v_svp_b);
      eq_check <= '0';
      p_check  <= '1';
      anom_clr <= '1';
      wait until rising_edge(clk);
      anom_clr <= '0';

      -- Phase B: positive pan
      set_pan(8, 2);
      wait_fields(10);
      check_h(ux(8), 2, "B");
      check_v(uy(2), "B");
      check_svp("B");
      assert h_anom <= 3
         report "B: too many period anomalies: " & integer'image(h_anom)
         severity failure;

      -- Phase C: negative pan
      set_pan(-8, -2);
      wait_fields(10);
      check_h(-ux(8), 2, "C");
      check_v(-uy(2), "C");
      check_svp("C");

      -- Phase D: clamped request (huge values degrade safely)
      set_pan(100, 100);
      wait_fields(10);
      v_lim := h_clamp_limit(true);
      check_h(v_lim, 2, "D");
      -- vertical: 100 -> 64 source lines; beyond field/4 on this raster -> zero
      v_sv := uy(64);
      if 64 * uy(1) * g_p_cur > (G_FIELD_X2 * g_p_cur) / 8 then
         v_sv := 0;
      end if;
      check_v(v_sv, "D");

      -- Phase E: return to zero -> seamless disengage back to true bypass
      set_pan(0, 0);
      wait_fields(10);
      assert eq_run > to_unsigned(2 * (G_FIELD_X2 * g_p_cur) / 2, 32)
         report "E: bypass equality not re-established, eq_run=" &
                integer'image(to_integer(eq_run))
         severity failure;
      -- white-box: the mux really returned to the combinational bypass (a
      -- stuck-in-RUN scheduler would also satisfy the equality check above)
      assert << signal .tb_analog_positioner.i_dut.h_live : std_logic >> = '0' and
             << signal .tb_analog_positioner.i_dut.v_live : std_logic >> = '0'
         report "E: positioner did not disengage to true bypass (still live)"
         severity failure;
      eq_check <= '1';
      wait_fields(2);
      eq_check <= '0';

      -- Phase F: engaged, then video mode change -> re-acquire with new raster
      set_pan(8, 0);
      wait_fields(8);
      check_h(ux(8), 2, "F1");
      w_check <= '0';
      p_check <= '0';
      g_p_cur <= G_P + 20;
      wait_fields(4);
      w_check <= '1';
      wait_fields(10);
      check_h(ux(8), 2, "F2");   -- base phase = DE_ON is raster-independent

      -- Phase G: reset while engaged -> immediate bypass, then re-engage
      -- (the reset discontinuity may legitimately truncate/stretch one pulse)
      w_check <= '0';
      rst <= '1';
      wait for 10 * C_CLK;
      wait until rising_edge(clk);
      rst <= '0';
      wait_fields(2);
      w_check <= '1';
      wait_fields(1);
      assert eq_run > to_unsigned(100, 32)
         report "G: not in bypass shortly after reset" severity failure;
      wait_fields(12);
      check_h(ux(8), 2, "G");

      report "TB PASSED (P=" & integer'image(G_P) &
             " field_x2=" & integer'image(G_FIELD_X2) &
             " quant=" & boolean'image(G_VS_QUANT) &
             " doubled=" & boolean'image(G_DOUBLED) & ")";
      sim_done <= true;
      wait;
   end process p_ctrl;

end architecture sim;
