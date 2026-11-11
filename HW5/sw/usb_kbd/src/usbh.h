/*
 * HW5 精簡 USB host（Zynq-7000 USB0，裸機）：讀一把 USB 鍵盤（HID boot protocol），鍵盤可以直接插在
 * root port，或接在 root port 上的一個 hub 後面（EGO-XZ7 的 J2 後面就是 GL850A hub）
 * 規格見 HW5/SPEC.md §12
 */
#ifndef USBH_H
#define USBH_H

#include "xil_types.h"

/* 初始化 PHY 與控制器、列舉鍵盤（經 hub 時會掃 hub 的每個埠）。
 *   成功傳回 0；還沒插鍵盤傳回 1；錯誤傳回負數。沒有鍵盤時呼叫端隔一下再呼叫 */
int usbh_kbd_open(void);

/* 讀一次鍵盤報告（8 byte boot report）。
 *   傳回 1：拿到新報告，存在 report；0：還沒有新報告；負數：錯誤或鍵盤拔掉了，要重新 usbh_kbd_open */
int usbh_kbd_poll(u8 report[8]);

/* root port 上有沒有裝置（PORTSC.CCS） */
int usbh_connected(void);

#endif
