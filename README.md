# MESSI
Modelling Evolution of Secondary Structure Interactions

### Installing and running MESSI:
1. [Download](https://julialang.org/downloads/) and install Julia 1.0 or higher, if it isn't already installed on your system.
2. [Download MESSI](https://github.com/michaelgoldendev/MESSI/archive/master.zip)'s source code and extract it to a folder on your computer.
3. Navigate to the folder using a Windows command prompt or a Linux terminal:
```
cd /path_to_messi/MESSI/
```
4. If you are running the code for the first time, run InstallDependencies.jl to install all the package dependencies. This can be done using the path to your julia executable:
```
/path_to_julia/bin/julia src/InstallDependencies.jl
```
5. Run MESSI using the path to your julia executable and the path of your alignment file:
```
/path_to_julia/bin/julia src/MESSI.jl --alignment /path_to_alignment/example.fas
```

By default MESSI will create a `results` folder in `/path_to_messi/MESSI/results/example/`

### Creating results files:
MESSI can take a long time to run, but will save intermediate state as it runs. To produce intermediate results: execute MESSI using the same command as before, but using the `--processmax` flag. For example:
```
/path_to_julia/bin/julia src/MESSI.jl --alignment /path_to_alignment/example.fas --processmax
```
