library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

-- HW3 旋轉正多面體單元（規格見 HW3/SPEC.md §5）
--   凸多面體 = F 個半空間 n_k · P <= a 的交集（n_k 為面的單位外法向量，a 為內切球半徑）
--   正交投影，視線沿 +z（螢幕 x 向右、y 向下、z 往螢幕裡），像素 d = (dx, dy) 的光線為 P = (dx, dy, z)：
--     每個面給出一個深度 z_k = (a - nx·dx - ny·dy) / nz，是 dx、dy 的一次式 A_k + B_k·dx + C_k·dy
--     nz < 0（朝向觀眾的正面）：光線在 z >= z_k；nz > 0（背面）：z <= z_k
--     光線穿過多面體 ⇔ max(正面 z_k) <= min(背面 z_k)
--     看到的是 z_k 最大的正面（進入點），光線從 z_k 最小的背面離開（離開點）
--   每幀一次（垂直遮沒內）：法向量與面上兩個切向量轉 R = Rx(α)·Ry(β)，算光照、1/|nz|、
--     每個面的 (A, B, C) 與面座標 (u, v) 的係數；只用一個 DSP48E1 當乘累加器，照固定排程表逐面算
--   每個像素：v = W · (dx, dy, 1)，每列兩個 DSP48E1 串接（乘加 + PCIN），再以比較樹取 max / min
--     全息點雲：進入點與離開點的面座標 (u, v) 也是 dx、dy 的一次式，各用兩個串接的 DSP 算出，
--     再以 (u, v) 所在的 8 × 8 像素格子查雜湊，決定格子裡有沒有點、點在哪
--   幾乎側對觀眾的面（|nz| < 1/256）不做除法，改用 2D 半平面 nx·dx + ny·dy <= a
--   定點格式：sin / cos、法向量、切向量為 Q1.14（1.0 = 16384），B、C、u / v 係數為 Q9.14，
--     A 與 u、v 為「像素 × 2^14」，比較樹裡的深度只留 4 位小數（像素 × 2^4，26 bit）
entity HW_3_solid is
    Generic (
        SOLID      : natural  := 0;          -- 0 立方體、1 八面體、2 十二面體、3 二十面體
        SEED       : natural  := 0;          -- 點雲雜湊的種子（0 ~ 3），每個形體不同
        CX         : natural  := 320;        -- 中心（像素）
        CY         : natural  := 240;
        RADIUS     : positive := 100;        -- 外接球半徑（像素）
        BASE_RGB   : std_logic_vector(23 downto 0) := x"FF0000";   -- 正對光源時的顏色
        ANGLE_BITS : positive := 10;         -- 一圈 2^ANGLE_BITS 步
        TREE_LV    : positive := 5           -- 比較樹層數，最多 2^TREE_LV 個面
    );
    Port (
        clk    : in  STD_LOGIC;
        reset  : in  STD_LOGIC;
        ce     : in  STD_LOGIC;                          -- 像素致能，像素管線只在 ce 前進
        load   : in  STD_LOGIC;                          -- 單拍：以 ang_x、ang_y 重算 W，每面 62 個 clk
        ang_x  : in  unsigned(ANGLE_BITS-1 downto 0);    -- 繞 x 軸（α）
        ang_y  : in  unsigned(ANGLE_BITS-1 downto 0);    -- 繞 y 軸（β）
        x      : in  unsigned(11 downto 0);
        y      : in  unsigned(11 downto 0);
        inside : out STD_LOGIC;                          -- 以下全部比 x / y 晚 9 + TREE_LV 個 ce
        face   : out unsigned(4 downto 0);               -- 看到的面（進入點）
        bface  : out unsigned(4 downto 0);               -- 光線離開的背面
        rgb    : out STD_LOGIC_VECTOR(23 downto 0);      -- 看到的面打光後的顏色
        dot_f  : out STD_LOGIC;                          -- 進入點落在點雲的點上
        dot_b  : out STD_LOGIC                           -- 離開點落在點雲的點上
    );
end HW_3_solid;

