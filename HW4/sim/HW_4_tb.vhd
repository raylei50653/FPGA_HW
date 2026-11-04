library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- HW4 LED 乒乓球測試檔（驗證計畫見 HW4/SPEC.md §10）
--   generic 縮短：1 ms = 10 clk（10 ns），step 20 ms → 加速到 8 ms，判定窗 ±10 ms，閃爍半週期 5 ms，
--   POINT 20 ms，WIN_SCORE = 3。
--   內部訊號（t_rel、pos、score…）以 VHDL-2008 external name 讀取，因此需以 VHDL 2008 編譯。
--   dut_a 為高電位有效版；dut_b 為 LED_ACTIVE_LOW = BTN_ACTIVE_LOW = true 版，輸入反相、輸出應全程反相。
--   最後印出 PASS / FAIL。
entity HW_4_tb is
end HW_4_tb;

architecture sim of HW_4_tb is

    constant CLK_PERIOD : time := 10 ns;
    constant MS         : time := 100 ns;     -- CLK_FREQ_HZ = 10_000：1 ms = 10 clk

    constant STEP_INIT  : integer := 20;
    constant STEP_MIN   : integer := 8;
    constant STEP_DEC   : integer := 4;
    constant EARLY      : integer := 10;
    constant LATE       : integer := 10;
    constant HALF       : integer := 5;
    constant SHOW       : integer := 20;
    constant WIN        : integer := 3;

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';
    signal btn_l    : std_logic := '0';
    signal btn_r    : std_logic := '0';
    signal sw_speed : std_logic := '0';
    signal led_a    : std_logic_vector(7 downto 0);
    signal led_b    : std_logic_vector(7 downto 0);
    signal btn_l_n  : std_logic;
    signal btn_r_n  : std_logic;
    signal sw_n     : std_logic;

    signal done       : boolean := false;
    signal pol_errors : natural := 0;

