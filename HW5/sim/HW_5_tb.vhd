library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

-- HW5 HDMI 乒乓球整體測試檔（驗證計畫見 HW5/SPEC.md §14.2）
--   例化 PL 部分 HW_5_pong（PS 與 block design 不模擬，鍵盤狀態 kbd 由測試檔直接給），
--   PIX_DIV = 2（像素輸出與 4 相同，模擬快一倍），去彈跳與 ADV7511 設定等待縮短，跑 3 幀：
--     1. 同步時序：hs 寬 96 像素、週期 800 像素；vs 寬 2 行、週期 525 行（全程）
--     2. 畫面：RGB888 串流的每個可視像素 = 測試檔依 SPEC §4 畫的參考畫面（用 top 層的物件座標與分數）
--     3. 4:2:2：每對像素（偶、奇）顏色相同，也就是物件的 x 邊界都是偶數
--     4. 不撕裂：遊戲座標只在 y >= 480（垂直遮沒）時改變
--     5. 鍵盤與按鈕：按住 W 時左球拍每幀上移、放開就停；按 BTNL 發球進入 PLAY；LD1、LD2 跟著 kbd(6)、kbd(7)
--     6. HDMI：腳位上的 YCbCr 4:2:2 = 串流轉換的結果；像素時脈週期與相位正確
--     7. ADV7511：I2C 從端模型收下設定，檢查重點暫存器；LD6 亮
--   畫面存成 PPM（frame_serve.ppm、frame_play.ppm）。需以 VHDL 2008 編譯，最後印出 PASS / FAIL
entity HW_5_tb is
    Generic (
        OUT_DIR : string := ""                  -- PPM 輸出目錄（含結尾斜線），空字串為模擬工作目錄
    );
end HW_5_tb;

