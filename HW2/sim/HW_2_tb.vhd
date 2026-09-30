library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

-- HW2 呼吸燈自我檢查測試檔（對應 SPEC.md 第 9 節）
-- 只觀察 port：以 LED 每個 PWM 週期的高電位 clk 數還原 duty。
-- 結束時印出 PASS / FAIL；Vivado 模擬直接 run all 即可。
entity HW_2_tb is
end HW_2_tb;

architecture Behavioral of HW_2_tb is

    -- 縮短時間的參數：1 ms = 10 clk，PWM 週期 = 32 clk，呼吸週期 = 192 個 PWM 週期
    constant T          : time    := 10 ns;
    constant PWM_BITS   : natural := 4;
    constant PWM_DIV    : natural := 2;
    constant CYC        : natural := 192;       -- CYCLE_PERIODS
    constant HB         : natural := 16;        -- HOLD_BOTTOM_PERIODS
    constant R          : natural := 2**PWM_BITS - 1;
    constant P          : natural := PWM_DIV * 2**PWM_BITS;
    constant SHORT_CLK  : natural := 100;       -- 10 ms：大於去彈跳、小於長按
    constant LONG_CLK   : natural := 400;       -- 40 ms：大於長按門檻 20 ms

    -- 與設計相同的時間分配（最亮 0% / 25% / 50% / 75%）
    type nat4_t is array (0 to 3) of natural;
    constant TOP_NOM  : nat4_t := (0, (CYC * 25) / 100, (CYC * 50) / 100, (CYC * 75) / 100);
    constant RAMP_LEN : nat4_t := ((CYC - HB - TOP_NOM(0)) / 2, (CYC - HB - TOP_NOM(1)) / 2,
                                   (CYC - HB - TOP_NOM(2)) / 2, (CYC - HB - TOP_NOM(3)) / 2);
    constant TOP_LEN  : nat4_t := (CYC - HB - 2 * RAMP_LEN(0), CYC - HB - 2 * RAMP_LEN(1),
                                   CYC - HB - 2 * RAMP_LEN(2), CYC - HB - 2 * RAMP_LEN(3));

    -- level = R 可見的週期數：最亮停留 + 漸暗第一步前的 ceil(RAMP_LEN / R) 個週期
    function peak_run(sel : natural) return natural is
    begin
        return TOP_LEN(sel) + (RAMP_LEN(sel) + R - 1) / R;
    end function;

    -- 預期最亮時的高電位 clk 數：gamma((255 × R) >> 8) × PWM_DIV
    function gamma_tb(x : natural) return natural is
    begin
        if x = 0 then
            return 0;
        end if;
        return integer(round(real(R) * ((real(x) / real(R)) ** 2.2)));
    end function;

    constant PEAK : natural := PWM_DIV * gamma_tb((255 * R) / 256);

    function to_str(v : std_logic_vector) return string is
        variable s : string(1 to v'length);
        variable k : natural := 1;
    begin
        for i in v'range loop
            if v(i) = '1' then s(k) := '1'; else s(k) := '0'; end if;
            k := k + 1;
        end loop;
        return s;
    end function;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';
    signal done  : std_logic := '0';

    -- DUT1：高電位有效
    signal bm, bh, bb    : std_logic := '0';
    signal lr, lg, lb    : std_logic;
    signal st            : std_logic_vector(4 downto 0);

    -- DUT2：LED 與按鈕皆低電位有效，按鈕輸入取反
    signal bm_n, bh_n, bb_n : std_logic;
    signal lr2, lg2, lb2    : std_logic;
    signal st2              : std_logic_vector(4 downto 0);

    -- 週期量測結果
    signal dr, dg, db : natural := 0;       -- 上一個 PWM 週期的高電位 clk 數
    signal pcount     : natural := 0;       -- 每量完一個週期 +1
    signal last_run   : natural := 0;       -- 上一段 dr = PEAK 連續的週期數
    signal run_evt    : std_logic := '0';

    signal err_mon, err_pol : natural := 0;

begin

    clk <= not clk after T / 2 when done = '0' else '0';

    bm_n <= not bm;
    bh_n <= not bh;
    bb_n <= not bb;

    dut : entity work.HW_2
        generic map (
            CLK_FREQ_HZ       => 10_000,
            PWM_BITS          => PWM_BITS,
            PWM_DIV           => PWM_DIV,
            CYCLE_PERIODS     => CYC,
            HOLD_BOTTOM_PERIODS => HB,
            HUE_PERIODS       => 1,
            DEBOUNCE_MS       => 3,
            LONG_PRESS_MS     => 20
        )
        port map (
            clk => clk, reset => reset,
            btn_mode => bm, btn_hold => bh, btn_breath => bb,
            led_r => lr, led_g => lg, led_b => lb, status => st
        );

    dut_n : entity work.HW_2
        generic map (
            CLK_FREQ_HZ       => 10_000,
            PWM_BITS          => PWM_BITS,
            PWM_DIV           => PWM_DIV,
            CYCLE_PERIODS     => CYC,
            HOLD_BOTTOM_PERIODS => HB,
            HUE_PERIODS       => 1,
            DEBOUNCE_MS       => 3,
            LONG_PRESS_MS     => 20,
            LED_ACTIVE_LOW    => true,
            BTN_ACTIVE_LOW    => true
        )
        port map (
            clk => clk, reset => reset,
            btn_mode => bm_n, btn_hold => bh_n, btn_breath => bb_n,
            led_r => lr2, led_g => lg2, led_b => lb2, status => st2
        );


    --------------------------------------------------
    -- PWM 週期量測：以第一個 led_r 上升緣對齊週期起點，
    -- 每 P 個 clk 為一個週期，檢查週期內只有一段高電位
    --------------------------------------------------
    mon : process
        variable hr, hg, hb_v : natural;
        variable pr, pg, pb   : std_logic;
        variable errs         : natural := 0;

        procedure check_pulse(h : natural; name : string) is
        begin
            if h mod PWM_DIV /= 0 or h > P - PWM_DIV then
                report "PWM " & name & ": bad high time " & integer'image(h) severity error;
                errs := errs + 1;
            end if;
        end procedure;
    begin
        wait until reset = '0';
        wait until rising_edge(clk) and lr = '1';

        loop
            hr := 0; hg := 0; hb_v := 0;
            pr := '1'; pg := '1'; pb := '1';

            for s in 0 to P - 1 loop
                if s > 0 then
                    wait until rising_edge(clk);
                end if;

                -- 週期中間出現 0 -> 1 即為毛刺或週期錯位
                if (lr = '1' and pr = '0') or (lg = '1' and pg = '0') or (lb = '1' and pb = '0') then
                    report "PWM glitch: rising edge inside a period" severity error;
                    errs := errs + 1;
                end if;
                if lr = '1' then hr := hr + 1; end if;
                if lg = '1' then hg := hg + 1; end if;
                if lb = '1' then hb_v := hb_v + 1; end if;
                pr := lr; pg := lg; pb := lb;
            end loop;

            check_pulse(hr, "R");
            check_pulse(hg, "G");
            check_pulse(hb_v, "B");

            dr      <= hr;
            dg      <= hg;
            db      <= hb_v;
            pcount  <= pcount + 1;
            err_mon <= errs;

            wait until rising_edge(clk);
        end loop;
    end process;


    -- 統計 dr 停在 PEAK 的連續週期數
    runmon : process
        variable run : natural := 0;
    begin
        wait on pcount;
        if dr = PEAK then
            run := run + 1;
        elsif run > 0 then
            last_run <= run;
            run_evt  <= not run_evt;
            run      := 0;
        end if;
    end process;


    --------------------------------------------------
    -- 極性：DUT2 的 LED 必須恆為 DUT1 的反相，status 相同
    --------------------------------------------------
    pol : process(clk)
    begin
        if rising_edge(clk) and reset = '0' then
            if lr2 /= not lr or lg2 /= not lg or lb2 /= not lb or st2 /= st then
                report "Polarity mismatch between active-high and active-low DUT" severity error;
                err_pol <= err_pol + 1;
            end if;
        end if;
    end process;


    watchdog : process
    begin
        wait until done = '1' for 20 ms;
        if done = '0' then
            report "TIMEOUT: testbench hung" severity failure;
        end if;
        wait;
    end process;


    --------------------------------------------------
    -- 測試流程
    --------------------------------------------------
    stim : process
        variable errors : natural := 0;
        variable prev_r, prev_g, prev_b : natural;
        variable n, k, mx, mn : natural;
        variable c : std_logic_vector(2 downto 0);
        variable hit : std_logic_vector(5 downto 0);  -- R/G/B 各自到過 0、PEAK

        type color_table_t is array (0 to 6) of std_logic_vector(2 downto 0);
        constant COLOR_SEQ : color_table_t :=       -- (R, G, B)
            ("100", "110", "010", "011", "001", "101", "111");

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                report msg severity error;
                errors := errors + 1;
            end if;
        end procedure;

        procedure wait_clk(n_clk : natural) is
        begin
            for i in 1 to n_clk loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure next_period is
        begin
            wait on pcount;
        end procedure;

        procedure press(signal b : out std_logic; n_clk : natural) is
        begin
            b <= '1';
            wait_clk(n_clk);
            b <= '0';
            wait_clk(100);                  -- 等放開的去彈跳完成
        end procedure;

        procedure expect_status(exp : std_logic_vector(4 downto 0); msg : string) is
        begin
            check(st = exp, msg & ": status=" & to_str(st) & " expected " & to_str(exp));
        end procedure;

        -- 對齊到下一個呼吸週期起點：一段全暗之後的第一個非 0 週期（三色皆看）
        procedure align_rise is
        begin
            while dr /= 0 or dg /= 0 or db /= 0 loop next_period; end loop;
            while dr = 0 and dg = 0 and db = 0 loop next_period; end loop;
        end procedure;

        -- 對齊到一段最亮的第一個週期
        procedure align_peak is
        begin
            while dr = PEAK loop next_period; end loop;
            while dr /= PEAK loop next_period; end loop;
        end procedure;

        -- 量一個完整呼吸週期：單調性、最亮停留、週期長度、白光三色一致
        -- 先跳過一個週期，確保量到的週期已鎖存新的 hold_sel
        procedure check_cycle(sel : natural; msg : string) is
            variable t0, prev, run : natural;

            procedure step is
            begin
                next_period;
                check(dg = dr and db = dr, msg & ": white channels differ");
            end procedure;
        begin
            align_rise;
            align_rise;
            t0   := pcount;
            prev := dr;

            while dr /= PEAK loop
                step;
                check(dr >= prev and dr <= PEAK, msg & ": rising not monotonic");
                prev := dr;
            end loop;

            run := 0;
            while dr = PEAK loop
                run := run + 1;
                step;
            end loop;
            check(run = peak_run(sel), msg & ": peak lasted " & integer'image(run) &
                  " periods, expected " & integer'image(peak_run(sel)));

            prev := dr;
            while dr /= 0 loop
                step;
                check(dr <= prev, msg & ": falling not monotonic");
                prev := dr;
            end loop;

            while dr = 0 loop step; end loop;
            check(pcount - t0 = CYC, msg & ": breath period " &
                  integer'image(pcount - t0) & ", expected " & integer'image(CYC));
        end procedure;

        -- 關閉呼吸：亮度只升不降並停在最亮；長按恢復後應開始變暗
        procedure breath_off_on(msg : string) is
        begin
            press(bb, SHORT_CLK);
            expect_status("01000", msg & " breath off");

            next_period;
            prev_r := dr;
            n := 0;
            while dr /= PEAK and n < 2 * CYC loop
                next_period;
                check(dr >= prev_r, msg & ": brightness dropped after breath off");
                prev_r := dr;
                n := n + 1;
            end loop;

            for i in 1 to 2 * CYC loop
                next_period;
                check(dr = PEAK, msg & ": not steady at peak while breath off");
            end loop;

            press(bb, LONG_CLK);
            expect_status("11000", msg & " breath on (long press)");

            n := 0;
            while dr = PEAK and n < CYC loop
                next_period;
                n := n + 1;
            end loop;
            check(dr < PEAK, msg & ": breathing did not resume");
        end procedure;

        -- 等下一個呼吸週期的最亮點，回傳亮著的色版
        procedure peak_color(col : out std_logic_vector(2 downto 0)) is
        begin
            align_rise;
            while dr /= PEAK and dg /= PEAK and db /= PEAK loop
                next_period;
            end loop;
            check((dr = 0 or dr = PEAK) and (dg = 0 or dg = PEAK) and (db = 0 or db = PEAK),
                  "mode 01: channel neither off nor full at peak");
            col := "000";
            if dr = PEAK then col(2) := '1'; end if;
            if dg = PEAK then col(1) := '1'; end if;
            if db = PEAK then col(0) := '1'; end if;
        end procedure;

    begin

        ------------------------------------------------ 1. Reset
        wait_clk(20);
        check(lr = '0' and lg = '0' and lb = '0', "reset: LEDs not off");
        expect_status("10000", "reset");
        reset <= '0';

        ------------------------------------------------ 2. 預設呼吸（白光、hold 00）
        report "TEST breath cycle (hold 00)";
        check_cycle(0, "hold 00");
        check_cycle(0, "hold 00 again");

        ------------------------------------------------ 3. 按鈕
        report "TEST buttons";

        -- 短於去彈跳的毛刺
        bm <= '1'; wait_clk(2); bm <= '0';
        wait_clk(200);
        expect_status("10000", "glitch ignored");

        -- 按下與放開都帶彈跳，只算一次
        bm <= '1'; wait_clk(3);  bm <= '0'; wait_clk(4);
        bm <= '1'; wait_clk(6);  bm <= '0'; wait_clk(3);
        bm <= '1'; wait_clk(SHORT_CLK);
        bm <= '0'; wait_clk(4);  bm <= '1'; wait_clk(3);
        bm <= '0'; wait_clk(100);
        expect_status("10001", "bouncy press counts once");

        -- mode 01 -> 10 -> 00（跳過 11）
        press(bm, SHORT_CLK); expect_status("10010", "mode 01 -> 10");
        press(bm, SHORT_CLK); expect_status("10000", "mode 10 -> 00");

        -- 長按回預設，放開後不再觸發短按
        press(bm, SHORT_CLK); expect_status("10001", "mode 00 -> 01");
        press(bm, LONG_CLK);  expect_status("10000", "long press restores mode");
        wait_clk(300);        expect_status("10000", "no short press after long press");

        -- hold_sel 00 -> 01 -> 10 -> 11 -> 00
        press(bh, SHORT_CLK); expect_status("10100", "hold 00 -> 01");
        press(bh, SHORT_CLK); expect_status("11000", "hold 01 -> 10");
        press(bh, SHORT_CLK); expect_status("11100", "hold 10 -> 11");
        press(bh, SHORT_CLK); expect_status("10000", "hold 11 -> 00");

        -- 已是預設時長按 breath 維持呼吸
        press(bb, LONG_CLK);  expect_status("10000", "long press breath keeps on");

        -- 同時按兩顆
        bm <= '1'; bh <= '1'; wait_clk(SHORT_CLK);
        bm <= '0'; bh <= '0'; wait_clk(100);
        expect_status("10101", "simultaneous short press");
        bm <= '1'; bh <= '1'; wait_clk(LONG_CLK);
        bm <= '0'; bh <= '0'; wait_clk(100);
        expect_status("10000", "simultaneous long press");

        ------------------------------------------------ 4. 最大亮度佔比
        report "TEST hold ratio";
        -- 四種佔比的呼吸週期都必須等於 CYC
        press(bh, SHORT_CLK); expect_status("10100", "hold 01");
        check_cycle(1, "hold 01 (25%)");
        press(bh, SHORT_CLK); expect_status("11000", "hold 10");
        check_cycle(2, "hold 10 (50%)");

        -- 最亮停留中切換，本週期不受影響，下一週期才生效
        align_peak;
        press(bh, SHORT_CLK); expect_status("11100", "hold 11 during peak");
        wait on run_evt;
        check(last_run = peak_run(2), "hold change during peak altered current cycle: " &
              integer'image(last_run));
        check_cycle(3, "hold 11 (75%)");

        ------------------------------------------------ 5. 呼吸開關（四個狀態）
        report "TEST breath enable";
        press(bh, LONG_CLK);  expect_status("10000", "hold back to 00");
        press(bh, SHORT_CLK);
        press(bh, SHORT_CLK); expect_status("11000", "hold 10 for breath tests");

        align_rise;
        breath_off_on("UP");

        align_peak;
        breath_off_on("HOLD_TOP");

        align_peak;
        while dr = PEAK loop next_period; end loop;
        breath_off_on("DOWN");

        align_peak;
        while dr /= 0 loop next_period; end loop;
        for i in 1 to 8 loop next_period; end loop;     -- 進入 HOLD_BOTTOM
        breath_off_on("HOLD_BOTTOM");

        press(bh, LONG_CLK);  expect_status("10000", "hold back to 00");

        ------------------------------------------------ 6. 單色序列
        report "TEST mode 01 color sequence";
        press(bm, SHORT_CLK); expect_status("10001", "mode 01");

        peak_color(c);
        k := 7;
        for i in 0 to 6 loop
            if COLOR_SEQ(i) = c then k := i; end if;
        end loop;
        check(k = 0 or k = 1, "mode 01: first color should be red or yellow, got " & to_str(c));

        for i in 1 to 8 loop
            peak_color(c);
            k := (k + 1) mod 7;
            check(c = COLOR_SEQ(k), "mode 01: color " & to_str(c) &
                  " expected " & to_str(COLOR_SEQ(k)));
        end loop;

        press(bm, LONG_CLK);  expect_status("10000", "mode back to 00");

        ------------------------------------------------ 7. 色輪（恆亮下觀察）
        report "TEST mode 10 color wheel";
        press(bb, SHORT_CLK); expect_status("00000", "breath off");
        while dr /= PEAK loop next_period; end loop;
        press(bm, SHORT_CLK);
        press(bm, SHORT_CLK); expect_status("00010", "mode 10");
        for i in 1 to 3 loop next_period; end loop;

        prev_r := dr; prev_g := dg; prev_b := db;
        hit := "000000";
        for i in 1 to 1536 + 64 loop                   -- 超過一圈
            next_period;

            mx := dr; mn := dr;
            if dg > mx then mx := dg; end if;
            if db > mx then mx := db; end if;
            if dg < mn then mn := dg; end if;
            if db < mn then mn := db; end if;
            check(mx = PEAK and mn = 0, "mode 10: expected one channel full and one off");

            check(abs(dr - prev_r) <= 2 * PWM_DIV and
                  abs(dg - prev_g) <= 2 * PWM_DIV and
                  abs(db - prev_b) <= 2 * PWM_DIV, "mode 10: color jumped");
            prev_r := dr; prev_g := dg; prev_b := db;

            if dr = 0 then hit(5) := '1'; end if;
            if dr = PEAK then hit(4) := '1'; end if;
            if dg = 0 then hit(3) := '1'; end if;
            if dg = PEAK then hit(2) := '1'; end if;
            if db = 0 then hit(1) := '1'; end if;
            if db = PEAK then hit(0) := '1'; end if;
        end loop;
        check(hit = "111111", "mode 10: wheel did not sweep all channels");

        press(bm, LONG_CLK);  expect_status("00000", "mode back to 00");
        press(bb, LONG_CLK);  expect_status("10000", "breath back on");

        ------------------------------------------------ 8. Reset 還原設定
        report "TEST reset restores settings";
        press(bm, SHORT_CLK);
        press(bh, SHORT_CLK);
        press(bb, SHORT_CLK); expect_status("00101", "settings changed");
        reset <= '1';
        wait_clk(3);
        check(lr = '0' and lg = '0' and lb = '0', "reset: LEDs not off");
        expect_status("10000", "reset restores defaults");

        ------------------------------------------------ 結果
        wait_clk(1);
        errors := errors + err_mon + err_pol;
        if errors = 0 then
            report "HW_2_tb PASS";
        else
            report "HW_2_tb FAIL: " & integer'image(errors) & " error(s)" severity error;
        end if;
        done <= '1';
        wait;
    end process;

end Behavioral;
