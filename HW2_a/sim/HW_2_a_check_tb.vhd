library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- HW2_a 自我檢查測試檔（看波形用 HW_2_a_tb）：run all 後印出 PASS / FAIL
--   以小參數模擬：MAX = 8、每階 2 個 PWM 週期
--   每 MAX 個 clk 為一個 PWM 週期，逐週期檢查：
--     1. LED 在週期開頭連續亮 h 個 clk，其餘暗（單一脈波、無毛刺）
--     2. h 依三角波 0, 1, ..., MAX, MAX-1, ..., 1, 0, 1, ... 變化，每階撐 STEP_PERIODS 個週期
--        （HW1 在週期開頭鎖存上限，整體延後一個 PWM 週期）
--     3. LED_ACTIVE_LOW 版本輸出恰為反相
--   最後中途 reset，確認 LED 熄滅並從最暗重新開始
entity HW_2_a_check_tb is
end HW_2_a_check_tb;

architecture sim of HW_2_a_check_tb is

    constant T            : time     := 10 ns;
    constant MAX          : positive := 8;
    constant STEP_HZ      : positive := 30;
    constant STEP_PERIODS : positive := 2;
    constant CLK_FREQ_HZ  : positive := STEP_HZ * MAX * STEP_PERIODS;   -- 480
    constant BREATHS      : positive := 2;                              -- 檢查兩次完整呼吸

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';
    signal led   : std_logic;
    signal led_n : std_logic;
    signal done  : boolean := false;

    -- 第 n 階的預期亮度（三角波，週期 2 × MAX 階）
    function level(n : natural) return natural is
        variable k : natural;
    begin
        k := n mod (2 * MAX);
        if k <= MAX then
            return k;
        else
            return 2 * MAX - k;
        end if;
    end function;

begin

    clk <= not clk after T / 2 when not done;

    dut : entity work.HW_2_a
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            MAX         => MAX,
            STEP_HZ     => STEP_HZ
        )
        port map (clk => clk, reset => reset, led => led);

    dut_n : entity work.HW_2_a
        generic map (
            CLK_FREQ_HZ    => CLK_FREQ_HZ,
            MAX            => MAX,
            STEP_HZ        => STEP_HZ,
            LED_ACTIVE_LOW => true
        )
        port map (clk => clk, reset => reset, led => led_n);

    process
        variable errors : natural := 0;
        variable h      : natural;
        variable fell   : boolean;
        variable exp    : natural;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                errors := errors + 1;
                report msg severity error;
            end if;
        end procedure;

        -- 在 clk 下降緣取樣一個 PWM 週期（MAX 個 clk），回傳亮的 clk 數
        procedure sample_period(p : natural) is
        begin
            h    := 0;
            fell := false;
            for j in 0 to MAX - 1 loop
                check(led_n = not led, "period " & integer'image(p) & ": active-low output not inverted");
                if led = '1' then
                    check(not fell, "period " & integer'image(p) & ": more than one pulse");
                    h := h + 1;
                else
                    fell := true;
                end if;
                wait until falling_edge(clk);
            end loop;
        end procedure;

        procedure run_from_reset(periods : natural; tag : string) is
        begin
            for p in 0 to periods - 1 loop
                sample_period(p);
                -- upbnd 在週期開頭才鎖進 HW1，所以亮度比 step 晚一個 PWM 週期
                if p = 0 then
                    exp := 0;
                else
                    exp := level((p - 1) / STEP_PERIODS);
                end if;
                check(h = exp, tag & " period " & integer'image(p) & ": high " &
                      integer'image(h) & " clk, expected " & integer'image(exp));
            end loop;
        end procedure;

    begin
        -- reset 期間 LED 熄滅
        for i in 1 to 4 loop
            wait until falling_edge(clk);
            check(led = '0' and led_n = '1', "reset: LED not off");
        end loop;

        -- 在下降緣放開 reset：此時的 clk 週期就是第一個 PWM 週期的第一拍
        reset <= '0';
        report "TEST breathing";
        run_from_reset(BREATHS * 2 * MAX * STEP_PERIODS + STEP_PERIODS, "breath");

        -- 中途 reset（此時正在變亮）
        wait until falling_edge(clk);
        reset <= '1';
        for i in 1 to 3 loop
            wait until falling_edge(clk);
            check(led = '0' and led_n = '1', "mid reset: LED not off");
        end loop;
        reset <= '0';
        report "TEST restart after reset";
        run_from_reset(2 * MAX * STEP_PERIODS, "restart");

        if errors = 0 then
            report "HW_2_a_check_tb PASS";
        else
            report "HW_2_a_check_tb FAIL: " & integer'image(errors) & " error(s)" severity error;
        end if;
        done <= true;
        wait;
    end process;

end sim;
