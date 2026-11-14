-------------------------------------------------------------------------------
-- Amiga 500 for MEGA65 (AExp)
--
-- tb_fdd_splice: the write-splice testbench for the Hardware Floppy read
-- chain, with a Kickstart 1.3 trackdisk decoder as consumer. It closes the
-- loop from flux through the real front-end (physical_fdd_top: conditioner
-- -> gaps -> quantiser/DPLL -> aligner -> word FIFO) into the software
-- decode that trackdisk runs on the captured words.
--
-- What it guards (the sync seam, see doc/developers/hardware-floppy.md): a
-- real Paula with WORDSYNC off, as trackdisk runs it, never realigns its
-- word framing in the middle of a capture. The whole capture carries one
-- framing, and trackdisk's decoder (16 pre-shifted sync patterns plus a
-- second gap hunt whose chunk takes its own shift) absorbs a constant
-- framing shift across the write splice. A front end that realigns at
-- every 0x4489 turns the once-per-revolution splice slip into a seam
--    [gap run at old framing][hybrid word][word-aligned 4489]
-- that matches no hunt pattern: the gap re-hunt fails with $1A (window
-- exhausted) or $17 (anchored on a later, aligned sync -> sector-ID
-- mismatch), and every attempt dies. physical_fdd_bits therefore holds the
-- framing while the engine streams past its serve-start sync with WORDSYNC
-- off (the framing hold, selected here by G_FIXED).
--
-- Expectations (asserted):
--   * no-splice controls decode through the real chain, including a -3%
--     cell attempt under the full deselect-per-attempt cadence with
--     nominal re-seeding;
--   * G_FIXED=false (realign-always framing, the control): with a splice
--     (phase jump >= half a cell, either sign, or an erase drought) every
--     attempt whose decode anchor is not the first-written sector fails
--     with $1A or $17, in both separator modes (-gG_LEGACY=true for the
--     legacy quantiser path);
--   * $17 versus $1A follows from the captured gap length: a 532-byte gap
--     (nominal 12500-byte writer) leaves the second post-gap sector
--     boundary inside the $67C re-hunt window, so the hunt anchors on it,
--     one sector late -> $17; a 600-byte gap pushes it outside -> $1A. The
--     split is a property of the writing drive's speed;
--   * the escape: an attempt anchored on the SG = 11 sector (the first
--     sector after the gap) skips the gap re-hunt and decodes from
--     seam-free data. With a stale buffer the anchor is the serve-start
--     sector, so the escape arc is the select-time window that starts
--     serving at that sector (G_SWEEP measures it over all 11 starts);
--   * G_FIXED=true (the framing hold, the power-up default): the same
--     spliced attempts decode, chunk 2 absorbing the splice shift;
--   * a real-Paula model - the same spliced flux framed synthetically
--     with constant framing, as a real A500 delivers it - decodes at every
--     serve start;
--   * the capture instruments follow the sync-anchored diagnostic word
--     stream, so header captures publish clean-format in every mode,
--     including hold-mode serves whose served framing free-runs across the
--     splice;
--   * WORDSYNC=1 (the X-Copy class): the framing hold stays off and the
--     capture contains an aligned [4489][4489] pair with a clean
--     word-aligned sector decode for every boundary, post-splice included.
--     A hold that ignored WORDSYNC fails here.
--
-- The checker is an independent reimplementation of the Kickstart 1.3
-- trackdisk.device read decode:
--   * sync hunt: scan for a literal $AAAA/$5555 word, skip the run of
--     identical words, compare the run-end long against the 8 rotations of
--     the sync pair for the run's parity (f_sync_rot; the last $AAAA entry
--     is the plain $44894489); on mismatch resume the outer scan at the
--     run-end word. Returns the pointer 4 bytes before the matched long
--     and the shift code s (the sync's bit offset within the long is
--     j = (16 - s) mod 16).
--   * decode: hunt window $ABC from buffer+$682 (the capture is DMA'd to
--     buffer+$684, the decode destination is buffer+$680 - one stale word
--     in front of the capture, which after any chunk-1 realign reads $AAAA
--     and anchors the next hunt at the serve-start sync, shift 0);
--     first-header check at the source shift ($1B class); chunk 1 =
--     SG * $440 bytes realigned to buffer+$680; SG = 11 skips the re-hunt
--     (the escape); otherwise re-hunt $67C from the expected gap ($1A on
--     failure) and realign chunk 2 at its own shift; trailing pad word
--     $AAA8/$2AA8 at +$2EC0 and a forced $AAAA at the image start.
--   * per-slot walk in trackdisk's check order: pre-sync long
--     $AAAAAAAA/$2AAAAAAA and sync long $44894489 ($16), header checksum
--     ($18), info byte checks format/track/sector ($17), data checksum
--     ($19). All-or-nothing; the first failure ends the attempt.
--   * helpers: decode pair ((odd & $55555555) << 1) | (even & $55555555);
--     checksum = XOR of longs & $55555555; shifted long extraction; the
--     blitter realign copy (out[i] = bits j..j+15 of source words i, i+1).
--   Not modelled: the walk's re-encode of the sectors-to-gap byte and the
--   header checksum back into the buffer (write preparation; it only
--   touches bytes the next attempt's DMA overwrites, so it cannot
--   influence a read verdict); the clock-bit repair of the first post-gap
--   pre-sync byte (it only toggles bit 7 of that byte, the walk's two
--   accepted pre-sync literals differ in exactly that bit, and in the
--   SG = 11 case the pad word overwrites it); the write path.
--   The attempt cadence is trackdisk's: the drive is deselected between
--   attempts (chain reset -> nominal re-seed), each attempt selects, waits
--   1 ms, then arms a 7358-word DMA to buffer+$684 whose first stored word
--   is the serve-from-sync 0x4489 (WORDSYNC=0 stores from the first served
--   word; the engine's phys_hunt discards pre-sync words,
--   adf_track_engine.vhd ST_PHYS_HDR).
--
-- G_DUMP writes the pristine capture of every spliced attempt to
-- splice_dump_att<N>.txt in the run directory; CORE/sim/floppy/models/
-- td_check.py decodes such a dump independently.
--
-- Run: CORE/sim/floppy/run_fdd_regression.sh full (cells splice_ff,
-- splice_fl, splice_xf, splice_xl); 10-15 min per cell. Both G_FIXED
-- values are needed: only G_FIXED=true engages the framing hold, so the
-- capture-instrument asserts, the served-stream check (a spliced decode
-- with a nonzero chunk-2 shift) and the WORDSYNC=1 check apply there;
-- G_FIXED=false is the realign-always control.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use std.textio.all;
use work.physical_fdd_pkg.all;

entity tb_fdd_splice is
  generic (
    -- false = DPLL separator (the default), true = legacy quantiser path
    G_LEGACY : boolean := false;
    -- true additionally sweeps all 11 serve-start sectors over the spliced
    -- track (measures the escape arc); costs ~11 extra simulated attempts
    -- of ~0.25 s disk time each
    G_SWEEP  : boolean := false;
    -- true dumps the full capture of every spliced attempt to
    -- splice_dump_att<N>.txt (offset + word per line) for offline analysis
    G_DUMP   : boolean := false;
    -- false = realign-always framing (framehold_dis driven '1'): the
    -- spliced attempts must fail, which is the control for this bench.
    -- true = the WORDSYNC-conditional framing hold in force (the
    -- power-up default): the same spliced attempts must decode, with
    -- chunk 2 absorbing the splice shift like the real-Paula model.
    G_FIXED  : boolean := false
  );
