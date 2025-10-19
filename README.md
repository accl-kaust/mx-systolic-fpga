# mx-systolic-fpga
This repository provides the **open-source implementation of Microscaling (MX) minifloat systolic arrays** on FPGAs. 
It includes parametrizable Top module and Processing Element (PE) designs, two accumulation modes (Exact and BF16), and scalable systolic array architectures targeting GEMM workloads.

## Supported Data Formats
- MXFP8_E5M2
- MXFP8_E4M3
- MXFP6_E3M2
- MXFP6_E2M3

## Repository Structure
The repository is organized as follows:
```bash
mx-systolic-fpga/
├─ src/         # RTL source files for different PE and top-level designs
│  ├─ exact/    # Exact accumulation implementation
│  └─ bf16/     # BF16 accumulation implementation
├─ tb/          # Testbenches for simulation
└─ docs/        # Documentation (optional)
```

Each accumulation type (exact/, bf16/) contains multiple PE implementations with different pipeline depths (1-stage, 2-stage, etc.).
Only one PE variant should be selected for synthesis depending on latency and throughput requirements.
The bf16/ has separete top module files as well depending on the pipeline stages.
## Building the Project in Vivado

To synthesize the design in Vivado:

Create a new Vivado project.

Add the Top module and PE implementation you intend to target.

Enable out-of-context synthesis mode:

Go to Tools → Settings → Synthesis → More Options

Add the following flag:
```bash
-mode out_of_context
```
Enable register retiming in synthesis mode:
Go to Tools → Settings → Synthesis → register retiming  

## 🛠️ Getting Started
1. Clone the Repository
```bash
git clone https://github.com/accl-kaust/mx-systolic-fpga.git
cd mx-systolic-fpga
```
2. Explore the Design

Review src/ for RTL implementations of PEs and top modules.

Choose the accumulation type (exact or bf16) and pipeline depth required.

Edit the top module parameters (exp_width, man_width, N, etc.) to match your MX format and target configuration.

3. Simulate and Test

Use the testbenches in tb/ to run RTL simulations and verify functional correctness before synthesis.

The data/ folder holds sample data points for each data type with the result file for the result to test compare against.

### 📄 Notes

The PE module name is the same across different pipeline variants — include only one in your synthesis project.
