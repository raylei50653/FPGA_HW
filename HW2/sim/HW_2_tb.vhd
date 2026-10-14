library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

-- HW2 8 顆 LED 呼吸燈自我檢查測試檔（對應 SPEC.md 第 9 節）
-- 以 LED 每個 PWM 週期的高電位 clk 數還原 duty；設定暫存器以 VHDL-2008 external name 讀取，
-- 因此本檔需以 VHDL 2008 編譯。結束時印出 PASS / FAIL；Vivado 模擬直接 run all 即可。
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
    constant LEDS       : natural := 8;
    constant D          : natural := CYC / LEDS; -- 流水相鄰兩顆的延遲（PWM 週期）
    constant HSIZE      : natural := 512;       -- 週期歷史深度，需大於 (LEDS-1) × D
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

    -- 與設計相同的 gamma 2.2 曲線
    function gamma_tb(x : natural) return natural is
    begin
        if x = 0 then
            return 0;
        end if;
        return integer(round(real(R) * ((real(x) / real(R)) ** 2.2)));
    end function;

    -- 最亮時的高電位 clk 數：gamma(R) = R
    constant PEAK : natural := PWM_DIV * R;

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
    signal bm, bh, bb : std_logic := '0';
    signal led1       : std_logic_vector(LEDS - 1 downto 0);

    -- DUT2：LED 與按鈕皆低電位有效，按鈕輸入取反
    signal bm_n, bh_n, bb_n : std_logic;
    signal led2             : std_logic_vector(LEDS - 1 downto 0);

    -- 週期量測結果：每顆 LED 上一個 PWM 週期的高電位 clk 數，以及最近 HSIZE 個週期的歷史
    type duty_arr_t is array (0 to LEDS - 1) of natural;
    type hist_t     is array (0 to HSIZE - 1) of duty_arr_t;
    signal cur      : duty_arr_t := (others => 0);
    signal hist     : hist_t := (others => (others => 0));
    signal dr       : natural := 0;         -- = cur(0)
    signal pcount   : natural := 0;         -- 每量完一個週期 +1，第 n 個週期存在 hist(n mod HSIZE)
    signal last_run : natural := 0;         -- 上一段 dr = PEAK 連續的週期數
    signal run_evt  : std_logic := '0';

    signal err_mon, err_pol : natural := 0;

