library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW2_a 看波形用測試檔（自我檢查版見 HW_2_a_check_tb）
--   縮小參數：MAX = 8、每階撐 2 個 PWM 週期
--   一個 PWM 週期 = 8 clk = 80 ns，一次呼吸 = 16 階 × 2 × 80 ns = 2.56 us
entity HW_2_a_tb is
end HW_2_a_tb;

architecture Behavioral of HW_2_a_tb is

    -- DUT inputs
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- DUT outputs
    signal led : std_logic;

    constant CLK_PERIOD : time := 10 ns;

    -- 縮小的 generic：CLK_FREQ_HZ = STEP_HZ × MAX × 2，讓每階撐 2 個 PWM 週期
    constant MAX         : positive := 8;
    constant STEP_HZ     : positive := 30;
    constant CLK_FREQ_HZ : positive := STEP_HZ * MAX * 2;

    signal sim_done : boolean := false;

begin

    --------------------------------------------------
    -- DUT
    --------------------------------------------------
    uut : entity work.HW_2_a
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            MAX         => MAX,
            STEP_HZ     => STEP_HZ
        )
        port map (
            clk   => clk,
            reset => reset,
            led   => led
        );


    --------------------------------------------------
    -- Clock（模擬結束後停止，讓 run all 可以結束）
    --------------------------------------------------
    clk_process : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;

            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;


    --------------------------------------------------
    -- Stimulus
    --------------------------------------------------
    stim_process : process
    begin

        -- Reset
        reset <= '1';
        wait for 2 * CLK_PERIOD;

        -- Release reset
        reset <= '0';

        -- 跑約 3 次完整呼吸
        wait for 8 us;

        sim_done <= true;
        wait;
    end process;

end Behavioral;
