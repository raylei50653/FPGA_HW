library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW5 遊戲邏輯：狀態機、球與球拍、計分、閃爍（規格見 HW5/SPEC.md §5 ~ §7、§10.3）
--   所有暫存器只在 frame_tick 更新；例外是發球鍵事件 req_l / req_r（隨時鎖存，frame_tick 時清除），
--   它們不直接畫在畫面上。
--   frame_tick 落在每幀的垂直遮沒開頭，畫面合成在整幀可視期間看到的座標都不變。
--
--   ④ 遊戲 FSM      state、server、wait_cnt、req_l、req_r
--   ⑤ 判定          serve、hit、lose、move、again（組合邏輯：這一幀要發生什麼）
--   ⑤ 球與球拍      pad_l_y、pad_r_y、to_left、spd、hits、vy、ball_x、ball_y（每個一個 process）
--   ⑥ 計分與閃爍    score_l、score_r、blink_cnt、blink_on
--
--   座標單位為像素，畫面 640×480；常數見 SPEC §4.1
entity HW_5_game is
    Generic (
        PADDLE_SPEED      : positive := 6;      -- 球拍每幀移動的像素
        VX_SLOW           : positive := 4;      -- SW0 撥下：發球時的水平速度（像素／幀）
        VX_FAST           : positive := 6;      -- SW0 撥上
        VX_STEP           : positive := 2;      -- 每次加速增加的水平速度
        VX_MAX            : positive := 12;     -- 水平速度上限
        SPEEDUP_HITS      : positive := 2;      -- 每回擊幾次加速一階
        WIN_SCORE         : positive := 5;      -- 1 ~ 8
        BLINK_HALF_FRAMES : positive := 30;     -- 閃爍半週期（約 0.5 s）
        SCORE_SHOW_FRAMES : positive := 120     -- POINT 長度（約 2 s）
    );
    Port (
        clk        : in  STD_LOGIC;
        reset      : in  STD_LOGIC;
        frame_tick : in  STD_LOGIC;             -- 每幀一拍，落在垂直遮沒開頭
        press_l    : in  STD_LOGIC;             -- 發球鍵按下瞬間的單拍脈衝（左方：鍵盤 D 或 BTNL）
        press_r    : in  STD_LOGIC;             -- 右方：鍵盤 ← 或 BTNR
        up_l       : in  STD_LOGIC;             -- 已同步的鍵盤電位：W 按住（左球拍往上）
        dn_l       : in  STD_LOGIC;             -- S 按住（左球拍往下）
        up_r       : in  STD_LOGIC;             -- ↑ 按住（右球拍往上）
        dn_r       : in  STD_LOGIC;             -- ↓ 按住（右球拍往下）
        sw_speed   : in  STD_LOGIC;             -- 已同步的 SW0：'1' = 快速發球
        phase      : out integer range 0 to 3;  -- 0 SERVE、1 PLAY、2 POINT、3 OVER
        server     : out STD_LOGIC;             -- '1' = 左方發球；POINT / OVER 中也代表得分方 / 勝方
        ball_x     : out unsigned(9 downto 0);  -- 球左上角
        ball_y     : out unsigned(8 downto 0);
        pad_l_y    : out unsigned(8 downto 0);  -- 球拍上緣
        pad_r_y    : out unsigned(8 downto 0);
        score_l    : out unsigned(3 downto 0);
        score_r    : out unsigned(3 downto 0);
        blink_on   : out STD_LOGIC;             -- POINT / OVER 的 1 Hz 閃爍；SERVE / PLAY 恆為 '1'
        heartbeat  : out STD_LOGIC              -- 每 32 幀翻轉一次
    );
end HW_5_game;

