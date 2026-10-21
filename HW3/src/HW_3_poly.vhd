library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

-- HW3 旋轉正多邊形單元（規格見 HW3/SPEC.md §5）
--   正 N 邊形 = N 個半平面 n_k · p <= a 的交集（n_k 為邊的單位法向量，a 為邊心距）
--   形狀轉 θ 等於把法向量轉 θ，所以把轉好的法向量排成 N×2 矩陣 W：
--     每幀一次（垂直遮沒內）：W = N0 · R(θ)ᵀ，逐列算，矩陣 × 矩陣
--     每個像素：s = W · d（d = 像素 - 中心），矩陣 × 向量，2N 個乘法同時算
--     判斷：max(s) <= a 在形狀內，max(s) > a - EDGE_W 是外框
--   定點格式：sin / cos、W 為 Q1.14（1.0 = 16384），s 與門檻都是「像素 × 2^14」
entity HW_3_poly is
    Generic (
        SIDES      : positive := 4;     -- 邊數 N（3 ~ 8）
        CX         : natural  := 320;   -- 中心（像素）
        CY         : natural  := 240;
        RADIUS     : positive := 90;    -- 外接圓半徑（像素）
        EDGE_W     : positive := 4;     -- 外框寬度（像素）
        ANGLE_BITS : positive := 10     -- 一圈 2^ANGLE_BITS 步
    );
    Port (
        clk    : in  STD_LOGIC;
        reset  : in  STD_LOGIC;
        ce     : in  STD_LOGIC;                          -- 像素致能，像素管線只在 ce 前進
        load   : in  STD_LOGIC;                          -- 單拍：以 angle 重算 W，約 2N+1 個 clk
        angle  : in  unsigned(ANGLE_BITS-1 downto 0);
        x      : in  unsigned(11 downto 0);
        y      : in  unsigned(11 downto 0);
        inside : out STD_LOGIC;                          -- 比 x / y 晚 4 個 ce
        edge   : out STD_LOGIC
    );
end HW_3_poly;

architecture Behavioral of HW_3_poly is

    constant FRAC : natural := 14;
    constant ONE  : real    := real(2**FRAC);

    --------------------------------------------------
    -- sin ROM（elaboration 時計算），cos(a) = sin(a + 1/4 圈)
    --------------------------------------------------
    type sin_rom_t is array (0 to 2**ANGLE_BITS - 1) of signed(15 downto 0);

    function gen_sin return sin_rom_t is
        variable rom : sin_rom_t;
    begin
        for i in 0 to 2**ANGLE_BITS - 1 loop
            rom(i) := to_signed(integer(round(ONE * sin(MATH_2_PI * real(i) / real(2**ANGLE_BITS)))), 16);
        end loop;
        return rom;
    end function;

    constant SIN_ROM : sin_rom_t := gen_sin;
    constant QUARTER : unsigned(ANGLE_BITS-1 downto 0) := to_unsigned(2**(ANGLE_BITS - 2), ANGLE_BITS);

    --------------------------------------------------
    -- 未旋轉的法向量 N0：第 k 條邊的法向量角度 90° + k × 360°/N
    --   螢幕 y 向下，90° 指向下方，所以底邊水平、三角形尖端朝上
    --------------------------------------------------
    type coef_t is array (0 to SIDES - 1) of signed(15 downto 0);

    function gen_normal(use_sin : boolean) return coef_t is
        variable t   : coef_t;
        variable phi : real;
    begin
        for k in 0 to SIDES - 1 loop
            phi := MATH_PI_OVER_2 + MATH_2_PI * real(k) / real(SIDES);
            if use_sin then
                t(k) := to_signed(integer(round(ONE * sin(phi))), 16);
            else
                t(k) := to_signed(integer(round(ONE * cos(phi))), 16);
            end if;
        end loop;
        return t;
    end function;

    constant NX : coef_t := gen_normal(false);
    constant NY : coef_t := gen_normal(true);

    -- 邊心距 a = R cos(π/N)；外框內緣 a - EDGE_W
    constant APO_Q  : integer := integer(round(real(RADIUS) * cos(MATH_PI / real(SIDES)) * ONE));
    constant CORE_Q : integer := APO_Q - EDGE_W * 2**FRAC;

    -- Q2.28 乘積四捨五入回 Q1.14
    function round_q(v : signed(31 downto 0)) return signed is
    begin
        return resize(shift_right(v + to_signed(2**(FRAC - 1), 32), FRAC), 16);
    end function;

    -- 每幀的矩陣 W（reset 後為 θ = 0，即 N0）
    signal wx : coef_t := NX;
    signal wy : coef_t := NY;

    -- W 的計算序列
    type seq_state_type is (S_IDLE, S_MUL, S_ADD);
    signal seq_state : seq_state_type := S_IDLE;
    signal k_cnt     : integer range 0 to SIDES - 1 := 0;
    signal cos_r     : signed(15 downto 0) := (others => '0');
    signal sin_r     : signed(15 downto 0) := (others => '0');
    signal m_cx      : signed(31 downto 0) := (others => '0');   -- cos · nx
    signal m_sy      : signed(31 downto 0) := (others => '0');   -- sin · ny
    signal m_sx      : signed(31 downto 0) := (others => '0');   -- sin · nx
    signal m_cy      : signed(31 downto 0) := (others => '0');   -- cos · ny

    -- 像素管線
    type prod_t is array (0 to SIDES - 1) of signed(28 downto 0);   -- 16 × 13 bit
    type sum_t  is array (0 to SIDES - 1) of signed(29 downto 0);
    signal dx     : signed(12 downto 0) := (others => '0');
    signal dy     : signed(12 downto 0) := (others => '0');
    signal px     : prod_t := (others => (others => '0'));
    signal py     : prod_t := (others => (others => '0'));
    signal s      : sum_t  := (others => (others => '0'));
    signal in_reg : std_logic := '0';
    signal ed_reg : std_logic := '0';

