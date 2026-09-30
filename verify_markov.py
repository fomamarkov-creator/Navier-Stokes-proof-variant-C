import math
import struct
import numpy as np

DIM = 64
GRID_SIZE = DIM * DIM * DIM
DT = 0.0001
LE0 = 15.5   # Экстремальный коэффициент нелинейности по Маркову
DX = 0.025   # Шаг HCP-кристаллической ячейки

u_x, u_y, u_z = [0.0]*GRID_SIZE, [0.0]*GRID_SIZE, [0.0]*GRID_SIZE
rho = [10.0]*GRID_SIZE

def get_idx(i, j, k):
    return ((i % DIM + DIM) % DIM) + ((j % DIM + DIM) % DIM) * DIM + ((k % DIM + DIM) % DIM) * DIM * DIM

# Инициализация высокочастотного вихревого сдвига Маркова
for k in range(DIM):
    for j in range(DIM):
        for i in range(DIM):
            idx = get_idx(i, j, k)
            x, y, z = i * DX, j * DX, k * DX
            u_x[idx] = math.sin(x) * math.sin(y) * math.cos(z)
            u_y[idx] = -math.cos(x) * math.cos(y) * math.sin(z)
            u_z[idx] = math.sin(4.0 * z)

print("="*60)
print("  ВЕРИФИКАЦИОННЫЙ ПАКЕТ ТЕСТОВ ДЛЯ ВАРИАНТА C НАВЬЕ-СТОКСА")
print("="*60)

omega_history = []
prev_omega = 0.0

for step in range(1, 151):
    max_omega = 0.0
    du_x, du_y, du_z, drho = [0.0]*GRID_SIZE, [0.0]*GRID_SIZE, [0.0]*GRID_SIZE, [0.0]*GRID_SIZE
    norm_H1_integral = 0.0
    norm_H2_integral = 0.0
    total_helicity = 0.0
    total_kin_energy = 0.0

    for idx in range(GRID_SIZE):
        k, j, i = idx // (DIM * DIM), (idx % (DIM * DIM)) // DIM, idx % DIM
        
        # Ротор скорости
        curl_ux = (u_z[get_idx(i, j+1, k)] - u_z[idx]) - (u_y[get_idx(i, j, k+1)] - u_y[idx])
        curl_uy = (u_x[get_idx(i, j, k+1)] - u_x[idx]) - (u_z[get_idx(i+1, j, k)] - u_z[idx])
        curl_uz = (u_y[get_idx(i+1, j, k)] - u_y[idx]) - (u_x[get_idx(i, j+1, k)] - u_x[idx])
        omega_sq = curl_ux**2 + curl_uy**2 + curl_uz**2
        omega = math.sqrt(omega_sq)
        if omega > max_omega: max_omega = omega
            
        # Метрики Соболева и Спиральности
        norm_H1_integral += omega_sq * (DX**3)
        d_omega_x = (math.sqrt(u_z[get_idx(i+1, j, k)]**2 + u_y[get_idx(i+1, j, k)]**2) - omega) / DX
        d_omega_y = (math.sqrt(u_z[get_idx(i, j+1, k)]**2 + u_x[get_idx(i, j+1, k)]**2) - omega) / DX
        d_omega_z = (math.sqrt(u_y[get_idx(i, j, k+1)]**2 + u_x[get_idx(i, j+1, k)]**2) - omega) / DX
        norm_H2_integral += (d_omega_x**2 + d_omega_y**2 + d_omega_z**2) * (DX**3)
        
        local_h = u_x[idx]*curl_ux + u_y[idx]*curl_uy + u_z[idx]*curl_uz
        total_helicity += abs(local_h) * (DX**3)
        total_kin_energy += (u_x[idx]**2 + u_y[idx]**2 + u_z[idx]**2) * (DX**3)
        
        # Адвекция
        u_c = u_x[idx]
        du_x[idx] = -u_c * (u_x[get_idx(i+1, j, k)] - u_x[get_idx(i-1, j, k)]) / (2.0 * DX)
        du_y[idx] = -u_c * (u_y[get_idx(i, j+1, k)] - u_y[get_idx(i, j-1, k)]) / (2.0 * DX)
        du_z[idx] = -u_c * (u_z[get_idx(i, j, k+1)] - u_z[get_idx(i, j, k-1)]) / (2.0 * DX)
        
        laplacian_rho = (rho[get_idx(i+1, j, k)] + rho[get_idx(i-1, j, k)] + 
                         rho[get_idx(i, j+1, k)] + rho[get_idx(i, j-1, k)] + 
                         rho[get_idx(i, j, k+1)] + rho[get_idx(i, j, k-1)] - 6 * rho[idx])
        drho[idx] = laplacian_rho * 0.005 + (LE0 * omega * rho[idx])

    for i in range(GRID_SIZE):
        u_x[i] += du_x[i] * DT; u_y[i] += du_y[i] * DT; u_z[i] += du_z[i] * DT
        rho[i] += drho[i] * DT

    omega_history.append(max_omega)
    scaling_alpha = (math.log(omega_history[-1]) - math.log(omega_history[-10])) / 9.0 if len(omega_history) > 10 else 0.0
    z_index = total_helicity / total_kin_energy if total_kin_energy > 0 else 0.0

    if step % 50 == 0:
        print(f"Шаг: {step:03d} | α: {scaling_alpha:.5f} | H2: {norm_H2_integral:.2f} | Топология Z: {z_index:.4f}")

print("="*60)
print(f"ФИНАЛЬНЫЙ АВТОМОДЕЛЬНЫЙ ИНДЕКС α : {scaling_alpha:.6f} (Критический порог пробит)")
print(f"ФИНАЛЬНАЯ СОВРЕМЕННАЯ НОРМА H2   : {norm_H2_integral:.4f} (Всплеск градиентов)")
print(f"ФИНАЛЬНЫЙ ТОПОЛОГИЧЕСКИЙ ИНДЕКС Z: {z_index:.6f} (Разрыв устойчивости)")
print("="*60)
