library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- HW4 LED 乒乓球（規格見 HW4/SPEC.md）
--   8 顆 LED 是球桌（LD7 = 左端、LD0 = 右端），BTNL / BTNR 是左右球拍。
--   球抵達接球方邊界前後 HIT_EARLY_MS / HIT_LATE_MS 內按下就反向；太早按或沒按判輸。
--   得分時以長條顯示得分方分數並 1 Hz 閃爍，由得分方發下一球；先到 WIN_SCORE 分獲勝。
--
--   ① 1 ms 節拍     tick_1ms
--   ② 按鈕與開關     press_l、press_r（HW_4_btn），sw_speed_s
--   ③ 遊戲 FSM      state、server、wait_cnt
--   ④ 球            pos、to_left、step_ms、step_cnt、t_rel、hit_pending；判定結果 lose
--   ④ 計分          score_l、score_r
--   ⑤ 1 Hz 閃爍     blink_cnt、blink_on
--   ⑥ LED 輸出      led_reg
entity HW_4 is
    Generic (
        CLK_FREQ_HZ    : positive := 100_000_000;  -- 必須是 1000 的倍數
        DEBOUNCE_MS    : positive := 20;
        STEP_MS_INIT   : positive := 300;          -- 發球時每移一格的時間
        STEP_MS_MIN    : positive := 100;          -- 加速後最短一格時間
        STEP_MS_DEC    : natural  := 20;           -- 每次回擊縮短（SW0 撥上才生效）
        HIT_EARLY_MS   : natural  := 250;          -- 判定窗：抵達邊界前
        HIT_LATE_MS    : natural  := 250;          -- 判定窗：抵達邊界後
        WIN_SCORE      : positive := 5;            -- 1 ~ 8
        BLINK_HALF_MS  : positive := 500;          -- 1 Hz 閃爍
        SCORE_SHOW_MS  : positive := 2000;         -- POINT 顯示時間
        LED_ACTIVE_LOW : boolean  := false;
        BTN_ACTIVE_LOW : boolean  := false
    );
    Port (
        clk      : in  STD_LOGIC;
        reset    : in  STD_LOGIC;                     -- 同步、高電位有效
        btn_l    : in  STD_LOGIC;                     -- 左玩家（BTNL）
        btn_r    : in  STD_LOGIC;                     -- 右玩家（BTNR）
        sw_speed : in  STD_LOGIC;                     -- 撥上：回擊時加速（SW0）
        led      : out STD_LOGIC_VECTOR(7 downto 0)   -- led(k) 接 LD k
    );
end HW_4;

architecture Behavioral of HW_4 is

    constant TICK_DIV        : positive := CLK_FREQ_HZ / 1000;
    constant DEBOUNCE_CYCLES : positive := DEBOUNCE_MS * TICK_DIV;
    constant EDGE_L          : integer  := 7;      -- 左邊界 LD7
    constant EDGE_R          : integer  := 0;      -- 右邊界 LD0
    constant TRAVEL          : positive := 7;      -- 從一端到另一端的步數

    -- 分數長條：亮幾顆 = 幾分，從得分方那一端長出來
    type bar_table_t is array (0 to 8) of std_logic_vector(7 downto 0);
    constant BAR_L : bar_table_t := (
        "00000000", "10000000", "11000000", "11100000", "11110000",
        "11111000", "11111100", "11111110", "11111111");
    constant BAR_R : bar_table_t := (
        "00000000", "00000001", "00000011", "00000111", "00001111",
        "00011111", "00111111", "01111111", "11111111");

    -- ① 1 ms 節拍
    signal tick_cnt : integer range 0 to TICK_DIV - 1 := 0;
    signal tick_1ms : std_logic := '0';

    -- ② 按鈕與開關
    signal press_l    : std_logic;
    signal press_r    : std_logic;
    signal press_rx   : std_logic;          -- 接球方的按鍵（球往哪邊就是哪邊）
    signal press_srv  : std_logic;          -- 發球方的按鍵
    signal sw_s1      : std_logic := '0';
    signal sw_speed_s : std_logic := '0';

    -- ③ 遊戲 FSM
    type state_t is (S_SERVE, S_PLAY, S_POINT, S_OVER);
    signal state    : state_t := S_SERVE;
    signal server   : std_logic := '1';     -- '1' = 左玩家發球；POINT / OVER 中也代表得分方 / 勝方
    signal wait_cnt : integer range 0 to SCORE_SHOW_MS - 1 := 0;

    -- ④ 球
    signal pos         : integer range 0 to 7 := EDGE_L;
    signal to_left     : std_logic := '0';  -- '1' = 球往左（pos 遞增），接球方是左玩家
    signal step_ms     : integer range STEP_MS_MIN to STEP_MS_INIT := STEP_MS_INIT;
    signal step_cnt    : integer range 0 to STEP_MS_INIT - 1 := 0;
    signal t_rel       : integer range -TRAVEL * STEP_MS_INIT to HIT_LATE_MS := 0;  -- 距離球抵達邊界的 ms
    signal hit_pending : std_logic := '0';  -- 判定窗內提早按下，等球抵達邊界再反向
    signal lose        : std_logic := '0';  -- 接球方輸了（早按或出界），單拍

    -- ④ 計分
    signal score_l : integer range 0 to WIN_SCORE := 0;
    signal score_r : integer range 0 to WIN_SCORE := 0;

    -- ⑤ 1 Hz 閃爍
    signal blink_cnt : integer range 0 to BLINK_HALF_MS - 1 := 0;
    signal blink_on  : std_logic := '1';

    -- ⑥ LED 輸出（內部一律高電位 = 亮）
    signal led_reg : std_logic_vector(7 downto 0) := "10000000";

