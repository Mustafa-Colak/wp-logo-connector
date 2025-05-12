# SQL Veritabanı - WooCommerce Fiyat Senkronizasyon Projesi

## Proje Özeti

Bu proje, Windows PC'de çalışan bir SQL veritabanındaki ürün fiyatlarını WordPress WooCommerce sitesine otomatik olarak aktarmak için tasarlanmıştır. Sadece belirli ürünlerin fiyatları güncellenecektir. Senkronizasyon işlemi dakika bazında ayarlanabilir ve Windows'tan tetiklenecektir.

## Özellikler

- SQL veritabanından seçili ürünlerin fiyatlarını WooCommerce'e aktarma
- Dakika bazında ayarlanabilir senkronizasyon sıklığı
- Hangi ürünlerin senkronize edileceğini kontrol etme imkanı
- Detaylı loglama sistemi
- Windows Görev Zamanlayıcısı ile otomatik çalıştırma

## Sistem Gereksinimleri

- Windows işletim sistemi
- SQL Server veritabanı
- WordPress ve WooCommerce kurulu bir web sitesi
- PowerShell 5.0 veya daha yeni sürümü (veya PHP 7.2+)
- WooCommerce REST API erişimi

## Kurulum

### 1. SQL Veritabanı Hazırlığı

SQL Server'da eşleştirme tablosu oluşturun:

```sql
-- Eşleştirme tablosu oluşturma
CREATE TABLE woocommerce_sync_products (
    id INT IDENTITY(1,1) PRIMARY KEY,
    sql_product_id INT NOT NULL,
    woocommerce_product_id INT NOT NULL,
    sync_enabled BIT DEFAULT 1,
    last_sync_date DATETIME NULL,
    created_date DATETIME DEFAULT GETDATE(),
    UNIQUE (sql_product_id, woocommerce_product_id)
);

-- Örnek veri ekleme
INSERT INTO woocommerce_sync_products (sql_product_id, woocommerce_product_id, sync_enabled)
VALUES 
(1001, 123, 1),
(1002, 124, 1),
(1003, 125, 0); -- Bu ürün senkronize edilmeyecek
```

### 2. WooCommerce API Anahtarları Oluşturma

1. WordPress yönetici paneline giriş yapın
2. "WooCommerce" → "Ayarlar" → "Gelişmiş" → "REST API" sekmesine gidin
3. "Anahtar ekle" butonuna tıklayın
4. Aşağıdaki bilgileri doldurun:
   - Açıklama: "Fiyat Senkronizasyon API"
   - İzinler: "Okuma/Yazma"
   - Kullanıcı: Admin kullanıcısını seçin
5. "API anahtarı oluştur" butonuna tıklayın
6. Oluşturulan "Tüketici Anahtarı" ve "Tüketici Gizli Anahtarı" kaydedin

### 3. Script Dosyalarını Oluşturma

#### PowerShell Yapılandırma Dosyası (config.ps1)

```powershell
# config.ps1 - Yapılandırma dosyası
$config = @{
    # WooCommerce API ayarları
    woocommerce = @{
        site_url = "https://sizin-site-adresiniz.com"
        consumer_key = "ck_xxxxxxxxxxxxxxxxxxxx"
        consumer_secret = "cs_xxxxxxxxxxxxxxxxxxxx"
    }
    
    # SQL Server ayarları
    sql = @{
        server = "localhost"
        database = "veritabani_adi"
        username = "kullanici_adi"
        password = "sifre"
        # Ana ürün tablosu
        product_table = "urunler_tablosu"
        product_id_field = "urun_id"
        price_field = "fiyat"
        # Eşleştirme tablosu
        sync_table = "woocommerce_sync_products"
        sql_id_field = "sql_product_id"
        woo_id_field = "woocommerce_product_id"
        sync_enabled_field = "sync_enabled"
        last_sync_field = "last_sync_date"
    }
    
    # Genel ayarlar
    general = @{
        log_file = "C:\logs\price_sync.log"
        sync_interval = 5  # dakika
    }
}

# Yapılandırmayı dışa aktar
Export-ModuleMember -Variable config
```

#### PowerShell Senkronizasyon Script'i (sync_prices.ps1)

```powershell
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
```

### 4. Windows Görev Zamanlayıcısı Ayarları

