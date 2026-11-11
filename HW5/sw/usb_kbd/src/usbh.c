/*
 * HW5 精簡 USB host（Zynq-7000 USB0，裸機）
 *
 * Zynq 的 USB 控制器在 host 模式是 EHCI 相容的（內建 transaction translator，低速、全速裝置直接接在
 * root port 上，不需要 split transaction）。Xilinx 的裸機驅動 XUsbPs 只做 device 模式，所以這裡直接
 * 操作暫存器，只做「一把直接插著的鍵盤」需要的最少功能：
 *
 *   1. MIO 46 拉低再放開，重設 USB3320 PHY（《EGO-XZ7 硬體手冊》V1.2 表 10：USB_RESET#）
 *   2. 控制器重設、切成 host 模式；經 ULPI 開 PHY 的 VBUS 輸出（USB3320 的 CPEN 控制 5V 開關 MIC2025）
 *   3. async schedule 上放兩個 QH，彼此串成環：qh_ctrl（端點 0，控制傳輸）、qh_int（鍵盤的中斷 IN 端點）
 *   4. 等鍵盤插上 → port reset → 列舉：GET_DESCRIPTOR、SET_ADDRESS、讀組態找 HID boot keyboard 介面、
 *      SET_CONFIGURATION、SET_PROTOCOL(boot)、SET_IDLE(0)
 *   5. 之後每次在 qh_int 掛一個 8 byte 的 IN qTD，鍵盤有按鍵變化才回資料（沒有變化就 NAK，控制器自己重試）
 *
 * 中斷端點照理要放在 periodic schedule；這裡放在 async schedule 上，對鍵盤來說在線上看到的 IN token
 * 完全一樣，只是輪詢得比較勤，程式簡單很多。
 * 為了不必處理 cache 一致性，main() 一開始就把 D-cache 關掉（Xil_DCacheDisable）。
 *
 * 暫存器位址與位元定義見 SDK 2018.3 的 xusbps_hw.h；QH、qTD 的格式見 EHCI 規格 §3.5、§3.6。
 */
#include "usbh.h"
#include "xparameters.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xgpiops.h"
#include "xtime_l.h"
#include "sleep.h"

/* ---- 暫存器 ---- */
#define USB_BASE        XPAR_XUSBPS_0_BASEADDR
#define USBCMD          (USB_BASE + 0x140)
#define USBSTS          (USB_BASE + 0x144)
#define USBINTR         (USB_BASE + 0x148)
#define ASYNCLISTADDR   (USB_BASE + 0x158)
#define ULPIVIEW        (USB_BASE + 0x170)
#define PORTSC          (USB_BASE + 0x184)
#define USBMODE         (USB_BASE + 0x1A8)

#define CMD_RS          0x00000001u
#define CMD_RST         0x00000002u
#define CMD_ASE         0x00000020u
#define STS_HCH         0x00001000u
#define STS_AS          0x00008000u
#define MODE_HOST       0x00000003u

#define PORT_CCS        0x00000001u
#define PORT_CSC        0x00000002u
#define PORT_PE         0x00000004u
#define PORT_PEC        0x00000008u
#define PORT_OCC        0x00000020u
#define PORT_PR         0x00000100u
#define PORT_PP         0x00001000u
#define PORT_W1C        (PORT_CSC | PORT_PEC | PORT_OCC)
#define PORT_PSPD(v)    (((v) >> 26) & 3u)      /* 0 全速、1 低速、2 高速 */

#define ULPI_WU         0x80000000u
#define ULPI_RUN        0x40000000u
#define ULPI_RW         0x20000000u

/* USB3320 的 ULPI 暫存器 */
#define ULPI_VID_L      0x00
#define ULPI_VID_H      0x01
#define ULPI_PID_L      0x02
#define ULPI_PID_H      0x03
#define ULPI_OTG_SET    0x0B                    /* OTG Control 的 set 位址 */
#define OTG_DP_PULLDOWN 0x02
#define OTG_DM_PULLDOWN 0x04
#define OTG_DRV_VBUS    0x20
#define OTG_DRV_VBUS_EXT 0x40

#define USB_RESET_MIO   46                      /* USB3320 RESET#，低電位重設 */

/* ---- EHCI 資料結構 ---- */
#define LINK_TERM       0x00000001u
#define LINK_QH         0x00000002u

