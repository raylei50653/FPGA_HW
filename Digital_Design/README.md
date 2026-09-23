# Digital Design

Coursework is organized by homework number:

```text
Digital_Design/
|-- HW1/
|   |-- src/
|   `-- sim/
|-- HW2/
|   |-- src/
|   `-- sim/
|-- scripts/
`-- vivado/project_1/
```

- `HW<n>/src/` contains synthesizable design sources.
- `HW<n>/sim/` contains testbenches.
- `vivado/project_1/` is a local copy of the complete Vivado project.
- Generated Vivado output remains available locally but is excluded from Git.

## Synchronize a Vivado project

From PowerShell:

```powershell
.\scripts\Sync-VivadoProject.ps1
```

The default source is `D:\Documents\vivado_2\project_1`. To use another project:

```powershell
.\scripts\Sync-VivadoProject.ps1 -VivadoProjectPath 'D:\path\to\project'
```

The script recognizes filenames beginning with `HW_1`, `HW1`, `HW-1`, and so on.
Files whose name ends in `_tb`, or whose Vivado path is under `sim_<n>`, are copied
to `sim/`; other matching source files are copied to `src/`.
