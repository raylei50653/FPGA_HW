library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity HW_1_tb is
end HW_1_tb;

architecture Behavioral of HW_1_tb is

    -- DUT inputs
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- DUT outputs
    signal count1 : std_logic_vector(3 downto 0);
    signal count2 : std_logic_vector(7 downto 0);

    constant CLK_PERIOD : time := 10 ns;

begin

    --------------------------------------------------
    -- DUT
    --------------------------------------------------
    uut : entity work.HW_1
        port map (
            clk    => clk,
            reset  => reset,
            count1 => count1,
            count2 => count2
        );


    --------------------------------------------------
    -- Clock
    --------------------------------------------------
    clk_process : process
    begin
        while true loop
            clk <= '0';
            wait for CLK_PERIOD / 2;

            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
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

        -- 跑完整幾個循環
        wait for 3000 ns;

        wait;
    end process;

end Behavioral;