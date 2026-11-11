# PREDICTIVE MAINTENANCE PROOF OF CONCEPT (PoC)
# Algoritma: Wild Binary Segmentation (WBS) & Tail-Greedy Unbalanced Haar (TGUH)
# Studi Kasus: Sensor Pompa Industri (Deteksi Dini Kegagalan Sistem)

# Memuat pustaka
library(readr)
library(dplyr)
library(ggplot2)
library(imputeTS)
library(changepoint) 
library(wbs)         
library(breakfast)   

# Memuat dataset historis sensor pabrik dari mesin pompa
df_sensor <- read_csv("sensor.csv", col_names = TRUE)

# Status BROKEN pertama diketahui ada pada baris 17.156
# Ekstraksi sampel data subset (Indeks 10.000 s/d 18.000) 
# Sampel ini merepresentasikan fase degradasi mesin hingga mati total
df_subset <- df_sensor[10000:18000, ]

# Fokus pada sensor utama dengan anomali magnitudo tinggi berdasarkan Exploratory Data Analysis (EDA)
# Notebook Kaggle oleh shawky El-gendy
y_raw <- df_subset$sensor_04 

# Penanganan Missing Values
# Fungsi imputasi stokastik lokal untuk memelihara struktur varians asli dari deret waktu sensor
impute_stochastic_local <- function(y, radius = 50) {
  idx_na <- which(is.na(y))
  if(length(idx_na) == 0) return(y)
  
  interp_base <- na_interpolation(y, option = "linear")
  n_data <- length(y)
  local_sd <- numeric(length(idx_na))
  
  # Kalkulasi standar deviasi lokal untuk mencegah distorsi sinyal
  for (i in seq_along(idx_na)) {
    start_idx <- max(1, idx_na[i] - radius)
    end_idx <- min(n_data, idx_na[i] + radius)
    sd_val <- sd(y[start_idx:end_idx], na.rm = TRUE)
    if (is.na(sd_val)) sd_val <- sd(y, na.rm = TRUE) * 0.5
    local_sd[i] <- sd_val
  }
  
  set.seed(10122054) 
  y_stochastic <- interp_base
  y_stochastic[idx_na] <- interp_base[idx_na] + rnorm(length(idx_na), 0, local_sd)
  
  # Memastikan batas bawah (lower bound) menyesuaikan dengan nilai empiris mesin
  min_val <- min(y, na.rm = TRUE)
  y_stochastic[y_stochastic < min_val] <- min_val 
  
  return(y_stochastic)
}

# Terapkan fungsi imputasi ke data mentah
y_clean <- impute_stochastic_local(y_raw, radius = 50)

# Menyiapkan dataframe)= terstandarisasi untuk visualisasi Dasbor
df_clean <- data.frame(
  waktu = 1:length(y_clean),
  sensor_val = y_clean
)

# Memulai change point detection
# Menghitung posisi garis mesin mati absolut pada subset data (Ground Truth)
titik_mati <- 17156 - 10000 + 1 

# Eksekusi algoritma WBS dan TGUH
cp_wbs <- changepoints(wbs(y_clean), penalty = "ssic.penalty")$cpt.ic$ssic.penalty
cp_tguh <- model.ic(sol.tguh(y_clean))$cpts 

# Visualisasi
level_urutan <- c("Data Asli", "WBS", "TGUH")

# Memetakan letak garis vertikal anomali yang ditemukan oleh mesin
df_cp <- data.frame(
  Metode = factor(c(rep("WBS", length(cp_wbs)), rep("TGUH", length(cp_tguh))), levels = level_urutan),
  Titik_CP = c(cp_wbs, cp_tguh)
)

df_plot <- bind_rows(
  df_clean %>% mutate(Metode = "Data Asli"),
  df_clean %>% mutate(Metode = "WBS"),
  df_clean %>% mutate(Metode = "TGUH")
) %>% mutate(Metode = factor(Metode, levels = level_urutan))

# Menampilkan grafik komparatif
ggplot(df_plot, aes(x = waktu, y = sensor_val)) +
  geom_line(color = "gray30", linewidth = 0.3) +
  # Garis anomali
  geom_vline(data = subset(df_cp, !is.na(Titik_CP)), 
             aes(xintercept = Titik_CP, color = Metode), linewidth = 0.6, alpha = 0.8) +
  # Garis mesin mati
  geom_vline(xintercept = titik_mati, color = "black", linetype = "dashed", linewidth = 1) +
  scale_color_manual(values = c("WBS" = "#E41A1C", "TGUH" = "#FF7F00")) +
  facet_grid(Metode ~ .) +
  labs(title = "Deteksi Dini Anomali Sensor_04 Menjelang System Failure",
       subtitle = "Garis Putus-Putus Hitam = Momen Kegagalan Sistem (BROKEN)",
       x = "Indeks Waktu (Menit)", y = "Nilai Sensor (PSI)") +
  theme_minimal() +
  theme(legend.position = "none", strip.text = element_text(face = "bold", size = 10))

# Menyimpan grafik
ggsave("plot_deteksi_anomali.jpg", width = 10, height = 7, dpi = 150)

# Menyusun file .log untuk memuat anomali yang terdeteksi

# Memuat file (semua output 'cat' setelah ini akan masuk ke file)
sink("EWS_Pompa_Industri.log")

cat("LOG SISTEM PERINGATAN DINI SENSOR POMPA INDUSTRI \n")

daftar_cp <- list(WBS = cp_wbs, TGUH = cp_tguh)

for (metode in names(daftar_cp)) {
  cat(sprintf("\n======================= METODE: %s =======================\n", metode))
  for (cp in sort(daftar_cp[[metode]])) {
    if (cp > 60 && cp < (length(y_clean) - 60) && cp < titik_mati) {
      mean_sebelum <- mean(y_clean[(cp-60):cp])
      mean_sesudah <- mean(y_clean[(cp+1):(cp+60)])
      delta_persen <- abs(mean_sesudah - mean_sebelum) / mean_sebelum * 100
      
      if (mean_sesudah > mean_sebelum) {
        arah <- "LONJAKAN (Spike)"
      } else {
        arah <- "PENURUNAN (Drop)"
      }
      
      status <- ifelse(delta_persen > 20, "KRITIS", "PERINGATAN")
      
      sisa_menit <- titik_mati - cp
      sisa_hari <- sisa_menit %/% (24 * 60)
      sisa_jam <- (sisa_menit %% (24 * 60)) %/% 60
      
      cat(sprintf("[%s] Terdeteksi di Menit ke-%d\n", status, cp))
      cat(sprintf("   >> Jenis     : %s\n", arah))
      cat(sprintf("   >> Perubahan : %.2f PSI menjadi %.2f PSI (Shift: %.1f%%)\n", mean_sebelum, mean_sesudah, delta_persen))
      cat(sprintf("   >> LEAD TIME : %d Hari, %d Jam sebelum estimasi mati total.\n", sisa_hari, sisa_jam))
      cat("------------------------------------------------------\n")
    }
  }
}

sink()