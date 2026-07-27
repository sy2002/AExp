-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- physical_fdd_mfm_quantise: DD-MFM read pipeline, stage 2 of 3: gap interval
-- -> 2-bit gap class.
--   "00" = short  (2 channel cells)   "01" = medium (3 channel cells)
--   "10" = long   (4 channel cells)   "11" = invalid / loss-of-lock
--
-- ADAPTIVE quantiser (C64MEGA65 issue #90 round 12, kept bit-for-bit). Fixed
-- windows had hard dead-bands between the classes; on real DD media the inner
-- cylinders (60+) show enough peak shift that gaps landed in a dead-band for
-- revolutions at a time -> class-11 loss of lock (hardware evidence there,
-- 2026-07-14). This stage:
--
--   * tracks the live half-cell length as a fixed-point estimate est
--     (C_QUANT_FRAC = 4 fraction bits; unit 50 MHz cycles; nominal 100.0),
--     seeded to nominal on reset AND on every loss of lock (a rejected gap);
--   * classifies each gap G to the NEAREST class n in {2,3,4} half-cells by
--     comparing G against the midpoints 2.5*est and 3.5*est;
--   * accepts the class iff |G - n*est| is at most est/2 - the acceptance
--     windows touch at the midpoints: every gap in [1.5*est .. 4.5*est]
--     classifies, there are NO dead-bands, and only gaps outside that span
--     are class "11" (loss of lock);
--   * adapts est on every ACCEPTED gap by a FIXED step of C_QUANT_STEP_Q
--     (1/8 cycle) toward the gap: est += step * sign(G - n*est). Sign-based
--     (median-seeking) because a proportional IIR has a BIASED equilibrium
--     under peak shift (ISI lengthens short gaps and shrinks long gaps
--     systematically) - proven by the C64MEGA65 A/B margin harness;
--   * hard-clamps est to [90 .. 110] cycles (+/-10% of nominal), bounding
--     any runaway adaptation (real drive speed tolerance is ~+/-3%).
--
-- For the Amiga the adaptivity additionally absorbs "long track" protections
-- (2..5% denser than nominal). The C64 decoder's field-phase tolerance tiers
-- and A1-train qualifier are not needed here: this front-end reconstructs the
-- RAW channel-bit stream and word alignment is a full 16-bit DSKSYNC compare
-- in physical_fdd_bits - structurally far stronger than any per-gap gate,
-- and self-healing (Paula word-compares the stream again downstream).
--
-- est_o exposes the estimate (Q8.4) as a read-only diagnostic tap.
--
-- Adapted from C64MEGA65 CORE/vhdl/physical_1581/physical_1581_mfm_quantise.vhd
-- (sy2002 2026, GPLv3); changes: the field_i tolerance-tier input and the
-- A/B-harness generics are dropped (single production tolerance est/2, the
-- default there), constants from physical_fdd_pkg.
--
-- Amiga 500 port (AExp) done by sy2002 in 2026 and licensed under GPL v3
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.physical_fdd_pkg.all;

entity physical_fdd_mfm_quantise is
  port (
    clk_i       : in  std_logic;
    rst_i       : in  std_logic;                       -- sync reset (re-seeds est)
    gap_valid_i : in  std_logic := '0';
    gap_len_i   : in  unsigned(15 downto 0) := (others => '0');
    gap_valid_o : out std_logic := '0';
    gap_class_o : out unsigned(1 downto 0) := "11";
    -- read-only diagnostic tap: live half-cell estimate, Q8.4 fixed point
    -- (bits 11:4 = integer cycles, bits 3:0 = sixteenths). Never read back.
    est_o       : out unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12)
  );
end entity physical_fdd_mfm_quantise;

architecture rtl of physical_fdd_mfm_quantise is
  -- half-cell estimate, Q8.4 (range clamped to [1440 .. 1760] = 90.0 .. 110.0)
  signal est_q : unsigned(11 downto 0) := to_unsigned(C_QUANT_EST_NOM_Q, 12);
begin

  est_o <= est_q;

  process (clk_i)
    -- all arithmetic in Q4 (sixteenths of a cycle)
    variable g_q      : unsigned(19 downto 0);   -- gap in Q4
    variable c2, c3, c4 : unsigned(14 downto 0); -- n*est, n = 2/3/4
    variable half_est : unsigned(14 downto 0);   -- est/2
    variable mid23    : unsigned(14 downto 0);   -- 2.5*est
    variable mid34    : unsigned(14 downto 0);   -- 3.5*est
    variable center   : unsigned(14 downto 0);   -- n*est of the nearest class
    variable n_cls    : integer range 2 to 4;
    variable e        : signed(21 downto 0);     -- G - n*est (Q4)
    variable tol      : unsigned(14 downto 0);   -- est/2
    variable upd      : signed(21 downto 0);     -- adaptation step, +/-C_QUANT_STEP_Q (Q4)
    variable nxt      : signed(21 downto 0);     -- est + upd before clamping
  begin
    if rising_edge(clk_i) then
      if rst_i = '1' then
        gap_valid_o <= '0';
        gap_class_o <= "11";
        est_q       <= to_unsigned(C_QUANT_EST_NOM_Q, est_q'length);
      else
        gap_valid_o <= gap_valid_i;

        if gap_valid_i = '1' then
          g_q      := gap_len_i & "0000";
          c2       := resize(est_q & '0', 15);                    -- 2*est
          c3       := resize(est_q & '0', 15) + resize(est_q, 15);-- 3*est
          c4       := resize(est_q & "00", 15);                   -- 4*est
          half_est := resize(est_q(11 downto 1), 15);             -- est/2
          mid23    := c2 + half_est;                              -- 2.5*est
          mid34    := c3 + half_est;                              -- 3.5*est

          -- nearest class by midpoint comparison
          if g_q < resize(mid23, g_q'length) then
            n_cls := 2; center := c2;
          elsif g_q < resize(mid34, g_q'length) then
            n_cls := 3; center := c3;
          else
            n_cls := 4; center := c4;
          end if;

          e   := signed(resize(g_q, e'length)) - signed(resize(center, e'length));
          tol := shift_right(resize(est_q, 15), C_QUANT_TOL_SHR);

          if abs(e) <= signed(resize(tol, e'length)) then
            -- accepted: emit the class and adapt est by a fixed 1/8-cycle
            -- step toward the gap (sign-based / median-seeking - see header).
            gap_class_o <= to_unsigned(n_cls - 2, 2);
            if e > 0 then
              upd := to_signed(C_QUANT_STEP_Q, upd'length);
            elsif e < 0 then
              upd := to_signed(-C_QUANT_STEP_Q, upd'length);
            else
              upd := (others => '0');
            end if;
            nxt := signed(resize(est_q, nxt'length)) + upd;
            if nxt < to_signed(C_QUANT_EST_MIN_Q, nxt'length) then
              est_q <= to_unsigned(C_QUANT_EST_MIN_Q, est_q'length);
            elsif nxt > to_signed(C_QUANT_EST_MAX_Q, nxt'length) then
              est_q <= to_unsigned(C_QUANT_EST_MAX_Q, est_q'length);
            else
              est_q <= unsigned(nxt(est_q'range));
            end if;
          else
            -- out of tolerance: loss of lock, re-seed the estimate
            gap_class_o <= "11";
            est_q       <= to_unsigned(C_QUANT_EST_NOM_Q, est_q'length);
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