architecture Behavioral of HW_5_game is

    -- 畫面配置（SPEC §4.1）
    constant FIELD_T    : positive := 8;        -- 球場範圍 y 8 ~ 472（上下牆各 8）
    constant FIELD_B    : positive := 472;
    constant PAD_W      : positive := 12;
    constant PAD_H      : positive := 96;
    constant PAD_L_X    : positive := 32;       -- 左球拍 32 ~ 44
    constant PAD_R_X    : positive := 596;      -- 右球拍 596 ~ 608
    constant PAD_Y_MIN  : positive := FIELD_T;
    constant PAD_Y_MAX  : positive := FIELD_B - PAD_H;            -- 376
    constant PAD_Y_INIT : positive := (PAD_Y_MIN + PAD_Y_MAX) / 2; -- 192，置中
    constant BALL       : positive := 12;
    constant BALL_Y_MIN : positive := FIELD_T;
    constant BALL_Y_MAX : positive := FIELD_B - BALL;             -- 460
    constant HIT_L_X    : positive := PAD_L_X + PAD_W;            -- 44：左球拍擊球面（右緣）
    constant HIT_R_X    : positive := PAD_R_X - BALL;             -- 584：右球拍擊球面（左緣）減球寬
    constant OUT_R_X    : positive := 640 - BALL;                 -- 628：球的右緣碰到畫面右邊
    constant SERVE_DY   : positive := (PAD_H - BALL) / 2;         -- 42：發球時球對齊球拍中央
    constant ZONE_H     : positive := PAD_H / 8;                  -- 12：反彈角度每段的高度

    -- 反彈角度：球拍分 8 段，由上到下（SPEC §5.5）；發球的垂直速度（SPEC §5.2）
    type vy_table_t is array (0 to 7) of integer range -4 to 4;
    constant BOUNCE_VY : vy_table_t := (-4, -3, -2, -1, 1, 2, 3, 4);
    type serve_table_t is array (0 to 3) of integer range -4 to 4;
    constant SERVE_VY  : serve_table_t := (-2, -1, 1, 2);

    -- ④ 遊戲 FSM
    type state_t is (S_SERVE, S_PLAY, S_POINT, S_OVER);
    signal state    : state_t := S_SERVE;
    signal srv      : std_logic := '1';
    signal wait_cnt : integer range 0 to SCORE_SHOW_FRAMES - 1 := 0;
    signal req_l    : std_logic := '0';         -- 上一個 frame_tick 之後按過（SPEC §7.1）
    signal req_r    : std_logic := '0';
    signal any_l    : std_logic;                -- 鎖存的或這一拍剛來的按下事件
    signal any_r    : std_logic;

    -- ⑤ 球與球拍
    signal pad_l     : integer range PAD_Y_MIN to PAD_Y_MAX := PAD_Y_INIT;
    signal pad_r     : integer range PAD_Y_MIN to PAD_Y_MAX := PAD_Y_INIT;
    signal to_left   : std_logic := '0';        -- '1' = 球往左，接球方是左玩家
    signal spd       : integer range 0 to VX_MAX := VX_SLOW;
    signal hits      : integer range 0 to SPEEDUP_HITS - 1 := 0;
    signal vy        : integer range -4 to 4 := 0;
    signal bx        : integer range 0 to OUT_R_X := HIT_L_X;
    signal by        : integer range BALL_Y_MIN to BALL_Y_MAX := PAD_Y_INIT + SERVE_DY;
    signal frame_cnt : integer range 0 to 255 := 0;

    -- ⑤ 判定（組合邏輯）
    signal nx        : integer range -64 to 704;              -- 下一個 x（可能越過畫面）
    signal ny_raw    : integer range -16 to 496;              -- 下一個 y（還沒處理撞牆）
    signal ny        : integer range BALL_Y_MIN to BALL_Y_MAX;  -- 撞牆後貼回牆邊
    signal vy_wall   : integer range -4 to 4;                 -- 撞牆後的 vy
    signal pad_rx    : integer range PAD_Y_MIN to PAD_Y_MAX;  -- 接球方球拍
    signal pad_srv   : integer range PAD_Y_MIN to PAD_Y_MAX;  -- 發球方球拍
    signal overlap   : std_logic;                             -- ny 與接球方球拍垂直重疊
    signal cross     : std_logic;                             -- 這一幀穿過接球方擊球面
    signal out_edge  : std_logic;                             -- 這一幀越過接球方那一邊的畫面邊
    signal zone_raw  : integer range -512 to 511;
    signal zone      : integer range 0 to 7;
    signal spd_sel   : integer range VX_SLOW to VX_FAST;      -- SW0 選的起始速度
    signal spd_up    : integer range 0 to VX_MAX;             -- 加速後的速度

    signal serve     : std_logic;   -- SERVE：發球方按下
    signal hit       : std_logic;   -- PLAY：擊到球 → 反向
    signal lose      : std_logic;   -- PLAY：接球方漏接 → 對方得分
    signal move      : std_logic;   -- PLAY：沒擊到也沒漏接 → 球前進
    signal again     : std_logic;   -- OVER：任一鍵重新開局
    signal point_end : std_logic;   -- POINT：顯示時間到

    -- ⑥ 計分與閃爍
    signal sc_l      : integer range 0 to WIN_SCORE := 0;
    signal sc_r      : integer range 0 to WIN_SCORE := 0;
    signal blink_cnt : integer range 0 to BLINK_HALF_FRAMES - 1 := 0;
    signal blink     : std_logic := '1';

