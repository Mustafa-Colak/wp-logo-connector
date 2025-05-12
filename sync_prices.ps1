# sync_prices.ps1 - Ana senkronizasyon script'i
# Yapılandırma dosyasını içe aktar
Import-Module "$PSScriptRoot\config.ps1" -Force

# Log fonksiyonu
function Write-Log {
    param (
        [string]$message,
        [string]$level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$level] $timestamp - $message"
    
    # Log klasörünü oluştur
    $logDir = [System.IO.Path]::GetDirectoryName($config.general.log_file)
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    # Log dosyasına yaz
    $logMessage | Out-File -FilePath $config.general.log_file -Append
    
    # Konsola yazdır
    if ($level -eq "ERROR") {
        Write-Host $logMessage -ForegroundColor Red
    } elseif ($level -eq "WARNING") {
        Write-Host $logMessage -ForegroundColor Yellow
    } elseif ($level -eq "SUCCESS") {
        Write-Host $logMessage -ForegroundColor Green
    } else {
        Write-Host $logMessage
    }
}

# Bağlantı test fonksiyonu
function Test-Connections {
    # SQL Server bağlantısını test et
    try {
        Write-Log "SQL Server bağlantısı test ediliyor: $($config.sql.server)..."
        $connectionString = "Server=$($config.sql.server);Database=$($config.sql.database);User Id=$($config.sql.username);Password=$($config.sql.password);Connection Timeout=5;"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        $connection.Close()
        Write-Log "SQL Server bağlantısı başarılı." -level "SUCCESS"
        $sqlOk = $true
    } catch {
        Write-Log "SQL Server bağlantı hatası: $($_.Exception.Message)" -level "ERROR"
        $sqlOk = $false
    }
    
    # WooCommerce API bağlantısını test et
    try {
        Write-Log "WooCommerce API bağlantısı test ediliyor: $($config.woocommerce.site_url)..."
        $endpoint = "$($config.woocommerce.site_url)/wp-json/wc/v3/products?per_page=1"
        $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($config.woocommerce.consumer_key):$($config.woocommerce.consumer_secret)"))
        
        $headers = @{
            Authorization = "Basic $auth"
        }
        
        $response = Invoke-RestMethod -Uri $endpoint -Method GET -Headers $headers -TimeoutSec 10
        Write-Log "WooCommerce API bağlantısı başarılı." -level "SUCCESS"
        $wooOk = $true
    } catch {
        Write-Log "WooCommerce API bağlantı hatası: $($_.Exception.Message)" -level "ERROR"
        $wooOk = $false
    }
    
    return ($sqlOk -and $wooOk)
}

# WooCommerce ürün fiyatını güncelleme fonksiyonu (yeniden deneme mekanizması ile)
function Update-WooCommerceProductPrice {
    param (
        [int]$productId,
        [decimal]$price,
        [int]$retryCount = $config.general.retry_count,
        [int]$retryDelay = $config.general.retry_delay
    )
    
    $attempt = 0
    $success = $false
    
    while (-not $success -and $attempt -lt $retryCount) {
        $attempt++
        try {
            $endpoint = "$($config.woocommerce.site_url)/wp-json/wc/v3/products/$productId"
            $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($config.woocommerce.consumer_key):$($config.woocommerce.consumer_secret)"))
            
            $headers = @{
                Authorization = "Basic $auth"
            }
            
            $body = @{
                regular_price = "$price"
            } | ConvertTo-Json
            
            $response = Invoke-RestMethod -Uri $endpoint -Method PUT -Headers $headers -Body $body -ContentType "application/json"
            
            Write-Log "Ürün #$productId fiyatı güncellendi: $price" -level "SUCCESS"
            $success = $true
        } catch {
            if ($attempt -lt $retryCount) {
                Write-Log "Ürün #$productId fiyat güncellemesi başarısız (Deneme $attempt/$retryCount): $($_.Exception.Message). $retryDelay saniye sonra tekrar denenecek..." -level "WARNING"
                Start-Sleep -Seconds $retryDelay
            } else {
                Write-Log "Ürün #$productId fiyat güncellemesi başarısız (Son deneme $attempt/$retryCount): $($_.Exception.Message)" -level "ERROR"
            }
        }
    }
    
    return $success
}

