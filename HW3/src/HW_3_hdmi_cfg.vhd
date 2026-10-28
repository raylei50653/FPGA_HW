library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW3 ADV7511 設定（規格見 HW3/SPEC.md §6.5）：I2C 主控端，只寫不讀
--   開機等 START_DELAY 個 clk 後，依序寫入暫存器表；寫完再等 START_DELAY 個 clk 重寫一次，一直重複，
--     螢幕晚插上、ADV7511 因 HPD 掉下來而重設時，下一輪就會恢復
--   每筆寫入：START、裝置位址 + W、暫存器位址、資料、STOP，每個 byte 後讀 ACK
--   ok：最近一輪全部寫入都收到 ACK
--   SCL 頻率 = clk / (4 × I2C_DIV)，100 MHz / 1000 = 100 kHz；SCL、SDA 為開汲極（只拉低或放開）
entity HW_3_hdmi_cfg is
    Generic (
        I2C_DIV         : positive := 250;        -- 四分之一個 SCL 週期的 clk 數
        START_DELAY     : positive := 2**24;      -- 每輪之前等待的 clk 數（約 168 ms）
        DEV_ADDR        : std_logic_vector(6 downto 0) := "0111001";   -- 0x39（寫入位元組 0x72）
        H_ACTIVE        : positive := 640;        -- DE 產生器：可視寬高
        V_ACTIVE        : positive := 480;
        H_DE_DELAY      : positive := 144;        -- hsync 前緣到 DE 開始的像素數（同步 + 後廊）
        V_DE_DELAY      : positive := 35;         -- vsync 前緣到第一條可視行的行數（同步 + 後廊）
        SYNC_ACTIVE_LOW : boolean  := true
    );
    Port (
        clk   : in    STD_LOGIC;
        reset : in    STD_LOGIC;
        scl   : out   STD_LOGIC;              -- 只拉低或放開，不讀回（不支援時脈延展）
        sda   : inout STD_LOGIC;
        ok    : out   STD_LOGIC
    );
end HW_3_hdmi_cfg;

