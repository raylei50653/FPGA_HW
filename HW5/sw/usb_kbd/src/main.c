/*
 * HW5 USB 鍵盤 → PL（規格見 HW5/SPEC.md §12）
 *
 * PS 上的裸機程式：當 USB host 讀插在 J2 的鍵盤，把按鍵狀態寫進 AXI GPIO（kbd_gpio），PL 的 HW_5_pong 從
 * kbd[7:0] 讀：
 *
 *   bit 0  W   左球拍往上        bit 3  ↑   右球拍往上
 *   bit 1  S   左球拍往下        bit 4  ↓   右球拍往下
 *   bit 2  D   左方發球          bit 5  ←   右方發球
 *   bit 6  鍵盤已連線（LD1）      bit 7  PS 心跳，約 2 Hz 翻轉（LD2）
 *
 * 除錯訊息從 UART1（板上的 USB-UART，115200 8N1）印出。
 */
#include "xparameters.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xtime_l.h"
#include "sleep.h"
#include "usbh.h"

#define KBD_GPIO_DATA   (XPAR_KBD_GPIO_BASEADDR + 0x0)

/* HID usage ID（USB HID Usage Tables，Keyboard page） */
#define KEY_D       0x07
#define KEY_S       0x16
#define KEY_W       0x1A
#define KEY_RIGHT   0x4F
#define KEY_LEFT    0x50
#define KEY_DOWN    0x51
#define KEY_UP      0x52

#define BIT_W       0x01
#define BIT_S       0x02
#define BIT_D       0x04
#define BIT_UP      0x08
#define BIT_DOWN    0x10
#define BIT_LEFT    0x20
#define BIT_KBD_OK  0x40
#define BIT_ALIVE   0x80

static u32 keys;        /* bit 0 ~ 5 */
static u32 kbd_ok;      /* BIT_KBD_OK 或 0 */
static u32 alive;       /* BIT_ALIVE 或 0 */

static void gpio_update(void)
{
    Xil_Out32(KBD_GPIO_DATA, keys | kbd_ok | alive);
}

/* boot report：byte 0 修飾鍵、byte 1 保留、byte 2 ~ 7 目前按著的鍵 */
static u32 decode(const u8 r[8])
{
    u32 k = 0;
    for (int i = 2; i < 8; i++) {
        switch (r[i]) {
        case KEY_W:    k |= BIT_W;    break;
        case KEY_S:    k |= BIT_S;    break;
        case KEY_D:    k |= BIT_D;    break;
        case KEY_UP:   k |= BIT_UP;   break;
        case KEY_DOWN: k |= BIT_DOWN; break;
        case KEY_LEFT: k |= BIT_LEFT; break;
        default: break;
        }
    }
    return k;
}

/* 心跳：每 250 ms 翻轉一次 */
static void heartbeat(void)
{
    static XTime last;
    XTime t;
    XTime_GetTime(&t);
    if (t - last >= COUNTS_PER_SECOND / 4) {
        last = t;
        alive ^= BIT_ALIVE;
        gpio_update();
    }
}

int main(void)
{
    u8 report[8];

    Xil_DCacheDisable();                 /* USB 控制器用 DMA 讀寫 QH / qTD，關掉 cache 免得要手動清 */
    xil_printf("\r\nHW5 USB keyboard host\r\n");
    xil_printf("Left: W / S move, D serve.  Right: Up / Down move, Left arrow serve.\r\n");

    keys = kbd_ok = alive = 0;
    gpio_update();

    for (;;) {
        /* 等鍵盤、列舉；沒插或失敗就隔 0.5 s 再試，等待期間心跳照常 */
        int waiting = 0;
        for (;;) {
            int r = usbh_kbd_open();
            if (r == 0)
                break;
            if (r == 1 && !waiting) {
                xil_printf("USB: waiting for a keyboard on J2...\r\n");
                waiting = 1;
            }
            keys = 0;
            kbd_ok = 0;
            gpio_update();
            for (int i = 0; i < 20; i++) {
                heartbeat();
                usleep(25000);
            }
        }
        kbd_ok = BIT_KBD_OK;
        keys = 0;
        gpio_update();

        /* 讀報告，直到錯誤或拔掉 */
        for (;;) {
            heartbeat();
            int r = usbh_kbd_poll(report);
            if (r < 0)
                break;
            if (r > 0) {
                u32 k = decode(report);
                if (k != keys) {
                    keys = k;
                    gpio_update();
                    xil_printf("keys %02x  (report %02x %02x %02x %02x %02x %02x %02x %02x)\r\n", keys,
                               report[0], report[1], report[2], report[3],
                               report[4], report[5], report[6], report[7]);
                }
            }
        }
        xil_printf("USB: keyboard lost, restarting\r\n");
        keys = 0;
        kbd_ok = 0;
        gpio_update();
        usleep(100000);
    }
    return 0;
}
