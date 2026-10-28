library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW3 VGA 掃描：RGB 色塊 + 旋轉 3D 多面體（規格見 HW3/SPEC.md）
--   基本模式（reset 後）：R、G、B 三個矩形色塊，位置與大小由 generic 設定，重疊處加色混合
--   進階模式（按 BTNU 切換）：立方體、八面體、十二面體各自翻滾，由 HW_3_solid 逐像素算出看到的面
--     BTND 切換兩種樣式：實心打光 + 白色稜線，或全息點雲（正面與背面的稀疏點、背面稜線畫虛線，可透視）
--   內部資料流：時序 -> 多面體管線 -> 合成 RGB888 視訊串流 -+-> VGA 輸出級（取各色高位元）
--                                                            +-> HDMI 輸出級（YCbCr 4:2:2 + 同步 + 像素時脈 -> ADV7511）
--   ADV7511 由 HW_3_hdmi_cfg 經 I2C 設定
--   EGO-XZ7 沒有 VGA 接頭：VGA 的 generic、埠、暫存器與輸出級先註解掉（標 [VGA]），
--     外接 VGA 時把標 [VGA] 的行取消註解，並在 HW_3.xdc 填 VGA 腳位
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

    --------------------------------------------------
    -- 形狀設定：0 = 立方體、1 = 八面體、2 = 十二面體，編號小的在上層
    --   位置與大小跟著解析度縮放，換成 HDMI 的 1280×720 也排得下
    --------------------------------------------------
    constant SHAPES    : positive := 3;
    constant TREE_LV   : positive := 5;           -- 比較樹層數，最多 32 個面（二十面體也放得下）
    constant SOLID_LAT : positive := 9 + TREE_LV; -- HW_3_solid 的管線深度（ce 數）

    type int_arr_t is array (0 to SHAPES - 1) of integer;
    type rgb_arr_t is array (0 to SHAPES - 1) of std_logic_vector(23 downto 0);

    constant SOLID_A  : int_arr_t := (0, 1, 2);
    constant SPIN_X_A : int_arr_t := (2, 3, -1);  -- 每幀繞 x 軸轉 SPIN × 2^speed 步
    constant SPIN_Y_A : int_arr_t := (3, -2, 2);  -- 每幀繞 y 軸轉 SPIN × 2^speed 步
    constant CX_A     : int_arr_t := (H_ACTIVE / 6, H_ACTIVE / 2, 5 * H_ACTIVE / 6);
    constant CY       : natural   := V_ACTIVE / 2;
    constant RADIUS   : positive  := H_ACTIVE * 5 / 32;   -- 640 寬時外接球半徑 100 像素

    -- 正對光源時的顏色；純紅、純綠、純藍，取高位元時不會混出雜色
    constant BASE_C : rgb_arr_t := (x"FF0000", x"00FF00", x"0000FF");
    constant EDGE_C : std_logic_vector(23 downto 0) := x"FFFFFF";
    constant BG_C   : std_logic_vector(23 downto 0) := x"000000";

    -- 像素致能
    signal div_cnt : integer range 0 to PIX_DIV - 1 := 0;
    signal pix_ce  : std_logic := '0';

    -- 時序產生器輸出
    signal t_x, t_y   : unsigned(11 downto 0);
    signal t_de       : std_logic;
    signal t_hs, t_vs : std_logic;
    signal t_frame    : std_logic;
    signal frame_tick : std_logic;                -- 每幀一拍（clk）
    signal load       : std_logic := '0';

    -- 按鈕與設定
    signal p_mode, p_speed, p_dir, p_style : std_logic;
    signal pause_s1  : std_logic := '0';
    signal pause_s2  : std_logic := '0';
    signal mode      : std_logic := '0';          -- 0 基本色塊、1 旋轉多面體
    signal running   : std_logic;
    signal dir       : std_logic := '0';
    signal speed_sel : unsigned(1 downto 0) := "01";
    signal holo      : std_logic := '0';          -- 0 實心打光 + 稜線、1 全息點雲
    signal frame_cnt : unsigned(5 downto 0) := (others => '0');

    -- 角度：每個形狀繞 x、y 軸各一個
    type ang_arr_t is array (0 to SHAPES - 1) of unsigned(ANGLE_BITS - 1 downto 0);
    signal ang_x : ang_arr_t := (others => (others => '0'));
    signal ang_y : ang_arr_t := (others => (others => '0'));

    -- 多面體管線輸出
    type face_arr_t is array (0 to SHAPES - 1) of unsigned(4 downto 0);
    signal inside : std_logic_vector(SHAPES - 1 downto 0);
    signal face   : face_arr_t;                   -- 看到的面（進入點）
    signal bface  : face_arr_t;                   -- 光線離開的背面
    signal shade  : rgb_arr_t;
    signal dot_f  : std_logic_vector(SHAPES - 1 downto 0);   -- 進入點 / 離開點落在點雲的點上
    signal dot_b  : std_logic_vector(SHAPES - 1 downto 0);

    -- 與多面體管線對齊的延遲線
    type u12_pipe_t is array (1 to SOLID_LAT) of unsigned(11 downto 0);
    signal x_d, y_d : u12_pipe_t := (others => (others => '0'));
    signal de_d     : std_logic_vector(1 to SOLID_LAT) := (others => '0');
    signal hs_d     : std_logic_vector(1 to SOLID_LAT) := (others => '0');
    signal vs_d     : std_logic_vector(1 to SOLID_LAT) := (others => '0');

    -- 合成：標籤 = 在形狀內 & 形狀編號（2 bit）& 面編號（5 bit），背景為 0
    --   正面標籤（看到的面）與背面標籤（光線離開的面）打包成 16 bit，存進同一組行緩衝：
    --   兩個行緩衝存上一行、上兩行同一欄的標籤，標籤和左邊或上面兩個像素不同就是稜線
    subtype label_t is std_logic_vector(7 downto 0);
    subtype pair_t  is std_logic_vector(15 downto 0);   -- 背面標籤 & 正面標籤
    type line_buf_t is array (0 to H_ACTIVE - 1) of pair_t;
    signal lb1, lb2   : line_buf_t := (others => (others => '0'));
    signal c1_rgb     : std_logic_vector(23 downto 0) := (others => '0');
    signal c1_holo    : std_logic_vector(23 downto 0) := (others => '0');   -- 點雲的顏色
    signal c1_lab     : label_t := (others => '0');
    signal c1_blab    : label_t := (others => '0');
    signal c1_x       : unsigned(11 downto 0) := (others => '0');
    signal c1_y       : unsigned(1 downto 0)  := (others => '0');   -- 背面虛線用的座標低位元
    signal c1_de      : std_logic := '0';
    signal c1_hs      : std_logic := '0';
    signal c1_vs      : std_logic := '0';
    signal up1        : pair_t := (others => '0');    -- (x, y-1)，與 c1 對齊
    signal c2_rgb     : std_logic_vector(23 downto 0) := (others => '0');
    signal c2_holo    : std_logic_vector(23 downto 0) := (others => '0');
    signal c2_lab     : label_t := (others => '0');
    signal c2_blab    : label_t := (others => '0');
    signal c2_x       : unsigned(1 downto 0) := (others => '0');
    signal c2_y       : unsigned(1 downto 0) := (others => '0');
    signal c2_de      : std_logic := '0';
    signal c2_hs      : std_logic := '0';
    signal c2_vs      : std_logic := '0';
    signal c2_up1     : pair_t := (others => '0');    -- 以下與 c2 對齊：(x, y-1)
    signal c2_up2     : pair_t := (others => '0');    -- (x, y-2)
    signal c2_left1   : label_t := (others => '0');   -- (x-1, y)
    signal c2_left2   : label_t := (others => '0');   -- (x-2, y)
    signal c2_bleft1  : label_t := (others => '0');   -- 背面標籤的 (x-1, y)
    signal c2_bleft2  : label_t := (others => '0');   -- 背面標籤的 (x-2, y)

    -- RGB888 視訊串流（送給 HDMI 輸出級；接回 VGA 時兩個輸出級共用）
    signal stream_rgb   : std_logic_vector(23 downto 0) := (others => '0');
    signal stream_label : label_t := (others => '0');
    signal stream_de    : std_logic := '0';
    signal stream_hs    : std_logic := '0';
    signal stream_vs    : std_logic := '0';

    -- VGA 輸出暫存器
    -- [VGA] signal r_reg  : std_logic_vector(RED_BITS - 1 downto 0)   := (others => '0');
    -- [VGA] signal g_reg  : std_logic_vector(GREEN_BITS - 1 downto 0) := (others => '0');
    -- [VGA] signal b_reg  : std_logic_vector(BLUE_BITS - 1 downto 0)  := (others => '0');
    -- [VGA] signal hs_reg : std_logic := '0';
    -- [VGA] signal vs_reg : std_logic := '0';

    -- HDMI：RGB -> YCbCr（第一拍），再排成 4:2:2（第二拍）
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

    function pol(v : std_logic; active_low : boolean) return std_logic is
    begin
        if active_low then
            return not v;
        else
            return v;
        end if;
    end function;

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

    --------------------------------------------------
    -- 1. 像素致能：每 PIX_DIV 個 clk 一拍
    --------------------------------------------------
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


    --------------------------------------------------
    -- 2. 視訊時序
    --------------------------------------------------
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


    --------------------------------------------------
    -- 3. 按鈕 ×4、暫停開關與設定暫存器
    --------------------------------------------------
    u_btn_mode : entity work.HW_3_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_mode, press => p_mode);

    u_btn_speed : entity work.HW_3_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_speed, press => p_speed);

    u_btn_dir : entity work.HW_3_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_dir, press => p_dir);

    u_btn_style : entity work.HW_3_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_style, press => p_style);

    -- 開關是電位，不會彈跳出多次觸發，只需同步
    process(clk)
    begin
        if rising_edge(clk) then
            pause_s1 <= sw_pause;
            pause_s2 <= pause_s1;
        end if;
    end process;

    running <= not pause_s2;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                mode      <= '0';
                dir       <= '0';
                speed_sel <= "01";
                holo      <= '0';
            else
                if p_mode = '1' then
                    mode <= not mode;
                end if;
                if p_dir = '1' then
                    dir <= not dir;
                end if;
                if p_speed = '1' then
                    speed_sel <= speed_sel + 1;
                end if;
                if p_style = '1' then
                    holo <= not holo;
                end if;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 4. 角度：每幀在垂直遮沒開頭更新，下一拍通知多面體單元重算 W
    --------------------------------------------------
    process(clk)
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


    --------------------------------------------------
    -- 5. 多面體管線 ×3
    --------------------------------------------------
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


    --------------------------------------------------
    -- 6. 延遲線：座標與同步訊號延遲 SOLID_LAT 個 ce，與 inside / face 對齊
    --------------------------------------------------
    process(clk)
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


    --------------------------------------------------
    -- 7. 合成（3 級）-> 遮沒期間輸出黑色
    --    C1：基本模式畫色塊；進階模式由下層往上層蓋形狀，得到打光顏色、點雲顏色與正面 / 背面標籤；
    --        讀寫第一個行緩衝
    --    C2：讀寫第二個行緩衝，左邊兩個像素的標籤
    --    C3：標籤和 (x-1)、(x-2)、(y-1)、(y-2) 任一個不同 -> 稜線（2 像素寬）
    --      實心：正面稜線白色，其餘為打光顏色
    --      全息：正面稜線白色；正面或背面落在點上 -> 形體顏色；背面稜線 -> 形體顏色的虛線；其餘黑色
    --------------------------------------------------
    process(clk)
        variable pix  : std_logic_vector(23 downto 0);
        variable hpix : std_logic_vector(23 downto 0);
        variable lab  : label_t;
        variable blab : label_t;
        variable xi   : integer range 0 to 4095;
        variable yi   : integer range 0 to 4095;
        variable ridge : boolean;
        variable bridge : boolean;
        variable dash : unsigned(1 downto 0);
        variable outp : std_logic_vector(23 downto 0);
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                -- C1
                xi  := to_integer(x_d(SOLID_LAT));
                yi  := to_integer(y_d(SOLID_LAT));
                lab  := (others => '0');
                blab := (others => '0');
                hpix := BG_C;

                if mode = '0' then
                    pix := (others => '0');
                    if xi >= R_X and xi < R_X + R_W and yi >= R_Y and yi < R_Y + R_H then
                        pix(23 downto 16) := x"FF";
                    end if;
                    if xi >= G_X and xi < G_X + G_W and yi >= G_Y and yi < G_Y + G_H then
                        pix(15 downto 8) := x"FF";
                    end if;
                    if xi >= B_X and xi < B_X + B_W and yi >= B_Y and yi < B_Y + B_H then
                        pix(7 downto 0) := x"FF";
                    end if;

                else
                    pix := BG_C;
                    for k in SHAPES - 1 downto 0 loop
                        if inside(k) = '1' then
                            pix  := shade(k);
                            lab  := '1' & std_logic_vector(to_unsigned(k, 2)) & std_logic_vector(face(k));
                            blab := '1' & std_logic_vector(to_unsigned(k, 2)) & std_logic_vector(bface(k));
                            if dot_f(k) = '1' or dot_b(k) = '1' then
                                hpix := BASE_C(k);
                            else
                                hpix := BG_C;
                            end if;
                        end if;
                    end loop;
                end if;

                if de_d(SOLID_LAT) = '0' then
                    lab  := (others => '0');
                    blab := (others => '0');
                end if;

                c1_rgb  <= pix;
                c1_holo <= hpix;
                c1_lab  <= lab;
                c1_blab <= blab;
                c1_x   <= x_d(SOLID_LAT);
                c1_y   <= y_d(SOLID_LAT)(1 downto 0);
                c1_de  <= de_d(SOLID_LAT);
                c1_hs  <= hs_d(SOLID_LAT);
                c1_vs  <= vs_d(SOLID_LAT);
                if de_d(SOLID_LAT) = '1' then
                    up1     <= lb1(xi);
                    lb1(xi) <= blab & lab;
                end if;

                -- C2：lb2 存的是上一行讀出的 up1，再讀出來就是上兩行
                c2_rgb    <= c1_rgb;
                c2_holo   <= c1_holo;
                c2_lab    <= c1_lab;
                c2_blab   <= c1_blab;
                c2_bleft1 <= c2_blab;
                c2_bleft2 <= c2_bleft1;
                c2_x     <= c1_x(1 downto 0);
                c2_y     <= c1_y;
                c2_de    <= c1_de;
                c2_hs    <= c1_hs;
                c2_vs    <= c1_vs;
                c2_up1   <= up1;
                c2_left1 <= c2_lab;
                c2_left2 <= c2_left1;
                if c1_de = '1' then
                    c2_up2                <= lb2(to_integer(c1_x));
                    lb2(to_integer(c1_x)) <= up1;
                end if;

                -- C3
                ridge  := c2_lab /= c2_left1 or c2_lab /= c2_left2 or
                          c2_lab /= c2_up1(7 downto 0) or c2_lab /= c2_up2(7 downto 0);
                bridge := c2_blab /= c2_bleft1 or c2_blab /= c2_bleft2 or
                          c2_blab /= c2_up1(15 downto 8) or c2_blab /= c2_up2(15 downto 8);
                dash   := c2_x + c2_y;              -- (x + y) mod 4 < 2 才畫：虛線
                outp   := c2_rgb;
                if mode = '1' then
                    if ridge then
                        outp := EDGE_C;
                    elsif holo = '1' then
                        if c2_holo /= BG_C then
                            outp := c2_holo;
                        elsif bridge and c2_blab(7) = '1' and dash(1) = '0' then
                            outp := BASE_C(to_integer(unsigned(c2_blab(6 downto 5))) mod SHAPES);
                        else
                            outp := BG_C;
                        end if;
                    end if;
                end if;
                if c2_de = '0' then
                    outp := (others => '0');
                end if;

                stream_rgb   <= outp;
                stream_label <= c2_lab;
                stream_de    <= c2_de;
                stream_hs    <= c2_hs;
                stream_vs    <= c2_vs;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 8. VGA 輸出級：取各色高位元、調整同步極性（EGO-XZ7 沒有 VGA 接頭，先註解掉）
    --------------------------------------------------
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


    --------------------------------------------------
    -- 9. HDMI 輸出級：板子上的 ADV7511 負責 TMDS 編碼，FPGA 只送影像資料、hs、vs 與像素時脈
    --    ADV7511 的輸入匯流排有 36 bit，24 bit RGB 時 R 在 D35..28，但板子只接了 D23..D0，
    --    所以照 ZedBoard 的接法送 16 bit YCbCr 4:2:2：D23..16 = Cb / Cr 輪流、D15..8 = Y，D7..0 不用；
    --    ADV7511 再用內建的 CSC 轉回 RGB（HW_3_hdmi_cfg 設定）
    --    第一拍：RGB -> YCbCr，BT.709、有限範圍（Y 16 ~ 235、Cb / Cr 16 ~ 240），係數 × 256，
    --      先加偏移量讓被除數不為負，除以 256 就是右移
    --    第二拍：每行第一個像素送 Cb，之後 Cr、Cb 輪流（不濾波，直接取該像素的色度）
    --    像素時脈由 div_cnt 解出，在資料換值後半個像素才上升，
    --    ADV7511 在上升緣取樣，前後各有半個像素（20 ns）的餘裕
    --    板子沒有接 DE，由 ADV7511 的 DE 產生器依 hs、vs 自己算（HW_3_hdmi_cfg 設定）
    --------------------------------------------------
    process(clk)
        variable r, g, b : natural range 0 to 255;
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                -- 第一拍
                r := to_integer(unsigned(stream_rgb(23 downto 16)));
                g := to_integer(unsigned(stream_rgb(15 downto 8)));
                b := to_integer(unsigned(stream_rgb(7 downto 0)));
                ycc_y  <= to_unsigned((4224 + 47 * r + 157 * g + 16 * b) / 256, 8);
                ycc_cb <= to_unsigned((32896 - 26 * r - 87 * g + 112 * b) / 256, 8);
                ycc_cr <= to_unsigned((32896 + 112 * r - 102 * g - 10 * b) / 256, 8);
                ycc_de <= stream_de;
                ycc_hs <= stream_hs;
                ycc_vs <= stream_vs;

                -- 第二拍
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

    u_hdmi_cfg : entity work.HW_3_hdmi_cfg
        generic map (
            I2C_DIV => I2C_DIV, START_DELAY => HDMI_CFG_DELAY,
            H_ACTIVE => H_ACTIVE, V_ACTIVE => V_ACTIVE,
            H_DE_DELAY => H_SYNC + H_BP, V_DE_DELAY => V_SYNC + V_BP,
            SYNC_ACTIVE_LOW => SYNC_ACTIVE_LOW
        )
        port map (clk => clk, reset => reset, scl => hdmi_scl, sda => hdmi_sda, ok => hdmi_ok);

    -- LD0 旋轉多面體模式、LD1 轉動中、LD2 反轉、LD4..3 轉速、LD5 全息點雲、LD6 ADV7511 設定成功、
    -- LD7 心跳（約每秒閃一次）
    led(0) <= pol(mode, LED_ACTIVE_LOW);
    led(1) <= pol(running, LED_ACTIVE_LOW);
    led(2) <= pol(dir, LED_ACTIVE_LOW);
    led(3) <= pol(speed_sel(0), LED_ACTIVE_LOW);
    led(4) <= pol(speed_sel(1), LED_ACTIVE_LOW);
    led(5) <= pol(holo, LED_ACTIVE_LOW);
    led(6) <= pol(hdmi_ok, LED_ACTIVE_LOW);
    led(7) <= pol(frame_cnt(5), LED_ACTIVE_LOW);

end Behavioral;
