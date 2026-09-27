# HW2

- `src/`：可綜合的設計原始碼，目前尚未加入。
- `sim/HW_2_tb.vhd`：Vivado 模擬測試檔。

原始 Vivado 專案目錄中雖有 HW2 測試檔，但專案設定尚未納入該檔。
匯入腳本會從舊專案的 `project_1.srcs` 找到此測試檔。

## 從舊專案匯入

在儲存庫根目錄執行：

```powershell
.\HW2\Import-FromVivado.ps1
```

預設來源為 `D:\Documents\vivado_2\project_1`。內容不同時腳本會停止；
確認要用舊專案版本覆蓋後，改用 `.\HW2\Import-FromVivado.ps1 -Update`。
其他來源可加上 `-VivadoProjectPath 'D:\path\to\project'`。

## 建立專案

請先將 HW2 設計原始碼匯入 `src/`，再執行：

```powershell
& 'C:\Xilinx\Vivado\2018.3\bin\vivado.bat' -mode batch -source .\HW2\Create-Project.tcl
```

產生的專案位於 `vivado/HW2/HW2.xpr`。目前 `src/` 尚無設計檔，
因此建立腳本會提示缺少原始碼。
