# config.ps1 - Yapılandırma dosyası
$config = @{
    # WooCommerce API ayarları
    woocommerce = @{
        site_url = "https://afay.com.tr"
        consumer_key = "ck_b77343b6fec2eabfbf0b15dfd94ed5e05cad120c"
        consumer_secret = "cs_34664e02f20ef732f930fc6f6b2f4f032ff6697e"
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