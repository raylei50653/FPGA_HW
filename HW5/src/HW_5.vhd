library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- ============================================================================
-- HW5 HDMI 乒乓球：top（規格見 HW5/SPEC.md §2、§12）
-- ============================================================================
--
--   PS：block design HW_5_ps（HW5/bd/HW_5_ps.tcl）。PS 上的裸機程式（HW5/sw/usb_kbd）當 USB host 讀鍵盤，
--       把按鍵狀態寫進 AXI GPIO，從 kbd[7:0] 交給 PL。DDR、MIO 等 PS 的腳位直接拉到 top。
--   PL：HW_5_pong（遊戲、畫面合成、HDMI 輸出）。
--   AXI 與 GPIO 跑在 PL 的 clk（Y9，100 MHz），kbd 和遊戲在同一個時脈域。
--   PS 沒開機（只燒 bitstream）時 kbd 一直是 0：畫面照常輸出，只是球拍不會動，BTNL / BTNR 仍可發球。
-- ============================================================================
entity HW_5 is
    Port (
        clk               : in    STD_LOGIC;
        reset             : in    STD_LOGIC;                     -- BTNC
        btn_l             : in    STD_LOGIC;                     -- BTNL：左方發球
        btn_r             : in    STD_LOGIC;                     -- BTNR：右方發球
        sw_speed          : in    STD_LOGIC;                     -- SW0：起始球速
        hdmi_clk          : out   STD_LOGIC;
        hdmi_d            : out   STD_LOGIC_VECTOR(23 downto 0);
        hdmi_hs           : out   STD_LOGIC;
        hdmi_vs           : out   STD_LOGIC;
        hdmi_scl          : out   STD_LOGIC;
        hdmi_sda          : inout STD_LOGIC;
        led               : out   STD_LOGIC_VECTOR(7 downto 0);
        -- PS 的固定腳位（DDR3、MIO：USB0、UART1、SD…），由 PS7 IP 決定，不需要在 xdc 指定
        DDR_addr          : inout STD_LOGIC_VECTOR(14 downto 0);
        DDR_ba            : inout STD_LOGIC_VECTOR(2 downto 0);
        DDR_cas_n         : inout STD_LOGIC;
        DDR_ck_n          : inout STD_LOGIC;
        DDR_ck_p          : inout STD_LOGIC;
        DDR_cke           : inout STD_LOGIC;
        DDR_cs_n          : inout STD_LOGIC;
        DDR_dm            : inout STD_LOGIC_VECTOR(3 downto 0);
        DDR_dq            : inout STD_LOGIC_VECTOR(31 downto 0);
        DDR_dqs_n         : inout STD_LOGIC_VECTOR(3 downto 0);
        DDR_dqs_p         : inout STD_LOGIC_VECTOR(3 downto 0);
        DDR_odt           : inout STD_LOGIC;
        DDR_ras_n         : inout STD_LOGIC;
        DDR_reset_n       : inout STD_LOGIC;
        DDR_we_n          : inout STD_LOGIC;
        FIXED_IO_ddr_vrn  : inout STD_LOGIC;
        FIXED_IO_ddr_vrp  : inout STD_LOGIC;
        FIXED_IO_mio      : inout STD_LOGIC_VECTOR(53 downto 0);
        FIXED_IO_ps_clk   : inout STD_LOGIC;
        FIXED_IO_ps_porb  : inout STD_LOGIC;
        FIXED_IO_ps_srstb : inout STD_LOGIC
    );
end HW_5;

architecture Behavioral of HW_5 is

    -- block design 的 wrapper（Vivado 產生的 Verilog），以 component 宣告
    component HW_5_ps_wrapper is
        port (
            DDR_addr          : inout STD_LOGIC_VECTOR(14 downto 0);
            DDR_ba            : inout STD_LOGIC_VECTOR(2 downto 0);
            DDR_cas_n         : inout STD_LOGIC;
            DDR_ck_n          : inout STD_LOGIC;
            DDR_ck_p          : inout STD_LOGIC;
            DDR_cke           : inout STD_LOGIC;
            DDR_cs_n          : inout STD_LOGIC;
            DDR_dm            : inout STD_LOGIC_VECTOR(3 downto 0);
            DDR_dq            : inout STD_LOGIC_VECTOR(31 downto 0);
            DDR_dqs_n         : inout STD_LOGIC_VECTOR(3 downto 0);
            DDR_dqs_p         : inout STD_LOGIC_VECTOR(3 downto 0);
            DDR_odt           : inout STD_LOGIC;
            DDR_ras_n         : inout STD_LOGIC;
            DDR_reset_n       : inout STD_LOGIC;
            DDR_we_n          : inout STD_LOGIC;
            FIXED_IO_ddr_vrn  : inout STD_LOGIC;
            FIXED_IO_ddr_vrp  : inout STD_LOGIC;
            FIXED_IO_mio      : inout STD_LOGIC_VECTOR(53 downto 0);
            FIXED_IO_ps_clk   : inout STD_LOGIC;
            FIXED_IO_ps_porb  : inout STD_LOGIC;
            FIXED_IO_ps_srstb : inout STD_LOGIC;
            kbd               : out   STD_LOGIC_VECTOR(7 downto 0);
            pl_clk            : in    STD_LOGIC
        );
    end component;

    signal kbd : std_logic_vector(7 downto 0);

begin

    u_ps : HW_5_ps_wrapper
        port map (
            DDR_addr => DDR_addr, DDR_ba => DDR_ba, DDR_cas_n => DDR_cas_n,
            DDR_ck_n => DDR_ck_n, DDR_ck_p => DDR_ck_p, DDR_cke => DDR_cke, DDR_cs_n => DDR_cs_n,
            DDR_dm => DDR_dm, DDR_dq => DDR_dq, DDR_dqs_n => DDR_dqs_n, DDR_dqs_p => DDR_dqs_p,
            DDR_odt => DDR_odt, DDR_ras_n => DDR_ras_n, DDR_reset_n => DDR_reset_n, DDR_we_n => DDR_we_n,
            FIXED_IO_ddr_vrn => FIXED_IO_ddr_vrn, FIXED_IO_ddr_vrp => FIXED_IO_ddr_vrp,
            FIXED_IO_mio => FIXED_IO_mio, FIXED_IO_ps_clk => FIXED_IO_ps_clk,
            FIXED_IO_ps_porb => FIXED_IO_ps_porb, FIXED_IO_ps_srstb => FIXED_IO_ps_srstb,
            kbd => kbd, pl_clk => clk
        );

    u_pong : entity work.HW_5_pong
        port map (
            clk => clk, reset => reset, btn_l => btn_l, btn_r => btn_r, sw_speed => sw_speed, kbd => kbd,
            hdmi_clk => hdmi_clk, hdmi_d => hdmi_d, hdmi_hs => hdmi_hs, hdmi_vs => hdmi_vs,
            hdmi_scl => hdmi_scl, hdmi_sda => hdmi_sda, led => led
        );

end Behavioral;
