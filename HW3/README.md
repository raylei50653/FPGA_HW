# HW3 VGA 掃描：RGB 色塊與旋轉 3D 多面體

## 用途

以 VGA 掃描（640×480@60）顯示圖形，按 BTNU 切換兩個模式。基本要求為每色 1 bit；Bonus 不限色深，
內部全程 RGB888，輸出位元數由 `RED_BITS`、`GREEN_BITS`、`BLUE_BITS` 決定（1 ~ 8）。

- **基本模式**（reset 後）：R、G、B 三個矩形色塊，位置與大小可任意設定，重疊處加色混合
- **旋轉多面體模式**（Bonus）：立方體、八面體、十二面體在 3D 空間中翻滾；每個像素由一條
  「矩陣 × 向量 + 比較樹」管線即時算出視線從哪個面進入、從哪個面離開，不需要 framebuffer。
  BTND 切換兩種樣式：
  - **實心打光**：依光照打亮度、描出白色稜線
  - **全息點雲**：只用稀疏的點描出正面與背面，背面稜線畫成虛線，形體像半透明的全息投影

完整規格與設計理由見 [`SPEC.md`](SPEC.md)。

- 目標板：e-elements EGO-XZ7（`xc7z020clg484-1`，100 MHz），腳位見 `constraints/HW_3.xdc`
- Top 模組：`HW_3`，測試檔：`HW_3_tb`（VHDL 2008）
- 單一時脈域，像素率 100 MHz / 4 = 25 MHz（以時脈致能推進）
- 內部有一組 RGB888 視訊串流（`stream_*`），之後加 HDMI 只要換掉輸出級，見 SPEC §6.4

![模擬擷取的畫面](docs/sim_frames.png)

左：RGB888 視訊串流（多位元 DAC 或 HDMI）；右：每色 1 bit 的 VGA 輸出。由上而下：實心打光、
轉速 ×8 反轉、全息點雲。全息點雲只用純色與白色，1 bit 輸出時也完全相同。

## 色塊的位置與大小

在 `src/HW_3.vhd` 的 generic（或 Vivado 的 Settings → Generics）修改，單位為像素：

| 色塊 | 左上角 | 寬 × 高 |
|---|---|---|
| R | `R_X`、`R_Y`（60, 160） | `R_W` × `R_H`（160 × 160） |
| G | `G_X`、`G_Y`（240, 160） | `G_W` × `G_H`（160 × 160） |
| B | `B_X`、`B_Y`（420, 160） | `B_W` × `B_H`（160 × 160） |

## 多面體怎麼算

凸多面體 = F 個半空間 `n_k · P ≤ a` 的交集。每個像素是一條往螢幕裡的光線 (dx, dy, z)，代進每個面
得到一個深度 `z_k = (a − nx·dx − ny·dy) / nz`，它對 (dx, dy) 是一次式：

```text
每幀一次：  法向量轉 Rx(α)·Ry(β)，算光照與 1/nz，得到 F×3 矩陣 W   （垂直遮沒時算）
每個像素：  v = W · (dx, dy, 1)                                      （2F 個 DSP 同時乘）
判斷：      max(正面 v) ≤ min(背面 v) → 在形體內，看到的是 v 最大的正面
稜線：      這個像素看到的面和左邊、上面兩個像素不同 → 白色（兩個行緩衝）
```

全息點雲用的是同一條光線的兩個交點：

```text
進入點、離開點：比較樹同時記下最遠的正面與最近的背面
面座標 (u, v)：  兩個交點在各自面上的座標，又是 (dx, dy) 的一次式（每個交點 2 × 2 個 DSP）
點：            (u, v) 所在的 8 × 8 像素格子查雜湊，75% 的格子放一個點，位置略為錯開
```

點黏在面上、跟著形體一起轉，正面與背面的點同時畫出來，就有透視感。不需要點表，也不需要 framebuffer。

