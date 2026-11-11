library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
-- HW5 HDMI 乒乓球：PL 部分（規格見 HW5/SPEC.md）
-- ============================================================================
--
--   雙人 Pong，畫面從 HDMI 輸出（640×480@60）。USB 鍵盤由 PS 讀取（HW_5 top 的 block design），
--   按鍵狀態從 kbd[7:0] 進來：左方 W / S 上下、D 發球；右方 ↑ / ↓ 上下、← 發球。BTNL / BTNR 也能發球。
--   球碰到上下牆反彈，碰到球拍依打在哪一段決定反彈角度；越過畫面左右邊就失分，對方得 1 分。
--   分數以七段數字畫在畫面上方，得分時閃爍；先到 WIN_SCORE 分獲勝。
--
-- 資料流（全部在 clk 時脈域；像素以 pix_ce 推進，遊戲以 frame_tick 推進）
--
--   ① pix_ce ─► ② 時序產生器 ──(x, y, de, hs, vs)──► ⑦ 合成 R1 → R2 ──(RGB888 串流)──► ⑧ HDMI 輸出級
--                    │ frame_tick                          ▲                                 │ ADV7511
--                    ▼                                     │ 物件座標、分數、閃爍            │（I2C 設定）
--   ③ 鍵盤 kbd、按鈕 ×2、SW0 ───────────────► ④⑤⑥ HW_5_game ────────────────────► ⑨ LED
--
-- 管線延遲（以像素 = pix_ce 計，相對時序產生器的輸出）
--   合成 R1 / R2          +1 / +2   （R2 的輸出就是 stream_*）
--   HDMI：YCbCr / 腳位    +3 / +4
--   同步訊號跟著資料走同一條管線，所以畫面與 hs / vs 永遠對齊
--
-- 遊戲座標只在 frame_tick（垂直遮沒開頭）改變，整幀可視期間都不變，畫面不會撕裂
-- ============================================================================
entity HW_5_pong is
    Generic (
        PIX_DIV           : positive := 4;          -- 100 MHz / 4 = 25 MHz 像素率；HDMI 需要 >= 2
        H_ACTIVE          : positive := 640;        -- 畫面配置固定為 640×480
        H_FP              : positive := 16;
        H_SYNC            : positive := 96;
        H_BP              : positive := 48;
        V_ACTIVE          : positive := 480;
        V_FP              : positive := 10;
        V_SYNC            : positive := 2;
        V_BP              : positive := 33;
        SYNC_ACTIVE_LOW   : boolean  := true;       -- 640×480@60 的 hs / vs 為負極性
        HDMI_CFG_DELAY    : positive := 2**24;      -- ADV7511 每輪設定之前等待的 clk 數（約 168 ms）
        I2C_DIV           : positive := 250;        -- SCL = 100 MHz / (4 × 250) = 100 kHz
        DEBOUNCE_CYCLES   : positive := 2_000_000;  -- 20 ms
        PADDLE_SPEED      : positive := 6;          -- 球拍按住上／下鍵時每幀移動的像素
        VX_SLOW           : positive := 4;          -- 發球水平速度：SW0 撥下（像素／幀）
        VX_FAST           : positive := 6;          -- 發球水平速度：SW0 撥上
        VX_STEP           : positive := 2;          -- 每次加速增加的水平速度
        VX_MAX            : positive := 12;         -- 水平速度上限
        SPEEDUP_HITS      : positive := 2;          -- 每回擊幾次加速一階
        WIN_SCORE         : positive := 5;          -- 1 ~ 8
        BLINK_HALF_FRAMES : positive := 30;         -- 約 0.5 s
        SCORE_SHOW_FRAMES : positive := 120;        -- 約 2 s
        BTN_ACTIVE_LOW    : boolean  := false;
        LED_ACTIVE_LOW    : boolean  := false
    );
    Port (
        clk      : in    STD_LOGIC;
        reset    : in    STD_LOGIC;                     -- 同步、高電位有效（BTNC）
        btn_l    : in    STD_LOGIC;                     -- 左方發球（BTNL，和鍵盤 D 相同）
        btn_r    : in    STD_LOGIC;                     -- 右方發球（BTNR，和鍵盤 ← 相同）
        kbd      : in    STD_LOGIC_VECTOR(7 downto 0);  -- PS 寫的按鍵狀態（SPEC §12.3）：
                                                        --   0 W、1 S、2 D、3 ↑、4 ↓、5 ←、6 鍵盤已連線、7 PS 心跳
        sw_speed : in    STD_LOGIC;                     -- 起始球速：撥下慢、撥上快（SW0）
        hdmi_clk : out   STD_LOGIC;                     -- ADV7511 像素時脈（上升緣取樣）
        hdmi_d   : out   STD_LOGIC_VECTOR(23 downto 0); -- ADV7511 D23..D0：D23..16 Cb / Cr、D15..8 Y、D7..0 = 0
        hdmi_hs  : out   STD_LOGIC;
        hdmi_vs  : out   STD_LOGIC;
        hdmi_scl : out   STD_LOGIC;                     -- ADV7511 設定用 I2C（開汲極：只拉低或放開）
        hdmi_sda : inout STD_LOGIC;
        led      : out   STD_LOGIC_VECTOR(7 downto 0)
    );