begin

    assert CLK_FREQ_HZ mod 1000 = 0
        report "CLK_FREQ_HZ must be a multiple of 1000" severity failure;
    assert STEP_MS_MIN <= STEP_MS_INIT
        report "STEP_MS_MIN must not exceed STEP_MS_INIT" severity failure;
    assert WIN_SCORE <= 8
        report "WIN_SCORE must be 1 to 8" severity failure;
    assert HIT_EARLY_MS < TRAVEL * STEP_MS_MIN
        report "HIT_EARLY_MS must be shorter than 7 * STEP_MS_MIN" severity failure;
    assert SCORE_SHOW_MS mod (2 * BLINK_HALF_MS) = 0
        report "SCORE_SHOW_MS must be a multiple of 2 * BLINK_HALF_MS" severity failure;

    --------------------------------------------------
    -- ① 1 ms 節拍
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            tick_1ms <= '0';
            if reset = '1' then
                tick_cnt <= 0;
            elsif tick_cnt = TICK_DIV - 1 then
                tick_cnt <= 0;
                tick_1ms <= '1';
            else
                tick_cnt <= tick_cnt + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ② 按鈕（同步、去彈跳、按下脈衝）與 SW0 兩級同步
    --------------------------------------------------
    u_btn_l : entity work.HW_4_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_l, press => press_l);

    u_btn_r : entity work.HW_4_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_r, press => press_r);

    press_rx  <= press_l when to_left = '1' else press_r;
    press_srv <= press_l when server  = '1' else press_r;

    process(clk)
    begin
        if rising_edge(clk) then
            sw_s1      <= sw_speed;
            sw_speed_s <= sw_s1;
        end if;
    end process;

    --------------------------------------------------
    -- ③ 遊戲 FSM：只負責切換狀態，記錄發球方與 POINT 顯示時間
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state    <= S_SERVE;
                server   <= '1';
                wait_cnt <= 0;
            else
                case state is
                    when S_SERVE =>
                        if press_srv = '1' then
                            state <= S_PLAY;
                        end if;

                    when S_PLAY =>
                        if lose = '1' then
                            server   <= not to_left;     -- 非接球方得分，由他發下一球
                            wait_cnt <= 0;
                            state    <= S_POINT;
                        end if;

                    when S_POINT =>
                        if tick_1ms = '1' then
                            if wait_cnt = SCORE_SHOW_MS - 1 then
                                if (server = '1' and score_l = WIN_SCORE) or
                                   (server = '0' and score_r = WIN_SCORE) then
                                    state <= S_OVER;
                                else
                                    state <= S_SERVE;
                                end if;
                            else
                                wait_cnt <= wait_cnt + 1;
                            end if;
                        end if;

                    when S_OVER =>
                        if press_l = '1' or press_r = '1' then
                            state <= S_SERVE;           -- server 不變：上一局勝方先發
                        end if;
                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ④ 球：發球、回擊判定、每 ms 推進
    --   發出一趟時 t_rel = −7 × step_ms，之後每 ms 加 1；
    --   pos 由同一個 tick 每 step_ms 移一格，所以球到邊界時 t_rel 剛好是 0。
    --   判定（SPEC §4.3）：
    --     t_rel < −HIT_EARLY_MS 時按      → 早按，lose
    --     −HIT_EARLY_MS ≤ t_rel < 0 時按  → 記下 hit_pending，球到邊界再反向
    --     t_rel ≥ 0 時按（或已記下）       → 反向
    --     t_rel 到 HIT_LATE_MS 還沒反向    → 出界，lose
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            lose <= '0';

            if reset = '1' then
                pos         <= EDGE_L;
                to_left     <= '0';
                step_ms     <= STEP_MS_INIT;
                step_cnt    <= 0;
                t_rel       <= 0;
                hit_pending <= '0';

            elsif state /= S_PLAY then
                -- SERVE / POINT / OVER：球放在下一個發球方的邊界
                -- （POINT、OVER 中 server 已經是得分方 / 勝方，也就是下一個發球方）
                if server = '1' then
                    pos <= EDGE_L;
                else
                    pos <= EDGE_R;
                end if;
                -- 發球方按下就往對方發出，回到初始球速
                if state = S_SERVE and press_srv = '1' then
                    to_left     <= not server;
                    step_ms     <= STEP_MS_INIT;
                    step_cnt    <= 0;
                    t_rel       <= -TRAVEL * STEP_MS_INIT;
                    hit_pending <= '0';
                end if;

            elsif state = S_PLAY and lose = '0' then
                -- 判定窗內、球還沒到邊界就按：先記下
                if press_rx = '1' and t_rel >= -HIT_EARLY_MS and t_rel < 0 then
                    hit_pending <= '1';
                end if;

                if press_rx = '1' and t_rel < -HIT_EARLY_MS then
                    -- 早按：接球方輸
                    lose <= '1';

                elsif (press_rx = '1' or hit_pending = '1') and t_rel >= 0 then
                    -- 回擊：反向；SW0 撥上時加速，最快 STEP_MS_MIN
                    to_left     <= not to_left;
                    step_cnt    <= 0;
                    hit_pending <= '0';
                    if sw_speed_s = '1' and step_ms - STEP_MS_DEC > STEP_MS_MIN then
                        step_ms <= step_ms - STEP_MS_DEC;
                        t_rel   <= -TRAVEL * (step_ms - STEP_MS_DEC);
                    elsif sw_speed_s = '1' then
                        step_ms <= STEP_MS_MIN;
                        t_rel   <= -TRAVEL * STEP_MS_MIN;
                    else
                        t_rel   <= -TRAVEL * step_ms;
                    end if;

                elsif tick_1ms = '1' then
                    if t_rel = HIT_LATE_MS then
                        -- 出界：接球方輸
                        lose <= '1';
                    else
                        -- 推進：t_rel 加 1；球還沒到邊界時每 step_ms 移一格
                        t_rel <= t_rel + 1;
                        if (to_left = '1' and pos /= EDGE_L) or (to_left = '0' and pos /= EDGE_R) then
                            if step_cnt = step_ms - 1 then
                                step_cnt <= 0;
                                if to_left = '1' then
                                    pos <= pos + 1;
                                else
                                    pos <= pos - 1;
                                end if;
                            else
                                step_cnt <= step_cnt + 1;
                            end if;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ④ 計分：接球方輸時對方加 1 分；OVER 中按任一鍵歸零
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or (state = S_OVER and (press_l = '1' or press_r = '1')) then
                score_l <= 0;
                score_r <= 0;
            elsif lose = '1' then
                if to_left = '1' then
                    score_r <= score_r + 1;
                else
                    score_l <= score_l + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ⑤ 1 Hz 閃爍
    --   SERVE / PLAY 中停在「亮、計數 0」，所以進入 POINT 時一定從亮開始；
    --   SCORE_SHOW_MS 是整數個閃爍週期，進入 OVER 時也剛好回到亮
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or state = S_SERVE or state = S_PLAY then
                blink_cnt <= 0;
                blink_on  <= '1';
            elsif tick_1ms = '1' then
                if blink_cnt = BLINK_HALF_MS - 1 then
                    blink_cnt <= 0;
                    blink_on  <= not blink_on;
                else
                    blink_cnt <= blink_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ⑥ LED 輸出：SERVE / PLAY 顯示球，POINT / OVER 顯示閃爍的分數長條
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if state = S_SERVE or state = S_PLAY then
                led_reg      <= (others => '0');
                led_reg(pos) <= '1';
            elsif blink_on = '0' then
                led_reg <= (others => '0');
            elsif server = '1' then
                led_reg <= BAR_L(score_l);
            else
                led_reg <= BAR_R(score_r);
            end if;
        end if;
    end process;

    led <= not led_reg when LED_ACTIVE_LOW else led_reg;

end Behavioral;