architecture Behavioral of HW_5_tb is

    constant T         : time     := 10 ns;
    constant PIX_DIV   : positive := 2;
    constant TP        : time     := PIX_DIV * T;   -- 一個像素
    constant H_ACTIVE  : positive := 640;
    constant H_SYNC    : positive := 96;
    constant H_TOTAL   : positive := 800;
    constant V_ACTIVE  : positive := 480;
    constant V_SYNC    : positive := 2;
    constant V_TOTAL   : positive := 525;
    constant NPIX      : positive := H_ACTIVE * V_ACTIVE;
    constant DB        : positive := 20;            -- 去彈跳 clk 數
    constant CFG_DELAY : positive := 1000;          -- ADV7511 每輪設定前等待的 clk 數

    subtype rgb_t is std_logic_vector(23 downto 0);

    -- 參考畫面（SPEC §4）：和設計分開寫一次
    type seg_t is array (0 to 9) of std_logic_vector(6 downto 0);
    constant SEG : seg_t := ("0111111", "0000110", "1011011", "1001111", "1100110",
                             "1101101", "1111101", "0000111", "1111111", "1101111");

    function in_rect(x, y, x0, y0, w, h : integer) return boolean is
    begin
        return x >= x0 and x < x0 + w and y >= y0 and y < y0 + h;
    end function;

    -- 七段數字：格子左上角 (cx, cy)，32 × 56，筆畫粗 8
    function digit_hit(x, y, cx, cy, d : integer) return boolean is
        variable m : std_logic_vector(6 downto 0);
    begin
        if d < 0 or d > 9 then
            return false;
        end if;
        m := SEG(d);
        return (m(0) = '1' and in_rect(x, y, cx,      cy,      32, 8))  or   -- a
               (m(1) = '1' and in_rect(x, y, cx + 24, cy,      8,  32)) or   -- b
               (m(2) = '1' and in_rect(x, y, cx + 24, cy + 24, 8,  32)) or   -- c
               (m(3) = '1' and in_rect(x, y, cx,      cy + 48, 32, 8))  or   -- d
               (m(4) = '1' and in_rect(x, y, cx,      cy + 24, 8,  32)) or   -- e
               (m(5) = '1' and in_rect(x, y, cx,      cy,      8,  32)) or   -- f
               (m(6) = '1' and in_rect(x, y, cx,      cy + 24, 32, 8));      -- g
    end function;

    function ref_rgb(x, y, bx, by, pl, pr, sl, sr, ph : integer; srv, blink : std_logic) return rgb_t is
        variable show_l, show_r : boolean;
    begin
        show_l := not (ph >= 2 and srv = '1' and blink = '0');
        show_r := not (ph >= 2 and srv = '0' and blink = '0');
        if ph <= 1 and in_rect(x, y, bx, by, 12, 12) then
            return x"FFFFFF";                                       -- 球
        elsif in_rect(x, y, 32, pl, 12, 96) then
            return x"FF8000";                                       -- 左球拍
        elsif in_rect(x, y, 596, pr, 12, 96) then
            return x"00C0FF";                                       -- 右球拍
        elsif show_l and digit_hit(x, y, 256, 24, sl) then
            return x"FF8000";                                       -- 左分數
        elsif show_r and digit_hit(x, y, 352, 24, sr) then
            return x"00C0FF";                                       -- 右分數
        elsif in_rect(x, y, 318, 8, 4, 464) and (y mod 16) < 8 then
            return x"808080";                                       -- 中線（虛線）
        elsif y < 8 or y >= 472 then
            return x"FFFFFF";                                       -- 上下牆
        else
            return x"000000";
        end if;
    end function;

    -- HDMI 輸出級的參考模型（同 HW3）：RGB -> YCbCr，4:2:2 時偶數像素送 Cb、奇數送 Cr
    function ycc422(pix : rgb_t; odd : boolean) return std_logic_vector is
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

    signal clk       : std_logic := '0';
    signal reset     : std_logic := '1';
    signal btn_l     : std_logic := '0';
    signal btn_r     : std_logic := '0';
    signal sw_speed  : std_logic := '0';
    signal kbd       : std_logic_vector(7 downto 0) := (others => '0');   -- PS 給的按鍵狀態（SPEC §12.3）
    signal led       : std_logic_vector(7 downto 0);
    signal hdmi_clk  : std_logic;
    signal hdmi_d    : std_logic_vector(23 downto 0);
    signal hdmi_hs   : std_logic;
    signal hdmi_vs   : std_logic;
    signal hdmi_scl  : std_logic;
    signal hdmi_sda  : std_logic;
    signal sda_ack   : std_logic := 'Z';            -- ADV7511 模型拉低 SDA 回 ACK

    signal done      : boolean := false;
    signal sync_err  : natural := 0;
    signal tear_err  : natural := 0;
    type reg_map_t is array (0 to 255) of integer range -1 to 255;
    signal adv_reg   : reg_map_t := (others => -1); -- ADV7511 模型收到的暫存器值，-1 = 沒寫過
    signal i2c_n     : natural := 0;
    signal i2c_err   : natural := 0;
    signal hclk_n    : natural := 0;
    signal hclk_err  : natural := 0;