end HW_5_pong;

architecture Behavioral of HW_5_pong is

    subtype rgb_t is std_logic_vector(23 downto 0);    -- R(23..16) G(15..8) B(7..0)

    ----------------------------------------------------------------------------
    -- 畫面配置（SPEC §4.1）：所有 x 邊界都是偶數，HDMI 4:2:2 不會在邊緣出現色邊
    ----------------------------------------------------------------------------
    constant WALL_T   : natural := 8;         -- 上下牆厚度
    constant FIELD_B  : natural := 472;       -- 下牆上緣
    constant NET_X0   : natural := 318;       -- 中線 318 ~ 322
    constant NET_X1   : natural := 322;
    constant PAD_W    : natural := 12;        -- 球拍 12 × 96、球 12 × 12（與 HW_5_game 相同）
    constant PAD_H    : natural := 96;
    constant PAD_L_X  : natural := 32;        -- 左球拍 32 ~ 44
    constant PAD_R_X  : natural := 596;       -- 右球拍 596 ~ 608
    constant BALL     : natural := 12;
    constant DIG_W    : natural := 32;        -- 七段數字格子 32 × 56，筆畫粗 8
    constant DIG_H    : natural := 56;
    constant DIG_T    : natural := 8;
    constant DIG_L_X  : natural := 256;       -- 左分數 256 ~ 288
    constant DIG_R_X  : natural := 352;       -- 右分數 352 ~ 384
    constant DIG_Y    : natural := 24;        -- 24 ~ 80

    constant BG_C     : rgb_t := x"000000";
    constant WALL_C   : rgb_t := x"FFFFFF";
    constant NET_C    : rgb_t := x"808080";
    constant BALL_C   : rgb_t := x"FFFFFF";
    constant LEFT_C   : rgb_t := x"FF8000";   -- 左玩家：球拍與分數
    constant RIGHT_C  : rgb_t := x"00C0FF";   -- 右玩家

    -- 七段數字（SPEC §4.3）：bit 6..0 = g f e d c b a
    type seg_table_t is array (0 to 15) of std_logic_vector(6 downto 0);
    constant SEG : seg_table_t := (
        "0111111", "0000110", "1011011", "1001111", "1100110",
        "1101101", "1111101", "0000111", "1111111", "1101111",
        "0000000", "0000000", "0000000", "0000000", "0000000", "0000000");

    -- LED 分數長條（同 HW4）：亮幾顆 = 幾分，從得分方那一端長出來
    type bar_table_t is array (0 to 15) of std_logic_vector(7 downto 0);
    constant BAR_L : bar_table_t := (
        "00000000", "10000000", "11000000", "11100000", "11110000",
        "11111000", "11111100", "11111110", "11111111",
        "11111111", "11111111", "11111111", "11111111", "11111111", "11111111", "11111111");
    constant BAR_R : bar_table_t := (
        "00000000", "00000001", "00000011", "00000111", "00001111",
        "00011111", "00111111", "01111111", "11111111",
        "11111111", "11111111", "11111111", "11111111", "11111111", "11111111", "11111111");

    -- BT.709 有限範圍 RGB -> YCbCr，係數 × 256 取整數（同 HW3 SPEC §6.5）；
    -- 偏移量多加 0.5，讓除以 256 變成四捨五入，被除數也不會是負數
    constant Y_OFS_X256 : natural := 4224;    -- (16  + 0.5) × 256
    constant C_OFS_X256 : natural := 32896;   -- (128 + 0.5) × 256

    -- ① 像素致能
    signal div_cnt    : integer range 0 to PIX_DIV - 1 := 0;
    signal pix_ce     : std_logic := '0';

    -- ② 視訊時序
    signal t_x        : unsigned(11 downto 0);
    signal t_y        : unsigned(11 downto 0);
    signal t_de       : std_logic;
    signal t_hs       : std_logic;
    signal t_vs       : std_logic;
    signal t_frame    : std_logic;
    signal frame_tick : std_logic;

    -- ③ 按鈕與開關
    signal press_l    : std_logic;
    signal press_r    : std_logic;
    signal kbd_s1     : std_logic_vector(7 downto 0) := (others => '0');
    signal kbd_s      : std_logic_vector(7 downto 0) := (others => '0');   -- 同步後的按鍵狀態
    signal kbd_d      : std_logic_vector(7 downto 0) := (others => '0');   -- 上一拍，取發球鍵的上升緣
    signal serve_l    : std_logic;            -- 左方發球：BTNL 或 D 剛按下
    signal serve_r    : std_logic;
    signal sw_s1      : std_logic := '0';
    signal sw_speed_s : std_logic := '0';

    -- ④⑤⑥ 遊戲（HW_5_game 的輸出）
    signal phase      : integer range 0 to 3;   -- 0 SERVE、1 PLAY、2 POINT、3 OVER
    signal server     : std_logic;
    signal ball_x     : unsigned(9 downto 0);
    signal ball_y     : unsigned(8 downto 0);
    signal pad_l_y    : unsigned(8 downto 0);
    signal pad_r_y    : unsigned(8 downto 0);
    signal score_l    : unsigned(3 downto 0);
    signal score_r    : unsigned(3 downto 0);
    signal blink_on   : std_logic;
    signal heartbeat  : std_logic;

    -- ⑦ 合成：R1 的比較（組合邏輯）
    signal px         : integer range 0 to 4095;
    signal py         : integer range 0 to 4095;
    signal bx         : integer range 0 to 1023;
    signal by         : integer range 0 to 511;
    signal pl         : integer range 0 to 511;
    signal pr         : integer range 0 to 511;
    signal in_dig_l   : std_logic;              -- 像素落在左分數的格子裡
    signal in_dig_r   : std_logic;
    signal seg_pos_l  : std_logic_vector(6 downto 0);  -- 像素落在格子裡的哪幾段（g .. a）
    signal seg_pos_r  : std_logic_vector(6 downto 0);
    signal dx_l       : integer range -4096 to 4095;   -- 相對格子左上角的座標
    signal dx_r       : integer range -4096 to 4095;
    signal dy         : integer range -4096 to 4095;
    signal show_ball  : std_logic;
    signal show_l     : std_logic;              -- 左分數這一幀要不要畫（閃爍）
    signal show_r     : std_logic;

    signal c_ball     : std_logic;
    signal c_pad_l    : std_logic;
    signal c_pad_r    : std_logic;
    signal c_dig_l    : std_logic;
    signal c_dig_r    : std_logic;
    signal c_net      : std_logic;
    signal c_wall     : std_logic;

    -- ⑦ 合成：R1 暫存器（每個物件一個旗標）
    signal h_ball     : std_logic := '0';
    signal h_pad_l    : std_logic := '0';
    signal h_pad_r    : std_logic := '0';
    signal h_dig_l    : std_logic := '0';
    signal h_dig_r    : std_logic := '0';
    signal h_net      : std_logic := '0';
    signal h_wall     : std_logic := '0';
    signal r1_de      : std_logic := '0';
    signal r1_hs      : std_logic := '0';
    signal r1_vs      : std_logic := '0';

    -- ⑦ 合成：R2 輸出，RGB888 視訊串流
    signal stream_rgb : rgb_t := (others => '0');
    signal stream_de  : std_logic := '0';
    signal stream_hs  : std_logic := '0';
    signal stream_vs  : std_logic := '0';

    -- ⑧ HDMI：RGB -> YCbCr（第一拍），再排成 4:2:2（第二拍）
    signal s_r        : integer range 0 to 255;
    signal s_g        : integer range 0 to 255;
    signal s_b        : integer range 0 to 255;
    signal ycc_y      : unsigned(7 downto 0) := (others => '0');
    signal ycc_cb     : unsigned(7 downto 0) := (others => '0');
    signal ycc_cr     : unsigned(7 downto 0) := (others => '0');
    signal ycc_de     : std_logic := '0';
    signal ycc_hs     : std_logic := '0';
    signal ycc_vs     : std_logic := '0';
    signal cr_sel     : std_logic := '0';       -- 0 = 這個像素送 Cb、1 = 送 Cr；每行第一個像素送 Cb

    -- HDMI 輸出暫存器（放進 IOB，見 HW_5.xdc）：hd_reg(23..16) 色度 Cb / Cr、hd_reg(15..8) 亮度 Y
    signal hd_reg     : std_logic_vector(23 downto 8) := (others => '0');
    signal hhs_reg    : std_logic := '0';
    signal hvs_reg    : std_logic := '0';
    signal hclk_reg   : std_logic := '0';
    signal hdmi_ok    : std_logic;              -- ADV7511 最近一輪設定全部收到 ACK

    -- ⑨ LED（內部一律高電位 = 亮）
    signal led_reg    : std_logic_vector(7 downto 0) := (others => '0');

