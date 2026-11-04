library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- HW4 LED 乒乓球（規格見 HW4/SPEC.md）
--   8 顆 LED 是球桌（LD7 = 左端、LD0 = 右端），BTNL / BTNR 是左右球拍。
--   球抵達接球方邊界前後 HIT_EARLY_MS / HIT_LATE_MS 內按下就反向；太早按或沒按判輸。
--   得分時以長條顯示得分方分數並 1 Hz 閃爍，由得分方發下一球；先到 WIN_SCORE 分獲勝。
--
--   ① 1 ms 節拍       tick_1ms
--   ② 按鈕介面 ×2     press_l、press_r（HW_4_btn），SW0 兩級同步 sw_speed_s
--   ③ 遊戲 FSM        state、t_rel、step_cnt、step_ms、hit_pending、server、wait_cnt
--   ④ 球與計分暫存器  pos、to_left、score_l、score_r（在 ③ 同一個 process）
--   ⑤ 1 Hz 閃爍       blink_cnt、blink_on
--   ⑥ LED 輸出選擇    led_reg
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
    constant EDGE_L          : integer  := 7;
    constant EDGE_R          : integer  := 0;
    constant TRAVEL          : positive := 7;      -- 從一端到另一端的步數
    constant T_REL_MIN       : integer  := -TRAVEL * STEP_MS_INIT;

    -- 分數長條：右玩家從 LD0 往左亮 s 顆，左玩家從 LD7 往右亮 s 顆
    function bar_r(s : natural) return std_logic_vector is
        variable v : std_logic_vector(7 downto 0) := (others => '0');
    begin
        for k in 0 to 7 loop
            if k < s then
                v(k) := '1';
            end if;
        end loop;
        return v;
    end function;

    function bar_l(s : natural) return std_logic_vector is
        variable v : std_logic_vector(7 downto 0) := (others => '0');
    begin
        for k in 0 to 7 loop
            if k < s then
                v(7 - k) := '1';
            end if;
        end loop;
        return v;
    end function;

    function edge_of(left : std_logic) return integer is
    begin
        if left = '1' then
            return EDGE_L;
        else
            return EDGE_R;
        end if;
    end function;

    function polarity(v : std_logic_vector(7 downto 0)) return std_logic_vector is
    begin
        if LED_ACTIVE_LOW then
            return not v;
        else
            return v;
        end if;
    end function;

    -- ① 1 ms 節拍
    signal tick_cnt : integer range 0 to TICK_DIV - 1 := 0;
    signal tick_1ms : std_logic := '0';

    -- ② 按鈕與開關
    signal press_l    : std_logic;
    signal press_r    : std_logic;
    signal sw_s1      : std_logic := '0';
    signal sw_speed_s : std_logic := '0';

    -- ③ 遊戲 FSM
    type state_t is (S_SERVE, S_PLAY, S_POINT, S_OVER);
    signal state       : state_t := S_SERVE;
    signal server      : std_logic := '1';    -- '1' = 左玩家發球；POINT / OVER 中也代表得分方 / 勝方
    signal t_rel       : integer range T_REL_MIN to HIT_LATE_MS := 0;  -- 距離球抵達接球方邊界的 ms
    signal step_cnt    : integer range 0 to STEP_MS_INIT - 1 := 0;
    signal step_ms     : integer range STEP_MS_MIN to STEP_MS_INIT := STEP_MS_INIT;
    signal hit_pending : std_logic := '0';    -- 判定窗內提早按下，等球抵達邊界再反向
    signal wait_cnt    : integer range 0 to SCORE_SHOW_MS - 1 := 0;

    -- ④ 球與計分
    signal pos     : integer range 0 to 7 := EDGE_L;
    signal to_left : std_logic := '0';        -- '1' = 球往左（pos 遞增），接球方是左玩家
    signal score_l : integer range 0 to WIN_SCORE := 0;
    signal score_r : integer range 0 to WIN_SCORE := 0;

    -- ⑤ 1 Hz 閃爍
    signal blink_cnt : integer range 0 to BLINK_HALF_MS - 1 := 0;
    signal blink_on  : std_logic := '1';

    -- ⑥ LED 輸出
    signal led_reg : std_logic_vector(7 downto 0) := polarity("10000000");

