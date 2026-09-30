# HW2_a 呼吸燈（白板架構版）

## 用途

依課堂白板架構實作單色呼吸燈：FSM1 在「變亮ing／變暗ing」之間切換，調整亮、暗兩段的上限
`upbnd1` / `upbnd2`；HW1 的雙計數器 FSM 以這兩個上限交替計數，數 count1 時 LED 亮，
形成 PWM。完整規格見 [`SPEC.md`](SPEC.md)。

- 目標器件：`xc7k70tfbv676-1`（與 HW1 相同）
- Top 模組：`HW_2_a`，測試檔：`HW_2_a_tb`（看波形）、`HW_2_a_check_tb`（自我檢查）
- 另一版（RGB、按鈕、Gamma）見 [`../HW2`](../HW2/README.md)

## 架構

![HW2_a 架構圖](docs/architecture.svg)

| 區塊 | 功能 |
|---|---|
| FSM1 | 兩狀態 Moore FSM：變亮ing 時 `upbnd1++`、`upbnd2--`，變暗ing 時相反；已最亮／已最暗時換方向 |
| `upbnd1` / `upbnd2` | 亮、暗兩段的 clk 數，和固定為 `MAX`，所以 PWM 週期不變 |
| HW1 雙計數器 | 獨立 entity `HW_1_pwm`，由 `HW_2_a` 實例化為 `hw1`：count1 數滿 `upbnd1`（亮）→ count2 數滿 `upbnd2`（暗）→ 重複；上限為 0 的一段直接跳過；上限在每個週期開頭鎖存 |
| PWM counter | 數 PWM 週期，每撐 1/30 s 送出 `step`，亮度走一階；只在週期交界更新，沒有殘缺脈波 |

預設 `MAX = 30`、`STEP_HZ = 30`：亮度 31 階（0 ~ 30），單程 1 s、呼吸週期 2 s；
PWM 週期 30 clk（100 MHz 下約 3.33 MHz）。

### 介面

| Port | 方向 | 寬度 | 說明 |
|---|---|---|---|
| `clk` / `reset` | in | 1 | 系統時脈；同步 reset，高電位有效 |
| `led` | out | 1 | PWM 輸出 |

Generic：`CLK_FREQ_HZ`、`MAX`、`STEP_HZ`、`LED_ACTIVE_LOW`，說明見 SPEC §3.1。

## 檔案

| 路徑 | 內容 |
|---|---|
| `SPEC.md` | 設計規格：FSM1、HW1 PWM、節拍計算、驗證計畫 |
| `src/HW_2_a.vhd` | Top：FSM1、upbnd1 / upbnd2、PWM counter，實例化 HW1 |
| `src/HW_1_pwm.vhd` | HW1 雙計數器改為 PWM（上限由 port 輸入） |
| `sim/HW_2_a_tb.vhd` | 看波形用測試檔（專案模擬 top）：縮小參數跑約 3 次呼吸，模擬時間已設為 8100 ns |
| `sim/HW_2_a_check_tb.vhd` | 自我檢查測試檔，逐個 PWM 週期比對三角波；`run all` 後印出 PASS / FAIL |
| `Create-Project.tcl` | 由本目錄原始碼建立 Vivado 專案 |
| `docs/architecture.svg` | 架構圖 |

## 進度與待辦

- [x] 規格（`SPEC.md`）
- [x] 設計原始碼（`src/HW_2_a.vhd`、`src/HW_1_pwm.vhd`）
- [x] 測試檔（`HW_2_a_tb` 看波形、`HW_2_a_check_tb` 自我檢查，xsim 2018.3 通過）
- [ ] 約束檔：板子型號、時脈、LED 腳位確認後建立 `constraints/`（見 SPEC §9）

## 使用

在儲存庫根目錄執行：

```powershell
.\Manage-FPGA.ps1 create HW2_a   # 建立 vivado/HW2_a/HW2_a.xpr，已存在時不要重複執行
.\Manage-FPGA.ps1 open HW2_a
```

本版只存在於 Git，舊 Vivado 專案沒有對應檔案，不需要 `import`。

模擬：Vivado 中 Run Behavioral Simulation 預設跑 `HW_2_a_tb`（8100 ns），可從 Scope 把 `uut` 內的
`fsm1_state`、`upbnd1`、`upbnd2`，以及 `uut/hw1` 內的 `state`、`b1`、`b2` 拖進波形；要跑自我檢查時，把 sim_1 的 top 改成
`HW_2_a_check_tb` 後執行 `run all`。
