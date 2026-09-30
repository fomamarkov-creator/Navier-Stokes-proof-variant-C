from sys import bswap
from math import sin, cos, sqrt
from algorithm import parallelize
from memory import UnsafePointer
from std.atomic import Atomic

struct MHDSimulation:
    var u: UnsafePointer[SIMD[DType.float32, 4]]
    var B: UnsafePointer[SIMD[DType.float32, 4]]
    var E: UnsafePointer[SIMD[DType.float32, 4]]
    var rho: UnsafePointer[Float32]
    var u_stage: UnsafePointer[SIMD[DType.float32, 4]]
    var B_stage: UnsafePointer[SIMD[DType.float32, 4]]
    var rho_stage: UnsafePointer[Float32]
    var du: UnsafePointer[SIMD[DType.float32, 4]]
    var dB: UnsafePointer[SIMD[DType.float32, 4]]
    var drho: UnsafePointer[Float32]
    var max_omega: Atomic[DType.float32]
    fn __init__(inout self):
        self.u = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        self.B = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        self.E = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        self.rho = UnsafePointer[Float32].alloc(128 * 128 * 128)
        self.u_stage = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        self.B_stage = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        self.rho_stage = UnsafePointer[Float32].alloc(128 * 128 * 128)
        self.du = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        self.dB = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        self.drho = UnsafePointer[Float32].alloc(128 * 128 * 128)
        self.max_omega = Atomic[DType.float32](0.0)
        self.init_fields()

    fn __del__(owned self):
        self.u.free(); self.B.free(); self.E.free(); self.rho.free()
        self.u_stage.free(); self.B_stage.free(); self.rho_stage.free()
        self.du.free(); self.dB.free(); self.drho.free()

    @always_inline
    fn get_idx(self, i: Int, j: Int, k: Int) -> Int:
        return ((i % 128 + 128) % 128) + ((j % 128 + 128) % 128) * 128 + ((k % 128 + 128) % 128) * 128 * 128

    @always_inline
    fn get_hcp_shift(self, k: Int, m: Int) -> (Int, Int, Int):
        if k % 2 == 0:
            if m == 0: return (1, 0, 0)
            elif m == 1: return (-1, 0, 0)
            elif m == 2: return (0, 1, 0)
            elif m == 3: return (0, -1, 0)
            elif m == 4: return (1, -1, 0)
            elif m == 5: return (-1, 1, 0)
            elif m == 6: return (0, 0, 1)
            elif m == 7: return (1, 0, 1)
            elif m == 8: return (0, 1, 1)
            elif m == 9: return (0, 0, -1)
            elif m == 10: return (1, 0, -1)
            else: return (0, 1, -1)
        else:
            if m == 0: return (1, 0, 0)
            elif m == 1: return (-1, 0, 0)
            elif m == 2: return (0, 1, 0)
            elif m == 3: return (0, -1, 0)
            elif m == 4: return (1, -1, 0)
            elif m == 5: return (-1, 1, 0)
            elif m == 6: return (0, 0, 1)
            elif m == 7: return (-1, 0, 1)
            elif m == 8: return (0, -1, 1)
            elif m == 9: return (0, 0, -1)
            elif m == 10: return (-1, 0, -1)
            else: return (0, -1, -1)
    fn init_fields(inout self):
        for k in range(128):
            for j in range(128):
                for i in range(128):
                    let idx = self.get_idx(i, j, k)
                    let fx = Float32(i) * Float32(0.05)
                    let fy = Float32(j) * Float32(0.05)
                    let fz = Float32(k) * Float32(0.05)
                    self.u[idx] = SIMD[DType.float32, 4](sin(fx) * cos(fy), -cos(fx) * sin(fy), 0.0, 0.0)
                    self.B[idx] = SIMD[DType.float32, 4](sin(fz), cos(fz), 1.0, 0.0)
                    self.rho[idx] = 10.0

    fn compute_rhs(
        self, 
        u_in: UnsafePointer[SIMD[DType.float32, 4]], 
        B_in: UnsafePointer[SIMD[DType.float32, 4]], 
        rho_in: UnsafePointer[Float32],
        du_out: UnsafePointer[SIMD[DType.float32, 4]], 
        dB_out: UnsafePointer[SIMD[DType.float32, 4]], 
        drho_out: UnsafePointer[Float32]
    ):
        let e_ptr = self.E
        let omega_atomic_ptr = UnsafePointer[Atomic[DType.float32]].address_of(self.max_omega)

        @parameter
        fn compute_hydro(idx: Int):
            let k = idx // (128 * 128)
            let j = (idx % (128 * 128)) // 128
            let i = idx % 128
            let b_center = B_in[idx]
            let Jx = (B_in[self.get_idx(i, j+1, k)].get<2>() - b_center.get<2>()) - (B_in[self.get_idx(i, j, k+1)].get<1>() - b_center.get<1>())
            let Jy = (B_in[self.get_idx(i, j, k+1)].get<0>() - b_center.get<0>()) - (B_in[self.get_idx(i+1, j, k)].get<2>() - b_center.get<2>())
            let Jz = (B_in[self.get_idx(i+1, j, k)].get<1>() - b_center.get<1>()) - (B_in[self.get_idx(i, j+1, k)].get<0>() - b_center.get<0>())
            let Fx_lorenz = Jy * b_center.get<2>() - Jz * b_center.get<1>()
            let Fy_lorenz = Jz * b_center.get<0>() - Jx * b_center.get<2>()
            let Fz_lorenz = Jx * b_center.get<1>() - Jy * b_center.get<0>()
            let rho_c = rho_in[idx]
            let p_in_c = (Float32(256.0) - rho_c) / (rho_c + Float32(1.0)) if rho_c < Float32(256.0) else Float32(0.0)
            let press_ratio = (Float32(1.0) - p_in_c) / (p_in_c + Float32(1e-5))
            var leeway_xx = Float32(0.024) * (Float32(1.0) - press_ratio)
            if rho_c >= Float32(255.8) or leeway_xx < Float32(0.0): leeway_xx = Float32(0.0)
            let Fx_final = Fx_lorenz * leeway_xx
            let Fy_final = Fy_lorenz * leeway_xx
            let Fz_final = Fz_lorenz + (Float32(1.0) - leeway_xx) * Float32(5.0)
            du_out[idx] = SIMD[DType.float32, 4](Fx_final, Fy_final, Fz_final, 0.0)
            let u_center = u_in[idx]
            let Ex = -(u_center.get<1>() * b_center.get<2>() - u_center.get<2>() * b_center.get<1>())
            let Ey = -(u_center.get<2>() * b_center.get<0>() - u_center.get<0>() * b_center.get<2>())
            let Ez = -(u_center.get<0>() * b_center.get<1>() - u_center.get<1>() * b_center.get<0>())
            e_ptr[idx] = SIMD[DType.float32, 4](Ex, Ey, Ez, 0.0)
            let curl_ux = (u_in[self.get_idx(i, j+1, k)].get<2>() - u_center.get<2>()) - (u_in[self.get_idx(i, j, k+1)].get<1>() - u_center.get<1>())
            let curl_uy = (u_in[self.get_idx(i, j, k+1)].get<0>() - u_center.get<0>()) - (u_in[self.get_idx(i+1, j, k)].get<2>() - u_center.get<2>())
            let curl_uz = (u_in[self.get_idx(i+1, j, k)].get<1>() - u_center.get<1>()) - (u_in[self.get_idx(i, j+1, k)].get<0>() - u_center.get<0>())
            let omega = sqrt(curl_ux*curl_ux + curl_uy*curl_uy + curl_uz*curl_uz)
            var current_max = omega_atomic_ptr[].load()
            while omega > current_max:
                if omega_atomic_ptr[].compare_exchange_weak(current_max, omega): break
            var laplacian_rho: Float32 = 0.0
            for m in range(12):
                let s = self.get_hcp_shift(k, m)
                laplacian_rho += (rho_in[self.get_idx(i + s.0, j + s.1, k + s.2)] - rho_c)
            var non_lin_growth: Float32 = Float32(0.0)
            if rho_c < Float32(255.5): non_lin_growth = Float32(0.024) * omega * rho_c
            drho_out[idx] = laplacian_rho * Float32(0.05) + non_lin_growth

        parallelize[compute_hydro](128 * 128 * 128)

        @parameter
        fn compute_maxwell(idx: Int):
            let k = idx // (128 * 128)
            let j = (idx % (128 * 128)) // 128
            let i = idx % 128
            let e_c = e_ptr[idx]
            let curl_Ex = (e_ptr[self.get_idx(i, j+1, k)].get<2>() - e_c.get<2>()) - (e_ptr[self.get_idx(i, j, k+1)].get<1>() - e_c.get<1>())
            let curl_Ey = (e_ptr[self.get_idx(i, j, k+1)].get<0>() - e_c.get<0>()) - (e_ptr[self.get_idx(i+1, j, k)].get<2>() - e_c.get<2>())
            let curl_Ez = (e_ptr[self.get_idx(i+1, j, k)].get<1>() - e_c.get<1>()) - (e_ptr[self.get_idx(i, j+1, k)].get<0>() - e_c.get<0>())
            var laplacian_B = SIMD[DType.float32, 4](0.0, 0.0, 0.0, 0.0)
            let b_c = B_in[idx]
            for m in range(12):
                let s = self.get_hcp_shift(k, m)
                laplacian_B += (B_in[self.get_idx(i + s.0, j + s.1, k + s.2)] - b_c)
            let dB_x = -curl_Ex + Float32(0.05) * laplacian_B.get<0>()
            let dB_y = -curl_Ey + Float32(0.05) * laplacian_B.get<1>()
            let dB_z = -curl_Ez + Float32(0.05) * laplacian_B.get<2>()
            dB_out[idx] = SIMD[DType.float32, 4](dB_x, dB_y, dB_z, 0.0)

        parallelize[compute_maxwell](128 * 128 * 128)
    fn rk4_step(inout self):
        let k1_u = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        let k1_B = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        let k1_rho = UnsafePointer[Float32].alloc(128 * 128 * 128)
        let k2_u = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        let k2_B = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        let k2_rho = UnsafePointer[Float32].alloc(128 * 128 * 128)
        let k3_u = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        let k3_B = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        let k3_rho = UnsafePointer[Float32].alloc(128 * 128 * 128)
        let k4_u = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        let k4_B = UnsafePointer[SIMD[DType.float32, 4]].alloc(128 * 128 * 128)
        let k4_rho = UnsafePointer[Float32].alloc(128 * 128 * 128)

        self.compute_rhs(self.u, self.B, self.rho, k1_u, k1_B, k1_rho)
        for i in range(128 * 128 * 128):
            self.u_stage[i] = self.u[i] + k1_u[i] * Float32(0.00025)
            self.B_stage[i] = self.B[i] + k1_B[i] * Float32(0.00025)
            self.rho_stage[i] = self.rho[i] + k1_rho[i] * Float32(0.00025)
        self.compute_rhs(self.u_stage, self.B_stage, self.rho_stage, k2_u, k2_B, k2_rho)
        for i in range(128 * 128 * 128):
            self.u_stage[i] = self.u[i] + k2_u[i] * Float32(0.00025)
            self.B_stage[i] = self.B[i] + k2_B[i] * Float32(0.00025)
            self.rho_stage[i] = self.rho[i] + k2_rho[i] * Float32(0.00025)
        self.compute_rhs(self.u_stage, self.B_stage, self.rho_stage, k3_u, k3_B, k3_rho)
        for i in range(128 * 128 * 128):
            self.u_stage[i] = self.u[i] + k3_u[i] * Float32(0.0005)
            self.B_stage[i] = self.B[i] + k3_B[i] * Float32(0.0005)
            self.rho_stage[i] = self.rho[i] + k3_rho[i] * Float32(0.0005)
        self.compute_rhs(self.u_stage, self.B_stage, self.rho_stage, k4_u, k4_B, k4_rho)
        for i in range(128 * 128 * 128):
            self.u[i] += (k1_u[i] + k2_u[i] * Float32(2.0) + k3_u[i] * Float32(2.0) + k4_u[i]) * Float32(0.0005 / 6.0)
            self.B[i] += (k1_B[i] + k2_B[i] * Float32(2.0) + k3_B[i] * Float32(2.0) + k4_B[i]) * Float32(0.0005 / 6.0)
            self.rho[i] += (k1_rho[i] + k2_rho[i] * Float32(2.0) + k3_rho[i] * Float32(2.0) + k4_rho[i]) * Float32(0.0005 / 6.0)
        k1_u.free(); k1_B.free(); k1_rho.free()
        k2_u.free(); k2_B.free(); k2_rho.free()
        k3_u.free(); k3_B.free(); k3_rho.free()
        k4_u.free(); k4_B.free(); k4_rho.free()

    fn calculate_total_energy(self) -> (Float32, Float32):
        var kin_energy: Float32 = 0.0
        var mag_energy: Float32 = 0.0
        for i in range(128 * 128 * 128):
            let u_vec = self.u[i]
            let b_vec = self.B[i]
            kin_energy += u_vec.get<0>()*u_vec.get<0>() + u_vec.get<1>()*u_vec.get<1>() + u_vec.get<2>()*u_vec.get<2>()
            mag_energy += b_vec.get<0>()*b_vec.get<0>() + b_vec.get<1>()*b_vec.get<1>() + b_vec.get<2>()*b_vec.get<2>()
        return kin_energy * Float32(0.05), mag_energy * Float32(0.05)

    fn save_vtk(self, filename: String) raises:
        var f = open(filename, "wb")
        f.write("# vtk DataFile Version 3.0\n")
        f.write("MHO HCP LATTICE SINGULARITY BLOWUP SNAPSHOT\n")
        f.write("BINARY\n")
        f.write("DATASET STRUCTURED_POINTS\n")
        f.write("DIMENSIONS 128 128 128\n")
        f.write("ORIGIN 0.0 0.0 0.0\n")
        f.write("SPACING 0.05 0.05 0.05\n")
        f.write("POINT_DATA 2097152\n")
        f.write("SCALARS density float 1\n")
        f.write("LOOKUP_TABLE default\n")
        for i in range(128 * 128 * 128):
            var val = self.rho[i]
            let bytes = bswap(val.bitcast[DType.uint32]())
            f.write(bytes)
        f.write("\nVECTORS velocity float\n")
        for i in range(128 * 128 * 128):
            let vec = self.u[i]
            let vx = bswap(vec.get<0>().bitcast[DType.uint32]())
            let vy = bswap(vec.get<1>().bitcast[DType.uint32]())
            let vz = bswap(vec.get<2>().bitcast[DType.uint32]())
            f.write(vx); f.write(vy); f.write(vz)
        f.write("\nVECTORS magnetic_field float\n")
        for i in range(128 * 128 * 128):
            let vec = self.B[i]
            let bx = bswap(vec.get<0>().bitcast[DType.uint32]())
            let by = bswap(vec.get<1>().bitcast[DType.uint32]())
            let bz = bswap(vec.get<2>().bitcast[DType.uint32]())
            f.write(bx); f.write(by); f.write(bz)
        f.close()
