library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW3 VGA 掃描：RGB 色塊 + 旋轉幾何圖形（規格見 HW3/SPEC.md）
--   基本模式（reset 後）：R、G、B 三個矩形色塊，位置與大小由 generic 設定，重疊處加色混合
--   進階模式（按 BTNU 切換）：三角形、正方形、六邊形各自旋轉，由 HW_3_poly 的矩陣管線判斷像素
--   內部資料流：時序 -> 多邊形管線 -> 合成 RGB888 視訊串流 -> VGA 輸出級
--   視訊串流（stream_*）與 VGA 腳位無關，日後 HDMI 編碼器接在這裡
entity HW_3 is
    Generic (
        PIX_DIV         : positive := 4;          -- 100 MHz / 4 = 25 MHz 像素率；獨立像素時脈時設 1
        H_ACTIVE        : positive := 640;        -- 640×480@60（像素時脈 25.175 MHz，用 25 MHz 近似）
        H_FP            : positive := 16;
        H_SYNC          : positive := 96;
        H_BP            : positive := 48;
        V_ACTIVE        : positive := 480;
        V_FP            : positive := 10;
        V_SYNC          : positive := 2;
        V_BP            : positive := 33;
        SYNC_ACTIVE_LOW : boolean  := true;       -- 640×480@60 的 hs / vs 為負極性
        RED_BITS        : positive := 1;          -- 每色位元數（1 ~ 8）；作業規定 R、G、B 各 1 bit
        GREEN_BITS      : positive := 1;
        BLUE_BITS       : positive := 1;
        -- 基本模式的色塊：左上角 (X, Y)、寬 W、高 H（像素）
        R_X : natural := 60;   R_Y : natural := 160;  R_W : natural := 160;  R_H : natural := 160;
        G_X : natural := 240;  G_Y : natural := 160;  G_W : natural := 160;  G_H : natural := 160;
        B_X : natural := 420;  B_Y : natural := 160;  B_W : natural := 160;  B_H : natural := 160;
        ANGLE_BITS      : positive := 10;         -- 一圈 1024 步
        DEBOUNCE_CYCLES : positive := 2_000_000;  -- 20 ms
        BTN_ACTIVE_LOW  : boolean  := false;
        LED_ACTIVE_LOW  : boolean  := false
    );
    Port (
        clk       : in  STD_LOGIC;
        reset     : in  STD_LOGIC;
        btn_mode  : in  STD_LOGIC;                -- 基本色塊 <-> 旋轉圖形
        sw_pause  : in  STD_LOGIC;                -- 撥上暫停旋轉
        btn_speed : in  STD_LOGIC;                -- 轉速 ×1 -> ×2 -> ×4 -> ×8
        btn_dir   : in  STD_LOGIC;                -- 反轉
        btn_style : in  STD_LOGIC;                -- 填色 + 外框 -> 只填色 -> 只有外框
        vga_r     : out STD_LOGIC_VECTOR(RED_BITS - 1 downto 0);
        vga_g     : out STD_LOGIC_VECTOR(GREEN_BITS - 1 downto 0);
        vga_b     : out STD_LOGIC_VECTOR(BLUE_BITS - 1 downto 0);
        vga_hs    : out STD_LOGIC;
        vga_vs    : out STD_LOGIC;
        led       : out STD_LOGIC_VECTOR(7 downto 0)
    );
end HW_3;

