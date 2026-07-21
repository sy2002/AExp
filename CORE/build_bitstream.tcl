# Build one board bitstream in Vivado batch mode - normally called by
# build_all.sh:
#
#   vivado -mode batch -source build_bitstream.tcl -tclargs <R3|R4|R5|R6> [jobs]
#
# Prints one machine-readable "RESULT <board> ..." line and exits non-zero on
# any failure. After the bitstream is written, the routed design is opened and
# the sign-off gates of CORE.xdc are checked explicitly, because those
# constraints silently no-op when instance names drift.

set board [lindex $argv 0]
set jobs  [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4}]

open_project CORE-${board}.xpr

reset_run synth_1               ;# force a clean rebuild (invalidates impl_1)
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "RESULT $board FAILED synth_1: [get_property STATUS [get_runs synth_1]]"
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "RESULT $board FAILED impl_1: [get_property STATUS [get_runs impl_1]]"
    exit 1
}

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} {
    puts "RESULT $board TIMING-FAILED WNS=$wns WHS=$whs"
    exit 2
}

open_run impl_1
set gate {}
if {[llength [get_pins -quiet {CORE/hr_core_speed_reg[0]/Q}]] == 0} {
    lappend gate "set_case_analysis target CORE/hr_core_speed_reg\[0\]/Q missing"
}
foreach {clk want} {main_clk 35.165} {
    set c [get_clocks -quiet $clk]
    if {[llength $c] == 0} {
        lappend gate "generated clock $clk missing"
    } elseif {[expr {abs([get_property PERIOD $c] - $want)}] > 0.05} {
        lappend gate "$clk period [get_property PERIOD $c] ns, expected ~$want ns (fast leg not constrained?)"
    }
}
if {[llength $gate] > 0} {
    foreach g $gate { puts "GATE $board: $g" }
    puts "RESULT $board SIGNOFF-FAILED WNS=$wns WHS=$whs"
    exit 3
}

puts "RESULT $board OK WNS=$wns WHS=$whs bit=CORE-${board}.runs/impl_1/mega65_[string tolower $board].bit"
close_project