begin

    clk <= not clk after CLK_PERIOD / 2 when not done else '0';

    btn_l_n <= not btn_l;
    btn_r_n <= not btn_r;
    sw_n    <= sw_speed;     -- SW0 沒有極性 generic，兩版接同一個值

    dut_a : entity work.HW_4
        generic map (
            CLK_FREQ_HZ => 10_000, DEBOUNCE_MS => 2,
            STEP_MS_INIT => STEP_INIT, STEP_MS_MIN => STEP_MIN, STEP_MS_DEC => STEP_DEC,
            HIT_EARLY_MS => EARLY, HIT_LATE_MS => LATE, WIN_SCORE => WIN,
            BLINK_HALF_MS => HALF, SCORE_SHOW_MS => SHOW,
            LED_ACTIVE_LOW => false, BTN_ACTIVE_LOW => false)
        port map (clk => clk, reset => reset, btn_l => btn_l, btn_r => btn_r,
                  sw_speed => sw_speed, led => led_a);

    dut_b : entity work.HW_4
        generic map (
            CLK_FREQ_HZ => 10_000, DEBOUNCE_MS => 2,
            STEP_MS_INIT => STEP_INIT, STEP_MS_MIN => STEP_MIN, STEP_MS_DEC => STEP_DEC,
            HIT_EARLY_MS => EARLY, HIT_LATE_MS => LATE, WIN_SCORE => WIN,
            BLINK_HALF_MS => HALF, SCORE_SHOW_MS => SHOW,
            LED_ACTIVE_LOW => true, BTN_ACTIVE_LOW => true)
        port map (clk => clk, reset => reset, btn_l => btn_l_n, btn_r => btn_r_n,
                  sw_speed => sw_n, led => led_b);

    -- 極性：兩版內部狀態相同，LED 應全程互為反相
    pol_check : process(clk)
    begin
        if falling_edge(clk) and not done then
            if led_b /= not led_a then
                pol_errors <= pol_errors + 1;
            end if;
        end if;
    end process;

    -- 看門狗：整個測試約 0.2 ms（模擬時間）跑完，卡在某個 wait 時直接判失敗
    --   注意 MS 常數遮住了 time 的 ms 單位，這裡的 10_000 * MS = 1 ms 模擬時間
    watchdog : process
    begin
        wait for 10_000 * MS;
        assert done report "HW_4_tb FAIL: timeout (stuck in a wait)" severity failure;
        wait;
    end process;

    stim : process
        alias t_rel   is << signal .HW_4_tb.dut_a.t_rel       : integer range -7 * STEP_INIT to LATE >>;
        alias pos     is << signal .HW_4_tb.dut_a.pos         : integer range 0 to 7 >>;
        alias to_left is << signal .HW_4_tb.dut_a.to_left     : std_logic >>;
        alias score_l is << signal .HW_4_tb.dut_a.score_l     : integer range 0 to WIN >>;
        alias score_r is << signal .HW_4_tb.dut_a.score_r     : integer range 0 to WIN >>;
        alias server  is << signal .HW_4_tb.dut_a.server      : std_logic >>;
        alias step_ms is << signal .HW_4_tb.dut_a.step_ms     : integer range STEP_MIN to STEP_INIT >>;
        alias pending is << signal .HW_4_tb.dut_a.hit_pending : std_logic >>;
        alias press_l is << signal .HW_4_tb.dut_a.press_l     : std_logic >>;
        alias press_r is << signal .HW_4_tb.dut_a.press_r     : std_logic >>;

        variable errors : natural := 0;
        variable t0, t1 : time;
        variable saved  : integer;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                errors := errors + 1;
                report "FAIL: " & msg severity error;
            end if;
        end procedure;

        procedure clocks(n : natural) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
            wait for 1 ns;     -- 讀到這個邊緣更新後的值
        end procedure;

        procedure set_btn(left : boolean; v : std_logic) is
        begin
            if left then
                btn_l <= v;
            else
                btn_r <= v;
            end if;
        end procedure;

        -- 一般按鍵：按住 4 ms、放開 4 ms（都超過去彈跳時間）
        procedure push(left : boolean) is
        begin
            set_btn(left, '1');
            wait for 4 * MS;
            set_btn(left, '0');
            wait for 4 * MS;
        end procedure;

        -- 讓按鍵脈衝落在 t_rel = target 時被 FSM 取樣：
        --   去彈跳延遲 2 + 20 clk，期間經過 2 個 tick，所以在 t_rel = target − 2 時按下。
        --   回傳時停在 FSM 取樣按鍵的那個時脈邊緣之後 1 ns，按鈕仍按著，由呼叫者放開
        procedure hit_at(left : boolean; target : integer) is
        begin
            wait until rising_edge(clk) and t_rel = target - 2;
            set_btn(left, '1');
            if left then
                wait until rising_edge(clk) and press_l = '1';
            else
                wait until rising_edge(clk) and press_r = '1';
            end if;
            check(t_rel = target, "testbench timing: press landed at t_rel = " &
                  integer'image(t_rel) & ", wanted " & integer'image(target));
            wait for 1 ns;
        end procedure;

        procedure let_go(left : boolean) is
        begin
            set_btn(left, '0');
            wait for 4 * MS;
        end procedure;

        function onehot(k : integer) return std_logic_vector is
            variable v : std_logic_vector(7 downto 0) := (others => '0');
        begin
            v(k) := '1';
            return v;
        end function;

    begin
        ------------------------------------------------------------
        report "T1 reset";
        clocks(5);
        reset <= '0';
        clocks(3);
        check(led_a = "10000000", "reset: LD7 should be lit");
        check(score_l = 0 and score_r = 0, "reset: score 0:0");
        check(server = '1', "reset: left serves first");

        ------------------------------------------------------------
        report "T2 only the server can serve";
        saved := t_rel;
        push(false);
        check(t_rel = saved and pos = 7, "BTNR must not serve when left is the server");

        ------------------------------------------------------------
        report "T3 serve, movement and travel time";
        btn_l <= '1';
        wait until rising_edge(clk) and press_l = '1';
        t0 := now;
        wait for 1 ns;
        btn_l <= '0';
        check(to_left = '0', "serve: ball should head right");
        check(t_rel = -7 * STEP_INIT, "serve: t_rel should start at -7 * step");
        for k in 6 downto 0 loop
            wait until pos = k;
            t1 := now;
            if k < 6 then
                check(t1 - t0 = STEP_INIT * MS, "step time at LD" & integer'image(k));
            end if;
            t0 := t1;
            clocks(2);
            check(led_a = onehot(k), "led should be one-hot at LD" & integer'image(k));
        end loop;

        ------------------------------------------------------------
        report "T4 late hit at +HIT_LATE_MS";
        hit_at(false, LATE);
        check(to_left = '1', "late hit at +LATE should return the ball");
        check(step_ms = STEP_INIT, "SW0 off: no speed-up");
        let_go(false);

        ------------------------------------------------------------
        report "T5 early hit at -HIT_EARLY_MS waits for the ball";
        hit_at(true, -EARLY);
        check(pending = '1' and to_left = '1', "early hit should be pending, ball still coming");
        check(pos /= 7, "ball must not be at the edge yet");
        let_go(true);
        wait until to_left = '0';
        check(pos = 7, "pending hit should reverse the ball only at LD7");

        ------------------------------------------------------------
        report "T6 speed-up with SW0";
        sw_speed <= '1';
        hit_at(false, 0);
        check(step_ms = 16 and t_rel = -7 * 16, "speed-up 20 -> 16");
        let_go(false);
        hit_at(true, 0);
        check(step_ms = 12, "speed-up 16 -> 12");
        let_go(true);
        hit_at(false, 0);
        check(step_ms = 8, "speed-up 12 -> 8");
        let_go(false);
        hit_at(true, 0);
        check(step_ms = STEP_MIN, "speed-up clamps at STEP_MS_MIN");
        let_go(true);
        sw_speed <= '0';

        ------------------------------------------------------------
        report "T7 early press loses; score bar blinks at 1 Hz; ball speed resets";
        hit_at(false, -EARLY - 1);
        t0 := now - 1 ns;
        clocks(1);                                       -- lose 是暫存器輸出，計分晚 1 clk
        check(score_l = 1 and score_r = 0, "early press: left should score");
        check(server = '1', "scorer (left) should serve next");
        btn_r <= '0';
        -- 入口 t0；長條在 [0, ~5) 亮、[~5, ~10) 暗…，POINT 在 ~20 ms 結束
        wait for t0 + 3 * MS - now;
        check(led_a = "10000000", "POINT: left bar of 1 should be lit");
        push(true);                                      -- POINT 中按鍵忽略
        wait for t0 + 17 * MS - now;
        check(led_a = "00000000", "POINT: bar should be dark in the 2nd off phase");
        wait for t0 + 22 * MS - now;
        check(led_a = "10000000", "SERVE: ball at LD7");
        wait for t0 + 27 * MS - now;
        check(led_a = "10000000", "SERVE: steady, not blinking");
        check(pos = 7 and score_l = 1, "button pressed in POINT must not serve");

        ------------------------------------------------------------
        report "T8 miss: out of bounds after +HIT_LATE_MS";
        push(true);
        check(step_ms = STEP_INIT, "serve resets ball speed");
        wait until pos = 0;
        t0 := now;
        wait until score_l = 2;
        -- t_rel = HIT_LATE_MS 那個 tick 判出界（第 LATE + 1 個 tick），lose 再晚 1 clk 計分
        check(now - t0 = (LATE + 1) * MS + CLK_PERIOD, "miss should be scored at the tick where t_rel = HIT_LATE_MS");
        t0 := now;
        clocks(2);
        check(led_a = "11000000", "POINT: left bar of 2");

        ------------------------------------------------------------
        report "T9 the player moving away is ignored; right scores";
        wait for t0 + 25 * MS - now;                  -- POINT 結束，左方發球
        push(true);                                      -- 左發球
        push(true);                                      -- 球遠離左方：忽略
        check(pending = '0' and to_left = '0' and score_r = 0, "non-receiver press must be ignored");
        hit_at(false, 5);
        check(to_left = '1', "right returns the ball");
        let_go(false);
        wait until score_r = 1;                          -- 左方漏接
        t0 := now;
        check(server = '0', "right scored and serves next");
        clocks(2);
        check(led_a = "00000001", "POINT: right bar of 1");

        ------------------------------------------------------------
        report "T10 right serves; holding a button counts once";
        wait for t0 + 25 * MS - now;
        check(pos = 0 and led_a = "00000001", "SERVE: ball at LD0 for the right server");
        saved := t_rel;
        push(true);
        check(t_rel = saved, "BTNL must not serve when right is the server");
        push(false);                                     -- 右發球，球往左
        hit_at(true, -30);                               -- 判定窗外按下並一直按住
        clocks(1);
        check(score_r = 2, "early press while holding: right scores");
        wait for 60 * MS;                                -- 一直按住
        check(score_r = 2 and score_l = 2, "holding must not trigger again");
        check(pos = 0, "right still waiting to serve");
        let_go(true);

        ------------------------------------------------------------
        report "T11 win and game over";
        push(false);                                     -- 右發球，左方漏接…
        wait until score_r = 3;
        wait for 30 * MS;                                -- POINT 結束 → OVER
        t0 := now;
        check(led_a = "00000111" or led_a = "00000000", "OVER: winner's bar");
        wait until led_a = "00000111";
        wait until led_a = "00000000";
        t1 := now;
        wait until led_a = "00000111";
        check(now - t1 = HALF * MS, "OVER: bar blinks with half period BLINK_HALF_MS");

        ------------------------------------------------------------
        report "T12 restart: any button, winner serves";
        push(true);                                      -- 輸家按也可以重新開局
        check(score_l = 0 and score_r = 0, "restart: score 0:0");
        check(server = '0' and pos = 0, "restart: last winner (right) serves");
        clocks(2);
        check(led_a = "00000001", "restart: ball at LD0");

        ------------------------------------------------------------
        report "T13 debounce: glitch shorter than DEBOUNCE_MS";
        saved := t_rel;
        btn_r <= '1';
        wait for 1 * MS;
        btn_r <= '0';
        wait for 5 * MS;
        check(t_rel = saved and pos = 0, "a 1 ms glitch must not serve");

        ------------------------------------------------------------
        report "T14 reset during play";
        push(false);
        wait for 30 * MS;
        reset <= '1';
        clocks(3);
        reset <= '0';
        clocks(2);
        check(led_a = "10000000" and server = '1' and score_l = 0 and score_r = 0,
              "reset during play restores the start state");

        ------------------------------------------------------------
        clocks(2);
        check(pol_errors = 0, "polarity: active-low DUT differs in " & integer'image(pol_errors) & " cycles");
        if errors = 0 then
            report "HW_4_tb PASS";
        else
            report "HW_4_tb FAIL: " & integer'image(errors) & " error(s)" severity failure;
        end if;
        done <= true;
        wait;
    end process;

end sim;
