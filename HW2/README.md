# HW2 8 顆 LED 呼吸燈（作業版：[HW2_a](../HW2_a/README.md)）

## 用途

以 PWM 驅動板上 8 顆 LED，亮度依固定週期平滑地「漸亮 → 漸暗」循環。三顆按鈕切換模式
（**基礎**：8 顆同步呼吸；**流水**：呼吸波形依序延遲、亮光沿 LED 流動，可選方向）、最亮停留時間與
呼吸／恆亮。完整規格與設計理由見 [`SPEC.md`](SPEC.md)。

- 目標板：e-elements EGO-XZ7（`xc7z020clg484-1`，100 MHz），腳位見 `constraints/HW_2.xdc`
- LED：`led(0)` ~ `led(7)` 接 LD0 ~ LD7；按鈕 reset = BTNC、mode = BTNU、hold = BTNL、breath = BTNR
- Top 模組：`HW_2`，測試檔：`HW_2_tb`（VHDL 2008）
- 全同步設計、單一時脈域；時間參數皆為 generic，模擬時可縮短

## 架構

上排是操作：按鈕改三個設定、右上是三種模式下 8 顆 LED 某一瞬間的樣子；下排是資料流：主波形 → 延遲線 → PWM → 8 顆 LED。圓圈編號對應 `src/HW_2.vhd` 的區段，見下表。

![HW2 架構圖](docs/architecture.svg)

| Process | 功能 | 規格章節 |
|---|---|---|
| ① PWM 計數器 | 前除頻 390 + 8 bit 計數，約 1 kHz；標出每個 PWM 週期結束點 | §4 |
| ② 亮度 FSM | 主波形：漸亮 → 最亮停留 → 漸暗 → 最暗，週期固定約 2 s；停留佔比可切換，關閉呼吸時恆亮 | §5.1、§5.3、§5.4 |
| ③ 1 ms 節拍 | 提供按鈕去彈跳與長按計時的時間基準 | §7.2 |
| ④ 按鈕介面 ×3 | 同步、20 ms 去彈跳；放開為短按，按滿 1 s 為長按 | §7.2 |
| ⑤ 設定暫存器 | 保存 `mode` / `hold_sel` / `breath_en`，短按切下一項、長按回預設 | §7.1 |
| ⑥ 流水延遲線 | 主波形每個 PWM 週期存進歷史 RAM；基礎模式 8 顆讀同一筆，流水模式 LD k 讀 k × 1/8 週期前的值；讀出後 Gamma 校正（γ = 2.2） | §5.2、§6 |
| ⑦ duty 影子暫存器 ×8 | 只在 PWM 週期交界更新 duty，避免殘缺脈波 | §4.2 |
| ⑧ 比較器與輸出 ×8 | 計數值 < duty 時點亮，依 LED 極性輸出 | §4.2 |

### 模式

| `mode` | 按 BTNU 切換 | LED 的樣子 |
|---|---|---|
| `00` | 基礎（預設、長按回到這裡） | 8 顆同步呼吸 |
| `01` | 流水 → | 呼吸波形由 LD0 依序傳到 LD7，相鄰兩顆差 1/8 週期 |
| `10` | 流水 ← | 方向相反，由 LD7 傳到 LD0 |

停留佔比（BTNL）與呼吸開關（BTNR）在每種模式下都有效。8 顆 LED 全部用來呼吸，所以不再輸出
`status`。

### 介面

| Port | 方向 | 寬度 | 說明 |
|---|---|---|---|
| `clk` / `reset` | in | 1 | 系統時脈；同步 reset，高電位有效 |
| `btn_mode` | in | 1 | 模式：基礎 → 流水 → → 流水 ← |
| `btn_hold` | in | 1 | 最亮停留佔比：0% / 25% / 50% / 75%（呼吸週期固定不變） |
| `btn_breath` | in | 1 | 呼吸／恆亮切換 |
| `led` | out | 8 | PWM 輸出，`led(k)` 接 LD k |

主要 generic：`CLK_FREQ_HZ`、`PWM_BITS`、`PWM_DIV`、`CYCLE_PERIODS`、`GAMMA_EN`、
`LED_ACTIVE_LOW`、`BTN_ACTIVE_LOW` 等，預設值與說明見 SPEC §3.1。

## 檔案

| 路徑 | 內容 |
|---|---|
| `SPEC.md` | 設計規格：參數計算、FSM、流水延遲線、按鈕行為、驗證計畫、腳位 |
| `src/HW_2.vhd` | 設計原始碼 |
| `sim/HW_2_tb.vhd` | 自我檢查測試檔（VHDL 2008），涵蓋 SPEC §9 全部項目；`run all` 約 2.61 ms 後印出 PASS / FAIL |
| `constraints/HW_2.xdc` | EGO-XZ7 腳位檔 |
| `Create-Project.tcl` | 由本目錄原始碼建立 Vivado 專案（測試檔設為 VHDL 2008、模擬時間 2700 us） |
| `Import-FromVivado.ps1` | 從舊 Vivado 專案匯入 HW2 檔案（舊專案是 RGB 版，見下方說明） |
| `docs/architecture.svg` | 架構圖（各 process 功能） |

## 進度與待辦

- [x] 規格（`SPEC.md`）
- [x] 設計原始碼（`src/HW_2.vhd`，Vivado 2018.3 實作：約 290 LUT、0.5 Block RAM，WNS +3.2 ns）
- [x] 測試檔（`sim/HW_2_tb.vhd`，xsim 2018.3 通過）
- [x] 約束檔（`constraints/HW_2.xdc`，EGO-XZ7 腳位見 SPEC §10）

## 使用

在儲存庫根目錄執行：

```powershell
.\Manage-FPGA.ps1 create HW2   # 建立 vivado/HW2/HW2.xpr，已存在時不要重複執行
.\Manage-FPGA.ps1 open HW2
```

舊 Vivado 專案（`project_1`、`project_2`）裡的 `HW_2.vhd` 是改版前的 RGB 版，**不要再 `import`**，
否則會用舊版覆蓋這裡的檔案。自己在 Vivado 加檔案時，記得把 `HW_2_tb.vhd` 的 File Type 設為
VHDL 2008（Source File Properties → Type），否則 external name 無法編譯。
