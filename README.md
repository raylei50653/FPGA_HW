# FPGA 作業

本儲存庫以作業編號管理 Vivado 原始碼。舊專案
`D:\Documents\vivado_2\project_1`（Vivado 2018.3）是持續匯入的來源；
每次在舊專案修改檔案後，執行對應作業的匯入腳本，再檢查與提交 Git 變更。

## 目錄結構

```text
HW<n>/
├── src/          可綜合的設計原始碼
├── sim/          模擬測試檔
├── constraints/  約束檔（需要時建立）
├── Import-FromVivado.ps1  從舊專案匯入該作業檔案
├── Create-Project.tcl     由 Git 原始碼建立該作業專案
└── README.md              該作業的操作說明
Manage-FPGA.ps1   Git 倉庫內的統一操作入口
scripts/          共用腳本
vivado/           本機產生的專案，Git 不追蹤
```

`<n>` 是作業編號，例如 `HW1`。同一作業的另一個版本加小寫字母後綴，例如 `HW2_a`，
Top 模組與測試檔對應為 `HW_2_a`、`HW_2_a_tb`。新增作業時依照相同結構建立 `HW<n>/`；
每份作業會產生獨立的 Vivado 專案。與本倉庫同層的
`D:\Documents\vivado_2\README.md` 有本機快速入門；在該目錄可直接執行 `.\fpga.ps1`。
從 GitHub 複製此倉庫到其他位置時，可直接使用倉庫內的 `.\Manage-FPGA.ps1`。

## 從舊專案匯入

以下以 HW1 為例，在儲存庫根目錄的 PowerShell 執行：

```powershell
.\Manage-FPGA.ps1 import HW1
git diff -- HW1
```

腳本會掃描舊專案的 `project_1.srcs`，依檔名中的作業編號將 HDL 與 XDC
檔案複製到該作業目錄；模擬檔放在 `sim/`，約束檔放在 `constraints/`。
內容相同的檔案會略過；若同名檔案內容不同，腳本會停止。確認要以舊專案
版本更新 Git 檔案時，執行 `.\Manage-FPGA.ps1 import HW1 -Update`。
匯入不會刪除 Git 中的檔案，
也不會修改舊專案。IP、block design 等複合檔案，以及器件、Top 等專案設定，
不會由此腳本同步；變更這些內容時需另行更新建立腳本。

## 建立與開啟專案

以下以 HW1 為例，在 PowerShell 執行：

```powershell
.\Manage-FPGA.ps1 create HW1
.\Manage-FPGA.ps1 open HW1
```

建立其他作業時，將指令中的 `HW1` 換成對應的 `HW<n>`。腳本使用相對於自身位置的
路徑，因此可從其他工作目錄執行；產生的專案會直接引用已匯入本儲存庫的原始碼。

若新檔案類型未被匯入或建立腳本涵蓋，需同步修改共用腳本。`vivado/`、編譯結果、
紀錄、波形及 bitstream 均不納入 Git。