begin

    assert SIDES >= 3 and SIDES <= 8
        report "SIDES must be between 3 and 8"
        severity failure;

    assert ANGLE_BITS >= 4 and ANGLE_BITS <= 12
        report "ANGLE_BITS must be between 4 and 12"
        severity failure;

    --------------------------------------------------
    -- 1. 每幀算 W = N0 · R(θ)ᵀ：第 k 列為 (c·nx - s·ny, s·nx + c·ny)
    --    load 那拍讀 ROM，之後每列兩拍（乘、加），只在垂直遮沒內執行
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                seq_state <= S_IDLE;
                k_cnt     <= 0;
                wx        <= NX;
                wy        <= NY;

            else
                case seq_state is

                    when S_IDLE =>
                        if load = '1' then
                            cos_r     <= SIN_ROM(to_integer(angle + QUARTER));
                            sin_r     <= SIN_ROM(to_integer(angle));
                            k_cnt     <= 0;
                            seq_state <= S_MUL;
                        end if;

                    when S_MUL =>
                        m_cx      <= cos_r * NX(k_cnt);
                        m_sy      <= sin_r * NY(k_cnt);
                        m_sx      <= sin_r * NX(k_cnt);
                        m_cy      <= cos_r * NY(k_cnt);
                        seq_state <= S_ADD;

                    when S_ADD =>
                        wx(k_cnt) <= round_q(m_cx - m_sy);
                        wy(k_cnt) <= round_q(m_sx + m_cy);
                        if k_cnt = SIDES - 1 then
                            seq_state <= S_IDLE;
                        else
                            k_cnt     <= k_cnt + 1;
                            seq_state <= S_MUL;
                        end if;

                end case;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 2. 像素管線（每級一個 ce）
    --    P1 平移：d = (x - CX, y - CY)
    --    P2 乘法：每列 wx·dx、wy·dy，共 2N 個 DSP
    --    P3 加法：s_k = wx·dx + wy·dy
    --    P4 門檻：全部 s_k <= a 在形狀內；任一 s_k > a - EDGE_W 是外框
    --------------------------------------------------
    process(clk)
        variable in_v   : std_logic;
        variable core_v : std_logic;
    begin
        if rising_edge(clk) then
            if ce = '1' then
                -- P1
                dx <= signed('0' & x) - to_signed(CX, 13);
                dy <= signed('0' & y) - to_signed(CY, 13);

                -- P2
                for k in 0 to SIDES - 1 loop
                    px(k) <= wx(k) * dx;
                    py(k) <= wy(k) * dy;
                end loop;

                -- P3
                for k in 0 to SIDES - 1 loop
                    s(k) <= resize(px(k), 30) + resize(py(k), 30);
                end loop;

                -- P4
                in_v   := '1';
                core_v := '1';
                for k in 0 to SIDES - 1 loop
                    if s(k) > to_signed(APO_Q, 30) then
                        in_v := '0';
                    end if;
                    if s(k) > to_signed(CORE_Q, 30) then
                        core_v := '0';
                    end if;
                end loop;
                in_reg <= in_v;
                ed_reg <= in_v and not core_v;
            end if;
        end if;
    end process;

    inside <= in_reg;
    edge   <= ed_reg;

end Behavioral;