begin

    assert PIX_DIV >= 2
        report "HDMI pixel clock is divided from clk, PIX_DIV must be at least 2" severity failure;
    assert H_ACTIVE = 640 and V_ACTIVE = 480
        report "The HW5 screen layout is fixed at 640x480" severity failure;

    ----------------------------------------------------------------------------
    -- ① 像素致能：每 PIX_DIV 個 clk 一拍
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                div_cnt <= 0;
                pix_ce  <= '0';
            elsif div_cnt = PIX_DIV - 1 then
                div_cnt <= 0;
                pix_ce  <= '1';
            else
                div_cnt <= div_cnt + 1;
                pix_ce  <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- ② 視訊時序（沿用 HW3）
    ----------------------------------------------------------------------------
    u_timing : entity work.HW_5_timing
        generic map (
            H_ACTIVE => H_ACTIVE, H_FP => H_FP, H_SYNC => H_SYNC, H_BP => H_BP,
            V_ACTIVE => V_ACTIVE, V_FP => V_FP, V_SYNC => V_SYNC, V_BP => V_BP
        )
        port map (
            clk => clk, reset => reset, ce => pix_ce,
            x => t_x, y => t_y, de => t_de, hs => t_hs, vs => t_vs,
            frame_start => t_frame
        );

    -- frame_start 維持一個像素（PIX_DIV 個 clk），與 pix_ce 相交剛好一拍
    frame_tick <= t_frame and pix_ce;

    ----------------------------------------------------------------------------
    -- ③ 按鈕（同步、去彈跳、按下脈衝與按住電位）與 SW0 兩級同步
    ----------------------------------------------------------------------------
    u_btn_l : entity work.HW_5_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_l, press => press_l, held => open);

    u_btn_r : entity work.HW_5_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_r, press => press_r, held => open);

    process(clk)
    begin
        if rising_edge(clk) then
            sw_s1      <= sw_speed;
            sw_speed_s <= sw_s1;
        end if;
    end process;

    -- 鍵盤：PS 經 AXI GPIO 寫的按鍵狀態。AXI 也跑在 clk，但 PS 沒開機時這組訊號不受控，照樣過兩級同步；
    --   發球鍵（D、←）取上升緣變成單拍脈衝，和 BTNL / BTNR 的按下脈衝 OR 起來
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                kbd_s1 <= (others => '0');
                kbd_s  <= (others => '0');
                kbd_d  <= (others => '0');
            else
                kbd_s1 <= kbd;
                kbd_s  <= kbd_s1;
                kbd_d  <= kbd_s;
            end if;
        end if;
    end process;

    serve_l <= press_l or (kbd_s(2) and not kbd_d(2));
    serve_r <= press_r or (kbd_s(5) and not kbd_d(5));

    ----------------------------------------------------------------------------
    -- ④⑤⑥ 遊戲：每個 frame_tick 更新一次
    ----------------------------------------------------------------------------
    u_game : entity work.HW_5_game
        generic map (
            PADDLE_SPEED => PADDLE_SPEED,
            VX_SLOW => VX_SLOW, VX_FAST => VX_FAST, VX_STEP => VX_STEP, VX_MAX => VX_MAX,
            SPEEDUP_HITS => SPEEDUP_HITS, WIN_SCORE => WIN_SCORE,
            BLINK_HALF_FRAMES => BLINK_HALF_FRAMES, SCORE_SHOW_FRAMES => SCORE_SHOW_FRAMES
        )
        port map (
            clk => clk, reset => reset, frame_tick => frame_tick,
            press_l => serve_l, press_r => serve_r,
            up_l => kbd_s(0), dn_l => kbd_s(1), up_r => kbd_s(3), dn_r => kbd_s(4),
            sw_speed => sw_speed_s,
            phase => phase, server => server,
            ball_x => ball_x, ball_y => ball_y, pad_l_y => pad_l_y, pad_r_y => pad_r_y,
            score_l => score_l, score_r => score_r, blink_on => blink_on, heartbeat => heartbeat
        );

    ----------------------------------------------------------------------------
    -- ⑦ 合成 R1：每個物件各自判斷 x0 <= x < x1 且 y0 <= y < y1（SPEC §4、§8）
    ----------------------------------------------------------------------------
    px <= to_integer(t_x);
    py <= to_integer(t_y);
    bx <= to_integer(ball_x);
    by <= to_integer(ball_y);
    pl <= to_integer(pad_l_y);
    pr <= to_integer(pad_r_y);

    -- 球只在 SERVE、PLAY 畫；POINT 時得分方、OVER 時勝方的數字跟著 blink_on 閃
    show_ball <= '1' when phase <= 1 else '0';
    show_l    <= '0' when phase >= 2 and server = '1' and blink_on = '0' else '1';
    show_r    <= '0' when phase >= 2 and server = '0' and blink_on = '0' else '1';

    c_wall  <= '1' when py < WALL_T or (py >= FIELD_B and py < V_ACTIVE) else '0';
    c_net   <= '1' when px >= NET_X0 and px < NET_X1 and py >= WALL_T and py < FIELD_B and
                        t_y(3) = '0' else '0';                      -- y mod 16 < 8：虛線
    c_pad_l <= '1' when px >= PAD_L_X and px < PAD_L_X + PAD_W and py >= pl and py < pl + PAD_H else '0';
    c_pad_r <= '1' when px >= PAD_R_X and px < PAD_R_X + PAD_W and py >= pr and py < pr + PAD_H else '0';
    c_ball  <= '1' when show_ball = '1' and px >= bx and px < bx + BALL and py >= by and py < by + BALL else '0';

    -- 七段數字：先判斷像素在格子裡的哪幾段，再和 SEG(分數) 取 AND
    dx_l <= px - DIG_L_X;
    dx_r <= px - DIG_R_X;
    dy   <= py - DIG_Y;
    in_dig_l <= '1' when dx_l >= 0 and dx_l < DIG_W and dy >= 0 and dy < DIG_H else '0';
    in_dig_r <= '1' when dx_r >= 0 and dx_r < DIG_W and dy >= 0 and dy < DIG_H else '0';

    -- 段的位置（以格子左上角為原點，SPEC §4.3 的表）
    --   a 上橫、b 右上、c 右下、d 下橫、e 左下、f 左上、g 中橫
    seg_pos_l(0) <= '1' when dy < DIG_T else '0';
    seg_pos_l(1) <= '1' when dx_l >= DIG_W - DIG_T and dy < DIG_H / 2 + DIG_T / 2 else '0';
    seg_pos_l(2) <= '1' when dx_l >= DIG_W - DIG_T and dy >= DIG_H / 2 - DIG_T / 2 else '0';
    seg_pos_l(3) <= '1' when dy >= DIG_H - DIG_T else '0';
    seg_pos_l(4) <= '1' when dx_l < DIG_T and dy >= DIG_H / 2 - DIG_T / 2 else '0';
    seg_pos_l(5) <= '1' when dx_l < DIG_T and dy < DIG_H / 2 + DIG_T / 2 else '0';
    seg_pos_l(6) <= '1' when dy >= DIG_H / 2 - DIG_T / 2 and dy < DIG_H / 2 + DIG_T / 2 else '0';

    seg_pos_r(0) <= '1' when dy < DIG_T else '0';
    seg_pos_r(1) <= '1' when dx_r >= DIG_W - DIG_T and dy < DIG_H / 2 + DIG_T / 2 else '0';
    seg_pos_r(2) <= '1' when dx_r >= DIG_W - DIG_T and dy >= DIG_H / 2 - DIG_T / 2 else '0';
    seg_pos_r(3) <= '1' when dy >= DIG_H - DIG_T else '0';
    seg_pos_r(4) <= '1' when dx_r < DIG_T and dy >= DIG_H / 2 - DIG_T / 2 else '0';
    seg_pos_r(5) <= '1' when dx_r < DIG_T and dy < DIG_H / 2 + DIG_T / 2 else '0';
    seg_pos_r(6) <= '1' when dy >= DIG_H / 2 - DIG_T / 2 and dy < DIG_H / 2 + DIG_T / 2 else '0';

    c_dig_l <= '1' when in_dig_l = '1' and show_l = '1' and
                        (seg_pos_l and SEG(to_integer(score_l))) /= "0000000" else '0';
    c_dig_r <= '1' when in_dig_r = '1' and show_r = '1' and
                        (seg_pos_r and SEG(to_integer(score_r))) /= "0000000" else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                h_ball  <= c_ball;
                h_pad_l <= c_pad_l;
                h_pad_r <= c_pad_r;
                h_dig_l <= c_dig_l;
                h_dig_r <= c_dig_r;
                h_net   <= c_net;
                h_wall  <= c_wall;
                r1_de   <= t_de;
                r1_hs   <= t_hs;
                r1_vs   <= t_vs;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- ⑦ 合成 R2：依疊放順序選顏色（SPEC §4.2），遮沒期間輸出黑色
    --   球 > 左球拍 > 右球拍 > 分數 > 中線 > 上下牆 > 背景
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                if r1_de = '0' then
                    stream_rgb <= BG_C;
                elsif h_ball = '1' then
                    stream_rgb <= BALL_C;
                elsif h_pad_l = '1' then
                    stream_rgb <= LEFT_C;
                elsif h_pad_r = '1' then
                    stream_rgb <= RIGHT_C;
                elsif h_dig_l = '1' then
                    stream_rgb <= LEFT_C;
                elsif h_dig_r = '1' then
                    stream_rgb <= RIGHT_C;
                elsif h_net = '1' then
                    stream_rgb <= NET_C;
                elsif h_wall = '1' then
                    stream_rgb <= WALL_C;
                else
                    stream_rgb <= BG_C;
                end if;
                stream_de <= r1_de;
                stream_hs <= r1_hs;
                stream_vs <= r1_vs;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- ⑧ HDMI 輸出級（沿用 HW3 SPEC §6.5）
    --   板子只接了 ADV7511 的 D23..D0，所以送 16 bit YCbCr 4:2:2：D23..16 = Cb / Cr 輪流、D15..8 = Y；
    --   ADV7511 再用內建的 CSC 轉回 RGB；板子沒有接 DE，由 ADV7511 的 DE 產生器依 hs、vs 自己算
    --
    --   第一拍：RGB -> YCbCr
    --   第二拍：4:2:2 = 每個像素都送自己的 Y，偶數像素送 Cb、奇數像素送 Cr（每行從 Cb 開始）
    --   像素時脈：由 div_cnt 解出，在資料換值後半個像素才上升
    --
    --   PIX_DIV = 4 時逐個 clk 看：
    --     div_cnt     0    1    2    3    0    1    2    3
    --     pix_ce      1    0    0    0    1    0    0    0
    --     hdmi_d      N-1  N    N    N    N    N+1  N+1  N+1   pix_ce 那拍結束時換值
    --     hdmi_clk    1    0    0    1    1    0    0    1     前一拍 div_cnt >= 2 時為 1
    ----------------------------------------------------------------------------
    s_r <= to_integer(unsigned(stream_rgb(23 downto 16)));
    s_g <= to_integer(unsigned(stream_rgb(15 downto 8)));
    s_b <= to_integer(unsigned(stream_rgb(7 downto 0)));

    process(clk)
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                -- 第一拍：RGB -> YCbCr
                ycc_y  <= to_unsigned((Y_OFS_X256 + 47 * s_r + 157 * s_g + 16 * s_b) / 256, 8);
                ycc_cb <= to_unsigned((C_OFS_X256 - 26 * s_r - 87 * s_g + 112 * s_b) / 256, 8);
                ycc_cr <= to_unsigned((C_OFS_X256 + 112 * s_r - 102 * s_g - 10 * s_b) / 256, 8);
                ycc_de <= stream_de;
                ycc_hs <= stream_hs;
                ycc_vs <= stream_vs;

                -- 第二拍：排成 4:2:2；遮沒期間資料為 0，Cb / Cr 順序歸零
                if ycc_de = '1' and cr_sel = '0' then
                    hd_reg(23 downto 16) <= std_logic_vector(ycc_cb);
                    hd_reg(15 downto 8)  <= std_logic_vector(ycc_y);
                    cr_sel <= '1';
                elsif ycc_de = '1' then
                    hd_reg(23 downto 16) <= std_logic_vector(ycc_cr);
                    hd_reg(15 downto 8)  <= std_logic_vector(ycc_y);
                    cr_sel <= '0';
                else
                    hd_reg <= (others => '0');
                    cr_sel <= '0';
                end if;

                -- 同步訊號：內部高電位有效，輸出時依 SYNC_ACTIVE_LOW 調整極性
                if SYNC_ACTIVE_LOW then
                    hhs_reg <= not ycc_hs;
                    hvs_reg <= not ycc_vs;
                else
                    hhs_reg <= ycc_hs;
                    hvs_reg <= ycc_vs;
                end if;
            end if;

            -- 像素時脈：每個像素的後半段為高電位
            if div_cnt >= PIX_DIV / 2 then
                hclk_reg <= '1';
            else
                hclk_reg <= '0';
            end if;
        end if;
    end process;

    hdmi_d   <= hd_reg & x"00";
    hdmi_hs  <= hhs_reg;
    hdmi_vs  <= hvs_reg;
    hdmi_clk <= hclk_reg;

    -- ADV7511 暫存器設定（I2C），DE 產生器的參數由這裡的視訊時序換算
    u_hdmi_cfg : entity work.HW_5_hdmi_cfg
        generic map (
            I2C_DIV => I2C_DIV, START_DELAY => HDMI_CFG_DELAY,
            H_ACTIVE => H_ACTIVE, V_ACTIVE => V_ACTIVE,
            H_DE_DELAY => H_SYNC + H_BP, V_DE_DELAY => V_SYNC + V_BP,
            SYNC_ACTIVE_LOW => SYNC_ACTIVE_LOW
        )
        port map (clk => clk, reset => reset, scl => hdmi_scl, sda => hdmi_sda, ok => hdmi_ok);

    ----------------------------------------------------------------------------
    -- ⑨ LED（SPEC §10）
    --   SERVE / PLAY：LD0 = SW0、LD1 = 鍵盤已連線、LD2 = PS 心跳、LD6 = ADV7511 設定成功、LD7 = 心跳
    --   POINT / OVER：得分方（勝方）的分數長條，跟著 blink_on 閃
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if phase <= 1 then
                led_reg    <= (others => '0');
                led_reg(0) <= sw_speed_s;
                led_reg(1) <= kbd_s(6);
                led_reg(2) <= kbd_s(7);
                led_reg(6) <= hdmi_ok;
                led_reg(7) <= heartbeat;
            elsif blink_on = '0' then
                led_reg <= (others => '0');
            elsif server = '1' then
                led_reg <= BAR_L(to_integer(score_l));
            else
                led_reg <= BAR_R(to_integer(score_r));
            end if;
        end if;
    end process;

    led <= not led_reg when LED_ACTIVE_LOW else led_reg;

end Behavioral;