architecture Behavioral of HW_3_solid is

    constant FRAC : natural := 14;
    constant ONE  : real    := real(2**FRAC);
    constant PHI  : real    := (1.0 + sqrt(5.0)) / 2.0;

    --------------------------------------------------
    -- 多面體的面法向量（elaboration 時計算）
    --------------------------------------------------
    function faces_of(sol : natural) return positive is
    begin
        case sol is
            when 0      => return 6;
            when 1      => return 8;
            when 2      => return 12;
            when others => return 20;
        end case;
    end function;

    -- 內切球半徑 / 外接球半徑：立方體與八面體互為對偶、十二面體與二十面體互為對偶，比值相同
    function in_ratio(sol : natural) return real is
    begin
        if sol <= 1 then
            return 1.0 / sqrt(3.0);
        else
            return sqrt((5.0 + 2.0 * sqrt(5.0)) / 15.0);
        end if;
    end function;

    constant FACES : positive := faces_of(SOLID);
    constant NL    : positive := 2**TREE_LV;

    type vec3_t is array (0 to 2) of real;

    -- k 的第 b 位元為 0 取 +1、為 1 取 -1
    function bit_sign(k, b : natural) return real is
    begin
        if (k / 2**b) mod 2 = 0 then
            return 1.0;
        else
            return -1.0;
        end if;
    end function;

    -- (0, p, q) 的第 g 個循環排列：(0, p, q)、(p, q, 0)、(q, 0, p)
    function cyc(g : natural; p, q : real) return vec3_t is
        variable t, v : vec3_t;
    begin
        t := (0.0, p, q);
        for j in 0 to 2 loop
            v(j) := t((j + g) mod 3);
        end loop;
        return v;
    end function;

    -- 第 k 個面的法向量方向（未正規化）
    function base_normal(sol, k : natural) return vec3_t is
        variable v : vec3_t := (0.0, 0.0, 0.0);
    begin
        case sol is
            when 0 =>                                   -- 立方體：±x、±y、±z
                v(k / 2) := bit_sign(k, 0);
            when 1 =>                                   -- 八面體：(±1, ±1, ±1)
                v := (bit_sign(k, 0), bit_sign(k, 1), bit_sign(k, 2));
            when 2 =>                                   -- 十二面體：(0, ±1, ±φ) 的循環排列
                v := cyc(k / 4, bit_sign(k, 0), bit_sign(k, 1) * PHI);
            when others =>                              -- 二十面體：(±1, ±1, ±1) 與 (0, ±1/φ, ±φ) 的循環排列
                if k < 8 then
                    v := (bit_sign(k, 0), bit_sign(k, 1), bit_sign(k, 2));
                else
                    v := cyc((k - 8) / 4, bit_sign(k, 0) / PHI, bit_sign(k, 1) * PHI);
                end if;
        end case;
        return v;
    end function;

    function unit(v : vec3_t) return vec3_t is
        variable len : real;
    begin
        len := sqrt(v(0) * v(0) + v(1) * v(1) + v(2) * v(2));
        return (v(0) / len, v(1) / len, v(2) / len);
    end function;

    function cross(a, b : vec3_t) return vec3_t is
    begin
        return (a(1) * b(2) - a(2) * b(1), a(2) * b(0) - a(0) * b(2), a(0) * b(1) - a(1) * b(0));
    end function;

    -- 面上的兩個單位切向量：t1 = n × ref、t2 = n × t1（ref 取 y 軸，n 幾乎平行 y 軸時改取 x 軸）
    --   which = 0 法向量、1 為 t1、2 為 t2
    function face_vec(sol, k, which : natural) return vec3_t is
        variable n, r, t1 : vec3_t;
    begin
        n := unit(base_normal(sol, k));
        if which = 0 then
            return n;
        end if;
        if abs n(1) < 0.9 then
            r := (0.0, 1.0, 0.0);
        else
            r := (1.0, 0.0, 0.0);
        end if;
        t1 := unit(cross(n, r));
        if which = 1 then
            return t1;
        end if;
        return cross(n, t1);
    end function;

    -- 初始傾斜 T = Rx(30°)·Ry(40°)：角度為 0 時也能同時看到好幾個面，不會只看到正面一個正方形
    constant TILT_X : real := MATH_PI / 6.0;
    constant TILT_Y : real := MATH_PI * 2.0 / 9.0;

    type n16_t is array (0 to FACES - 1) of signed(15 downto 0);

    -- 第 which 個向量（法向量 / t1 / t2）套上初始傾斜後的第 axis 個分量，Q1.14
    function gen_vec(which, axis : natural) return n16_t is
        variable t      : n16_t;
        variable v, r   : vec3_t;
        variable z1     : real;
    begin
        for k in 0 to FACES - 1 loop
            v    := face_vec(SOLID, k, which);
            -- Ry(TILT_Y) 再 Rx(TILT_X)
            r(0) := cos(TILT_Y) * v(0) + sin(TILT_Y) * v(2);
            z1   := cos(TILT_Y) * v(2) - sin(TILT_Y) * v(0);
            r(1) := cos(TILT_X) * v(1) - sin(TILT_X) * z1;
            r(2) := sin(TILT_X) * v(1) + cos(TILT_X) * z1;
            t(k) := to_signed(integer(round(ONE * r(axis))), 16);
        end loop;
        return t;
    end function;

    constant N0X : n16_t := gen_vec(0, 0);
    constant N0Y : n16_t := gen_vec(0, 1);
    constant N0Z : n16_t := gen_vec(0, 2);
    constant T1X : n16_t := gen_vec(1, 0);
    constant T1Y : n16_t := gen_vec(1, 1);
    constant T1Z : n16_t := gen_vec(1, 2);
    constant T2X : n16_t := gen_vec(2, 0);
    constant T2Y : n16_t := gen_vec(2, 1);
    constant T2Z : n16_t := gen_vec(2, 2);

    -- 內切球半徑 a 只留 8 位小數（像素 × 2^8），才放得進 DSP 的 18 bit 埠；
    --   所有面用同一個 a，等於整個形體縮放不到 1/512 像素，面與面之間仍然一致
    constant A_Q8  : integer := integer(round(real(RADIUS) * in_ratio(SOLID) * 256.0));
    constant EPS_Q : integer := 2**(FRAC - 8);  -- |nz| 小於 1/256 的面視為側面

    -- 光源方向（指向光源）：左上前方；亮度 = 1/4 + 3/4 × max(0, n · L)
    constant L_LEN : real    := sqrt(0.45 * 0.45 + 0.65 * 0.65 + 0.6 * 0.6);
    constant LX_Q  : integer := integer(round(ONE * (-0.45) / L_LEN));
    constant LY_Q  : integer := integer(round(ONE * (-0.65) / L_LEN));
    constant LZ_Q  : integer := integer(round(ONE * (-0.60) / L_LEN));

    -- 點雲：格子 8 × 8 像素（u、v 的第 17 位以上是格子編號，第 12 ~ 16 位是格子內的 1/4 像素位置），
    --   每格保留機率 192 / 256 = 75%（正面、背面相同）
    constant DOT_KEEP : natural := 192;

    --------------------------------------------------
    -- sin ROM（elaboration 時計算），cos(a) = sin(a + 1/4 圈)
    --   1024 × 16 bit 剛好一個 RAMB18，兩個讀取埠同時讀 sin 與 cos
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

    -- 乘累加結果四捨五入，去掉 sh 位小數
    function rnd(p : signed(47 downto 0); sh, bits : positive) return signed is
    begin
        return resize(shift_right(p + to_signed(2**(sh - 1), 48), sh), bits);
    end function;

    --------------------------------------------------
    -- 點雲的雜湊：只用 XOR、旋轉與一個 24 bit 加法（不佔 DSP）
    --   key = 正/背面 & 種子 & 面編號 & 格子 v & 格子 u
    --------------------------------------------------
    function rotl(v : unsigned(23 downto 0); r : natural) return unsigned is
    begin
        return v(23 - r downto 0) & v(23 downto 24 - r);
    end function;

    function mix(key : unsigned(23 downto 0)) return unsigned is
        variable h1, h2 : unsigned(23 downto 0);
    begin
        h1 := key xor rotl(key, 5) xor rotl(key, 11);
        h2 := h1 + rotl(h1, 9);
        return h2 xor rotl(h2, 15);
    end function;

    -- 格子保留時，點在格子內的位置 9 ~ 23（1/4 像素，中心 16），像素離點不超過 2/4 像素就點亮
    function dot_hit(u, v : signed(39 downto 0); key_hi : unsigned(7 downto 0)) return std_logic is
        variable h      : unsigned(23 downto 0);
        variable pu, pv : integer;
        variable wu, wv : integer;
    begin
        h  := mix(key_hi & unsigned(v(24 downto 17)) & unsigned(u(24 downto 17)));
        pu := 9 + 2 * to_integer(h(10 downto 8));
        pv := 9 + 2 * to_integer(h(13 downto 11));
        wu := to_integer(unsigned(u(16 downto 12)));
        wv := to_integer(unsigned(v(16 downto 12)));
        if to_integer(h(7 downto 0)) < DOT_KEEP and abs (wu - pu) <= 2 and abs (wv - pv) <= 2 then
            return '1';
        end if;
        return '0';
    end function;

    --------------------------------------------------
    -- 每幀的矩陣 W：第 k 列 (B_k, C_k, A_k) 與面的種類
    --   正面 / 背面：v = 深度 z_k；側面：v = nx·dx + ny·dy - a，v <= 0 才在形狀內
    -- 面座標：u = t1 · (dx, dy, z_k) = U0 + Ux·dx + Uy·dy（z_k 代入上式），v 同理用 t2
    --------------------------------------------------
    constant CLS_FRONT : std_logic_vector(1 downto 0) := "00";
    constant CLS_BACK  : std_logic_vector(1 downto 0) := "01";
    constant CLS_SIDE  : std_logic_vector(1 downto 0) := "10";

    type a_arr_t   is array (0 to FACES - 1) of signed(31 downto 0);
    type bc_arr_t  is array (0 to FACES - 1) of signed(23 downto 0);
    type cls_arr_t is array (0 to FACES - 1) of std_logic_vector(1 downto 0);
    type rgb_arr_t is array (0 to FACES - 1) of std_logic_vector(23 downto 0);

    signal a_t   : a_arr_t   := (others => (others => '0'));
    signal b_t   : bc_arr_t  := (others => (others => '0'));
    signal c_t   : bc_arr_t  := (others => (others => '0'));
    signal cls_t : cls_arr_t := (others => CLS_SIDE);
    signal rgb_t : rgb_arr_t := (others => (others => '0'));
    -- 面座標係數：像素管線以進入面、離開面兩個編號同時讀，綜合成雙讀取埠的 LUTRAM
    signal ux_t, uy_t : bc_arr_t := (others => (others => '0'));
    signal vx_t, vy_t : bc_arr_t := (others => (others => '0'));
    signal u0_t, v0_t : a_arr_t  := (others => (others => '0'));
    signal valid : std_logic := '0';             -- reset 後第一次算完 W 才輸出

    --------------------------------------------------
    -- W 的計算序列：一個乘累加器（DSP48E1，A 埠 25 bit、B 埠 18 bit）
    --   第 s 拍送出運算元 -> s+1 拍乘積進 M 暫存器 -> s+2 拍 P = M（載入）或 P + M（累加）
    --   -> 第 s+3 拍可以讀 P。沒事做的拍子送 0 × 0 累加，P 保持不變
    --------------------------------------------------
    constant ST_LAST : natural := 61;            -- 每面 62 拍（0 ~ 61）

    type seq_state_type is (S_IDLE, S_TRIG, S_RUN);
    signal seq_state : seq_state_type := S_IDLE;
    signal st        : integer range 0 to ST_LAST := 0;
    signal k_cnt     : integer range 0 to FACES - 1 := 0;
    signal ca, sa    : signed(15 downto 0) := (others => '0');   -- cos α、sin α
    signal cb, sb    : signed(15 downto 0) := (others => '0');   -- cos β、sin β

    signal mac_a     : signed(24 downto 0) := (others => '0');
    signal mac_b     : signed(17 downto 0) := (others => '0');
    signal mac_ld    : std_logic := '0';
    signal mac_m     : signed(42 downto 0) := (others => '0');
    signal mac_ld_m  : std_logic := '0';
    signal mac_p     : signed(47 downto 0) := (others => '0');

    signal nxr, nyr  : signed(15 downto 0) := (others => '0');   -- 轉好的法向量
    signal nzr, wr   : signed(15 downto 0) := (others => '0');   -- wr：轉完 Ry 後的 z
    signal r1x, r1y  : signed(15 downto 0) := (others => '0');   -- 轉好的切向量 t1
    signal r1z, w1   : signed(15 downto 0) := (others => '0');
    signal r2x, r2y  : signed(15 downto 0) := (others => '0');   -- 轉好的切向量 t2
    signal r2z, w2   : signed(15 downto 0) := (others => '0');
    signal cls_r     : std_logic_vector(1 downto 0) := CLS_SIDE;
    signal dot_r     : signed(33 downto 0) := (others => '0');   -- n · L（Q2.28）
    signal lit_r     : unsigned(13 downto 0) := (others => '0'); -- max(0, n · L)，Q0.14
    signal i8        : unsigned(7 downto 0) := (others => '0');  -- 亮度 64 ~ 255
    signal div_d     : unsigned(14 downto 0) := (others => '0'); -- |nz|
    signal div_rem   : unsigned(14 downto 0) := (others => '0');
    signal div_q     : unsigned(22 downto 0) := (others => '0'); -- 2^28 / |nz| = 1/|nz| 的 Q9.14
    signal b_q, c_q  : signed(23 downto 0) := (others => '0');   -- nx/|nz|、ny/|nz|
    signal a_q       : signed(31 downto 0) := (others => '0');   -- a/|nz|
    signal b_s, c_s  : signed(23 downto 0) := (others => '0');   -- 依正面 / 背面 / 側面定好正負號的 B、C、A
    signal a_s       : signed(31 downto 0) := (others => '0');
    signal ux_q, uy_q : signed(23 downto 0) := (others => '0');
    signal vx_q, vy_q : signed(23 downto 0) := (others => '0');
    signal u0_q      : signed(31 downto 0) := (others => '0');
    signal r8, g8    : std_logic_vector(7 downto 0) := (others => '0');
    signal b8        : std_logic_vector(7 downto 0) := (others => '0');

    --------------------------------------------------
    -- 像素管線
    --   P2、P3 是每列兩個 DSP48E1：第一個算 B·dx + A（A 進 C 埠），第二個算 C·dy 再加上第一個的 P
    --   （PCIN 串接），v 留在第二個 DSP 的 P 暫存器裡，比較樹只取其中 26 bit
    --------------------------------------------------
    constant VW    : positive := 26;              -- 比較樹的深度位元寬（像素 × 2^4）
    constant V_LSB : natural  := FRAC - 4;        -- 從 v 的第 10 位元開始取
    constant D_LAT : positive := 5 + TREE_LV;     -- dx 從 P1 到 H2 要等的 ce 數

    type acc_t is array (0 to FACES - 1) of signed(39 downto 0);
    type d_pipe_t is array (1 to D_LAT + 1) of signed(12 downto 0);

    -- 比較樹的節點：最遠的正面（深度、編號）、最近的背面（深度、編號）、側面條件
    type node_t is record
        f  : signed(VW - 1 downto 0);
        fi : unsigned(4 downto 0);
        b  : signed(VW - 1 downto 0);
        bi : unsigned(4 downto 0);
        s  : std_logic;
    end record;
    type tree_t is array (1 to 2 * NL - 1) of node_t;

    constant NEG_INF  : signed(VW - 1 downto 0) := ('1', others => '0');
    constant POS_INF  : signed(VW - 1 downto 0) := ('0', others => '1');
    constant NODE_PAD : node_t := (f => NEG_INF, fi => (others => '0'), b => POS_INF,
                                   bi => (others => '0'), s => '1');

    function leaf(v : signed(VW - 1 downto 0); cls : std_logic_vector(1 downto 0); k : natural) return node_t is
        variable n : node_t := NODE_PAD;
    begin
        n.fi := to_unsigned(k, 5);
        n.bi := to_unsigned(k, 5);
        if cls = CLS_FRONT then
            n.f := v;
        elsif cls = CLS_BACK then
            n.b := v;
        elsif v > 0 then
            n.s := '0';
        end if;
        return n;
    end function;

    function join(l, r : node_t) return node_t is
        variable n : node_t := l;
    begin
        if r.f > l.f then
            n.f  := r.f;
            n.fi := r.fi;
        end if;
        if r.b < l.b then
            n.b  := r.b;
            n.bi := r.bi;
        end if;
        n.s := l.s and r.s;
        return n;
    end function;

    signal dx       : signed(12 downto 0) := (others => '0');
    signal dy       : signed(12 downto 0) := (others => '0');
    signal dy_d     : signed(12 downto 0) := (others => '0');
    signal dx_p     : d_pipe_t := (others => (others => '0'));   -- 給 H2、H3 用的 dx、dy（綜合成 SRL）
    signal dy_p     : d_pipe_t := (others => (others => '0'));
    signal pa       : acc_t  := (others => (others => '0'));   -- A + B·dx
    signal v        : acc_t  := (others => (others => '0'));   -- A + B·dx + C·dy
    signal tree     : tree_t := (others => NODE_PAD);
    signal in_reg   : std_logic := '0';
    signal face_reg : unsigned(4 downto 0) := (others => '0');
    signal bf_reg   : unsigned(4 downto 0) := (others => '0');
    signal rgb_reg  : std_logic_vector(23 downto 0) := (others => '0');

    -- H1 ~ H4：面座標與點雲
    type out_t is record
        inside : std_logic;
        face   : unsigned(4 downto 0);
        bface  : unsigned(4 downto 0);
        rgb    : std_logic_vector(23 downto 0);
    end record;
    type out_pipe_t is array (1 to 4) of out_t;
    constant OUT_ZERO : out_t := ('0', (others => '0'), (others => '0'), (others => '0'));
    signal o_p      : out_pipe_t := (others => OUT_ZERO);

    signal f_ux, f_uy, f_vx, f_vy : signed(23 downto 0) := (others => '0');   -- H1：進入面的係數
    signal b_ux, b_uy, b_vx, b_vy : signed(23 downto 0) := (others => '0');   -- H1：離開面的係數
    signal f_u0, f_v0, b_u0, b_v0 : signed(31 downto 0) := (others => '0');
    signal f_uy2, f_vy2, b_uy2, b_vy2 : signed(23 downto 0) := (others => '0');
    signal pu_f, pv_f, pu_b, pv_b : signed(39 downto 0) := (others => '0');   -- H2：U0 + Ux·dx
    signal u_f, v_f, u_b, v_b     : signed(39 downto 0) := (others => '0');   -- H3：再加 Uy·dy
    signal dotf_reg : std_logic := '0';
    signal dotb_reg : std_logic := '0';