#define TOK_ACTIVE      0x00000080u
#define TOK_HALTED      0x00000040u
#define TOK_ERRMASK     0x00000078u             /* halted、buffer error、babble、transaction error */
#define TOK_PID_OUT     0x00000000u
#define TOK_PID_IN      0x00000100u
#define TOK_PID_SETUP   0x00000200u
#define TOK_CERR3       0x00000C00u
#define TOK_IOC         0x00008000u
#define TOK_BYTES(n)    ((u32)(n) << 16)
#define TOK_REMAIN(t)   (((t) >> 16) & 0x7FFFu)
#define TOK_DT          0x80000000u

typedef struct {
    volatile u32 next;
    volatile u32 alt;
    volatile u32 token;
    volatile u32 buf[5];
} __attribute__((aligned(32))) qtd_t;

typedef struct {
    volatile u32 hlink;
    volatile u32 ep_char;
    volatile u32 ep_cap;
    volatile u32 cur_qtd;
    volatile u32 next_qtd;                       /* 以下是 overlay（目前 qTD 的工作副本） */
    volatile u32 alt_qtd;
    volatile u32 token;
    volatile u32 buf[5];
    u32 pad[4];
} __attribute__((aligned(64))) qh_t;

static qh_t  qh_ctrl, qh_int;
static qtd_t td_setup, td_data, td_status, td_int;
static u8 setup_buf[8]   __attribute__((aligned(32)));
static u8 data_buf[256]  __attribute__((aligned(256)));
static u8 int_buf[64]    __attribute__((aligned(64)));

static XGpioPs gpio_ps;
static u32 dev_speed;                           /* 0 全速、1 低速 */
static u32 ep0_mps = 8;
static u32 int_ep, int_mps, kbd_iface;
static int int_pending;

/* ---- 小工具 ---- */
static u64 now_us(void)
{
    XTime t;
    XTime_GetTime(&t);
    return (u64)t / (COUNTS_PER_SECOND / 1000000u);
}

/* 等到 (reg & mask) == want，逾時傳回 -1 */
static int wait_reg(u32 reg, u32 mask, u32 want, u32 timeout_us)
{
    u64 t0 = now_us();
    while ((Xil_In32(reg) & mask) != want) {
        if (now_us() - t0 > timeout_us)
            return -1;
    }
    return 0;
}

static int ulpi_write(u8 addr, u8 data)
{
    Xil_Out32(ULPIVIEW, ULPI_RUN | ULPI_RW | ((u32)addr << 16) | data);
    return wait_reg(ULPIVIEW, ULPI_RUN, 0, 10000);
}

static int ulpi_read(u8 addr)
{
    Xil_Out32(ULPIVIEW, ULPI_RUN | ((u32)addr << 16));
    if (wait_reg(ULPIVIEW, ULPI_RUN, 0, 10000))
        return -1;
    return (Xil_In32(ULPIVIEW) >> 8) & 0xFF;
}

/* 改 QH 前先停掉 async schedule，改完再開，避免控制器讀到改到一半的 QH */
static void async_stop(void)
{
    Xil_Out32(USBCMD, Xil_In32(USBCMD) & ~CMD_ASE);
    wait_reg(USBSTS, STS_AS, 0, 10000);
}

static void async_start(void)
{
    Xil_Out32(USBCMD, Xil_In32(USBCMD) | CMD_ASE);
    wait_reg(USBSTS, STS_AS, STS_AS, 10000);
}

static u32 ep_char(u32 addr, u32 ep, u32 mps, int control, int head)
{
    u32 v = addr | (ep << 8) | (dev_speed << 12) | (mps << 16);
    if (control)
        v |= (1u << 14);                         /* DTC：控制傳輸的 toggle 由 qTD 決定 */
    if (control && dev_speed != 2)
        v |= (1u << 27);                         /* C：非高速的控制端點 */
    if (head)
        v |= (1u << 15);                         /* H：async list 的頭 */
    return v;
}

static void qh_init(qh_t *qh, qh_t *next, u32 chr)
{
    qh->hlink    = (u32)next | LINK_QH;
    qh->ep_char  = chr;
    qh->ep_cap   = (1u << 30);                   /* Mult = 1；root port 上的裝置不需要 hub 位址 */
    qh->cur_qtd  = 0;
    qh->next_qtd = LINK_TERM;
    qh->alt_qtd  = LINK_TERM;
    qh->token    = 0;
    for (int i = 0; i < 5; i++)
        qh->buf[i] = 0;
}

