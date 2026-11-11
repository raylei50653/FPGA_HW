library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW5 遊戲邏輯測試檔（驗證計畫見 HW5/SPEC.md §13.1）
--   直接例化 HW_5_game，每 4 個 clk 送一個 frame_tick（不用真的掃一幀），按鍵直接驅動 press / held。
--   ref_model 依 SPEC §5、§7 自己算一份遊戲狀態，每幀與 DUT 的輸出逐項比對。
--   前半段是定向測試（reset、球拍、只有發球方能發球、起始球速），後半段兩支球拍自動追球對打，
--   並統計擊球的 8 個 zone、撞牆、加速到上限、左右失分、OVER、重新開局都有出現。
--   spd、vy、to_left 以 VHDL-2008 external name 讀取，需以 VHDL 2008 編譯；最後印出 PASS / FAIL。
entity HW_5_game_tb is
end HW_5_game_tb;

architecture sim of HW_5_game_tb is

    constant T        : time := 10 ns;

    -- DUT generic（縮短 POINT 與閃爍，讓對打時常出現 OVER）
    constant SPEED    : positive := 6;
    constant V_SLOW   : positive := 4;
    constant V_FAST   : positive := 6;
    constant V_STEP   : positive := 2;
    constant V_MAX    : positive := 12;
    constant SP_HITS  : positive := 2;
    constant WIN      : positive := 3;
    constant HALF     : positive := 2;
    constant SHOW     : positive := 8;
    constant N_RALLY  : positive := 30000;    -- 自動對打的幀數

    -- 畫面配置（SPEC §4.1）
    constant PAD_H      : integer := 64;
    constant PAD_Y_MIN  : integer := 8;
    constant PAD_Y_MAX  : integer := 408;
    constant PAD_Y_INIT : integer := 208;
    constant BALL       : integer := 8;
    constant BALL_Y_MIN : integer := 8;
    constant BALL_Y_MAX : integer := 464;
    constant HIT_L_X    : integer := 40;
    constant HIT_R_X    : integer := 592;
    constant OUT_R_X    : integer := 632;

    type int8_t is array (0 to 7) of integer;
    constant BOUNCE_VY : int8_t := (-4, -3, -2, -1, 1, 2, 3, 4);
    type int4_t is array (0 to 3) of integer;
    constant SERVE_VY  : int4_t := (-2, -1, 1, 2);

    signal clk        : std_logic := '0';
    signal reset      : std_logic := '1';
    signal frame_tick : std_logic := '0';
    signal press_l    : std_logic := '0';
    signal press_r    : std_logic := '0';
    signal held_l     : std_logic := '0';
    signal held_r     : std_logic := '0';
    signal sw_speed   : std_logic := '0';

    signal phase      : integer range 0 to 3;
    signal server     : std_logic;
    signal ball_x     : unsigned(9 downto 0);
    signal ball_y     : unsigned(8 downto 0);
    signal pad_l_y    : unsigned(8 downto 0);
    signal pad_r_y    : unsigned(8 downto 0);
    signal score_l    : unsigned(3 downto 0);
    signal score_r    : unsigned(3 downto 0);
    signal blink_on   : std_logic;
    signal heartbeat  : std_logic;

    signal done       : boolean := false;

    -- 參考模型的比對結果與統計（ref_model 寫、stim 讀）
    signal m_errors   : natural := 0;
    signal m_frames   : natural := 0;
    type cnt8_t is array (0 to 7) of natural;
    signal cov_zone   : cnt8_t := (others => 0);
    signal cov_wall   : natural := 0;
    signal cov_speed  : natural := 0;    -- 加速次數
    signal cov_vmax   : natural := 0;    -- spd = VX_MAX 時擊到球
    signal cov_lose_l : natural := 0;
    signal cov_lose_r : natural := 0;
    signal cov_over   : natural := 0;
    signal cov_again  : natural := 0;
    signal cov_coinc  : natural := 0;    -- 和 frame_tick 同一拍的按下事件被處理

