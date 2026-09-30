library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW2_a 呼吸燈（規格見 HW2_a/SPEC.md）
--   FSM1 決定變亮／變暗，調整 upbnd1（亮）與 upbnd2（暗），兩者和固定為 MAX；
--   HW1 雙計數器以 upbnd1 / upbnd2 為上限交替計數，數 count1 時 LED 亮
entity HW_2_a is
    Generic (
        CLK_FREQ_HZ    : positive := 100_000_000; -- 系統時脈
        MAX            : positive := 30;          -- 亮度階數 = PWM 週期的 clk 數
        STEP_HZ        : positive := 30;          -- 每 1/STEP_HZ 秒亮度走一階
        LED_ACTIVE_LOW : boolean  := false
    );
    Port (
        clk   : in  STD_LOGIC;
        reset : in  STD_LOGIC;
        led   : out STD_LOGIC
    );
end HW_2_a;

architecture Behavioral of HW_2_a is

    -- 每一階撐多少個 PWM 週期（1/STEP_HZ 秒）
    constant STEP_PERIODS : natural := CLK_FREQ_HZ / (STEP_HZ * MAX);

    -- FSM1：變暗ing / 變亮ing
    type fsm1_type is (DIMMING, BRIGHTENING);
    signal fsm1_state      : fsm1_type := DIMMING;
    signal fsm1_next_state : fsm1_type;

    -- 上限：upbnd1 + upbnd2 = MAX
    signal upbnd1     : integer range 0 to MAX := 0;
    signal upbnd2     : integer range 0 to MAX := MAX;
    signal upbnd1_nxt : integer range 0 to MAX;
    signal upbnd2_nxt : integer range 0 to MAX;

    -- HW1：數 count1 時亮、數 count2 時暗
    type hw1_type is (COUNT1_STATE, COUNT2_STATE);
    signal hw1_state      : hw1_type := COUNT2_STATE;
    signal hw1_next_state : hw1_type;
    signal c1 : integer range 0 to MAX - 1 := 0;
    signal c2 : integer range 0 to MAX - 1 := 0;
    signal c1_end, c2_end : std_logic;

    -- PWM 週期結束點與 1/STEP_HZ 秒節拍
    signal pwm_end  : std_logic;
    signal pwm_cnt  : integer range 0 to STEP_PERIODS - 1 := 0;
    signal step     : std_logic;

begin

    assert STEP_PERIODS >= 1
        report "CLK_FREQ_HZ too small: one step must last at least one PWM period"
        severity failure;

    --------------------------------------------------
    -- 1. FSM1 狀態暫存器
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                fsm1_state <= DIMMING;
            else
                fsm1_state <= fsm1_next_state;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 2. FSM1 下一狀態邏輯
    --------------------------------------------------
    process(fsm1_state, upbnd1, upbnd2)
    begin

        -- 預設保持目前狀態
        fsm1_next_state <= fsm1_state;

        case fsm1_state is

            when DIMMING =>
                if upbnd1 = 0 and upbnd2 = MAX then        -- 已最暗
                    fsm1_next_state <= BRIGHTENING;
                end if;

            when BRIGHTENING =>
                if upbnd1 = MAX and upbnd2 = 0 then        -- 已最亮
                    fsm1_next_state <= DIMMING;
                end if;

        end case;

    end process;


    --------------------------------------------------
    -- 3. upbnd1 / upbnd2（Moore 輸出：每一階依狀態 ++ / --）
    --------------------------------------------------
    process(fsm1_state, step, upbnd1, upbnd2)
    begin
        upbnd1_nxt <= upbnd1;
        upbnd2_nxt <= upbnd2;

        if step = '1' then
            if fsm1_state = BRIGHTENING and upbnd1 < MAX then
                upbnd1_nxt <= upbnd1 + 1;
                upbnd2_nxt <= upbnd2 - 1;
            elsif fsm1_state = DIMMING and upbnd1 > 0 then
                upbnd1_nxt <= upbnd1 - 1;
                upbnd2_nxt <= upbnd2 + 1;
            end if;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                upbnd1 <= 0;
                upbnd2 <= MAX;
            else
                upbnd1 <= upbnd1_nxt;
                upbnd2 <= upbnd2_nxt;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 4. HW1 狀態暫存器
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                hw1_state <= COUNT2_STATE;
            else
                hw1_state <= hw1_next_state;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 5. HW1 下一狀態邏輯
    --    count1 數滿 upbnd1 個 clk、count2 數滿 upbnd2 個 clk 後交替；
    --    PWM 週期結束時依新的 upbnd1 決定下一週期是否從亮開始，
    --    上限為 0 的那一段直接跳過
    --------------------------------------------------
    c1_end <= '1' when hw1_state = COUNT1_STATE and c1 + 1 >= upbnd1 else '0';
    c2_end <= '1' when hw1_state = COUNT2_STATE and c2 + 1 >= upbnd2 else '0';

    pwm_end <= '1' when c2_end = '1' or (c1_end = '1' and upbnd2 = 0) else '0';

    process(hw1_state, c1_end, pwm_end, upbnd1_nxt)
    begin

        -- 預設保持目前狀態
        hw1_next_state <= hw1_state;

        if pwm_end = '1' then
            if upbnd1_nxt /= 0 then
                hw1_next_state <= COUNT1_STATE;
            else
                hw1_next_state <= COUNT2_STATE;
            end if;
        elsif c1_end = '1' then
            hw1_next_state <= COUNT2_STATE;
        end if;

    end process;


    --------------------------------------------------
    -- 6. Count1（亮）
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                c1 <= 0;

            elsif hw1_state = COUNT1_STATE then

                if c1_end = '1' then
                    c1 <= 0;
                else
                    c1 <= c1 + 1;
                end if;

            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 7. Count2（暗）
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                c2 <= 0;

            elsif hw1_state = COUNT2_STATE then

                if c2_end = '1' then
                    c2 <= 0;
                else
                    c2 <= c2 + 1;
                end if;

            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 8. PWM counter：數 PWM 週期，撐滿 1/STEP_HZ 秒送出 step
    --------------------------------------------------
    step <= '1' when pwm_end = '1' and pwm_cnt = STEP_PERIODS - 1 else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pwm_cnt <= 0;
            elsif pwm_end = '1' then
                if pwm_cnt = STEP_PERIODS - 1 then
                    pwm_cnt <= 0;
                else
                    pwm_cnt <= pwm_cnt + 1;
                end if;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- Output：Moore，直接由狀態暫存器產生，不會有毛刺
    --------------------------------------------------
    led <= '1' when (hw1_state = COUNT1_STATE) xor LED_ACTIVE_LOW else '0';

end Behavioral;