architecture Behavioral of HW_3 is

    --------------------------------------------------
    -- 形狀設定：0 = 三角形、1 = 正方形、2 = 六邊形，編號小的在上層
    --   位置與大小跟著解析度縮放，換成 HDMI 的 1280×720 也排得下
    --------------------------------------------------
    constant SHAPES   : positive := 3;
    constant POLY_LAT : positive := 4;            -- HW_3_poly 的管線深度（ce 數）

    type int_arr_t is array (0 to SHAPES - 1) of integer;
    type rgb_arr_t is array (0 to SHAPES - 1) of std_logic_vector(23 downto 0);

    constant SIDES_A : int_arr_t := (3, 4, 6);
    constant SPIN_A  : int_arr_t := (3, -2, 1);   -- 每幀轉 SPIN × 2^speed 步，正數順時針
    constant CX_A    : int_arr_t := (H_ACTIVE / 4, H_ACTIVE / 2, 3 * H_ACTIVE / 4);
    constant CY      : natural   := V_ACTIVE / 2;
    constant RADIUS  : positive  := H_ACTIVE * 9 / 64;   -- 640 寬時 90 像素
    constant EDGE_W  : positive  := 4;

    -- 每色最高位元恰好是純紅、純綠、純藍與白色，1 bit 輸出時顏色不會跑掉
    constant FILL_C : rgb_arr_t := (x"E04050", x"40C060", x"3070F0");
    constant EDGE_C : rgb_arr_t := (x"FFD0D0", x"D0FFD0", x"D0E8FF");
    constant BG_C   : std_logic_vector(23 downto 0) := x"080A14";
    constant GRID_C : std_logic_vector(23 downto 0) := x"202838";

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
    signal mode      : std_logic := '0';          -- 0 基本色塊、1 旋轉圖形
    signal running   : std_logic;
    signal dir       : std_logic := '0';
    signal speed_sel : unsigned(1 downto 0) := "01";
    signal style     : unsigned(1 downto 0) := "00";
    signal frame_cnt : unsigned(5 downto 0) := (others => '0');

    -- 角度
    type ang_arr_t is array (0 to SHAPES - 1) of unsigned(ANGLE_BITS - 1 downto 0);
    signal ang : ang_arr_t := (others => (others => '0'));

    -- 多邊形管線輸出
    signal inside : std_logic_vector(SHAPES - 1 downto 0);
    signal edge   : std_logic_vector(SHAPES - 1 downto 0);

    -- 與多邊形管線對齊的延遲線
    type u12_pipe_t is array (1 to POLY_LAT) of unsigned(11 downto 0);
    signal x_d, y_d : u12_pipe_t := (others => (others => '0'));
    signal de_d     : std_logic_vector(1 to POLY_LAT) := (others => '0');
    signal hs_d     : std_logic_vector(1 to POLY_LAT) := (others => '0');
    signal vs_d     : std_logic_vector(1 to POLY_LAT) := (others => '0');

    -- RGB888 視訊串流（HDMI 接點）
    signal stream_rgb : std_logic_vector(23 downto 0) := (others => '0');
    signal stream_de  : std_logic := '0';
    signal stream_hs  : std_logic := '0';
    signal stream_vs  : std_logic := '0';

    -- VGA 輸出暫存器
    signal r_reg  : std_logic_vector(RED_BITS - 1 downto 0)   := (others => '0');
    signal g_reg  : std_logic_vector(GREEN_BITS - 1 downto 0) := (others => '0');
    signal b_reg  : std_logic_vector(BLUE_BITS - 1 downto 0)  := (others => '0');
    signal hs_reg : std_logic := '0';
    signal vs_reg : std_logic := '0';

    function pol(v : std_logic; active_low : boolean) return std_logic is
    begin
        if active_low then
            return not v;
        else
            return v;
        end if;
    end function;

