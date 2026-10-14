library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

-- HW2 8 顆 LED 呼吸燈（規格見 HW2/SPEC.md）
--   mode 00 基礎：8 顆同步呼吸；01 流水 LD0 -> LD7；10 流水 LD7 -> LD0
entity HW_2 is
    Generic (
        CLK_FREQ_HZ         : natural := 100_000_000; -- 系統時脈，同時決定 1 ms 節拍
        PWM_BITS            : natural := 8;           -- PWM 解析度 N（>= 2）
        PWM_DIV             : natural := 390;         -- PWM 前除頻
        CYCLE_PERIODS       : natural := 2048;        -- 呼吸週期（PWM 週期數），約 2.04 s
        HOLD_BOTTOM_PERIODS : natural := 0;           -- 最暗停留（PWM 週期數）
        GAMMA_EN            : boolean := true;
        LED_ACTIVE_LOW      : boolean := false;
        DEBOUNCE_MS         : natural := 20;
        LONG_PRESS_MS       : natural := 1000;
        BTN_ACTIVE_LOW      : boolean := false
    );
    Port (
        clk        : in  STD_LOGIC;
        reset      : in  STD_LOGIC;
        btn_mode   : in  STD_LOGIC;
        btn_hold   : in  STD_LOGIC;
        btn_breath : in  STD_LOGIC;
        led        : out STD_LOGIC_VECTOR(7 downto 0)
    );
end HW_2;

