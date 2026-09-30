library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

-- HW2 呼吸燈（規格見 HW2/SPEC.md）
entity HW_2 is
    Generic (
        CLK_FREQ_HZ       : natural := 100_000_000; -- 系統時脈，同時決定 1 ms 節拍
        PWM_BITS          : natural := 8;           -- PWM 解析度 N（>= 2）
        PWM_DIV           : natural := 390;         -- PWM 前除頻
        STEP_PERIODS      : natural := 4;           -- 每階亮度的 PWM 週期數
        HOLD_BOTTOM_STEPS : natural := 0;           -- 最暗停留階數
        GAMMA_EN          : boolean := true;
        LED_ACTIVE_LOW    : boolean := false;
        DEBOUNCE_MS       : natural := 20;
        LONG_PRESS_MS     : natural := 1000;
        BTN_ACTIVE_LOW    : boolean := false
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
    constant R_EXT     : unsigned(N downto 0)   := resize(LEVEL_MAX, N+1);

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

    -- PWM
    signal div_cnt  : integer range 0 to PWM_DIV - 1 := 0;
    signal pwm_cnt  : unsigned(N-1 downto 0) := (others => '0');
    signal pwm_end  : std_logic;

    -- 亮度 FSM
    type breath_state_type is (UP, HOLD_TOP, DOWN, HOLD_BOTTOM);
    signal b_state   : breath_state_type := UP;
    signal step_cnt  : integer range 0 to STEP_PERIODS - 1 := 0;
    signal step_tick : std_logic;
    signal level     : unsigned(N-1 downto 0) := (others => '0');
    signal hold_cnt  : unsigned(N downto 0) := (others => '0');
    signal h_top     : unsigned(N downto 0) := (others => '0');
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

    -- 每 STEP_PERIODS 個 PWM 週期前進一階
    step_tick <= '1' when pwm_end = '1' and step_cnt = STEP_PERIODS - 1 else '0';


    --------------------------------------------------
    -- 2. 亮度 FSM（三角波 + 停留 + 呼吸開關）
    --------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                b_state   <= UP;
                step_cnt  <= 0;
                level     <= (others => '0');
                hold_cnt  <= (others => '0');
                h_top     <= (others => '0');
                cycle_end <= '0';

            else
                cycle_end <= '0';

                if pwm_end = '1' then
                    if step_cnt = STEP_PERIODS - 1 then
                        step_cnt <= 0;
                    else
                        step_cnt <= step_cnt + 1;
                    end if;
                end if;

                if step_tick = '1' then
                    case b_state is

                        when UP =>
                            level <= level + 1;
                            if level = LEVEL_MAX - 1 then
                                b_state  <= HOLD_TOP;
                                hold_cnt <= (others => '0');
                                -- 進入最亮時鎖存停留階數
                                case hold_sel is
                                    when "00"   => h_top <= (others => '0');
                                    when "01"   => h_top <= shift_right(R_EXT, 1);   -- R/2
                                    when "10"   => h_top <= R_EXT;                   -- R
                                    when others => h_top <= shift_left(R_EXT, 1);    -- 2R
                                end case;
                            end if;

                        when HOLD_TOP =>
                            if hold_cnt >= h_top then
                                if breath_en = '1' then
                                    b_state <= DOWN;
                                    level   <= level - 1;
                                end if;             -- 恆亮時停在這裡
                            else
                                hold_cnt <= hold_cnt + 1;
                            end if;

                        when DOWN =>
                            if breath_en = '0' then
                                b_state <= UP;      -- 關閉呼吸：轉回漸亮
                            else
                                level <= level - 1;
                                if level = 1 then
                                    b_state   <= HOLD_BOTTOM;
                                    hold_cnt  <= (others => '0');
                                    cycle_end <= '1';   -- 亮度歸零，可換色
                                end if;
                            end if;

                        when HOLD_BOTTOM =>
                            if breath_en = '0' then
                                b_state <= UP;
                            elsif hold_cnt >= HOLD_BOTTOM_STEPS then
                                b_state <= UP;
                                level   <= level + 1;
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

    process(clk)
    begin
        if rising_edge(clk) then

            if reset = '1' then
                seq_idx <= 0;
                hue     <= (others => '0');
                c_r     <= (others => '1');
                c_g     <= (others => '1');
                c_b     <= (others => '1');

            else
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

                    if mode = "10" and step_tick = '1' then
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