想換成二十面體，把 `src/HW_3.vhd` 的 `SOLID_A` 某一項改成 3（0 立方體、1 八面體、2 十二面體、
3 二十面體）。

## 架構

| 檔案 | 區段 | 功能 |
|---|---|---|
| `src/HW_3.vhd` | ① 像素致能 | 每 4 個 clk 一拍 `pix_ce` |
| `src/HW_3_timing.vhd` | ② 視訊時序 | 640×480@60 計數器，輸出對齊的 x / y / de / hs / vs |
| `src/HW_3_btn.vhd`、`src/HW_3.vhd` | ③ 按鈕 ×4、SW0、設定 | 去彈跳，保存模式、轉速、方向、樣式 |
| `src/HW_3.vhd` | ④ 角度累加 | 每幀更新三個形體繞 x、y 軸的角度 |
| `src/HW_3_solid.vhd` | ⑤ 多面體管線 ×3 | 每幀算 W、各面顏色與面座標係數；每像素 14 級管線：平移 → 乘 → 加 → 比較樹 → 判斷 → 面座標 → 點雲 |
| `src/HW_3.vhd` | ⑥ 延遲線 | 座標與同步延遲 14 個像素，對齊 ⑤ |
| `src/HW_3.vhd` | ⑦ 合成 | 基本模式畫色塊；多面體模式蓋上打光顏色或點雲，描正面稜線與背面虛線，輸出 RGB888 串流 |
| `src/HW_3.vhd` | ⑧ VGA 輸出級 | 取各色高位元、同步負極性 |

## 操作

| 輸入 | 功能 | LED |
|---|---|---|
| BTNC | reset（回到基本模式） | |
| BTNU | 模式：基本色塊 ↔ 旋轉多面體 | LD0 亮 = 旋轉多面體 |
| SW0 | 撥上暫停旋轉 | LD1 亮 = 轉動中 |
| BTNR | 反轉 | LD2 |
| BTNL | 轉速 ×1 → ×2 → ×4 → ×8 | LD4..LD3 |
| BTND | 實心打光 ↔ 全息點雲 | LD5 亮 = 全息點雲 |

LD7 約 1 Hz 閃爍，表示時序在跑（沒接螢幕也看得到）。

## 模擬

```powershell
.\Manage-FPGA.ps1 create HW3
.\Manage-FPGA.ps1 open HW3
```

在 Vivado 執行 Run Simulation（已設定跑 160 ms，約 10 分鐘），Tcl Console 最後應印出
`HW_3_tb PASS`。測試檔會用浮點數重做一次光線投射，逐像素比對看到的面，每個形體不符的像素最多約
30 個（約 0.1%，都在面與面的交界）；全息點雲則重做兩個交點、面座標與雜湊，逐像素比對點的位置。擷取的畫面存成 PPM，位置在
`vivado/HW3/HW3.sim/sim_1/behav/xsim/`，可用 GIMP、IrfanView 等打開。

不想開 Vivado 時可以改用 GHDL（先 `winget install --id ghdl.ghdl.ucrt64.mcode -e`）：

```powershell
.\HW3\Run-GHDL.ps1
```

畫面存在 `vivado/HW3/ghdl/`。兩個模擬器的差別見 SPEC §9.1。

## 上板前要補的東西

EGO-XZ7 的 Vivado board file 沒有 VGA 腳位。上板前請：

1. 在 `constraints/HW_3.xdc` 的 TODO 區段填入 `vga_r`、`vga_g`、`vga_b`、`vga_hs`、`vga_vs` 的腳位
2. 每色接約 270 Ω 串聯電阻到 VGA 接頭（螢幕端 75 Ω，得到約 0.7 V）
3. 若改接多位元電阻 DAC，修改 `HW_3` 的 `RED_BITS`、`GREEN_BITS`、`BLUE_BITS`

沒填腳位也能綜合，但 bitstream 會被 DRC 擋下。