1. Windows Görev Zamanlayıcısı'nı açın (taskschd.msc)
2. "Eylem" menüsünden "Basit Görev Oluştur" seçeneğini tıklayın
3. Görev için bir isim girin: "WooCommerce Fiyat Senkronizasyonu"
4. Tetikleyici olarak "Günlük" seçin
5. Başlangıç saati belirleyin
6. Eylem olarak "Program başlat" seçin
7. Program/script alanına: `powershell.exe`
8. Argümanlar alanına: `-ExecutionPolicy Bypass -File "C:\path\to\sync_prices.ps1"`
9. "Son" butonuna tıklayın
10. Oluşturulan göreve sağ tıklayın ve "Özellikler"i seçin
11. "Tetikleyiciler" sekmesine gidin ve mevcut tetikleyiciyi düzenleyin
12. "Gelişmiş ayarlar" bölümünde "Tekrarla" seçeneğini işaretleyin
13. "Her" alanına istediğiniz dakika değerini girin (örn. 5 dakika)
14. "Süre" alanını "Süresiz" olarak ayarlayın
15. "Tamam" butonuna tıklayın

## Eşleştirme Tablosunu Yönetme

Eşleştirme tablosunu yönetmek için SQL Server Management Studio kullanabilir veya basit bir Windows Forms uygulaması geliştirebilirsiniz.

### SQL Sorguları ile Yönetim

#### Yeni Eşleştirme Ekleme

```sql
INSERT INTO woocommerce_sync_products (sql_product_id, woocommerce_product_id, sync_enabled)
VALUES (SQL_URUN_ID, WOOCOMMERCE_URUN_ID, 1);
```

#### Eşleştirmeyi Etkinleştirme/Devre Dışı Bırakma

```sql
-- Etkinleştirme
UPDATE woocommerce_sync_products 
SET sync_enabled = 1 
WHERE sql_product_id = SQL_URUN_ID AND woocommerce_product_id = WOOCOMMERCE_URUN_ID;

-- Devre dışı bırakma
UPDATE woocommerce_sync_products 
SET sync_enabled = 0 
WHERE sql_product_id = SQL_URUN_ID AND woocommerce_product_id = WOOCOMMERCE_URUN_ID;
```

#### Eşleştirmeleri Listeleme

```sql
SELECT 
    s.id,
    s.sql_product_id,
    p.urun_adi, -- Ürün tablosundaki ad alanı
    s.woocommerce_product_id,
    p.fiyat,
    s.sync_enabled,
    s.last_sync_date
FROM 
    woocommerce_sync_products s
INNER JOIN 
    urunler_tablosu p ON s.sql_product_id = p.urun_id
ORDER BY 
    s.sql_product_id;
```

## Sorun Giderme

### Genel Sorunlar ve Çözümleri

1. **Bağlantı Hataları**
   - SQL Server bağlantı bilgilerini kontrol edin
   - Firewall ayarlarını kontrol edin
   - SQL Server'ın çalıştığından emin olun

2. **API Hataları**
   - WooCommerce API anahtarlarının doğru olduğundan emin olun
   - WordPress sitenizin erişilebilir olduğundan emin olun
   - API izinlerinin doğru ayarlandığından emin olun

3. **Zamanlama Sorunları**
   - Windows Görev Zamanlayıcısı'nın düzgün çalıştığından emin olun
   - Script'in manuel olarak çalışıp çalışmadığını kontrol edin

4. **Fiyat Güncelleme Sorunları**
   - Eşleştirme tablosundaki ürün ID'lerinin doğru olduğundan emin olun
   - WooCommerce ürünlerinin var olduğundan emin olun

### Log Dosyasını Kontrol Etme

Sorunları tespit etmek için log dosyasını kontrol edin:

C:\logs\price_sync.log

## Güvenlik Önlemleri

1. **API Anahtarları**: WooCommerce API anahtarlarını güvenli bir şekilde saklayın
2. **Şifreleme**: Yapılandırma dosyalarında şifreleri şifrelenmiş formatta saklayın
3. **IP Kısıtlaması**: WooCommerce API'sine sadece belirli IP adreslerinden erişim izni verin
4. **HTTPS**: API isteklerini her zaman HTTPS üzerinden yapın
5. **Loglama**: Tüm işlemleri loglayın ve düzenli olarak kontrol edin

## Lisans

Bu proje [MIT Lisansı](LICENSE) altında lisanslanmıştır.

## İletişim

Sorularınız veya önerileriniz için: [reboteknoloji@gmail.com]