static void qtd_fill(qtd_t *td, qtd_t *next, u32 token, void *buf)
{
    u32 a = (u32)buf;
    td->next  = next ? (u32)next : LINK_TERM;
    td->alt   = LINK_TERM;
    td->token = token;
    td->buf[0] = a;
    td->buf[1] = (a & ~0xFFFu) + 0x1000u;
    td->buf[2] = td->buf[3] = td->buf[4] = 0;
}

/* 把一串 qTD 掛到 QH 上（清掉 halted，讓控制器從 first 開始做）
 *   overlay 的 DT 位元要留著：中斷端點的 DATA0 / DATA1 交替記在這裡，清掉的話每隔一個報告就會被當成重送丟掉 */
static void qh_submit(qh_t *qh, qtd_t *first)
{
    async_stop();
    qh->alt_qtd  = LINK_TERM;
    qh->token    = qh->token & TOK_DT;
    qh->next_qtd = (u32)first;
    async_start();
}

/* 控制傳輸。data 方向由 bmRequestType bit 7 決定。成功傳回實際傳了幾個 byte，失敗傳回負數 */
static int ctrl_xfer(u8 rtype, u8 req, u16 value, u16 index, u16 len, void *data)
{
    int in = (rtype & 0x80) != 0;
    u8 *d = (u8 *)data;

    if (len > sizeof(data_buf))
        return -10;
    setup_buf[0] = rtype;
    setup_buf[1] = req;
    setup_buf[2] = value & 0xFF;
    setup_buf[3] = value >> 8;
    setup_buf[4] = index & 0xFF;
    setup_buf[5] = index >> 8;
    setup_buf[6] = len & 0xFF;
    setup_buf[7] = len >> 8;
    if (!in)
        for (u16 i = 0; i < len; i++)
            data_buf[i] = d[i];

    /* 狀態階段的方向和資料階段相反；沒有資料階段時為 IN */
    qtd_fill(&td_status, NULL,
             TOK_DT | TOK_CERR3 | TOK_IOC | TOK_ACTIVE | ((in && len) ? TOK_PID_OUT : TOK_PID_IN), data_buf);
    if (len) {
        qtd_fill(&td_data, &td_status,
                 TOK_DT | TOK_BYTES(len) | TOK_CERR3 | TOK_ACTIVE | (in ? TOK_PID_IN : TOK_PID_OUT), data_buf);
        qtd_fill(&td_setup, &td_data, TOK_BYTES(8) | TOK_CERR3 | TOK_PID_SETUP | TOK_ACTIVE, setup_buf);
    } else {
        qtd_fill(&td_setup, &td_status, TOK_BYTES(8) | TOK_CERR3 | TOK_PID_SETUP | TOK_ACTIVE, setup_buf);
    }
    qh_submit(&qh_ctrl, &td_setup);

    u64 t0 = now_us();
    for (;;) {
        u32 s0 = td_setup.token, s1 = len ? td_data.token : 0, s2 = td_status.token;
        if ((s0 | s1 | s2) & TOK_HALTED) {
            xil_printf("  ctrl %02x/%02x failed: setup %08x data %08x status %08x\r\n",
                       rtype, req, s0, s1, s2);
            return -1;
        }
        if (!(s2 & TOK_ACTIVE))
            break;
        if (now_us() - t0 > 500000) {
            xil_printf("  ctrl %02x/%02x timeout: setup %08x data %08x status %08x\r\n",
                       rtype, req, s0, s1, s2);
            return -2;
        }
    }
    int got = len ? (int)(len - TOK_REMAIN(td_data.token)) : 0;
    if (in)
        for (int i = 0; i < got; i++)
            d[i] = data_buf[i];
    return got;
}

int usbh_connected(void)
{
    return (Xil_In32(PORTSC) & PORT_CCS) != 0;
}