# Son senkronizasyon tarihini güncelleme fonksiyonu
function Update-SyncDate {
    param (
        [int]$sqlProductId,
        [int]$wooProductId
    )
    
    try {
        $connectionString = "Server=$($config.sql.server);Database=$($config.sql.database);User Id=$($config.sql.username);Password=$($config.sql.password);"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        
        $query = "UPDATE $($config.sql.sync_table) SET $($config.sql.last_sync_field) = GETDATE() WHERE $($config.sql.sql_id_field) = @sqlId AND $($config.sql.woo_id_field) = @wooId"
        $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
        $command.Parameters.AddWithValue("@sqlId", $sqlProductId)
        $command.Parameters.AddWithValue("@wooId", $wooProductId)
        $command.ExecuteNonQuery()
        
        $connection.Close()
        return $true
    } catch {
        Write-Log "Senkronizasyon tarihi güncellemesi başarısız: $($_.Exception.Message)" -level "ERROR"
        return $false
    }
}

# Ana senkronizasyon fonksiyonu
function Sync-Prices {
    $startTime = Get-Date
    Write-Log "Fiyat senkronizasyonu başlatılıyor... (Sürüm 1.0.1)"
    
    # Bağlantıları test et
    if (-not (Test-Connections)) {
        Write-Log "Bağlantı testleri başarısız. Senkronizasyon iptal ediliyor." -level "ERROR"
        return
    }
    
    try {
        # SQL Server'a bağlan
        Write-Log "SQL Server'a bağlanılıyor: $($config.sql.server)..."
        $connectionString = "Server=$($config.sql.server);Database=$($config.sql.database);User Id=$($config.sql.username);Password=$($config.sql.password);"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        
        # SQL sorgusu - Sadece senkronizasyon için işaretlenmiş ürünleri seç
        $query = @"
        SELECT 
            p.$($config.sql.product_id_field) AS sql_product_id,
            p.$($config.sql.price_field) AS price,
            s.$($config.sql.woo_id_field) AS woo_product_id
        FROM 
            $($config.sql.product_table) p
        INNER JOIN 
            $($config.sql.sync_table) s ON p.$($config.sql.product_id_field) = s.$($config.sql.sql_id_field)
        WHERE 
            s.$($config.sql.sync_enabled_field) = 1
"@
        $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
        $reader = $command.ExecuteReader()
        
        $updatedCount = 0
        $errorCount = 0
        $totalCount = 0
        
        # Sonuçları işle
        while ($reader.Read()) {
            $totalCount++
            $sqlProductId = $reader["sql_product_id"]
            $wooProductId = $reader["woo_product_id"]
            $price = $reader["price"]
            
            Write-Log "İşleniyor: SQL Ürün #$sqlProductId -> WooCommerce Ürün #$wooProductId (Fiyat: $price)"
            
            # Fiyatı güncelle
            $result = Update-WooCommerceProductPrice -productId $wooProductId -price $price
            
            if ($result) {
                # Son senkronizasyon tarihini güncelle
                Update-SyncDate -sqlProductId $sqlProductId -wooProductId $wooProductId
                $updatedCount++
            } else {
                $errorCount++
            }
        }
        
        $reader.Close()
        $connection.Close()
        
        $endTime = Get-Date
        $duration = ($endTime - $startTime).TotalSeconds
        
        Write-Log "Fiyat senkronizasyonu tamamlandı. Toplam: $totalCount, Güncellenen: $updatedCount, Hata: $errorCount (Süre: $duration saniye)" -level "SUCCESS"
    } catch {
        Write-Log "Senkronizasyon hatası: $($_.Exception.Message)" -level "ERROR"
        Write-Log "Hata detayları: $($_.Exception.StackTrace)" -level "ERROR"
    }
}

# Test fonksiyonu - Bağlantıları test etmek için
function Test-Configuration {
    Write-Log "Yapılandırma testi başlatılıyor..."
    
    # Yapılandırma değerlerini kontrol et
    Write-Log "WooCommerce Site URL: $($config.woocommerce.site_url)"
    Write-Log "SQL Server: $($config.sql.server)"
    Write-Log "SQL Database: $($config.sql.database)"
    Write-Log "Ürün Tablosu: $($config.sql.product_table)"
    Write-Log "Eşleştirme Tablosu: $($config.sql.sync_table)"
    Write-Log "Log Dosyası: $($config.general.log_file)"
    Write-Log "Senkronizasyon Aralığı: $($config.general.sync_interval) dakika"
    
    # Bağlantıları test et
    Test-Connections
}

# Parametreleri işle
param (
    [switch]$Test,
    [switch]$Verbose
)

# Verbose modunu ayarla
if ($Verbose) {
    $VerbosePreference = "Continue"
}

# Test veya senkronizasyon işlemini çalıştır
if ($Test) {
    Test-Configuration
} else {
    Sync-Prices
}