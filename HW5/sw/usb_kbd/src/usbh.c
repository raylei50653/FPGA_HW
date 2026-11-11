/*
 * HW5 精簡 USB host（Zynq-7000 USB0，裸機）
 *
 * Zynq 的 USB 控制器在 host 模式是 EHCI 相容的。Xilinx 的裸機驅動 XUsbPs 只做 device 模式，所以這裡直接
 * 操作暫存器，只做「讀一把 USB 鍵盤」需要的最少功能：
 *
 *   1. MIO 46 拉低再放開，重設 USB3320 PHY（《EGO-XZ7 硬體手冊》V1.2 表 10：USB_RESET#）
 *   2. 控制器重設、切成 host 模式；經 ULPI 開 PHY 的 VBUS 輸出（USB3320 的 CPEN 控制 5V 開關 MIC2025）
 *   3. 兩個 schedule：
 *      - async：qh_ctrl（端點 0，控制傳輸）與 qh_int（直接插在 root port 的鍵盤的中斷 IN 端點）串成環
 *      - periodic：frame list 每 8 個 frame（8 ms）指向 qh_per（接在 hub 後面的鍵盤的中斷 IN 端點）
 *   4. root port 有裝置插上 → port reset → 列舉
 *      - 是 hub（板上 J2 後面的 GL850A，05E3:0608）：設定 hub、打開每個埠的電源，之後每次呼叫
 *        usbh_kbd_open 掃一遍 hub 的埠，找到有裝置的埠就 hub port reset、列舉
 *      - 是鍵盤：直接用
 *   5. 鍵盤：讀組態找 HID boot keyboard 介面、SET_CONFIGURATION、SET_PROTOCOL(boot)、SET_IDLE(0)，
 *      之後每次在中斷 QH 掛一個 8 byte 的 IN qTD，鍵盤有按鍵變化才回資料（沒有變化就 NAK）
 *
 * hub 是高速的，後面的低速 / 全速鍵盤要經 hub 的 transaction translator（TT）：QH 填 hub 位址與埠號，
 * 控制器自動送 start-split / complete-split。中斷端點的 split 一定要放在 periodic schedule
 * （S-mask = microframe 0 送 start-split，C-mask = microframe 2 ~ 4 收 complete-split）；
 * 放在 async schedule 會被當成 bulk，而低速裝置不能做 bulk。
 * 直接插在 root port 的低速 / 全速鍵盤走控制器內建的 TT（TTCTRL 的 hub 位址 0），中斷端點放在 async schedule。
 *
 * 為了不必處理 cache 一致性，main() 一開始就把 D-cache 關掉（Xil_DCacheDisable）。
 * 暫存器位址與位元定義見 SDK 2018.3 的 xusbps_hw.h；QH、qTD 的格式見 EHCI 規格 §3.5、§3.6；
 * hub 的類別請求見 USB 2.0 規格 §11.24。
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
#define PERIODICLISTBASE (USB_BASE + 0x154)
#define ASYNCLISTADDR   (USB_BASE + 0x158)
#define ULPIVIEW        (USB_BASE + 0x170)
#define PORTSC          (USB_BASE + 0x184)
#define USBMODE         (USB_BASE + 0x1A8)

#define CMD_RS          0x00000001u
#define CMD_RST         0x00000002u
#define CMD_FS_MASK     0x0000800Cu             /* frame list 大小；0 = 1024 個 */
#define CMD_PSE         0x00000010u
#define CMD_ASE         0x00000020u
#define STS_HCH         0x00001000u
#define STS_PS          0x00004000u
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

/* ---- hub 類別請求（USB 2.0 §11.24） ---- */
#define HUB_PS_CONNECTION   0x00000001u         /* wPortStatus */
#define HUB_PS_ENABLE       0x00000002u
#define HUB_PS_LOW_SPEED    0x00000200u
#define HUB_PS_HIGH_SPEED   0x00000400u
#define HUB_PC_CONNECTION   0x00010000u         /* wPortChange（放在高 16 bit） */
#define HUB_PC_RESET        0x00100000u
#define HUB_F_PORT_RESET    4                   /* feature selector */
#define HUB_F_PORT_POWER    8
#define HUB_F_C_CONNECTION  16
#define HUB_F_C_RESET       20

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