/* ---- 開機：PHY、控制器 ---- */
static int host_init(void)
{
    XGpioPs_Config *cfg = XGpioPs_LookupConfig(XPAR_XGPIOPS_0_DEVICE_ID);
    XGpioPs_CfgInitialize(&gpio_ps, cfg, cfg->BaseAddr);
    XGpioPs_SetDirectionPin(&gpio_ps, USB_RESET_MIO, 1);
    XGpioPs_SetOutputEnablePin(&gpio_ps, USB_RESET_MIO, 1);
    XGpioPs_WritePin(&gpio_ps, USB_RESET_MIO, 0);
    usleep(2000);
    XGpioPs_WritePin(&gpio_ps, USB_RESET_MIO, 1);
    usleep(10000);

    Xil_Out32(USBCMD, CMD_RST);
    if (wait_reg(USBCMD, CMD_RST, 0, 100000)) {
        xil_printf("USB: controller reset timeout\r\n");
        return -1;
    }
    Xil_Out32(USBMODE, MODE_HOST);
    Xil_Out32(USBINTR, 0);

    int vl = ulpi_read(ULPI_VID_L), vh = ulpi_read(ULPI_VID_H);
    int pl = ulpi_read(ULPI_PID_L), ph = ulpi_read(ULPI_PID_H);
    xil_printf("USB: ULPI PHY vendor %02x%02x product %02x%02x (USB3320 = 0424 / 0007)\r\n", vh, vl, ph, pl);
    if (vl < 0)
        return -2;

    /* host 模式：D+ / D- 下拉，開 VBUS（DrvVbus、DrvVbusExternal → CPEN → MIC2025） */
    ulpi_write(ULPI_OTG_SET, OTG_DP_PULLDOWN | OTG_DM_PULLDOWN | OTG_DRV_VBUS | OTG_DRV_VBUS_EXT);
    Xil_Out32(PORTSC, (Xil_In32(PORTSC) & ~(PORT_W1C | PORT_PE)) | PORT_PP);

    dev_speed = 0;
    qh_init(&qh_ctrl, &qh_int, ep_char(0, 0, 8, 1, 1));
    qh_init(&qh_int, &qh_ctrl, ep_char(0, 1, 8, 0, 0));
    Xil_Out32(ASYNCLISTADDR, (u32)&qh_ctrl);
    Xil_Out32(USBCMD, Xil_In32(USBCMD) | CMD_RS);
    if (wait_reg(USBSTS, STS_HCH, 0, 100000)) {
        xil_printf("USB: controller does not start\r\n");
        return -3;
    }
    async_start();
    return 0;
}

static int port_reset(void)
{
    u32 v = Xil_In32(PORTSC) & ~(PORT_W1C | PORT_PE);
    Xil_Out32(PORTSC, v | PORT_PR);
    usleep(50000);
    Xil_Out32(PORTSC, Xil_In32(PORTSC) & ~(PORT_W1C | PORT_PR));
    if (wait_reg(PORTSC, PORT_PR, 0, 100000))
        return -1;
    usleep(20000);
    v = Xil_In32(PORTSC);
    xil_printf("USB: port reset done, PORTSC %08x, speed %s\r\n", v,
               PORT_PSPD(v) == 1 ? "low" : PORT_PSPD(v) == 2 ? "high" : "full");
    if (!(v & PORT_PE))
        return -2;
    dev_speed = PORT_PSPD(v);
    return 0;
}

