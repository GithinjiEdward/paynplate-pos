# 🍽️ PayNPlate POS System

A modern, scalable Point of Sale (POS) mobile application built with Flutter, designed for small and medium-sized food businesses.

---

## 🚀 Overview

PayNPlate is a full-featured POS system that enables businesses to manage sales, inventory, staff, and analytics in a single mobile application. It is designed with an **offline-first architecture** and **cloud synchronization**, ensuring reliability even in low-connectivity environments.

---

## ✨ Key Features

### 🔐 Authentication & Multi-Business Support
- Secure login using Firebase Authentication
- Multi-business account structure
- Device-based session control and security

### 👥 Staff Management
- Role-based access (Admin / Staff)
- Staff account creation and control
- Session tracking and device locking

### 📦 Inventory Management
- Product categorization (Cooked, Raw, Drinks, etc.)
- Real-time stock tracking
- Automatic stock deduction during sales

### 💰 Sales & Transactions
- Fast checkout system
- Cart-based order processing
- Multiple payment methods (Cash / M-Pesa)
- Sequential business-based invoice IDs

### 🧾 Receipt System
- PDF receipt generation
- Local receipt storage
- Downloadable receipts for sharing and records
- (Upcoming) Bluetooth 80mm thermal printing

### ☁️ Cloud Synchronization
- Firestore integration for:
  - Products
  - Sales
  - Staff
- Automatic sync between devices

### 📊 Analytics Dashboard
- Daily revenue trends
- Monthly revenue analysis
- Visual charts using `fl_chart`

---

## 🛠️ Tech Stack

- **Frontend:** Flutter (Dart)
- **Backend:** Firebase (Authentication + Firestore)
- **Local Storage:** SQLite (`sqflite`)
- **Charts:** `fl_chart`
- **PDF Generation:** `pdf` & `printing`
- **State Handling:** Stateful widgets + async services

---

## 📱 Screenshots

<table>
  <tr>
    <td align="center">
      <b>Login</b><br>
      <a href="screenshots/Login.png">
        <img src="screenshots/Login.png" width="200"/>
      </a>
    </td>
    <td align="center">
      <b>Business Registration</b><br>
      <a href="screenshots/Business_Registration.png">
        <img src="screenshots/Business_Registration.png" width="200"/>
      </a>
    </td>
    <td align="center">
      <b>POS Dashboard</b><br>
      <a href="screenshots/Dashboard.png">
        <img src="screenshots/Dashboard.png" width="200"/>
      </a>
    </td>
  </tr>

  <tr>
    <td align="center">
      <b>Staff Management</b><br>
      <a href="screenshots/Staff_Management.png">
        <img src="screenshots/Staff_Management.png" width="200"/>
      </a>
    </td>
    <td align="center">
      <b>Menu Management</b><br>
      <a href="screenshots/Menu_Management.png">
        <img src="screenshots/Menu_Management.png" width="200"/>
      </a>
    </td>
    <td align="center">
      <b>Cart / Checkout</b><br>
      <a href="screenshots/Menu_Cart.png">
        <img src="screenshots/Menu_Cart.png" width="200"/>
      </a>
    </td>
  </tr>

  <tr>
    <td align="center">
      <b>Payment</b><br>
      <a href="screenshots/Payment.png">
        <img src="screenshots/Payment.png" width="200"/>
      </a>
    </td>
    <td align="center">
      <b>Receipt</b><br>
      <a href="screenshots/Invoice.png">
        <img src="screenshots/Invoice.png" width="200"/>
      </a>
    </td>
    <td align="center">
      <b>Weekly Analytics</b><br>
      <a href="screenshots/analytics_weekly.png">
        <img src="screenshots/analytics_weekly.png" width="200"/>
      </a>
    </td>
  </tr>

  <tr>
    <td align="center">
      <b>Monthly Analytics</b><br>
      <a href="screenshots/analytics_monthly.png">
        <img src="screenshots/analytics_monthly.png" width="200"/>
      </a>
    </td>
  </tr>
</table>