begin

    clk <= not clk after T / 2 when done = '0' else '0';

    bm_n <= not bm;
    bh_n <= not bh;
    bb_n <= not bb;

    dut : entity work.HW_2
        generic map (
            CLK_FREQ_HZ         => 10_000,
            PWM_BITS            => PWM_BITS,
            PWM_DIV             => PWM_DIV,
            CYCLE_PERIODS       => CYC,
            HOLD_BOTTOM_PERIODS => HB,
            DEBOUNCE_MS         => 3,
            LONG_PRESS_MS       => 20
        )
        port map (
            clk => clk, reset => reset,
            btn_mode => bm, btn_hold => bh, btn_breath => bb,
            led => led1
        );

    dut_n : entity work.HW_2
        generic map (
            CLK_FREQ_HZ         => 10_000,
            PWM_BITS            => PWM_BITS,
            PWM_DIV             => PWM_DIV,
            CYCLE_PERIODS       => CYC,
            HOLD_BOTTOM_PERIODS => HB,
            DEBOUNCE_MS         => 3,
            LONG_PRESS_MS       => 20,
            LED_ACTIVE_LOW      => true,
            BTN_ACTIVE_LOW      => true
        )
        port map (
            clk => clk, reset => reset,
            btn_mode => bm_n, btn_hold => bh_n, btn_breath => bb_n,
            led => led2
        );


    --------------------------------------------------
    -- PWM 週期量測：reset 放開後以第一個 LED 上升緣對齊週期起點，
    -- 每 P 個 clk 為一個週期，檢查每顆 LED 週期內只有一段高電位；
    -- reset 時清空歷史並重新對齊
    --------------------------------------------------
    mon : process
        variable h       : duty_arr_t;
        variable prev    : std_logic_vector(LEDS - 1 downto 0);
        variable errs    : natural := 0;
        variable aborted : boolean;
    begin
        loop
            hist <= (others => (others => 0));
            cur  <= (others => 0);
            dr   <= 0;

            wait until reset = '0';
            wait until rising_edge(clk) and (led1 /= (led1'range => '0') or reset = '1');

            if reset = '0' then
                loop
                    h       := (others => 0);
                    prev    := (others => '1');
                    aborted := false;

                    for s in 0 to P - 1 loop
                        if s > 0 then
                            wait until rising_edge(clk);
                        end if;
                        if reset = '1' then
                            aborted := true;
                            exit;
                        end if;

                        -- 週期中間出現 0 -> 1 即為毛刺或週期錯位
                        if (led1 and not prev) /= (led1'range => '0') then
                            report "PWM glitch: rising edge inside a period" severity error;
                            errs := errs + 1;
                        end if;
                        for k in 0 to LEDS - 1 loop
                            if led1(k) = '1' then h(k) := h(k) + 1; end if;
                        end loop;
                        prev := led1;
                    end loop;

                    exit when aborted;

                    for k in 0 to LEDS - 1 loop
                        if h(k) mod PWM_DIV /= 0 or h(k) > P - PWM_DIV then
                            report "PWM LD" & integer'image(k) & ": bad high time " &
                                   integer'image(h(k)) severity error;
                            errs := errs + 1;
                        end if;
                    end loop;

                    cur                  <= h;
                    dr                   <= h(0);
                    hist(pcount mod HSIZE) <= h;
                    pcount               <= pcount + 1;
                    err_mon              <= errs;

                    wait until rising_edge(clk);
                end loop;
            end if;
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
    -- 極性：DUT2 的 LED 必須恆為 DUT1 的反相，設定相同
    --------------------------------------------------
    pol : process
        alias mode1 is << signal .HW_2_tb.dut.mode        : unsigned(1 downto 0) >>;
        alias hold1 is << signal .HW_2_tb.dut.hold_sel    : unsigned(1 downto 0) >>;
        alias brth1 is << signal .HW_2_tb.dut.breath_en   : std_logic >>;
        alias mode2 is << signal .HW_2_tb.dut_n.mode      : unsigned(1 downto 0) >>;
        alias hold2 is << signal .HW_2_tb.dut_n.hold_sel  : unsigned(1 downto 0) >>;
        alias brth2 is << signal .HW_2_tb.dut_n.breath_en : std_logic >>;
    begin
        wait until rising_edge(clk);
        if reset = '0' then
            if led2 /= not led1 or mode2 /= mode1 or hold2 /= hold1 or brth2 /= brth1 then
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
        alias mode      is << signal .HW_2_tb.dut.mode      : unsigned(1 downto 0) >>;
        alias hold_sel  is << signal .HW_2_tb.dut.hold_sel  : unsigned(1 downto 0) >>;
        alias breath_en is << signal .HW_2_tb.dut.breath_en : std_logic >>;

        variable errors : natural := 0;
        variable prev_r : natural;
        variable n      : natural;
        variable spread : boolean;

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

        -- 設定：breath_en(4)、hold_sel(3:2)、mode(1:0)，與舊版 status 排列相同
        procedure expect_status(exp : std_logic_vector(4 downto 0); msg : string) is
            variable st : std_logic_vector(4 downto 0);
        begin
            st := breath_en & std_logic_vector(hold_sel) & std_logic_vector(mode);
            check(st = exp, msg & ": settings=" & to_str(st) & " expected " & to_str(exp));
        end procedure;

        -- 歷史中第 (目前 - back) 個週期 LD k 的值；back = 0 為剛量完的週期
        impure function past(back : natural; k : natural) return natural is
        begin
            return hist((pcount - 1 - back) mod HSIZE)(k);
        end function;

        impure function all_same return boolean is
        begin
            for k in 1 to LEDS - 1 loop
                if cur(k) /= cur(0) then
                    return false;
                end if;
            end loop;
            return true;
        end function;

        -- 對齊到下一個呼吸週期起點：一段全暗之後的第一個非 0 週期
        procedure align_rise is
        begin
            while dr /= 0 loop next_period; end loop;
            while dr = 0 loop next_period; end loop;
        end procedure;

        -- 對齊到一段最亮的第一個週期
        procedure align_peak is
        begin
            while dr = PEAK loop next_period; end loop;
            while dr /= PEAK loop next_period; end loop;
        end procedure;

        -- 以 LD0 量一個完整呼吸週期：漸亮依序走過 gamma 曲線的每個值、最亮停留、
        -- 漸暗單調、週期長度；same 時 8 顆必須一致
        -- 先跳過一個週期，確保量到的週期已鎖存新的 hold_sel
        procedure check_cycle(sel : natural; same : boolean; msg : string) is
            variable t0, prev, run, lvl : natural;

            procedure step is
            begin
                next_period;
                if same then
                    check(all_same, msg & ": LEDs not in sync");
                end if;
            end procedure;
        begin
            align_rise;
            align_rise;
            t0   := pcount;
            prev := dr;

            -- 漸亮：每次變化都要是 gamma 曲線上的下一個不同值
            lvl := 1;
            while gamma_tb(lvl) = 0 loop lvl := lvl + 1; end loop;
            check(dr = PWM_DIV * gamma_tb(lvl), msg & ": first step " & integer'image(dr) &
                  ", expected gamma " & integer'image(PWM_DIV * gamma_tb(lvl)));

            while dr /= PEAK loop
                step;
                if dr /= prev then
                    while lvl < R and gamma_tb(lvl + 1) = gamma_tb(lvl) loop lvl := lvl + 1; end loop;
                    if lvl < R then lvl := lvl + 1; end if;
                    check(dr = PWM_DIV * gamma_tb(lvl), msg & ": rising step " & integer'image(dr) &
                          ", expected gamma " & integer'image(PWM_DIV * gamma_tb(lvl)));
                end if;
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

        -- 流水：連續 n_per 個週期，每顆 LED 等於領頭那顆 k 格延遲前的值
        --   rev = false：LD0 領頭，LD k 延遲 k × D；rev = true：LD7 領頭，LD k 延遲 (7 - k) × D
        procedure check_flow(rev : boolean; n_per : natural; msg : string) is
            variable lead, lag : natural;
        begin
            spread := false;
            for i in 1 to n_per loop
                next_period;
                for k in 0 to LEDS - 1 loop
                    if rev then
                        lead := LEDS - 1;
                        lag  := (LEDS - 1 - k) * D;
                    else
                        lead := 0;
                        lag  := k * D;
                    end if;
                    check(cur(k) = past(lag, lead), msg & ": LD" & integer'image(k) & " = " &
                          integer'image(cur(k)) & ", expected " & integer'image(past(lag, lead)));
                end loop;
                if cur(0) = 0 and cur(LEDS / 2) = PEAK then
                    spread := true;
                end if;
            end loop;
            check(spread, msg & ": never saw LD0 dark while LD4 at full brightness");
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
                check(dr = PEAK and all_same, msg & ": not steady at peak while breath off");
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

    begin

        ------------------------------------------------ 1. Reset
        wait_clk(20);
        check(led1 = x"00", "reset: LEDs not off");
        expect_status("10000", "reset");
        reset <= '0';

        ------------------------------------------------ 2. 基礎模式：8 顆同步呼吸（hold 00）
        report "TEST mode 00 breath cycle (hold 00)";
        check_cycle(0, true, "hold 00");
        check_cycle(0, true, "hold 00 again");

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
        check_cycle(1, true, "hold 01 (25%)");
        press(bh, SHORT_CLK); expect_status("11000", "hold 10");
        check_cycle(2, true, "hold 10 (50%)");

        -- 最亮停留中切換，本週期不受影響，下一週期才生效
        align_peak;
        press(bh, SHORT_CLK); expect_status("11100", "hold 11 during peak");
        wait on run_evt;
        check(last_run = peak_run(2), "hold change during peak altered current cycle: " &
              integer'image(last_run));
        check_cycle(3, true, "hold 11 (75%)");

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

        ------------------------------------------------ 6. 流水 LD0 -> LD7
        report "TEST mode 01 flow LD0 -> LD7";
        press(bm, SHORT_CLK); expect_status("10001", "mode 01");
        wait_clk(2 * P);                                -- 新 mode 生效後的完整週期才開始比對
        check_flow(false, 2 * CYC, "mode 01");
        check_cycle(0, false, "mode 01 LD0 breath cycle");

        ------------------------------------------------ 7. 流水 LD7 -> LD0
        report "TEST mode 10 flow LD7 -> LD0";
        press(bm, SHORT_CLK); expect_status("10010", "mode 10");
        for i in 1 to CYC loop next_period; end loop;   -- 等 LD7 的歷史都是領頭值
        check_flow(true, 2 * CYC, "mode 10");

        ------------------------------------------------ 8. 流水中關閉呼吸：8 顆依序升到最亮後恆亮
        report "TEST breath off while flowing";
        press(bb, SHORT_CLK); expect_status("00010", "breath off in mode 10");
        for i in 1 to 2 * CYC loop next_period; end loop;
        for i in 1 to CYC loop
            next_period;
            check(dr = PEAK and all_same, "mode 10 breath off: not all LEDs steady at peak");
        end loop;
        press(bb, LONG_CLK);  expect_status("10010", "breath back on");
        n := 0;
        while all_same and n < 2 * CYC loop
            next_period;
            n := n + 1;
        end loop;
        check(not all_same, "mode 10: flow did not resume after breath on");

        ------------------------------------------------ 9. 回到基礎模式
        report "TEST mode 10 -> 00";
        press(bm, SHORT_CLK); expect_status("10000", "mode 00");
        check_cycle(0, true, "back to mode 00");

        ------------------------------------------------ 10. reset 後立即流水：延遲線不得吐出 reset 前的舊資料
        report "TEST flow right after reset";
        press(bm, SHORT_CLK); expect_status("10001", "mode 01 before reset");
        for i in 1 to CYC / 2 loop next_period; end loop;
        reset <= '1';
        wait_clk(3);
        check(led1 = x"00", "reset: LEDs not off");
        expect_status("10000", "reset restores mode");
        reset <= '0';
        press(bm, SHORT_CLK); expect_status("10001", "mode 01 after reset");
        wait_clk(2 * P);                                -- 新 mode 生效後的完整週期才開始比對
        check_flow(false, 2 * CYC, "mode 01 after reset");

        ------------------------------------------------ 11. Reset 還原設定
        report "TEST reset restores settings";
        press(bh, SHORT_CLK);
        press(bb, SHORT_CLK); expect_status("00101", "settings changed");
        reset <= '1';
        wait_clk(3);
        check(led1 = x"00", "reset: LEDs not off");
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
