library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
use STD.TEXTIO.ALL;

-- HW3 VGA 掃描自我檢查測試檔（對應 SPEC.md 第 9 節）
--   以真實的 640×480@60 參數跑數幀：檢查 hs / vs 時序、基本模式的 RGB 色塊、
--   切換到旋轉圖形後每個形狀的面積、旋轉、樣式與暫停
--   畫面從 RGB888 視訊串流擷取（VHDL-2008 external name），存成 PPM 圖檔，可直接打開看
--   本檔需以 VHDL 2008 編譯；全程約 9 幀（約 150 ms 模擬時間，Vivado 約 1～2 分鐘），結束時印出 PASS / FAIL
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

    -- 與設計相同的形狀設定
    constant SHAPES : positive := 3;
    type int_arr_t is array (0 to SHAPES - 1) of integer;
    type rgb_arr_t is array (0 to SHAPES - 1) of std_logic_vector(23 downto 0);
    constant SIDES_A : int_arr_t := (3, 4, 6);
    constant RADIUS  : real      := real(H_ACTIVE * 9 / 64);
    constant FILL_C  : rgb_arr_t := (x"E04050", x"40C060", x"3070F0");
    constant BLK_C   : rgb_arr_t := (x"FF0000", x"00FF00", x"0000FF");
    constant BLK_PIX : natural   := 160 * 160;  -- 預設色塊大小，三塊互不重疊
    constant EDGE_C  : rgb_arr_t := (x"FFD0D0", x"D0FFD0", x"D0E8FF");

    -- 正 N 邊形面積 = N R² sin(2π/N) / 2
    function poly_area(n : positive) return real is
    begin
        return real(n) * RADIUS * RADIUS * sin(MATH_2_PI / real(n)) / 2.0;
    end function;

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

    signal clk       : std_logic := '0';
    signal reset     : std_logic := '1';
    signal btn_mode  : std_logic := '0';
    signal sw_pause  : std_logic := '0';
    signal btn_speed : std_logic := '0';
    signal btn_dir   : std_logic := '0';
    signal btn_style : std_logic := '0';
    signal vga_r     : std_logic_vector(0 downto 0);
    signal vga_g     : std_logic_vector(0 downto 0);
    signal vga_b     : std_logic_vector(0 downto 0);
    signal vga_hs    : std_logic;
    signal vga_vs    : std_logic;
    signal led       : std_logic_vector(7 downto 0);
    signal done      : boolean := false;
    signal sync_err  : natural := 0;