begin

    dut : entity work.HW_5_pong
        generic map (PIX_DIV => PIX_DIV, DEBOUNCE_CYCLES => DB, HDMI_CFG_DELAY => CFG_DELAY)
        port map (
            clk => clk, reset => reset, btn_l => btn_l, btn_r => btn_r, sw_speed => sw_speed, kbd => kbd,
            hdmi_clk => hdmi_clk, hdmi_d => hdmi_d, hdmi_hs => hdmi_hs, hdmi_vs => hdmi_vs,
            hdmi_scl => hdmi_scl, hdmi_sda => hdmi_sda, led => led);

    clk <= not clk after T / 2 when not done;

    -- I2C 上拉
    hdmi_scl <= 'H';
    hdmi_sda <= 'H';
    hdmi_sda <= sda_ack;

    watchdog : process
    begin
        wait for 100 ms;
        assert done report "HW_5_tb FAIL: timeout" severity failure;
        wait;
    end process;

    --------------------------------------------------
    -- ADV7511 模型（I2C 從端，同 HW3）：START 後收 3 個 byte，每個 byte 回 ACK，
    --   位址為 0x72 時記下暫存器值
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
                    errs := errs + 1;
                end if;
                hs_fall := now;
                hs_seen := true;
            elsif rising_edge(hdmi_hs) and hs_seen then
                if now - hs_fall /= H_SYNC * TP then
                    errs := errs + 1;
                end if;
            end if;
            if falling_edge(hdmi_vs) then
                if vs_seen and now - vs_fall /= V_TOTAL * H_TOTAL * TP then
                    errs := errs + 1;
                end if;
                vs_fall := now;
                vs_seen := true;
            elsif rising_edge(hdmi_vs) and vs_seen then
                if now - vs_fall /= V_SYNC * H_TOTAL * TP then
                    errs := errs + 1;
                end if;
            end if;
            sync_err <= errs;
        end loop;
        wait;
    end process;

    --------------------------------------------------
    -- 不撕裂：遊戲輸出只在時序產生器的 y >= 480（垂直遮沒）時改變
    --------------------------------------------------
    tear_chk : process
        alias t_y     is << signal .HW_5_tb.dut.t_y      : unsigned(11 downto 0) >>;
        alias ball_x  is << signal .HW_5_tb.dut.ball_x   : unsigned(9 downto 0) >>;
        alias ball_y  is << signal .HW_5_tb.dut.ball_y   : unsigned(8 downto 0) >>;
        alias pad_l_y is << signal .HW_5_tb.dut.pad_l_y  : unsigned(8 downto 0) >>;
        alias pad_r_y is << signal .HW_5_tb.dut.pad_r_y  : unsigned(8 downto 0) >>;
        alias score_l is << signal .HW_5_tb.dut.score_l  : unsigned(3 downto 0) >>;
        alias score_r is << signal .HW_5_tb.dut.score_r  : unsigned(3 downto 0) >>;
        alias phase   is << signal .HW_5_tb.dut.phase    : integer >>;
        alias blink   is << signal .HW_5_tb.dut.blink_on : std_logic >>;
        variable errs : natural := 0;
    begin
        wait until reset = '0';
        loop
            wait on ball_x, ball_y, pad_l_y, pad_r_y, score_l, score_r, phase, blink, done;
            exit when done;
            if to_integer(t_y) < V_ACTIVE then
                errs := errs + 1;
                report "game outputs changed at y = " & integer'image(to_integer(t_y)) severity error;
            end if;
            tear_err <= errs;
        end loop;
        wait;
    end process;

    --------------------------------------------------
    -- 測試流程
    --------------------------------------------------
    stim : process
        alias pix_ce     is << signal .HW_5_tb.dut.pix_ce     : std_logic >>;
        alias stream_rgb is << signal .HW_5_tb.dut.stream_rgb : std_logic_vector(23 downto 0) >>;
        alias stream_de  is << signal .HW_5_tb.dut.stream_de  : std_logic >>;
        alias stream_vs  is << signal .HW_5_tb.dut.stream_vs  : std_logic >>;
        alias ball_x     is << signal .HW_5_tb.dut.ball_x     : unsigned(9 downto 0) >>;
        alias ball_y     is << signal .HW_5_tb.dut.ball_y     : unsigned(8 downto 0) >>;
        alias pad_l_y    is << signal .HW_5_tb.dut.pad_l_y    : unsigned(8 downto 0) >>;
        alias pad_r_y    is << signal .HW_5_tb.dut.pad_r_y    : unsigned(8 downto 0) >>;
        alias score_l    is << signal .HW_5_tb.dut.score_l    : unsigned(3 downto 0) >>;
        alias score_r    is << signal .HW_5_tb.dut.score_r    : unsigned(3 downto 0) >>;
        alias phase      is << signal .HW_5_tb.dut.phase      : integer >>;
        alias server     is << signal .HW_5_tb.dut.server     : std_logic >>;
        alias blink_on   is << signal .HW_5_tb.dut.blink_on   : std_logic >>;
        alias heartbeat  is << signal .HW_5_tb.dut.heartbeat  : std_logic >>;
        alias hdmi_ok    is << signal .HW_5_tb.dut.hdmi_ok    : std_logic >>;

        variable errors : natural := 0;
        variable pl0    : integer;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                errors := errors + 1;
                report "FAIL: " & msg severity error;
            end if;
        end procedure;

        -- 擷取下一個完整畫面：每個像素比對參考畫面、偶奇像素同色、HDMI 輸出；需要時存成 PPM
        procedure capture(name : string; save : boolean) is
            file     f         : text;
            variable l         : line;
            variable pix, want : rgb_t;
            variable prev      : rgb_t;
            variable n, col, row : natural := 0;
            variable n_ref, n_pair, n_hdmi, n_obj : natural := 0;
            variable want_ycc, want_ycc2 : std_logic_vector(23 downto 0);
            variable pend, pend2 : boolean := false;
        begin
            if save then
                file_open(f, OUT_DIR & name & ".ppm", write_mode);
                write(l, string'("P3"));
                writeline(f, l);
                write(l, integer'image(H_ACTIVE) & " " & integer'image(V_ACTIVE));
                writeline(f, l);
                write(l, string'("255"));
                writeline(f, l);
            end if;

            -- 從垂直同步結束後開始，確保拿到一整幀
            wait until rising_edge(clk) and stream_vs = '1';
            wait until rising_edge(clk) and stream_vs = '0';

            -- HDMI 腳位比串流晚兩個 ce：每個 ce 先檢查兩個 ce 之前讀到的像素，再讀這個像素
            while n < NPIX or pend or pend2 loop
                wait until rising_edge(clk);
                if pix_ce = '1' then
                    if pend2 and hdmi_d /= want_ycc2 then
                        n_hdmi := n_hdmi + 1;
                    end if;
                    pend2     := pend;
                    want_ycc2 := want_ycc;
                    pend      := false;

                    if stream_de = '1' and n < NPIX then
                        col  := n mod H_ACTIVE;
                        row  := n / H_ACTIVE;
                        pix  := stream_rgb;
                        want := ref_rgb(col, row,
                                        to_integer(ball_x), to_integer(ball_y),
                                        to_integer(pad_l_y), to_integer(pad_r_y),
                                        to_integer(score_l), to_integer(score_r),
                                        phase, server, blink_on);
                        if pix /= want then
                            if n_ref < 10 then
                                report name & ": pixel (" & integer'image(col) & ", " & integer'image(row) &
                                       ") differs from the reference" severity error;
                            end if;
                            n_ref := n_ref + 1;
                        end if;
                        if col mod 2 = 1 and pix /= prev then
                            n_pair := n_pair + 1;
                        end if;
                        if pix /= x"000000" then
                            n_obj := n_obj + 1;
                        end if;
                        prev     := pix;
                        want_ycc := ycc422(pix, col mod 2 = 1);
                        pend     := true;
                        if save then
                            write(l, integer'image(to_integer(unsigned(pix(23 downto 16)))) & " " &
                                     integer'image(to_integer(unsigned(pix(15 downto 8)))) & " " &
                                     integer'image(to_integer(unsigned(pix(7 downto 0)))) & " ");
                            if col = H_ACTIVE - 1 then
                                writeline(f, l);
                            end if;
                        end if;
                        n := n + 1;
                    end if;
                end if;
            end loop;

            if save then
                file_close(f);
                report "wrote " & OUT_DIR & name & ".ppm";
            end if;
            report name & ": phase " & integer'image(phase) &
                   ", ball (" & integer'image(to_integer(ball_x)) & ", " & integer'image(to_integer(ball_y)) &
                   "), paddles " & integer'image(to_integer(pad_l_y)) & " / " & integer'image(to_integer(pad_r_y)) &
                   ", lit pixels " & integer'image(n_obj);
            check(n_ref = 0, name & ": " & integer'image(n_ref) & " pixels differ from the reference screen");
            check(n_pair = 0, name & ": " & integer'image(n_pair) & " odd pixels differ from their even neighbor (4:2:2)");
            check(n_hdmi = 0, name & ": " & integer'image(n_hdmi) & " HDMI pixels differ from the YCbCr 4:2:2 model");
            check(n_obj > 0, name & ": blank screen");
        end procedure;

        procedure check_adv(a, v : natural) is
        begin
            check(adv_reg(a) = v, "ADV7511 register " & integer'image(a) & " = " & integer'image(adv_reg(a)) &
                                  ", expected " & integer'image(v));
        end procedure;

    begin
        sw_speed <= '1';
        wait for 10 * T;
        reset <= '0';

        -- 1. SERVE：球黏在左球拍上，沒按鍵時球拍不動
        capture("frame_serve", true);
        check(phase = 0, "first frame should be SERVE");
        check(to_integer(pad_l_y) = 192 and to_integer(pad_r_y) = 192, "paddles should stay put without keys");

        -- 2. 按住 W（kbd(0)）、按 BTNL：下一幀左球拍上移，左方發球進入 PLAY
        pl0    := to_integer(pad_l_y);
        kbd(0) <= '1';
        btn_l  <= '1';
        capture("frame_1", false);
        check(phase = 1, "BTNL should serve");
        check(to_integer(pad_l_y) < pl0, "holding W should move the left paddle up");
        btn_l  <= '0';
        kbd(0) <= '0';
        pl0    := to_integer(pad_l_y);

        -- 3. PLAY：球離開球拍；放開 W 後球拍停住
        capture("frame_play", true);
        check(to_integer(ball_x) > 44, "ball should leave the left paddle");
        check(to_integer(pad_l_y) = pl0, "the left paddle should stop after W is released");
        kbd(6) <= '1';                 -- 鍵盤已連線、PS 心跳
        kbd(7) <= '1';
        wait for 100 * T;

        done <= true;
        wait for 1 us;

        -- 4. 時序、HDMI、ADV7511、LED
        check(sync_err = 0, "sync timing errors: " & integer'image(sync_err));
        check(tear_err = 0, "game outputs changed during the visible area");
        check(hclk_n > 1000 and hclk_err = 0, "HDMI pixel clock errors: " & integer'image(hclk_err));
        check(i2c_n >= 47 and i2c_err = 0, "ADV7511: " & integer'image(i2c_n) & " writes, " &
                                            integer'image(i2c_err) & " with a wrong address");
        check_adv(16#41#, 16#10#);     -- 開啟電源
        check_adv(16#15#, 16#01#);     -- YCbCr 4:2:2 輸入
        check_adv(16#16#, 16#38#);
        check_adv(16#48#, 16#08#);     -- 靠右對齊
        check_adv(16#17#, 16#61#);     -- 同步低電位有效、DE 產生器
        check_adv(16#35#, 16#24#);     -- DE 產生器：hsync 延遲 144、vsync 延遲 35、640 × 480
        check_adv(16#36#, 16#23#);
        check_adv(16#37#, 16#05#);
        check_adv(16#38#, 16#00#);
        check_adv(16#39#, 16#1E#);
        check_adv(16#3A#, 16#00#);
        check_adv(16#AF#, 16#04#);     -- DVI
        check(hdmi_ok = '1' and led(6) = '1', "LD6 should show the ADV7511 configuration succeeded");
        check(led(0) = sw_speed, "LD0 should follow SW0");
        check(led(7) = heartbeat, "LD7 should be the heartbeat");
        check(led(1) = '1' and led(2) = '1', "LD1 / LD2 should follow kbd(6) / kbd(7)");

        if errors = 0 then
            report "HW_5_tb PASS";
        else
            report "HW_5_tb FAIL: " & integer'image(errors) & " error(s)" severity failure;
        end if;
        wait;
    end process;

end Behavioral;