end entity tb_fdd_splice;

architecture sim of tb_fdd_splice is

  constant C_CLK : time := 20 ns;                 -- 50 MHz front-end clock

  -----------------------------------------------------------------------------
  -- track geometry (standard AmigaDOS DD track, written by KS1.3 trackdisk)
  -----------------------------------------------------------------------------
  constant C_NSEC       : natural := 11;
  constant C_SLOT_B     : natural := 16#440#;     -- 1088 channel bytes/sector
  constant C_SLOT_BITS  : natural := C_SLOT_B * 8;
  constant C_TRACK_NO   : natural := 81;          -- cyl 40 head 1
  constant C_SECRUN_B   : natural := C_NSEC * C_SLOT_B;      -- 11968
  constant C_MAX_BITS   : natural := 106_000;     -- >= (11968 + 600) * 8

  -- the splice sits 300 channel bytes into the gap (the write-end point;
  -- physically the once-per-rev discontinuity where the write's tail
  -- overwrote its own oversized leading gap)
  constant C_SPLICE_OFF_B : natural := 300;
  constant C_SPLICE_BIT   : natural := (C_SECRUN_B + C_SPLICE_OFF_B) * 8;
  constant C_ERASE_BITS   : natural := 16;        -- erase-drought variant

  -----------------------------------------------------------------------------
  -- trackdisk parameters (Kickstart 1.3 trackdisk.device read behaviour)
  -----------------------------------------------------------------------------
  constant C_DMA_WORDS  : natural := 7358;        -- read DMA: $397C bytes
  constant C_DEC        : natural := 16#680#;     -- decode dest = buf+$680
  constant C_CAP        : natural := 16#684#;     -- DMA dest    = buf+$684
  constant C_HUNT1_LEN  : natural := 16#ABC#;     -- initial hunt window
  constant C_HUNT2_LEN  : natural := 16#67C#;     -- gap re-hunt window
  constant C_BUF_SZ     : natural := 20480;       -- unit buffer model

  constant TDERR_NOSYNC  : natural := 16#15#;
  constant TDERR_BADPRE  : natural := 16#16#;
  constant TDERR_BADID   : natural := 16#17#;
  constant TDERR_BADHSUM : natural := 16#18#;
  constant TDERR_BADDSUM : natural := 16#19#;
  constant TDERR_NOSECT  : natural := 16#1A#;
  constant TDERR_BADHDR  : natural := 16#1B#;

  constant C_MASK : unsigned(31 downto 0) := x"55555555";

  -- The 16 sync-hunt patterns: the long that ends a run of $AAAA/$5555
  -- words when the word framing leaves k bits of the $AAAA preamble in
  -- front of the sync pair $4489 $4489 (k = 0..15). Odd table (run word
  -- $5555): entry e has k = 2e+1 and matches shift s = 15-2e. Even table
  -- (run word $AAAA): entry e has k = 2e+2 and matches shift s = 14-2e;
  -- entry 7 has k = 0, the plain $44894489 (shift 0). The hunt compares
  -- the entries in index order.
  function f_sync_rot(k : natural) return unsigned is
    constant C_SYNC2 : unsigned(31 downto 0) := x"44894489";
    constant C_PRE   : unsigned(31 downto 0) := x"0000AAAA";
    variable v_mask  : unsigned(31 downto 0);
  begin
    if k = 0 then
      return C_SYNC2;
    end if;
    v_mask := shift_left(to_unsigned(1, 32), k) - 1;
    return shift_left(C_PRE and v_mask, 32 - k) or shift_right(C_SYNC2, k);
  end function;

  type t_tbl is array (0 to 7) of unsigned(31 downto 0);
  function f_sync_tbl(odd : boolean) return t_tbl is
    variable v : t_tbl;
  begin
    for e in 0 to 7 loop
      if odd then
        v(e) := f_sync_rot(2 * e + 1);
      else
        v(e) := f_sync_rot((2 * e + 2) mod 16);
      end if;
    end loop;
    return v;
  end function;
  constant C_TBL_ODD  : t_tbl := f_sync_tbl(true);
  constant C_TBL_EVEN : t_tbl := f_sync_tbl(false);

  -----------------------------------------------------------------------------
  -- shared types
  -----------------------------------------------------------------------------
  type t_bitvec is array (0 to C_MAX_BITS - 1) of std_logic;
  type t_buf    is array (0 to C_BUF_SZ - 1) of natural range 0 to 255;

  -- decode result record (err < 11 = success and equals the anchor sector,
  -- exactly like trackdisk's return value; err >= $15 = TDERR)
  type t_res is record
    err       : natural;
    anchor    : integer;                          -- byte offset of hunt-1 ptr
    srom1     : integer;                          -- chunk-1 ROM shift code
    first_sec : integer;                          -- anchor sector number
    sg        : integer;                          -- anchor sectors-to-gap
    srom2     : integer;                          -- chunk-2 ROM shift code
    failslot  : integer;                          -- walk slot of the failure
    rehunt_ll : unsigned(31 downto 0);            -- last long the re-hunt saw
  end record;

  -----------------------------------------------------------------------------
  -- scenarios and attempts
  -----------------------------------------------------------------------------
  -- mode: 0 = no splice, 1 = phase jump only, 2 = erase drought + jump
  type t_scen is record
    gap_b : natural;                              -- gap length, channel bytes
    cell  : natural;                              -- cycles per channel cell
    mode  : natural;
    jump  : integer;                              -- phase jump, 50 MHz cycles
  end record;
  type t_scen_arr is array (natural range <>) of t_scen;
  constant C_SCEN : t_scen_arr(0 to 4) := (
    0 => (gap_b => 532, cell => 100, mode => 0, jump =>   0),  -- control
    1 => (gap_b => 532, cell => 103, mode => 0, jump =>   0),  -- -3% bias ctrl
    2 => (gap_b => 532, cell => 100, mode => 1, jump =>  65),  -- splice, $17
    3 => (gap_b => 600, cell => 100, mode => 1, jump => -65),  -- splice, $1A
    4 => (gap_b => 600, cell => 100, mode => 2, jump =>  65)); -- erase splice

  type t_exp is (EXP_GREEN, EXP_17, EXP_1A, EXP_RED_ANY);
  type t_att is record
    scen  : natural;
    k     : natural;                              -- serve-start sector
    fresh : boolean;                              -- zero the buffer first
    exp   : t_exp;
  end record;
  type t_att_arr is array (natural range <>) of t_att;

  constant C_ATT_BASE : t_att_arr(0 to 9) := (
    0 => (scen => 0, k => 0, fresh => true,  exp => EXP_GREEN),
    1 => (scen => 0, k => 5, fresh => false, exp => EXP_GREEN),
    2 => (scen => 1, k => 3, fresh => false, exp => EXP_GREEN),
    3 => (scen => 2, k => 2, fresh => true,  exp => EXP_17),
    4 => (scen => 2, k => 0, fresh => false, exp => EXP_GREEN),   -- escape
    5 => (scen => 2, k => 6, fresh => false, exp => EXP_17),
    6 => (scen => 3, k => 4, fresh => false, exp => EXP_1A),
    7 => (scen => 3, k => 0, fresh => false, exp => EXP_GREEN),   -- escape
    8 => (scen => 3, k => 9, fresh => false, exp => EXP_1A),
    9 => (scen => 4, k => 5, fresh => false, exp => EXP_RED_ANY));

  function f_attempts return t_att_arr is
    variable v : t_att_arr(0 to 20);
  begin
    v(0 to 9) := C_ATT_BASE;
    for k in 0 to 10 loop
      if k = 0 then
        v(10 + k) := (scen => 2, k => k, fresh => false, exp => EXP_GREEN);
      else
        v(10 + k) := (scen => 2, k => k, fresh => false, exp => EXP_17);
      end if;
    end loop;
    return v;
  end function;
  constant C_ATT_ALL : t_att_arr := f_attempts;

  function f_natt return natural is
  begin
    if G_SWEEP then
      return 21;
    end if;
    return 10;
  end function;
  constant C_NATT : natural := f_natt;

  -- serve starts for the real-Paula (constant framing) model checks
  type t_synth is record
    k    : natural;
    slip : integer;                               -- +1 inserted / -1 deleted
  end record;
  type t_synth_arr is array (natural range <>) of t_synth;
  constant C_SYN : t_synth_arr(0 to 3) := (
    0 => (k => 3, slip => 1),
    1 => (k => 7, slip => 1),
    2 => (k => 0, slip => 1),                     -- the SG=11 skip path
    3 => (k => 4, slip => -1));

  -----------------------------------------------------------------------------
  -- track builder (shared by the flux driver and the model side - fully
  -- deterministic, so both reconstruct the identical track)
  -----------------------------------------------------------------------------
  -- data bits of the odd (bits 31,29,..,1) / even (30,28,..,0) channel long
  function f_compact(l : unsigned(31 downto 0); odd : boolean)
    return unsigned is
    variable r : unsigned(15 downto 0);
  begin
    for i in 0 to 15 loop
      if odd then
        r(15 - i) := l(31 - 2 * i);
      else
        r(15 - i) := l(30 - 2 * i);
      end if;
    end loop;
    return r;
  end function;

  procedure build_track(
    gap_b : in  natural;
    bits  : out t_bitvec;
    nbits : out natural) is
    variable v_bits  : t_bitvec := (others => '0');
    variable v_n     : natural  := 0;
    variable prev_d  : std_logic := '0';
    variable s1, s2  : positive := 4711;
    variable r       : real;
    variable payload : unsigned(4095 downto 0);   -- one sector, 128 longs
    variable info    : unsigned(31 downto 0);
    variable hsum    : unsigned(31 downto 0);
    variable dsum    : unsigned(31 downto 0);
    variable pl      : unsigned(31 downto 0);
    variable c       : unsigned(15 downto 0);

    procedure put_bit(b : std_logic) is
    begin
      v_bits(v_n) := b;
      v_n := v_n + 1;
    end procedure;

    -- one data byte with proper MFM clocking (clock 1 between two 0 bits)
    procedure put_data_byte(byte : unsigned(7 downto 0)) is
    begin
      for i in 7 downto 0 loop
        if prev_d = '0' and byte(i) = '0' then
          put_bit('1');
        else
          put_bit('0');
        end if;
        put_bit(byte(i));
        prev_d := byte(i);
      end loop;
    end procedure;

    -- literal channel word (the missing-clock sync)
    procedure put_raw_word(w : unsigned(15 downto 0)) is
    begin
      for i in 15 downto 0 loop
        put_bit(w(i));
      end loop;
      prev_d := w(0);
    end procedure;

    -- one data long as its odd-bits then even-bits channel long
    procedure put_mfm_long(l : unsigned(31 downto 0)) is
      variable cc : unsigned(15 downto 0);
    begin
      cc := f_compact(l, true);
      put_data_byte(cc(15 downto 8));
      put_data_byte(cc(7 downto 0));
      cc := f_compact(l, false);
      put_data_byte(cc(15 downto 8));
      put_data_byte(cc(7 downto 0));
    end procedure;

  begin
    for sec in 0 to C_NSEC - 1 loop
      -- pre-sync: two 0x00 data bytes = channel $AAAA $AAAA (first clock
      -- follows the previous data bit, authentically allowing $2AAA)
      put_data_byte(x"00");
      put_data_byte(x"00");
      put_raw_word(x"4489");
      put_raw_word(x"4489");
      -- info long: $FF, track, sector, sectors-to-gap (11-sec: the track
      -- is laid out in written order, sector 0 first after the gap)
      info := x"FF" & to_unsigned(C_TRACK_NO, 8) & to_unsigned(sec, 8)
              & to_unsigned(C_NSEC - sec, 8);
      -- deterministic pseudo-random payload
      for i in 0 to 127 loop
        uniform(s1, s2, r);
        pl(31 downto 16) := to_unsigned(integer(trunc(r * 65536.0)), 16);
        uniform(s1, s2, r);
        pl(15 downto 0)  := to_unsigned(integer(trunc(r * 65536.0)), 16);
        payload(4095 - 32 * i downto 4064 - 32 * i) := pl;
      end loop;
      -- header checksum: XOR over the masked encoded info + label longs
      -- (label = zeros -> contributes nothing)
      hsum := (shift_right(info, 1) and C_MASK) xor (info and C_MASK);
      -- data checksum over the masked encoded data longs
      dsum := (others => '0');
      for i in 0 to 127 loop
        pl   := payload(4095 - 32 * i downto 4064 - 32 * i);
        dsum := dsum xor (shift_right(pl, 1) and C_MASK) xor (pl and C_MASK);
      end loop;
      put_mfm_long(info);
      for i in 1 to 8 loop                        -- label: 4 odd + 4 even
        put_data_byte(x"00");                     -- longs, all zero
        put_data_byte(x"00");
      end loop;
      put_mfm_long(hsum);
      put_mfm_long(dsum);
      -- data: all 128 odd longs, then all 128 even longs
      for i in 0 to 127 loop
        c := f_compact(payload(4095 - 32 * i downto 4064 - 32 * i), true);
        put_data_byte(c(15 downto 8));
        put_data_byte(c(7 downto 0));
      end loop;
      for i in 0 to 127 loop
        c := f_compact(payload(4095 - 32 * i downto 4064 - 32 * i), false);
        put_data_byte(c(15 downto 8));
        put_data_byte(c(7 downto 0));
      end loop;
    end loop;
    -- the gap: 0x00 data bytes = channel $AAAA
    for i in 1 to gap_b / 2 loop
      put_data_byte(x"00");
    end loop;
    bits  := v_bits;
    nbits := v_n;
  end procedure;

  -- bit index at which sector k's second sync word completes
  function f_sync_end(k : natural) return natural is
  begin
    return k * C_SLOT_BITS + 64;
  end function;

  -----------------------------------------------------------------------------
  -- the trackdisk decode model (pure functions/procedures over the buffer)
  -----------------------------------------------------------------------------
  function f_word(buf : t_buf; off : integer) return unsigned is
  begin
    return to_unsigned(buf(off), 8) & to_unsigned(buf(off + 1), 8);
  end function;

  function f_long(buf : t_buf; off : integer) return unsigned is
  begin
    return to_unsigned(buf(off), 8) & to_unsigned(buf(off + 1), 8)
         & to_unsigned(buf(off + 2), 8) & to_unsigned(buf(off + 3), 8);
  end function;

  procedure p_put_word(buf : inout t_buf; off : in integer;
                       w : in unsigned(15 downto 0)) is
  begin
    buf(off)     := to_integer(w(15 downto 8));
    buf(off + 1) := to_integer(w(7 downto 0));
  end procedure;

  -- decode an odd/even MFM long pair
  function f_decode_pair(o, e : unsigned(31 downto 0)) return unsigned is
  begin
    return shift_left(o and C_MASK, 1) or (e and C_MASK);
  end function;

  -- long at bit offset j of the 48 bits starting at off
  function f_ext32(buf : t_buf; off : integer; j : integer) return unsigned is
    variable v : unsigned(47 downto 0);
  begin
    v := f_long(buf, off) & f_word(buf, off + 4);
    return v(47 - j downto 16 - j);
  end function;

  -- checksum = XOR of longs, masked (aligned variant)
  function f_cksum(buf : t_buf; off : integer; nlongs : integer)
    return unsigned is
    variable v : unsigned(31 downto 0) := (others => '0');
  begin
    for i in 0 to nlongs - 1 loop
      v := v xor f_long(buf, off + 4 * i);
    end loop;
    return v and C_MASK;
  end function;

  -- the same checksum read at a bit shift (first-header path)
  function f_cksum_sh(buf : t_buf; off : integer; nlongs : integer;
                      j : integer) return unsigned is
    variable v : unsigned(31 downto 0) := (others => '0');
  begin
    for i in 0 to nlongs - 1 loop
      v := v xor f_ext32(buf, off + 4 * i, j);
    end loop;
    return v and C_MASK;
  end function;

  -- the gap+sync hunt. ptr = -1 on failure, else the address 4 bytes
  -- before the matched long; srom = trackdisk's shift code
  procedure td_hunt(buf   : in  t_buf;
                    start : in  integer;
                    len   : in  integer;
                    ptr   : out integer;
                    srom  : out integer;
                    lastl : out unsigned(31 downto 0)) is
    variable a0, aend : integer;
    variable d2, d1w  : unsigned(15 downto 0);
    variable dl       : unsigned(31 downto 0);
    variable odd_run  : boolean;
    variable v_last   : unsigned(31 downto 0) := (others => '0');
  begin
    a0   := start;
    aend := start + len;
    ptr  := -1;
    srom := -1;
    outer : loop
      d2 := f_word(buf, a0);                      -- next word
      a0 := a0 + 2;
      if d2 = x"AAAA" then
        odd_run := false;                         -- even table
      elsif d2 = x"5555" then
        odd_run := true;                          -- odd table
      else
        if aend > a0 then                         -- window not exhausted
          next outer;
        end if;
        lastl := v_last;
        return;                                   -- fail
      end if;
      -- run skip + table compare
      run : loop
        if aend <= a0 then                        -- window exhausted: fail
          lastl := v_last;
          return;
        end if;
        d1w := f_word(buf, a0);
        a0  := a0 + 2;
        if d1w = d2 then
          next run;                               -- still in the run
        end if;
        a0 := a0 - 2;                             -- back to the run end
        dl := f_long(buf, a0);                    -- run-end long
        v_last := dl;
        for e in 0 to 7 loop                      -- 8 entries
          if odd_run then
            if dl = C_TBL_ODD(e) then
              ptr   := a0 - 4;
              srom  := 15 - 2 * e;
              lastl := v_last;
              return;
            end if;
          else
            if dl = C_TBL_EVEN(e) then
              ptr   := a0 - 4;
              srom  := 14 - 2 * e;
              lastl := v_last;
              return;
            end if;
          end if;
        end loop;
        next outer;                               -- resume scan at
      end loop run;                               -- the run-end word
    end loop outer;
  end procedure;

  -- the blitter realign copy - out[i] = bits j..j+15 of source words
  -- i,i+1 (one extra source word consumed when shifted)
  procedure td_copy(buf  : inout t_buf;
                    src  : in    integer;
                    dst  : in    integer;
                    nb   : in    integer;
                    srom : in    integer) is
    variable j : integer;
    variable v : unsigned(31 downto 0);
  begin
    assert src >= dst
      report "td_copy: descending overlap (src < dst) - model violation"
      severity failure;
    j := (16 - srom) mod 16;
    for i in 0 to nb / 2 - 1 loop
      if j = 0 then
        p_put_word(buf, dst + 2 * i, f_word(buf, src + 2 * i));
      else
        v := f_word(buf, src + 2 * i) & f_word(buf, src + 2 * i + 2);
        p_put_word(buf, dst + 2 * i, v(31 - j downto 16 - j));
      end if;
    end loop;
  end procedure;

  -- the full per-attempt decode
  procedure td_decode(buf       : inout t_buf;
                      exp_track : in    natural;
                      res       : out   t_res) is
    variable r        : t_res;
    variable p, s1, j : integer;
    variable p2, s2   : integer;
    variable ll       : unsigned(31 downto 0);
    variable io, ie   : unsigned(31 downto 0);
    variable cks, stv : unsigned(31 downto 0);
    variable info     : unsigned(31 downto 0);
    variable d4       : integer;
    variable padw     : unsigned(15 downto 0);
    variable exp_sec  : integer;
    variable off      : integer;
    variable pre      : unsigned(31 downto 0);
  begin
    r := (err => 0, anchor => -1, srom1 => -1, first_sec => -1, sg => -1,
          srom2 => -1, failslot => -1, rehunt_ll => (others => '0'));

    -- initial hunt: buffer+$682, window $ABC
    td_hunt(buf, C_DEC + 2, C_HUNT1_LEN, p, s1, ll);
    if p = -1 then
      r.err := TDERR_NOSYNC;
      res := r;
      return;
    end if;
    r.anchor := p;
    r.srom1  := s1;
    j := (16 - s1) mod 16;

    -- first-header check at the source shift
    if s1 = 0 then
      io  := f_long(buf, p + 8);
      ie  := f_long(buf, p + 12);
      cks := f_cksum(buf, p + 8, 10);
      stv := f_decode_pair(f_long(buf, p + 16#30#),
                           f_long(buf, p + 16#34#));
    else
      io  := f_ext32(buf, p + 8, j);
      ie  := f_ext32(buf, p + 12, j);
      cks := f_cksum_sh(buf, p + 8, 10, j);
      stv := f_decode_pair(f_ext32(buf, p + 16#30#, j),
                           f_ext32(buf, p + 16#34#, j));
    end if;
    if cks /= stv then
      r.err := TDERR_BADHDR;                      -- header checksum
      res := r;
      return;
    end if;
    info := f_decode_pair(io, ie);
    if info(31 downto 24) /= x"FF"
       or to_integer(info(23 downto 16)) /= exp_track then
      r.err := TDERR_BADHDR;                      -- format or track
      res := r;
      return;
    end if;
    r.first_sec := to_integer(info(15 downto 8));
    r.sg        := to_integer(info(7 downto 0));
    assert r.sg >= 1 and r.sg <= 11
      report "td_decode: SG byte " & integer'image(r.sg)
             & " outside 1..11 - stimulus/model corrupt" severity failure;
    d4 := r.sg * C_SLOT_B;

    -- chunk 1: SG sectors realigned to buffer+$680
    td_copy(buf, p, C_DEC, d4, s1);

    -- gap re-hunt unless SG = 11 (the escape)
    if r.sg /= 11 then
      td_hunt(buf, p + d4 + 2, C_HUNT2_LEN, p2, s2, ll);
      r.rehunt_ll := ll;
      if p2 = -1 then
        r.err := TDERR_NOSECT;
        res := r;
        return;
      end if;
      r.srom2 := s2;
      td_copy(buf, p2, C_DEC + d4, (C_NSEC - r.sg) * C_SLOT_B, s2);
    end if;

    -- trailing pad word + forced image-start $AAAA
    padw := x"AAA8";
    if (buf(C_DEC + 16#2EC0# - 1) mod 2) = 1 then
      padw := x"2AA8";
    end if;
    p_put_word(buf, C_DEC + 16#2EC0#, padw);
    p_put_word(buf, C_DEC, x"AAAA");

    -- the per-slot literal walk, in trackdisk's check order
    exp_sec := r.first_sec;
    for slot in 0 to C_NSEC - 1 loop
      off := C_DEC + slot * C_SLOT_B;
      r.failslot := slot;
      pre := f_long(buf, off);
      if pre /= x"AAAAAAAA" and pre /= x"2AAAAAAA" then
        r.err := TDERR_BADPRE;                    -- pre-sync long
        res := r;
        return;
      end if;
      if f_long(buf, off + 4) /= x"44894489" then
        r.err := TDERR_BADPRE;                    -- sync long
        res := r;
        return;
      end if;
      if f_cksum(buf, off + 8, 10)
         /= f_decode_pair(f_long(buf, off + 16#30#),
                          f_long(buf, off + 16#34#)) then
        r.err := TDERR_BADHSUM;
        res := r;
        return;
      end if;
      info := f_decode_pair(f_long(buf, off + 8), f_long(buf, off + 12));
      if info(31 downto 24) /= x"FF"
         or to_integer(info(23 downto 16)) /= exp_track
         or to_integer(info(15 downto 8)) /= exp_sec then
        r.err := TDERR_BADID;
        res := r;
        return;
      end if;
      -- (re-encode of the sectors-to-gap byte + header checksum skipped -
      -- write preparation only, cannot influence any read verdict)
      if f_cksum(buf, off + 16#40#, 256)
         /= f_decode_pair(f_long(buf, off + 16#38#),
                          f_long(buf, off + 16#3C#)) then
        r.err := TDERR_BADDSUM;
        res := r;
        return;
      end if;
      exp_sec := (exp_sec + 1) mod C_NSEC;
    end loop;
    r.failslot := -1;
    r.err := r.first_sec;                         -- success, < 11
    res := r;
  end procedure;

  -----------------------------------------------------------------------------
  -- signals
  -----------------------------------------------------------------------------
  function f_dpll_dis return std_logic is
  begin
    if G_LEGACY then
      return '1';
    end if;
    return '0';
  end function;

  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal f_rdata  : std_logic := '1';
  signal enable   : std_logic := '0';
  signal selected : std_logic := '0';
  signal motor    : std_logic := '0';
  signal rd_data  : std_logic_vector(15 downto 0);
  signal rd_empty : std_logic;
  signal dpll_dis : std_logic := f_dpll_dis;

  signal diag_cnt_drop : unsigned(15 downto 0);
  signal diag_cnt_sync : unsigned(15 downto 0);
  signal diag_realign  : unsigned(15 downto 0);
  signal diag_fmt_bad  : unsigned(15 downto 0);
  signal diag_cap_cnt  : unsigned(15 downto 0);
  signal diag_frame_st : std_logic_vector(3 downto 0);
  signal serving_data  : std_logic := '0';
  signal wordsync_sig  : std_logic := '0';

  function f_frzdis return std_logic is
  begin
    if G_FIXED then
      return '0';
    end if;
    return '1';
  end function;
  signal frzdis : std_logic := f_frzdis;

  signal cfg_req  : integer := 0;                 -- scenario index wanted
  signal cfg_ack  : integer := -1;                -- scenario index driven
  signal pos_bit  : integer := 0;                 -- driver position (bit idx)

begin

  clk <= not clk after C_CLK / 2;

  uut : entity work.physical_fdd_top
    port map (
      clk_i            => clk,
      rst_i            => rst,
      f_index_i        => '1',
      f_track0_i       => '1',
      f_writeprotect_i => '1',
      f_diskchanged_i  => '1',
      f_rdata_i        => f_rdata,
      enable_i         => enable,
      selected_i       => selected,
      motor_i          => motor,
      side_i           => '1',
      dsksync_i        => x"4489",
      dpll_dis_i       => dpll_dis,
      framehold_dis_i  => frzdis,
      serving_data_i   => serving_data,
      wordsync_i       => wordsync_sig,
      rd_clk_i         => clk,
      rd_rst_i         => rst,
      rd_en_i          => '1',
      rd_data_o        => rd_data,
      rd_empty_o       => rd_empty,
      diag_cnt_sync_o  => diag_cnt_sync,
      diag_cnt_drop_o  => diag_cnt_drop,
      diag_fmt_bad_o   => diag_fmt_bad,
      diag_cap_count_o => diag_cap_cnt,
      diag_realign_o   => diag_realign,
      diag_frame_stat_o => diag_frame_st
    ); -- uut

  -----------------------------------------------------------------------------
  -- flux driver: loops the built track as timed RDATA edges (600 ns low
  -- pulses, debt-compensated cell grid - the tb_physical_fdd_top driver),
  -- applies the per-revolution splice, publishes the bit position, and
  -- rebuilds at revolution boundaries when the controller switches scenario
  -----------------------------------------------------------------------------
  driver : process
    variable v_bits   : t_bitvec;
    variable v_nbits  : natural := 0;
    variable v_sc     : t_scen := C_SCEN(0);
    variable v_debt   : natural;
    variable v_tcells : natural;
    variable v_wait   : integer;
    variable v_jump   : integer;
    variable v_erased : boolean;
  begin
    wait until rst = '0';
    loop
      if cfg_ack /= cfg_req then
        v_sc := C_SCEN(cfg_req);
        build_track(v_sc.gap_b, v_bits, v_nbits);
        cfg_ack <= cfg_req;
        pos_bit <= 0;
        wait for 1 us;                            -- inter-config gap
      end if;
      -- one revolution
      v_debt   := 0;
      v_tcells := 0;
      v_jump   := 0;
      for i in 0 to v_nbits - 1 loop
        if v_sc.mode /= 0 and i = C_SPLICE_BIT then
          v_jump := v_sc.jump;                    -- applies to the next edge
        end if;
        v_erased := v_sc.mode = 2
                    and i >= C_SPLICE_BIT and i < C_SPLICE_BIT + C_ERASE_BITS;
        if v_bits(i) = '1' and not v_erased then
          v_wait := v_tcells * v_sc.cell + v_jump - v_debt;
          if v_wait < 1 then
            v_wait := 1;
          end if;
          wait for v_wait * C_CLK;
          v_debt   := 0;
          v_tcells := 0;
          v_jump   := 0;
          pos_bit  <= i;
          f_rdata  <= '0';                        -- flux pulse, 600 ns low
          wait for 600 ns;
          f_rdata  <= '1';
          v_debt   := 30;
        end if;
        v_tcells := v_tcells + 1;
      end loop;
      -- close the revolution: the trailing gap cells run out in real time
      -- so the wrap-around edge lands on the exact grid
      if v_tcells * v_sc.cell > v_debt then
        wait for (v_tcells * v_sc.cell - v_debt) * C_CLK;
      end if;
    end loop;
  end process driver;

  -----------------------------------------------------------------------------
  -- controller: trackdisk-cadence attempts + the trackdisk decode, then
  -- the real-Paula constant-framing model checks and the summary
  -----------------------------------------------------------------------------
  control : process
    variable v_buf      : t_buf := (others => 0);
    variable v_res      : t_res;
    variable v_att      : t_att;
    variable v_sc       : t_scen;
    variable v_nbits    : natural;
    variable v_target   : integer;
    variable v_exp_anch : integer;
    variable v_red17    : natural := 0;
    variable v_red1a    : natural := 0;
    variable v_green_e  : natural := 0;
    variable v_reds     : natural := 0;
    variable v_sync0    : unsigned(15 downto 0);
    variable v_sync1    : unsigned(15 downto 0);
    variable v_ral0     : unsigned(15 downto 0);
    variable v_ral1     : unsigned(15 downto 0);
    variable v_fmt0     : unsigned(15 downto 0);
    variable v_cap0     : unsigned(15 downto 0);
    variable v_exp      : t_exp;
    variable v_pristine : t_buf;
    file     v_df       : text;
    variable v_dl       : line;

    -- real-Paula model state
    variable m_bits   : t_bitvec;
    variable m_nbits  : natural;
    variable m_buf    : t_buf;
    variable m_res    : t_res;
    variable m_p, m_n : integer;
    variable m_ins    : boolean;
    variable m_del    : boolean;
    variable m_w      : unsigned(15 downto 0);
    variable m_bit    : std_logic;
    variable m_del_at : integer;

    -- WORDSYNC=1 coverage state
    variable w_pairs  : natural;
    variable w_clean  : natural;
    variable w_post   : natural;
    variable w_p      : integer;
    variable w_info   : unsigned(31 downto 0);

    -- wait until the driver's position crosses 'target' (mod track)
    procedure wait_pos(target : in integer) is
      variable prev, cur : integer;
      variable crossed   : boolean;
    begin
      prev := pos_bit;
      loop
        wait on pos_bit;
        cur := pos_bit;
        if cur >= prev then
          crossed := (prev < target) and (target <= cur);
        else                                      -- wrapped
          crossed := (target > prev) or (target <= cur);
        end if;
        exit when crossed;
        prev := cur;
      end loop;
    end procedure;

    -- capture C_DMA_WORDS words from the serve-from-sync stream into the
    -- unit buffer at +$684 (the engine's phys_hunt + Paula WORDSYNC=0)
    procedure capture(buf : inout t_buf) is
      variable n       : natural := 0;
      variable hunting : boolean := true;
      variable w       : std_logic_vector(15 downto 0);
    begin
      while n < C_DMA_WORDS loop
        if rd_empty /= '0' then
          wait until rd_empty = '0';
        end if;
        w := rd_data;
        if hunting then
          if w = x"4489" then
            hunting := false;
            serving_data <= '1';       -- engine: phys_hunt done, streaming
            p_put_word(buf, C_CAP, unsigned(w));
            n := 1;
          end if;
        else
          p_put_word(buf, C_CAP + 2 * n, unsigned(w));
          n := n + 1;
        end if;
        wait until rising_edge(clk);              -- this edge pops the head
        wait for 1 ns;                            -- outputs settle
      end loop;
    end procedure;

    -- seam fingerprint: the 8 words leading into the first sync found in
    -- the re-hunt region (report-only diagnostic)
    procedure seam_report(buf : in t_buf; from_off : in integer) is
      variable o : integer;
      variable s : integer := -1;
    begin
      o := from_off;
      while o < from_off + C_HUNT2_LEN + C_SLOT_B loop
        if f_word(buf, o) = x"4489" then
          s := o;
          exit;
        end if;
        o := o + 2;
      end loop;
      if s >= 16 then
        report "  seam fingerprint (8 words up to the first post-gap sync): "
               & to_hstring(f_word(buf, s - 16)) & " "
               & to_hstring(f_word(buf, s - 14)) & " "
               & to_hstring(f_word(buf, s - 12)) & " "
               & to_hstring(f_word(buf, s - 10)) & " "
               & to_hstring(f_word(buf, s - 8)) & " "
               & to_hstring(f_word(buf, s - 6)) & " "
               & to_hstring(f_word(buf, s - 4)) & " "
               & to_hstring(f_word(buf, s - 2)) & " | "
               & to_hstring(f_word(buf, s)) & " "
               & to_hstring(f_word(buf, s + 2));
      end if;
    end procedure;

    function f_exp_str(e : t_exp) return string is
    begin
      case e is
        when EXP_GREEN   => return "decode";
        when EXP_17      => return "$17";
        when EXP_1A      => return "$1A";
        when EXP_RED_ANY => return "$17/$1A";
      end case;
    end function;

    function f_hex8(v : natural) return string is
    begin
      return to_hstring(to_unsigned(v, 8));
    end function;

  begin
    wait for 200 ns;
    rst <= '0';
    wait for 200 ns;
    enable <= '1';
    motor  <= '1';

    for a in 0 to C_NATT - 1 loop
      v_att := C_ATT_ALL(a);
      v_sc  := C_SCEN(v_att.scen);
      v_nbits := (C_SECRUN_B + v_sc.gap_b) * 8;

      -- scenario switch (deselected; driver rebuilds at the rev boundary)
      if cfg_ack /= v_att.scen then
        cfg_req <= v_att.scen;
        wait until cfg_ack = v_att.scen;
        wait for 1 us;
      end if;
      if v_att.fresh then
        v_buf := (others => 0);
      end if;

      -- select so that trackdisk's 1 ms wait ends ~1 ms before sector k's
      -- sync: the serve start lands deterministically on sector k
      v_target := (f_sync_end(v_att.k) - 32 - 1100) mod v_nbits;
      wait_pos(v_target);
      selected <= '1';
      wait for 1150 us;                           -- 1 ms wait + arm code
      v_sync0 := diag_cnt_sync;
      v_ral0  := diag_realign;
      v_fmt0  := diag_fmt_bad;
      v_cap0  := diag_cap_cnt;
      capture(v_buf);
      -- still-selected settle: a capture that was in flight at the final
      -- DMA pop (a sync inside the last ~7 words) publishes up to ~256 us
      -- later - sample the instrument counters only after it landed, so
      -- the asserts below cover the serve tail too
      wait for 300 us;
      v_sync1 := diag_cnt_sync;
      v_ral1  := diag_realign;

      -- capture-instrument framing: the capture path follows the
      -- sync-anchored diagnostic word stream, so header captures publish
      -- clean-format in every mode - including hold-mode serves whose
      -- served framing free-runs across the splice (a capture path on the
      -- served stream would decode misframed post-splice words and tick
      -- fmt_bad). The publish count guards against a vacuous pass
      -- (captures gated off entirely would also keep fmt_bad flat).
      assert diag_fmt_bad = v_fmt0
        report "capture instruments decoded " &
               integer'image(to_integer(diag_fmt_bad - v_fmt0))
               & " bad-format header(s) during the serve - the capture "
               & "framing is not sync-anchored"
        severity failure;
      -- floor derivation: a 7358-word capture spans >= 13 sector starts
      -- for every serve-start sector k (worst case crosses the 266-word
      -- gap once: 7358 >= 12*544 + 266 + margin), and each start publishes
      -- one capture; minus one publish of margin for a sync landing within
      -- C_CAP_WORDS of the window end -> 12. The G_SWEEP run checks the
      -- floor across all eleven k values.
      assert diag_cap_cnt - v_cap0 >= 12
        report "only " & integer'image(to_integer(diag_cap_cnt - v_cap0))
               & " header captures published during a full-DMA serve "
               & "(expected >= 12) - the capture path is not publishing"
        severity failure;
      serving_data <= '0';                        -- DMA done
      selected <= '0';                            -- GiveUnit: deselected
      wait for 100 us;                            -- software decode window

      -- dump the pristine capture (before the decode's blits mutate the
      -- buffer) of every splice attempt for the offline analyzer
      if G_DUMP and C_SCEN(v_att.scen).mode /= 0 then
        file_open(v_df, "splice_dump_att" & integer'image(a) & ".txt",
                  write_mode);
        write(v_dl, string'("# att=" & integer'image(a)
              & " scen=" & integer'image(v_att.scen)
              & " k=" & integer'image(v_att.k)
              & " fresh=" & boolean'image(v_att.fresh)
              & " legacy=" & boolean'image(G_LEGACY)
              & " gap_b=" & integer'image(C_SCEN(v_att.scen).gap_b)
              & " jump=" & integer'image(C_SCEN(v_att.scen).jump)
              & " mode=" & integer'image(C_SCEN(v_att.scen).mode)));
        writeline(v_df, v_dl);
        for o in 0 to C_DMA_WORDS - 1 loop
          write(v_dl, integer'image(C_CAP + 2 * o) & " "
                & to_hstring(f_word(v_buf, C_CAP + 2 * o)));
          writeline(v_df, v_dl);
        end loop;
        file_close(v_df);
        report "  capture dumped to splice_dump_att" & integer'image(a) & ".txt";
      end if;

      v_pristine := v_buf;                        -- decode blits mutate the
      td_decode(v_buf, C_TRACK_NO, v_res);        -- buffer; reports read the
                                                  -- pristine capture
      -- aligner sync-hit delta across the capture: two hits per sector
      -- boundary; a surplus = false window matches
      report "  aligner sync hits during capture: "
             & integer'image(to_integer(v_sync1 - v_sync0));

      report "ATT " & integer'image(a)
             & " scen=" & integer'image(v_att.scen)
             & " k=" & integer'image(v_att.k)
             & " fresh=" & boolean'image(v_att.fresh)
             & " -> err=$" & f_hex8(v_res.err)
             & " anchor=" & integer'image(v_res.anchor)
             & " s1=" & integer'image(v_res.srom1)
             & " sec=" & integer'image(v_res.first_sec)
             & " SG=" & integer'image(v_res.sg)
             & " s2=" & integer'image(v_res.srom2)
             & " failslot=" & integer'image(v_res.failslot)
             & " rehunt_last=" & to_hstring(v_res.rehunt_ll)
             & " (expected " & f_exp_str(v_att.exp) & ")";
      if v_res.err = TDERR_BADID or v_res.err = TDERR_NOSECT then
        seam_report(v_pristine, v_res.anchor + v_res.sg * C_SLOT_B);
      end if;

      -- model-validation invariants
      if v_att.fresh then
        v_exp_anch := (v_att.k + 1) mod C_NSEC;   -- fresh: 2nd boundary
      else
        v_exp_anch := v_att.k;                    -- stale-$AAAA: capture
        assert v_res.anchor = C_DEC and v_res.srom1 = 0
          report "stale attempt did not anchor at $680/shift0 - the "
                 & "stale-AAAA model is wrong" severity failure;
      end if;
      assert v_res.first_sec = v_exp_anch
        report "anchor sector " & integer'image(v_res.first_sec)
               & " /= scheduled " & integer'image(v_exp_anch)
               & " - serve-start scheduling broke" severity failure;

      -- the seam-event instrument: mid-serve sync matches
      -- landing mid-word are counted whether the hold is in force or not -
      -- spliced captures must show the seam, splice-free ones must not
      if C_SCEN(v_att.scen).mode /= 0 then
        assert v_ral1 /= v_ral0
          report "spliced capture produced no seam event - the realign "
                 & "instrument is blind" severity failure;
      else
        assert v_ral1 = v_ral0
          report "splice-free capture produced seam events ("
                 & integer'image(to_integer(v_ral1 - v_ral0))
                 & ") - phantom realigns" severity failure;
      end if;

      -- the expected verdicts (with the framing hold every spliced attempt
      -- must decode, chunk 2 absorbing the splice shift)
      v_exp := v_att.exp;
      if G_FIXED and v_exp /= EXP_GREEN then
        v_exp := EXP_GREEN;
        assert v_res.err < 11 and v_res.srom2 > 0
          report "framing-hold spliced attempt: err=$" & f_hex8(v_res.err)
                 & " s2=" & integer'image(v_res.srom2)
                 & " - expected a decode with a nonzero chunk-2 shift "
                 & "(the constant-framing absorption)" severity failure;
      end if;
      case v_exp is
        when EXP_GREEN =>
          assert v_res.err < 11
            report "attempt expected to decode failed with $" & f_hex8(v_res.err)
                   & " - controls/escape must decode (TB or model bug, "
                   & "or the escape branch is not real)" severity failure;
          if v_att.scen >= 2 and v_att.exp = EXP_GREEN then
            v_green_e := v_green_e + 1;           -- escape events
          end if;
        when EXP_17 =>
          assert v_res.err = TDERR_BADID
            report "expected $17 (mis-anchored re-hunt), got $"
                   & f_hex8(v_res.err)
                   & " - a decode here means realign-always framing no longer "
                   & "breaks this case" severity failure;
          v_red17 := v_red17 + 1;
        when EXP_1A =>
          assert v_res.err = TDERR_NOSECT
            report "expected $1A (re-hunt window exhausted), got $"
                   & f_hex8(v_res.err)
                   & " - a decode here means realign-always framing no longer "
                   & "breaks this case" severity failure;
          v_red1a := v_red1a + 1;
        when EXP_RED_ANY =>
          assert v_res.err = TDERR_BADID or v_res.err = TDERR_NOSECT
            report "expected $17/$1A, got $" & f_hex8(v_res.err)
            severity failure;
      end case;
      if v_res.err >= 11 then
        v_reds := v_reds + 1;
      end if;
    end loop;

    assert diag_cnt_drop = 0
      report "front-end FIFO overflowed during the run" severity failure;
    -- whole-run backstop: no capture anywhere in the matrix may decode a
    -- bad format byte - closes the per-attempt assert windows' edges
    -- (inter-attempt gaps and anything a baseline resample would absorb)
    assert diag_fmt_bad = 0
      report "bad-format captures leaked outside the per-attempt assert "
             & "windows (" & integer'image(to_integer(diag_fmt_bad)) & ")"
      severity failure;

    ---------------------------------------------------------------------------
    -- WORDSYNC=1 coverage (the X-Copy class): under live WORDSYNC=1 the
    -- framing hold must not engage - real Paula re-syncs its shifter per
    -- matching word in that mode, and X-Copy's copies depend on the
    -- per-sector realignment. A hold that ignored WORDSYNC would pass the
    -- trackdisk matrix above (which runs WORDSYNC=0) yet break that class,
    -- so this block checks it: with realignment active, every post-splice
    -- sector sync appears as an aligned [4489][4489] word pair in the
    -- capture and its sector decodes
    -- clean at word alignment; with the framing mistakenly held, the
    -- post-splice stream is misframed and carries no aligned sync pair at
    -- all (a 1-bit-shifted 0x4489 reads 0x8912/0xA244, and 0x4489 cannot
    -- occur inside legal MFM data).
    ---------------------------------------------------------------------------
    if cfg_ack /= 2 then
      cfg_req <= 2;                               -- splice +65, gap 532
      wait until cfg_ack = 2;
      wait for 1 us;
    end if;
    wordsync_sig <= '1';
    v_buf := (others => 0);
    v_target := (f_sync_end(2) - 32 - 1100) mod ((C_SECRUN_B + 532) * 8);
    wait_pos(v_target);
    selected <= '1';
    wait for 1150 us;
    v_fmt0 := diag_fmt_bad;
    capture(v_buf);
    wait for 300 us;                    -- tail settle (see the matrix loop)
    -- still serving: the framing hold must be off under WORDSYNC=1
    -- (frame_stat = {3: ctrl-bit7, 2: serving-data, 1: wordsync, 0: hold})
    assert diag_frame_st(2) = '1' and diag_frame_st(1) = '1'
      report "WORDSYNC=1 serve not visible in the frame status (TB wiring)"
      severity failure;
    assert diag_frame_st(0) = '0'
      report "framing hold engaged during a WORDSYNC=1 serve - the hold "
             & "must be WORDSYNC-conditional (the X-Copy class would break)"
      severity failure;
    serving_data <= '0';
    selected     <= '0';
    wordsync_sig <= '0';
    wait for 100 us;
    assert diag_fmt_bad = v_fmt0
      report "bad-format header captures during the WORDSYNC=1 serve"
      severity failure;

    -- the X-Copy verdict over the capture. k=2 geometry: 9 pre-splice
    -- starts (s2..s10), the gap (splice ~ word 5046), then s0..s4 =
    -- 14 aligned pairs, 13 of them with the full 542 sector words inside
    -- the capture. (A pair's second 0x4489 cannot start a phantom pair:
    -- the word after it is header content.)
    w_pairs := 0;
    w_clean := 0;
    w_post  := 0;
    for o in 0 to C_DMA_WORDS - 2 loop
      if f_word(v_buf, C_CAP + 2 * o) = x"4489"
         and f_word(v_buf, C_CAP + 2 * o + 2) = x"4489" then
        w_pairs := w_pairs + 1;
        if o + 542 <= C_DMA_WORDS then
          w_p    := C_CAP + 2 * o;
          w_info := f_decode_pair(f_long(v_buf, w_p + 4),
                                  f_long(v_buf, w_p + 8));
          assert w_info(31 downto 24) = x"FF"
                 and to_integer(w_info(23 downto 16)) = C_TRACK_NO
            report "WORDSYNC=1: aligned pair at word " & integer'image(o)
                   & " has a bad info long " & to_hstring(w_info)
            severity failure;
          assert f_cksum(v_buf, w_p + 4, 10)
                 = f_decode_pair(f_long(v_buf, w_p + 44),
                                 f_long(v_buf, w_p + 48))
            report "WORDSYNC=1: header checksum fail at word "
                   & integer'image(o) severity failure;
          assert f_cksum(v_buf, w_p + 60, 256)
                 = f_decode_pair(f_long(v_buf, w_p + 52),
                                 f_long(v_buf, w_p + 56))
            report "WORDSYNC=1: data checksum fail at word "
                   & integer'image(o) severity failure;
          w_clean := w_clean + 1;
          if o > 5000 then
            w_post := w_post + 1;
          end if;
        end if;
      end if;
    end loop;
    report "WORDSYNC=1 coverage: " & integer'image(w_pairs)
           & " aligned sync pairs, " & integer'image(w_clean)
           & " clean sectors (" & integer'image(w_post) & " post-splice)";
    assert w_pairs >= 13
      report "WORDSYNC=1: only " & integer'image(w_pairs) & " aligned "
             & "sync pairs in the spliced capture (expected 14) - "
             & "post-splice realignment is not happening: the framing "
             & "hold ignored WORDSYNC" severity failure;
    assert w_post >= 3
      report "WORDSYNC=1: no clean post-splice sectors - realignment "
             & "did not recover the splice shift" severity failure;

    ---------------------------------------------------------------------------
    -- real-Paula model: the same spliced flux, constant word framing (no
    -- mid-capture realign, as on a real A500 and with the framing hold).
    -- The separator-level effect of the splice is the once-per-rev bit
    -- slip: one '0' inserted for the +jump (class-flip) event, one '0'
    -- removed for the -jump event - exactly what both separators produce.
    -- With constant framing the post-splice sync sits at a constant bit
    -- offset which the re-hunt tables absorb via chunk 2's own shift.
    ---------------------------------------------------------------------------
    build_track(532, m_bits, m_nbits);
    -- the deleted bit must be a '0' of the gap run (a deleted '1' would be
    -- content damage, not a framing slip)
    m_del_at := C_SPLICE_BIT;
    while m_bits(m_del_at) /= '0' loop
      m_del_at := m_del_at + 1;
    end loop;
    for s in C_SYN'range loop
      -- steady-state buffer: zeros + the stale $AAAA leader in front of
      -- the capture (the post-decode state of the real unit buffer)
      m_buf := (others => 0);
      p_put_word(m_buf, C_DEC, x"AAAA");
      p_put_word(m_buf, C_DEC + 2, x"AAAA");
      -- constant-framing capture from sector k's first sync word
      m_p   := f_sync_end(C_SYN(s).k) - 32;
      m_n   := 0;
      m_ins := true;
      m_del := true;
      m_w   := (others => '0');
      while m_n < C_DMA_WORDS * 16 loop
        if C_SYN(s).slip = 1 and m_ins and m_p = C_SPLICE_BIT then
          m_bit := '0';                           -- the inserted slip bit
          m_ins := false;
        else
          if C_SYN(s).slip = -1 and m_del and m_p = m_del_at then
            m_p   := (m_p + 1) mod m_nbits;       -- the deleted slip bit
            m_del := false;
          end if;
          m_bit := m_bits(m_p);
          m_p   := (m_p + 1) mod m_nbits;
          if m_p = 0 then                         -- new revolution: the
            m_ins := true;                        -- splice strikes again
            m_del := true;
          end if;
        end if;
        m_w := m_w(14 downto 0) & m_bit;
        if (m_n mod 16) = 15 then
          p_put_word(m_buf, C_CAP + 2 * (m_n / 16), m_w);
        end if;
        m_n := m_n + 1;
      end loop;
      td_decode(m_buf, C_TRACK_NO, m_res);
      report "REAL-PAULA MODEL k=" & integer'image(C_SYN(s).k)
             & " slip=" & integer'image(C_SYN(s).slip)
             & " -> err=$" & f_hex8(m_res.err)
             & " SG=" & integer'image(m_res.sg)
             & " s2=" & integer'image(m_res.srom2);
      assert m_res.err < 11
        report "REAL-PAULA MODEL FAILED with $" & f_hex8(m_res.err)
               & " - constant framing must absorb the splice (checker or "
               & "stimulus broken)"
        severity failure;
      if C_SYN(s).k /= 0 then
        assert m_res.srom2 > 0
          report "REAL-PAULA MODEL: chunk 2 took shift "
                 & integer'image(m_res.srom2)
                 & " - the splice slip never reached the framing "
                 & "(stimulus model bug)" severity failure;
      end if;
    end loop;

    ---------------------------------------------------------------------------
    -- summary
    ---------------------------------------------------------------------------
    report "----------------------------------------------------------------";
    report "SUMMARY legacy=" & boolean'image(G_LEGACY)
           & ": red$17=" & integer'image(v_red17)
           & " red$1A=" & integer'image(v_red1a)
           & " spliced-escapes-decoded=" & integer'image(v_green_e)
           & " total_red=" & integer'image(v_reds);
    if G_FIXED then
      report "VERDICT (framing hold): every spliced attempt decodes "
             & "through the real front-end, chunk 2 absorbing the splice "
             & "shift.";
    else
      report "VERDICT (realign-always control): every spliced non-escape "
             & "attempt failed through the real front-end while the "
             & "constant-framing model of the same flux decodes. Escapes "
             & "only at the SG=11 anchor (escape arc = gap + 1 sector of "
             & "select time).";
    end if;
    report "TB_FDD_SPLICE (legacy=" & boolean'image(G_LEGACY)
           & " fixed=" & boolean'image(G_FIXED)
           & " sweep=" & boolean'image(G_SWEEP) & "): ALL CHECKS PASS";
    stop;
  end process control;

end architecture sim;
