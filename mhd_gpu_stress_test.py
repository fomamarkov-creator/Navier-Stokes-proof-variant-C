"""
MHD Code Complex Verification & Stress Test (GPU / CuPy Edition)
Author: E. C. Markov
Date: September 2026
License: AGPLv3
"""

import datetime
import cupy as cp
from google.colab import files

def run_gpu_stress_test():
    # 1. Основные физические и сеточные параметры
    DIM = 256
    DT = 0.0005
    DX_BASE = 0.0125
    LE0 = 15.5
    TOTAL_STEPS = 1000

    print(f"[GPU-START] Инициализация сетки {DIM}^3 на CuPy (CUDA)...")

    # 2. Построение пространственной решетки в памяти GPU
    coord = cp.linspace(0, DIM * DX_BASE, DIM, dtype=cp.float32)
    X, Y, Z = cp.meshgrid(coord, coord, coord, indexing="ij")

    # 3. Инициализация гладких начальных полей (Случай C)
    Vx = cp.sin(X) * cp.sin(Y) * cp.cos(Z)
    Vy = -cp.cos(X) * cp.cos(Y) * cp.sin(Z)
    Vz = np_sin_4z = cp.sin(4.0 * Z)

    Mx = cp.sin(Z)
    My = cp.cos(Z)
    Mz = cp.ones_like(Z)
    rho = cp.ones_like(X) * 10.0

    # Потенциал Деднера для консервативного подавления дивергенции
    psi = cp.zeros_like(X)
    
    # Буфер для записи истории пошагового скейлинга
    log_lines = []

    print("[GPU-RUN] Запуск симуляции на 1000 тактов...")

    # 4. Основной итерационный цикл симуляции
    for step in range(1, TOTAL_STEPS + 1):
        
        # Вычисление ротора поля скорости (Завихренность)
        curl_vx = (cp.roll(Vz, -1, axis=2) - Vz) - (cp.roll(Vy, -1, axis=1) - Vy)
        curl_vy = (cp.roll(Vx, -1, axis=2) - Vx) - (cp.roll(Vz, -1, axis=0) - Vz)
        curl_vz = (cp.roll(Vy, -1, axis=0) - Vy) - (cp.roll(Vx, -1, axis=1) - Vx)
        w = cp.sqrt(curl_vx**2 + curl_vy**2 + curl_vz**2)
        max_w = float(cp.max(w))

        # Вычисление плотности токов Лоренца (Ротор магнитного поля)
        Jx = (cp.roll(Mz, -1, axis=2) - Mz) - (cp.roll(My, -1, axis=1) - My)
        Jy = (cp.roll(Mx, -1, axis=2) - Mx) - (cp.roll(Mz, -1, axis=0) - Mz)
        Jz = (cp.roll(My, -1, axis=0) - My) - (cp.roll(Mx, -1, axis=1) - Mx)

        # Расчет компонент магнитной силы
        Fx = Jy * Mz - Jz * My
        Fy = Jz * Mx - Jx * Mz
        Fz = Jx * My - Jy * Mx

        # Расчет профиля Electro-Leeway ограничения
        p_in = cp.where(rho < 256.0, (256.0 - rho) / (rho + 1.0), 0.0)
        press_ratio = (1.0 - p_in) / (p_in + 1e-5)
        damp = cp.clip(LE0 * (1.0 - press_ratio), 0.0, None)
        damp[rho >= 255.8] = 0.0

        # Интегрирование полей скоростей во времени
        Vx += Fx * damp * DT
        Vy += Fy * damp * DT
        Vz += (Fz + (1.0 - damp) * 15.0) * DT

        # Диффузия и разгон плотности непрерывной среды
        laplacian_rho = (
            cp.roll(rho, -1, axis=0) + cp.roll(rho, 1, axis=0) +
            cp.roll(rho, -1, axis=1) + cp.roll(rho, 1, axis=1) +
            cp.roll(rho, -1, axis=2) + cp.roll(rho, 1, axis=2) - 6.0 * rho
        )
        rho += (laplacian_rho * 0.005 + (damp * w * rho)) * DT

        # --- БЛОК ГИПЕРБОЛИЧЕСКОЙ ОЧИСТКИ ДИВЕРГЕНЦИИ (МЕТОД ДЕДНЕРА) ---
        divB = ((cp.roll(Mx, -1, axis=0) - Mx) + 
                (cp.roll(My, -1, axis=1) - My) + 
                (cp.roll(Mz, -1, axis=2) - Mz)) / DX_BASE
        max_divB = float(cp.max(cp.abs(divB)))

        # Обновление демпфирующего потенциала скалярного поля psi
        psi += (-0.1 * divB * DT) - (0.005 * psi * DT)

        # Коррекция компонент индукции для строгого удержания div B = 0
        Mx -= (cp.roll(psi, -1, axis=0) - psi) * DT
        My -= (cp.roll(psi, -1, axis=1) - psi) * DT
        Mz -= (cp.roll(psi, -1, axis=2) - psi) * DT
        # ---------------------------------------------------------------

        # Анализ эффективного сжатия шага сетки (r-refinement)
        dx_eff = DX_BASE / (1.0 + 0.1 * max_w)

        # Сбор данных текущей итерации в буфер
        log_lines.append(
            f"Step: {step:04d} | W_max: {max_w:.4f} | "
            f"divB: {max_divB:.2e} | DX: {dx_eff:.6f}\n"
        )

        # Вывод контрольных точек прогресса на экран
        if step % 100 == 0 or step == 1 or step == TOTAL_STEPS:
            print(
                f"Такт: {step:04d} | W_max: {max_w:.2f} | "
                f"divB: {max_divB:.2e} | DX_eff: {dx_eff:.5f}"
            )

    # 5. Экспорт результатов в лог-файл и скачивание
    filename = 'mhd_gpu_stress_test.log'
    with open(filename, 'w', encoding='utf-8') as f:
        f.writelines(log_lines)

    print(f"[ГОТОВО] Симуляция завершена. Лог сохранен в {filename}. Запуск выгрузки...")
    files.download(filename)

if __name__ == "__main__":
    run_gpu_stress_test()
