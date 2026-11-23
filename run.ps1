$ErrorActionPreference = "Continue"

# 1. Install & Connect Tailscale
Write-Host "Menginstall Tailscale..."
Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi" -OutFile "tailscale.msi"
Start-Process msiexec.exe -ArgumentList "/i tailscale.msi /qn /norestart" -Wait
Start-Sleep -Seconds 5

$tsExe = "C:\Program Files\Tailscale\tailscale.exe"
& $tsExe up --authkey="$env:TS_AUTHKEY" --hostname="gh-rdp-$(Get-Random -Maximum 9999)" --unattended
Start-Sleep -Seconds 5
$tsIP = (& $tsExe ip -4).Trim()

# 2. Setup RDP, Firewall & Generate Profil Asli administrator1
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
New-NetFirewallRule -DisplayName "Allow Estafet HTTP 8888" -Direction Inbound -Protocol TCP -LocalPort 8888 -Action Allow -ErrorAction SilentlyContinue | Out-Null

net user administrator1 "$env:RDP_PASSWORD" /add /Y
net localgroup Administrators administrator1 /add
net localgroup "Remote Desktop Users" administrator1 /add

$pass = ConvertTo-SecureString "$env:RDP_PASSWORD" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ("administrator1", $pass)
Start-Process -FilePath "cmd.exe" -ArgumentList "/c exit" -Credential $cred -LoadUserProfile -Wait

$desktopPath = "C:\Users\administrator1\Desktop"
icacls "C:\Users\administrator1" /grant "administrator1:(OI)(CI)F" /T /Q | Out-Null

# 3. Sedot & Restore Backup TAR via IP Tailscale sesi sebelumnya (jika ada)
$backupUrl = $env:BACKUP_URL
if (-not [string]::IsNullOrWhiteSpace($backupUrl)) {
    try {
        Write-Host "Menyedot backup.tar dari http://$backupUrl/backup.tar ..."
        Invoke-WebRequest -Uri "http://$backupUrl/backup.tar" -OutFile "C:\backup_in.tar" -TimeoutSec 180
        New-Item -ItemType Directory -Force -Path "C:\restore_temp" | Out-Null
        tar -xf "C:\backup_in.tar" -C "C:\restore_temp"
        Remove-Item "C:\backup_in.tar" -Force

        if (Test-Path "C:\restore_temp\desktop") {
            robocopy "C:\restore_temp\desktop" $desktopPath /E /NFL /NDL /NJH /NJS | Out-Null
        }
        if (Test-Path "C:\restore_temp\extra_1") {
            New-Item -ItemType Directory -Force -Path "C:\Users\administrator1\AppData\Roaming\NamaAplikasi" | Out-Null
            robocopy "C:\restore_temp\extra_1" "C:\Users\administrator1\AppData\Roaming\NamaAplikasi" /E /NFL /NDL /NJH /NJS | Out-Null
        }
        if (Test-Path "C:\restore_temp\extra_2") {
            New-Item -ItemType Directory -Force -Path "C:\ProgramData\NamaFolder" | Out-Null
            robocopy "C:\restore_temp\extra_2" "C:\ProgramData\NamaFolder" /E /NFL /NDL /NJH /NJS | Out-Null
        }

        Remove-Item "C:\restore_temp" -Recurse -Force
        icacls "C:\Users\administrator1" /grant "administrator1:(OI)(CI)F" /T /Q | Out-Null
        Write-Host "Backup TAR berhasil di-restore!"
    } catch {
        Write-Host "Gagal restore backup: $($_.Exception.Message)"
    }
}

