# parsec-riscv-performance-testing

Script(s) for automatedly setting up and running the PARSEC benchmarks on an emulated RISC-V environment.

The main purpose is to document the steps required in order to reproduce the setup used for a QEMU/RISC-V related paper I've been collaborating with.

## Execution

1. run `./setup_system.sh`
   - it will prepare a `projects` directory, will all the required sources/data
   - it will prepare a `components` directory, with all the compiled/processed objects
2. run `run_parsec_benchmarks.sh`
   - it will run the PARSEC benchmarks in a VM, and output the results into `output`
