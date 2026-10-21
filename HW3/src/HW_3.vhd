library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW3 VGA 掃描：RGB 色塊 + 旋轉 3D 多面體（規格見 HW3/SPEC.md）
--   基本模式（reset 後）：R、G、B 三個矩形色塊，位置與大小由 generic 設定，重疊處加色混合
--   進階模式（按 BTNU 切換）：立方體、八面體、十二面體各自翻滾，由 HW_3_solid 逐像素算出看到的面
--     BTND 切換兩種樣式：實心打光 + 白色稜線，或全息點雲（正面與背面的稀疏點、背面稜線畫虛線，可透視）
--   內部資料流：時序 -> 多面體管線 -> 合成 RGB888 視訊串流 -> VGA 輸出級（取各色高位元）
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
        RED_BITS        : positive := 1;          -- 每色位元數（1 ~ 8）：基本要求 1 bit；Bonus 不限，
        GREEN_BITS      : positive := 1;          --   接多位元電阻 DAC 時加大（內部全程 RGB888）
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
        btn_mode  : in  STD_LOGIC;                -- 基本色塊 <-> 旋轉多面體
        sw_pause  : in  STD_LOGIC;                -- 撥上暫停旋轉
        btn_speed : in  STD_LOGIC;                -- 轉速 ×1 -> ×2 -> ×4 -> ×8
        btn_dir   : in  STD_LOGIC;                -- 反轉
        btn_style : in  STD_LOGIC;                -- 實心打光 + 稜線 <-> 全息點雲
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

    -- RGB888 視訊串流（HDMI 接點）
    signal stream_rgb   : std_logic_vector(23 downto 0) := (others => '0');
    signal stream_label : label_t := (others => '0');
    signal stream_de    : std_logic := '0';
    signal stream_hs    : std_logic := '0';
    signal stream_vs    : std_logic := '0';

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

    -- LD0 旋轉多面體模式、LD1 轉動中、LD2 反轉、LD4..3 轉速、LD5 全息點雲、LD7 心跳（約每秒閃一次）
    led(0) <= pol(mode, LED_ACTIVE_LOW);
    led(1) <= pol(running, LED_ACTIVE_LOW);
    led(2) <= pol(dir, LED_ACTIVE_LOW);
    led(3) <= pol(speed_sel(0), LED_ACTIVE_LOW);
    led(4) <= pol(speed_sel(1), LED_ACTIVE_LOW);
    led(5) <= pol(holo, LED_ACTIVE_LOW);
    led(6) <= pol('0', LED_ACTIVE_LOW);
    led(7) <= pol(frame_cnt(5), LED_ACTIVE_LOW);

end Behavioral;