begin

    dut : entity work.HW_3
        generic map (PIX_DIV => PIX_DIV, DEBOUNCE_CYCLES => DB)
        port map (
            clk => clk, reset => reset,
            btn_mode => btn_mode, sw_pause => sw_pause,
            btn_speed => btn_speed, btn_dir => btn_dir, btn_style => btn_style,
            vga_r => vga_r, vga_g => vga_g, vga_b => vga_b, vga_hs => vga_hs, vga_vs => vga_vs,
            led => led
        );

    clk <= not clk after T / 2 when not done;


    --------------------------------------------------
    -- 同步時序：hs / vs 為負極性，檢查脈波寬度與週期
    --------------------------------------------------
    sync_chk : process
        variable hs_fall, vs_fall : time := 0 ns;
        variable hs_seen, vs_seen : boolean := false;
        variable errs             : natural := 0;
    begin
        wait until reset = '0';
        loop
            wait until falling_edge(vga_hs) or rising_edge(vga_hs) or
                       falling_edge(vga_vs) or rising_edge(vga_vs) or done;
            exit when done;

            if falling_edge(vga_hs) then
                if hs_seen and now - hs_fall /= H_TOTAL * TP then
                    report "hsync period " & time'image(now - hs_fall) severity error;
                    errs := errs + 1;
                end if;
                hs_fall := now;
                hs_seen := true;
            elsif rising_edge(vga_hs) and hs_seen then
                if now - hs_fall /= H_SYNC * TP then
                    report "hsync width " & time'image(now - hs_fall) severity error;
                    errs := errs + 1;
                end if;
            end if;

            if falling_edge(vga_vs) then
                if vs_seen and now - vs_fall /= V_TOTAL * H_TOTAL * TP then
                    report "vsync period " & time'image(now - vs_fall) severity error;
                    errs := errs + 1;
                end if;
                vs_fall := now;
                vs_seen := true;
            elsif rising_edge(vga_vs) and vs_seen then
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
    -- 主流程
    --------------------------------------------------
    stim : process
        alias stream_rgb is << signal .HW_3_tb.dut.stream_rgb : std_logic_vector(23 downto 0) >>;
        alias stream_de  is << signal .HW_3_tb.dut.stream_de  : std_logic >>;
        alias stream_vs  is << signal .HW_3_tb.dut.stream_vs  : std_logic >>;
        alias pix_ce     is << signal .HW_3_tb.dut.pix_ce     : std_logic >>;

        type cnt_arr_t is array (0 to SHAPES - 1) of natural;

        variable errors : natural := 0;
        variable fill   : cnt_arr_t;
        variable edge   : cnt_arr_t;
        variable blk    : cnt_arr_t;
        variable hash   : natural;
        variable hash0  : natural;

        procedure press(signal b : out std_logic) is
        begin
            b <= '1';
            wait for 4 * DB * T;
            b <= '0';
            wait for 4 * DB * T;
        end procedure;

        -- 擷取下一個完整畫面：統計各形狀填色 / 外框像素數、算雜湊，需要時存成 PPM
        procedure capture(name : string; save : boolean) is
            file     f    : text;
            variable l    : line;
            variable pix  : std_logic_vector(23 downto 0);
            variable n    : natural := 0;
        begin
            fill := (others => 0);
            edge := (others => 0);
            blk  := (others => 0);
            hash := 0;
            if save then
                file_open(f, OUT_DIR & name, write_mode);
                write(l, string'("P3"));
                writeline(f, l);
                write(l, integer'image(H_ACTIVE) & " " & integer'image(V_ACTIVE));
                writeline(f, l);
                write(l, string'("255"));
                writeline(f, l);
            end if;

            -- 從垂直遮沒結束後開始，確保拿到一整幀
            wait until rising_edge(clk) and stream_vs = '1';
            wait until rising_edge(clk) and stream_vs = '0';

            while n < H_ACTIVE * V_ACTIVE loop
                wait until rising_edge(clk);
                if pix_ce = '1' and stream_de = '1' then
                    pix := stream_rgb;
                    for k in 0 to SHAPES - 1 loop
                        if pix = FILL_C(k) then
                            fill(k) := fill(k) + 1;
                        elsif pix = EDGE_C(k) then
                            edge(k) := edge(k) + 1;
                        elsif pix = BLK_C(k) then
                            blk(k) := blk(k) + 1;
                        end if;
                    end loop;
                    hash := (hash * 7 + to_integer(unsigned(pix(23 downto 12))) + to_integer(unsigned(pix(11 downto 0)))) mod 16777213;
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
            end loop;

            if save then
                file_close(f);
                report "wrote " & OUT_DIR & name;
            end if;
        end procedure;

        -- 形狀面積（填色 + 外框）與理論值差 3% 以內
        procedure check_area(tag : string) is
            variable got, want : real;
        begin
            for k in 0 to SHAPES - 1 loop
                got  := real(fill(k) + edge(k));
                want := poly_area(SIDES_A(k));
                report tag & ": shape " & integer'image(k) & " fill " & integer'image(fill(k)) &
                       " edge " & integer'image(edge(k)) & " area " & integer'image(integer(want));
                if abs (got - want) > 0.03 * want then
                    report tag & ": shape " & integer'image(k) & " area off" severity error;
                    errors := errors + 1;
                end if;
            end loop;
        end procedure;

    begin
        wait for 10 * T;
        reset <= '0';

        -- 1. reset 後為基本模式：R、G、B 色塊各 160×160，沒有旋轉圖形
        capture("frame_basic.ppm", true);
        for k in 0 to SHAPES - 1 loop
            report "basic: block " & integer'image(k) & " pixels " & integer'image(blk(k));
            if blk(k) /= BLK_PIX or fill(k) /= 0 or edge(k) /= 0 then
                report "basic: block " & integer'image(k) & " wrong pixels" severity error;
                errors := errors + 1;
            end if;
        end loop;
        if led(0) /= '0' then
            report "LD0 on in basic mode" severity error;
            errors := errors + 1;
        end if;

        -- 2. 按 BTNU 切到旋轉圖形：填色 + 外框，面積正確且有外框
        press(btn_mode);
        if led(0) /= '1' then
            report "LD0 off after switching to shapes" severity error;
            errors := errors + 1;
        end if;
        capture("frame0.ppm", true);
        check_area("frame0");
        hash0 := hash;
        for k in 0 to SHAPES - 1 loop
            if edge(k) = 0 or fill(k) = 0 then
                report "frame0: shape " & integer'image(k) & " missing fill or edge" severity error;
                errors := errors + 1;
            end if;
        end loop;

        -- 3. 下一幀已轉動：畫面不同、面積不變
        capture("frame1.ppm", true);
        check_area("frame1");
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
        capture("frame_fast.ppm", true);
        check_area("fast");

        -- 5. 只填色：沒有外框色
        press(btn_style);
        capture("frame_fill.ppm", false);
        check_area("fill-only");
        for k in 0 to SHAPES - 1 loop
            if edge(k) /= 0 then
                report "fill-only: shape " & integer'image(k) & " still has edge pixels" severity error;
                errors := errors + 1;
            end if;
        end loop;

        -- 6. 只有外框：沒有填色
        press(btn_style);
        capture("frame_wire.ppm", true);
        for k in 0 to SHAPES - 1 loop
            if fill(k) /= 0 or edge(k) = 0 then
                report "wireframe: shape " & integer'image(k) & " wrong pixels" severity error;
                errors := errors + 1;
            end if;
        end loop;

        -- 7. SW0 撥上暫停：連續兩幀相同
        sw_pause <= '1';
        wait for 10 * T;
        if led(1) /= '0' then
            report "LD1 still on after pause" severity error;
            errors := errors + 1;
        end if;
        capture("frame_pause_a.ppm", false);
        hash0 := hash;
        capture("frame_pause_b.ppm", false);
        if hash /= hash0 then
            report "paused frames differ" severity error;
            errors := errors + 1;
        end if;

        errors := errors + sync_err;
        if sync_err /= 0 then
            report integer'image(sync_err) & " sync timing errors" severity error;
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
