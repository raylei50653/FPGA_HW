# FPGA 作業

本儲存庫以作業編號管理 Vivado 原始碼。現有 VHDL 檔案來自
`D:\Documents\vivado_2\project_1`（Vivado 2018.3）。往後請修改本儲存庫中的檔案，
避免與原專案各自維護一份。

## 目錄結構

```text
HW<n>/
├── src/          可綜合的設計原始碼
├── sim/          模擬測試檔
└── constraints/  約束檔（需要時建立）
scripts/          建立 Vivado 專案的 Tcl 腳本
vivado/           本機產生的專案，Git 不追蹤
```

`<n>` 是作業編號，例如 `HW1`。新增作業時依照相同結構建立 `HW<n>/`；
每份作業會產生獨立的 Vivado 專案。

## 建立與開啟專案

以下以 HW1 為例，在 PowerShell 執行：

```powershell
& 'C:\Xilinx\Vivado\2018.3\bin\vivado.bat' -mode batch -source .\scripts\Create-VivadoProject.tcl -tclargs HW1
& 'C:\Xilinx\Vivado\2018.3\bin\vivado.bat' .\vivado\HW1\HW1.xpr
```

建立其他作業時，將指令中的 `HW1` 換成對應的 `HW<n>`。腳本使用相對於自身位置的
路徑，因此可從其他工作目錄執行；產生的專案會直接引用本儲存庫的原始碼。
目前 HW2 只有測試檔，須先將設計原始碼放入 `HW2/src/`，才能建立 HW2 專案。

新增 RTL、測試檔、約束檔或 IP 設定檔時，請放在對應的作業目錄。
透過 Vivado 介面加入檔案時，不要勾選複製到專案的選項。
若新檔案類型未被建立腳本涵蓋，需同步修改腳本。`vivado/`、編譯結果、
紀錄、波形及 bitstream 均不納入 Git。
