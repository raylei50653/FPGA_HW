library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- HW3 按鈕介面（規格見 HW3/SPEC.md §7）
--   兩級同步 -> 連續 DEBOUNCE_CYCLES 拍穩定才更新 -> 按下瞬間輸出單拍脈衝
entity HW_3_btn is
    Generic (
        DEBOUNCE_CYCLES : positive := 2_000_000;  -- 100 MHz 下 20 ms
        ACTIVE_LOW      : boolean  := false
    );
    Port (
        clk    : in  STD_LOGIC;
        reset  : in  STD_LOGIC;
        btn_in : in  STD_LOGIC;
        press  : out STD_LOGIC
    );
end HW_3_btn;

architecture Behavioral of HW_3_btn is

    signal sync1  : std_logic := '0';
    signal sync2  : std_logic := '0';
    signal stable : std_logic := '0';
    signal db_cnt : integer range 0 to DEBOUNCE_CYCLES - 1 := 0;

begin

    process(clk)
    begin
        if rising_edge(clk) then
            -- 極性調整 + 兩級同步
            if ACTIVE_LOW then
                sync1 <= not btn_in;
            else
                sync1 <= btn_in;
            end if;
            sync2 <= sync1;

            press <= '0';

            if reset = '1' then
                stable <= '0';
                db_cnt <= 0;
            elsif sync2 /= stable then
                if db_cnt = DEBOUNCE_CYCLES - 1 then
                    stable <= sync2;
                    db_cnt <= 0;
                    press  <= sync2;            -- 只在按下時觸發
                else
                    db_cnt <= db_cnt + 1;
                end if;
            else
                db_cnt <= 0;
            end if;
        end if;
    end process;

end Behavioral;
