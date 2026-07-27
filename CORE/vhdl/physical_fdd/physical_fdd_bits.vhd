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
    word_valid_o : out std_logic := '0';               -- 1-clk pulse
    word_o       : out std_logic_vector(15 downto 0) := (others => '0');
    sync_hit_o   : out std_logic := '0';               -- diag: 1-clk pulse per sync match
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

begin

  process (clk_i)
    variable v_bit    : std_logic;
    variable v_emit   : std_logic;
    variable v_new_sr : std_logic_vector(15 downto 0);
  begin
    if rising_edge(clk_i) then
      -- pulses default low
      word_valid_o <= '0';
      sync_hit_o   <= '0';
      lol_o        <= '0';

      if rst_i = '1' then
        pend_sr     <= (others => '0');
        pend_cnt    <= (others => '0');
        sr          <= (others => '0');
        bit_cnt     <= (others => '0');
        drought_cnt <= 0;
      else
        v_emit := '0';
        v_bit  := '0';

        -- 1) new gap event dominates (physically >= 16 cycles apart, while
        --    the pending queue drains in at most 4 - see the gaps stage)
        if gap_valid_i = '1' then
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

        -- shift the emitted bit in, MSB-first; sync match dominates the
        -- 16-bit rollover so words re-align on every DSKSYNC occurrence
        if v_emit = '1' then
          v_new_sr := sr(14 downto 0) & v_bit;
          sr <= v_new_sr;
          if sync_i /= x"0000" and v_new_sr = sync_i then
            word_o       <= v_new_sr;
            word_valid_o <= '1';
            sync_hit_o   <= '1';
            bit_cnt      <= (others => '0');
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
