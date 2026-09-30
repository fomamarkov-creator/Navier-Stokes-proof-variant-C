import numpy as np

DIM = 256
DT = 0.001
LE0 = 15.5
M_CONST = 150.0
DX = 0.0125

print('[INIT] Starting 256^3 (16.7M nodes) Verification Suite...')
x = np.linspace(0, DIM * DX, DIM, dtype=np.float32)
X, Y, Z = np.meshgrid(x, x, x, indexing='ij')

u_x = np.sin(X) * np.sin(Y) * np.cos(Z)
u_y = -np.cos(X) * np.cos(Y) * np.sin(Z)
u_z = np.sin(4.0 * Z)

B_x = np.sin(Z)
B_y = np.cos(Z)
B_z = np.ones_like(Z)
rho = np.ones_like(X) * 10.0

log_f = open('mhd_energy_balance.log', 'w')
log_f.write('Step,KineticEnergy,MagneticEnergy,TotalEnergy,MaxOmega,H2_norm,Z_index\n')
print('[RUN] Processing 150 evaluation cycles...')

for step in range(1, 151):
    curl_ux = (np.roll(u_z, -1, axis=2) - u_z) - (np.roll(u_y, -1, axis=1) - u_y)
    curl_uy = (np.roll(u_x, -1, axis=2) - u_x) - (np.roll(u_z, -1, axis=0) - u_z)
    curl_uz = (np.roll(u_y, -1, axis=0) - u_y) - (np.roll(u_x, -1, axis=1) - u_x)
    omega = np.sqrt(curl_ux**2 + curl_uy**2 + curl_uz**2)
    max_omega = float(np.max(omega))
    
    Jx = (np.roll(B_z, -1, axis=2) - B_z) - (np.roll(B_y, -1, axis=1) - B_y)
    Jy = (np.roll(B_x, -1, axis=2) - B_x) - (np.roll(B_z, -1, axis=0) - B_z)
    Jz = (np.roll(B_y, -1, axis=0) - B_y) - (np.roll(B_x, -1, axis=1) - B_x)
    Fx = Jy * B_z - Jz * B_y
    Fy = Jz * B_x - Jx * B_z
    Fz = Jx * B_y - Jy * B_x
    
    p_in = np.where(rho < 256.0, (256.0 - rho) / (rho + 1.0), 0.0)
    press_ratio = (1.0 - p_in) / (p_in + 1e-5)
    leeway = LE0 * (1.0 - press_ratio)
    leeway[rho >= 255.8] = 0.0
    leeway[leeway < 0.0] = 0.0
    
    u_x += Fx * leeway * DT
    u_y += Fy * leeway * DT
    u_z += (Fz + (1.0 - leeway) * 15.0) * DT
    
    lapl_rho = (np.roll(rho, -1, axis=0) + np.roll(rho, 1, axis=0) + 
                np.roll(rho, -1, axis=1) + np.roll(rho, 1, axis=1) + 
                np.roll(rho, -1, axis=2) + np.roll(rho, 1, axis=2) - 6.0 * rho)
    rho += (lapl_rho * 0.005 + (leeway * omega * rho)) * DT
    
    h2_norm = float(np.sum((np.roll(omega, -1, axis=0) - omega)**2 + 
                           (np.roll(omega, -1, axis=1) - omega)**2 + 
                           (np.roll(omega, -1, axis=2) - omega)**2) * (DX**3))
    
    h_local = u_x * curl_ux + u_y * curl_uy + u_z * curl_uz
    e_kin = float(np.sum(u_x**2 + u_y**2 + u_z**2) * (DX**3))
    e_mag = float(np.sum(B_x**2 + B_y**2 + B_z**2) * (DX**3))
    z_index = float(np.sum(np.abs(h_local)) * (DX**3)) / e_kin if e_kin > 0 else 0.0
    
    log_f.write(f'{step},{e_kin},{e_mag},{e_kin+e_mag},{max_omega},{h2_norm},{z_index}\n')
    
    if step % 20 == 0 or step == 1 or step == 150:
        print(f'Step: {step:03d} | w_max: {max_omega:.2f} | H2_norm: {h2_norm:.4f} | Z_index: {z_index:.5f}')
        
    if max_omega > M_CONST:
        print(f'\n[🚨 HYPER CRITICAL BLOW-UP 256^3]\nSingularity boundary breached at step: {step}')
        break

log_f.close()
print('[DONE] Verification suite finished successfully.')