# 4. Auto-Start start.bat sebagai Administrator (Highest) via schtasks.exe
$startScript = "C:\Users\administrator1\Desktop\start.bat"
if (Test-Path $startScript) {
    schtasks.exe /Create /TN "AutoStartDesktop" /TR "cmd.exe /c `"$startScript`"" /SC ONCE /ST 00:00 /RU "administrator1" /RP "$env:RDP_PASSWORD" /RL HIGHEST /F
    schtasks.exe /Run /TN "AutoStartDesktop"
    Write-Host "start.bat berhasil dijalankan dalam mode Administrator (HIGHEST)."
} else {
    Write-Host "File start.bat tidak ditemukan, melewati auto-start."
}

# 5. Tampilkan Info Koneksi di Log (+ Telegram jika token diisi)
Write-Host "========================================"
Write-Host "RDP TAILSCALE AKTIF!"
Write-Host "IP Host : $tsIP"
Write-Host "User    : administrator1"
Write-Host "========================================"

if (-not [string]::IsNullOrWhiteSpace($env:TG_BOT_TOKEN) -and -not [string]::IsNullOrWhiteSpace($env:TG_CHAT_ID)) {
    $msg = "RDP Tailscale Aktif!`nIP: $tsIP`nUser: administrator1`nPass: $($env:RDP_PASSWORD)"
    $tgUri = "https://api.telegram.org/bot$($env:TG_BOT_TOKEN)/sendMessage"
    Invoke-RestMethod -Uri $tgUri -Method Post -Body @{ chat_id = $env:TG_CHAT_ID; text = $msg }
}

# 6. Tunggu 348 menit (5 jam 48 menit)
Start-Sleep -Seconds (348 * 60)

# 7. Packing Desktop & Path Tambahan ke backup.tar
New-Item -ItemType Directory -Force -Path "C:\transfer_out\pack" | Out-Null
robocopy $desktopPath "C:\transfer_out\pack\desktop" /E /XF desktop.ini *.lnk /XD node_modules .git __pycache__ | Out-Null

$path1 = "C:\Users\administrator1\AppData\Roaming\NamaAplikasi"
if (Test-Path $path1) { robocopy $path1 "C:\transfer_out\pack\extra_1" /E /XD Cache "Code Cache" GPUCache | Out-Null }

$path2 = "C:\ProgramData\NamaFolder"
if (Test-Path $path2) { robocopy $path2 "C:\transfer_out\pack\extra_2" /E | Out-Null }

$items = Get-ChildItem -Path "C:\transfer_out\pack" -Recurse -File
$backupHost = ""

if ($items.Count -gt 0) {
    tar -cf "C:\transfer_out\backup.tar" -C "C:\transfer_out\pack" .
    Start-Process -FilePath "python" -ArgumentList "-m http.server 8888 --bind $tsIP --directory C:\transfer_out" -NoNewWindow
    Start-Sleep -Seconds 3
    $backupHost = "$($tsIP):8888"
}

# 8. Trigger sesi estafet berikutnya
$headers = @{ Authorization = "Bearer $($env:GH_PAT)"; Accept = "application/vnd.github.v3+json" }
$ghUri = "https://api.github.com/repos/$($env:GITHUB_REPO)/actions/workflows/estafet.yml/dispatches"
$payload = @{ ref = "main"; inputs = @{ backup_url = $backupHost } } | ConvertTo-Json
Invoke-RestMethod -Uri $ghUri -Method Post -Headers $headers -Body $payload

Write-Host "Estafet sesi berikutnya telah di-trigger! Backup P2P: $backupHost"

if (-not [string]::IsNullOrWhiteSpace($env:TG_BOT_TOKEN) -and -not [string]::IsNullOrWhiteSpace($env:TG_CHAT_ID)) {
    $tgUri = "https://api.telegram.org/bot$($env:TG_BOT_TOKEN)/sendMessage"
    $notifText = if ($backupHost -ne "") {
        "Estafet Sesi Dimulai!`nTransfer P2P: $backupHost`nMenunggu 9 menit untuk sedot backup.tar."
    } else {
        "Estafet Sesi Dimulai!`nDesktop kosong, langsung lanjut sesi baru."
    }
    Invoke-RestMethod -Uri $tgUri -Method Post -Body @{ chat_id = $env:TG_CHAT_ID; text = $notifText }
}

if ($backupHost -ne "") {
    Start-Sleep -Seconds (9 * 60)
}

& $tsExe logout