begin

    assert VX_SLOW mod 2 = 0 and VX_FAST mod 2 = 0 and VX_STEP mod 2 = 0 and VX_MAX mod 2 = 0
        report "VX_SLOW, VX_FAST, VX_STEP and VX_MAX must be even (ball_x stays even for 4:2:2)"
        severity failure;
    assert VX_SLOW <= VX_FAST and VX_FAST <= VX_MAX and VX_MAX <= 32
        report "Need VX_SLOW <= VX_FAST <= VX_MAX <= 32" severity failure;
    assert PADDLE_SPEED <= PAD_H
        report "PADDLE_SPEED must not exceed the paddle height" severity failure;
    assert WIN_SCORE <= 8
        report "WIN_SCORE must be 1 to 8" severity failure;
    assert SCORE_SHOW_FRAMES mod (2 * BLINK_HALF_FRAMES) = 0
        report "SCORE_SHOW_FRAMES must be a multiple of 2 * BLINK_HALF_FRAMES" severity failure;

    --------------------------------------------------
    -- ④ 按鍵事件鎖存：press 可能出現在任何一拍，留到下一個 frame_tick 處理
    --   和 frame_tick 同一拍來的 press 由 any_* 直接帶進這一幀
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or frame_tick = '1' then
                req_l <= '0';
            elsif press_l = '1' then
                req_l <= '1';
            end if;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or frame_tick = '1' then
                req_r <= '0';
            elsif press_r = '1' then
                req_r <= '1';
            end if;
        end if;
    end process;

    any_l <= req_l or press_l;
    any_r <= req_r or press_r;

    --------------------------------------------------
    -- ⑤ 判定（組合邏輯）：依目前的暫存器算出這一幀要發生什麼（SPEC §7.2）
    --------------------------------------------------
    -- 下一個位置
    nx     <= bx - spd when to_left = '1' else bx + spd;
    ny_raw <= by + vy;

    -- 撞牆：貼回牆邊，垂直方向反向（SPEC §5.3）
    process(ny_raw, vy)
    begin
        if ny_raw < BALL_Y_MIN then
            ny      <= BALL_Y_MIN;
            vy_wall <= -vy;
        elsif ny_raw > BALL_Y_MAX then
            ny      <= BALL_Y_MAX;
            vy_wall <= -vy;
        else
            ny      <= ny_raw;
            vy_wall <= vy;
        end if;
    end process;

    -- 接球方是球正在飛向的那一方；發球方由 srv 決定
    pad_rx  <= pad_l when to_left = '1' else pad_r;
    pad_srv <= pad_l when srv = '1' else pad_r;

    -- 擊球判定：這一幀穿過擊球面，且垂直方向和球拍重疊（SPEC §5.4）
    overlap <= '1' when ny + BALL > pad_rx and ny < pad_rx + PAD_H else '0';
    cross   <= '1' when (to_left = '1' and bx >= HIT_L_X and nx < HIT_L_X) or
                        (to_left = '0' and bx <= HIT_R_X and nx > HIT_R_X) else '0';
    out_edge <= '1' when (to_left = '1' and nx <= 0) or
                         (to_left = '0' and nx >= OUT_R_X) else '0';

    -- 反彈角度：球的中心落在球拍哪一段，ZONE_H（12）像素一段（SPEC §5.5）
    zone_raw <= ny + BALL / 2 - pad_rx;
    zone <= 0 when zone_raw < 1 * ZONE_H else
            1 when zone_raw < 2 * ZONE_H else
            2 when zone_raw < 3 * ZONE_H else
            3 when zone_raw < 4 * ZONE_H else
            4 when zone_raw < 5 * ZONE_H else
            5 when zone_raw < 6 * ZONE_H else
            6 when zone_raw < 7 * ZONE_H else
            7;

    -- 速度（SPEC §5.6）
    spd_sel <= VX_FAST when sw_speed = '1' else VX_SLOW;
    spd_up  <= VX_MAX when spd + VX_STEP > VX_MAX else spd + VX_STEP;

    -- 這一幀的事件：只在 frame_tick 那一拍為 1
    serve     <= '1' when frame_tick = '1' and state = S_SERVE and
                          ((srv = '1' and any_l = '1') or (srv = '0' and any_r = '1')) else '0';
    hit       <= '1' when frame_tick = '1' and state = S_PLAY and cross = '1' and overlap = '1' else '0';
    lose      <= '1' when frame_tick = '1' and state = S_PLAY and hit = '0' and out_edge = '1' else '0';
    move      <= '1' when frame_tick = '1' and state = S_PLAY and hit = '0' and out_edge = '0' else '0';
    again     <= '1' when frame_tick = '1' and state = S_OVER and (any_l = '1' or any_r = '1') else '0';
    point_end <= '1' when frame_tick = '1' and state = S_POINT and wait_cnt = SCORE_SHOW_FRAMES - 1 else '0';

    --------------------------------------------------
    -- ④ 遊戲 FSM：只負責切換狀態，記錄發球方與 POINT 顯示時間
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= S_SERVE;
            elsif serve = '1' then
                state <= S_PLAY;
            elsif lose = '1' then
                state <= S_POINT;
            elsif point_end = '1' and ((srv = '1' and sc_l = WIN_SCORE) or (srv = '0' and sc_r = WIN_SCORE)) then
                state <= S_OVER;
            elsif point_end = '1' then
                state <= S_SERVE;
            elsif again = '1' then
                state <= S_SERVE;               -- srv 不變：上一局勝方先發
            end if;
        end if;
    end process;

    -- srv：漏接時改成得分方（非接球方），由他發下一球
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                srv <= '1';
            elsif lose = '1' then
                srv <= not to_left;
            end if;
        end if;
    end process;

    -- wait_cnt：POINT 中每幀加 1
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or state /= S_POINT then
                wait_cnt <= 0;
            elsif frame_tick = '1' and point_end = '0' then
                wait_cnt <= wait_cnt + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ⑤ 球拍（SPEC §5.1）：鍵盤按住「上」每幀往上、按住「下」每幀往下；
    --   都沒按或兩個同時按就停在原地，碰到牆就停住，任何狀態都會動
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pad_l <= PAD_Y_INIT;
            elsif frame_tick = '0' or up_l = dn_l then
                null;                                   -- 沒按或上下同時按：停在原地
            elsif up_l = '1' and pad_l - PADDLE_SPEED < PAD_Y_MIN then
                pad_l <= PAD_Y_MIN;
            elsif up_l = '1' then
                pad_l <= pad_l - PADDLE_SPEED;
            elsif pad_l + PADDLE_SPEED > PAD_Y_MAX then
                pad_l <= PAD_Y_MAX;
            else
                pad_l <= pad_l + PADDLE_SPEED;
            end if;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pad_r <= PAD_Y_INIT;
            elsif frame_tick = '0' or up_r = dn_r then
                null;
            elsif up_r = '1' and pad_r - PADDLE_SPEED < PAD_Y_MIN then
                pad_r <= PAD_Y_MIN;
            elsif up_r = '1' then
                pad_r <= pad_r - PADDLE_SPEED;
            elsif pad_r + PADDLE_SPEED > PAD_Y_MAX then
                pad_r <= PAD_Y_MAX;
            else
                pad_r <= pad_r + PADDLE_SPEED;
            end if;
        end if;
    end process;

    -- frame_cnt：自由計數，給發球方向與心跳用
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                frame_cnt <= 0;
            elsif frame_tick = '1' and frame_cnt = 255 then
                frame_cnt <= 0;
            elsif frame_tick = '1' then
                frame_cnt <= frame_cnt + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ⑤ 球的暫存器：每個 process 只管一個暫存器（SPEC §7.3）
    --------------------------------------------------

    -- to_left：發球往對方，擊球反向
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                to_left <= '0';
            elsif serve = '1' then
                to_left <= not srv;
            elsif hit = '1' then
                to_left <= not to_left;
            end if;
        end if;
    end process;

    -- spd：發球時依 SW0 決定；每 SPEEDUP_HITS 次擊球加速一階
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                spd <= VX_SLOW;
            elsif serve = '1' then
                spd <= spd_sel;
            elsif hit = '1' and hits = SPEEDUP_HITS - 1 then
                spd <= spd_up;
            end if;
        end if;
    end process;

    -- hits：這一球的擊球次數，數到 SPEEDUP_HITS 歸零
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or serve = '1' then
                hits <= 0;
            elsif hit = '1' and hits = SPEEDUP_HITS - 1 then
                hits <= 0;
            elsif hit = '1' then
                hits <= hits + 1;
            end if;
        end if;
    end process;

    -- vy：發球取 SERVE_VY，擊球取 BOUNCE_VY，前進時撞牆反向
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                vy <= 0;
            elsif serve = '1' then
                vy <= SERVE_VY(frame_cnt mod 4);
            elsif hit = '1' then
                vy <= BOUNCE_VY(zone);
            elsif move = '1' then
                vy <= vy_wall;
            end if;
        end if;
    end process;

    -- bx：SERVE 中黏在發球方擊球面；擊球時拉回擊球面；前進時取 nx
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                bx <= HIT_L_X;
            elsif frame_tick = '1' and state = S_SERVE and srv = '1' then
                bx <= HIT_L_X;
            elsif frame_tick = '1' and state = S_SERVE then
                bx <= HIT_R_X;
            elsif hit = '1' and to_left = '1' then
                bx <= HIT_L_X;
            elsif hit = '1' then
                bx <= HIT_R_X;
            elsif move = '1' then
                bx <= nx;
            end if;
        end if;
    end process;

    -- by：SERVE 中對齊發球方球拍中央（取這一幀移動前的球拍位置）；擊球或前進時取 ny
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                by <= PAD_Y_INIT + SERVE_DY;
            elsif frame_tick = '1' and state = S_SERVE then
                by <= pad_srv + SERVE_DY;
            elsif hit = '1' or move = '1' then
                by <= ny;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ⑥ 計分：漏接時對方加 1 分；OVER 中按任一鍵歸零
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or again = '1' then
                sc_l <= 0;
                sc_r <= 0;
            elsif lose = '1' and to_left = '1' then
                sc_r <= sc_r + 1;
            elsif lose = '1' then
                sc_l <= sc_l + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- ⑥ 1 Hz 閃爍（SPEC §10.3）
    --   SERVE / PLAY 中停在「亮、計數 0」，所以進入 POINT 時一定從亮開始；
    --   SCORE_SHOW_FRAMES 是整數個閃爍週期，進入 OVER 時也剛好回到亮
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or state = S_SERVE or state = S_PLAY then
                blink_cnt <= 0;
                blink     <= '1';
            elsif frame_tick = '1' and blink_cnt = BLINK_HALF_FRAMES - 1 then
                blink_cnt <= 0;
                blink     <= not blink;
            elsif frame_tick = '1' then
                blink_cnt <= blink_cnt + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------
    -- 輸出
    --------------------------------------------------
    phase <= 0 when state = S_SERVE else
             1 when state = S_PLAY  else
             2 when state = S_POINT else
             3;
    server    <= srv;
    ball_x    <= to_unsigned(bx, 10);
    ball_y    <= to_unsigned(by, 9);
    pad_l_y   <= to_unsigned(pad_l, 9);
    pad_r_y   <= to_unsigned(pad_r, 9);
    score_l   <= to_unsigned(sc_l, 4);
    score_r   <= to_unsigned(sc_r, 4);
    blink_on  <= blink;
    heartbeat <= '1' when (frame_cnt / 32) mod 2 = 1 else '0';

end Behavioral;