architecture Behavioral of HW_3_hdmi_cfg is

    subtype byte_t is std_logic_vector(7 downto 0);
    type reg_t is record
        addr : byte_t;
        data : byte_t;
    end record;
    type reg_arr_t is array (natural range <>) of reg_t;

    function b(v : natural) return byte_t is
    begin
        return std_logic_vector(to_unsigned(v, 8));
    end function;

    -- 暫存器表（ADV7511 Programming Guide；輸入格式與 CSC 照 ZedBoard 的 Linux 設定）
    --   ADV7511 的輸入匯流排有 36 bit，EGO-XZ7 只接了 D23..D0：24 bit RGB 的 R 在 D35..28 收不到，
    --   所以用 16 bit YCbCr 4:2:2（D23..16 = Cb / Cr、D15..8 = Y），再由 CSC 轉回 RGB
    --   CSC 係數取自 Linux adv7511_drv.c 的 adv7511_csc_ycbcr_to_rgb（BT.709、有限範圍、縮放 ×4）：
    --     每個係數 13 bit，0x18 + 2i 放 [12:8]、0x19 + 2i 放 [7:0]；0x18[7] 開啟 CSC、0x18[6:5] = 2 縮放 ×4；
    --     寫係數時先把 0x1A[5] 設 1（更新模式），寫完再清掉
    function reg_table return reg_arr_t is
        variable t   : reg_arr_t(0 to 46);
        variable pol : natural := 0;
    begin
        if SYNC_ACTIVE_LOW then
            pol := 16#60#;                        -- 0x17[6:5]：DE 產生器把 vs、hs 當低電位有效
        end if;
        t := (
            (b(16#D6#), b(16#C0#)),               -- HPD 視為一直有接，不必等熱插拔偵測
            (b(16#41#), b(16#10#)),               -- 開啟電源
            (b(16#98#), b(16#03#)),               -- 以下 8 個是手冊要求的固定值
            (b(16#9A#), b(16#E0#)),
            (b(16#9C#), b(16#30#)),
            (b(16#9D#), b(16#61#)),
            (b(16#A2#), b(16#A4#)),
            (b(16#A3#), b(16#A4#)),
            (b(16#E0#), b(16#D0#)),
            (b(16#F9#), b(16#00#)),
            (b(16#15#), b(16#01#)),               -- 輸入 ID 1：YCbCr 4:2:2、分離同步
            (b(16#16#), b(16#38#)),               -- 輸出 4:4:4、每色 8 bit、輸入樣式 1、輸出 RGB
            (b(16#48#), b(16#08#)),               -- 輸入資料靠右對齊（16 bit 在 D23..8）
            (b(16#17#), b(pol + 1)),              -- 同步極性、4:3、DE 產生器開啟（板子沒有接 DE）
            (b(16#35#), b(H_DE_DELAY / 4)),       -- DE 產生器：hsync 延遲 [9:2]
            (b(16#36#), b((H_DE_DELAY mod 4) * 64 + V_DE_DELAY)),   -- hsync 延遲 [1:0]、vsync 延遲
            (b(16#37#), b(H_ACTIVE / 128)),       -- 寬 [11:7]
            (b(16#38#), b((H_ACTIVE mod 128) * 2)),                 -- 寬 [6:0]
            (b(16#39#), b(V_ACTIVE / 16)),        -- 高 [11:4]
            (b(16#3A#), b((V_ACTIVE mod 16) * 16)),                 -- 高 [3:0]
            (b(16#1A#), b(16#24#)),               -- CSC：進入更新模式（0x1A[5]）
            (b(16#18#), b(16#C7#)),               -- 開啟 CSC、縮放 ×4、A1 = 0x0734
            (b(16#19#), b(16#34#)),
            (b(16#1B#), b(16#AD#)),               -- A2 = 0x04AD（0x1A 的高位元在上一筆與最後一筆）
            (b(16#1C#), b(16#00#)),               -- A3 = 0x0000
            (b(16#1D#), b(16#00#)),
            (b(16#1E#), b(16#1C#)),               -- A4 = 0x1C1B
            (b(16#1F#), b(16#1B#)),
            (b(16#20#), b(16#1D#)),               -- B1 = 0x1DDC
            (b(16#21#), b(16#DC#)),
            (b(16#22#), b(16#04#)),               -- B2 = 0x04AD
            (b(16#23#), b(16#AD#)),
            (b(16#24#), b(16#1F#)),               -- B3 = 0x1F24
            (b(16#25#), b(16#24#)),
            (b(16#26#), b(16#01#)),               -- B4 = 0x0135
            (b(16#27#), b(16#35#)),
            (b(16#28#), b(16#00#)),               -- C1 = 0x0000
            (b(16#29#), b(16#00#)),
            (b(16#2A#), b(16#04#)),               -- C2 = 0x04AD
            (b(16#2B#), b(16#AD#)),
            (b(16#2C#), b(16#08#)),               -- C3 = 0x087C
            (b(16#2D#), b(16#7C#)),
            (b(16#2E#), b(16#1B#)),               -- C4 = 0x1B77
            (b(16#2F#), b(16#77#)),
            (b(16#1A#), b(16#04#)),               -- 離開更新模式，A2 高位元 0x04
            (b(16#AF#), b(16#04#)),               -- DVI 模式（只有影像）
            (b(16#BA#), b(16#60#))                -- 輸入時脈不延遲
        );
        return t;
    end function;

    constant REGS : reg_arr_t := reg_table;
    constant NREG : positive  := REGS'length;

    type state_t is (WAIT_ST, START_ST, BIT_ST, STOP_ST);
    signal state    : state_t := WAIT_ST;
    signal wait_cnt : integer range 0 to START_DELAY - 1 := 0;
    signal tick_cnt : integer range 0 to I2C_DIV - 1 := 0;
    signal q        : integer range 0 to 3 := 0;          -- 一個 SCL 週期裡的第幾個四分之一
    signal idx      : integer range 0 to NREG - 1 := 0;
    signal bitn     : integer range 0 to 26 := 0;          -- 3 個 byte × (8 bit + ACK)
    signal scl_o    : std_logic := '1';                    -- '1' = 放開
    signal sda_o    : std_logic := '1';
    signal sda_s    : std_logic := '1';
    signal nack     : std_logic := '0';
    signal ok_reg   : std_logic := '0';
    signal word     : std_logic_vector(26 downto 0);       -- ACK 位置填 1（放開 SDA）

begin

    word <= DEV_ADDR & '0' & '1' & REGS(idx).addr & '1' & REGS(idx).data & '1';

    process(clk)
    begin
        if rising_edge(clk) then
            if sda = '0' then
                sda_s <= '0';
            else
                sda_s <= '1';
            end if;

            if reset = '1' then
                state    <= WAIT_ST;
                wait_cnt <= 0;
                tick_cnt <= 0;
                q        <= 0;
                idx      <= 0;
                bitn     <= 0;
                scl_o    <= '1';
                sda_o    <= '1';
                nack     <= '0';
                ok_reg   <= '0';
            elsif state = WAIT_ST then
                scl_o <= '1';
                sda_o <= '1';
                if wait_cnt = START_DELAY - 1 then
                    wait_cnt <= 0;
                    tick_cnt <= 0;
                    q        <= 0;
                    idx      <= 0;
                    nack     <= '0';
                    state    <= START_ST;
                else
                    wait_cnt <= wait_cnt + 1;
                end if;
            elsif tick_cnt /= I2C_DIV - 1 then
                tick_cnt <= tick_cnt + 1;
            else
                tick_cnt <= 0;
                case state is
                    -- START：SCL 高時把 SDA 拉低，再拉低 SCL
                    when START_ST =>
                        case q is
                            when 0 =>
                                scl_o <= '1';
                                sda_o <= '1';
                                q     <= 1;
                            when 1 =>
                                sda_o <= '0';
                                q     <= 2;
                            when others =>
                                scl_o <= '0';
                                bitn  <= 0;
                                q     <= 0;
                                state <= BIT_ST;
                        end case;

                    -- 每個 bit：SCL 低時換 SDA，SCL 高的中間讀 ACK
                    when BIT_ST =>
                        case q is
                            when 0 =>
                                sda_o <= word(26 - bitn);
                                q     <= 1;
                            when 1 =>
                                scl_o <= '1';
                                q     <= 2;
                            when 2 =>
                                if (bitn = 8 or bitn = 17 or bitn = 26) and sda_s /= '0' then
                                    nack <= '1';
                                end if;
                                q <= 3;
                            when others =>
                                scl_o <= '0';
                                q     <= 0;
                                if bitn = 26 then
                                    state <= STOP_ST;
                                else
                                    bitn <= bitn + 1;
                                end if;
                        end case;

                    -- STOP：SCL 高時放開 SDA
                    when STOP_ST =>
                        case q is
                            when 0 =>
                                sda_o <= '0';
                                q     <= 1;
                            when 1 =>
                                scl_o <= '1';
                                q     <= 2;
                            when 2 =>
                                sda_o <= '1';
                                q     <= 3;
                            when others =>
                                q <= 0;
                                if idx = NREG - 1 then
                                    ok_reg <= not nack;
                                    state  <= WAIT_ST;
                                else
                                    idx   <= idx + 1;
                                    state <= START_ST;
                                end if;
                        end case;

                    when others =>
                        state <= WAIT_ST;
                end case;
            end if;
        end if;
    end process;

    scl <= '0' when scl_o = '0' else 'Z';
    sda <= '0' when sda_o = '0' else 'Z';
    ok  <= ok_reg;

end Behavioral;