begin

    assert CLK_FREQ_HZ mod 1000 = 0
        report "CLK_FREQ_HZ must be a multiple of 1000 for an exact 1 ms tick"
        severity failure;

    assert STEP_MS_MIN <= STEP_MS_INIT
        report "STEP_MS_MIN must not exceed STEP_MS_INIT"
        severity failure;

    assert WIN_SCORE <= 8
        report "WIN_SCORE must be 1 to 8: the score bar has only 8 LEDs"
        severity failure;

    -- 否則球一發出就在判定窗內，早按永遠不會發生
    assert HIT_EARLY_MS < TRAVEL * STEP_MS_MIN
        report "HIT_EARLY_MS must be shorter than 7 * STEP_MS_MIN"
        severity failure;

    -- POINT 結束時剛好閃完整數次，OVER 才會從亮開始
    assert SCORE_SHOW_MS mod (2 * BLINK_HALF_MS) = 0
        report "SCORE_SHOW_MS must be a multiple of 2 * BLINK_HALF_MS"
        severity failure;

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
    -- ② 按鈕介面 ×2、SW0 兩級同步
    --------------------------------------------------
    u_btn_l : entity work.HW_4_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_l, press => press_l);

    u_btn_r : entity work.HW_4_btn
        generic map (DEBOUNCE_CYCLES => DEBOUNCE_CYCLES, ACTIVE_LOW => BTN_ACTIVE_LOW)
        port map (clk => clk, reset => reset, btn_in => btn_r, press => press_r);

    -- SW0 是電位，只在回擊瞬間取樣一次，不需去彈跳
    process(clk)
    begin
        if rising_edge(clk) then
            sw_s1      <= sw_speed;
            sw_speed_s <= sw_s1;
        end if;
    end process;

    --------------------------------------------------
    -- ③ 遊戲 FSM、④ 球與計分
    --------------------------------------------------
    process(clk)
        variable press_rx : std_logic;   -- 接球方的按鍵
        variable fault    : boolean;     -- 早按：接球方判輸
        variable hit      : boolean;     -- 有效回擊：反向
        variable next_ms  : integer range STEP_MS_MIN to STEP_MS_INIT;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state       <= S_SERVE;
                server      <= '1';
                pos         <= EDGE_L;
                to_left     <= '0';
                score_l     <= 0;
                score_r     <= 0;
                step_ms     <= STEP_MS_INIT;
                step_cnt    <= 0;
                t_rel       <= 0;
                hit_pending <= '0';
                wait_cnt    <= 0;
            else
                case state is

                    -- 球停在發球方邊界，只有發球方能發球
                    when S_SERVE =>
                        if (server = '1' and press_l = '1') or (server = '0' and press_r = '1') then
                            to_left     <= not server;          -- 往對方
                            step_ms     <= STEP_MS_INIT;
                            step_cnt    <= 0;
                            t_rel       <= -TRAVEL * STEP_MS_INIT;
                            hit_pending <= '0';
                            state       <= S_PLAY;
                        end if;

                    when S_PLAY =>
                        if to_left = '1' then
                            press_rx := press_l;
                        else
                            press_rx := press_r;
                        end if;

                        -- 1. 接球方按鍵依 t_rel 判定（已記下 hit_pending 後再按忽略）
                        -- 2. 提早按下的回擊在球抵達邊界時生效
                        fault := false;
                        hit   := false;
                        if press_rx = '1' and hit_pending = '0' then
                            if t_rel < -HIT_EARLY_MS then
                                fault := true;
                            elsif t_rel < 0 then
                                hit_pending <= '1';
                            else
                                hit := true;
                            end if;
                        elsif hit_pending = '1' and t_rel >= 0 then
                            hit := true;
                        end if;

                        if fault then
                            -- 非接球方得分，並由他發下一球
                            if to_left = '1' then
                                score_r <= score_r + 1;
                            else
                                score_l <= score_l + 1;
                            end if;
                            server   <= not to_left;
                            wait_cnt <= 0;
                            state    <= S_POINT;

                        elsif hit then
                            -- 反向；SW0 撥上時加速，一趟之內 step_ms 不變
                            if sw_speed_s = '1' and step_ms - STEP_MS_DEC > STEP_MS_MIN then
                                next_ms := step_ms - STEP_MS_DEC;
                            elsif sw_speed_s = '1' then
                                next_ms := STEP_MS_MIN;
                            else
                                next_ms := step_ms;
                            end if;
                            to_left     <= not to_left;
                            step_ms     <= next_ms;
                            step_cnt    <= 0;
                            t_rel       <= -TRAVEL * next_ms;
                            hit_pending <= '0';

                        elsif tick_1ms = '1' then
                            if t_rel = HIT_LATE_MS then
                                -- 3. 出界：接球方判輸（得分處理與早按相同）
                                if to_left = '1' then
                                    score_r <= score_r + 1;
                                else
                                    score_l <= score_l + 1;
                                end if;
                                server   <= not to_left;
                                wait_cnt <= 0;
                                state    <= S_POINT;
                            else
                                -- 4. 推進：t_rel 與 pos 由同一個 tick 推進，抵達邊界時 t_rel 剛好為 0
                                t_rel <= t_rel + 1;
                                if pos /= edge_of(to_left) then
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

                    -- 顯示得分方長條 SCORE_SHOW_MS；按鍵忽略
                    when S_POINT =>
                        if tick_1ms = '1' then
                            if wait_cnt = SCORE_SHOW_MS - 1 then
                                if (server = '1' and score_l = WIN_SCORE) or
                                   (server = '0' and score_r = WIN_SCORE) then
                                    state <= S_OVER;
                                else
                                    pos   <= edge_of(server);
                                    state <= S_SERVE;
                                end if;
                            else
                                wait_cnt <= wait_cnt + 1;
                            end if;
                        end if;

                    -- 勝方長條持續閃爍；任一鍵重新開局，勝方（server）先發
                    when S_OVER =>
                        if press_l = '1' or press_r = '1' then
                            score_l <= 0;
                            score_r <= 0;
                            pos     <= edge_of(server);
                            state   <= S_SERVE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ⑤ 1 Hz 閃爍
    --   SERVE / PLAY 中停在「亮、計數 0」，所以進入 POINT 時一定從亮開始；
    --   SCORE_SHOW_MS 是整數個閃爍週期，進入 OVER 時也剛好回到亮、計數 0
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
    -- ⑥ LED 輸出選擇：球（one-hot）或分數長條，經暫存器輸出
    --------------------------------------------------
    process(clk)
        variable v : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            v := (others => '0');
            case state is
                when S_SERVE | S_PLAY =>
                    v(pos) := '1';
                when S_POINT | S_OVER =>
                    if blink_on = '1' then
                        if server = '1' then
                            v := bar_l(score_l);
                        else
                            v := bar_r(score_r);
                        end if;
                    end if;
            end case;
            led_reg <= polarity(v);
        end if;
    end process;

    led <= led_reg;

end Behavioral;
