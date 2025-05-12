# config.ps1 - Güvenli yapılandırma dosyası
# Bu script, güvenli bir şekilde yapılandırma ayarlarını yönetir ve keys.txt dosyasından hassas bilgileri okur

# Keys.txt dosyasını okuma fonksiyonu
function Read-KeysFile {
    param (
        [string]$keysFilePath = "$PSScriptRoot\keys.txt"
    )
    
    if (!(Test-Path $keysFilePath)) {
        Write-Error "Keys dosyası bulunamadı: $keysFilePath"
        throw "Yapılandırma hatası: Keys dosyası bulunamadı."
    }
    
    $keysContent = Get-Content $keysFilePath
    $keysDict = @{}
    
    foreach ($line in $keysContent) {
        # Yorum satırlarını ve boş satırları atla
        if ($line.Trim() -eq "" -or $line.Trim().StartsWith("#")) {
            continue
        }
        
        $keyValuePair = $line.Split('=', 2)
        if ($keyValuePair.Length -eq 2) {
            $key = $keyValuePair[0].Trim()
            $value = $keyValuePair[1].Trim()
            $keysDict[$key] = $value
        }
    }
    
    return $keysDict
}

# Ortam değişkenlerini kontrol etme fonksiyonu
function Get-ConfigValue {
    param (
        [string]$keyName,
        [string]$defaultValue = "",
        [hashtable]$keysDict
    )
    
    # Önce ortam değişkenlerini kontrol et
    $envVarName = "WP_LOGO_CONNECTOR_$($keyName.ToUpper())"
    $envValue = [Environment]::GetEnvironmentVariable($envVarName)
    
    if ($envValue) {
        return $envValue
    }
    
    # Sonra keys.txt dosyasından kontrol et
    if ($keysDict.ContainsKey($keyName)) {
        return $keysDict[$keyName]
    }
    
    # Son olarak varsayılan değeri döndür
    return $defaultValue
}

try {
    # Keys dosyasını oku
    $keysDict = Read-KeysFile
    
    # Yapılandırma nesnesi oluştur
    $config = @{
        # WooCommerce API ayarları
        woocommerce = @{
            site_url = Get-ConfigValue -keyName "site_url" -defaultValue "https://sizin-site-adresiniz.com" -keysDict $keysDict
            consumer_key = Get-ConfigValue -keyName "consumer_key" -keysDict $keysDict
            consumer_secret = Get-ConfigValue -keyName "consumer_secret" -keysDict $keysDict
        }
        
        # SQL Server ayarları
        sql = @{
            server = Get-ConfigValue -keyName "sql_server" -defaultValue "localhost" -keysDict $keysDict
            database = Get-ConfigValue -keyName "sql_database" -keysDict $keysDict
            username = Get-ConfigValue -keyName "sql_username" -keysDict $keysDict
            password = Get-ConfigValue -keyName "sql_password" -keysDict $keysDict
            # Ana ürün tablosu
            product_table = Get-ConfigValue -keyName "product_table" -defaultValue "urunler_tablosu" -keysDict $keysDict
            product_id_field = Get-ConfigValue -keyName "product_id_field" -defaultValue "urun_id" -keysDict $keysDict
            price_field = Get-ConfigValue -keyName "price_field" -defaultValue "fiyat" -keysDict $keysDict
            # Eşleştirme tablosu
            sync_table = Get-ConfigValue -keyName "sync_table" -defaultValue "woocommerce_sync_products" -keysDict $keysDict
            sql_id_field = Get-ConfigValue -keyName "sql_id_field" -defaultValue "sql_product_id" -keysDict $keysDict
            woo_id_field = Get-ConfigValue -keyName "woo_id_field" -defaultValue "woocommerce_product_id" -keysDict $keysDict
            sync_enabled_field = Get-ConfigValue -keyName "sync_enabled_field" -defaultValue "sync_enabled" -keysDict $keysDict
            last_sync_field = Get-ConfigValue -keyName "last_sync_field" -defaultValue "last_sync_date" -keysDict $keysDict
        }
        
        # Genel ayarlar
        general = @{
            log_file = Get-ConfigValue -keyName "log_file" -defaultValue "C:\logs\price_sync.log" -keysDict $keysDict
            sync_interval = [int](Get-ConfigValue -keyName "sync_interval" -defaultValue "5" -keysDict $keysDict)
            retry_count = [int](Get-ConfigValue -keyName "retry_count" -defaultValue "3" -keysDict $keysDict)
            retry_delay = [int](Get-ConfigValue -keyName "retry_delay" -defaultValue "30" -keysDict $keysDict) # saniye
        }
    }
    
    # Gerekli değerlerin varlığını kontrol et
    $requiredFields = @(
        @{ Category = "woocommerce"; Field = "consumer_key"; FriendlyName = "WooCommerce Tüketici Anahtarı" },
        @{ Category = "woocommerce"; Field = "consumer_secret"; FriendlyName = "WooCommerce Tüketici Gizli Anahtarı" },
        @{ Category = "sql"; Field = "database"; FriendlyName = "SQL Veritabanı Adı" },
        @{ Category = "sql"; Field = "username"; FriendlyName = "SQL Kullanıcı Adı" },
        @{ Category = "sql"; Field = "password"; FriendlyName = "SQL Şifresi" }
    )
    
    foreach ($field in $requiredFields) {
        if ([string]::IsNullOrEmpty($config[$field.Category][$field.Field])) {
            throw "Yapılandırma hatası: $($field.FriendlyName) belirtilmemiş. Lütfen keys.txt dosyasını veya ortam değişkenlerini kontrol edin."
        }
    }
    
    # Yapılandırmayı dışa aktar
    Export-ModuleMember -Variable config
    
} catch {
    Write-Error "Yapılandırma yüklenirken hata oluştu: $_"
    throw $_
}