----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework 
--
-- Debouncer for the joystick ports that includes a port switcher and the
-- ability to turn the joysticks on/off.
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity debouncer is
generic (
   CLK_FREQ           : in integer
);
port (
   clk                : in std_logic;  
   reset_n            : in std_logic;
   
   flip_joys_i        : in std_logic;
   joy_1_on           : in std_logic;
   joy_2_on           : in std_logic;
 
   joy_1_up_n         : in std_logic;
   joy_1_down_n       : in std_logic;
   joy_1_left_n       : in std_logic;
   joy_1_right_n      : in std_logic;
   joy_1_fire_n       : in std_logic;
   
   dbnce_joy1_up_n    : out std_logic;
   dbnce_joy1_down_n  : out std_logic;
   dbnce_joy1_left_n  : out std_logic;
   dbnce_joy1_right_n : out std_logic;
   dbnce_joy1_fire_n  : out std_logic;
   
   joy_2_up_n         : in std_logic;
   joy_2_down_n       : in std_logic;
   joy_2_left_n       : in std_logic;
   joy_2_right_n      : in std_logic;
   joy_2_fire_n       : in std_logic;
   
   dbnce_joy2_up_n    : out std_logic;
   dbnce_joy2_down_n  : out std_logic;
   dbnce_joy2_left_n  : out std_logic;
   dbnce_joy2_right_n : out std_logic;
   dbnce_joy2_fire_n  : out std_logic     
);
end debouncer;

architecture beh of debouncer is

-- M2M-UPSTREAM raw-joyports: this framework joystick debouncer is reduced to
-- plain 2-FF synchronizers (no stable-time filter) so the DB9 direction/fire
-- and mouse quadrature lines pass through raw.
-- MiSTer2MEGA65 (AExp Amiga 500 port), July 2026: debouncing removed, the ten
-- work.debounce instances (stable_time 1 ms) are replaced by plain 2-FF
-- synchronizers. A real Amiga has no debouncing on the DB9 lines: Denise counts
-- mouse quadrature transitions and software polls direction/fire levels, so any
-- filtering is inauthentic - and the 1 ms stable-time filter swallowed the
-- quadrature edges of a real Amiga mouse (frozen-then-jumping pointer on brisk
-- movement). The port switcher and the joystick on/off gating below are kept
-- unchanged. CLK_FREQ and reset_n remain in the interface for compatibility but
-- are no longer used. To be turned into a proper framework option when this is
-- upstreamed to MiSTer2MEGA65.

signal j1_u, j1_d, j1_l, j1_r, j1_f : std_logic := '1';
signal j2_u, j2_d, j2_l, j2_r, j2_f : std_logic := '1';

-- first synchronizer stage
signal j1_u_s, j1_d_s, j1_l_s, j1_r_s, j1_f_s : std_logic := '1';
signal j2_u_s, j2_d_s, j2_l_s, j2_r_s, j2_f_s : std_logic := '1';

begin

   -- assign output signals and support the flip joystick ports feature and the on/off switches
   handle_outputs: process(all)
   begin
      dbnce_joy1_up_n      <= '1';
      dbnce_joy1_down_n    <= '1';
      dbnce_joy1_left_n    <= '1';
      dbnce_joy1_right_n   <= '1';
      dbnce_joy1_fire_n    <= '1';
      
      dbnce_joy2_up_n      <= '1';
      dbnce_joy2_down_n    <= '1';
      dbnce_joy2_left_n    <= '1';
      dbnce_joy2_right_n   <= '1';
      dbnce_joy2_fire_n    <= '1';
      
      if joy_1_on then
         dbnce_joy1_up_n      <= j1_u when flip_joys_i = '0' else j2_u;
         dbnce_joy1_down_n    <= j1_d when flip_joys_i = '0' else j2_d;
         dbnce_joy1_left_n    <= j1_l when flip_joys_i = '0' else j2_l;
         dbnce_joy1_right_n   <= j1_r when flip_joys_i = '0' else j2_r;
         dbnce_joy1_fire_n    <= j1_f when flip_joys_i = '0' else j2_f;
      end if;
 
      if joy_2_on then
         dbnce_joy2_up_n      <= j2_u when flip_joys_i = '0' else j1_u;
         dbnce_joy2_down_n    <= j2_d when flip_joys_i = '0' else j1_d;
         dbnce_joy2_left_n    <= j2_l when flip_joys_i = '0' else j1_l;
         dbnce_joy2_right_n   <= j2_r when flip_joys_i = '0' else j1_r;
         dbnce_joy2_fire_n    <= j2_f when flip_joys_i = '0' else j1_f;
      end if;
   end process;
   
   -- 2-FF input synchronizers, NO debouncing (see the architecture header):
   -- authentic Amiga behavior and mandatory for quadrature mice, whose fast
   -- pulse trains a stable-time filter would swallow
   sync_joysticks : process (clk)
   begin
      if rising_edge(clk) then
         j1_u_s <= joy_1_up_n;      j1_u <= j1_u_s;
         j1_d_s <= joy_1_down_n;    j1_d <= j1_d_s;
         j1_l_s <= joy_1_left_n;    j1_l <= j1_l_s;
         j1_r_s <= joy_1_right_n;   j1_r <= j1_r_s;
         j1_f_s <= joy_1_fire_n;    j1_f <= j1_f_s;

         j2_u_s <= joy_2_up_n;      j2_u <= j2_u_s;
         j2_d_s <= joy_2_down_n;    j2_d <= j2_d_s;
         j2_l_s <= joy_2_left_n;    j2_l <= j2_l_s;
         j2_r_s <= joy_2_right_n;   j2_r <= j2_r_s;
         j2_f_s <= joy_2_fire_n;    j2_f <= j2_f_s;
      end if;
   end process sync_joysticks;
end beh;
