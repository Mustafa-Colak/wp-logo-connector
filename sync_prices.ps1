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
    Write-Host $logMessage
}

# WooCommerce ürün fiyatını güncelleme fonksiyonu
function Update-WooCommerceProductPrice {
    param (
        [int]$productId,
        [decimal]$price
    )
    
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
        
        Write-Log "Ürün #$productId fiyatı güncellendi: $price"
        return $true
    } catch {
        Write-Log "Ürün #$productId fiyat güncellemesi başarısız: $($_.Exception.Message)" -level "ERROR"
        return $false
    }
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
    Write-Log "Seçili ürünlerin fiyat senkronizasyonu başlatılıyor..."
    
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
        
        # Sonuçları işle
        while ($reader.Read()) {
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
        
        Write-Log "Fiyat senkronizasyonu tamamlandı. Güncellenen: $updatedCount, Hata: $errorCount"
    } catch {
        Write-Log "Senkronizasyon hatası: $($_.Exception.Message)" -level "ERROR"
    }
}

# Script'i çalıştır
Sync-Prices