#define SPLIT_SMASK     0x01u                   /* microframe 0 送 start-split */
#define SPLIT_CMASK     0x1Cu                   /* microframe 2、3、4 收 complete-split */
#define POLL_FRAMES     8                       /* 中斷端點每 8 ms 輪詢一次 */

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

/* 一個 USB 裝置：位址、速度，以及經哪個 hub 的哪個埠（split transaction 要用） */
typedef struct {
    u32 addr;
    u32 speed;                                   /* 0 全速、1 低速、2 高速（和 EHCI 的 EPS 編碼相同） */
    u32 mps0;                                    /* 端點 0 的封包大小 */
    u32 hub;                                     /* 上游 hub 的位址；0 = 直接接在 root port */
    u32 port;                                    /* 上游 hub 的埠號 */
} usbdev_t;

static volatile u32 frame_list[1024] __attribute__((aligned(4096)));
static qh_t  qh_ctrl, qh_int, qh_per;
static qtd_t td_setup, td_data, td_status, td_int;
static u8 setup_buf[8]   __attribute__((aligned(32)));
static u8 data_buf[256]  __attribute__((aligned(256)));
static u8 int_buf[64]    __attribute__((aligned(64)));
static u8 cfg_buf[256];

static XGpioPs gpio_ps;
static usbdev_t root_dev;                        /* 插在 root port 上的裝置（hub 或鍵盤），位址 1 */
static usbdev_t hub_kbd;                         /* 接在 hub 後面的鍵盤，位址 = 1 + 埠號 */
static usbdev_t *kbd;                            /* 目前用的鍵盤：&root_dev 或 &hub_kbd */

static qh_t *int_qh = &qh_int;                   /* 鍵盤中斷端點用哪個 QH */
static int int_periodic;                         /* 1：int_qh 在 periodic schedule */
static u32 int_ep, int_mps, kbd_iface;
static int int_pending;

static int inited;                               /* 0：下次 usbh_kbd_open 要從 PHY 重設開始 */
static int hub_ready;                            /* 1：root port 上的 hub 已設定好 */
static u32 hub_nports;
static u32 port_skip;                            /* 試過、不是鍵盤或失敗的 hub 埠（拔掉才再試） */

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

/* 開關 async（CMD_ASE / STS_AS）或 periodic（CMD_PSE / STS_PS）schedule，等狀態跟上。
 * 改 QH 前先關、改完再開，避免控制器讀到改到一半的 QH */
static void sched_set(int periodic, int on)
{
    u32 cmd = periodic ? CMD_PSE : CMD_ASE;
    u32 sts = periodic ? STS_PS : STS_AS;
    u32 v = Xil_In32(USBCMD);
    Xil_Out32(USBCMD, on ? (v | cmd) : (v & ~cmd));
    wait_reg(USBSTS, sts, on ? sts : 0, 10000);
}

static u32 qh_char(u32 addr, u32 ep, u32 speed, u32 mps, int control, int head)
{
    u32 v = addr | (ep << 8) | (speed << 12) | (mps << 16);
    if (control)
        v |= (1u << 14);                         /* DTC：控制傳輸的 toggle 由 qTD 決定 */
    if (control && speed != 2)
        v |= (1u << 27);                         /* C：非高速的控制端點 */
    if (head)
        v |= (1u << 15);                         /* H：async list 的頭 */
    return v;
}

/* Mult = 1；非高速裝置接在 hub 後面時填 hub 位址與埠號（split transaction） */
static u32 qh_cap(const usbdev_t *d, u32 smask, u32 cmask)
{
    u32 v = (1u << 30) | (cmask << 8) | smask;
    if (d->hub && d->speed != 2)
        v |= (d->port << 23) | (d->hub << 16);
    return v;
}

