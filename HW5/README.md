# HW5 HDMI 乒乓球

## 用途

HW4 的雙人乒乓球搬到螢幕上：畫面從板上的 HDMI 輸出（640×480@60），經典 Pong 的玩法。
BTNL、BTNR 是左右球拍，**按住往上、放開往下**；球碰到上下牆反彈，碰到球拍依打在哪一段決定反彈角度，
越過畫面左右邊就失分。分數以七段數字畫在畫面上方，先到 5 分獲勝。
完整規格與設計理由見 [`SPEC.md`](SPEC.md)。

- 目標板：e-elements EGO-XZ7（`xc7z020clg484-1`，100 MHz），腳位見 `constraints/HW_5.xdc`
- Top 模組：`HW_5`，測試檔：`HW_5_tb`（整體）、`HW_5_game_tb`（遊戲邏輯），皆為 VHDL 2008
- 單一時脈域；像素以 `pix_ce`（25 MHz）推進，遊戲每幀（約 16.8 ms）在垂直遮沒期間更新一次
- 不用 framebuffer：每個像素直接比對球、球拍、牆、中線、數字這些矩形
- HDMI 輸出級與 ADV7511 設定沿用 HW3（YCbCr 4:2:2）

![模擬畫面](docs/sim_play.png)

`HW_5_tb` 擷取的 RGB888 串流：左方剛發球，球離開左球拍。

## 怎麼玩

| 輸入 | 功能 |
|---|---|
| BTNL | 左球拍：按住往上、放開往下；輪到左方發球時按下發球 |
| BTNR | 右球拍：按住往上、放開往下；輪到右方發球時按下發球 |
| SW0 | 起始球速：撥下慢（4 像素／幀）、撥上快（6 像素／幀），發球時決定 |
| BTNC | reset：比分歸零、左方發球 |

1. Reset 後球黏在左球拍上，左方按 BTNL 發球。
2. 用「按一下、放一下」控制球拍高度，把球接回去。打在球拍上半段往上彈、下半段往下彈，越靠邊角度越大。
3. 每回擊 2 次球速加快一階，最快 12 像素／幀（約 0.77 s 跨過球場）。
4. 球越過自己這一邊就失分。得分方的數字與 LED 長條閃 2 秒，接著由得分方發球。
5. 先到 5 分獲勝，勝方數字持續閃爍；任一方按鍵重新開局，由勝方先發。

![畫面配置](docs/screen.svg)

| LED | SERVE / PLAY | POINT / OVER |
|---|---|---|
| LD0 | SW0（亮 = 快速發球） | 得分方的分數長條，1 Hz 閃（同 HW4） |
| LD6 | ADV7511 設定成功 | |
| LD7 | 心跳（約 1 Hz） | |

## 架構

![HW5 架構圖](docs/architecture.svg)

| 編號 | 功能 | 檔案 | 規格章節 |
|---|---|---|---|
| ① 像素致能 | 每 4 個 clk 一拍 `pix_ce` | `src/HW_5.vhd` | §9 |
| ② 視訊時序 | 640×480@60 計數器，`frame_tick` 標出每幀的遮沒開始（沿用 HW3） | `src/HW_5_timing.vhd` | §9 |
| ③ 按鈕 ×2、SW0 | 同步、去彈跳；按下脈衝 `press` 與按住電位 `held` | `src/HW_5_btn.vhd` | §11 |
| ④ 遊戲 FSM | SERVE / PLAY / POINT / OVER；按鍵事件鎖存到下一幀處理 | `src/HW_5_game.vhd` | §6、§7 |
| ⑤ 球與球拍 | 每幀移動、撞牆、穿過擊球面判定擊球、失分 | `src/HW_5_game.vhd` | §5、§7 |
| ⑥ 計分與閃爍 | 比分、1 Hz 閃爍 | `src/HW_5_game.vhd` | §5.6、§10 |
| ⑦ 畫面合成 | R1 每個物件一個比較、R2 依疊放順序選顏色 | `src/HW_5.vhd` | §4、§8 |
| ⑧ HDMI 輸出級 | RGB → YCbCr 4:2:2、IOB 暫存器、像素時脈；I2C 設定 ADV7511（沿用 HW3） | `src/HW_5.vhd`、`src/HW_5_hdmi_cfg.vhd` | §9 |
| ⑨ LED | 心跳、HDMI 狀態、分數長條 | `src/HW_5.vhd` | §10 |

![HW5 狀態機](docs/fsm.svg)

![擊球判定](docs/hit_zone.svg)

主要 generic：`PADDLE_SPEED`（球拍速度）、`VX_SLOW`、`VX_FAST`、`VX_STEP`、`VX_MAX`、`SPEEDUP_HITS`
（球速與加速）、`WIN_SCORE`（勝分，1 ~ 8）、`BLINK_HALF_FRAMES`、`SCORE_SHOW_FRAMES`，預設值見 SPEC §3.1。

## 檔案

| 路徑 | 內容 |
|---|---|
| `SPEC.md` | 設計規格：畫面配置、遊戲規則、狀態機、每幀更新、畫面合成、驗證計畫、腳位 |
| `src/HW_5.vhd` | Top：像素致能、按鈕、畫面合成、HDMI 輸出級、LED |
| `src/HW_5_game.vhd` | 遊戲邏輯：狀態機、球與球拍、計分、閃爍 |
| `src/HW_5_btn.vhd` | 按鈕介面（HW4 的版本多一個 `held` 輸出） |
| `src/HW_5_timing.vhd` | 視訊時序（與 HW3 相同） |
| `src/HW_5_hdmi_cfg.vhd` | ADV7511 I2C 設定（與 HW3 相同） |
| `sim/HW_5_game_tb.vhd` | 遊戲邏輯測試檔：內含參考模型，自動對打 30000 幀逐幀比對 |
| `sim/HW_5_tb.vhd` | 整體測試檔：3 幀畫面逐像素比對參考畫面、HDMI 輸出、同步時序、ADV7511 設定 |
| `constraints/HW_5.xdc` | EGO-XZ7 腳位檔（HDMI 腳位同 HW3） |
| `Create-Project.tcl` | 由本目錄原始碼建立 Vivado 專案（測試檔設為 VHDL 2008） |
| `Import-FromVivado.ps1` | 從舊 Vivado 專案匯入 HW5 檔案 |
| `docs/` | 架構圖、畫面配置、擊球判定、狀態機、模擬畫面 |

## 建立與模擬

```powershell
.\Manage-FPGA.ps1 create HW5
.\Manage-FPGA.ps1 open HW5
```

在 Vivado 按 Run Simulation 跑 `HW_5_tb`（約 30 ms 模擬時間，畫面存成 `frame_serve.ppm`、
`frame_play.ppm`，在 `vivado/HW5/HW5.sim/sim_1/behav/xsim/`）。要跑遊戲邏輯測試檔時，在 Sources 視窗的
Simulation Sources 對 `HW_5_game_tb` 按右鍵 → Set as Top（約 1.2 ms 模擬時間）。兩個測試檔最後都印出
PASS / FAIL。

## 進度與待辦

- [x] 規格（`SPEC.md`）
- [x] 設計原始碼、測試檔（xsim 2018.3：`HW_5_game_tb PASS`、`HW_5_tb PASS`）
- [x] Vivado 2018.3 實作：747 LUT、279 FF，沒有 DSP、BRAM；WNS +0.70 ns、WHS +0.13 ns，bitstream 產生成功
- [ ] 上板試玩：調整 `PADDLE_SPEED`、加速幅度、確認顏色
