library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW5 視訊時序產生器（沿用 HW3/src/HW_3_timing.vhd，規格見 HW3/SPEC.md §4）
--   每個 ce 前進一個像素；輸出全部經暫存器，x / y / de / hs / vs 彼此對齊
--   hs、vs 為高電位有效，極性在輸出級才調整，HDMI 編碼器可直接接這組訊號
--
--   一行（一幀同理，單位換成行）由四段組成：
--     |<-- H_ACTIVE 可視 -->|<- H_FP 前廊 ->|<- H_SYNC 同步 ->|<- H_BP 後廊 ->|
--     de = 1                 de = 0          hs = 1             de = 0
--   計數器從 0 數到 H_TOTAL - 1；x / y 就是計數值，所以遮沒期間 x >= H_ACTIVE 或 y >= V_ACTIVE
entity HW_5_timing is
    Generic (
        H_ACTIVE : positive := 640;
        H_FP     : positive := 16;
        H_SYNC   : positive := 96;
        H_BP     : positive := 48;
        V_ACTIVE : positive := 480;
        V_FP     : positive := 10;
        V_SYNC   : positive := 2;
        V_BP     : positive := 33
    );
    Port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        ce          : in  STD_LOGIC;
        x           : out unsigned(11 downto 0);
        y           : out unsigned(11 downto 0);
        de          : out STD_LOGIC;
        hs          : out STD_LOGIC;
        vs          : out STD_LOGIC;
        frame_start : out STD_LOGIC     -- 進入垂直遮沒的第一個像素（y = V_ACTIVE、x = 0）
    );
end HW_5_timing;

architecture Behavioral of HW_5_timing is

    constant H_TOTAL : positive := H_ACTIVE + H_FP + H_SYNC + H_BP;
    constant V_TOTAL : positive := V_ACTIVE + V_FP + V_SYNC + V_BP;

    -- 同步脈衝的範圍：[START, END)
    constant H_SYNC_START : natural := H_ACTIVE + H_FP;
    constant H_SYNC_END   : natural := H_ACTIVE + H_FP + H_SYNC;
    constant V_SYNC_START : natural := V_ACTIVE + V_FP;
    constant V_SYNC_END   : natural := V_ACTIVE + V_FP + V_SYNC;

    signal h_cnt : integer range 0 to H_TOTAL - 1 := 0;
    signal v_cnt : integer range 0 to V_TOTAL - 1 := 0;

begin

    assert H_TOTAL <= 4096 and V_TOTAL <= 4096
        report "Video timing exceeds the 12-bit x / y counters"
        severity failure;

    --------------------------------------------------
    -- 1. 水平 / 垂直計數器
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                h_cnt <= 0;
                v_cnt <= 0;
            elsif ce = '1' then
                if h_cnt = H_TOTAL - 1 then
                    h_cnt <= 0;
                    if v_cnt = V_TOTAL - 1 then
                        v_cnt <= 0;
                    else
                        v_cnt <= v_cnt + 1;
                    end if;
                else
                    h_cnt <= h_cnt + 1;
                end if;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 2. 輸出暫存器：同一組計數值解出所有訊號，因此彼此對齊
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                x           <= (others => '0');
                y           <= (others => '0');
                de          <= '0';
                hs          <= '0';
                vs          <= '0';
                frame_start <= '0';
            elsif ce = '1' then
                x <= to_unsigned(h_cnt, 12);
                y <= to_unsigned(v_cnt, 12);

                if h_cnt < H_ACTIVE and v_cnt < V_ACTIVE then
                    de <= '1';
                else
                    de <= '0';
                end if;

                if h_cnt >= H_SYNC_START and h_cnt < H_SYNC_END then
                    hs <= '1';
                else
                    hs <= '0';
                end if;

                if v_cnt >= V_SYNC_START and v_cnt < V_SYNC_END then
                    vs <= '1';
                else
                    vs <= '0';
                end if;

                -- 最後一條可視行畫完的下一個像素：整個垂直遮沒都可以拿來準備下一幀
                if h_cnt = 0 and v_cnt = V_ACTIVE then
                    frame_start <= '1';
                else
                    frame_start <= '0';
                end if;
            end if;
        end if;
    end process;

end Behavioral;
