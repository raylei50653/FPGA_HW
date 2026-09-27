# HW1

- `src/HW_1.vhd`：可綜合的設計原始碼。
- `sim/HW_1_tb.vhd`：Vivado 模擬測試檔。

## 從舊專案匯入

在儲存庫根目錄執行：

```powershell
.\HW1\Import-FromVivado.ps1
```

預設來源為 `D:\Documents\vivado_2\project_1`。內容不同時腳本會停止；
確認要用舊專案版本覆蓋後，改用 `.\HW1\Import-FromVivado.ps1 -Update`。
其他來源可加上 `-VivadoProjectPath 'D:\path\to\project'`。

## 建立專案

```powershell
& 'C:\Xilinx\Vivado\2018.3\bin\vivado.bat' -mode batch -source .\HW1\Create-Project.tcl
```

產生的專案位於 `vivado/HW1/HW1.xpr`，直接引用本目錄的 VHDL 檔。
已有專案時請直接開啟，不要重複執行建立腳本。