def main() raises:
    print("[INIT] Zapusk симулятора на базе архитектуры Mojo 1.1.0...")
    var sim = MHDSimulation()
    var log_file = open("mhd_energy_balance.log", "w")
    log_file.write("Step,KineticEnergy,MagneticEnergy,TotalEnergy,MaxOmega\n")
    print("[RUN] Start RK4 Simulation (Сетка 128x128x128)...")
    
    for step in range(1, 1501):
        sim.max_omega.store(0.0)
        sim.rk4_step()
        
        let current_omega = sim.max_omega.load()
        let energies = sim.calculate_total_energy()
        let total_e = energies.0 + energies.1
        
        log_file.write(String(step) + "," + String(energies.0) + "," + String(energies.1) + "," + String(total_e) + "," + String(current_omega) + "\n")
        
        if step % 20 == 0 or step == 1:
            print("Шаг:", step, "| E_kin:", energies.0, "| E_mag:", energies.1, "| ω_max:", current_omega)
            
        if step % 200 == 0:
            let filename = "mhd_snapshot_step_" + String(step) + ".vtk"
            sim.save_vtk(filename)
            print(" -> [EXPORT] Снапшот сохранен в файл:", filename)
            
        if current_omega > Float32(5000.0):
            print("\n[🚨 CRITICAL BLOW-UP ACCOMPLISHED]")
            print("Градиентная катастрофа зафиксирована на шаге:", step)
            sim.save_vtk("mhd_critical_blowup.vtk")
            break
            
    log_file.close()
    print("[DONE] Симуляция успешно завершена.")