static void qh_init(qh_t *qh, qh_t *next, u32 chr, u32 cap)
{
    qh->hlink    = next ? ((u32)next | LINK_QH) : LINK_TERM;
    qh->ep_char  = chr;
    qh->ep_cap   = cap;
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

/* 把 qTD 掛到 QH 上（first = NULL：取消 QH 上正在做的傳輸）
 *   overlay 的 DT 位元要留著：中斷端點的 DATA0 / DATA1 交替記在這裡，清掉的話每隔一個報告就會被當成重送丟掉 */
static void qh_load(qh_t *qh, qtd_t *first, int periodic)
{
    sched_set(periodic, 0);
    qh->alt_qtd  = LINK_TERM;
    qh->token    = qh->token & TOK_DT;
    qh->next_qtd = first ? (u32)first : LINK_TERM;
    sched_set(periodic, 1);
}

/* 控制傳輸。data 方向由 bmRequestType bit 7 決定。成功傳回實際傳了幾個 byte，失敗傳回負數 */
static int ctrl_xfer(const usbdev_t *d, u8 rtype, u8 req, u16 value, u16 index, u16 len, void *data)
{
    int in = (rtype & 0x80) != 0;
    u8 *p = (u8 *)data;

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
            data_buf[i] = p[i];

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

    /* qh_ctrl 每次都重新指向這次的裝置（hub 或鍵盤） */
    sched_set(0, 0);
    qh_ctrl.ep_char  = qh_char(d->addr, 0, d->speed, d->mps0, 1, 1);
    qh_ctrl.ep_cap   = qh_cap(d, 0, 0);
    qh_ctrl.alt_qtd  = LINK_TERM;
    qh_ctrl.token    = 0;
    qh_ctrl.next_qtd = (u32)&td_setup;
    sched_set(0, 1);

    u64 t0 = now_us();
    for (;;) {
        u32 s0 = td_setup.token, s1 = len ? td_data.token : 0, s2 = td_status.token;
        if ((s0 | s1 | s2) & TOK_HALTED) {
            xil_printf("  ctrl %d: %02x/%02x failed: setup %08x data %08x status %08x\r\n",
                       d->addr, rtype, req, s0, s1, s2);
            return -1;
        }
        if (!(s2 & TOK_ACTIVE))
            break;
        if (now_us() - t0 > 500000) {
            xil_printf("  ctrl %d: %02x/%02x timeout: setup %08x data %08x status %08x\r\n",
                       d->addr, rtype, req, s0, s1, s2);
            qh_load(&qh_ctrl, NULL, 0);
            return -2;
        }
    }
    int got = len ? (int)(len - TOK_REMAIN(td_data.token)) : 0;
    if (in)
        for (int i = 0; i < got; i++)
            p[i] = data_buf[i];
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

    /* async：qh_ctrl ⇄ qh_int；periodic：每 POLL_FRAMES 個 frame 指向 qh_per（還沒掛 qTD，什麼都不送） */
    static const usbdev_t none = { 0, 0, 8, 0, 0 };
    qh_init(&qh_ctrl, &qh_int, qh_char(0, 0, 0, 8, 1, 1), qh_cap(&none, 0, 0));
    qh_init(&qh_int, &qh_ctrl, qh_char(0, 1, 0, 8, 0, 0), qh_cap(&none, 0, 0));
    qh_init(&qh_per, NULL, qh_char(0, 1, 0, 8, 0, 0), qh_cap(&none, SPLIT_SMASK, 0));
    for (int i = 0; i < 1024; i++)
        frame_list[i] = (i % POLL_FRAMES == 0) ? ((u32)&qh_per | LINK_QH) : LINK_TERM;
    Xil_Out32(ASYNCLISTADDR, (u32)&qh_ctrl);
    Xil_Out32(PERIODICLISTBASE, (u32)frame_list);
    Xil_Out32(USBCMD, (Xil_In32(USBCMD) & ~CMD_FS_MASK) | CMD_RS);
    if (wait_reg(USBSTS, STS_HCH, 0, 100000)) {
        xil_printf("USB: controller does not start\r\n");
        return -3;
    }
    sched_set(0, 1);
    sched_set(1, 1);
    int_qh = &qh_int;
    int_periodic = 0;
    int_pending = 0;
    hub_ready = 0;
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
    root_dev.speed = PORT_PSPD(v);
    return 0;
}

/* ---- 列舉 ----
 * 剛 reset 完的裝置在位址 0：讀 device descriptor、SET_ADDRESS(addr)、讀完整的 configuration descriptor。
 * 成功傳回 configuration descriptor 的長度（放在 cfg_buf），失敗傳回負數 */
static int dev_enum(usbdev_t *d, u32 addr, u8 dd[18])
{
    int n;

    d->addr = 0;
    d->mps0 = (d->speed == 2) ? 64 : 8;
    n = ctrl_xfer(d, 0x80, 6, 0x0100, 0, 8, dd);       /* GET_DESCRIPTOR(device)，先讀 8 byte */
    if (n < 8)
        return -1;
    d->mps0 = dd[7] ? dd[7] : 8;

    if (ctrl_xfer(d, 0x00, 5, addr, 0, 0, NULL) < 0)    /* SET_ADDRESS */
        return -2;
    usleep(20000);
    d->addr = addr;

    n = ctrl_xfer(d, 0x80, 6, 0x0100, 0, 18, dd);
    if (n < 18)
        return -3;
    xil_printf("USB: device %02x%02x:%02x%02x, class %02x, ep0 max packet %d, address %d\r\n",
               dd[9], dd[8], dd[11], dd[10], dd[4], d->mps0, d->addr);

    n = ctrl_xfer(d, 0x80, 6, 0x0200, 0, 9, cfg_buf);   /* GET_DESCRIPTOR(configuration) */
    if (n < 9)
        return -4;
    u16 total = cfg_buf[2] | (cfg_buf[3] << 8);
    if (total > sizeof(cfg_buf))
        total = sizeof(cfg_buf);
    n = ctrl_xfer(d, 0x80, 6, 0x0200, 0, total, cfg_buf);
    if (n < 9)
        return -5;
    return n;
}

/* 在 cfg_buf 裡找 HID 介面（優先 boot keyboard：class 3 / subclass 1 / protocol 1）與它的中斷 IN 端點，
 * 設定好鍵盤、把中斷 QH 指向它 */
static int kbd_setup(usbdev_t *d, int n)
{
    const u8 *cfg = cfg_buf;
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

    if (ctrl_xfer(d, 0x00, 9, cfg[5], 0, 0, NULL) < 0)      /* SET_CONFIGURATION */
        return -7;
    if (ctrl_xfer(d, 0x21, 0x0B, 0, kbd_iface, 0, NULL) < 0)    /* SET_PROTOCOL(boot) */
        xil_printf("USB: SET_PROTOCOL failed (ignored)\r\n");
    if (ctrl_xfer(d, 0x21, 0x0A, 0, kbd_iface, 0, NULL) < 0)    /* SET_IDLE(0)：只在按鍵變化時回報 */
        xil_printf("USB: SET_IDLE failed (ignored)\r\n");

    if (int_mps == 0 || int_mps > sizeof(int_buf))
        int_mps = 8;

    /* 接在 hub 後面：periodic schedule 的 qh_per；直接插在 root port：async schedule 的 qh_int */
    int_periodic = (d->hub != 0);
    int_qh = int_periodic ? &qh_per : &qh_int;
    sched_set(int_periodic, 0);
    int_qh->ep_char  = qh_char(d->addr, int_ep, d->speed, int_mps, 0, 0);
    int_qh->ep_cap   = int_periodic ? qh_cap(d, SPLIT_SMASK, d->speed == 2 ? 0 : SPLIT_CMASK) : qh_cap(d, 0, 0);
    int_qh->alt_qtd  = LINK_TERM;
    int_qh->next_qtd = LINK_TERM;
    int_qh->token    = 0;                                   /* toggle 從 DATA0 開始 */
    sched_set(int_periodic, 1);
    int_pending = 0;
    kbd = d;
    return 0;
}

/* ---- hub ---- */
static int hub_port_status(u32 port, u32 *st)
{
    u8 b[4];
    if (ctrl_xfer(&root_dev, 0xA3, 0, 0, port, 4, b) < 4)     /* GET_STATUS(port) */
        return -1;
    *st = b[0] | (b[1] << 8) | (b[2] << 16) | ((u32)b[3] << 24);
    return 0;
}

static int hub_feature(int set, u32 feature, u32 port)
{
    return ctrl_xfer(&root_dev, 0x23, set ? 3 : 1, feature, port, 0, NULL);  /* SET_ / CLEAR_FEATURE */
}

/* 設定 root port 上的 hub：SET_CONFIGURATION、讀 hub descriptor、打開每個埠的電源 */
static int hub_setup(void)
{
    u8 hd[8];

    if (ctrl_xfer(&root_dev, 0x00, 9, cfg_buf[5], 0, 0, NULL) < 0)   /* SET_CONFIGURATION */
        return -1;
    int n = ctrl_xfer(&root_dev, 0xA0, 6, 0x2900, 0, sizeof(hd), hd);   /* GET_DESCRIPTOR(hub) */
    if (n < 6)
        return -2;
    hub_nports = hd[2] > 15 ? 15 : hd[2];
    u32 pwr_ms = 2u * hd[5];                         /* bPwrOn2PwrGood，單位 2 ms */
    for (u32 p = 1; p <= hub_nports; p++)
        if (hub_feature(1, HUB_F_PORT_POWER, p) < 0)
            return -3;
    usleep((pwr_ms < 100 ? 100 : pwr_ms) * 1000);
    xil_printf("USB: hub with %d ports, ports powered\r\n", hub_nports);
    port_skip = 0;
    hub_ready = 1;
    return 0;
}

/* hub 的埠 reset，完成後由狀態讀出速度 */
static int hub_port_reset(u32 port, u32 *speed)
{
    u32 st = 0;

    usleep(100000);                                  /* 插上後的去彈跳時間（USB 2.0 §7.1.7.3） */
    if (hub_feature(1, HUB_F_PORT_RESET, port) < 0)
        return -1;
    u64 t0 = now_us();
    do {
        usleep(10000);
        if (hub_port_status(port, &st))
            return -2;
        if (now_us() - t0 > 500000)
            return -3;
    } while (!(st & HUB_PC_RESET));
    hub_feature(0, HUB_F_C_RESET, port);
    usleep(20000);                                   /* reset recovery */
    *speed = (st & HUB_PS_LOW_SPEED) ? 1 : (st & HUB_PS_HIGH_SPEED) ? 2 : 0;
    xil_printf("USB: hub port %d reset done, status %08x, speed %s\r\n", port, st,
               *speed == 1 ? "low" : *speed == 2 ? "high" : "full");
    if (!(st & HUB_PS_ENABLE))
        return -4;
    return 0;
}

/* 掃一遍 hub 的埠，找到鍵盤傳回 0；沒有傳回 1；hub 本身出錯傳回負數 */
static int hub_scan(void)
{
    u8 dd[18];

    for (u32 p = 1; p <= hub_nports; p++) {
        u32 st, speed, bit = 1u << p;
        if (hub_port_status(p, &st)) {
            xil_printf("USB: hub GET_STATUS failed\r\n");
            return -1;
        }
        if (st & HUB_PC_CONNECTION)
            hub_feature(0, HUB_F_C_CONNECTION, p);
        if (!(st & HUB_PS_CONNECTION)) {
            port_skip &= ~bit;                       /* 拔掉了，下次插上再試 */
            continue;
        }
        if (port_skip & bit)
            continue;
        port_skip |= bit;                            /* 失敗或不是鍵盤就先跳過，拔掉再插才重試 */

        xil_printf("USB: device on hub port %d\r\n", p);
        int r = hub_port_reset(p, &speed);
        if (r) {
            xil_printf("USB: hub port %d reset failed (%d)\r\n", p, r);
            continue;
        }
        hub_kbd.speed = speed;
        hub_kbd.hub   = root_dev.addr;
        hub_kbd.port  = p;
        int n = dev_enum(&hub_kbd, 1 + p, dd);
        if (n < 0) {
            xil_printf("USB: hub port %d enumeration failed (%d)\r\n", p, n);
            continue;
        }
        if (kbd_setup(&hub_kbd, n))
            continue;
        port_skip &= ~bit;                           /* 是鍵盤：之後出錯可以重新列舉 */
        xil_printf("USB: keyboard ready on hub port %d\r\n", p);
        return 0;
    }
    return 1;
}

/* ---- 對外介面 ---- */
int usbh_kbd_open(void)
{
    u8 dd[18];
    int r, n;

    if (!inited) {
        r = host_init();
        if (r)
            return r;
        inited = 1;
    }
    if (!usbh_connected()) {
        hub_ready = 0;
        return 1;                                        /* root port 沒東西：呼叫端過一下再來 */
    }
    if (hub_ready) {
        r = hub_scan();
        if (r < 0)
            inited = 0;
        return r;
    }

    usleep(200000);                                      /* 插上後等電源穩定 */
    Xil_Out32(PORTSC, (Xil_In32(PORTSC) & ~PORT_PE) | PORT_W1C);
    r = port_reset();
    if (r) {
        xil_printf("USB: port reset failed (%d)\r\n", r);
        inited = 0;
        return -10 + r;
    }
    root_dev.hub  = 0;
    root_dev.port = 0;
    n = dev_enum(&root_dev, 1, dd);
    if (n < 0) {
        xil_printf("USB: enumeration failed (%d)\r\n", n);
        inited = 0;
        return -20 + n;
    }
    if (dd[4] == 9) {                                    /* device class 9 = hub */
        r = hub_setup();
        if (r) {
            xil_printf("USB: hub setup failed (%d)\r\n", r);
            inited = 0;
            return -30 + r;
        }
        r = hub_scan();
        if (r < 0)
            inited = 0;
        return r;
    }
    r = kbd_setup(&root_dev, n);
    if (r) {
        xil_printf("USB: enumeration failed (%d)\r\n", r);
        inited = 0;
        return -20 + r;
    }
    xil_printf("USB: keyboard ready\r\n");
    return 0;
}

/* 鍵盤不能用了：取消中斷傳輸。直接插在 root port 的話整個重來；接在 hub 後面的話 hub 留著，下次重新掃埠 */
static int kbd_lost(int r)
{
    qh_load(int_qh, NULL, int_periodic);
    int_pending = 0;
    if (!usbh_connected() || kbd == &root_dev)
        inited = 0;
    return r;
}

int usbh_kbd_poll(u8 report[8])
{
    static u64 last_check;

    if (!usbh_connected())
        return kbd_lost(-1);

    /* 接在 hub 後面：每 0.5 s 問一次 hub 那個埠還插著沒 */
    if (kbd->hub) {
        u64 t = now_us();
        if (t - last_check > 500000) {
            u32 st;
            last_check = t;
            if (hub_port_status(kbd->port, &st) || !(st & HUB_PS_CONNECTION))
                return kbd_lost(-1);
        }
    }

    if (!int_pending) {
        qtd_fill(&td_int, NULL, TOK_BYTES(int_mps) | TOK_CERR3 | TOK_PID_IN | TOK_IOC | TOK_ACTIVE, int_buf);
        qh_load(int_qh, &td_int, int_periodic);
        int_pending = 1;
        return 0;
    }
    u32 t = td_int.token;
    if (t & TOK_ACTIVE)
        return 0;
    int_pending = 0;
    if (t & TOK_ERRMASK) {
        xil_printf("USB: interrupt IN error, token %08x\r\n", t);
        return kbd_lost(-2);
    }
    int got = (int)(int_mps - TOK_REMAIN(t));
    for (int i = 0; i < 8; i++)
        report[i] = (i < got) ? int_buf[i] : 0;
    return got > 0 ? 1 : 0;
}