begin

    clk <= not clk after T / 2 when not done else '0';

    dut : entity work.HW_5_game
        generic map (
            PADDLE_SPEED => SPEED, VX_SLOW => V_SLOW, VX_FAST => V_FAST, VX_STEP => V_STEP,
            VX_MAX => V_MAX, SPEEDUP_HITS => SP_HITS, WIN_SCORE => WIN,
            BLINK_HALF_FRAMES => HALF, SCORE_SHOW_FRAMES => SHOW)
        port map (
            clk => clk, reset => reset, frame_tick => frame_tick,
            press_l => press_l, press_r => press_r, held_l => held_l, held_r => held_r,
            sw_speed => sw_speed,
            phase => phase, server => server, ball_x => ball_x, ball_y => ball_y,
            pad_l_y => pad_l_y, pad_r_y => pad_r_y, score_l => score_l, score_r => score_r,
            blink_on => blink_on, heartbeat => heartbeat);

    watchdog : process
    begin
        wait for 50 ms;
        assert done report "HW_5_game_tb FAIL: timeout" severity failure;
        wait;
    end process;

    --------------------------------------------------
    -- 參考模型：依 SPEC 逐幀更新，每個 frame_tick 先比對 DUT 的輸出（上一幀的結果），再算這一幀
    --------------------------------------------------
    ref_model : process
        alias d_spd     is << signal .HW_5_game_tb.dut.spd     : integer >>;
        alias d_vy      is << signal .HW_5_game_tb.dut.vy      : integer >>;
        alias d_to_left is << signal .HW_5_game_tb.dut.to_left : std_logic >>;

        variable st, srv, wcnt          : integer;   -- st: 0 SERVE、1 PLAY、2 POINT、3 OVER；srv: 1 = 左
        variable req_l, req_r           : boolean;
        variable any_l, any_r           : boolean;
        variable pl, pr, tl             : integer;   -- 球拍上緣；tl: 1 = 球往左
        variable spd, hits, vy, bx, by  : integer;
        variable sl, sr, bcnt, blink    : integer;
        variable fcnt                   : integer;
        variable nx, ny, vyw, prx, zr   : integer;
        variable zone                   : integer;
        variable over_l, cr, outx       : boolean;
        variable n_st, n_srv            : integer;
        variable errs, frames           : natural := 0;
        variable c_zone                 : cnt8_t := (others => 0);
        variable c_wall, c_speed, c_vmax, c_ll, c_lr, c_over, c_again, c_coinc : natural := 0;

        procedure expect(cond : boolean; msg : string) is
        begin
            if not cond then
                errs := errs + 1;
                if errs <= 20 then
                    report "frame " & integer'image(frames) & ": " & msg severity error;
                end if;
            end if;
        end procedure;

        procedure init is
        begin
            st := 0; srv := 1; wcnt := 0; req_l := false; req_r := false;
            pl := PAD_Y_INIT; pr := PAD_Y_INIT; tl := 0;
            spd := V_SLOW; hits := 0; vy := 0; bx := HIT_L_X; by := PAD_Y_INIT + 28;
            sl := 0; sr := 0; bcnt := 0; blink := 1; fcnt := 0;
        end procedure;

    begin
        init;
        loop
            wait until rising_edge(clk);
            exit when done;
            if reset = '1' then
                init;
            elsif frame_tick = '0' then
                if press_l = '1' then req_l := true; end if;
                if press_r = '1' then req_r := true; end if;
            else
                -- 1. 比對上一幀的結果
                expect(phase = st, "phase " & integer'image(phase) & " /= " & integer'image(st));
                expect((server = '1') = (srv = 1), "server");
                expect(to_integer(ball_x) = bx, "ball_x " & integer'image(to_integer(ball_x)) & " /= " & integer'image(bx));
                expect(to_integer(ball_y) = by, "ball_y " & integer'image(to_integer(ball_y)) & " /= " & integer'image(by));
                expect(to_integer(pad_l_y) = pl, "pad_l_y " & integer'image(to_integer(pad_l_y)) & " /= " & integer'image(pl));
                expect(to_integer(pad_r_y) = pr, "pad_r_y " & integer'image(to_integer(pad_r_y)) & " /= " & integer'image(pr));
                expect(to_integer(score_l) = sl and to_integer(score_r) = sr, "score");
                expect((blink_on = '1') = (blink = 1), "blink_on");
                expect(d_spd = spd, "spd " & integer'image(d_spd) & " /= " & integer'image(spd));
                expect(d_vy = vy, "vy " & integer'image(d_vy) & " /= " & integer'image(vy));
                expect((d_to_left = '1') = (tl = 1), "to_left");
                expect((heartbeat = '1') = ((fcnt / 32) mod 2 = 1), "heartbeat");
                expect(to_integer(ball_x) mod 2 = 0, "ball_x is odd");
                expect(by >= BALL_Y_MIN and by <= BALL_Y_MAX, "ball_y out of the field");
                frames := frames + 1;

                -- 2. 算這一幀（SPEC §5、§7）
                any_l := req_l or press_l = '1';
                any_r := req_r or press_r = '1';
                if (press_l = '1' and not req_l) or (press_r = '1' and not req_r) then
                    if st = 0 or st = 3 then
                        c_coinc := c_coinc + 1;
                    end if;
                end if;
                req_l := false;
                req_r := false;
                n_st  := st;
                n_srv := srv;

                case st is
                    when 0 =>                                       -- SERVE：球黏在發球方球拍
                        if srv = 1 then
                            bx := HIT_L_X; by := pl + 28;
                        else
                            bx := HIT_R_X; by := pr + 28;
                        end if;
                        if (srv = 1 and any_l) or (srv = 0 and any_r) then
                            n_st := 1;
                            tl   := 1 - srv;
                            if sw_speed = '1' then spd := V_FAST; else spd := V_SLOW; end if;
                            vy   := SERVE_VY(fcnt mod 4);
                            hits := 0;
                        end if;

                    when 1 =>                                       -- PLAY
                        if tl = 1 then nx := bx - spd; else nx := bx + spd; end if;
                        ny  := by + vy;
                        vyw := vy;
                        if ny < BALL_Y_MIN then
                            ny := BALL_Y_MIN; vyw := -vy;
                        elsif ny > BALL_Y_MAX then
                            ny := BALL_Y_MAX; vyw := -vy;
                        end if;
                        if tl = 1 then prx := pl; else prx := pr; end if;
                        over_l := ny + BALL > prx and ny < prx + PAD_H;
                        cr     := (tl = 1 and bx >= HIT_L_X and nx < HIT_L_X) or
                                  (tl = 0 and bx <= HIT_R_X and nx > HIT_R_X);
                        outx   := (tl = 1 and nx <= 0) or (tl = 0 and nx >= OUT_R_X);
                        if cr and over_l then                       -- 擊球
                            zr := ny + 4 - prx;
                            if zr < 0 then zone := 0; elsif zr > 63 then zone := 7; else zone := zr / 8; end if;
                            c_zone(zone) := c_zone(zone) + 1;
                            if spd = V_MAX then c_vmax := c_vmax + 1; end if;
                            if tl = 1 then bx := HIT_L_X; else bx := HIT_R_X; end if;
                            by := ny;
                            tl := 1 - tl;
                            vy := BOUNCE_VY(zone);
                            if hits = SP_HITS - 1 then
                                hits := 0;
                                if spd /= V_MAX then c_speed := c_speed + 1; end if;
                                if spd + V_STEP > V_MAX then spd := V_MAX; else spd := spd + V_STEP; end if;
                            else
                                hits := hits + 1;
                            end if;
                        elsif outx then                             -- 漏接
                            if tl = 1 then
                                sr := sr + 1; c_ll := c_ll + 1;
                            else
                                sl := sl + 1; c_lr := c_lr + 1;
                            end if;
                            n_srv := 1 - tl;
                            n_st  := 2;
                        else                                        -- 前進
                            if vyw /= vy then c_wall := c_wall + 1; end if;
                            bx := nx; by := ny; vy := vyw;
                        end if;

                    when 2 =>                                       -- POINT
                        if wcnt = SHOW - 1 then
                            if (srv = 1 and sl = WIN) or (srv = 0 and sr = WIN) then
                                n_st := 3; c_over := c_over + 1;
                            else
                                n_st := 0;
                            end if;
                        else
                            wcnt := wcnt + 1;
                        end if;

                    when others =>                                  -- OVER
                        if any_l or any_r then
                            sl := 0; sr := 0; n_st := 0; c_again := c_again + 1;
                        end if;
                end case;

                -- 閃爍：這一幀開始時在 POINT / OVER 就計數
                if st >= 2 then
                    if bcnt = HALF - 1 then
                        bcnt := 0; blink := 1 - blink;
                    else
                        bcnt := bcnt + 1;
                    end if;
                end if;

                -- 球拍：按住往上、放開往下（SPEC §5.1）
                if held_l = '1' then pl := pl - SPEED; else pl := pl + SPEED; end if;
                if pl < PAD_Y_MIN then pl := PAD_Y_MIN; elsif pl > PAD_Y_MAX then pl := PAD_Y_MAX; end if;
                if held_r = '1' then pr := pr - SPEED; else pr := pr + SPEED; end if;
                if pr < PAD_Y_MIN then pr := PAD_Y_MIN; elsif pr > PAD_Y_MAX then pr := PAD_Y_MAX; end if;

                fcnt := (fcnt + 1) mod 256;
                st   := n_st;
                srv  := n_srv;
                if st /= 2 then wcnt := 0; end if;
                if st <= 1 then bcnt := 0; blink := 1; end if;

                m_errors   <= errs;
                m_frames   <= frames;
                cov_zone   <= c_zone;
                cov_wall   <= c_wall;
                cov_speed  <= c_speed;
                cov_vmax   <= c_vmax;
                cov_lose_l <= c_ll;
                cov_lose_r <= c_lr;
                cov_over   <= c_over;
                cov_again  <= c_again;
                cov_coinc  <= c_coinc;
            end if;
        end loop;
        wait;
    end process;

    --------------------------------------------------
    -- 測試流程
    --------------------------------------------------
    stim : process
        alias d_to_left is << signal .HW_5_game_tb.dut.to_left : std_logic >>;
        alias d_spd     is << signal .HW_5_game_tb.dut.spd     : integer >>;

        variable errors : natural := 0;
        variable seed   : natural := 12345;
        variable aim_l  : integer := 32;     -- 球拍要對準球中心的哪個位置（0 ~ 63）
        variable aim_r  : integer := 32;
        variable lazy   : boolean := false;  -- 這一趟接球方不追球（製造失分）
        variable last_tl: std_logic := '0';
        variable wait_n : integer := 0;
        variable at_l, at_r : integer;
        variable target : integer;
        variable p0     : integer;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                errors := errors + 1;
                report "FAIL: " & msg severity error;
            end if;
        end procedure;

        impure function rnd(n : positive) return natural is
        begin
            seed := (seed * 75 + 74) mod 65537;
            return seed mod n;
        end function;

        -- 一幀 = 4 個 clk，第一個 clk 送 frame_tick；
        --   pl_at / pr_at：按下脈衝放在第幾個 clk（0 = 和 frame_tick 同一拍，−1 = 不按）
        procedure frame(pl_at, pr_at : integer) is
        begin
            for k in 0 to 3 loop
                if k = 0 then frame_tick <= '1'; else frame_tick <= '0'; end if;
                if k = pl_at then press_l <= '1'; else press_l <= '0'; end if;
                if k = pr_at then press_r <= '1'; else press_r <= '0'; end if;
                wait until rising_edge(clk);
                wait for 1 ns;
            end loop;
            frame_tick <= '0';
            press_l    <= '0';
            press_r    <= '0';
        end procedure;

        procedure frames(n : natural) is
        begin
            for i in 1 to n loop
                frame(-1, -1);
            end loop;
        end procedure;

    begin
        wait for 5 * T;
        wait until rising_edge(clk);
        wait for 1 ns;
        reset <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;

        -- 1. Reset：比分 0:0、左發、球拍置中、球黏在左球拍擊球面中央
        check(phase = 0 and server = '1', "reset: SERVE, left serves");
        check(to_integer(pad_l_y) = 208 and to_integer(pad_r_y) = 208, "reset: paddles centered");
        check(to_integer(ball_x) = 40 and to_integer(ball_y) = 236, "reset: ball on the left paddle");
        check(score_l = 0 and score_r = 0, "reset: score 0:0");

        -- 2. 球拍：按住每幀上移 6，停在 8；放開每幀下移 6，停在 408
        held_l <= '1';
        frame(-1, -1);
        check(to_integer(pad_l_y) = 202, "paddle: one frame up = 202");
        frames(40);
        check(to_integer(pad_l_y) = 8, "paddle: stops at the top wall");
        check(to_integer(ball_y) = 8 + 28, "serve: ball follows the left paddle");
        held_l <= '0';
        frames(80);
        check(to_integer(pad_l_y) = 408, "paddle: stops at the bottom wall");
        check(to_integer(pad_r_y) = 408, "paddle: right paddle falls when released");

        -- 3. 只有發球方能發球：右方按下不影響
        held_r <= '1';
        frame(-1, 2);
        held_r <= '0';
        frames(2);
        check(phase = 0, "serve: the receiver cannot serve");

        -- 4. SW0 撥上、左方按下（和 frame_tick 同一拍）：進入 PLAY，起始速度 VX_FAST，球往右
        sw_speed <= '1';
        held_l   <= '1';
        frame(0, -1);
        check(phase = 1, "serve: left press starts PLAY");
        check(d_spd = V_FAST and d_to_left = '0', "serve: VX_FAST toward the right");
        p0 := to_integer(ball_x);
        frame(-1, -1);
        check(to_integer(ball_x) = p0 + V_FAST, "serve: ball moves VX_FAST per frame");
        held_l   <= '0';
        sw_speed <= '0';

        -- 5. 自動對打：接球方的球拍追著球；每 6 趟有一趟不追，製造失分
        for i in 1 to N_RALLY loop
            -- 球拍
            if phase = 1 then
                if d_to_left /= last_tl then             -- 換方向：重新挑對準位置
                    last_tl := d_to_left;
                    aim_l   := rnd(64);
                    aim_r   := rnd(64);
                    lazy    := rnd(6) = 0;
                end if;
                if d_to_left = '1' and not lazy then
                    target := to_integer(ball_y) + 4 - aim_l;
                    if to_integer(pad_l_y) > target then held_l <= '1'; else held_l <= '0'; end if;
                else
                    if rnd(2) = 0 then held_l <= '1'; else held_l <= '0'; end if;
                end if;
                if d_to_left = '0' and not lazy then
                    target := to_integer(ball_y) + 4 - aim_r;
                    if to_integer(pad_r_y) > target then held_r <= '1'; else held_r <= '0'; end if;
                else
                    if rnd(2) = 0 then held_r <= '1'; else held_r <= '0'; end if;
                end if;
            else
                if rnd(2) = 0 then held_l <= '1'; else held_l <= '0'; end if;
                if rnd(2) = 0 then held_r <= '1'; else held_r <= '0'; end if;
            end if;

            -- SW0 偶爾撥動（只在發球時生效）
            if rnd(200) = 0 then
                sw_speed <= not sw_speed;
            end if;

            -- 按鍵：SERVE、OVER 中等幾幀後按下；其他狀態偶爾亂按（應被忽略）
            at_l := -1;
            at_r := -1;
            if phase = 0 or phase = 3 then
                if wait_n = 0 then
                    wait_n := 1 + rnd(20);
                end if;
                wait_n := wait_n - 1;
                if wait_n = 0 then
                    if phase = 3 and rnd(2) = 0 then
                        at_r := rnd(4);
                    elsif phase = 3 or server = '1' then
                        at_l := rnd(4);
                    else
                        at_r := rnd(4);
                    end if;
                elsif rnd(8) = 0 then
                    if server = '1' then at_r := rnd(4); else at_l := rnd(4); end if;   -- 非發球方亂按
                end if;
            elsif rnd(30) = 0 then
                at_l := rnd(4);
            end if;

            frame(at_l, at_r);
        end loop;

        frames(2);
        done <= true;
        wait for 2 * T;

        -- 6. 結果
        report "frames compared " & integer'image(m_frames) & ", model mismatches " & integer'image(m_errors);
        for z in 0 to 7 loop
            report "hits in zone " & integer'image(z) & ": " & integer'image(cov_zone(z));
            check(cov_zone(z) > 0, "coverage: zone " & integer'image(z) & " never hit");
        end loop;
        report "wall bounces " & integer'image(cov_wall) & ", speed-ups " & integer'image(cov_speed) &
               ", hits at VX_MAX " & integer'image(cov_vmax);
        report "left lost " & integer'image(cov_lose_l) & ", right lost " & integer'image(cov_lose_r) &
               ", games over " & integer'image(cov_over) & ", restarts " & integer'image(cov_again) &
               ", presses on frame_tick " & integer'image(cov_coinc);
        check(m_errors = 0, "DUT differs from the reference model");
        check(cov_wall > 0, "coverage: no wall bounce");
        check(cov_speed > 0 and cov_vmax > 0, "coverage: never sped up to VX_MAX");
        check(cov_lose_l > 0 and cov_lose_r > 0, "coverage: both sides must lose a point");
        check(cov_over > 0 and cov_again > 0, "coverage: no game over / restart");
        check(cov_coinc > 0, "coverage: no press on the frame_tick clock");

        if errors = 0 then
            report "HW_5_game_tb PASS";
        else
            report "HW_5_game_tb FAIL: " & integer'image(errors) & " error(s)" severity failure;
        end if;
        wait;
    end process;

end sim;
