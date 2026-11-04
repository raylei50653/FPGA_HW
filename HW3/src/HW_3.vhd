library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
-- HW3 VGA 掃描：RGB 色塊 + 旋轉 3D 多面體（規格見 HW3/SPEC.md）
-- ============================================================================
--
-- 功能
--   基本模式（reset 後）：R、G、B 三個矩形色塊，位置與大小由 generic 設定，重疊處加色混合
--   進階模式（按 BTNU 切換）：立方體、八面體、十二面體各自翻滾，由 HW_3_solid 逐像素算出看到的面
--     BTND 切換兩種樣式：
--       實心：打光的面 + 白色稜線
--       全息：正面與背面的稀疏點、背面稜線畫虛線，形體可透視
--
-- 資料流（全部在 clk 時脈域，像素管線只在 pix_ce = '1' 的那一拍前進）
--
--   ① pix_ce ─► ② 時序產生器 ──(x, y, de, hs, vs)──┬─► ⑤ 多面體管線 ×3 ──(inside, face, 顏色, 點)─┐
--                                                  └─► ⑥ 延遲線（對齊 ⑤）──(x, y, de, hs, vs)──────┤
--                                                                                                 ▼
--   ③ 按鈕 / 開關 ─► 模式、樣式、轉速、方向                                    ⑦ 合成（C1 → C2 → C3）
--   ④ 每幀累加角度 ─► ⑤                                                               │ RGB888 串流
--                                                                    ┌────────────────┴────────────┐
--                                                                    ▼                             ▼
--                                                          ⑧ VGA 輸出級（[VGA]）      ⑨ HDMI 輸出級（YCbCr 4:2:2）
--                                                                                                  │ ADV7511（I2C 設定）
--
-- 管線延遲（以像素 = pix_ce 計，相對時序產生器的輸出）
--   多面體管線 / 延遲線輸出  SOLID_LAT（= 14）
--   合成 C1 / C2 / C3        +1 / +2 / +3   （C3 的輸出就是 stream_*）
--   HDMI：YCbCr / 腳位       +4 / +5
--   同步訊號跟著資料走同一條管線，所以畫面與 hs / vs 永遠對齊，不用另外補償
--
-- EGO-XZ7 沒有 VGA 接頭：VGA 的 generic、埠、暫存器與輸出級先註解掉（標 [VGA]），
--   外接 VGA 時把標 [VGA] 的行取消註解，並在 HW_3.xdc 填 VGA 腳位
-- ============================================================================
entity HW_3 is
    Generic (
        PIX_DIV         : positive := 4;          -- 100 MHz / 4 = 25 MHz 像素率；HDMI 需要 >= 2（像素時脈由 clk 分頻）
        H_ACTIVE        : positive := 640;        -- 640×480@60（像素時脈 25.175 MHz，用 25 MHz 近似）
        H_FP            : positive := 16;
        H_SYNC          : positive := 96;
        H_BP            : positive := 48;
        V_ACTIVE        : positive := 480;
        V_FP            : positive := 10;
        V_SYNC          : positive := 2;
        V_BP            : positive := 33;
        SYNC_ACTIVE_LOW : boolean  := true;       -- 640×480@60 的 hs / vs 為負極性
        -- [VGA] RED_BITS        : positive := 1;          -- 每色位元數（1 ~ 8）：基本模式要求 1 bit；多面體不限，
        -- [VGA] GREEN_BITS      : positive := 1;          --   接多位元電阻 DAC 時加大（內部全程 RGB888）
        -- [VGA] BLUE_BITS       : positive := 1;
        -- 基本模式的色塊：左上角 (X, Y)、寬 W、高 H（像素）
        --   預設把畫面直切三等分、不留黑：640 / 3 不整除，寬取 214、212、214，讓交界落在偶數 x，
        --   HDMI 的 4:2:2 一對像素（偶、奇）共用色度，交界不會跨在一對中間而出現色邊
        R_X : natural := 0;    R_Y : natural := 0;    R_W : natural := 214;  R_H : natural := 480;
        G_X : natural := 214;  G_Y : natural := 0;    G_W : natural := 212;  G_H : natural := 480;
        B_X : natural := 426;  B_Y : natural := 0;    B_W : natural := 214;  B_H : natural := 480;
        ANGLE_BITS      : positive := 10;         -- 一圈 1024 步
        DEBOUNCE_CYCLES : positive := 2_000_000;  -- 20 ms
        HDMI_CFG_DELAY  : positive := 2**24;      -- ADV7511 每輪設定之前等待的 clk 數（約 168 ms）
        I2C_DIV         : positive := 250;        -- SCL = 100 MHz / (4 × 250) = 100 kHz
        BTN_ACTIVE_LOW  : boolean  := false;
        LED_ACTIVE_LOW  : boolean  := false
    );
    Port (
        clk       : in  STD_LOGIC;
        reset     : in  STD_LOGIC;
        btn_mode  : in  STD_LOGIC;                -- 基本色塊 <-> 旋轉多面體
        sw_pause  : in  STD_LOGIC;                -- 撥上暫停旋轉
        btn_speed : in  STD_LOGIC;                -- 轉速 ×1 -> ×2 -> ×4 -> ×8
        btn_dir   : in  STD_LOGIC;                -- 反轉
        btn_style : in  STD_LOGIC;                -- 實心打光 + 稜線 <-> 全息點雲
        -- [VGA] vga_r     : out STD_LOGIC_VECTOR(RED_BITS - 1 downto 0);
        -- [VGA] vga_g     : out STD_LOGIC_VECTOR(GREEN_BITS - 1 downto 0);
        -- [VGA] vga_b     : out STD_LOGIC_VECTOR(BLUE_BITS - 1 downto 0);
        -- [VGA] vga_hs    : out STD_LOGIC;
        -- [VGA] vga_vs    : out STD_LOGIC;
        hdmi_clk  : out   STD_LOGIC;              -- ADV7511 像素時脈（上升緣取樣）
        hdmi_d    : out   STD_LOGIC_VECTOR(23 downto 0);   -- ADV7511 D23..D0：D23..16 Cb / Cr、D15..8 Y、D7..0 = 0
        hdmi_hs   : out   STD_LOGIC;
        hdmi_vs   : out   STD_LOGIC;
        hdmi_scl  : out   STD_LOGIC;              -- ADV7511 設定用 I2C（開汲極：只拉低或放開）
        hdmi_sda  : inout STD_LOGIC;
        led       : out STD_LOGIC_VECTOR(7 downto 0)
    );