/* ---- 列舉 ---- */
static int enumerate(void)
{
    u8 dd[18];
    u8 cfg[256];
    int n;

    ep0_mps = 8;
    async_stop();
    qh_ctrl.ep_char = ep_char(0, 0, ep0_mps, 1, 1);
    async_start();

    n = ctrl_xfer(0x80, 6, 0x0100, 0, 8, dd);            /* GET_DESCRIPTOR(device)，先讀 8 byte */
    if (n < 8)
        return -1;
    ep0_mps = dd[7] ? dd[7] : 8;

    if (ctrl_xfer(0x00, 5, 1, 0, 0, NULL) < 0)          /* SET_ADDRESS(1) */
        return -2;
    usleep(20000);
    async_stop();
    qh_ctrl.ep_char = ep_char(1, 0, ep0_mps, 1, 1);
    async_start();

    n = ctrl_xfer(0x80, 6, 0x0100, 0, 18, dd);
    if (n < 18)
        return -3;
    xil_printf("USB: device %02x%02x:%02x%02x, ep0 max packet %d\r\n", dd[9], dd[8], dd[11], dd[10], ep0_mps);

    n = ctrl_xfer(0x80, 6, 0x0200, 0, 9, cfg);           /* GET_DESCRIPTOR(configuration) */
    if (n < 9)
        return -4;
    u16 total = cfg[2] | (cfg[3] << 8);
    if (total > sizeof(cfg))
        total = sizeof(cfg);
    n = ctrl_xfer(0x80, 6, 0x0200, 0, total, cfg);
    if (n < 9)
        return -5;

    /* 找 HID 介面（優先 boot keyboard：class 3 / subclass 1 / protocol 1）與它的中斷 IN 端點 */
    int found = 0, cur_iface = -1, cur_boot = 0, best_boot = -1;
    int_ep = 0;
    for (int i = 0; i + 1 < n && cfg[i] >= 2; i += cfg[i]) {
        u8 type = cfg[i + 1];
        if (type == 4 && i + 8 < n) {
            cur_iface = (cfg[i + 5] == 3) ? cfg[i + 2] : -1;
            cur_boot  = (cfg[i + 5] == 3 && cfg[i + 6] == 1 && cfg[i + 7] == 1);
        } else if (type == 5 && i + 6 < n && cur_iface >= 0 &&
                   (cfg[i + 2] & 0x80) && (cfg[i + 3] & 3) == 3 && cur_boot > best_boot) {
            int_ep    = cfg[i + 2] & 0x0F;
            int_mps   = (cfg[i + 4] | (cfg[i + 5] << 8)) & 0x7FF;
            kbd_iface = cur_iface;
            best_boot = cur_boot;
            found = 1;
        }
    }
    if (!found) {
        xil_printf("USB: no HID interrupt IN endpoint found\r\n");
        return -6;
    }
    xil_printf("USB: HID interface %d%s, interrupt IN ep %d, max packet %d\r\n",
               kbd_iface, best_boot ? " (boot keyboard)" : "", int_ep, int_mps);

    if (ctrl_xfer(0x00, 9, cfg[5], 0, 0, NULL) < 0)     /* SET_CONFIGURATION */
        return -7;
    if (ctrl_xfer(0x21, 0x0B, 0, kbd_iface, 0, NULL) < 0)   /* SET_PROTOCOL(boot) */
        xil_printf("USB: SET_PROTOCOL failed (ignored)\r\n");
    if (ctrl_xfer(0x21, 0x0A, 0, kbd_iface, 0, NULL) < 0)   /* SET_IDLE(0)：只在按鍵變化時回報 */
        xil_printf("USB: SET_IDLE failed (ignored)\r\n");

    if (int_mps == 0 || int_mps > sizeof(int_buf))
        int_mps = 8;
    async_stop();
    qh_int.ep_char = ep_char(1, int_ep, int_mps, 0, 0);
    qh_int.token   = 0;                                  /* toggle 從 DATA0 開始 */
    async_start();
    int_pending = 0;
    return 0;
}

static int inited;                               /* 0：下次 usbh_kbd_open 要從 PHY 重設開始 */

int usbh_kbd_open(void)
{
    int r;

    if (!inited) {
        r = host_init();
        if (r)
            return r;
        inited = 1;
    }
    if (!usbh_connected())
        return 1;                                        /* 還沒插鍵盤：呼叫端過一下再來 */
    usleep(200000);                                      /* 插上後等電源穩定 */
    Xil_Out32(PORTSC, (Xil_In32(PORTSC) & ~PORT_PE) | PORT_W1C);

    r = port_reset();
    if (r) {
        xil_printf("USB: port reset failed (%d)\r\n", r);
        inited = 0;
        return -10 + r;
    }
    r = enumerate();
    if (r) {
        xil_printf("USB: enumeration failed (%d)\r\n", r);
        inited = 0;
        return -20 + r;
    }
    xil_printf("USB: keyboard ready\r\n");
    return 0;
}

int usbh_kbd_poll(u8 report[8])
{
    if (!usbh_connected()) {
        inited = 0;
        return -1;
    }
    if (!int_pending) {
        qtd_fill(&td_int, NULL, TOK_BYTES(int_mps) | TOK_CERR3 | TOK_PID_IN | TOK_IOC | TOK_ACTIVE, int_buf);
        qh_submit(&qh_int, &td_int);
        int_pending = 1;
        return 0;
    }
    u32 t = td_int.token;
    if (t & TOK_ACTIVE)
        return 0;
    int_pending = 0;
    if (t & TOK_ERRMASK) {
        xil_printf("USB: interrupt IN error, token %08x\r\n", t);
        inited = 0;
        return -2;
    }
    int got = (int)(int_mps - TOK_REMAIN(t));
    for (int i = 0; i < 8; i++)
        report[i] = (i < got) ? int_buf[i] : 0;
    return got > 0 ? 1 : 0;
}