architecture Behavioral of HW_2 is

    constant N         : natural := PWM_BITS;
    constant TICK_DIV  : natural := CLK_FREQ_HZ / 1000;
    constant LEVEL_MAX : unsigned(N-1 downto 0) := (others => '1');  -- R = 2^N - 1
    constant R_INT     : natural := 2**N - 1;
    constant CYC       : natural := CYCLE_PERIODS;
    constant HB        : natural := HOLD_BOTTOM_PERIODS;
    constant LEDS      : natural := 8;

    --------------------------------------------------
    -- 各 hold_sel 的時間分配（PWM 週期數，elaboration 時算好的常數）
    --   CYC = RAMP_LEN × 2 + TOP_LEN + HB，四種選擇的週期都相同
    --------------------------------------------------
    type period_table_t is array (0 to 3) of natural;

    -- 最亮停留佔週期的 0% / 25% / 50% / 75%
    constant TOP_NOM : period_table_t :=
        (0, (CYC * 25) / 100, (CYC * 50) / 100, (CYC * 75) / 100);

    -- 單程斜坡長度（漸亮 = 漸暗）
    constant RAMP_LEN : period_table_t :=
        ((CYC - HB - TOP_NOM(0)) / 2, (CYC - HB - TOP_NOM(1)) / 2,
         (CYC - HB - TOP_NOM(2)) / 2, (CYC - HB - TOP_NOM(3)) / 2);

    -- 實際最亮停留，吸收除以 2 的餘數，確保總和剛好等於 CYC
    constant TOP_LEN : period_table_t :=
        (CYC - HB - 2 * RAMP_LEN(0), CYC - HB - 2 * RAMP_LEN(1),
         CYC - HB - 2 * RAMP_LEN(2), CYC - HB - 2 * RAMP_LEN(3));

    --------------------------------------------------
    -- Gamma ROM（elaboration 時計算，gamma = 2.2）
    --------------------------------------------------
    type gamma_rom_t is array (0 to 2**N - 1) of unsigned(N-1 downto 0);

    function gen_gamma return gamma_rom_t is
        variable rom : gamma_rom_t;
        variable x   : real;
    begin
        rom(0) := (others => '0');
        for i in 1 to 2**N - 1 loop
            x      := real(i) / real(2**N - 1);
            rom(i) := to_unsigned(integer(round(real(2**N - 1) * (x ** 2.2))), N);
        end loop;
        return rom;
    end function;

    constant GAMMA_ROM : gamma_rom_t := gen_gamma;

    -- gamma(0) = 0、gamma(max) = max、單調不減
    function gamma_ok(rom : gamma_rom_t) return boolean is
    begin
        if rom(0) /= 0 or rom(2**N - 1) /= 2**N - 1 then
            return false;
        end if;
        for i in 1 to 2**N - 1 loop
            if rom(i) < rom(i - 1) then
                return false;
            end if;
        end loop;
        return true;
    end function;

    --------------------------------------------------
    -- 流水延遲：LD k 顯示 k × FLOW_STEP 個 PWM 週期前的亮度
    --   相鄰兩顆差 1/8 個呼吸週期，8 顆剛好排滿一個週期
    --------------------------------------------------
    constant FLOW_STEP : natural := CYC / LEDS;
    constant MAX_OFF   : natural := (LEDS - 1) * FLOW_STEP;

    function clog2(n : natural) return natural is
        variable r : natural := 0;
    begin
        while 2**r < n loop
            r := r + 1;
        end loop;
        return r;
    end function;

    constant HIST_BITS : natural := clog2(MAX_OFF + 1);   -- 歷史 RAM 深度 2^HIST_BITS > MAX_OFF

    type off_table_t is array (0 to LEDS - 1) of natural;

    function gen_offsets return off_table_t is
        variable t : off_table_t;
    begin
        for k in 0 to LEDS - 1 loop
            t(k) := k * FLOW_STEP;
        end loop;
        return t;
    end function;

    constant OFFSETS : off_table_t := gen_offsets;

    -- PWM
    signal div_cnt   : integer range 0 to PWM_DIV - 1 := 0;
    signal pwm_cnt   : unsigned(N-1 downto 0) := (others => '0');
    signal pwm_end   : std_logic;
    signal pwm_end_d : std_logic := '0';    -- pwm_end 延遲一拍：level 已更新

    -- 亮度 FSM（主波形，8 顆 LED 共用）
    type breath_state_type is (UP, HOLD_TOP, DOWN, HOLD_BOTTOM);
    signal b_state   : breath_state_type := UP;
    signal sel_l     : integer range 0 to 3 := 0;      -- 本週期鎖存的 hold_sel
    signal acc       : integer range 0 to CYC := 0;    -- DDA 累加器
    signal dda_carry : std_logic;
    signal level     : unsigned(N-1 downto 0) := (others => '0');
    signal hold_cnt  : integer range 0 to CYC := 0;

    -- 按鈕：bit 0 = mode，1 = hold，2 = breath
    signal tick_cnt : integer range 0 to TICK_DIV - 1 := 0;
    signal tick_1ms : std_logic := '0';
    signal btn_raw  : std_logic_vector(2 downto 0);
    signal short_p  : std_logic_vector(2 downto 0);
    signal long_p   : std_logic_vector(2 downto 0);

    -- 設定暫存器
    signal mode      : unsigned(1 downto 0) := "00";
    signal hold_sel  : unsigned(1 downto 0) := "00";
    signal breath_en : std_logic := '1';

    -- 流水延遲線：每個 PWM 週期寫入一筆 level，再依序讀出 8 顆 LED 的值
    type hist_ram_t is array (0 to 2**HIST_BITS - 1) of unsigned(N-1 downto 0);
    signal hist_ram  : hist_ram_t := (others => (others => '0'));
    signal hist_we   : std_logic;
    signal wr_ptr    : unsigned(HIST_BITS-1 downto 0) := (others => '0');
    signal base      : unsigned(HIST_BITS-1 downto 0) := (others => '0');  -- 本週期剛寫入的位址
    signal fill      : integer range 0 to MAX_OFF + 1 := 0;               -- reset 後已寫入筆數（飽和）
    signal rd_busy   : std_logic := '0';
    signal rd_k      : integer range 0 to LEDS - 1 := 0;
    signal rd_off    : integer range 0 to MAX_OFF;
    signal rd_addr   : unsigned(HIST_BITS-1 downto 0);
    signal hist_q    : unsigned(N-1 downto 0) := (others => '0');
    signal q_valid   : std_logic := '0';
    signal q_k       : integer range 0 to LEDS - 1 := 0;
    signal q_ok      : std_logic := '0';                                  -- 讀到的位址 reset 後已寫過

    -- gamma 後的 duty：下一週期的值與目前週期的影子暫存器
    type duty_array_t is array (0 to LEDS - 1) of unsigned(N-1 downto 0);
    signal duty_nxt : duty_array_t := (others => (others => '0'));
    signal duty     : duty_array_t := (others => (others => '0'));

    -- LED 熄滅電位
    function led_level(on_s : boolean) return std_logic is
    begin
        if on_s xor LED_ACTIVE_LOW then
            return '1';
        else
            return '0';
        end if;
    end function;

    signal led_reg : std_logic_vector(LEDS - 1 downto 0) := (others => '0');

