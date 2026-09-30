library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW1 雙計數器改為 PWM（由 HW_2_a 實例化，規格見 HW2_a/SPEC.md §5）
--   count1 數滿 upbnd1 個 clk（亮）→ count2 數滿 upbnd2 個 clk（暗）→ 重複
--   upbnd1 / upbnd2 在每個 PWM 週期開頭鎖存，週期內亮暗長度不變
entity HW_1_pwm is
    Generic (
        MAX : positive := 30        -- upbnd1 + upbnd2，即 PWM 週期的 clk 數
    );
    Port (
        clk     : in  STD_LOGIC;
        reset   : in  STD_LOGIC;
        upbnd1  : in  integer range 0 to MAX;   -- 亮的 clk 數
        upbnd2  : in  integer range 0 to MAX;   -- 暗的 clk 數
        led_on  : out STD_LOGIC;                -- 目前在數 count1（亮）
        pwm_end : out STD_LOGIC                 -- PWM 週期最後一拍
    );
end HW_1_pwm;

architecture Behavioral of HW_1_pwm is

    -- 狀態宣告
    type state_type is (COUNT1_STATE, COUNT2_STATE);

    signal state      : state_type := COUNT2_STATE;
    signal next_state : state_type;

    -- 本週期使用的上限（影子暫存器）
    signal b1 : integer range 0 to MAX := 0;
    signal b2 : integer range 0 to MAX := MAX;

    -- 計數器
    signal c1 : integer range 0 to MAX - 1 := 0;
    signal c2 : integer range 0 to MAX - 1 := 0;

    signal c1_end, c2_end, period_end : std_logic;

begin

    c1_end <= '1' when state = COUNT1_STATE and c1 + 1 >= b1 else '0';
    c2_end <= '1' when state = COUNT2_STATE and c2 + 1 >= b2 else '0';

    -- 暗的一段數完，或沒有暗的一段（b2 = 0）時亮的一段數完
    period_end <= '1' when c2_end = '1' or (c1_end = '1' and b2 = 0) else '0';

    --------------------------------------------------
    -- 1. 影子暫存器：週期結束時鎖存下一週期的上限
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                b1 <= 0;
                b2 <= MAX;
            elsif period_end = '1' then
                b1 <= upbnd1;
                b2 <= upbnd2;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 2. 狀態暫存器
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= COUNT2_STATE;
            else
                state <= next_state;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 3. 下一狀態邏輯
    --    週期結束時依即將鎖存的 upbnd1 決定下一週期從亮或暗開始，
    --    上限為 0 的那一段直接跳過
    --------------------------------------------------
    process(state, c1_end, period_end, upbnd1)
    begin

        -- 預設保持目前狀態
        next_state <= state;

        if period_end = '1' then
            if upbnd1 /= 0 then
                next_state <= COUNT1_STATE;
            else
                next_state <= COUNT2_STATE;
            end if;
        elsif c1_end = '1' then
            next_state <= COUNT2_STATE;
        end if;

    end process;


    --------------------------------------------------
    -- 4. Count1（亮）
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                c1 <= 0;

            elsif state = COUNT1_STATE then

                if c1_end = '1' then
                    c1 <= 0;
                else
                    c1 <= c1 + 1;
                end if;

            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 5. Count2（暗）
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                c2 <= 0;

            elsif state = COUNT2_STATE then

                if c2_end = '1' then
                    c2 <= 0;
                else
                    c2 <= c2 + 1;
                end if;

            end if;

        end if;
    end process;


    --------------------------------------------------
    -- Output
    --------------------------------------------------
    led_on  <= '1' when state = COUNT1_STATE else '0';
    pwm_end <= period_end;

end Behavioral;
