library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
use STD.TEXTIO.ALL;

-- HW3 VGA 掃描自我檢查測試檔（對應 SPEC.md 第 9 節）
--   以真實的 640×480@60 參數跑數幀：檢查 hs / vs 時序、基本模式的 RGB 色塊、
--   切換到旋轉多面體後，每個像素看到的面與浮點數光線投射的參考模型比對，並檢查樣式、HDMI 輸出與暫停
--   EGO-XZ7 沒有 VGA 接頭，HW_3 的 VGA 埠已註解掉；VGA 相關的檢查標 [VGA]，接回 VGA 時一起取消註解
--   畫面從 RGB888 視訊串流擷取（VHDL-2008 external name），存成 PPM 圖檔，可直接打開看
--   HDMI：24 bit 輸出逐像素等於串流，像素時脈的週期與相位正確；ADV7511 模型收下 I2C 設定並檢查暫存器值
--   本檔需以 VHDL 2008 編譯；全程約 9 幀（約 150 ms 模擬時間），結束時印出 PASS / FAIL
entity HW_3_tb is
    Generic (
        OUT_DIR : string := ""                  -- PPM 輸出目錄（含結尾斜線），空字串為模擬工作目錄
    );
end HW_3_tb;

architecture Behavioral of HW_3_tb is

    constant T        : time     := 10 ns;
    constant PIX_DIV  : positive := 4;
    constant H_ACTIVE : positive := 640;
    constant H_SYNC   : positive := 96;
    constant H_TOTAL  : positive := 800;
    constant V_ACTIVE : positive := 480;
    constant V_SYNC   : positive := 2;
    constant V_TOTAL  : positive := 525;
    constant DB       : positive := 16;         -- 去彈跳 clk 數
    constant TP       : time     := PIX_DIV * T; -- 一個像素
    constant NPIX     : positive := H_ACTIVE * V_ACTIVE;

    -- 與設計相同的形狀設定
    constant SHAPES : positive := 3;
    type int_arr_t is array (0 to SHAPES - 1) of integer;
    type rgb_arr_t is array (0 to SHAPES - 1) of std_logic_vector(23 downto 0);
    constant SOLID_A : int_arr_t := (0, 1, 2);
    constant FACES_A : int_arr_t := (6, 8, 12);
    constant SPIN_X_A : int_arr_t := (2, 3, -1);
    constant SPIN_Y_A : int_arr_t := (3, -2, 2);
    constant CX_A    : int_arr_t := (H_ACTIVE / 6, H_ACTIVE / 2, 5 * H_ACTIVE / 6);
    constant CY      : integer   := V_ACTIVE / 2;
    constant RADIUS  : integer   := H_ACTIVE * 5 / 32;
    constant EDGE_C  : std_logic_vector(23 downto 0) := x"FFFFFF";
    constant BG_C    : std_logic_vector(23 downto 0) := x"000000";
    constant BLK_C   : rgb_arr_t := (x"FF0000", x"00FF00", x"0000FF");
    constant BLK_PIX : int_arr_t := (214 * 480, 212 * 480, 214 * 480);   -- 預設色塊：畫面直切三等分，加起來是整個畫面
    constant ANG_ONE : real      := 1024.0;     -- 一圈的角度步數（ANGLE_BITS = 10）


    -- xsim 2018.3 不支援 VHDL-2008 的 to_string
    function to_str(v : std_logic_vector) return string is
        variable s : string(1 to v'length);
        variable k : natural := 1;
    begin
        for i in v'range loop
            if v(i) = '1' then s(k) := '1'; else s(k) := '0'; end if;
            k := k + 1;
        end loop;
        return s;
    end function;

    --------------------------------------------------
    -- 參考模型：以浮點數重新推一次多面體，與設計的定點管線無關
    --------------------------------------------------
    constant PHI : real := (1.0 + sqrt(5.0)) / 2.0;
    type vec3_t is array (0 to 2) of real;

    function bit_sign(k, b : natural) return real is
    begin
        if (k / 2**b) mod 2 = 0 then return 1.0; else return -1.0; end if;
    end function;

    function cyc(g : natural; p, q : real) return vec3_t is
        variable tt, v : vec3_t;
    begin
        tt := (0.0, p, q);
        for j in 0 to 2 loop
            v(j) := tt((j + g) mod 3);
        end loop;
        return v;
    end function;

    function base_normal(sol, k : natural) return vec3_t is
        variable v : vec3_t := (0.0, 0.0, 0.0);
    begin
        case sol is
            when 0 => v(k / 2) := bit_sign(k, 0);
            when 1 => v := (bit_sign(k, 0), bit_sign(k, 1), bit_sign(k, 2));
            when 2 => v := cyc(k / 4, bit_sign(k, 0), bit_sign(k, 1) * PHI);
            when others =>
                if k < 8 then
                    v := (bit_sign(k, 0), bit_sign(k, 1), bit_sign(k, 2));
                else
                    v := cyc((k - 8) / 4, bit_sign(k, 0) / PHI, bit_sign(k, 1) * PHI);
                end if;
        end case;
        return v;
    end function;

    function in_ratio(sol : natural) return real is
    begin
        if sol <= 1 then return 1.0 / sqrt(3.0); else return sqrt((5.0 + 2.0 * sqrt(5.0)) / 15.0); end if;
    end function;

    -- 繞 y 轉 b、再繞 x 轉 a
    function rot(v : vec3_t; a, b : real) return vec3_t is
        variable r      : vec3_t;
        variable y1, z1 : real;
    begin
        r(0) := cos(b) * v(0) + sin(b) * v(2);
        y1   := v(1);
        z1   := cos(b) * v(2) - sin(b) * v(0);
        r(1) := cos(a) * y1 - sin(a) * z1;
        r(2) := sin(a) * y1 + cos(a) * z1;
        return r;
    end function;

    type normals_t is array (0 to 19) of vec3_t;

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

    -- which = 0 法向量；1、2 為面上的切向量 t1 = n × ref、t2 = n × t1（與設計相同的取法）
    --   先套初始傾斜 Rx(30°)·Ry(40°)，再套 Rx(α)·Ry(β)
    function ref_vecs(sol, nf, which : natural; a, b : real) return normals_t is
        variable n      : normals_t;
        variable v, r   : vec3_t;
        variable t1     : vec3_t;
    begin
        for k in 0 to nf - 1 loop
            v := unit(base_normal(sol, k));
            if which > 0 then
                if abs v(1) < 0.9 then r := (0.0, 1.0, 0.0); else r := (1.0, 0.0, 0.0); end if;
                t1 := unit(cross(v, r));
                if which = 1 then v := t1; else v := cross(v, t1); end if;
            end if;
            n(k) := rot(rot(v, MATH_PI / 6.0, MATH_PI * 2.0 / 9.0), a, b);
        end loop;
        return n;
    end function;

    function ref_normals(sol, nf : natural; a, b : real) return normals_t is
    begin
        return ref_vecs(sol, nf, 0, a, b);
    end function;

    -- 光線 (dx, dy, z) 穿過多面體時的進入面 fi、離開面 bi 與兩個深度；不在形狀內時 fi = -1
    procedure ref_hits(n : normals_t; nf : natural; ap : real; dx, dy : real;
                       fi, bi : out integer; zf, zb : out real) is
        variable f, bk   : integer := -1;
        variable zmin    : real    := 1.0e30;
        variable zmax    : real    := -1.0e30;
        variable r, z    : real;
    begin
        fi := -1;
        bi := -1;
        zf := 0.0;
        zb := 0.0;
        for k in 0 to nf - 1 loop
            r := ap - n(k)(0) * dx - n(k)(1) * dy;
            if abs n(k)(2) < 1.0 / 256.0 then
                if r < 0.0 then
                    return;
                end if;
            else
                z := r / n(k)(2);
                if n(k)(2) < 0.0 then
                    if z > zmax then zmax := z; f := k; end if;
                elsif z < zmin then
                    zmin := z;
                    bk   := k;
                end if;
            end if;
        end loop;
        if f >= 0 and bk >= 0 and zmax <= zmin then
            fi := f;
            bi := bk;
            zf := zmax;
            zb := zmin;
        end if;
    end procedure;

    -- 點雲雜湊（與設計相同的位元運算）
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

    -- 面座標 (u, v)（像素）是否落在點上：格子 8 像素、位置以 1/4 像素計
    function ref_hit(u, v : real; key_hi : natural) return boolean is
        variable uq, vq : integer;
        variable h      : unsigned(23 downto 0);
        variable pu, pv : integer;
    begin
        uq := integer(floor(u * 4.0));
        vq := integer(floor(v * 4.0));
        -- 格子編號用 floor 除法（VHDL 的 / 向 0 取整，負數會差一格），取低 8 位元
        h  := mix(to_unsigned(key_hi, 8) &
                  to_unsigned(integer(floor(real(vq) / 32.0)) mod 256, 8) &
                  to_unsigned(integer(floor(real(uq) / 32.0)) mod 256, 8));
        pu := 9 + 2 * to_integer(h(10 downto 8));
        pv := 9 + 2 * to_integer(h(13 downto 11));
        return to_integer(h(7 downto 0)) < 192 and abs ((uq mod 32) - pu) <= 2 and abs ((vq mod 32) - pv) <= 2;
    end function;

    -- 光線 (dx, dy, z)：回傳看到的面編號，不在形狀內回傳 -1
    function ref_face(n : normals_t; nf : natural; ap : real; dx, dy : real) return integer is
        variable zf   : real    := -1.0e30;
        variable zb   : real    := 1.0e30;
        variable fi   : integer := -1;
        variable r, z : real;
    begin
        for k in 0 to nf - 1 loop
            r := ap - n(k)(0) * dx - n(k)(1) * dy;
            if abs n(k)(2) < 1.0 / 256.0 then
                if r < 0.0 then
                    return -1;
                end if;
            else
                z := r / n(k)(2);
                if n(k)(2) < 0.0 then
                    if z > zf then
                        zf := z;
                        fi := k;
                    end if;
                elsif z < zb then
                    zb := z;
                end if;
            end if;
        end loop;
        if fi >= 0 and zf <= zb then
            return fi;
        end if;
        return -1;
    end function;

    signal clk       : std_logic := '0';
    signal reset     : std_logic := '1';
    signal btn_mode  : std_logic := '0';
    signal sw_pause  : std_logic := '0';
    signal btn_speed : std_logic := '0';
    signal btn_dir   : std_logic := '0';
    signal btn_style : std_logic := '0';
    -- [VGA] signal vga_r     : std_logic_vector(0 downto 0);
    -- [VGA] signal vga_g     : std_logic_vector(0 downto 0);
    -- [VGA] signal vga_b     : std_logic_vector(0 downto 0);
    -- [VGA] signal vga_hs    : std_logic;
    -- [VGA] signal vga_vs    : std_logic;
    signal led       : std_logic_vector(7 downto 0);
    signal hdmi_clk  : std_logic;
    signal hdmi_d    : std_logic_vector(23 downto 0);
    signal hdmi_hs   : std_logic;
    signal hdmi_vs   : std_logic;
    signal hdmi_scl  : std_logic;
    signal hdmi_sda  : std_logic;
    signal sda_ack   : std_logic := 'Z';         -- ADV7511 模型拉低 SDA 回 ACK
    signal done      : boolean := false;
    signal sync_err  : natural := 0;
    signal ang_x     : int_arr_t := (others => 0);   -- 角度模型（步數，一圈 1024）
    signal ang_y     : int_arr_t := (others => 0);

    -- HDMI 輸出級的參考模型：RGB -> YCbCr（BT.709、有限範圍，係數 × 256），4:2:2 時偶數像素送 Cb、奇數送 Cr
    --   回傳腳位上的 24 bit：D23..16 = Cb / Cr、D15..8 = Y、D7..0 = 0
    function ycc422(pix : std_logic_vector(23 downto 0); odd : boolean) return std_logic_vector is
        variable r, g, b, y, c : natural;
    begin
        r := to_integer(unsigned(pix(23 downto 16)));
        g := to_integer(unsigned(pix(15 downto 8)));
        b := to_integer(unsigned(pix(7 downto 0)));
        y := (4224 + 47 * r + 157 * g + 16 * b) / 256;
        if odd then
            c := (32896 + 112 * r - 102 * g - 10 * b) / 256;
        else
            c := (32896 - 26 * r - 87 * g + 112 * b) / 256;
        end if;
        return std_logic_vector(to_unsigned(c, 8)) & std_logic_vector(to_unsigned(y, 8)) & x"00";
    end function;

    constant CFG_DELAY : positive := 1000;       -- ADV7511 每輪設定前等待的 clk 數（縮短，省模擬時間）
    type reg_map_t is array (0 to 255) of integer range -1 to 255;
    signal adv_reg   : reg_map_t := (others => -1);   -- ADV7511 模型收到的暫存器值，-1 = 沒寫過
    signal i2c_n     : natural := 0;             -- 收到的寫入筆數
    signal i2c_err   : natural := 0;             -- 裝置位址不對
    signal hclk_n    : natural := 0;             -- 檢查過的像素時脈上升緣
    signal hclk_err  : natural := 0;             -- 週期或 setup / hold 不對

begin

    dut : entity work.HW_3
        generic map (PIX_DIV => PIX_DIV, DEBOUNCE_CYCLES => DB, HDMI_CFG_DELAY => CFG_DELAY)
        port map (
            clk => clk, reset => reset,
            btn_mode => btn_mode, sw_pause => sw_pause,
            btn_speed => btn_speed, btn_dir => btn_dir, btn_style => btn_style,
            -- [VGA] vga_r => vga_r, vga_g => vga_g, vga_b => vga_b, vga_hs => vga_hs, vga_vs => vga_vs,
            hdmi_clk => hdmi_clk, hdmi_d => hdmi_d, hdmi_hs => hdmi_hs, hdmi_vs => hdmi_vs,
            hdmi_scl => hdmi_scl, hdmi_sda => hdmi_sda,
            led => led
        );

    clk <= not clk after T / 2 when not done;

    -- I2C 上拉
    hdmi_scl <= 'H';
    hdmi_sda <= 'H';
    hdmi_sda <= sda_ack;


    --------------------------------------------------
    -- ADV7511 模型（I2C 從端）：START 後收 3 個 byte，每個 byte 回 ACK，
    --   位址為 0x72（0x39 + 寫入）時記下暫存器值
    --------------------------------------------------
    adv_model : process
        variable sr   : std_logic_vector(23 downto 0);
        variable errs : natural := 0;
        variable n    : natural := 0;
    begin
        loop
            wait until (falling_edge(hdmi_sda) and to_x01(hdmi_scl) = '1') or done;
            exit when done;
            for nb in 0 to 2 loop
                for i in 7 downto 0 loop
                    wait until rising_edge(hdmi_scl);
                    sr := sr(22 downto 0) & to_x01(hdmi_sda);
                end loop;
                wait until falling_edge(hdmi_scl);
                sda_ack <= '0';
                wait until falling_edge(hdmi_scl);
                sda_ack <= 'Z';
            end loop;
            if sr(23 downto 16) /= x"72" then
                errs := errs + 1;
            else
                adv_reg(to_integer(unsigned(sr(15 downto 8)))) <= to_integer(unsigned(sr(7 downto 0)));
            end if;
            n := n + 1;
            i2c_n   <= n;
            i2c_err <= errs;
        end loop;
        wait;
    end process;


    --------------------------------------------------
    -- HDMI 像素時脈：週期 = 一個像素；上升緣前後 TP / 4 內資料與同步不變
    --------------------------------------------------
    hdmi_chk : process
        variable last_rise : time := 0 ns;
        variable errs, n   : natural := 0;
    begin
        wait until reset = '0';
        loop
            wait until rising_edge(hdmi_clk) or done;
            exit when done;
            if n > 0 and now - last_rise /= TP then
                errs := errs + 1;
            end if;
            last_rise := now;
            if hdmi_d'last_event < TP / 4 or hdmi_hs'last_event < TP / 4 or hdmi_vs'last_event < TP / 4 then
                errs := errs + 1;
            end if;
            -- [VGA] if hdmi_hs /= vga_hs or hdmi_vs /= vga_vs then
                -- [VGA] errs := errs + 1;
            -- [VGA] end if;
            wait for TP / 4;
            if hdmi_d'last_event < TP / 4 or hdmi_hs'last_event < TP / 4 or hdmi_vs'last_event < TP / 4 then
                errs := errs + 1;
            end if;
            n := n + 1;
            hclk_n   <= n;
            hclk_err <= errs;
        end loop;
        wait;
    end process;


    --------------------------------------------------
    -- 同步時序：HDMI 的 hs / vs 為負極性，檢查脈波寬度與週期
    --------------------------------------------------
    sync_chk : process
        variable hs_fall, vs_fall : time := 0 ns;
        variable hs_seen, vs_seen : boolean := false;
        variable errs             : natural := 0;
    begin
        wait until reset = '0';
        loop
            wait until falling_edge(hdmi_hs) or rising_edge(hdmi_hs) or
                       falling_edge(hdmi_vs) or rising_edge(hdmi_vs) or done;
            exit when done;

            if falling_edge(hdmi_hs) then
                if hs_seen and now - hs_fall /= H_TOTAL * TP then
                    report "hsync period " & time'image(now - hs_fall) severity error;
                    errs := errs + 1;
                end if;
                hs_fall := now;
                hs_seen := true;
            elsif rising_edge(hdmi_hs) and hs_seen then
                if now - hs_fall /= H_SYNC * TP then
                    report "hsync width " & time'image(now - hs_fall) severity error;
                    errs := errs + 1;
                end if;
            end if;

            if falling_edge(hdmi_vs) then
                if vs_seen and now - vs_fall /= V_TOTAL * H_TOTAL * TP then
                    report "vsync period " & time'image(now - vs_fall) severity error;
                    errs := errs + 1;
                end if;
                vs_fall := now;
                vs_seen := true;
            elsif rising_edge(hdmi_vs) and vs_seen then
                if now - vs_fall /= V_SYNC * H_TOTAL * TP then
                    report "vsync width " & time'image(now - vs_fall) severity error;
                    errs := errs + 1;
                end if;
            end if;

            sync_err <= errs;
        end loop;
        wait;
    end process;


    --------------------------------------------------
    -- 角度模型：依 SPEC §6.2 自己累加角度，給參考模型用
    --   只讀 top 層的設定與 frame_tick；xsim 2018.3 的 external name 進不了 for-generate 的第 1、2 個實例
    --------------------------------------------------
    ang_model : process
        alias frame_tick is << signal .HW_3_tb.dut.frame_tick : std_logic >>;
        alias running    is << signal .HW_3_tb.dut.running    : std_logic >>;
        alias dir        is << signal .HW_3_tb.dut.dir        : std_logic >>;
        alias speed_sel  is << signal .HW_3_tb.dut.speed_sel  : unsigned(1 downto 0) >>;
        variable step : integer;
    begin
        wait until rising_edge(clk);
        if reset = '1' then
            ang_x <= (others => 0);
            ang_y <= (others => 0);
        elsif frame_tick = '1' and running = '1' then
            for k in 0 to SHAPES - 1 loop
                step := 2**to_integer(speed_sel);
                if dir = '1' then
                    step := -step;
                end if;
                ang_x(k) <= (ang_x(k) + SPIN_X_A(k) * step) mod 1024;
                ang_y(k) <= (ang_y(k) + SPIN_Y_A(k) * step) mod 1024;
            end loop;
        end if;
    end process;


    --------------------------------------------------
    -- 主流程
    --------------------------------------------------
    stim : process
        alias stream_rgb   is << signal .HW_3_tb.dut.stream_rgb   : std_logic_vector(23 downto 0) >>;
        alias stream_label is << signal .HW_3_tb.dut.stream_label : std_logic_vector(7 downto 0) >>;
        alias stream_de    is << signal .HW_3_tb.dut.stream_de    : std_logic >>;
        alias stream_vs    is << signal .HW_3_tb.dut.stream_vs    : std_logic >>;
        alias pix_ce       is << signal .HW_3_tb.dut.pix_ce       : std_logic >>;

        type cnt_arr_t  is array (0 to SHAPES - 1) of natural;
        type real_arr_t is array (0 to SHAPES - 1) of real;
        type label_buf_t is array (0 to NPIX - 1) of natural range 0 to 255;

        variable errors  : natural := 0;
        variable labels  : label_buf_t;
        variable pcls    : label_buf_t;        -- 0 背景、1 純色（點雲的點或背面虛線）、2 稜線白、3 其他
        variable ref_f   : label_buf_t;        -- 參考模型的正面 / 背面標籤與點
        variable ref_b   : label_buf_t;
        variable ref_d   : label_buf_t;
        variable n_shade : natural;            -- 全息樣式下不該出現的顏色（打光的中間色）
        variable area    : cnt_arr_t;          -- 每個形狀標籤為「在形狀內」的像素數
        variable nfaces  : cnt_arr_t;          -- 看得到幾個面
        variable blk     : cnt_arr_t;
        variable n_edge  : natural;            -- 稜線色像素
        variable n_extra : natural;            -- 既不是稜線也不是背景，且不在任何形狀內
        variable n_wire  : natural;            -- 不是稜線也不是背景色
        -- [VGA] variable n_vga   : natural;            -- VGA 輸出與串流的高位元不符
        variable n_hdmi  : natural;            -- HDMI 的 24 bit 輸出與串流不符
        variable hash    : natural;
        variable hash0   : natural;
        variable ax, ay  : real_arr_t;         -- 擷取的那一幀用的角度（弧度）

        procedure press(signal b : out std_logic) is
        begin
            b <= '1';
            wait for 4 * DB * T;
            b <= '0';
            wait for 4 * DB * T;
        end procedure;

        -- 擷取下一個完整畫面：記下每個像素的標籤、統計顏色、檢查 HDMI 輸出，需要時存成 PPM
        --   rgb 是 RGB888 視訊串流，hdmi 是實際送給 ADV7511 的亮度 Y（灰階）
        procedure capture(name : string; save : boolean) is
            file     f, fv     : text;
            variable l, lv     : line;
            variable pix       : std_logic_vector(23 downto 0);
            variable lab       : natural;
            variable n         : natural := 0;
            -- [VGA] variable want      : std_logic_vector(2 downto 0);   -- 上一個 ce 讀到的像素的各色高位元
            variable want_ycc  : std_logic_vector(23 downto 0);  -- 上一個 ce 讀到的像素該有的 HDMI 輸出
            variable want_ycc2 : std_logic_vector(23 downto 0);  -- 再上一個 ce 的（HDMI 比串流晚兩個 ce）
            variable pend2     : boolean := false;
            -- [VGA] variable got       : std_logic_vector(2 downto 0);
            variable pend      : boolean := false;
            variable nv        : natural := 0;                   -- 已檢查的 HDMI 像素數
            type seen_t is array (0 to SHAPES - 1, 0 to 31) of boolean;
            variable seen      : seen_t := (others => (others => false));
        begin
            area    := (others => 0);
            nfaces  := (others => 0);
            blk     := (others => 0);
            n_edge  := 0;
            n_extra := 0;
            n_wire  := 0;
            n_shade := 0;
            -- [VGA] n_vga   := 0;
            n_hdmi  := 0;
            hash    := 0;
            if save then
                file_open(f, OUT_DIR & name & ".ppm", write_mode);
                file_open(fv, OUT_DIR & name & "_hdmi.ppm", write_mode);
                write(l, string'("P3"));
                writeline(f, l);
                write(l, integer'image(H_ACTIVE) & " " & integer'image(V_ACTIVE));
                writeline(f, l);
                write(l, string'("255"));
                writeline(f, l);
                write(lv, string'("P3"));
                writeline(fv, lv);
                write(lv, integer'image(H_ACTIVE) & " " & integer'image(V_ACTIVE));
                writeline(fv, lv);
                write(lv, string'("255"));
                writeline(fv, lv);
            end if;

            -- 從垂直遮沒結束後開始，確保拿到一整幀；這時角度已是這一幀要用的值
            wait until rising_edge(clk) and stream_vs = '1';
            wait until rising_edge(clk) and stream_vs = '0';
            for k in 0 to SHAPES - 1 loop
                ax(k) := MATH_2_PI * real(ang_x(k)) / ANG_ONE;
                ay(k) := MATH_2_PI * real(ang_y(k)) / ANG_ONE;
            end loop;

            -- HDMI 腳位比串流晚兩個 ce（YCbCr 轉換一拍、輸出暫存器一拍）、VGA 腳位晚一個 ce：
            --   每個 ce 先檢查兩個 ce 之前讀到的像素的 HDMI 輸出（與上一個像素的 VGA 輸出），再讀這個像素
            while n < NPIX or pend or pend2 loop
                wait until rising_edge(clk);
                if pix_ce = '1' then
                    if pend2 then
                        if hdmi_d /= want_ycc2 then
                            n_hdmi := n_hdmi + 1;
                        end if;
                        nv := nv + 1;
                        if save then
                            for c in 0 to 2 loop
                                write(lv, integer'image(to_integer(unsigned(hdmi_d(15 downto 8)))) & " ");
                            end loop;
                            if nv mod H_ACTIVE = 0 then
                                writeline(fv, lv);
                            end if;
                        end if;
                    end if;
                    pend2     := pend;
                    want_ycc2 := want_ycc;
                    -- [VGA] if pend then
                        -- [VGA] got := vga_r(0) & vga_g(0) & vga_b(0);
                        -- [VGA] if got /= want then
                            -- [VGA] n_vga := n_vga + 1;
                        -- [VGA] end if;
                    -- [VGA] end if;
                    pend := false;

                    if stream_de = '1' and n < NPIX then
                        pix := stream_rgb;
                        lab := to_integer(unsigned(stream_label));
                        labels(n) := lab;

                        if lab >= 128 then
                            area((lab / 32) mod 4) := area((lab / 32) mod 4) + 1;
                            seen((lab / 32) mod 4, lab mod 32) := true;
                        end if;
                        for k in 0 to SHAPES - 1 loop
                            if pix = BLK_C(k) then
                                blk(k) := blk(k) + 1;
                            end if;
                        end loop;
                        if pix = EDGE_C then
                            n_edge := n_edge + 1;
                            pcls(n) := 2;
                        elsif pix /= BG_C then
                            n_wire := n_wire + 1;
                            if lab < 128 then
                                n_extra := n_extra + 1;
                            end if;
                            if pix = BLK_C(0) or pix = BLK_C(1) or pix = BLK_C(2) then
                                pcls(n) := 1;
                            else
                                pcls(n) := 3;
                                n_shade := n_shade + 1;
                            end if;
                        else
                            pcls(n) := 0;
                        end if;

                        -- [VGA] want := pix(23) & pix(15) & pix(7);
                        want_ycc := ycc422(pix, (n mod H_ACTIVE) mod 2 = 1);
                        pend := true;

                        hash := (hash * 7 + to_integer(unsigned(pix(23 downto 12))) +
                                 to_integer(unsigned(pix(11 downto 0))) + lab) mod 16777213;
                        if save then
                            write(l, integer'image(to_integer(unsigned(pix(23 downto 16)))) & " " &
                                     integer'image(to_integer(unsigned(pix(15 downto 8)))) & " " &
                                     integer'image(to_integer(unsigned(pix(7 downto 0)))) & " ");
                            if (n + 1) mod H_ACTIVE = 0 then
                                writeline(f, l);
                            end if;
                        end if;
                        n := n + 1;
                    end if;
                end if;
            end loop;

            for k in 0 to SHAPES - 1 loop
                for i in 0 to 31 loop
                    if seen(k, i) then
                        nfaces(k) := nfaces(k) + 1;
                    end if;
                end loop;
            end loop;

            if save then
                file_close(f);
                file_close(fv);
                report "wrote " & OUT_DIR & name & ".ppm / " & name & "_hdmi.ppm";
            end if;
            -- [VGA] if n_vga /= 0 then
                -- [VGA] report name & ": " & integer'image(n_vga) & " VGA pixels differ from the stream's top bits" severity error;
                -- [VGA] errors := errors + 1;
            -- [VGA] end if;
            if n_hdmi /= 0 then
                report name & ": " & integer'image(n_hdmi) & " HDMI pixels differ from the stream" severity error;
                errors := errors + 1;
            end if;
        end procedure;

        -- 每個形狀外接方框內的像素，逐一與參考模型比對看到的面
        --   允許少量不符：只會出現在面與面的交界（定點誤差讓邊界差一個像素）
        procedure check_ref(tag : string) is
            variable n       : normals_t;
            variable ap      : real;
            variable fr, lab : integer;
            variable want    : integer;
            variable ref_a   : natural;
            variable miss    : natural;
        begin
            for k in 0 to SHAPES - 1 loop
                n     := ref_normals(SOLID_A(k), FACES_A(k), ax(k), ay(k));
                ap    := real(RADIUS) * in_ratio(SOLID_A(k));
                ref_a := 0;
                miss  := 0;
                for yy in CY - RADIUS - 2 to CY + RADIUS + 2 loop
                    for xx in CX_A(k) - RADIUS - 2 to CX_A(k) + RADIUS + 2 loop
                        fr  := ref_face(n, FACES_A(k), ap, real(xx - CX_A(k)), real(yy - CY));
                        lab := labels(yy * H_ACTIVE + xx);
                        if fr >= 0 then
                            ref_a := ref_a + 1;
                            want  := 128 + k * 32 + fr;
                        else
                            want  := 0;
                        end if;
                        if lab /= want then
                            miss := miss + 1;
                        end if;
                    end loop;
                end loop;
                report tag & ": shape " & integer'image(k) & " area " & integer'image(area(k)) &
                       " ref " & integer'image(ref_a) & " faces " & integer'image(nfaces(k)) &
                       " mismatched " & integer'image(miss);
                if miss > ref_a / 200 + 10 then
                    report tag & ": shape " & integer'image(k) & " differs from the reference model" severity error;
                    errors := errors + 1;
                end if;
                if nfaces(k) < 2 then
                    report tag & ": shape " & integer'image(k) & " shows fewer than 2 faces" severity error;
                    errors := errors + 1;
                end if;
            end loop;
        end procedure;

        -- 全息點雲：參考模型逐像素算出進入面、離開面與兩個面座標，用同一個雜湊決定點，
        --   再加上背面標籤變化的虛線；正面稜線（白色）的位置不比對
        --   允許少量不符：只會出現在點的邊緣（定點與浮點的面座標差一點點，就會差一個像素）
        procedure check_holo(tag : string) is
            variable nn, t1, t2 : normals_t;
            variable ap         : real;
            variable fi, bi     : integer;
            variable zf, zb     : real;
            variable px, q      : integer;
            variable rf, rb     : boolean;
            variable want, got  : boolean;
            variable n_want     : natural;
            variable n_got      : natural;
            variable miss       : natural;
            function lab(arr : label_buf_t; x, y : integer) return natural is
            begin
                return arr(y * H_ACTIVE + x);
            end function;
        begin
            for k in 0 to SHAPES - 1 loop
                nn := ref_vecs(SOLID_A(k), FACES_A(k), 0, ax(k), ay(k));
                t1 := ref_vecs(SOLID_A(k), FACES_A(k), 1, ax(k), ay(k));
                t2 := ref_vecs(SOLID_A(k), FACES_A(k), 2, ax(k), ay(k));
                ap := real(RADIUS) * in_ratio(SOLID_A(k));
                for yy in CY - RADIUS - 4 to CY + RADIUS + 4 loop
                    for xx in CX_A(k) - RADIUS - 4 to CX_A(k) + RADIUS + 4 loop
                        px := yy * H_ACTIVE + xx;
                        ref_hits(nn, FACES_A(k), ap, real(xx - CX_A(k)), real(yy - CY), fi, bi, zf, zb);
                        if fi < 0 then
                            ref_f(px) := 0;
                            ref_b(px) := 0;
                            ref_d(px) := 0;
                        else
                            ref_f(px) := 128 + k * 32 + fi;
                            ref_b(px) := 128 + k * 32 + bi;
                            rf := ref_hit(t1(fi)(0) * real(xx - CX_A(k)) + t1(fi)(1) * real(yy - CY) + t1(fi)(2) * zf,
                                          t2(fi)(0) * real(xx - CX_A(k)) + t2(fi)(1) * real(yy - CY) + t2(fi)(2) * zf,
                                          k * 32 + fi);
                            rb := ref_hit(t1(bi)(0) * real(xx - CX_A(k)) + t1(bi)(1) * real(yy - CY) + t1(bi)(2) * zb,
                                          t2(bi)(0) * real(xx - CX_A(k)) + t2(bi)(1) * real(yy - CY) + t2(bi)(2) * zb,
                                          128 + k * 32 + bi);
                            if rf or rb then ref_d(px) := 1; else ref_d(px) := 0; end if;
                        end if;
                    end loop;
                end loop;

                n_want := 0;
                n_got  := 0;
                miss   := 0;
                for yy in CY - RADIUS - 2 to CY + RADIUS + 2 loop
                    for xx in CX_A(k) - RADIUS - 2 to CX_A(k) + RADIUS + 2 loop
                        px := yy * H_ACTIVE + xx;
                        q  := ref_f(px);
                        -- 正面稜線：白色，不比對
                        if q /= lab(ref_f, xx - 1, yy) or q /= lab(ref_f, xx - 2, yy) or
                           q /= lab(ref_f, xx, yy - 1) or q /= lab(ref_f, xx, yy - 2) then
                            next;
                        end if;
                        q    := ref_b(px);
                        want := ref_d(px) = 1 or
                                (q >= 128 and (xx + yy) mod 4 < 2 and
                                 (q /= lab(ref_b, xx - 1, yy) or q /= lab(ref_b, xx - 2, yy) or
                                  q /= lab(ref_b, xx, yy - 1) or q /= lab(ref_b, xx, yy - 2)));
                        got  := pcls(px) = 1;
                        if want then n_want := n_want + 1; end if;
                        if got then n_got := n_got + 1; end if;
                        if want /= got then miss := miss + 1; end if;
                    end loop;
                end loop;
                report tag & ": shape " & integer'image(k) & " dots ref " & integer'image(n_want) &
                       " got " & integer'image(n_got) & " mismatched " & integer'image(miss);
                if n_want = 0 or miss > n_want / 10 + 20 then
                    report tag & ": shape " & integer'image(k) & " point cloud differs from the reference model" severity error;
                    errors := errors + 1;
                end if;
            end loop;
        end procedure;

        procedure check_adv(a, v : natural) is
        begin
            if adv_reg(a) /= v then
                report "ADV7511 register " & integer'image(a) & " = " & integer'image(adv_reg(a)) &
                       ", expected " & integer'image(v) severity error;
                errors := errors + 1;
            end if;
        end procedure;

    begin
        wait for 10 * T;
        reset <= '0';

        -- 1. reset 後為基本模式：R、G、B 色塊把畫面直切三等分（214、212、214 × 480），沒有黑色、沒有多面體
        capture("frame_basic", true);
        for k in 0 to SHAPES - 1 loop
            report "basic: block " & integer'image(k) & " pixels " & integer'image(blk(k));
            if blk(k) /= BLK_PIX(k) or area(k) /= 0 then
                report "basic: block " & integer'image(k) & " wrong pixels" severity error;
                errors := errors + 1;
            end if;
        end loop;
        if led(0) /= '0' then
            report "LD0 on in basic mode" severity error;
            errors := errors + 1;
        end if;

        -- 2. 按 BTNU 切到旋轉多面體：每個像素看到的面與參考模型一致，有稜線
        press(btn_mode);
        if led(0) /= '1' then
            report "LD0 off after switching to solids" severity error;
            errors := errors + 1;
        end if;
        capture("frame0", true);
        check_ref("frame0");
        hash0 := hash;
        if n_edge = 0 or n_extra /= 0 then
            report "frame0: " & integer'image(n_edge) & " ridge pixels, " & integer'image(n_extra) &
                   " stray pixels" severity error;
            errors := errors + 1;
        end if;

        -- 3. 下一幀已轉動：畫面不同，仍與參考模型一致
        capture("frame1", false);
        check_ref("frame1");
        if hash = hash0 then
            report "frame1 identical to frame0: not rotating" severity error;
            errors := errors + 1;
        end if;

        -- 4. 轉速 ×8、反轉，LED 反映設定（LD0 模式、LD1 轉動、LD2 反轉、LD4..3 轉速）
        press(btn_speed);
        press(btn_speed);
        press(btn_dir);
        if led(4 downto 0) /= "11111" then
            report "LED settings after speed / dir: " & to_str(led) severity error;
            errors := errors + 1;
        end if;
        capture("frame_fast", true);
        check_ref("fast");

        -- 5. BTND 切到全息點雲：LD5 亮；只有背景、白色稜線與純色的點，點的位置與參考模型一致
        press(btn_style);
        if led(5) /= '1' then
            report "LD5 off after switching to the point cloud" severity error;
            errors := errors + 1;
        end if;
        capture("frame_holo", true);
        check_ref("holo");
        check_holo("holo");
        if n_shade /= 0 or n_edge = 0 then
            report "holo: " & integer'image(n_shade) & " shaded pixels, " & integer'image(n_edge) &
                   " ridge pixels" severity error;
            errors := errors + 1;
        end if;

        -- 6. 再按一次回到實心打光：LD5 熄滅、有稜線
        press(btn_style);
        if led(5) /= '0' then
            report "LD5 still on after switching back to solid" severity error;
            errors := errors + 1;
        end if;
        capture("frame_solid", false);
        check_ref("solid");
        if n_edge = 0 or n_extra /= 0 then
            report "solid: " & integer'image(n_edge) & " ridge pixels, " & integer'image(n_extra) &
                   " stray pixels" severity error;
            errors := errors + 1;
        end if;

        -- 7. SW0 撥上暫停：連續兩幀相同
        sw_pause <= '1';
        wait for 10 * T;
        if led(1) /= '0' then
            report "LD1 still on after pause" severity error;
            errors := errors + 1;
        end if;
        capture("frame_pause_a", false);
        hash0 := hash;
        capture("frame_pause_b", false);
        if hash /= hash0 then
            report "paused frames differ" severity error;
            errors := errors + 1;
        end if;

        errors := errors + sync_err;
        if sync_err /= 0 then
            report integer'image(sync_err) & " sync timing errors" severity error;
        end if;

        -- 8. HDMI：24 bit 輸出已在每次擷取時逐像素比對；這裡檢查像素時脈與 ADV7511 的設定
        report "HDMI: " & integer'image(hclk_n) & " pixel clocks checked, " & integer'image(i2c_n) & " I2C writes";
        if hclk_err /= 0 or hclk_n = 0 then
            report integer'image(hclk_err) & " HDMI pixel clock errors" severity error;
            errors := errors + 1;
        end if;
        if i2c_err /= 0 or i2c_n < 47 then
            report integer'image(i2c_err) & " I2C writes to a wrong address" severity error;
            errors := errors + 1;
        end if;
        check_adv(16#D6#, 16#C0#);           -- HPD 視為一直有接
        check_adv(16#41#, 16#10#);           -- 開啟電源
        check_adv(16#15#, 16#01#);           -- YCbCr 4:2:2、分離同步
        check_adv(16#16#, 16#38#);           -- 輸出 4:4:4、8 bit、輸入樣式 1、RGB
        check_adv(16#48#, 16#08#);           -- 靠右對齊
        check_adv(16#18#, 16#C7#);           -- CSC 開啟、縮放 ×4、A1 高位元
        check_adv(16#1A#, 16#04#);           -- 最後一筆離開更新模式
        check_adv(16#2E#, 16#1B#);           -- C4 = 0x1B77
        check_adv(16#2F#, 16#77#);
        check_adv(16#17#, 16#61#);           -- 同步低電位有效、DE 產生器開啟
        check_adv(16#35#, 16#24#);           -- DE 產生器：hsync 延遲 144 = 0x24 << 2
        check_adv(16#36#, 16#23#);           -- hsync 延遲低 2 位 0、vsync 延遲 35
        check_adv(16#37#, 16#05#);           -- 寬 640 = 0x280：[11:7] = 5
        check_adv(16#38#, 16#00#);           --   [6:0] = 0
        check_adv(16#39#, 16#1E#);           -- 高 480 = 0x1E0：[11:4] = 0x1E
        check_adv(16#3A#, 16#00#);           --   [3:0] = 0
        check_adv(16#AF#, 16#04#);           -- DVI 模式
        if led(6) /= '1' then
            report "LD6 off: ADV7511 configuration not acknowledged" severity error;
            errors := errors + 1;
        end if;

        if errors = 0 then
            report "HW_3_tb PASS";
        else
            report "HW_3_tb FAIL: " & integer'image(errors) & " errors" severity failure;
        end if;
        done <= true;
        wait;
    end process;

end Behavioral;