begin

    -- DDA 每個 PWM 週期最多走一步，斜坡不得短於 R 個週期
    assert RAMP_LEN(3) >= R_INT
        report "CYCLE_PERIODS too small: 75% hold leaves a ramp shorter than 2^PWM_BITS-1 periods"
        severity failure;

    assert CLK_FREQ_HZ >= 1000 and CLK_FREQ_HZ mod 1000 = 0
        report "CLK_FREQ_HZ must be a multiple of 1000 for an exact 1 ms tick"
        severity failure;

    assert gamma_ok(GAMMA_ROM)
        report "GAMMA_ROM must satisfy gamma(0) = 0, gamma(max) = max and be non-decreasing"
        severity failure;

    -- 流水相鄰兩顆至少差一個 PWM 週期
    assert FLOW_STEP >= 1
        report "CYCLE_PERIODS must be at least 8 for the flowing modes"
        severity failure;

    -- 延遲線每個 PWM 週期需約 11 個 clk 讀完 8 顆，必須在下一個 pwm_end 前完成
    assert PWM_DIV * 2**N >= 16
        report "PWM period too short: PWM_DIV * 2^PWM_BITS must be at least 16 clocks"
        severity failure;

    --------------------------------------------------
    -- 1. PWM 計數器
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                div_cnt <= 0;
                pwm_cnt <= (others => '0');
            elsif div_cnt = PWM_DIV - 1 then
                div_cnt <= 0;
                pwm_cnt <= pwm_cnt + 1;         -- 自然溢位
            else
                div_cnt <= div_cnt + 1;
            end if;
        end if;
    end process;

    -- pwm_cnt 即將由 2^N-1 回到 0 的那一拍
    pwm_end <= '1' when div_cnt = PWM_DIV - 1 and pwm_cnt = LEVEL_MAX else '0';


    --------------------------------------------------
    -- 2. 亮度 FSM（三角波 + 停留 + 呼吸開關）
    --    時間單位為 PWM 週期；斜坡以 DDA 讓 level 在 RAMP_LEN 個週期內
    --    均勻走完 R 步，因此週期固定為 CYCLE_PERIODS，與最亮佔比無關
    --------------------------------------------------
    dda_carry <= '1' when acc + R_INT >= RAMP_LEN(sel_l) else '0';

    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                b_state   <= UP;
                sel_l     <= 0;
                acc       <= 0;
                level     <= (others => '0');
                hold_cnt  <= 0;

            else
                if pwm_end = '1' then
                    case b_state is

                        when UP =>
                            if dda_carry = '1' then
                                acc   <= acc + R_INT - RAMP_LEN(sel_l);
                                level <= level + 1;
                                if level = LEVEL_MAX - 1 then
                                    acc      <= 0;
                                    hold_cnt <= 0;
                                    if TOP_LEN(sel_l) = 0 and breath_en = '1' then
                                        b_state <= DOWN;
                                    else
                                        b_state <= HOLD_TOP;
                                    end if;
                                end if;
                            else
                                acc <= acc + R_INT;
                            end if;

                        when HOLD_TOP =>
                            if hold_cnt + 1 >= TOP_LEN(sel_l) and breath_en = '1' then
                                b_state <= DOWN;
                                acc     <= 0;
                            elsif hold_cnt < TOP_LEN(sel_l) then
                                hold_cnt <= hold_cnt + 1;   -- 恆亮時停在這裡（計數飽和）
                            end if;

                        when DOWN =>
                            if breath_en = '0' then
                                acc <= 0;                   -- 關閉呼吸：轉回漸亮
                                if level = LEVEL_MAX then
                                    b_state  <= HOLD_TOP;
                                    hold_cnt <= 0;
                                else
                                    b_state <= UP;
                                end if;
                            elsif dda_carry = '1' then
                                acc   <= acc + R_INT - RAMP_LEN(sel_l);
                                level <= level - 1;
                                if level = 1 then
                                    acc      <= 0;
                                    hold_cnt <= 0;
                                    if HB = 0 then
                                        b_state <= UP;
                                        sel_l   <= to_integer(hold_sel);  -- 新週期鎖存佔比
                                    else
                                        b_state <= HOLD_BOTTOM;
                                    end if;
                                end if;
                            else
                                acc <= acc + R_INT;
                            end if;

                        when HOLD_BOTTOM =>
                            if breath_en = '0' or hold_cnt + 1 >= HB then
                                b_state <= UP;
                                acc     <= 0;
                                sel_l   <= to_integer(hold_sel);      -- 新週期鎖存佔比
                            else
                                hold_cnt <= hold_cnt + 1;
                            end if;

                    end case;
                end if;

            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 3. 1 ms 節拍
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            tick_1ms <= '0';
            if reset = '1' then
                tick_cnt <= 0;
            elsif tick_cnt = TICK_DIV - 1 then
                tick_cnt <= 0;
                tick_1ms <= '1';
            else
                tick_cnt <= tick_cnt + 1;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 4. 按鈕介面 ×3：同步 -> 去彈跳 -> 短/長按 FSM
    --------------------------------------------------
    btn_raw <= btn_breath & btn_hold & btn_mode;

    gen_btn : for i in 0 to 2 generate

        type btn_state_type is (B_IDLE, B_PRESSED, B_LONG);
        signal btn_state : btn_state_type := B_IDLE;
        signal sync1     : std_logic := '0';
        signal sync2     : std_logic := '0';
        signal stable    : std_logic := '0';
        signal db_cnt    : integer range 0 to DEBOUNCE_MS - 1 := 0;
        signal press_cnt : integer range 0 to LONG_PRESS_MS - 1 := 0;

    begin

        -- 極性調整 + 兩級同步
        process(clk)
        begin
            if rising_edge(clk) then
                if BTN_ACTIVE_LOW then
                    sync1 <= not btn_raw(i);
                else
                    sync1 <= btn_raw(i);
                end if;
                sync2 <= sync1;
            end if;
        end process;

        -- 去彈跳：連續 DEBOUNCE_MS 拍不同才更新
        process(clk)
        begin
            if rising_edge(clk) then
                if reset = '1' then
                    stable <= '0';
                    db_cnt <= 0;
                elsif tick_1ms = '1' then
                    if sync2 /= stable then
                        if db_cnt = DEBOUNCE_MS - 1 then
                            stable <= sync2;
                            db_cnt <= 0;
                        else
                            db_cnt <= db_cnt + 1;
                        end if;
                    else
                        db_cnt <= 0;
                    end if;
                end if;
            end if;
        end process;

        -- 短/長按 FSM
        process(clk)
        begin
            if rising_edge(clk) then

                short_p(i) <= '0';
                long_p(i)  <= '0';

                if reset = '1' then
                    btn_state <= B_IDLE;
                    press_cnt <= 0;
                else
                    case btn_state is

                        when B_IDLE =>
                            if stable = '1' then
                                btn_state <= B_PRESSED;
                                press_cnt <= 0;
                            end if;

                        when B_PRESSED =>
                            if stable = '0' then
                                btn_state  <= B_IDLE;
                                short_p(i) <= '1';      -- 放開時觸發短按
                            elsif tick_1ms = '1' then
                                if press_cnt = LONG_PRESS_MS - 1 then
                                    btn_state <= B_LONG;
                                    long_p(i) <= '1';   -- 滿門檻立即觸發長按
                                else
                                    press_cnt <= press_cnt + 1;
                                end if;
                            end if;

                        when B_LONG =>
                            if stable = '0' then
                                btn_state <= B_IDLE;
                            end if;

                    end case;
                end if;

            end if;
        end process;

    end generate;


    --------------------------------------------------
    -- 5. 設定暫存器（短按 = 下一項，長按 = 回預設）
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                mode      <= "00";
                hold_sel  <= "00";
                breath_en <= '1';

            else
                -- mode：00 -> 01 -> 10 -> 00
                if long_p(0) = '1' then
                    mode <= "00";
                elsif short_p(0) = '1' then
                    if mode = "01" then
                        mode <= "10";
                    elsif mode = "00" then
                        mode <= "01";
                    else
                        mode <= "00";
                    end if;
                end if;

                -- hold_sel：00 -> 01 -> 10 -> 11 -> 00
                if long_p(1) = '1' then
                    hold_sel <= "00";
                elsif short_p(1) = '1' then
                    hold_sel <= hold_sel + 1;
                end if;

                -- breath_en：切換
                if long_p(2) = '1' then
                    breath_en <= '1';
                elsif short_p(2) = '1' then
                    breath_en <= not breath_en;
                end if;
            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 6. 流水延遲線：歷史 RAM -> gamma -> duty_nxt
    --    pwm_end 後一拍把新的 level 寫入 RAM，接著 8 拍依序讀出
    --    LD k 的位址 base - 偏移（00 偏移 0；01 為 k 格；10 為 7 - k 格）
    --------------------------------------------------
    hist_we <= '1' when pwm_end_d = '1' else '0';

    with mode select rd_off <=
        OFFSETS(rd_k)            when "01",
        OFFSETS(LEDS - 1 - rd_k) when "10",
        0                        when others;

    rd_addr <= base - to_unsigned(rd_off, HIST_BITS);

    -- 單埠寫、同步讀，推論為 Block RAM
    process(clk)
    begin
        if rising_edge(clk) then
            if hist_we = '1' then
                hist_ram(to_integer(wr_ptr)) <= level;
            end if;
            hist_q <= hist_ram(to_integer(rd_addr));
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then

            pwm_end_d <= pwm_end;
            q_valid   <= '0';

            if reset = '1' then
                wr_ptr   <= (others => '0');
                base     <= (others => '0');
                fill     <= 0;
                rd_busy  <= '0';
                rd_k     <= 0;
                q_k      <= 0;
                q_ok     <= '0';
                duty_nxt <= (others => (others => '0'));

            else
                -- 寫入：level 在 pwm_end 更新，下一拍存進 RAM
                if hist_we = '1' then
                    base    <= wr_ptr;
                    wr_ptr  <= wr_ptr + 1;
                    rd_busy <= '1';
                    rd_k    <= 0;
                    if fill <= MAX_OFF then
                        fill <= fill + 1;
                    end if;

                -- 讀出：每拍一顆，RAM 資料下一拍出來
                elsif rd_busy = '1' then
                    q_valid <= '1';
                    q_k     <= rd_k;
                    -- reset 後還沒寫到的位址當作 0，避免 RAM 殘留舊資料
                    if rd_off < fill then
                        q_ok <= '1';
                    else
                        q_ok <= '0';
                    end if;
                    if rd_k = LEDS - 1 then
                        rd_busy <= '0';
                    else
                        rd_k <= rd_k + 1;
                    end if;
                end if;

                -- gamma 查表後存成下一週期的 duty
                if q_valid = '1' then
                    if q_ok = '0' then
                        duty_nxt(q_k) <= (others => '0');
                    elsif GAMMA_EN then
                        duty_nxt(q_k) <= GAMMA_ROM(to_integer(hist_q));
                    else
                        duty_nxt(q_k) <= hist_q;
                    end if;
                end if;
            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 7. duty 影子暫存器：只在 PWM 週期交界更新
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                duty <= (others => (others => '0'));
            elsif pwm_end = '1' then
                duty <= duty_nxt;
            end if;
        end if;
    end process;


    --------------------------------------------------
    -- 8. 比較器與輸出暫存器 ×8
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            for k in 0 to LEDS - 1 loop
                if reset = '1' then
                    led_reg(k) <= led_level(false);
                else
                    led_reg(k) <= led_level(pwm_cnt < duty(k));
                end if;
            end loop;
        end if;
    end process;

    led <= led_reg;

end Behavioral;
