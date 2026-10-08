set cur_dir [exec pwd]
# Vivado runs this pre-synthesis hook in the synthesis run directory
# (CORE/CORE-R<n>.runs/synth_1/), three levels below the repository root.

cd ../../../CORE/m2m-rom/
exec ./make_rom.sh <@stdin >@stdout 2>@stderr
cd $cur_dir

