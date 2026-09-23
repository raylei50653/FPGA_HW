library IEEE; 
use IEEE.STD_LOGIC_1164.ALL; 
use IEEE.NUMERIC_STD.ALL; 
 
entity HW_1 is 
    Port ( 
        clk    : in  STD_LOGIC; 
        reset  : in  STD_LOGIC; 
        count1 : out STD_LOGIC_VECTOR(3 downto 0); 
        count2 : out STD_LOGIC_VECTOR(7 downto 0) 
    ); 
end HW_1; 
 
architecture Behavioral of HW_1 is 
 
    -- 狀態宣告 
    type state_type is (COUNT1_STATE, COUNT2_STATE); 
 
    signal state      : state_type := COUNT1_STATE; 
    signal next_state : state_type; 
 
    -- 計數器 
    signal c1 : unsigned(3 downto 0) := to_unsigned(0, 4); 
    signal c2 : unsigned(7 downto 0) := to_unsigned(253, 8); 
 
begin 
 
    -------------------------------------------------- 
    -- 1. 狀態暫存器 
    -------------------------------------------------- 
    process(clk) 
    begin 
        if rising_edge(clk) then 
            if reset = '1' then 
                state <= COUNT1_STATE; 
            else 
                state <= next_state; 
            end if; 
        end if; 
    end process; 
 
 
    -------------------------------------------------- 
    -- 2. 下一狀態邏輯 
    -------------------------------------------------- 
    process(state, c1, c2) 
    begin 
 
        -- 預設保持目前狀態 
        next_state <= state; 
 
        case state is 
 
            when COUNT1_STATE => 
                if c1 = 9 then 
                    next_state <= COUNT2_STATE; 
                end if; 
 
            when COUNT2_STATE => 
                if c2 = 17 then 
                    next_state <= COUNT1_STATE; 
                end if; 
 
        end case; 
 
    end process; 
 
 
    -------------------------------------------------- 
    -- 3. Count1 
    -------------------------------------------------- 
    process(clk) 
    begin 
        if rising_edge(clk) then 
 
            if reset = '1' then 
                c1 <= to_unsigned(0, 4); 
 
            elsif state = COUNT1_STATE then 
 
                if c1 = 9 then 
                    c1 <= to_unsigned(0, 4); 
                else 
                    c1 <= c1 + 1; 
                end if; 
 
            end if; 
 
        end if; 
    end process; 
 
 
    -------------------------------------------------- 
    -- 4. Count2 
    -------------------------------------------------- 
    process(clk) 
    begin 
        if rising_edge(clk) then 
 
            if reset = '1' then 
                c2 <= to_unsigned(253, 8); 
 
            elsif state = COUNT2_STATE then 
 
                if c2 = 17 then 
                    c2 <= to_unsigned(253, 8); 
                else 
                    c2 <= c2 - 1; 
                end if; 
 
            end if; 
 
        end if; 
    end process; 
 
 
    -------------------------------------------------- 
    -- Output 
    -------------------------------------------------- 
    count1 <= std_logic_vector(c1); 
    count2 <= std_logic_vector(c2); 
 
end Behavioral;