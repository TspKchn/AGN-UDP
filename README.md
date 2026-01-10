# 🚀 AGN-UDP (Hysteria v1 User Manager)

ระบบจัดการผู้ใช้ **Hysteria v1 (AGN-UDP)**  
ออกแบบมาเพื่อใช้งานร่วมกับ **Webmin / SSH / OpenVPN / 3x-ui**  
รองรับทั้ง **Manual Mode** และ **Sync Mode (Local / Remote VPS)**

---

## ✨ Features

### 🔹 User Management
- ➕ เพิ่มผู้ใช้ (username = password)
- ⏳ ต่ออายุผู้ใช้
- ❌ ลบผู้ใช้
- 📋 แสดงรายชื่อผู้ใช้และวันหมดอายุ

### 🔹 Sync System
- 🔁 Sync user จากเครื่องเดียวกัน (Local VPS)
- 🌐 Sync user จาก VPS อื่น (Remote VPS)
- 🔐 Login ด้วย username / password / port (ไม่ต้องใช้ SSH key)
- 📅 Sync วันหมดอายุจาก /etc/shadow จริง
- 🧠 กรองเฉพาะ user client จริง
  - UID ≥ 1000
  - ตัด nobody (65534) และ system users

### 🔹 Auto Mode
- 🟢 Manual Mode → Auto Delete เปิด
- 🔵 Sync Mode → Auto Delete ปิด
- ระบบสลับโหมดให้อัตโนมัติ

---

## 🗂️ Repository Structure

AGN-UDP/
├── install.sh
├── agnudp
├── README.md
└── LICENSE

---

## ⚙️ Installation
```
curl -fsSL https://raw.githubusercontent.com/TspKchn/AGN-UDP/main/install.sh | bash

```
หลังติดตั้งเสร็จ ใช้คำสั่ง:

agnudp

---

## 🔁 Sync

- Sync Local: ดึง user จากเครื่องเดียวกัน
- Sync Remote: ดึง user จาก VPS อื่นผ่าน SSH

---

## 💾 Backup & Restore

- Backup: /backup/agnudp-backup.7z
- Restore: ผ่าน HTTP จาก VPS อื่น

---

## ⏰ Cron
- Sync ทุกคืน
- Cleanup อัตโนมัติ (เฉพาะ Manual Mode)

---

## 👨‍💻 Author
GitHub: https://github.com/TspKchn

MIT License