end HW_3;

architecture Behavioral of HW_3 is

    subtype rgb_t is std_logic_vector(23 downto 0);    -- R(23..16) G(15..8) B(7..0)

    ----------------------------------------------------------------------------
    -- 形狀設定：0 = 立方體、1 = 八面體、2 = 十二面體，編號小的在上層
    --   位置與大小跟著解析度縮放，換成 HDMI 的 1280×720 也排得下
    ----------------------------------------------------------------------------
    constant SHAPES    : positive := 3;
    constant TREE_LV   : positive := 5;           -- 比較樹層數，最多 32 個面（二十面體也放得下）
    constant SOLID_LAT : positive := 9 + TREE_LV; -- HW_3_solid 的管線深度（ce 數）

    type int_arr_t is array (0 to SHAPES - 1) of integer;
    type rgb_arr_t is array (0 to SHAPES - 1) of rgb_t;

    constant SOLID_A  : int_arr_t := (0, 1, 2);
    constant SPIN_X_A : int_arr_t := (2, 3, -1);  -- 每幀繞 x 軸轉 SPIN × 2^speed 步
    constant SPIN_Y_A : int_arr_t := (3, -2, 2);  -- 每幀繞 y 軸轉 SPIN × 2^speed 步
    constant CX_A     : int_arr_t := (H_ACTIVE / 6, H_ACTIVE / 2, 5 * H_ACTIVE / 6);
    constant CY       : natural   := V_ACTIVE / 2;
    constant RADIUS   : positive  := H_ACTIVE * 5 / 32;   -- 640 寬時外接球半徑 100 像素

    -- 正對光源時的顏色；純紅、純綠、純藍，取高位元時不會混出雜色
    constant BASE_C : rgb_arr_t := (x"FF0000", x"00FF00", x"0000FF");
    constant EDGE_C : rgb_t     := x"FFFFFF";
    constant BG_C   : rgb_t     := x"000000";

    ----------------------------------------------------------------------------
    -- 標籤：每個像素「看到哪個形狀的哪個面」，用來找稜線
    --   bit 7     = 1：在某個形狀內（背景整個標籤為 0）
    --   bit 6..5  = 形狀編號
    --   bit 4..0  = 面編號
    -- 每個像素有兩個標籤：正面標籤（光線進入的面，也就是看到的面）與背面標籤（光線離開的面）
    -- 兩個標籤打包成 16 bit 的 pair_t 存進行緩衝：背面標籤在高 8 bit、正面標籤在低 8 bit
    ----------------------------------------------------------------------------
    subtype label_t is std_logic_vector(7 downto 0);
    subtype pair_t  is std_logic_vector(15 downto 0);
    constant NO_LABEL : label_t := (others => '0');

    function make_label(shape : natural; face : unsigned(4 downto 0)) return label_t is
    begin
        return '1' & std_logic_vector(to_unsigned(shape, 2)) & std_logic_vector(face);
    end function;

    function label_inside(lab : label_t) return boolean is
    begin
        return lab(7) = '1';
    end function;

    function label_shape(lab : label_t) return natural is
    begin
        return to_integer(unsigned(lab(6 downto 5)));
    end function;

    function front_of(p : pair_t) return label_t is
    begin
        return p(7 downto 0);
    end function;

    function back_of(p : pair_t) return label_t is
    begin
        return p(15 downto 8);
    end function;

    -- 稜線：這個像素的標籤和左邊兩個或上面兩個像素任一個不同（看兩個鄰居，線寬 2 像素）
    function on_ridge(here, left1, left2, up1, up2 : label_t) return boolean is
    begin
        return here /= left1 or here /= left2 or here /= up1 or here /= up2;
    end function;

    -- 像素 (x, y) 在左上角 (rx, ry)、寬 rw、高 rh 的矩形內
    function in_rect(x, y, rx, ry, rw, rh : integer) return boolean is
    begin
        return x >= rx and x < rx + rw and y >= ry and y < ry + rh;
    end function;

    -- 依極性輸出：active_low 時反相
    function pol(v : std_logic; active_low : boolean) return std_logic is
    begin
        if active_low then
            return not v;
        else
            return v;
        end if;
    end function;

    ----------------------------------------------------------------------------
    -- ① 像素致能
    ----------------------------------------------------------------------------
    signal div_cnt : integer range 0 to PIX_DIV - 1 := 0;
    signal pix_ce  : std_logic := '0';

    ----------------------------------------------------------------------------
    -- ② 時序產生器輸出
    ----------------------------------------------------------------------------
    signal t_x, t_y   : unsigned(11 downto 0);
    signal t_de       : std_logic;
    signal t_hs, t_vs : std_logic;
    signal t_frame    : std_logic;
    signal frame_tick : std_logic;                -- 每幀一拍（clk）

    ----------------------------------------------------------------------------
    -- ③ 按鈕與設定
    ----------------------------------------------------------------------------
    signal press_mode, press_speed, press_dir, press_style : std_logic;   -- 按下瞬間的單拍脈衝
    signal pause_s1  : std_logic := '0';          -- SW0 兩級同步
    signal pause_s2  : std_logic := '0';
    signal mode      : std_logic := '0';          -- 0 基本色塊、1 旋轉多面體
    signal running   : std_logic;                 -- 1 = 轉動中（SW0 沒撥上）
    signal dir       : std_logic := '0';          -- 1 = 反轉
    signal speed_sel : unsigned(1 downto 0) := "01";   -- 轉速 ×2^speed_sel
    signal holo      : std_logic := '0';          -- 0 實心打光 + 稜線、1 全息點雲
    signal frame_cnt : unsigned(5 downto 0) := (others => '0');   -- 心跳 LED 用

    ----------------------------------------------------------------------------
    -- ④ 角度：每個形狀繞 x、y 軸各一個
    ----------------------------------------------------------------------------
    type ang_arr_t is array (0 to SHAPES - 1) of unsigned(ANGLE_BITS - 1 downto 0);
    signal ang_x : ang_arr_t := (others => (others => '0'));
    signal ang_y : ang_arr_t := (others => (others => '0'));
    signal load  : std_logic := '0';             -- 角度更新後一拍：通知多面體單元重算 W

    ----------------------------------------------------------------------------
    -- ⑤ 多面體管線輸出（比時序產生器晚 SOLID_LAT 個像素）
    ----------------------------------------------------------------------------
    type face_arr_t is array (0 to SHAPES - 1) of unsigned(4 downto 0);
    signal inside : std_logic_vector(SHAPES - 1 downto 0);
    signal face   : face_arr_t;                   -- 看到的面（進入點）
    signal bface  : face_arr_t;                   -- 光線離開的背面
    signal shade  : rgb_arr_t;                    -- 看到的面打光後的顏色
    signal dot_f  : std_logic_vector(SHAPES - 1 downto 0);   -- 進入點 / 離開點落在點雲的點上
    signal dot_b  : std_logic_vector(SHAPES - 1 downto 0);

    ----------------------------------------------------------------------------
    -- ⑥ 延遲線：時序訊號延遲 SOLID_LAT 個像素，與 ⑤ 的輸出對齊
    ----------------------------------------------------------------------------
    type u12_pipe_t is array (1 to SOLID_LAT) of unsigned(11 downto 0);
    signal x_d, y_d : u12_pipe_t := (others => (others => '0'));
    signal de_d     : std_logic_vector(1 to SOLID_LAT) := (others => '0');
    signal hs_d     : std_logic_vector(1 to SOLID_LAT) := (others => '0');
    signal vs_d     : std_logic_vector(1 to SOLID_LAT) := (others => '0');

    -- 延遲線的最後一級：和 inside / face / shade 同一個像素
    alias aligned_x  : unsigned(11 downto 0) is x_d(SOLID_LAT);
    alias aligned_y  : unsigned(11 downto 0) is y_d(SOLID_LAT);
    alias aligned_de : std_logic is de_d(SOLID_LAT);
    alias aligned_hs : std_logic is hs_d(SOLID_LAT);
    alias aligned_vs : std_logic is vs_d(SOLID_LAT);

    ----------------------------------------------------------------------------
    -- ⑦ 合成（3 級）
    --   兩個行緩衝串接：lb1 存上一行的標籤，lb1 讀出的值再寫進 lb2，所以 lb2 讀出的是上兩行
    ----------------------------------------------------------------------------
    type line_buf_t is array (0 to H_ACTIVE - 1) of pair_t;
    signal lb1, lb2 : line_buf_t := (others => (others => '0'));

    -- C1：這個像素的顏色與標籤
    signal c1_rgb       : rgb_t   := (others => '0');   -- 基本模式的色塊顏色 / 實心樣式的打光顏色
    signal c1_holo      : rgb_t   := (others => '0');   -- 全息樣式：落在點上時為形狀顏色，否則黑色
    signal c1_front_lab : label_t := (others => '0');
    signal c1_back_lab  : label_t := (others => '0');
    signal c1_x         : unsigned(11 downto 0) := (others => '0');
    signal c1_y_lsb     : unsigned(1 downto 0)  := (others => '0');   -- 背面虛線只用到座標低 2 位
    signal c1_de        : std_logic := '0';
    signal c1_hs        : std_logic := '0';
    signal c1_vs        : std_logic := '0';
    signal c1_up1       : pair_t := (others => '0');    -- lb1 讀出：(x, y-1) 的標籤，與 C1 對齊

    -- C2：再晚一拍，湊齊四個鄰居的標籤
    signal c2_rgb        : rgb_t   := (others => '0');
    signal c2_holo       : rgb_t   := (others => '0');
    signal c2_front_lab  : label_t := (others => '0');
    signal c2_back_lab   : label_t := (others => '0');
    signal c2_x_lsb      : unsigned(1 downto 0) := (others => '0');
    signal c2_y_lsb      : unsigned(1 downto 0) := (others => '0');
    signal c2_de         : std_logic := '0';
    signal c2_hs         : std_logic := '0';
    signal c2_vs         : std_logic := '0';
    signal c2_up1        : pair_t  := (others => '0');   -- 以下與 C2 對齊：(x, y-1)
    signal c2_up2        : pair_t  := (others => '0');   -- (x, y-2)，lb2 讀出
    signal c2_front_left1 : label_t := (others => '0');  -- 正面標籤的 (x-1, y)
    signal c2_front_left2 : label_t := (others => '0');  -- 正面標籤的 (x-2, y)
    signal c2_back_left1  : label_t := (others => '0');  -- 背面標籤的 (x-1, y)
    signal c2_back_left2  : label_t := (others => '0');  -- 背面標籤的 (x-2, y)

    -- C3 輸出：RGB888 視訊串流（送給 HDMI 輸出級；接回 VGA 時兩個輸出級共用）
    signal stream_rgb   : rgb_t   := (others => '0');
    signal stream_label : label_t := (others => '0');   -- 正面標籤，給測試檔核對
    signal stream_de    : std_logic := '0';
    signal stream_hs    : std_logic := '0';
    signal stream_vs    : std_logic := '0';

    ----------------------------------------------------------------------------
    -- ⑧ VGA 輸出暫存器
    ----------------------------------------------------------------------------
    -- [VGA] signal r_reg  : std_logic_vector(RED_BITS - 1 downto 0)   := (others => '0');
    -- [VGA] signal g_reg  : std_logic_vector(GREEN_BITS - 1 downto 0) := (others => '0');
    -- [VGA] signal b_reg  : std_logic_vector(BLUE_BITS - 1 downto 0)  := (others => '0');
    -- [VGA] signal hs_reg : std_logic := '0';
    -- [VGA] signal vs_reg : std_logic := '0';

    ----------------------------------------------------------------------------
    -- ⑨ HDMI：RGB -> YCbCr（第一拍），再排成 4:2:2（第二拍）
    ----------------------------------------------------------------------------
    signal ycc_y    : unsigned(7 downto 0) := (others => '0');
    signal ycc_cb   : unsigned(7 downto 0) := (others => '0');
    signal ycc_cr   : unsigned(7 downto 0) := (others => '0');
    signal ycc_de   : std_logic := '0';
    signal ycc_hs   : std_logic := '0';
    signal ycc_vs   : std_logic := '0';
    signal cr_sel   : std_logic := '0';           -- 0 = 這個像素送 Cb、1 = 送 Cr；每行第一個像素送 Cb

    -- HDMI 輸出暫存器（放進 IOB，見 HW_3.xdc）：hd_reg(23..16) 色度 Cb / Cr、hd_reg(15..8) 亮度 Y
    signal hd_reg   : std_logic_vector(23 downto 8) := (others => '0');
    signal hhs_reg  : std_logic := '0';
    signal hvs_reg  : std_logic := '0';
    signal hclk_reg : std_logic := '0';
    signal hdmi_ok  : std_logic;                  -- ADV7511 最近一輪設定全部收到 ACK

    -- BT.709 有限範圍（Y 16 ~ 235、Cb / Cr 16 ~ 240）RGB -> YCbCr，係數 × 256 取整數：
    --        R        G        B         偏移
    --   Y    0.183    0.614    0.062     16
    --   Cb  -0.101   -0.339    0.439    128
    --   Cr   0.439   -0.399   -0.040    128
    -- 偏移量多加 0.5，讓除以 256（右移）變成四捨五入；加上偏移後被除數也不會是負數
    constant Y_OFS_X256 : natural := 4224;        -- (16  + 0.5) × 256
    constant C_OFS_X256 : natural := 32896;       -- (128 + 0.5) × 256