begin

    assert FACES <= NL
        report "TREE_LV too small for this solid"
        severity failure;

    assert ANGLE_BITS >= 4 and ANGLE_BITS <= 12
        report "ANGLE_BITS must be between 4 and 12"
        severity failure;

    assert RADIUS <= 200
        report "RADIUS must be at most 200 pixels to keep a within the 18-bit DSP port"
        severity failure;

    assert SEED <= 3
        report "SEED must be between 0 and 3"
        severity failure;

    --------------------------------------------------
    -- 1. 乘累加器：M、P 兩級暫存器，綜合成一個 DSP48E1（OPMODE 在載入 / 累加之間切換）
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            mac_m    <= mac_a * mac_b;
            mac_ld_m <= mac_ld;
            if mac_ld_m = '1' then
                mac_p <= resize(mac_m, 48);
            else
                mac_p <= mac_p + resize(mac_m, 48);
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 2. 每幀算 W：load 後兩拍查 ROM，接著每個面照排程表跑 62 拍
    --   送運算元（第 s 拍）                      讀結果（第 s+3 拍）
    --    0  cβ·nx0          載入
    --    1  sβ·nz0          累加                 4  nx = cβ·nx0 + sβ·nz0
    --    2  cβ·nz0          載入
    --    3  -sβ·nx0         累加                 6  w  = cβ·nz0 - sβ·nx0
    --    4  cα·ny0          載入
    --    7  -sα·w           累加（等 w）        10  ny = cα·ny0 - sα·w
    --    8  sα·ny0          載入
    --    9  cα·w            累加                12  nz = sα·ny0 + cα·w
    --   10  Lx·nx           載入
    --   11  Ly·ny           累加
    --   13  Lz·nz           累加（等 nz）       16  n · L
    --   14 ~ 23  切向量 t1 照 0 ~ 9 的方式轉     18、20、24、26  r1x、w1、r1y、r1z
    --   26 ~ 35  切向量 t2 照 0 ~ 9 的方式轉     30、32、36、38  r2x、w2、r2y、r2z
    --   13  依 nz 分類、開始除法；14 ~ 41 恢復式除法 2^28 / |nz|，每拍一位（MAC 同時轉切向量）
    --   17  夾在 0 ~ 1；18  亮度 = 64 + 3·lit / 256（移位相加，不用乘法器）
    --   42  q·nx            載入                45  B
    --   43  q·ny            載入                46  C
    --   44  q·a             載入                47  A
    --   45 ~ 47  底色 × (亮度 + 1)，三個通道      48 ~ 50  顏色
    --   48  依正面 / 背面 / 側面定好 A、B、C 的正負號
    --   49、50  B·r1z 載入、1.0·r1x 累加          53  Ux = r1x + r1z·B
    --   51、52  C·r1z、1.0·r1y                    55  Uy = r1y + r1z·C
    --   53、54  B·r2z、1.0·r2x                    57  Vx
    --   55、56  C·r2z、1.0·r2y                    59  Vy
    --   57  (A / 256)·r1z    載入               60  U0 = r1z·A
    --   58  (A / 256)·r2z    載入               61  V0 = r2z·A；寫進表格
    --   側面也照同一張表跑（除法結果不用），排程固定，不需要分支
    --------------------------------------------------
    process(clk)
        variable q25  : signed(24 downto 0);
        variable lum  : signed(17 downto 0);
        variable a6   : signed(24 downto 0);
        variable rem2 : unsigned(15 downto 0);
        variable dot_i : signed(33 downto 0);
        variable t16  : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            -- 預設送 0 × 0 累加：P 保持不變
            mac_a  <= (others => '0');
            mac_b  <= (others => '0');
            mac_ld <= '0';

            if reset = '1' then
                seq_state <= S_IDLE;
                st        <= 0;
                k_cnt     <= 0;
                valid     <= '0';

            else
                case seq_state is

                    when S_IDLE =>
                        if load = '1' then
                            ca        <= SIN_ROM(to_integer(ang_x + QUARTER));
                            sa        <= SIN_ROM(to_integer(ang_x));
                            seq_state <= S_TRIG;
                        end if;

                    when S_TRIG =>
                        cb        <= SIN_ROM(to_integer(ang_y + QUARTER));
                        sb        <= SIN_ROM(to_integer(ang_y));
                        k_cnt     <= 0;
                        st        <= 0;
                        seq_state <= S_RUN;

                    when S_RUN =>
                        q25 := resize(signed('0' & div_q), 25);
                        lum := resize(signed("00" & i8), 18) + 1;
                        a6  := resize(shift_right(a_s, 8), 25);

                        -- 送運算元
                        case st is
                            -- 法向量
                            when 0  => mac_a <= resize(cb, 25);  mac_b <= resize(N0X(k_cnt), 18); mac_ld <= '1';
                            when 1  => mac_a <= resize(sb, 25);  mac_b <= resize(N0Z(k_cnt), 18);
                            when 2  => mac_a <= resize(cb, 25);  mac_b <= resize(N0Z(k_cnt), 18); mac_ld <= '1';
                            when 3  => mac_a <= -resize(sb, 25); mac_b <= resize(N0X(k_cnt), 18);
                            when 4  => mac_a <= resize(ca, 25);  mac_b <= resize(N0Y(k_cnt), 18); mac_ld <= '1';
                            when 7  => mac_a <= -resize(sa, 25); mac_b <= resize(wr, 18);
                            when 8  => mac_a <= resize(sa, 25);  mac_b <= resize(N0Y(k_cnt), 18); mac_ld <= '1';
                            when 9  => mac_a <= resize(ca, 25);  mac_b <= resize(wr, 18);
                            -- 光照
                            when 10 => mac_a <= to_signed(LX_Q, 25); mac_b <= resize(nxr, 18); mac_ld <= '1';
                            when 11 => mac_a <= to_signed(LY_Q, 25); mac_b <= resize(nyr, 18);
                            when 13 => mac_a <= to_signed(LZ_Q, 25); mac_b <= resize(nzr, 18);
                            -- 切向量 t1
                            when 14 => mac_a <= resize(cb, 25);  mac_b <= resize(T1X(k_cnt), 18); mac_ld <= '1';
                            when 15 => mac_a <= resize(sb, 25);  mac_b <= resize(T1Z(k_cnt), 18);
                            when 16 => mac_a <= resize(cb, 25);  mac_b <= resize(T1Z(k_cnt), 18); mac_ld <= '1';
                            when 17 => mac_a <= -resize(sb, 25); mac_b <= resize(T1X(k_cnt), 18);
                            when 18 => mac_a <= resize(ca, 25);  mac_b <= resize(T1Y(k_cnt), 18); mac_ld <= '1';
                            when 21 => mac_a <= -resize(sa, 25); mac_b <= resize(w1, 18);
                            when 22 => mac_a <= resize(sa, 25);  mac_b <= resize(T1Y(k_cnt), 18); mac_ld <= '1';
                            when 23 => mac_a <= resize(ca, 25);  mac_b <= resize(w1, 18);
                            -- 切向量 t2
                            when 26 => mac_a <= resize(cb, 25);  mac_b <= resize(T2X(k_cnt), 18); mac_ld <= '1';
                            when 27 => mac_a <= resize(sb, 25);  mac_b <= resize(T2Z(k_cnt), 18);
                            when 28 => mac_a <= resize(cb, 25);  mac_b <= resize(T2Z(k_cnt), 18); mac_ld <= '1';
                            when 29 => mac_a <= -resize(sb, 25); mac_b <= resize(T2X(k_cnt), 18);
                            when 30 => mac_a <= resize(ca, 25);  mac_b <= resize(T2Y(k_cnt), 18); mac_ld <= '1';
                            when 33 => mac_a <= -resize(sa, 25); mac_b <= resize(w2, 18);
                            when 34 => mac_a <= resize(sa, 25);  mac_b <= resize(T2Y(k_cnt), 18); mac_ld <= '1';
                            when 35 => mac_a <= resize(ca, 25);  mac_b <= resize(w2, 18);
                            -- 1/|nz| 相乘與顏色
                            when 42 => mac_a <= q25; mac_b <= resize(nxr, 18); mac_ld <= '1';
                            when 43 => mac_a <= q25; mac_b <= resize(nyr, 18); mac_ld <= '1';
                            when 44 => mac_a <= q25; mac_b <= to_signed(A_Q8, 18); mac_ld <= '1';
                            when 45 => mac_a <= resize(signed('0' & BASE_RGB(23 downto 16)), 25); mac_b <= lum; mac_ld <= '1';
                            when 46 => mac_a <= resize(signed('0' & BASE_RGB(15 downto 8)), 25);  mac_b <= lum; mac_ld <= '1';
                            when 47 => mac_a <= resize(signed('0' & BASE_RGB(7 downto 0)), 25);   mac_b <= lum; mac_ld <= '1';
                            -- 面座標係數
                            when 49 => mac_a <= resize(b_s, 25); mac_b <= resize(r1z, 18); mac_ld <= '1';
                            when 50 => mac_a <= to_signed(2**FRAC, 25); mac_b <= resize(r1x, 18);
                            when 51 => mac_a <= resize(c_s, 25); mac_b <= resize(r1z, 18); mac_ld <= '1';
                            when 52 => mac_a <= to_signed(2**FRAC, 25); mac_b <= resize(r1y, 18);
                            when 53 => mac_a <= resize(b_s, 25); mac_b <= resize(r2z, 18); mac_ld <= '1';
                            when 54 => mac_a <= to_signed(2**FRAC, 25); mac_b <= resize(r2x, 18);
                            when 55 => mac_a <= resize(c_s, 25); mac_b <= resize(r2z, 18); mac_ld <= '1';
                            when 56 => mac_a <= to_signed(2**FRAC, 25); mac_b <= resize(r2y, 18);
                            when 57 => mac_a <= a6; mac_b <= resize(r1z, 18); mac_ld <= '1';
                            when 58 => mac_a <= a6; mac_b <= resize(r2z, 18); mac_ld <= '1';
                            when others => null;
                        end case;

                        -- 讀結果
                        case st is
                            when 4  => nxr <= rnd(mac_p, FRAC, 16);
                            when 6  => wr  <= rnd(mac_p, FRAC, 16);
                            when 10 => nyr <= rnd(mac_p, FRAC, 16);
                            when 12 => nzr <= rnd(mac_p, FRAC, 16);
                            when 16 => dot_r <= resize(mac_p, 34);
                            when 18 => r1x <= rnd(mac_p, FRAC, 16);
                            when 20 => w1  <= rnd(mac_p, FRAC, 16);
                            when 24 => r1y <= rnd(mac_p, FRAC, 16);
                            when 26 => r1z <= rnd(mac_p, FRAC, 16);
                            when 30 => r2x <= rnd(mac_p, FRAC, 16);
                            when 32 => w2  <= rnd(mac_p, FRAC, 16);
                            when 36 => r2y <= rnd(mac_p, FRAC, 16);
                            when 38 => r2z <= rnd(mac_p, FRAC, 16);
                            when 45 => b_q <= rnd(mac_p, FRAC, 24);
                            when 46 => c_q <= rnd(mac_p, FRAC, 24);
                            when 47 => a_q <= rnd(mac_p, 8, 32);
                            when 48 => r8  <= std_logic_vector(mac_p(15 downto 8));
                            when 49 => g8  <= std_logic_vector(mac_p(15 downto 8));
                            when 50 => b8  <= std_logic_vector(mac_p(15 downto 8));
                            when 53 => ux_q <= rnd(mac_p, FRAC, 24);
                            when 55 => uy_q <= rnd(mac_p, FRAC, 24);
                            when 57 => vx_q <= rnd(mac_p, FRAC, 24);
                            when 59 => vy_q <= rnd(mac_p, FRAC, 24);
                            when 60 => u0_q <= rnd(mac_p, 6, 32);
                            when others => null;
                        end case;

                        -- 分類與除法
                        if st = 13 then
                            if nzr <= -EPS_Q then
                                cls_r <= CLS_FRONT;
                            elsif nzr >= EPS_Q then
                                cls_r <= CLS_BACK;
                            else
                                cls_r <= CLS_SIDE;
                            end if;
                            div_d   <= resize(unsigned(abs(nzr)), 15);
                            div_rem <= to_unsigned(1, 15);
                            div_q   <= (others => '0');
                        elsif st >= 14 and st <= 41 then
                            rem2 := div_rem & '0';
                            if rem2 >= div_d then
                                div_rem <= resize(rem2 - div_d, 15);
                                div_q   <= div_q(21 downto 0) & '1';
                            else
                                div_rem <= resize(rem2, 15);
                                div_q   <= div_q(21 downto 0) & '0';
                            end if;
                        end if;

                        -- 亮度
                        if st = 17 then
                            dot_i := shift_right(dot_r, FRAC);
                            if dot_i < 0 then
                                lit_r <= (others => '0');
                            elsif dot_i >= 2**FRAC then
                                lit_r <= (others => '1');
                            else
                                lit_r <= unsigned(dot_i(13 downto 0));
                            end if;
                        end if;
                        if st = 18 then
                            t16 := ('0' & lit_r & '0') + resize(lit_r, 16);
                            i8  <= 64 + resize(t16(15 downto 8), 8);
                        end if;

                        -- 正面：A = -a/|nz|、B = nx/|nz|、C = ny/|nz|；背面全部反號；側面改用 (nx, ny, -a)
                        if st = 48 then
                            if cls_r = CLS_FRONT then
                                a_s <= -a_q;
                                b_s <= b_q;
                                c_s <= c_q;
                            elsif cls_r = CLS_BACK then
                                a_s <= a_q;
                                b_s <= -b_q;
                                c_s <= -c_q;
                            else
                                a_s <= to_signed(-A_Q8 * 2**(FRAC - 8), 32);
                                b_s <= resize(nxr, 24);
                                c_s <= resize(nyr, 24);
                            end if;
                        end if;

                        -- 寫進表格，換下一個面
                        if st = ST_LAST then
                            cls_t(k_cnt) <= cls_r;
                            a_t(k_cnt)   <= a_s;
                            b_t(k_cnt)   <= b_s;
                            c_t(k_cnt)   <= c_s;
                            rgb_t(k_cnt) <= r8 & g8 & b8;
                            ux_t(k_cnt)  <= ux_q;
                            uy_t(k_cnt)  <= uy_q;
                            vx_t(k_cnt)  <= vx_q;
                            vy_t(k_cnt)  <= vy_q;
                            u0_t(k_cnt)  <= u0_q;
                            v0_t(k_cnt)  <= rnd(mac_p, 6, 32);
                            st <= 0;
                            if k_cnt = FACES - 1 then
                                valid     <= '1';
                                seq_state <= S_IDLE;
                            else
                                k_cnt <= k_cnt + 1;
                            end if;
                        else
                            st <= st + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 3. 像素管線（每級一個 ce）
    --    P1 平移：d = (x - CX, y - CY)
    --    P2 DSP：pa = A + B·dx（每列一個 DSP48E1，A 進 C 埠）
    --    P3 DSP：v  = pa + C·dy（第二個 DSP48E1，pa 經 PCIN 串接進來）
    --    P4 葉節點：取 v 的 26 bit（像素 × 2^4）；正面當候選深度、背面當上限、側面判斷 v <= 0
    --    T1..T(TREE_LV) 比較樹：每層一級，取最遠的正面與最近的背面（連同編號）
    --    P5 判斷：max(正面) <= min(背面) 且側面都滿足 -> 在形狀內，查該面的顏色
    --    H1 以進入面、離開面的編號讀面座標係數（LUTRAM 兩個讀取埠）
    --    H2 DSP：U0 + Ux·dx（進入面與離開面的 u、v，共 4 個 DSP）
    --    H3 DSP：再加 Uy·dy（PCIN 串接，4 個 DSP）
    --    H4 以 (u, v) 所在格子查雜湊，判斷這個像素是不是點雲上的點
    --------------------------------------------------
    process(clk)
        variable root  : node_t;
        variable in_v  : std_logic;
        variable kf, kb : unsigned(7 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                -- P1
                dx <= signed('0' & x) - to_signed(CX, 13);
                dy <= signed('0' & y) - to_signed(CY, 13);

                -- P2
                dy_d <= dy;
                for k in 0 to FACES - 1 loop
                    pa(k) <= resize(b_t(k) * dx, 40) + resize(a_t(k), 40);
                end loop;

                -- P3
                for k in 0 to FACES - 1 loop
                    v(k) <= resize(c_t(k) * dy_d, 40) + pa(k);
                end loop;

                -- P4：|v| < 2^34，取第 10 ~ 35 位元；沒用到的葉節點填 NODE_PAD
                for k in 0 to FACES - 1 loop
                    tree(NL + k) <= leaf(v(k)(V_LSB + VW - 1 downto V_LSB), cls_t(k), k);
                end loop;
                for k in FACES to NL - 1 loop
                    tree(NL + k) <= NODE_PAD;
                end loop;

                -- 比較樹：節點 i 的子節點為 2i、2i+1，根為 1
                for i in 1 to NL - 1 loop
                    tree(i) <= join(tree(2 * i), tree(2 * i + 1));
                end loop;

                -- P5
                root := tree(1);
                in_v := '0';
                if valid = '1' and root.s = '1' and root.f /= NEG_INF and root.f <= root.b then
                    in_v := '1';
                end if;
                in_reg   <= in_v;
                face_reg <= root.fi;
                bf_reg   <= root.bi;
                if to_integer(root.fi) < FACES then
                    rgb_reg <= rgb_t(to_integer(root.fi));
                end if;

                -- dx、dy 延遲到 H2、H3（純位移，綜合成 SRL）
                dx_p(1) <= dx;
                dy_p(1) <= dy;
                for i in 2 to D_LAT + 1 loop
                    dx_p(i) <= dx_p(i - 1);
                    dy_p(i) <= dy_p(i - 1);
                end loop;

                -- H1
                o_p(1) <= (in_reg, face_reg, bf_reg, rgb_reg);
                if to_integer(face_reg) < FACES then
                    f_ux <= ux_t(to_integer(face_reg));
                    f_uy <= uy_t(to_integer(face_reg));
                    f_vx <= vx_t(to_integer(face_reg));
                    f_vy <= vy_t(to_integer(face_reg));
                    f_u0 <= u0_t(to_integer(face_reg));
                    f_v0 <= v0_t(to_integer(face_reg));
                end if;
                if to_integer(bf_reg) < FACES then
                    b_ux <= ux_t(to_integer(bf_reg));
                    b_uy <= uy_t(to_integer(bf_reg));
                    b_vx <= vx_t(to_integer(bf_reg));
                    b_vy <= vy_t(to_integer(bf_reg));
                    b_u0 <= u0_t(to_integer(bf_reg));
                    b_v0 <= v0_t(to_integer(bf_reg));
                end if;

                -- H2
                o_p(2) <= o_p(1);
                pu_f  <= resize(f_ux * dx_p(D_LAT), 40) + resize(f_u0, 40);
                pv_f  <= resize(f_vx * dx_p(D_LAT), 40) + resize(f_v0, 40);
                pu_b  <= resize(b_ux * dx_p(D_LAT), 40) + resize(b_u0, 40);
                pv_b  <= resize(b_vx * dx_p(D_LAT), 40) + resize(b_v0, 40);
                f_uy2 <= f_uy;
                f_vy2 <= f_vy;
                b_uy2 <= b_uy;
                b_vy2 <= b_vy;

                -- H3
                o_p(3) <= o_p(2);
                u_f <= resize(f_uy2 * dy_p(D_LAT + 1), 40) + pu_f;
                v_f <= resize(f_vy2 * dy_p(D_LAT + 1), 40) + pv_f;
                u_b <= resize(b_uy2 * dy_p(D_LAT + 1), 40) + pu_b;
                v_b <= resize(b_vy2 * dy_p(D_LAT + 1), 40) + pv_b;

                -- H4
                o_p(4) <= o_p(3);
                kf := "0" & to_unsigned(SEED, 2) & o_p(3).face;
                kb := "1" & to_unsigned(SEED, 2) & o_p(3).bface;
                dotf_reg <= o_p(3).inside and dot_hit(u_f, v_f, kf);
                dotb_reg <= o_p(3).inside and dot_hit(u_b, v_b, kb);
            end if;
        end if;
    end process;

    inside <= o_p(4).inside;
    face   <= o_p(4).face;
    bface  <= o_p(4).bface;
    rgb    <= o_p(4).rgb;
    dot_f  <= dotf_reg;
    dot_b  <= dotb_reg;

end Behavioral;
