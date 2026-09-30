library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

-- HW2 呼吸燈（規格見 HW2/SPEC.md）
entity HW_2 is
    Generic (
        CLK_FREQ_HZ         : natural := 100_000_000; -- 系統時脈，同時決定 1 ms 節拍
        PWM_BITS            : natural := 8;           -- PWM 解析度 N（>= 2）
        PWM_DIV             : natural := 390;         -- PWM 前除頻
        CYCLE_PERIODS       : natural := 2048;        -- 呼吸週期（PWM 週期數），約 2.04 s
        HOLD_BOTTOM_PERIODS : natural := 0;           -- 最暗停留（PWM 週期數）
        HUE_PERIODS         : natural := 4;           -- 色輪每步的 PWM 週期數
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
        led_r      : out STD_LOGIC;
        led_g      : out STD_LOGIC;
        led_b      : out STD_LOGIC;
        status     : out STD_LOGIC_VECTOR(4 downto 0)
    );
end HW_2;

architecture Behavioral of HW_2 is

    constant N         : natural := PWM_BITS;
    constant TICK_DIV  : natural := CLK_FREQ_HZ / 1000;
    constant LEVEL_MAX : unsigned(N-1 downto 0) := (others => '1');  -- R = 2^N - 1
    constant R_INT     : natural := 2**N - 1;
    constant CYC       : natural := CYCLE_PERIODS;
    constant HB        : natural := HOLD_BOTTOM_PERIODS;

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

    -- PWM
    signal div_cnt  : integer range 0 to PWM_DIV - 1 := 0;
    signal pwm_cnt  : unsigned(N-1 downto 0) := (others => '0');
    signal pwm_end  : std_logic;

    -- 亮度 FSM
    type breath_state_type is (UP, HOLD_TOP, DOWN, HOLD_BOTTOM);
    signal b_state   : breath_state_type := UP;
    signal sel_l     : integer range 0 to 3 := 0;      -- 本週期鎖存的 hold_sel
    signal acc       : integer range 0 to CYC := 0;    -- DDA 累加器
    signal dda_carry : std_logic;
    signal level     : unsigned(N-1 downto 0) := (others => '0');
    signal hold_cnt  : integer range 0 to CYC := 0;
    signal cycle_end : std_logic := '0';

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

    -- 顏色
    signal seq_idx : integer range 0 to 6 := 0;
    signal hue     : unsigned(10 downto 0) := (others => '0');  -- 0 ~ 1535
    signal hue_f   : unsigned(7 downto 0);
    signal hue_cnt : integer range 0 to HUE_PERIODS - 1 := 0;
    signal hue_tick : std_logic;
    signal c_r, c_g, c_b : unsigned(7 downto 0) := (others => '1');

    -- 資料路徑：混合 -> gamma -> duty 影子暫存器
    signal mix_r, mix_g, mix_b    : unsigned(N-1 downto 0) := (others => '0');
    signal gam_r, gam_g, gam_b    : unsigned(N-1 downto 0) := (others => '0');
    signal duty_r, duty_g, duty_b : unsigned(N-1 downto 0) := (others => '0');

    -- LED 熄滅電位
    function led_level(on_s : boolean) return std_logic is
    begin
        if on_s xor LED_ACTIVE_LOW then
            return '1';
        else
            return '0';
        end if;
    end function;

    signal led_r_reg, led_g_reg, led_b_reg : std_logic := '0';

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
                cycle_end <= '0';

            else
                cycle_end <= '0';

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
                                    acc       <= 0;
                                    hold_cnt  <= 0;
                                    cycle_end <= '1';       -- 亮度歸零，可換色
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

    status <= breath_en & std_logic_vector(hold_sel) & std_logic_vector(mode);


    --------------------------------------------------
    -- 6. 顏色控制
    --------------------------------------------------
    hue_f <= hue(7 downto 0);

    -- 色輪每 HUE_PERIODS 個 PWM 週期前進一步
    hue_tick <= '1' when pwm_end = '1' and hue_cnt = HUE_PERIODS - 1 else '0';

    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                seq_idx <= 0;
                hue     <= (others => '0');
                hue_cnt <= 0;
                c_r     <= (others => '1');
                c_g     <= (others => '1');
                c_b     <= (others => '1');

            else
                if pwm_end = '1' then
                    if hue_cnt = HUE_PERIODS - 1 then
                        hue_cnt <= 0;
                    else
                        hue_cnt <= hue_cnt + 1;
                    end if;
                end if;

                -- 序列索引與色相
                if short_p(0) = '1' or long_p(0) = '1' then
                    seq_idx <= 0;                   -- 切換模式時從紅色開始
                    hue     <= (others => '0');
                else
                    if mode = "01" and cycle_end = '1' then
                        if seq_idx = 6 then
                            seq_idx <= 0;
                        else
                            seq_idx <= seq_idx + 1;
                        end if;
                    end if;

                    if mode = "10" and hue_tick = '1' then
                        if hue = 1535 then
                            hue <= (others => '0');
                        else
                            hue <= hue + 1;
                        end if;
                    end if;
                end if;

                -- 目前顏色 C = (c_r, c_g, c_b)
                case mode is

                    when "01" =>                    -- 單色序列
                        case seq_idx is
                            when 0      => c_r <= x"FF"; c_g <= x"00"; c_b <= x"00";  -- 紅
                            when 1      => c_r <= x"FF"; c_g <= x"FF"; c_b <= x"00";  -- 黃
                            when 2      => c_r <= x"00"; c_g <= x"FF"; c_b <= x"00";  -- 綠
                            when 3      => c_r <= x"00"; c_g <= x"FF"; c_b <= x"FF";  -- 青
                            when 4      => c_r <= x"00"; c_g <= x"00"; c_b <= x"FF";  -- 藍
                            when 5      => c_r <= x"FF"; c_g <= x"00"; c_b <= x"FF";  -- 洋紅
                            when others => c_r <= x"FF"; c_g <= x"FF"; c_b <= x"FF";  -- 白
                        end case;

                    when "10" =>                    -- 色輪，255 - f = not f
                        case hue(10 downto 8) is
                            when "000"  => c_r <= x"FF";      c_g <= hue_f;      c_b <= x"00";
                            when "001"  => c_r <= not hue_f;  c_g <= x"FF";      c_b <= x"00";
                            when "010"  => c_r <= x"00";      c_g <= x"FF";      c_b <= hue_f;
                            when "011"  => c_r <= x"00";      c_g <= not hue_f;  c_b <= x"FF";
                            when "100"  => c_r <= hue_f;      c_g <= x"00";      c_b <= x"FF";
                            when others => c_r <= x"FF";      c_g <= x"00";      c_b <= not hue_f;
                        end case;

                    when others =>                  -- 固定白光
                        c_r <= x"FF"; c_g <= x"FF"; c_b <= x"FF";

                end case;
            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 7. 資料路徑：顏色混合 -> gamma -> duty 影子暫存器
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then

            -- (C × level) >> 8，8×N 乘法器
            mix_r <= resize(shift_right(c_r * level, 8), N);
            mix_g <= resize(shift_right(c_g * level, 8), N);
            mix_b <= resize(shift_right(c_b * level, 8), N);

            -- gamma 查表
            if GAMMA_EN then
                gam_r <= GAMMA_ROM(to_integer(mix_r));
                gam_g <= GAMMA_ROM(to_integer(mix_g));
                gam_b <= GAMMA_ROM(to_integer(mix_b));
            else
                gam_r <= mix_r;
                gam_g <= mix_g;
                gam_b <= mix_b;
            end if;

            -- duty 只在 PWM 週期交界更新
            if reset = '1' then
                duty_r <= (others => '0');
                duty_g <= (others => '0');
                duty_b <= (others => '0');
            elsif pwm_end = '1' then
                duty_r <= gam_r;
                duty_g <= gam_g;
                duty_b <= gam_b;
            end if;

        end if;
    end process;


    --------------------------------------------------
    -- 8. 比較器與輸出暫存器
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                led_r_reg <= led_level(false);
                led_g_reg <= led_level(false);
                led_b_reg <= led_level(false);
            else
                led_r_reg <= led_level(pwm_cnt < duty_r);
                led_g_reg <= led_level(pwm_cnt < duty_g);
                led_b_reg <= led_level(pwm_cnt < duty_b);
            end if;
        end if;
    end process;

    led_r <= led_r_reg;
    led_g <= led_g_reg;
    led_b <= led_b_reg;

end Behavioral;