begin

    -- [VGA] assert RED_BITS <= 8 and GREEN_BITS <= 8 and BLUE_BITS <= 8
    -- [VGA]     report "VGA color depth must be at most 8 bits per channel"
    -- [VGA]     severity failure;

    assert R_X + R_W <= H_ACTIVE and G_X + G_W <= H_ACTIVE and B_X + B_W <= H_ACTIVE and
           R_Y + R_H <= V_ACTIVE and G_Y + G_H <= V_ACTIVE and B_Y + B_H <= V_ACTIVE
        report "RGB blocks must fit inside the visible area"
        severity failure;

    assert ANGLE_BITS >= 6
        report "ANGLE_BITS must be at least 6 to hold SPIN x 8 steps per frame"
        severity failure;

    assert PIX_DIV >= 2
        report "HDMI pixel clock is divided from clk, PIX_DIV must be at least 2"
        severity failure;

    ----------------------------------------------------------------------------
    -- ① 像素致能：每 PIX_DIV 個 clk 一拍
    --   整個設計只有一個時脈 clk；像素管線用 pix_ce 當致能，不另外產生 25 MHz 時脈
    ----------------------------------------------------------------------------
    pixel_enable : process(clk)
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
    -- ② 視訊時序：產生 x、y、de、hs、vs（高電位有效）與每幀開頭的 frame_start
    ----------------------------------------------------------------------------
    u_timing : entity work.HW_3_timing
        generic map (
            H_ACTIVE => H_ACTIVE, H_FP => H_FP, H_SYNC => H_SYNC, H_BP => H_BP,
            V_ACTIVE => V_ACTIVE, V_FP => V_FP, V_SYNC => V_SYNC, V_BP => V_BP
        )
        port map (
            clk => clk, reset => reset, ce => pix_ce,
            x => t_x, y => t_y, de => t_de, hs => t_hs, vs => t_vs,
            frame_start => t_frame
        );

    -- frame_start 維持一個像素（PIX_DIV 個 clk），與 ce 相交剛好一拍
    frame_tick <= t_frame and pix_ce;


    ----------------------------------------------------------------------------
    -- ③ 按鈕 ×4、暫停開關與設定暫存器
    ----------------------------------------------------------------------------
    u_btn_mode : entity work.HW_3_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_mode, press => press_mode);

    u_btn_speed : entity work.HW_3_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_speed, press => press_speed);

    u_btn_dir : entity work.HW_3_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_dir, press => press_dir);

    u_btn_style : entity work.HW_3_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_style, press => press_style);

    -- 開關是電位，不會彈跳出多次觸發，只需同步
    pause_sync : process(clk)
    begin
        if rising_edge(clk) then
            pause_s1 <= sw_pause;
            pause_s2 <= pause_s1;
        end if;
    end process;

    running <= not pause_s2;

    -- 每按一下：模式、方向、樣式切換；轉速 ×1 -> ×2 -> ×4 -> ×8 -> ×1（2 bit 自然溢位）
    settings : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                mode      <= '0';
                dir       <= '0';
                speed_sel <= "01";
                holo      <= '0';
            else
                if press_mode = '1' then
                    mode <= not mode;
                end if;
                if press_dir = '1' then
                    dir <= not dir;
                end if;
                if press_speed = '1' then
                    speed_sel <= speed_sel + 1;
                end if;
                if press_style = '1' then
                    holo <= not holo;
                end if;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- ④ 角度：每幀在垂直遮沒開頭更新，下一拍以 load 通知多面體單元重算 W
    --   每幀的步數 = SPIN × 2^speed_sel，反轉時取負號；角度是 ANGLE_BITS 位元，溢位就是繞一圈
    ----------------------------------------------------------------------------
    angles : process(clk)
        variable step_x : signed(ANGLE_BITS - 1 downto 0);
        variable step_y : signed(ANGLE_BITS - 1 downto 0);
    begin
        if rising_edge(clk) then
            load <= '0';
            if reset = '1' then
                ang_x     <= (others => (others => '0'));
                ang_y     <= (others => (others => '0'));
                frame_cnt <= (others => '0');
            elsif frame_tick = '1' then
                load      <= '1';
                frame_cnt <= frame_cnt + 1;
                if running = '1' then
                    for k in 0 to SHAPES - 1 loop
                        step_x := shift_left(to_signed(SPIN_X_A(k), ANGLE_BITS), to_integer(speed_sel));
                        step_y := shift_left(to_signed(SPIN_Y_A(k), ANGLE_BITS), to_integer(speed_sel));
                        if dir = '1' then
                            step_x := -step_x;
                            step_y := -step_y;
                        end if;
                        ang_x(k) <= ang_x(k) + unsigned(step_x);
                        ang_y(k) <= ang_y(k) + unsigned(step_y);
                    end loop;
                end if;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- ⑤ 多面體管線 ×3：每個像素回答「在不在形狀內、看到哪個面、面的顏色、是不是點雲上的點」
    ----------------------------------------------------------------------------
    gen_solid : for k in 0 to SHAPES - 1 generate
        u_solid : entity work.HW_3_solid
            generic map (
                SOLID => SOLID_A(k), SEED => k, CX => CX_A(k), CY => CY, RADIUS => RADIUS,
                BASE_RGB => BASE_C(k), ANGLE_BITS => ANGLE_BITS, TREE_LV => TREE_LV
            )
            port map (
                clk => clk, reset => reset, ce => pix_ce, load => load,
                ang_x => ang_x(k), ang_y => ang_y(k), x => t_x, y => t_y,
                inside => inside(k), face => face(k), bface => bface(k), rgb => shade(k),
                dot_f => dot_f(k), dot_b => dot_b(k)
            );
    end generate;


    ----------------------------------------------------------------------------
    -- ⑥ 延遲線：座標與同步訊號延遲 SOLID_LAT 個像素，與 ⑤ 的輸出對齊（aligned_*）
    ----------------------------------------------------------------------------
    delay_line : process(clk)
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                x_d(1)  <= t_x;
                y_d(1)  <= t_y;
                de_d(1) <= t_de;
                hs_d(1) <= t_hs;
                vs_d(1) <= t_vs;
                for i in 2 to SOLID_LAT loop
                    x_d(i)  <= x_d(i - 1);
                    y_d(i)  <= y_d(i - 1);
                    de_d(i) <= de_d(i - 1);
                    hs_d(i) <= hs_d(i - 1);
                    vs_d(i) <= vs_d(i - 1);
                end loop;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- ⑦ 合成：三級管線，每級一個像素
    --   C1  決定這個像素的顏色與標籤，並讀寫第一個行緩衝（拿到上一行的標籤）
    --   C2  讀寫第二個行緩衝（拿到上兩行的標籤），並記下左邊兩個像素的標籤
    --   C3  比較四個鄰居找出稜線，依樣式決定最後的顏色；遮沒期間輸出黑色
    ----------------------------------------------------------------------------

    -- C1 ----------------------------------------------------------------------
    --   基本模式：三個色塊各自點亮一個顏色通道，重疊處自然變成加色混合
    --   進階模式：由下層（編號大）往上層蓋，最後留下的是最上層的形狀
    --   遮沒期間標籤清成 0，所以每行開頭的左鄰居一定是背景
    compose_c1 : process(clk)
        variable xi        : integer range 0 to 4095;
        variable yi        : integer range 0 to 4095;
        variable rgb       : rgb_t;
        variable holo_rgb  : rgb_t;
        variable front_lab : label_t;
        variable back_lab  : label_t;
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                xi        := to_integer(aligned_x);
                yi        := to_integer(aligned_y);
                front_lab := NO_LABEL;
                back_lab  := NO_LABEL;
                holo_rgb  := BG_C;

                if mode = '0' then
                    rgb := (others => '0');
                    if in_rect(xi, yi, R_X, R_Y, R_W, R_H) then
                        rgb(23 downto 16) := x"FF";
                    end if;
                    if in_rect(xi, yi, G_X, G_Y, G_W, G_H) then
                        rgb(15 downto 8) := x"FF";
                    end if;
                    if in_rect(xi, yi, B_X, B_Y, B_W, B_H) then
                        rgb(7 downto 0) := x"FF";
                    end if;

                else
                    rgb := BG_C;
                    for k in SHAPES - 1 downto 0 loop
                        if inside(k) = '1' then
                            rgb       := shade(k);
                            front_lab := make_label(k, face(k));
                            back_lab  := make_label(k, bface(k));
                            if dot_f(k) = '1' or dot_b(k) = '1' then
                                holo_rgb := BASE_C(k);
                            else
                                holo_rgb := BG_C;
                            end if;
                        end if;
                    end loop;
                end if;

                if aligned_de = '0' then
                    front_lab := NO_LABEL;
                    back_lab  := NO_LABEL;
                end if;

                c1_rgb       <= rgb;
                c1_holo      <= holo_rgb;
                c1_front_lab <= front_lab;
                c1_back_lab  <= back_lab;
                c1_x         <= aligned_x;
                c1_y_lsb     <= aligned_y(1 downto 0);
                c1_de        <= aligned_de;
                c1_hs        <= aligned_hs;
                c1_vs        <= aligned_vs;

                -- 行緩衝 1：先讀出同一欄上一行的值，再寫入這一行的（read-first，綜合成 BRAM）
                if aligned_de = '1' then
                    c1_up1  <= lb1(xi);
                    lb1(xi) <= back_lab & front_lab;
                end if;
            end if;
        end if;
    end process;

    -- C2 ----------------------------------------------------------------------
    --   lb2 存的是上一行從 lb1 讀出的值（= 上兩行），讀出來就是 (x, y-2)
    --   left1 / left2 是 C2 自己前一、前兩拍的標籤，也就是左邊一、兩個像素
    compose_c2 : process(clk)
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                c2_rgb         <= c1_rgb;
                c2_holo        <= c1_holo;
                c2_front_lab   <= c1_front_lab;
                c2_back_lab    <= c1_back_lab;
                c2_front_left1 <= c2_front_lab;
                c2_front_left2 <= c2_front_left1;
                c2_back_left1  <= c2_back_lab;
                c2_back_left2  <= c2_back_left1;
                c2_x_lsb       <= c1_x(1 downto 0);
                c2_y_lsb       <= c1_y_lsb;
                c2_de          <= c1_de;
                c2_hs          <= c1_hs;
                c2_vs          <= c1_vs;
                c2_up1         <= c1_up1;
                if c1_de = '1' then
                    c2_up2                <= lb2(to_integer(c1_x));
                    lb2(to_integer(c1_x)) <= c1_up1;
                end if;
            end if;
        end if;
    end process;

    -- C3 ----------------------------------------------------------------------
    --   front_ridge：正面標籤的稜線（看得到的稜線）
    --   back_ridge ：背面標籤的稜線（被擋住的稜線，全息樣式才畫）
    --   顏色優先順序（進階模式）：
    --     實心：正面稜線 -> 白色；其餘 -> 打光顏色（背景就是黑色）
    --     全息：正面稜線 -> 白色；落在點上 -> 形狀顏色；背面稜線 -> 形狀顏色的虛線；其餘 -> 黑色
    --   虛線：(x + y) mod 4 < 2 才畫，沿任何方向都是畫 2 像素、空 2 像素
    compose_c3 : process(clk)
        variable front_ridge : boolean;
        variable back_ridge  : boolean;
        variable diag        : unsigned(1 downto 0);
        variable dash_on     : boolean;
        variable outp        : rgb_t;
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                front_ridge := on_ridge(c2_front_lab, c2_front_left1, c2_front_left2,
                                        front_of(c2_up1), front_of(c2_up2));
                back_ridge  := on_ridge(c2_back_lab, c2_back_left1, c2_back_left2,
                                        back_of(c2_up1), back_of(c2_up2));
                diag        := c2_x_lsb + c2_y_lsb;          -- (x + y) mod 4
                dash_on     := diag(1) = '0';

                outp := c2_rgb;
                if mode = '1' then
                    if front_ridge then
                        outp := EDGE_C;
                    elsif holo = '1' then
                        if c2_holo /= BG_C then
                            outp := c2_holo;
                        elsif back_ridge and label_inside(c2_back_lab) and dash_on then
                            outp := BASE_C(label_shape(c2_back_lab) mod SHAPES);
                        else
                            outp := BG_C;
                        end if;
                    end if;
                end if;
                if c2_de = '0' then
                    outp := (others => '0');
                end if;

                stream_rgb   <= outp;
                stream_label <= c2_front_lab;
                stream_de    <= c2_de;
                stream_hs    <= c2_hs;
                stream_vs    <= c2_vs;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- ⑧ VGA 輸出級：取各色高位元、調整同步極性（EGO-XZ7 沒有 VGA 接頭，先註解掉）
    ----------------------------------------------------------------------------
    -- [VGA] process(clk)
    -- [VGA] begin
    -- [VGA]     if rising_edge(clk) then
    -- [VGA]         if pix_ce = '1' then
    -- [VGA]             r_reg  <= stream_rgb(23 downto 24 - RED_BITS);
    -- [VGA]             g_reg  <= stream_rgb(15 downto 16 - GREEN_BITS);
    -- [VGA]             b_reg  <= stream_rgb(7 downto 8 - BLUE_BITS);
    -- [VGA]             hs_reg <= pol(stream_hs, SYNC_ACTIVE_LOW);
    -- [VGA]             vs_reg <= pol(stream_vs, SYNC_ACTIVE_LOW);
    -- [VGA]         end if;
    -- [VGA]     end if;
    -- [VGA] end process;
    -- [VGA]
    -- [VGA] vga_r  <= r_reg;
    -- [VGA] vga_g  <= g_reg;
    -- [VGA] vga_b  <= b_reg;
    -- [VGA] vga_hs <= hs_reg;
    -- [VGA] vga_vs <= vs_reg;


    ----------------------------------------------------------------------------
    -- ⑨ HDMI 輸出級
    --   板子上的 ADV7511 負責 TMDS 編碼，FPGA 只送影像資料、hs、vs 與像素時脈
    --   ADV7511 的輸入匯流排有 36 bit，24 bit RGB 時 R 在 D35..28，但板子只接了 D23..D0，
    --   所以照 ZedBoard 的接法送 16 bit YCbCr 4:2:2：D23..16 = Cb / Cr 輪流、D15..8 = Y，D7..0 不用；
    --   ADV7511 再用內建的 CSC 轉回 RGB（HW_3_hdmi_cfg 設定）
    --   板子沒有接 DE，由 ADV7511 的 DE 產生器依 hs、vs 自己算（HW_3_hdmi_cfg 設定）
    --
    --   第一拍：RGB -> YCbCr（係數見宣告區的表）
    --   第二拍：4:2:2 = 每個像素都送自己的 Y，色度只送一半：偶數像素送 Cb、奇數像素送 Cr
    --           （不濾波，直接取該像素的色度；每行從 Cb 開始）
    --   像素時脈：由 div_cnt 解出，在資料換值後半個像素才上升，
    --           ADV7511 在上升緣取樣，前後各有半個像素（20 ns）的餘裕
    --
    --   PIX_DIV = 4 時逐個 clk 看：
    --     div_cnt     0    1    2    3    0    1    2    3
    --     pix_ce      1    0    0    0    1    0    0    0
    --     hdmi_d      N-1  N    N    N    N    N+1  N+1  N+1   pix_ce 那拍結束時換值
    --     hdmi_clk    1    0    0    1    1    0    0    1     晚 div_cnt 一拍：前一拍 div_cnt >= 2 時為 1
    --                                ↑ 上升緣：資料已穩定 2 個 clk，之後還會保持 2 個 clk
    ----------------------------------------------------------------------------
    hdmi_out : process(clk)
        variable r, g, b : natural range 0 to 255;
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                -- 第一拍：RGB -> YCbCr
                r := to_integer(unsigned(stream_rgb(23 downto 16)));
                g := to_integer(unsigned(stream_rgb(15 downto 8)));
                b := to_integer(unsigned(stream_rgb(7 downto 0)));
                ycc_y  <= to_unsigned((Y_OFS_X256 + 47 * r + 157 * g + 16 * b) / 256, 8);
                ycc_cb <= to_unsigned((C_OFS_X256 - 26 * r - 87 * g + 112 * b) / 256, 8);
                ycc_cr <= to_unsigned((C_OFS_X256 + 112 * r - 102 * g - 10 * b) / 256, 8);
                ycc_de <= stream_de;
                ycc_hs <= stream_hs;
                ycc_vs <= stream_vs;

                -- 第二拍：排成 4:2:2，同步訊號調整極性；遮沒期間資料為 0，Cb / Cr 順序歸零
                if ycc_de = '1' then
                    if cr_sel = '0' then
                        hd_reg(23 downto 16) <= std_logic_vector(ycc_cb);
                    else
                        hd_reg(23 downto 16) <= std_logic_vector(ycc_cr);
                    end if;
                    hd_reg(15 downto 8) <= std_logic_vector(ycc_y);
                    cr_sel <= not cr_sel;
                else
                    hd_reg <= (others => '0');
                    cr_sel <= '0';
                end if;
                hhs_reg <= pol(ycc_hs, SYNC_ACTIVE_LOW);
                hvs_reg <= pol(ycc_vs, SYNC_ACTIVE_LOW);
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
    u_hdmi_cfg : entity work.HW_3_hdmi_cfg
        generic map (
            I2C_DIV => I2C_DIV, START_DELAY => HDMI_CFG_DELAY,
            H_ACTIVE => H_ACTIVE, V_ACTIVE => V_ACTIVE,
            H_DE_DELAY => H_SYNC + H_BP, V_DE_DELAY => V_SYNC + V_BP,
            SYNC_ACTIVE_LOW => SYNC_ACTIVE_LOW
        )
        port map (clk => clk, reset => reset, scl => hdmi_scl, sda => hdmi_sda, ok => hdmi_ok);


    ----------------------------------------------------------------------------
    -- LED
    --   LD0 旋轉多面體模式、LD1 轉動中、LD2 反轉、LD4..3 轉速、LD5 全息點雲、
    --   LD6 ADV7511 設定成功、LD7 心跳（frame_cnt 第 5 位，約每秒閃一次）
    ----------------------------------------------------------------------------
    led(0) <= pol(mode, LED_ACTIVE_LOW);
    led(1) <= pol(running, LED_ACTIVE_LOW);
    led(2) <= pol(dir, LED_ACTIVE_LOW);
    led(3) <= pol(speed_sel(0), LED_ACTIVE_LOW);
    led(4) <= pol(speed_sel(1), LED_ACTIVE_LOW);
    led(5) <= pol(holo, LED_ACTIVE_LOW);
    led(6) <= pol(hdmi_ok, LED_ACTIVE_LOW);
    led(7) <= pol(frame_cnt(5), LED_ACTIVE_LOW);

end Behavioral;
