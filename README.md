# FPGA Homework

Vivado project sources are organized by homework number. The VHDL files were
imported from `D:\Documents\vivado_2\project_1` (Vivado 2018.3). Edit the files
in this repository going forward; the original project is an archive, not a
second source to synchronize.

```text
HW1/src/             Synthesizable design
HW1/sim/             Testbench
HW2/src/             Synthesizable design (currently empty)
HW2/sim/             Testbench
scripts/             Vivado project creation script
vivado/              Locally generated projects (ignored by Git)
```

## Create and open a Vivado project

Run from PowerShell, with Vivado 2018.3 installed:

```powershell
& 'C:\Xilinx\Vivado\2018.3\bin\vivado.bat' -mode batch -source .\scripts\Create-VivadoProject.tcl -tclargs HW1
& 'C:\Xilinx\Vivado\2018.3\bin\vivado.bat' .\vivado\HW1\HW1.xpr
```

The script can also be run from another working directory. It uses paths relative
to its own location and references the repository's source files directly. It
creates a separate project for each homework under `vivado/`. Select `HW2` when
its design source has been added to `HW2/src/`; the current original Vivado
project contains only the HW1 design and HW1 testbench. `HW2/sim/HW_2_tb.vhd`
exists but is not part of that original project.

Keep RTL, testbenches, constraints, and IP configuration files in the homework
directories. Do not copy sources into the Vivado project when adding them through
the GUI. Add new source file paths to the project script if its automatic file
selection does not cover them. The generated `vivado/` directory, run results,
logs, waveforms, and bitstreams are excluded from Git.
