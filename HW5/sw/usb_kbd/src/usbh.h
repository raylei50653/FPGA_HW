/*
 * HW5 精簡 USB host（Zynq-7000 USB0，裸機）：只支援直接插在 J2 的一把 USB 鍵盤（HID boot protocol）
 * 規格見 HW5/SPEC.md §12
 */
#ifndef USBH_H
#define USBH_H

#include "xil_types.h"

/* 初始化 PHY 與控制器、列舉插在 J2 的鍵盤。成功傳回 0；還沒插鍵盤傳回 1；錯誤傳回負數 */
int usbh_kbd_open(void);

/* 讀一次鍵盤報告（8 byte boot report）。
 *   傳回 1：拿到新報告，存在 report；0：還沒有新報告；負數：錯誤或鍵盤拔掉了，要重新 usbh_kbd_open */
int usbh_kbd_poll(u8 report[8]);

/* 鍵盤是否還插著（PORTSC.CCS） */
int usbh_connected(void);

#endif
