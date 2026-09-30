library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW2_a 呼吸燈（規格見 HW2_a/SPEC.md）
--   FSM1 決定變亮／變暗，調整 upbnd1（亮）與 upbnd2（暗），兩者和固定為 MAX；
--   實例化 HW1 雙計數器（HW_1_pwm）以 upbnd1 / upbnd2 為上限交替計數，數 count1 時 LED 亮
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
    signal upbnd1 : integer range 0 to MAX := 0;
    signal upbnd2 : integer range 0 to MAX := MAX;

    -- HW1 輸出
    signal led_on  : std_logic;
    signal pwm_end : std_logic;

    -- PWM counter：1/STEP_HZ 秒節拍
    signal pwm_cnt : integer range 0 to STEP_PERIODS - 1 := 0;
    signal step    : std_logic;

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
    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                upbnd1 <= 0;
                upbnd2 <= MAX;

            elsif step = '1' then

                if fsm1_state = BRIGHTENING and upbnd1 < MAX then
                    upbnd1 <= upbnd1 + 1;
                    upbnd2 <= upbnd2 - 1;
                elsif fsm1_state = DIMMING and upbnd1 > 0 then
                    upbnd1 <= upbnd1 - 1;
                    upbnd2 <= upbnd2 + 1;
                end if;

            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 4. HW1 雙計數器（PWM）
    --------------------------------------------------
    hw1 : entity work.HW_1_pwm
        generic map (
            MAX => MAX
        )
        port map (
            clk     => clk,
            reset   => reset,
            upbnd1  => upbnd1,
            upbnd2  => upbnd2,
            led_on  => led_on,
            pwm_end => pwm_end
        );


    --------------------------------------------------
    -- 5. PWM counter：數 PWM 週期，撐滿 1/STEP_HZ 秒送出 step
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
    -- Output：led_on 直接來自 HW1 的狀態暫存器，不會有毛刺
    --------------------------------------------------
    led <= not led_on when LED_ACTIVE_LOW else led_on;

end Behavioral;
