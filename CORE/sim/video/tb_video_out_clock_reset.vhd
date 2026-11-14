-- Reset bench for M2M/vhdl/controllers/HDMI/video_out_clock.vhd, the
-- reprogrammable HDMI pixel-clock MMCM, against the behavioural cell models of
-- unisim_models.vhd and the real cdc_stable.vhd (runner: run_voc_reset.sh).
--
-- Part 1, the long press. Power-up (rsti high for 100 us; 70 ms on hardware,
-- long enough for the MMCM to lock on its default before the state machine
-- resets it), 400 us running in the 74.25 MHz mode, a long press (rsti high
-- for 200 us; on hardware from 1.5 s into the press until about 70 ms after
-- the release), the release, 300 us settling. reset_na models the scaler's
-- reset: low while rsti is high, high 60 ns after rsti falls (the hr_rst
-- release of clk_m2m.vhd).
-- Part 2, the sweep. A 10 ns rsti pulse starts a reprogramming; a second
-- pulse of 10 ns, 5 us or 60 us follows at offsets from 0 to 100 us, so that
-- it lands in RESET_WAIT, RESET, the DRP states, LOCK_WAIT and IDLE.
--
-- Checks (all must hold, TB PASSED only then):
--   1. no rising edge of clko while the multiplexer actually passes the MMCM
--      clock, LOCKED is low and reset_na is high: no edge of the unlocked MMCM
--      reaches the scaler's released output stage, at power-up, after the
--      press and in every sweep case;
--   2. clko never pauses for more than 100 ns from the start of the press to
--      200 us after its release, nor in any sweep case: the pixel clock keeps
--      running (the 50 MHz backup clock has a 20 ns period, a multiplexer
--      switch costs two edges);
--   3. rsto (hdmi_rst) is high in the middle of the press;
--   4. after the press and after every sweep case the MMCM locks within 1 ms,
--      the multiplexer passes the locked MMCM clock, rsto is low, and the
--      period is the model's 13.468 ns.
-- The template behaviour (red control of the runner) fails checks 2 and 3 and,
-- in this model, 1.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity tb_video_out_clock_reset is
  generic (VARIANT : string := "dut");
end entity;

architecture sim of tb_video_out_clock_reset is
  signal clki : std_logic := '0';
  signal rsti : std_logic := '1';
  signal sel  : std_logic_vector(2 downto 0) := "010";   -- 74.25 MHz, 720p
  signal rsto, clko, clko_x5 : std_logic;
  signal reset_na : std_logic := '0';
  signal mon_clear : std_logic := '0';  -- toggles: the monitors start over
  signal hazard : natural := 0;         -- check 1 counter since the last mon_clear
  signal max_gap : time := 0 ns;        -- check 2 since the last mon_clear
