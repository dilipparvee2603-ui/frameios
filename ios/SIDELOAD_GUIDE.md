# CFX FrameStudio for iOS — Sideload Installation Guide

This guide walks you through compiling the iOS `.ipa` and installing it on your iPhone from your Windows PC using **Sideloadly** (or **AltStore**) with your personal free Apple ID.

---

## Step 1: Build the `.ipa` using GitHub Actions

1. Commit and push the project to your GitHub repository:
   ```powershell
   git add ios/ .github/
   git commit -m "Add native iOS Swift project & build workflow"
   git push
   ```
2. Open your repository on GitHub in a web browser.
3. Click on the **Actions** tab at the top.
4. Select the **"Build iOS App (.IPA)"** workflow on the left and click **"Run workflow"** (or let it run automatically from your push).
5. Once completed (takes ~1 minute on Apple Silicon Mac runner), click on the workflow run.
6. Under **Artifacts**, download **`CFXFrameStudio-iOS-IPA`** and extract **`CFXFrameStudio.ipa`** to your PC.

---

## Step 2: Install Sideloadly on Windows

1. Download and install **Sideloadly** for Windows:
   - Official Link: [https://sideloadly.io](https://sideloadly.io)
2. Ensure you have **iTunes for Windows** (non-Microsoft Store version) or the Apple Mobile Device Support installed so your PC recognizes your iPhone over USB.

---

## Step 3: Sideload onto your iPhone

1. Connect your iPhone to your Windows PC using a USB cable.
2. Tap **"Trust This Computer"** on your iPhone screen and enter your device passcode.
3. Open **Sideloadly** on Windows:
   - Your connected iPhone will appear under **Device**.
   - Drag and drop **`CFXFrameStudio.ipa`** into the large IPA icon box on Sideloadly.
   - Enter your **Apple ID** (used by Apple to sign the app for free).
4. Click **Start**.
   - If prompted for your Apple ID password or 2-Factor Authentication code, enter it.
   - Sideloadly will cryptographically sign the app and install it onto your iPhone within 30 seconds.

---

## Step 4: First-Time Setup on iPhone

Before opening the app on your phone, Apple requires granting developer trust:

1. On your iPhone, open **Settings** > **General** > **VPN & Device Management**.
2. Under *Developer App*, tap on your **Apple ID email**.
3. Tap **"Trust [your email]"** and confirm.
4. **On iOS 16, 17, and 18**:
   - Go to **Settings** > **Privacy & Security** > scroll to the bottom.
   - Tap **Developer Mode** > turn it **ON** and reboot your phone when prompted.
5. Tap the **CFX Studio** icon on your home screen to launch!

---

## Re-signing Every 7 Days

Because free Apple IDs have a 7-day certificate limit:
- Once a week, simply plug your phone in, open Sideloadly, and click **Start** to refresh the app without losing any settings or data.
- Alternatively, if you set up **AltStore**, it can refresh automatically over your home Wi-Fi.
