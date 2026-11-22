$ErrorActionPreference = "Continue"

# 1. Setup RDP & User administrator1
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
net user administrator1 "$env:RDP_PASSWORD" /add /Y
net localgroup Administrators administrator1 /add
net localgroup "Remote Desktop Users" administrator1 /add

$desktopPath = "C:\Users\administrator1\Desktop"
New-Item -ItemType Directory -Force -Path $desktopPath | Out-Null
icacls "C:\Users\administrator1" /grant "administrator1:(OI)(CI)F" /T /Q | Out-Null

# 2. Sedot & Restore Backup TAR jika ada
$backupUrl = $env:BACKUP_URL
if (-not [string]::IsNullOrWhiteSpace($backupUrl)) {
    try {
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
        Write-Host "✅ Backup TAR berhasil di-restore!"
    } catch {
        Write-Host "⚠️ Gagal restore backup: $($_.Exception.Message)"
    }
}

# 3. Auto-Start start.bat di Desktop sebagai administrator1
$startScript = "C:\Users\administrator1\Desktop\start.bat"
if (Test-Path $startScript) {
    $pass = ConvertTo-SecureString "$env:RDP_PASSWORD" -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ("administrator1", $pass)
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$startScript`"" -WorkingDirectory $desktopPath -Credential $cred -WindowStyle Hidden Write-Host "start.bat berhasil dijalankan." } else { Write-Host "File start.bat tidak ditemukan, melewati auto-start." }  # 4. Jalankan Bore untuk RDP & Tampilkan di Log (+ Telegram jika token diisi) Invoke-WebRequest -Uri "https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-pc-windows-msvc.zip" -OutFile "bore.zip" Expand-Archive -Path "bore.zip" -DestinationPath "." -Force  Start-Process -FilePath ".\bore.exe" -ArgumentList "local 3389 --to bore.pub" -RedirectStandardOutput "bore_rdp.log" -RedirectStandardError "bore_rdp_err.log" -NoNewWindow Start-Sleep -Seconds 6  $logContent = (Get-Content "bore_rdp.log" -ErrorAction SilentlyContinue) + (Get-Content "bore_rdp_err.log" -ErrorAction SilentlyContinue) $match = $logContent \vert{} Select-String -Pattern "bore\.pub:\d+" $rdpAddress = if ($match) { $match.Matches[0].Value } else { "Gagal mendapatkan port" }  Write-Host "========================================" Write-Host "🚀 RDP AKTIF!" Write-Host "Host : $rdpAddress" Write-Host "User : administrator1" Write-Host "========================================"  if (-not [string]::IsNullOrWhiteSpace($env:TG_BOT_TOKEN) -and -not [string]::IsNullOrWhiteSpace($env:TG_CHAT_ID)) { $msg = "🚀 *RDP Estafet Aktif!*`nHost: ``$rdpAddress```nUser: ``administrator1```nPass: ``$($env:RDP_PASSWORD)```n📦 Mode: TAR"
    $tgUri = "[https://api.telegram.org/bot$($env:TG_BOT_TOKEN)/sendMessage](https://api.telegram.org/bot$($env:TG_BOT_TOKEN)/sendMessage)"
    Invoke-RestMethod -Uri $tgUri -Method Post -Body @{ chat_id = $env:TG_CHAT_ID; text = $msg; parse_mode = "Markdown" }
}

# 5. Tunggu 348 menit (5 jam 48 menit)
Start-Sleep -Seconds (348 * 60)

# 6. Packing Desktop & Path Tambahan ke backup.tar
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
    Start-Process -FilePath "python" -ArgumentList "-m http.server 8888 --directory C:\transfer_out" -NoNewWindow
    Start-Sleep -Seconds 2
    Start-Process -FilePath ".\bore.exe" -ArgumentList "local 8888 --to bore.pub" -RedirectStandardOutput "bore_http.log" -RedirectStandardError "bore_http_err.log" -NoNewWindow
    Start-Sleep -Seconds 6

    $httpLog = (Get-Content "bore_http.log" -ErrorAction SilentlyContinue) + (Get-Content "bore_http_err.log" -ErrorAction SilentlyContinue)
    $httpMatch = $httpLog | Select-String -Pattern "bore\.pub:\d+"
    if ($httpMatch) { $backupHost = $httpMatch.Matches[0].Value }
}

# 7. Trigger sesi estafet berikutnya
$headers = @{ Authorization = "Bearer $($env:GH_PAT)"; Accept = "application/vnd.github.v3+json" }
$ghUri = "[https://api.github.com/repos/$($env:GITHUB_REPO)/actions/workflows/estafet.yml/dispatches](https://api.github.com/repos/$($env:GITHUB_REPO)/actions/workflows/estafet.yml/dispatches)"
$payload = @{ ref = "main"; inputs = @{ backup_url = $backupHost } } | ConvertTo-Json
Invoke-RestMethod -Uri $ghUri -Method Post -Headers $headers -Body $payload

Write-Host "🔄 Estafet sesi berikutnya telah di-trigger! Backup URL: $backupHost"

if (-not [string]::IsNullOrWhiteSpace($env:TG_BOT_TOKEN) -and -not [string]::IsNullOrWhiteSpace($env:TG_CHAT_ID)) {
    $notifText = if ($backupHost -ne "") {
        "🔄 *Estafet Sesi Dimulai!*`nServer TAR: ``$backupHost```nMenunggu 9 menit untuk sedot backup.tar."
    } else {
        "🔄 *Estafet Sesi Dimulai!*`nDesktop kosong, langsung lanjut sesi baru."
    }
    Invoke-RestMethod -Uri $tgUri -Method Post -Body @{ chat_id = $env:TG_CHAT_ID; text = $notifText; parse_mode = "Markdown" }
}

if ($backupHost -ne "") {
    Start-Sleep -Seconds (9 * 60)
}