begin

    assert RED_BITS <= 8 and GREEN_BITS <= 8 and BLUE_BITS <= 8
        report "VGA color depth must be at most 8 bits per channel"
        severity failure;

    assert R_X + R_W <= H_ACTIVE and G_X + G_W <= H_ACTIVE and B_X + B_W <= H_ACTIVE and
           R_Y + R_H <= V_ACTIVE and G_Y + G_H <= V_ACTIVE and B_Y + B_H <= V_ACTIVE
        report "RGB blocks must fit inside the visible area"
        severity failure;

    assert ANGLE_BITS >= 6
        report "ANGLE_BITS must be at least 6 to hold SPIN x 8 steps per frame"
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
                style     <= "00";
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
                -- style：00 -> 01 -> 10 -> 00
                if p_style = '1' then
                    if style = "10" then
                        style <= "00";
                    else
                        style <= style + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 4. 角度：每幀在垂直遮沒開頭更新，下一拍通知多邊形單元重算 W
    --------------------------------------------------
    process(clk)
        variable step : signed(ANGLE_BITS - 1 downto 0);
    begin
        if rising_edge(clk) then
            load <= '0';
            if reset = '1' then
                ang       <= (others => (others => '0'));
                frame_cnt <= (others => '0');
            elsif frame_tick = '1' then
                load      <= '1';
                frame_cnt <= frame_cnt + 1;
                if running = '1' then
                    for k in 0 to SHAPES - 1 loop
                        step := shift_left(to_signed(SPIN_A(k), ANGLE_BITS), to_integer(speed_sel));
                        if dir = '1' then
                            step := -step;
                        end if;
                        ang(k) <= ang(k) + unsigned(step);
                    end loop;
                end if;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 5. 多邊形矩陣管線 ×3
    --------------------------------------------------
    gen_poly : for k in 0 to SHAPES - 1 generate
        u_poly : entity work.HW_3_poly
            generic map (
                SIDES => SIDES_A(k), CX => CX_A(k), CY => CY,
                RADIUS => RADIUS, EDGE_W => EDGE_W, ANGLE_BITS => ANGLE_BITS
            )
            port map (
                clk => clk, reset => reset, ce => pix_ce, load => load, angle => ang(k),
                x => t_x, y => t_y, inside => inside(k), edge => edge(k)
            );
    end generate;


    --------------------------------------------------
    -- 6. 延遲線：座標與同步訊號延遲 POLY_LAT 個 ce，與 inside / edge 對齊
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
                for i in 2 to POLY_LAT loop
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
    -- 7. 合成 -> 遮沒期間輸出黑色
    --    基本模式：黑底，R、G、B 色塊各自點亮一個顏色通道，重疊處加色（黃、青、洋紅、白）
    --    進階模式：背景格線 -> 由下層往上層蓋形狀
    --      style 00 填色 + 外框、01 只填色、10 只有外框
    --------------------------------------------------
    process(clk)
        variable pix : std_logic_vector(23 downto 0);
        variable xi  : integer range 0 to 4095;
        variable yi  : integer range 0 to 4095;
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                xi := to_integer(x_d(POLY_LAT));
                yi := to_integer(y_d(POLY_LAT));

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
                    if x_d(POLY_LAT)(4 downto 0) = "00000" or y_d(POLY_LAT)(4 downto 0) = "00000" then
                        pix := GRID_C;
                    else
                        pix := BG_C;
                    end if;

                    for k in SHAPES - 1 downto 0 loop
                        if edge(k) = '1' and style /= "01" then
                            pix := EDGE_C(k);
                        elsif inside(k) = '1' and style /= "10" then
                            pix := FILL_C(k);
                        end if;
                    end loop;
                end if;

                if de_d(POLY_LAT) = '0' then
                    pix := (others => '0');
                end if;

                stream_rgb <= pix;
                stream_de  <= de_d(POLY_LAT);
                stream_hs  <= hs_d(POLY_LAT);
                stream_vs  <= vs_d(POLY_LAT);
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 8. VGA 輸出級：取各色高位元、調整同步極性
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if pix_ce = '1' then
                r_reg  <= stream_rgb(23 downto 24 - RED_BITS);
                g_reg  <= stream_rgb(15 downto 16 - GREEN_BITS);
                b_reg  <= stream_rgb(7 downto 8 - BLUE_BITS);
                hs_reg <= pol(stream_hs, SYNC_ACTIVE_LOW);
                vs_reg <= pol(stream_vs, SYNC_ACTIVE_LOW);
            end if;
        end if;
    end process;

    vga_r  <= r_reg;
    vga_g  <= g_reg;
    vga_b  <= b_reg;
    vga_hs <= hs_reg;
    vga_vs <= vs_reg;

    -- LD0 旋轉圖形模式、LD1 轉動中、LD2 反轉、LD4..3 轉速、LD6..5 樣式、LD7 心跳（約每秒閃一次）
    led(0) <= pol(mode, LED_ACTIVE_LOW);
    led(1) <= pol(running, LED_ACTIVE_LOW);
    led(2) <= pol(dir, LED_ACTIVE_LOW);
    led(3) <= pol(speed_sel(0), LED_ACTIVE_LOW);
    led(4) <= pol(speed_sel(1), LED_ACTIVE_LOW);
    led(5) <= pol(style(0), LED_ACTIVE_LOW);
    led(6) <= pol(style(1), LED_ACTIVE_LOW);
    led(7) <= pol(frame_cnt(5), LED_ACTIVE_LOW);

end Behavioral;