begin
  clki <= not clki after 5 ns;

  dut : entity work.video_out_clock generic map (fref => 100.0)
    port map (rsti => rsti, clki => clki, sel => sel, rsto => rsto, clko => clko, clko_x5 => clko_x5);

  -- the scaler's reset: asynchronous assertion, release 60 ns after rsti
  reset_model : process (rsti) begin
    if rsti = '1' then reset_na <= '0'; else reset_na <= '1' after 60 ns; end if;
  end process;

  -- check 1: edges from the MMCM clock (the multiplexer's real selection, not
  -- its select input) while LOCKED is low and the scaler is out of reset
  hazard_mon : process (clko, mon_clear)
    alias mux_sel_q  is <<signal .tb_video_out_clock_reset.dut.U_BUFG_1.sel_q : std_logic>>;
    alias mux_en     is <<signal .tb_video_out_clock_reset.dut.U_BUFG_1.en    : std_logic>>;
    alias dut_locked is <<signal .tb_video_out_clock_reset.dut.locked         : std_logic>>;
  begin
    if mon_clear'event then
      hazard <= 0;
    elsif rising_edge(clko) and reset_na = '1' and mux_sel_q = '1' and mux_en = '1' and dut_locked = '0' then
      hazard <= hazard + 1;
    end if;
  end process;

  -- check 2: the longest pause between rising edges of clko
  gap_mon : process
    variable last : time := 0 ns;
  begin
    wait on clko, mon_clear for 1 ms;
    if mon_clear'event then
      max_gap <= 0 ns; last := now;
    else
      if now - last > max_gap then max_gap <= now - last; end if;
      if clko'event and clko = '1' then last := now; end if;
    end if;
  end process;

  main : process
    alias mux_sel_q  is <<signal .tb_video_out_clock_reset.dut.U_BUFG_1.sel_q : std_logic>>;
    alias mux_en     is <<signal .tb_video_out_clock_reset.dut.U_BUFG_1.en    : std_logic>>;
    alias dut_locked is <<signal .tb_video_out_clock_reset.dut.locked         : std_logic>>;
    variable ok : boolean := true;
    variable t0, p : time;
    variable rsto_mid : std_logic;
    type time_vector is array (natural range <>) of time;
    constant OFFSETS : time_vector := (0 ns, 20 ns, 40 ns, 100 ns, 500 ns, 1 us, 2 us, 2500 ns, 3 us,
                                       20 us, 50 us, 52 us, 60 us, 100 us);
    constant LENGTHS : time_vector := (10 ns, 5 us, 60 us);
    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then report VARIANT & ": FAIL  " & msg severity error; ok := false; end if;
    end procedure;
    -- settle after a reset: lock within 1 ms, then 100 us; check the final state
    procedure settle_and_check(tag : string) is
    begin
      wait until dut_locked = '1' for 1 ms;
      check(dut_locked = '1', tag & ": locked within 1 ms");
      wait for 100 us;
      check(hazard = 0, tag & ": no unlocked edge reached the scaler");
      check(max_gap <= 100 ns, tag & ": clko paused for more than 100 ns (" & time'image(max_gap) & ")");
      check(mux_sel_q = '1' and mux_en = '1', tag & ": multiplexer on the MMCM clock");
      check(rsto = '0', tag & ": rsto low");
      wait until rising_edge(clko); p := now; wait until rising_edge(clko); p := now - p;
      check(abs(p - 13468 ps) <= 1 ps, tag & ": period 13.468 ns");
    end procedure;
  begin
    -- part 1: power-up
    rsti <= '1'; wait for 100 us; rsti <= '0';
    wait for 400 us;
    check(hazard = 0, "power-up: no unlocked edge reached the scaler");
    -- the long press
    mon_clear <= not mon_clear; wait for 1 ns;
    rsti <= '1';
    wait for 100 us; rsto_mid := rsto;
    wait for 100 us;
    rsti <= '0'; t0 := now;
    wait until dut_locked = '1' for 1 ms;
    report VARIANT & ": long press: unlocked edges so far " & integer'image(hazard)
         & ", longest clko pause " & time'image(max_gap)
         & ", rsto mid-press " & std_logic'image(rsto_mid)
         & ", LOCKED " & time'image(now - t0) & " after the release";
    check(rsto_mid = '1', "long press: rsto high during the press");
    wait for 200 us;
    check(max_gap <= 100 ns, "long press: clko paused for more than 100 ns (" & time'image(max_gap) & ")");
    settle_and_check("long press");

    -- part 2: the sweep
    for i in OFFSETS'range loop
      for j in LENGTHS'range loop
        mon_clear <= not mon_clear; wait for 1 ns;
        rsti <= '1'; wait for 10 ns; rsti <= '0';          -- start a reprogramming
        wait for OFFSETS(i);
        rsti <= '1'; wait for LENGTHS(j); rsti <= '0';     -- the reset under test
        settle_and_check("sweep offset " & time'image(OFFSETS(i)) & " length " & time'image(LENGTHS(j)));
      end loop;
    end loop;
    report VARIANT & ": sweep: " & integer'image(OFFSETS'length * LENGTHS'length) & " cases";

    if ok then report "TB PASSED (" & VARIANT & ")"; else report "TB FAILED (" & VARIANT & ")"; end if;
    std.env.finish;
  end process;
end architecture;
